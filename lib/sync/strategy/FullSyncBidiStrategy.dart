import 'package:caleesync/entity/SyncContext.dart';
import 'package:caleesync/entity/SyncSummary.dart';
import 'package:caleesync/sync/SyncEnum.dart';
import 'package:caleesync/sync/strategy/SyncStrategy.dart';
import 'package:flutter/cupertino.dart';
import 'package:sqflite/sqflite.dart';

import '../../core/platform/pigeon/calendar_api.g.dart';
import '../../entity/sync_run_record.dart';
import '../sync_run_recorder.dart';
import '../sync_run_telemetry.dart';

class FullSyncBidiStrategy extends SyncStrategy {
  static const int _defaultDeletionPolicy = SyncDeletionPolicy.bidirectional;

  String _keyUid(PlatformItem e) {
    final u = (e.uid ?? '').trim();
    if (u.isNotEmpty) return u;
    return 'local_${e.localId}';
  }

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

      final snapshot = await nc.fetchUnifiedEventsSnapshot(
        calendarPath: remotePath,
        isSubscription: ctx.isSubscription ?? false,
      );
      final List<Map<String, dynamic>> remoteEvents = snapshot.events;

      final rawMapped = await db.query('sync_items', where: 'remote_collection_id = ?', whereArgs: [remoteCollectionId]);
      final mappedRecords = await repairDuplicateMappings(db, remoteCollectionId, rawMapped);

      final localEvents = await loadLocalEvents(localCalendarId);
      final Map<String, PlatformItem> localItemsMap = {for (final e in localEvents) _keyUid(e): e};

      final Map<String, Map<String, dynamic>> mappingByRemoteUid = {
        for (final r in mappedRecords)
          if ((r['remote_uid']?.toString() ?? '').isNotEmpty) r['remote_uid'].toString(): r,
      };
      final Map<String, Map<String, dynamic>> remoteByUid = {
        for (final r in remoteEvents)
          if ((r['remote_uid']?.toString() ?? '').isNotEmpty) r['remote_uid'].toString(): r,
      };

      final Set<String> allUids = {...remoteByUid.keys, ...mappingByRemoteUid.keys, ...localItemsMap.keys};

      final int mappedCount = mappingByRemoteUid.length;
      final bool suspiciousEmptyRemoteFetch = snapshot.parseProducedZeroEvents && mappedCount > 0;
      final bool suspiciousEmptyLocalFetch = localItemsMap.isEmpty && mappedCount > 0;
      final bool remoteSnapshotTrusted =
          snapshot.fetchSucceeded &&
          (snapshot.statusCode == 200 || snapshot.statusCode == 207) &&
          (newCtag ?? '').isNotEmpty &&
          !suspiciousEmptyRemoteFetch;
      final bool localSnapshotTrusted = !suspiciousEmptyLocalFetch;

      int localDeleteCandidates = 0;
      int remoteDeleteCandidates = 0;
      for (final uid in allUids) {
        final decision = resolveItemDecision(
          mode: SyncAction.fullSyncBidi,
          bindingOrigin: origin,
          deletionPolicy: _defaultDeletionPolicy,
          hasMapping: mappingByRemoteUid[uid] != null,
          remoteExists: remoteByUid[uid] != null,
          localExists: localItemsMap[uid] != null,
          remoteChanged: false,
          localChanged: false,
        );
        if (decision.action == SyncItemAction.deleteLocal) localDeleteCandidates++;
        if (decision.action == SyncItemAction.deleteRemote) remoteDeleteCandidates++;
      }

      final bool allowMassDeletion = isMassDeletionOverrideEnabled(bindingId);
      final bool massDeletionSafetyTripped =
          localDeleteCandidates >= SyncStrategy.massDeletionAbsoluteThreshold ||
          remoteDeleteCandidates >= SyncStrategy.massDeletionAbsoluteThreshold;
      final bool blockDeletesBySafetyGate = massDeletionSafetyTripped && !allowMassDeletion;

      int createLocal = 0;
      int createRemote = 0;
      int pull = 0;
      int push = 0;
      int deleteLocal = 0;
      int deleteRemote = 0;
      int skip = 0;

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

        final decision = resolveItemDecision(
          mode: SyncAction.fullSyncBidi,
          bindingOrigin: origin,
          deletionPolicy: _defaultDeletionPolicy,
          hasMapping: mapping != null,
          remoteExists: remoteExists,
          localExists: localExists,
          remoteChanged: remoteChanged,
          localChanged: localChanged,
        );

        debugPrint('[SYNC_ITEM][binding=$remoteCollectionId][uid=$uid] intent=${decision.intent} action=${decision.action} outcome=pending '
            'flags(remoteExists=$remoteExists localExists=$localExists remoteChanged=$remoteChanged localChanged=$localChanged origin=$origin reason=${decision.reason})');

        switch (decision.action) {
          case SyncItemAction.createLocal:
          case SyncItemAction.pull:
            await _pullFromRemote(remote!, localCalendarId, remoteCollectionId, mapping?['local_item_id']?.toString(), remoteToken, db);
            if (decision.action == SyncItemAction.createLocal) {
              createLocal++;
              summary.telemetry?.onOperation(ctx: ctx, target: SyncOperationTarget.local, type: SyncOperationType.created);
            } else {
              pull++;
              summary.telemetry?.onOperation(ctx: ctx, target: SyncOperationTarget.local, type: SyncOperationType.updated);
            }
            break;
          case SyncItemAction.push:
            await _pushToRemote(local!, remotePath, db, localCalendarId, remoteCollectionId);
            if (mapping == null) {
              createRemote++;
              summary.telemetry?.onOperation(ctx: ctx, target: SyncOperationTarget.remote, type: SyncOperationType.created);
            } else {
              push++;
              summary.telemetry?.onOperation(ctx: ctx, target: SyncOperationTarget.remote, type: SyncOperationType.updated);
            }
            break;
          case SyncItemAction.deleteLocal:
            if (blockDeletesBySafetyGate || !remoteSnapshotTrusted || !localSnapshotTrusted) {
              skip++;
              break;
            }
            final localId = mapping?['local_item_id']?.toString() ?? local?.localId?.toString() ?? '';
            if (localId.isNotEmpty) {
              await nativeApi.deleteEvent(localId);
            }
            await db.delete('sync_items', where: 'remote_collection_id = ? AND remote_uid = ?', whereArgs: [remoteCollectionId, uid]);
            deleteLocal++;
            summary.telemetry?.onOperation(ctx: ctx, target: SyncOperationTarget.local, type: SyncOperationType.deleted);
            break;
          case SyncItemAction.deleteRemote:
            if (blockDeletesBySafetyGate || !remoteSnapshotTrusted || !localSnapshotTrusted) {
              skip++;
              break;
            }
            final href = mapping?['remote_href']?.toString() ?? remote?['href']?.toString() ?? '';
            if (href.isNotEmpty) {
              await nc.deleteEvent(eventPath: href);
            }
            await db.delete('sync_items', where: 'remote_collection_id = ? AND remote_uid = ?', whereArgs: [remoteCollectionId, uid]);
            deleteRemote++;
            summary.telemetry?.onOperation(ctx: ctx, target: SyncOperationTarget.remote, type: SyncOperationType.deleted);
            break;
          case SyncItemAction.skip:
            if (mapping != null && remoteExists && status != SyncItemStatus.synced) {
              await db.update('sync_items', {'sync_status': SyncItemStatus.synced}, where: 'remote_collection_id = ? AND remote_uid = ?', whereArgs: [remoteCollectionId, uid]);
            }
            skip++;
            break;
        }
      }

      if (!blockDeletesBySafetyGate) {
        summary.success++;
        summary.recordBindingOutcome(
          bindingId,
          allowMassDeletion ? SyncOutcomeStatus.persistentOverrideEnabled : SyncOutcomeStatus.completedNormally,
        );
        summary.telemetry?.onBindingEnd(
          ctx: ctx,
          status: SyncBindingResultStatus.success,
          snapshotTrustStatus: (!remoteSnapshotTrusted || !localSnapshotTrusted) ? SnapshotTrustStatus.unknown : SnapshotTrustStatus.remote,
          safetyTriggered: false,
        );
      } else {
        summary.recordBindingOutcome(bindingId, SyncOutcomeStatus.safetyGateBlockedDeletions);
        summary.telemetry?.onSafetyTriggered(ctx: ctx, detail: 'localDeleteCandidates=$localDeleteCandidates remoteDeleteCandidates=$remoteDeleteCandidates');
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
          'remoteSnapshotTrusted=$remoteSnapshotTrusted localSnapshotTrusted=$localSnapshotTrusted '
          'localDeleteCandidates=$localDeleteCandidates remoteDeleteCandidates=$remoteDeleteCandidates safetyAborted=$blockDeletesBySafetyGate allowMassDeletion=$allowMassDeletion status=${snapshot.statusCode}');
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

  Future<void> _pullFromRemote(
    Map<String, dynamic> remote,
    String localCalendarId,
    int remoteCollectionId,
    String? existingLocalId,
    String remoteToken,
    Database db,
  ) async {
    final pulled = await pullRemoteEventToLocal(
      remote: remote,
      localCalendarId: localCalendarId,
      existingLocalId: existingLocalId,
      isSubscription: false,
    );
    if (pulled == null) return;
    await upsertSyncedItem(
      db: db,
      remoteCollectionId: remoteCollectionId,
      uid: pulled.uid,
      localItemId: pulled.localEventId,
      etag: remoteToken,
      lastMtime: DateTime.now().millisecondsSinceEpoch,
      remoteHref: (remote['href'] ?? '').toString(),
      summary: pulled.summary,
    );
  }

  Future<void> _pushToRemote(
    PlatformItem local,
    String remotePath,
    Database db,
    String localCalendarId,
    int remoteCollectionId,
  ) async {
    final pushed = await pushLocalEventToRemote(
      local: local,
      remotePath: remotePath,
      localCalendarId: localCalendarId,
    );
    if (pushed == null) return;
    await upsertSyncedItem(
      db: db,
      remoteCollectionId: remoteCollectionId,
      uid: pushed.uid,
      localItemId: local.localId.toString(),
      etag: pushed.etag,
      lastMtime: pushed.lastMtime,
      remoteHref: pushed.remoteHref,
      summary: local.title,
    );
  }
}
