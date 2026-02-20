import 'package:caleesync/entity/SyncContext.dart';
import 'package:caleesync/entity/SyncSummary.dart';
import 'package:caleesync/sync/SyncEnum.dart';
import 'package:flutter/cupertino.dart';

import '../../entity/sync_run_record.dart';
import '../sync_run_recorder.dart';
import '../sync_run_telemetry.dart';

import 'SyncStrategy.dart';

class FullSyncPushStrategy extends SyncStrategy {
  @override
  Future<void> execute(SyncContext ctx, SyncSummary summary) async {
    if (loginName == null || loginName!.isEmpty || password == null || password!.isEmpty) return;

    try {
      final db = await dbHelper.database;
      final String remotePath = ctx.remotePath;
      final String localCalendarId = ctx.localCalendarId;
      final int remoteCollectionId = ctx.remoteCollectionId;
      final int bindingId = (ctx.extra['binding_id'] as int?) ?? 0;
      final int origin = (ctx.extra['binding_origin'] as int?) ?? SyncBindingOrigin.local;

      final localEvents = await loadLocalEvents(localCalendarId);
      final localByUid = mapLocalEventsByUid(localEvents);
      final localById = mapLocalEventsById(localEvents);

      final rawMapped = await db.query('sync_items', where: 'remote_collection_id = ?', whereArgs: [remoteCollectionId]);
      final mappedRecords = await repairDuplicateMappings(db, remoteCollectionId, rawMapped);
      final mappingByUid = {
        for (final row in mappedRecords)
          if ((row['remote_uid']?.toString() ?? '').isNotEmpty) row['remote_uid'].toString(): row,
      };

      final snapshot = await nc.fetchUnifiedEventsSnapshot(
        calendarPath: remotePath,
        isSubscription: ctx.isSubscription ?? false,
      );
      final remoteByUid = {
        for (final row in snapshot.events)
          if ((row['remote_uid']?.toString() ?? '').isNotEmpty) row['remote_uid'].toString(): row,
      };

      final Set<String> allUids = {...remoteByUid.keys, ...mappingByUid.keys, ...localByUid.keys};

      final bool suspiciousEmptyLocalFetch = localEvents.isEmpty && mappingByUid.isNotEmpty;
      final bool suspiciousEmptyRemoteFetch = snapshot.parseProducedZeroEvents && mappingByUid.isNotEmpty;
      final bool localSnapshotTrusted = !suspiciousEmptyLocalFetch;
      final bool remoteSnapshotTrusted =
          snapshot.fetchSucceeded && (snapshot.statusCode == 200 || snapshot.statusCode == 207) && !suspiciousEmptyRemoteFetch;

      int remoteDeleteCandidates = 0;
      for (final uid in allUids) {
        final remoteExists = remoteByUid[uid] != null;
        final localExists = localByUid[uid] != null || ((mappingByUid[uid]?['local_item_id']?.toString() ?? '').isNotEmpty);
        final decision = resolveItemDecision(
          mode: SyncAction.fullSyncPush,
          bindingOrigin: origin,
          deletionPolicy: SyncDeletionPolicy.bidirectional,
          hasMapping: mappingByUid[uid] != null,
          remoteExists: remoteExists,
          localExists: localExists,
          remoteChanged: false,
          localChanged: false,
        );
        if (decision.action == SyncItemAction.deleteRemote) {
          remoteDeleteCandidates++;
        }
      }

      final bool allowMassDeletion = isMassDeletionOverrideEnabled(bindingId);
      final bool blockDeletesBySafetyGate = remoteDeleteCandidates >= SyncStrategy.massDeletionAbsoluteThreshold && !allowMassDeletion;

      int createRemote = 0;
      int push = 0;
      int deleteRemote = 0;
      int skip = 0;

      for (final uid in allUids) {
        final remote = remoteByUid[uid];
        final mapping = mappingByUid[uid];
        PlatformItem? local = localByUid[uid];
        if (local == null) {
          final localId = mapping?['local_item_id']?.toString() ?? '';
          if (localId.isNotEmpty) local = localById[localId];
        }

        final bool remoteExists = remote != null;
        final bool localExists = local != null;
        final String remoteToken = normalizeRemoteToken(remote?['etag']);
        final String storedRemoteToken = normalizeRemoteToken(mapping?['last_etag']);
        final int localMtime = local?.lastModified ?? 0;
        final int storedMtime = (mapping?['last_mtime'] as int?) ?? 0;
        final int syncStatus = (mapping?['sync_status'] as int?) ?? SyncItemStatus.synced;
        final bool remoteChanged = remoteExists && (mapping == null || remoteToken != storedRemoteToken);
        final bool localChanged = localExists && (mapping == null || syncStatus == SyncItemStatus.pendingPush || localMtime > storedMtime);

        final decision = resolveItemDecision(
          mode: SyncAction.fullSyncPush,
          bindingOrigin: origin,
          deletionPolicy: SyncDeletionPolicy.bidirectional,
          hasMapping: mapping != null,
          remoteExists: remoteExists,
          localExists: localExists,
          remoteChanged: remoteChanged,
          localChanged: localChanged,
        );

        debugPrint('[SYNC_ITEM][binding=$remoteCollectionId][uid=$uid] intent=${decision.intent} action=${decision.action} outcome=pending '
            'flags(remoteExists=$remoteExists localExists=$localExists remoteChanged=$remoteChanged localChanged=$localChanged reason=${decision.reason})');

        switch (decision.action) {
          case SyncItemAction.push:
            if (local == null) {
              skip++;
              continue;
            }
            final pushed = await pushLocalEventToRemote(local: local, remotePath: remotePath, localCalendarId: localCalendarId);
            if (pushed == null) {
              skip++;
              continue;
            }
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
            if (mapping == null) {
              createRemote++;
              summary.telemetry?.onOperation(ctx: ctx, target: SyncOperationTarget.remote, type: SyncOperationType.created);
            } else {
              push++;
              summary.telemetry?.onOperation(ctx: ctx, target: SyncOperationTarget.remote, type: SyncOperationType.updated);
            }
            break;
          case SyncItemAction.deleteRemote:
            if (blockDeletesBySafetyGate || !localSnapshotTrusted || !remoteSnapshotTrusted) {
              skip++;
              continue;
            }
            final href = (mapping?['remote_href']?.toString() ?? remote?['href']?.toString() ?? '');
            if (href.isNotEmpty) {
              await nc.deleteEvent(eventPath: href);
            }
            await db.delete('sync_items', where: 'remote_collection_id = ? AND remote_uid = ?', whereArgs: [remoteCollectionId, uid]);
            deleteRemote++;
            summary.telemetry?.onOperation(ctx: ctx, target: SyncOperationTarget.remote, type: SyncOperationType.deleted);
            break;
          case SyncItemAction.skip:
          case SyncItemAction.createLocal:
          case SyncItemAction.pull:
          case SyncItemAction.deleteLocal:
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
          snapshotTrustStatus: remoteSnapshotTrusted ? SnapshotTrustStatus.remote : SnapshotTrustStatus.unknown,
          safetyTriggered: false,
        );
      } else {
        summary.recordBindingOutcome(bindingId, SyncOutcomeStatus.safetyGateBlockedDeletions);
        summary.telemetry?.onSafetyTriggered(ctx: ctx, detail: 'remoteDeleteCandidates=$remoteDeleteCandidates');
        summary.telemetry?.onBindingEnd(
          ctx: ctx,
          status: SyncBindingResultStatus.abortedBySafety,
          snapshotTrustStatus: remoteSnapshotTrusted ? SnapshotTrustStatus.remote : SnapshotTrustStatus.unknown,
          safetyTriggered: true,
          errorCode: SyncErrorCode.safetyStop,
          errorMessage: 'Safety gate blocked deletions',
        );
      }

      debugPrint('[SYNC_SUMMARY][binding=$remoteCollectionId] createRemote=$createRemote push=$push deleteRemote=$deleteRemote skip=$skip '
          'remoteDeleteCandidates=$remoteDeleteCandidates safetyAborted=$blockDeletesBySafetyGate allowMassDeletion=$allowMassDeletion');
    } catch (e) {
      summary.failed++;
      summary.errorLog.add('[ERROR] ${ctx.displayName} Publish failed: $e');
      final code = mapSyncErrorCode(e);
      summary.telemetry?.onError(ctx: ctx, code: code, message: 'Push sync failed', technicalDetail: e.toString());
      summary.telemetry?.onBindingEnd(
        ctx: ctx,
        status: SyncBindingResultStatus.failed,
        snapshotTrustStatus: SnapshotTrustStatus.unknown,
        safetyTriggered: false,
        errorCode: code,
        errorMessage: 'Push sync failed',
        technicalDetail: e.toString(),
      );
    }
  }
}
