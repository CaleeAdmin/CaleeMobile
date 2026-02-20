import 'package:caleesync/entity/SyncContext.dart';
import 'package:caleesync/entity/SyncSummary.dart';
import 'package:caleesync/sync/SyncEnum.dart';
import 'package:flutter/cupertino.dart';

import '../../entity/sync_run_record.dart';
import '../sync_run_telemetry.dart';
import '../sync_run_recorder.dart';

import 'SyncStrategy.dart';

class FullSyncPushStrategy extends SyncStrategy {
  @override
  Future<void> execute(SyncContext ctx, SyncSummary summary) async {
    if (loginName == null || loginName!.isEmpty || password == null || password!.isEmpty) {
      return;
    }

    try {
      final db = await dbHelper.database;
      final String remotePath = ctx.remotePath;
      final String localCalendarId = ctx.localCalendarId;
      final int remoteCollectionId = ctx.remoteCollectionId;
      final int bindingId = (ctx.extra['binding_id'] as int?) ?? 0;

      final localEvents = await loadLocalEvents(localCalendarId);
      final List<Map<String, dynamic>> mappedRecords = await db.query(
        'sync_items',
        where: 'remote_collection_id = ?',
        whereArgs: [remoteCollectionId],
      );

      final snapshot = await nc.fetchUnifiedEventsSnapshot(
        calendarPath: remotePath,
        isSubscription: ctx.isSubscription ?? false,
      );

      final Map<String, Map<String, dynamic>> localSyncMap = {
        for (final record in mappedRecords) record['local_item_id'].toString(): record,
      };

      int changeCount = 0;
      for (final local in localEvents) {
        final String localId = local.localId.toString();
        final int lastModified = local.lastModified ?? 0;

        final Map<String, dynamic>? record = localSyncMap[localId];
        final int syncStatus = (record?['sync_status'] as int?) ?? SyncItemStatus.synced;
        final int recordMtime = (record?['last_mtime'] as int?) ?? 0;

        final bool needsPush =
            record == null || syncStatus == SyncItemStatus.pendingPush || lastModified > recordMtime;
        if (!needsPush) {
          continue;
        }

        final RemotePushResult? pushed = await pushLocalEventToRemote(
          local: local,
          remotePath: remotePath,
          localCalendarId: localCalendarId,
        );
        if (pushed == null) {
          continue;
        }

        await upsertSyncedItem(
          db: db,
          remoteCollectionId: remoteCollectionId,
          uid: pushed.uid,
          localItemId: localId,
          etag: pushed.etag,
          lastMtime: pushed.lastMtime,
          remoteHref: pushed.remoteHref,
          summary: local.title,
        );
        changeCount++;
        summary.telemetry?.onOperation(ctx: ctx, target: SyncOperationTarget.remote, type: SyncOperationType.updated);
      }

      final Set<String> currentLocalIds = localEvents.map((event) => event.localId.toString()).toSet();
      final int mappedCount = localSyncMap.length;
      final int remoteDeleteCandidates =
          localSyncMap.keys.where((id) => !currentLocalIds.contains(id)).length;
      const int localDeleteCandidates = 0;
      final bool suspiciousEmptyLocalFetch = localEvents.isEmpty && mappedCount > 0;
      final bool suspiciousEmptyRemoteFetch = snapshot.parseProducedZeroEvents && mappedCount > 0;
      final bool localSnapshotTrusted = !suspiciousEmptyLocalFetch;
      final bool remoteSnapshotTrusted =
          snapshot.fetchSucceeded &&
          (snapshot.statusCode == 200 || snapshot.statusCode == 207) &&
          !suspiciousEmptyRemoteFetch;
      final bool allowMassDeletion = isMassDeletionOverrideEnabled(bindingId);
      final bool massDeletionSafetyTripped =
          localDeleteCandidates >= SyncStrategy.massDeletionAbsoluteThreshold ||
          remoteDeleteCandidates >= SyncStrategy.massDeletionAbsoluteThreshold;
      final bool blockDeletesBySafetyGate = massDeletionSafetyTripped && !allowMassDeletion;

      if (blockDeletesBySafetyGate) {
        debugPrint('[SYNC_SAFETY][binding=$remoteCollectionId] aborted by safety gate '
            '(localDeleteCandidates=$localDeleteCandidates, remoteDeleteCandidates=$remoteDeleteCandidates, mappedCount=$mappedCount, threshold=${SyncStrategy.massDeletionAbsoluteThreshold})');
        summary.recordBindingOutcome(bindingId, SyncOutcomeStatus.safetyGateBlockedDeletions);
        summary.telemetry?.onSafetyTriggered(ctx: ctx, detail: 'remoteDeleteCandidates=$remoteDeleteCandidates');
        summary.errorLog.add('[ERROR] ${ctx.displayName} Safety gate blocked deletions (localDeleteCandidates=$localDeleteCandidates, remoteDeleteCandidates=$remoteDeleteCandidates, mappedCount=$mappedCount, threshold=${SyncStrategy.massDeletionAbsoluteThreshold})');
      }

      for (final localId in localSyncMap.keys) {
        if (currentLocalIds.contains(localId)) {
          continue;
        }

        final record = localSyncMap[localId]!;
        final String href = (record['remote_href'] ?? '').toString();
        final String uid = (record['remote_uid'] ?? '').toString();
        final int syncStatus = (record['sync_status'] as int?) ?? SyncItemStatus.synced;

        if (href.isEmpty || syncStatus != SyncItemStatus.pendingDelete) {
          continue;
        }
        if (blockDeletesBySafetyGate || !localSnapshotTrusted || !remoteSnapshotTrusted) {
          continue;
        }

        final bool isDeletedOnRemote = await nc.deleteEvent(eventPath: href);
        if (isDeletedOnRemote) {
          await db.delete(
            'sync_items',
            where: 'remote_collection_id = ? AND remote_uid = ?',
            whereArgs: [remoteCollectionId, uid],
          );
          changeCount++;
          summary.telemetry?.onOperation(ctx: ctx, target: SyncOperationTarget.remote, type: SyncOperationType.deleted);
        }
      }

      if (!blockDeletesBySafetyGate) {
        summary.success++;
        if (allowMassDeletion) {
          summary.recordBindingOutcome(bindingId, SyncOutcomeStatus.persistentOverrideEnabled);
          summary.successLog.add('[WARN] ${ctx.displayName} Persistent override enabled (dangerous mode)');
        } else {
          summary.recordBindingOutcome(bindingId, SyncOutcomeStatus.completedNormally);
          summary.successLog.add('[INFO] ${ctx.displayName} Completed normally (processed $changeCount changes)');
        }
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
