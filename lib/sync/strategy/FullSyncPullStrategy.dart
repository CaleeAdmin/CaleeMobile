import 'package:caleesync/entity/SyncContext.dart';
import 'package:caleesync/entity/SyncSummary.dart';
import 'package:caleesync/services/calee_server_service.dart';
import 'package:caleesync/sync/SyncEnum.dart';
import 'package:caleesync/sync/strategy/SyncStrategy.dart';
import 'package:flutter/cupertino.dart';

import '../../entity/sync_run_record.dart';
import '../sync_run_telemetry.dart';
import '../sync_run_recorder.dart';

import '../../core/platform/pigeon/calendar_api.g.dart';

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

    if (localCalendarId.isEmpty || remoteCollectionId <= 0) {
      return;
    }

    try {
      final UnifiedEventsSnapshot snapshot = await nc.fetchUnifiedEventsSnapshot(
        calendarPath: remotePath,
        isSubscription: ctx.isSubscription ?? false,
      );
      final List<Map<String, dynamic>> remoteEvents = snapshot.events;
      final db = await dbHelper.database;

      final List<Map<String, dynamic>> localSyncRecords = await db.query(
        'sync_items',
        where: 'remote_collection_id = ?',
        whereArgs: [remoteCollectionId],
      );
      final Map<String, Map<String, dynamic>> localSyncMap = {
        for (final row in localSyncRecords)
          if ((row['remote_uid']?.toString() ?? '').isNotEmpty) row['remote_uid'] as String: row,
      };

      final localEvents = await loadLocalEvents(localCalendarId);
      final Map<String, PlatformItem> localItemsByUid = mapLocalEventsByUid(localEvents);
      final Map<String, PlatformItem> localItemsById = mapLocalEventsById(localEvents);

      int createLocal = 0;
      int pull = 0;
      int deleteLocal = 0;
      int skip = 0;

      final Set<String> remoteUids = {};

      debugPrint('[SYNC_BINDING][binding_id=$bindingId] mode=pull origin=$origin '
          'deletionPolicy=two_phase_delete_local counts(remote=${remoteEvents.length}, local=${localItemsByUid.length}, mapped=${localSyncMap.length})');

      for (final remoteEvent in remoteEvents) {
        final String uid = (remoteEvent['remote_uid'] ?? '').toString().trim();
        if (uid.isEmpty) continue;

        remoteUids.add(uid);
        final localRecord = localSyncMap[uid];
        final PlatformItem? localItem = localRecord != null
            ? localItemsById[localRecord['local_item_id']?.toString() ?? '']
            : localItemsByUid[uid];

        final String remoteToken = normalizeRemoteToken(remoteEvent['etag']);
        final String storedRemoteToken = normalizeRemoteToken(localRecord?['last_etag']);
        final int localMtime = localItem?.lastModified ?? 0;
        final int storedLocalMtime = (localRecord?['last_mtime'] as int?) ?? 0;

        final bool remoteChanged = localRecord == null || storedRemoteToken != remoteToken;
        final bool localChanged = localItem != null && (localRecord == null || localMtime > storedLocalMtime);

        SyncItemAction action;
        String reason;

        if (localRecord == null || localItem == null) {
          action = SyncItemAction.createLocal;
          reason = 'remote_exists_local_missing';
        } else if (localChanged) {
          action = SyncItemAction.pull;
          reason = 'readonly_enforce_remote_overwrite_local_edit';
        } else if (remoteChanged) {
          action = SyncItemAction.pull;
          reason = 'remote_changed';
        } else {
          action = SyncItemAction.skip;
          reason = 'no_change';
        }

        debugPrint('[SYNC_ITEM][binding=$remoteCollectionId][uid=$uid] action=$action '
            'flags(remoteExists=true localExists=${localItem != null} remoteChanged=$remoteChanged localChanged=$localChanged reason=$reason)');

        if (action == SyncItemAction.createLocal || action == SyncItemAction.pull) {
          final RemotePullResult? pulled = await pullRemoteEventToLocal(
            remote: remoteEvent,
            localCalendarId: localCalendarId,
            existingLocalId: localRecord?['local_item_id']?.toString(),
            isSubscription: ctx.isSubscription ?? false,
          );

          if (pulled != null) {
            await upsertSyncedItem(
              db: db,
              remoteCollectionId: remoteCollectionId,
              uid: pulled.uid,
              localItemId: pulled.localEventId,
              etag: remoteToken,
              lastMtime: localItem?.lastModified ?? DateTime.now().millisecondsSinceEpoch,
              remoteHref: (remoteEvent['href'] ?? '').toString(),
              summary: pulled.summary,
            );
            if (action == SyncItemAction.createLocal) {
              createLocal++;
              summary.telemetry?.onOperation(ctx: ctx, target: SyncOperationTarget.local, type: SyncOperationType.created);
            } else {
              pull++;
              summary.telemetry?.onOperation(ctx: ctx, target: SyncOperationTarget.local, type: SyncOperationType.updated);
            }
          } else {
            skip++;
          }
        } else if (action == SyncItemAction.skip) {
          if (localRecord != null && status != SyncItemStatus.synced) {
            await db.update(
              'sync_items',
              {'sync_status': SyncItemStatus.synced},
              where: 'remote_collection_id = ? AND remote_uid = ?',
              whereArgs: [remoteCollectionId, uid],
            );
          }
          skip++;
        }
      }

      final int localCount = localItemsByUid.length;
      final int mappedCount = localSyncMap.length;
      final int remoteUidsMatchedCount = localSyncMap.keys.where(remoteUids.contains).length;
      final int localDeleteCandidates = mappedCount - remoteUidsMatchedCount;
      const int remoteDeleteCandidates = 0;
      final bool suspiciousEmptyRemoteFetch = snapshot.parseProducedZeroEvents && mappedCount > 0;
      final bool remoteSnapshotTrusted =
          snapshot.fetchSucceeded &&
          (snapshot.statusCode == 200 || snapshot.statusCode == 207) &&
          (newCtag ?? '').isNotEmpty &&
          !suspiciousEmptyRemoteFetch;
      final bool allowMassDeletion = isMassDeletionOverrideEnabled(bindingId);
      final bool massDeletionSafetyTripped =
          localDeleteCandidates >= SyncStrategy.massDeletionAbsoluteThreshold ||
          remoteDeleteCandidates >= SyncStrategy.massDeletionAbsoluteThreshold;
      final bool blockDeletesBySafetyGate = massDeletionSafetyTripped && !allowMassDeletion;
      final bool canFinalizeDeletes = remoteSnapshotTrusted && !blockDeletesBySafetyGate;

      if (!snapshot.fetchSucceeded) {
        debugPrint('[SYNC_SAFETY][binding_id=$bindingId][origin=$origin] untrusted remote snapshot: fetch failed');
      }
      if (!(snapshot.statusCode == 200 || snapshot.statusCode == 207)) {
        debugPrint('[SYNC_SAFETY][binding_id=$bindingId][origin=$origin] untrusted remote snapshot: bad status=${snapshot.statusCode}');
      }
      if (suspiciousEmptyRemoteFetch) {
        debugPrint('[SYNC_SAFETY][binding_id=$bindingId][origin=$origin] suspicious empty remote fetch, skip deletion (remote=${remoteEvents.length}, local=$localCount, mapped=$mappedCount)');
      }

      if (blockDeletesBySafetyGate) {
        debugPrint('[SYNC_SAFETY][binding_id=$bindingId][origin=$origin] aborted by safety gate '
            '(localDeleteCandidates=$localDeleteCandidates, remoteDeleteCandidates=$remoteDeleteCandidates, mappedCount=$mappedCount, threshold=${SyncStrategy.massDeletionAbsoluteThreshold})');
        summary.recordBindingOutcome(bindingId, SyncOutcomeStatus.safetyGateBlockedDeletions);
        summary.telemetry?.onSafetyTriggered(ctx: ctx, detail: 'localDeleteCandidates=$localDeleteCandidates remoteDeleteCandidates=$remoteDeleteCandidates');
        summary.errorLog.add('[ERROR] ${ctx.displayName} Safety gate blocked deletions (localDeleteCandidates=$localDeleteCandidates, remoteDeleteCandidates=$remoteDeleteCandidates, mappedCount=$mappedCount, threshold=${SyncStrategy.massDeletionAbsoluteThreshold})');
      }

      if (!remoteSnapshotTrusted) {
        debugPrint('[SYNC_SAFETY][binding_id=$bindingId][origin=$origin] untrusted snapshot; skip remote-missing delete staging/finalization '
            '(status=${snapshot.statusCode}, fetchSucceeded=${snapshot.fetchSucceeded}, parseZero=${snapshot.parseProducedZeroEvents}, localDeleteCandidates=$localDeleteCandidates)');
      }

      for (final uid in localSyncMap.keys) {
        if (!remoteSnapshotTrusted) break;
        if (remoteUids.contains(uid)) continue;
        if (blockDeletesBySafetyGate) continue;

        final record = localSyncMap[uid]!;
        if (!canFinalizeDeletes) {
          debugPrint('[SYNC_DELETE][binding=$remoteCollectionId][uid=$uid] blocked_by_finalize_guard');
          continue;
        }

        final String localItemId = record['local_item_id']?.toString() ?? '';
        if (localItemId.isEmpty) {
          await db.delete(
            'sync_items',
            where: 'remote_collection_id = ? AND remote_uid = ?',
            whereArgs: [remoteCollectionId, uid],
          );
          debugPrint('[SYNC_DELETE][binding=$remoteCollectionId][uid=$uid] local_deleted_immediately_reason=remote_missing_no_local_id');
          deleteLocal++;
          summary.telemetry?.onOperation(ctx: ctx, target: SyncOperationTarget.local, type: SyncOperationType.deleted);
          continue;
        }

        final bool deleted = await nativeApi.deleteEvent(localItemId);
        if (deleted) {
          await db.delete(
            'sync_items',
            where: 'remote_collection_id = ? AND remote_uid = ?',
            whereArgs: [remoteCollectionId, uid],
          );
          debugPrint('[SYNC_DELETE][binding=$remoteCollectionId][uid=$uid] local_deleted_immediately_reason=remote_missing');
          deleteLocal++;
          summary.telemetry?.onOperation(ctx: ctx, target: SyncOperationTarget.local, type: SyncOperationType.deleted);
        }
      }

      await db.update(
        'remote_collections',
        {'synced_ctag': newCtag},
        where: 'remote_path = ? AND account_name = ?',
        whereArgs: [remotePath, accountName],
      );

      debugPrint('[SYNC_SUMMARY][binding=$remoteCollectionId] createLocal=$createLocal pull=$pull deleteLocal=$deleteLocal skip=$skip '
          'localDeleteCandidates=$localDeleteCandidates remoteDeleteCandidates=$remoteDeleteCandidates safetyAborted=$blockDeletesBySafetyGate '
          'allowMassDeletion=$allowMassDeletion remoteSnapshotTrusted=$remoteSnapshotTrusted status=${snapshot.statusCode} fetchSucceeded=${snapshot.fetchSucceeded}');

      if (!blockDeletesBySafetyGate) {
        summary.success++;
        if (allowMassDeletion) {
          summary.recordBindingOutcome(bindingId, SyncOutcomeStatus.persistentOverrideEnabled);
          summary.successLog.add('[WARN] ${ctx.displayName} Persistent override enabled (dangerous mode)');
        } else {
          summary.recordBindingOutcome(bindingId, SyncOutcomeStatus.completedNormally);
          summary.successLog.add('[INFO] ${ctx.displayName} Completed normally');
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
      debugPrint('[ERROR] FullSyncPull exception: $e');
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
