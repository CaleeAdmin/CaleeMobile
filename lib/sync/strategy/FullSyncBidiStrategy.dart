import 'package:caleesync/entity/SyncContext.dart';
import 'package:caleesync/entity/SyncSummary.dart';
import 'package:caleesync/sync/SyncEnum.dart';
import 'package:caleesync/sync/strategy/SyncStrategy.dart';
import 'package:flutter/cupertino.dart';
import 'package:sqflite/sqflite.dart';

import '../../entity/sync_run_record.dart';
import '../operation/sync_operation.dart';
import '../operation/sync_operation_executor.dart';
import '../operation/sync_reconciler.dart';
import '../sync_run_telemetry.dart';
import '../sync_run_recorder.dart';
import '../operation/store_adapters.dart';
import '../operation/unified_store_executor.dart';

import '../../core/platform/pigeon/calendar_api.g.dart';

/// TWO_WAY strategy using a deterministic per-item decision matrix.
///
/// Decision inputs: remoteExists/localExists/remoteChanged/localChanged.
/// Conflict resolution: binding origin decides winner (remote pull vs local push).
class FullSyncBidiStrategy extends SyncStrategy {
  static const int _defaultDeletionPolicy = SyncDeletionPolicy.bidirectional;
  final SyncReconciler _reconciler = const SyncReconciler();
  final SyncOperationExecutor _executor = const SyncOperationExecutor();


  @override
  Future<void> execute(SyncContext ctx, SyncSummary summary) async {
    try {
      if (loginName == null || loginName?.isEmpty == true) return;

      final db = await dbHelper.database;
      final String localCalendarId = ctx.localCalendarId;
      final int remoteCollectionId = ctx.remoteCollectionId;
      final String remotePath = ctx.remotePath;
      final String? newCtag = ctx.ctag;
      final int origin = (ctx.extra['binding_origin'] as int?) ?? SyncBindingOrigin.remote;
      final int bindingId = (ctx.extra['binding_id'] as int?) ?? 0;

      final RemoteStoreAdapter remoteAdapter = RemoteStoreAdapter(
        nc: nc,
        loginName: loginName!,
        remotePath: remotePath,
        isSubscription: ctx.isSubscription ?? false,
      );
      final LocalStoreAdapter localAdapter = LocalStoreAdapter(
        nativeApi: nativeApi,
        localCalendarId: localCalendarId,
      );
      final UnifiedStoreExecutor storeExecutor = UnifiedStoreExecutor(
        localAdapter: localAdapter,
        remoteAdapter: remoteAdapter,
      );

      final AdapterSnapshot remoteSnapshot = await remoteAdapter.getSnapshot();

      final List<Map<String, dynamic>> mappedRecords = await db.query(
        'sync_items',
        where: 'remote_collection_id = ?',
        whereArgs: [remoteCollectionId],
      );

      final _RepairResult dedup = await _repairDuplicateMappings(db, remoteCollectionId, mappedRecords);
      final List<Map<String, dynamic>> records = dedup.records;

      final AdapterSnapshot localSnapshot = await localAdapter.getSnapshot();
      final Map<String, PlatformItem> localItemsMap = {
        for (final entry in localSnapshot.byStableKey.entries)
          if (entry.value.raw['item'] is PlatformItem) entry.key: entry.value.raw['item'] as PlatformItem,
      };

      final Map<String, Map<String, dynamic>> mappingByRemoteUid = {
        for (var r in records)
          if ((r['remote_uid']?.toString() ?? '').isNotEmpty) r['remote_uid'].toString(): r
      };

      final Map<String, Map<String, dynamic>> remoteByUid = {
        for (final entry in remoteSnapshot.byStableKey.entries)
          if (entry.key.isNotEmpty) entry.key: entry.value.raw,
      };

      final Set<String> allUids = {
        ...remoteByUid.keys,
        ...mappingByRemoteUid.keys,
        ...localItemsMap.keys,
      };

      final int mappedCount = mappingByRemoteUid.length;
      final bool suspiciousEmptyRemoteFetch = remoteSnapshot.parseProducedZeroEvents && mappedCount > 0;
      final bool suspiciousEmptyLocalFetch = localItemsMap.isEmpty && mappedCount > 0;
      final bool remoteSnapshotTrusted =
          remoteSnapshot.fetchSucceeded &&
          (remoteSnapshot.statusCode == 200 || remoteSnapshot.statusCode == 207) &&
          (newCtag ?? '').isNotEmpty &&
          !suspiciousEmptyRemoteFetch;
      final bool localSnapshotTrusted = !suspiciousEmptyLocalFetch;

      int localDeleteCandidates = 0;
      int remoteDeleteCandidates = 0;
      for (final uid in allUids) {
        final remoteExists = remoteByUid[uid] != null;
        final localExists = localItemsMap[uid] != null;
        if (!remoteExists && localExists) {
          if (_defaultDeletionPolicy == SyncDeletionPolicy.remoteDeleteWins) {
            localDeleteCandidates++;
          } else {
            remoteDeleteCandidates++;
          }
        }
      }

      final bool allowMassDeletion = isMassDeletionOverrideEnabled(bindingId);
      final bool massDeletionSafetyTripped =
          localDeleteCandidates >= SyncStrategy.massDeletionAbsoluteThreshold ||
          remoteDeleteCandidates >= SyncStrategy.massDeletionAbsoluteThreshold;
      final bool blockDeletesBySafetyGate = massDeletionSafetyTripped && !allowMassDeletion;

      if (!remoteSnapshotTrusted || !localSnapshotTrusted) {
        debugPrint('[SYNC_SAFETY][binding=$remoteCollectionId] TWO_WAY untrusted snapshot; block delete actions '
            '(remoteTrusted=$remoteSnapshotTrusted, localTrusted=$localSnapshotTrusted, status=${remoteSnapshot.statusCode}, fetchSucceeded=${remoteSnapshot.fetchSucceeded})');
      }
      if (blockDeletesBySafetyGate) {
        debugPrint('[SYNC_SAFETY][binding=$remoteCollectionId] aborted by safety gate '
            '(localDeleteCandidates=$localDeleteCandidates, remoteDeleteCandidates=$remoteDeleteCandidates, mappedCount=$mappedCount, threshold=${SyncStrategy.massDeletionAbsoluteThreshold})');
        summary.recordBindingOutcome(bindingId, SyncOutcomeStatus.safetyGateBlockedDeletions);
        summary.telemetry?.onSafetyTriggered(ctx: ctx, detail: 'localDeleteCandidates=$localDeleteCandidates remoteDeleteCandidates=$remoteDeleteCandidates');
        summary.errorLog.add('[ERROR] ${ctx.displayName} Safety gate blocked deletions (localDeleteCandidates=$localDeleteCandidates, remoteDeleteCandidates=$remoteDeleteCandidates, mappedCount=$mappedCount, threshold=${SyncStrategy.massDeletionAbsoluteThreshold})');
      }

      int createLocal = 0;
      int createRemote = 0;
      int pull = 0;
      int push = 0;
      int deleteLocal = 0;
      int deleteRemote = 0;
      int skip = 0;
      int conflicts = 0;

      debugPrint('[SYNC_BINDING][id=$remoteCollectionId] mode=TWO_WAY origin=$origin deletionPolicy=$_defaultDeletionPolicy '
          'counts(remote=${remoteByUid.length}, local=${localItemsMap.length}, mapped=${mappingByRemoteUid.length})');

      // Main decision matrix loop: each uid maps to exactly one action.
      for (final uid in allUids) {
        final remote = remoteByUid[uid];
        final mapping = mappingByRemoteUid[uid];
        final local = localItemsMap[uid];

        final bool remoteExists = remote != null;
        final bool localExists = local != null;

        final String remoteToken = normalizeRemoteToken(remote?['etag']);
        final String storedRemoteToken = normalizeRemoteToken(mapping?['last_etag']);
        final int localLastModified = local?.lastModified ?? 0;
        final int storedLocalLastModified = (mapping?['last_mtime'] as int?) ?? 0;

        final bool remoteChanged = remoteExists && (mapping == null || remoteToken != storedRemoteToken);
        final bool localChanged = localExists && (mapping == null || localLastModified > storedLocalLastModified);
        final int status = (mapping?['sync_status'] as int?) ?? SyncItemStatus.synced;

        final plan = _reconciler.plan(
          uid: uid,
          mode: SyncReconcileMode.bidi,
          remoteExists: remoteExists,
          localExists: localExists,
          remoteChanged: remoteChanged,
          localChanged: localChanged,
          hasMapping: mapping != null,
          bindingOrigin: origin,
          deletionPolicy: _defaultDeletionPolicy,
        );

        if (remoteChanged && localChanged && remoteExists && localExists) {
          conflicts++;
        }

        debugPrint('[SYNC_ITEM][binding=$remoteCollectionId][uid=$uid] operation=${plan.operation} '
            'flags(remoteExists=$remoteExists localExists=$localExists remoteChanged=$remoteChanged localChanged=$localChanged origin=$origin reason=${plan.reason})');

        final bool completed = await _executor.execute(
          plan: plan,
          onLocalCreate: () async {
            final result = await storeExecutor.execute(
              operation: CanonicalSyncOperation.localCreate,
              uid: uid,
              remote: remote,
              local: local,
              mapping: mapping,
              remoteToken: remoteToken,
            );
            if (!result.success || result.mutation == null) return false;
            await _persistPulledMutation(
              db: db,
              remoteCollectionId: remoteCollectionId,
              uid: uid,
              remote: remote,
              remoteToken: remoteToken,
              mutation: result.mutation!,
            );
            createLocal++;
            summary.telemetry?.onOperation(ctx: ctx, target: SyncOperationTarget.local, type: SyncOperationType.created);
            return true;
          },
          onLocalUpdate: () async {
            final result = await storeExecutor.execute(
              operation: CanonicalSyncOperation.localUpdate,
              uid: uid,
              remote: remote,
              local: local,
              mapping: mapping,
              remoteToken: remoteToken,
            );
            if (!result.success || result.mutation == null) return false;
            await _persistPulledMutation(
              db: db,
              remoteCollectionId: remoteCollectionId,
              uid: uid,
              remote: remote,
              remoteToken: remoteToken,
              mutation: result.mutation!,
            );
            pull++;
            summary.telemetry?.onOperation(ctx: ctx, target: SyncOperationTarget.local, type: SyncOperationType.updated);
            return true;
          },
          onRemoteCreate: () async {
            final String stableUid = (local?.uid ?? '').trim().isNotEmpty
                ? (local?.uid ?? '').trim()
                : 'local_${local?.localId ?? ''}';
            final result = await storeExecutor.execute(
              operation: CanonicalSyncOperation.remoteCreate,
              uid: stableUid,
              remote: remote,
              local: local,
              mapping: mapping,
              remoteToken: remoteToken,
            );
            if (!result.success || result.mutation == null) return false;
            await _persistPushedMutation(
              db: db,
              remoteCollectionId: remoteCollectionId,
              local: local,
              mutation: result.mutation!,
            );
            createRemote++;
            summary.telemetry?.onOperation(ctx: ctx, target: SyncOperationTarget.remote, type: SyncOperationType.created);
            return true;
          },
          onRemoteUpdate: () async {
            final String stableUid = (local?.uid ?? '').trim().isNotEmpty
                ? (local?.uid ?? '').trim()
                : 'local_${local?.localId ?? ''}';
            final result = await storeExecutor.execute(
              operation: CanonicalSyncOperation.remoteUpdate,
              uid: stableUid,
              remote: remote,
              local: local,
              mapping: mapping,
              remoteToken: remoteToken,
            );
            if (!result.success || result.mutation == null) return false;
            await _persistPushedMutation(
              db: db,
              remoteCollectionId: remoteCollectionId,
              local: local,
              mutation: result.mutation!,
            );
            if (mapping == null) {
              createRemote++;
              summary.telemetry?.onOperation(ctx: ctx, target: SyncOperationTarget.remote, type: SyncOperationType.created);
            } else {
              push++;
              summary.telemetry?.onOperation(ctx: ctx, target: SyncOperationTarget.remote, type: SyncOperationType.updated);
            }
            return true;
          },
          onLocalDelete: () async {
            final result = await storeExecutor.execute(
              operation: CanonicalSyncOperation.localDelete,
              uid: uid,
              remote: remote,
              local: local,
              mapping: mapping,
              remoteToken: remoteToken,
              allowDelete: !blockDeletesBySafetyGate && remoteSnapshotTrusted && localSnapshotTrusted,
            );
            if (!result.success) return false;
            await db.delete('sync_items', where: 'remote_collection_id = ? AND remote_uid = ?', whereArgs: [remoteCollectionId, uid]);
            deleteLocal++;
            summary.telemetry?.onOperation(ctx: ctx, target: SyncOperationTarget.local, type: SyncOperationType.deleted);
            return true;
          },
          onRemoteDelete: () async {
            final result = await storeExecutor.execute(
              operation: CanonicalSyncOperation.remoteDelete,
              uid: uid,
              remote: remote,
              local: local,
              mapping: mapping,
              remoteToken: remoteToken,
              allowDelete: !blockDeletesBySafetyGate && remoteSnapshotTrusted && localSnapshotTrusted,
            );
            if (!result.success) return false;
            await db.delete('sync_items', where: 'remote_collection_id = ? AND remote_uid = ?', whereArgs: [remoteCollectionId, uid]);
            deleteRemote++;
            summary.telemetry?.onOperation(ctx: ctx, target: SyncOperationTarget.remote, type: SyncOperationType.deleted);
            return true;
          },
          onMarkSynced: () async {
            if (mapping != null && remoteExists && status != SyncItemStatus.synced) {
              await db.update(
                'sync_items',
                {'sync_status': SyncItemStatus.synced},
                where: 'remote_collection_id = ? AND remote_uid = ?',
                whereArgs: [remoteCollectionId, uid],
              );
            }
            return true;
          },
          onMappingDelete: () async => true,
          onMappingUpsert: () async => true,
        );

        if (!completed || plan.operation == CanonicalSyncOperation.skip) {
          skip++;
        }
      }

      if (!blockDeletesBySafetyGate) {
        summary.success++;
        if (allowMassDeletion) {
          summary.recordBindingOutcome(bindingId, SyncOutcomeStatus.persistentOverrideEnabled);
          summary.successLog.add('[WARN] ${ctx.displayName} Persistent override enabled (dangerous mode)');
        } else {
          summary.recordBindingOutcome(bindingId, SyncOutcomeStatus.completedNormally);
          summary.successLog.add('[INFO] ${ctx.displayName} Completed normally');
        }
        final trust = (!remoteSnapshotTrusted || !localSnapshotTrusted)
            ? SnapshotTrustStatus.unknown
            : SnapshotTrustStatus.remote;
        summary.telemetry?.onBindingEnd(
          ctx: ctx,
          status: SyncBindingResultStatus.success,
          snapshotTrustStatus: trust,
          safetyTriggered: false,
        );
      } else {
        summary.telemetry?.onBindingEnd(
          ctx: ctx,
          status: SyncBindingResultStatus.abortedBySafety,
          snapshotTrustStatus: SnapshotTrustStatus.unknown,
          safetyTriggered: true,
          errorCode: SyncErrorCode.safetyStop,
          errorMessage: 'Safety gate blocked deletions',
        );
      }
      debugPrint('[SYNC_SUMMARY][binding=$remoteCollectionId] createLocal=$createLocal createRemote=$createRemote '
          'pull=$pull push=$push deleteLocal=$deleteLocal deleteRemote=$deleteRemote skip=$skip '
          'conflicts=$conflicts dedupRemoved=${dedup.removedCount} remoteSnapshotTrusted=$remoteSnapshotTrusted localSnapshotTrusted=$localSnapshotTrusted '
          'localDeleteCandidates=$localDeleteCandidates remoteDeleteCandidates=$remoteDeleteCandidates safetyAborted=$blockDeletesBySafetyGate allowMassDeletion=$allowMassDeletion status=${remoteSnapshot.statusCode}');
    } catch (e) {
      summary.failed++;
      summary.errorLog.add('[ERROR] ${ctx.displayName} Two-way sync exception: $e');
      final code = mapSyncErrorCode(e);
      summary.telemetry?.onError(ctx: ctx, code: code, message: 'Two-way sync failed', technicalDetail: e.toString());
      summary.telemetry?.onBindingEnd(
        ctx: ctx,
        status: SyncBindingResultStatus.failed,
        snapshotTrustStatus: SnapshotTrustStatus.unknown,
        safetyTriggered: false,
        errorCode: code,
        errorMessage: 'Two-way sync failed',
        technicalDetail: e.toString(),
      );
    }
  }

  /// Repair duplicate mapping rows to enforce uniqueness invariants.
  ///
  /// Winner is chosen deterministically by structural quality, not "latest" heuristics.
  Future<_RepairResult> _repairDuplicateMappings(
    Database db,
    int remoteCollectionId,
    List<Map<String, dynamic>> mappedRecords,
  ) async {
    final Map<String, List<Map<String, dynamic>>> byRemoteUid = {};
    final Map<String, List<Map<String, dynamic>>> byLocalId = {};

    for (final r in mappedRecords) {
      final uid = r['remote_uid']?.toString() ?? '';
      final localId = r['local_item_id']?.toString() ?? '';
      if (uid.isNotEmpty) {
        byRemoteUid.putIfAbsent(uid, () => []).add(r);
      }
      if (localId.isNotEmpty) {
        byLocalId.putIfAbsent(localId, () => []).add(r);
      }
    }

    final Set<int> toDeleteIds = {};

    Map<String, dynamic> pickWinner(List<Map<String, dynamic>> group) {
      group.sort((a, b) {
        final int aHasLocal = ((a['local_item_id']?.toString() ?? '').isNotEmpty) ? 1 : 0;
        final int bHasLocal = ((b['local_item_id']?.toString() ?? '').isNotEmpty) ? 1 : 0;
        if (aHasLocal != bHasLocal) return bHasLocal.compareTo(aHasLocal);

        final int aHasHref = ((a['remote_href']?.toString() ?? '').isNotEmpty) ? 1 : 0;
        final int bHasHref = ((b['remote_href']?.toString() ?? '').isNotEmpty) ? 1 : 0;
        if (aHasHref != bHasHref) return bHasHref.compareTo(aHasHref);

        final int aid = (a['id'] as int?) ?? 0;
        final int bid = (b['id'] as int?) ?? 0;
        return aid.compareTo(bid);
      });
      return group.first;
    }

    for (final entry in byRemoteUid.entries) {
      if (entry.value.length <= 1) continue;
      final winner = pickWinner(entry.value);
      for (final r in entry.value) {
        if (r['id'] != winner['id']) toDeleteIds.add(r['id'] as int);
      }
      debugPrint('[SYNC_DEDUP][binding=$remoteCollectionId] duplicate_remote_uid=${entry.key} count=${entry.value.length} winner=${winner['id']}');
    }

    for (final entry in byLocalId.entries) {
      if (entry.value.length <= 1) continue;
      final winner = pickWinner(entry.value);
      for (final r in entry.value) {
        if (r['id'] != winner['id']) toDeleteIds.add(r['id'] as int);
      }
      debugPrint('[SYNC_DEDUP][binding=$remoteCollectionId] duplicate_local_id=${entry.key} count=${entry.value.length} winner=${winner['id']}');
    }

    for (final id in toDeleteIds) {
      await db.delete('sync_items', where: 'id = ?', whereArgs: [id]);
    }

    final List<Map<String, dynamic>> refreshed = await db.query(
      'sync_items',
      where: 'remote_collection_id = ?',
      whereArgs: [remoteCollectionId],
    );
    return _RepairResult(records: refreshed, removedCount: toDeleteIds.length);
  }

  Future<void> _persistPulledMutation({
    required Database db,
    required int remoteCollectionId,
    required String uid,
    required Map<String, dynamic>? remote,
    required String remoteToken,
    required AdapterMutationResult mutation,
  }) async {
    await upsertSyncedItem(
      db: db,
      remoteCollectionId: remoteCollectionId,
      uid: uid,
      localItemId: mutation.localId ?? '',
      etag: remoteToken,
      lastMtime: int.tryParse(mutation.token ?? '') ?? DateTime.now().millisecondsSinceEpoch,
      remoteHref: (remote?['href'] ?? '').toString(),
      summary: remote?['summary']?.toString(),
    );
  }

  Future<void> _persistPushedMutation({
    required Database db,
    required int remoteCollectionId,
    required PlatformItem? local,
    required AdapterMutationResult mutation,
  }) async {
    final String localId = local?.localId ?? mutation.localId ?? '';
    if (localId.isEmpty) return;

    await upsertSyncedItem(
      db: db,
      remoteCollectionId: remoteCollectionId,
      uid: mutation.stableKey,
      localItemId: localId,
      etag: mutation.token ?? '',
      lastMtime: local?.lastModified ?? DateTime.now().millisecondsSinceEpoch,
      remoteHref: mutation.remoteHref ?? '',
    );
  }
}

class _RepairResult {
  final List<Map<String, dynamic>> records;
  final int removedCount;

  _RepairResult({required this.records, required this.removedCount});
}
