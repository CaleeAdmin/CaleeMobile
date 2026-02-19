import 'package:caleesync/entity/SyncContext.dart';
import 'package:caleesync/entity/SyncSummary.dart';
import 'package:caleesync/sync/SyncEnum.dart';
import 'package:caleesync/sync/strategy/SyncStrategy.dart';
import 'package:flutter/cupertino.dart';
import 'package:sqflite/sqflite.dart';

import '../../core/platform/pigeon/calendar_api.g.dart';
import '../../utils/TimeUtils.dart';

/// READ_ONLY strategy (remote is authoritative).
///
/// Per-item rules:
/// - remote exists + local missing => create local
/// - both exist + localChanged => overwrite local from remote
/// - both exist + remoteChanged => pull update
/// - remote missing + local mapped exists => delete local (read-only deletion policy)
class FullSyncPullStrategy extends SyncStrategy {
  @override
  Future<void> execute(SyncContext ctx, SyncSummary summary) async {
    final String localCalendarId = ctx.localCalendarId;
    final int remoteCollectionId = ctx.remoteCollectionId;
    final String remotePath = ctx.remotePath;
    final String? newCtag = ctx.ctag;
    final String accountName = ctx.accountName;

    if (localCalendarId.isEmpty || remoteCollectionId <= 0) return;

    try {
      final List<Map<String, dynamic>> remoteEvents = await nc.fetchUnifiedEvents(
        calendarPath: remotePath,
        isSubscription: ctx.isSubscription ?? false,
      );
      final db = await dbHelper.database;

      final List<Map<String, dynamic>> localSyncRecords = await db.query(
        'sync_items',
        where: 'remote_collection_id = ?',
        whereArgs: [remoteCollectionId],
      );
      final Map<String, Map<String, dynamic>> localSyncMap = {
        for (var row in localSyncRecords)
          if ((row['remote_uid']?.toString() ?? '').isNotEmpty) row['remote_uid'] as String: row
      };

      final start = DateTime.now().subtract(const Duration(days: 365)).millisecondsSinceEpoch;
      final end = DateTime.now().add(const Duration(days: 730)).millisecondsSinceEpoch;
      final items = await nativeApi.getEvents(localCalendarId, start, end);
      final Map<String, PlatformItem> localItemsByUid = {
        for (final item in items.whereType<PlatformItem>())
          if ((item.uid ?? '').trim().isNotEmpty) (item.uid ?? '').trim(): item
      };
      final Map<String, PlatformItem> localItemsById = {
        for (final item in items.whereType<PlatformItem>())
          if ((item.localId ?? '').isNotEmpty) (item.localId ?? ''): item
      };

      int createLocal = 0;
      int pull = 0;
      int deleteLocal = 0;
      int skip = 0;

      final Set<String> remoteUids = {};

      debugPrint('[SYNC_BINDING][id=$remoteCollectionId] mode=READ_ONLY origin=${SyncBindingOrigin.remote} '
          'deletionPolicy=delete_local counts(remote=${remoteEvents.length}, local=${localItemsByUid.length}, mapped=${localSyncMap.length})');

      // Evaluate per-item decision matrix for read-only bindings.
      for (var remoteEvent in remoteEvents) {
        final String uid = (remoteEvent['remote_uid'] ?? '').toString().trim();
        if (uid.isEmpty) continue;

        remoteUids.add(uid);
        final localRecord = localSyncMap[uid];
        final PlatformItem? localItem = localRecord != null
            ? localItemsById[localRecord['local_item_id']?.toString() ?? '']
            : localItemsByUid[uid];

        final String remoteToken = _normalizeToken(remoteEvent['etag']);
        final String storedRemoteToken = _normalizeToken(localRecord?['last_etag']);
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
          final request = CalendarEventRequest(
            calendarId: localCalendarId,
            title: remoteEvent['summary'] ?? '无标题',
            start: Timeutils.parseToMillis(remoteEvent['start']),
            end: Timeutils.parseToMillis(remoteEvent['end']),
            notes: remoteEvent['description'] ?? 'UID: $uid',
            uid: uid,
            eventId: localRecord?['local_item_id']?.toString(),
          );

          final String? systemEventId = await nativeApi.createOrUpdateEvent(request);
          if (systemEventId != null) {
            await db.insert('sync_items', {
              'remote_uid': uid,
              'local_item_id': systemEventId,
              'remote_collection_id': remoteCollectionId,
              'summary': remoteEvent['summary'],
              'last_etag': remoteToken,
              'last_mtime': DateTime.now().millisecondsSinceEpoch,
              'remote_href': remoteEvent['href'],
              'sync_status': SyncItemStatus.synced,
            }, conflictAlgorithm: ConflictAlgorithm.replace);
          }

          if (action == SyncItemAction.createLocal) {
            createLocal++;
          } else {
            pull++;
          }
        } else {
          skip++;
        }
      }

      for (var uid in localSyncMap.keys) {
        if (!remoteUids.contains(uid)) {
          final record = localSyncMap[uid]!;
          final bool deleted = await nativeApi.deleteEvent(record['local_item_id'].toString());
          if (deleted) {
            await db.delete('sync_items', where: 'remote_collection_id = ? AND remote_uid = ?', whereArgs: [remoteCollectionId, uid]);
            deleteLocal++;
          }
        }
      }

      await db.update(
        'remote_collections',
        {'synced_ctag': newCtag},
        where: 'remote_path = ? AND account_name = ?',
        whereArgs: [remotePath, accountName],
      );

      debugPrint('[SYNC_SUMMARY][binding=$remoteCollectionId] createLocal=$createLocal pull=$pull deleteLocal=$deleteLocal skip=$skip');
      summary.success++;
      summary.successLog.add('⬇️ 只读同步完成: ${ctx.displayName}');
    } catch (e) {
      debugPrint('❌ FullSyncPull 异常: $e');
      summary.failed++;
      summary.errorLog.add('❌ ${ctx.displayName} 只读同步异常: $e');
    }
  }

  String _normalizeToken(dynamic token) => (token ?? '').toString().replaceAll('"', '');
}
