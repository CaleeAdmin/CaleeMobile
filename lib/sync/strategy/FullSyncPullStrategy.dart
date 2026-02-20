import 'package:caleesync/entity/SyncContext.dart';
import 'package:caleesync/entity/SyncSummary.dart';
import 'package:caleesync/sync/SyncEnum.dart';
import 'package:caleesync/sync/strategy/SyncStrategy.dart';
import 'package:flutter/cupertino.dart';

import '../../core/platform/pigeon/calendar_api.g.dart';
import '../../entity/sync_run_record.dart';
import '../sync_run_recorder.dart';
import '../sync_run_telemetry.dart';

class FullSyncPullStrategy extends SyncStrategy {
  @override
  Future<void> execute(SyncContext ctx, SyncSummary summary) async {
    final String localCalendarId = ctx.localCalendarId;
    final int remoteCollectionId = ctx.remoteCollectionId;
    final String remotePath = ctx.remotePath;
    final String? newCtag = ctx.ctag;
    final String accountName = ctx.accountName;
    final int bindingId = (ctx.extra['binding_id'] as int?) ?? 0;
    final int origin = (ctx.extra['binding_origin'] as int?) ?? SyncBindingOrigin.remote;

    if (localCalendarId.isEmpty || remoteCollectionId <= 0) return;

    try {
      final snapshot = await nc.fetchUnifiedEventsSnapshot(
        calendarPath: remotePath,
        isSubscription: ctx.isSubscription ?? false,
      );
      final List<Map<String, dynamic>> remoteEvents = snapshot.events;
      final db = await dbHelper.database;

      final rawMapped = await db.query(
        'sync_items',
        where: 'remote_collection_id = ?',
        whereArgs: [remoteCollectionId],
      );
      final mappedRecords = await repairDuplicateMappings(db, remoteCollectionId, rawMapped);

      final Map<String, Map<String, dynamic>> mappingByRemoteUid = {
        for (final row in mappedRecords)
          if ((row['remote_uid']?.toString() ?? '').isNotEmpty) row['remote_uid'].toString(): row,
      };

      final localEvents = await loadLocalEvents(localCalendarId);
      final localByUid = mapLocalEventsByUid(localEvents);
      final localById = mapLocalEventsById(localEvents);
      final remoteByUid = {
        for (final row in remoteEvents)
          if ((row['remote_uid']?.toString() ?? '').isNotEmpty) row['remote_uid'].toString(): row,
      };

      final Set<String> allUids = {...remoteByUid.keys, ...mappingByRemoteUid.keys, ...localByUid.keys};

      final int mappedCount = mappingByRemoteUid.length;
      final bool suspiciousEmptyRemoteFetch = snapshot.parseProducedZeroEvents && mappedCount > 0;
      final bool remoteSnapshotTrusted =
          snapshot.fetchSucceeded &&
          (snapshot.statusCode == 200 || snapshot.statusCode == 207) &&
          (newCtag ?? '').isNotEmpty &&
          !suspiciousEmptyRemoteFetch;
      const bool localSnapshotTrusted = true;

      int localDeleteCandidates = 0;
      for (final uid in allUids) {
        final remoteExists = remoteByUid[uid] != null;
        final localExists =
            localByUid[uid] != null || ((mappingByRemoteUid[uid]?['local_item_id']?.toString() ?? '').isNotEmpty);
        final decision = resolveItemDecision(
          mode: SyncAction.fullSyncPull,
          bindingOrigin: origin,
          deletionPolicy: SyncDeletionPolicy.remoteDeleteWins,
          hasMapping: mappingByRemoteUid[uid] != null,
          remoteExists: remoteExists,
          localExists: localExists,
          remoteChanged: false,
          localChanged: false,
        );
        if (decision.action == SyncItemAction.deleteLocal) {
          localDeleteCandidates++;
        }
      }

      final bool allowMassDeletion = isMassDeletionOverrideEnabled(bindingId);
      final bool massDeletionSafetyTripped =
          localDeleteCandidates >= SyncStrategy.massDeletionAbsoluteThreshold;
      final bool blockDeletesBySafetyGate = massDeletionSafetyTripped && !allowMassDeletion;

      if (blockDeletesBySafetyGate) {
        summary.recordBindingOutcome(bindingId, SyncOutcomeStatus.safetyGateBlockedDeletions);
      }

      int createLocal = 0;
      int pull = 0;
      int deleteLocal = 0;
      int skip = 0;

      for (final uid in allUids) {
        final remote = remoteByUid[uid];
        final mapping = mappingByRemoteUid[uid];
        final PlatformItem? local = mapping != null
            ? localById[mapping['local_item_id']?.toString() ?? ''] ?? localByUid[uid]
            : localByUid[uid];

        final bool remoteExists = remote != null;
        final bool localExists = local != null || ((mapping?['local_item_id']?.toString() ?? '').isNotEmpty);
        final String remoteToken = normalizeRemoteToken(remote?['etag']);
        final String storedRemoteToken = normalizeRemoteToken(mapping?['last_etag']);
        final int localMtime = local?.lastModified ?? 0;
        final int storedLocalMtime = (mapping?['last_mtime'] as int?) ?? 0;
        final bool remoteChanged = remoteExists && (mapping == null || remoteToken != storedRemoteToken);
        final bool localChanged = local != null && (mapping == null || localMtime > storedLocalMtime);
        final int status = (mapping?['sync_status'] as int?) ?? SyncItemStatus.synced;

        final decision = resolveItemDecision(
          mode: SyncAction.fullSyncPull,
          bindingOrigin: origin,
          deletionPolicy: SyncDeletionPolicy.remoteDeleteWins,
          hasMapping: mapping != null,
          remoteExists: remoteExists,
          localExists: localExists,
          remoteChanged: remoteChanged,
          localChanged: localChanged,
        );

        debugPrint('[SYNC_ITEM][binding=$remoteCollectionId][uid=$uid] intent=${decision.intent} action=${decision.action} '
            'outcome=pending flags(remoteExists=$remoteExists localExists=$localExists remoteChanged=$remoteChanged localChanged=$localChanged reason=${decision.reason})');

        switch (decision.action) {
          case SyncItemAction.createLocal:
          case SyncItemAction.pull:
            final pulled = await pullRemoteEventToLocal(
              remote: remote!,
              localCalendarId: localCalendarId,
              existingLocalId: mapping?['local_item_id']?.toString(),
              isSubscription: ctx.isSubscription ?? false,
            );
            if (pulled == null) {
              skip++;
              continue;
            }
            await upsertSyncedItem(
              db: db,
              remoteCollectionId: remoteCollectionId,
              uid: pulled.uid,
              localItemId: pulled.localEventId,
              etag: remoteToken,
              lastMtime: localMtime > 0 ? localMtime : DateTime.now().millisecondsSinceEpoch,
              remoteHref: (remote['href'] ?? '').toString(),
              summary: pulled.summary,
            );
            if (decision.action == SyncItemAction.createLocal) {
              createLocal++;
              summary.telemetry?.onOperation(ctx: ctx, target: SyncOperationTarget.local, type: SyncOperationType.created);
            } else {
              pull++;
              summary.telemetry?.onOperation(ctx: ctx, target: SyncOperationTarget.local, type: SyncOperationType.updated);
            }
            break;
          case SyncItemAction.deleteLocal:
            if (!remoteSnapshotTrusted || !localSnapshotTrusted || blockDeletesBySafetyGate) {
              skip++;
              continue;
            }
            final String localId = mapping?['local_item_id']?.toString() ?? local?.localId?.toString() ?? '';
            if (localId.isNotEmpty) {
              await nativeApi.deleteEvent(localId);
            }
            await db.delete(
              'sync_items',
              where: 'remote_collection_id = ? AND remote_uid = ?',
              whereArgs: [remoteCollectionId, uid],
            );
            deleteLocal++;
            summary.telemetry?.onOperation(ctx: ctx, target: SyncOperationTarget.local, type: SyncOperationType.deleted);
            break;
          case SyncItemAction.skip:
          case SyncItemAction.deleteRemote:
          case SyncItemAction.push:
            if (mapping != null && remoteExists && status != SyncItemStatus.synced) {
              await db.update(
                'sync_items',
                {'sync_status': SyncItemStatus.synced},
                where: 'remote_collection_id = ? AND remote_uid = ?',
                whereArgs: [remoteCollectionId, uid],
              );
            }
            skip++;
            break;
        }
      }

      await db.update(
        'remote_collections',
        {'synced_ctag': newCtag},
        where: 'remote_path = ? AND account_name = ?',
        whereArgs: [remotePath, accountName],
      );

      debugPrint('[SYNC_SUMMARY][binding=$remoteCollectionId] createLocal=$createLocal pull=$pull deleteLocal=$deleteLocal skip=$skip '
          'localDeleteCandidates=$localDeleteCandidates safetyAborted=$blockDeletesBySafetyGate allowMassDeletion=$allowMassDeletion');

      if (!blockDeletesBySafetyGate) {
        summary.success++;
        summary.recordBindingOutcome(
          bindingId,
          allowMassDeletion ? SyncOutcomeStatus.persistentOverrideEnabled : SyncOutcomeStatus.completedNormally,
        );
        summary.telemetry?.onBindingEnd(
          ctx: ctx,
          status: SyncBindingResultStatus.success,
          snapshotTrustStatus: remoteSnapshotTrusted ? SnapshotTrustStatus.remote : SnapshotTrustStatus.unknown,
          safetyTriggered: false,
        );
      } else {
        summary.telemetry?.onBindingEnd(
          ctx: ctx,
          status: SyncBindingResultStatus.abortedBySafety,
          snapshotTrustStatus: remoteSnapshotTrusted ? SnapshotTrustStatus.remote : SnapshotTrustStatus.unknown,
          safetyTriggered: true,
          errorCode: SyncErrorCode.safetyStop,
          errorMessage: 'Safety gate blocked deletions',
        );
      }
    } catch (e) {
      summary.failed++;
      summary.errorLog.add('[ERROR] ${ctx.displayName} Read-only sync exception: $e');
      final code = mapSyncErrorCode(e);
      summary.telemetry?.onError(ctx: ctx, code: code, message: 'Pull sync failed', technicalDetail: e.toString());
      summary.telemetry?.onBindingEnd(
        ctx: ctx,
        status: SyncBindingResultStatus.failed,
        snapshotTrustStatus: SnapshotTrustStatus.unknown,
        safetyTriggered: false,
        errorCode: code,
        errorMessage: 'Pull sync failed',
        technicalDetail: e.toString(),
      );
    }
  }
}
