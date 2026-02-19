import 'package:caleesync/entity/SyncContext.dart';
import 'package:caleesync/entity/SyncSummary.dart';
import 'package:caleesync/sync/SyncEnum.dart';
import 'package:caleesync/sync/strategy/SyncStrategy.dart';
import 'package:flutter/cupertino.dart';
import 'package:sqflite/sqflite.dart';

import '../../core/platform/pigeon/calendar_api.g.dart';
import '../../utils/TimeUtils.dart';

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
        for (var row in localSyncRecords) row['remote_uid'] as String: row
      };

      final Set<String> remoteUids = {};

      for (var remoteEvent in remoteEvents) {
        final String uid = (remoteEvent['remote_uid'] ?? '').toString().trim();
        if (uid.isEmpty) continue;
        final String etag = (remoteEvent['etag'] ?? '').toString().replaceAll('"', '');
        remoteUids.add(uid);

        final localRecord = localSyncMap[uid];
        final String localEtag = (localRecord?['last_etag'] ?? '').toString().replaceAll('"', '');

        if (localRecord == null || localEtag != etag) {
          final request = CalendarEventRequest(
            calendarId: localCalendarId,
            title: remoteEvent['summary'] ?? '无标题',
            start: Timeutils.parseToMillis(remoteEvent['start']),
            end: Timeutils.parseToMillis(remoteEvent['end']),
            notes: remoteEvent['description'] ?? "UID: $uid",
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
              'last_etag': etag,
              'remote_href': remoteEvent['href'],
              'sync_status': SyncItemStatus.synced,
            }, conflictAlgorithm: ConflictAlgorithm.replace);
          }
        }
      }

      for (var uid in localSyncMap.keys) {
        if (!remoteUids.contains(uid)) {
          final recordToDelete = localSyncMap[uid]!;
          final bool isDeleted = await nativeApi.deleteEvent(recordToDelete['local_item_id']);
          if (isDeleted) {
            await db.delete(
              'sync_items',
              where: 'remote_collection_id = ? AND remote_uid = ?',
              whereArgs: [remoteCollectionId, uid],
            );
          }
        }
      }

      await db.update(
        'remote_collections',
        {'synced_ctag': newCtag},
        where: 'remote_path = ? AND account_name = ?',
        whereArgs: [remotePath, accountName],
      );

      debugPrint("✅ FullSyncPull 完成，CTAG 更新为: $newCtag");
    } catch (e) {
      debugPrint("❌ FullSyncPull 异常: $e");
    }
  }
}
