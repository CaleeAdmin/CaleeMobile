import 'package:caleesync/entity/SyncContext.dart';
import 'package:caleesync/entity/SyncSummary.dart';
import 'package:caleesync/sync/SyncStrategy.dart';
import 'package:flutter/cupertino.dart';
import 'package:sqflite/sqflite.dart';

import '../core/platform/pigeon/calendar_api.g.dart';
import '../utils/TimeUtils.dart';

class Fullsyncpullstrategy extends SyncStrategy {
  @override
  Future<void> execute(SyncContext ctx, SyncSummary summary) async{
    final String localCalendarId = ctx.calendarId;
    final String remotePath = ctx.remotePath;
    final String? newCtag = ctx.ctag;
    final String accountName = ctx.accountName;

    if (localCalendarId.isEmpty) return;

    try {
      // 1. 获取远端最新全量数据
      final List<Map<String, dynamic>> remoteEvents = await nc.fetchUnifiedEvents(calendarPath: remotePath,
          isSubscription: ctx.isSubscription ?? false
      );
      final db = await dbHelper.database;

      // 2. 获取本地 sync_map 缓存
      final List<Map<String, dynamic>> localSyncRecords = await db.query(
        'sync_map',
        where: 'calendar_local_id = ?',
        whereArgs: [localCalendarId],
      );
      final Map<String, Map<String, dynamic>> localSyncMap = {
        for (var row in localSyncRecords) row['uid'] as String: row
      };

      final Set<String> remoteUids = {};

      // 3. 遍历远端，处理 新增/更新
      for (var remoteEvent in remoteEvents) {
        final String uid = remoteEvent['uid'];
        final String etag = remoteEvent['etag'];
        remoteUids.add(uid);

        final localRecord = localSyncMap[uid];

        // 只有 ETag 不一致时才触发原生操作
        if (localRecord == null || localRecord['last_etag'] != etag) {
          // 调用新增的 createOrUpdateEvent 接口
          // 如果 localRecord 为 null，eventId 传 null 触发原生 Insert
          final request = CalendarEventRequest(
            calendarId: localCalendarId.toString(),
            title: remoteEvent['summary'] ?? '无标题',
            start: Timeutils.parseToMillis(remoteEvent['start']),
            end: Timeutils.parseToMillis(remoteEvent['end']),
            notes: remoteEvent['description'] ?? "UID: $uid",
            uid: uid,
            // 关键：如果 localRecord 存在，则传入其 local_id 告诉原生端执行 Update
            eventId: localRecord?['local_id']?.toString(),
          );

          final String? systemEventId = await nativeApi.createOrUpdateEvent(
              request
          );

          if (systemEventId != null) {
            await db.insert('sync_map', {
              'uid': uid,
              'local_id': systemEventId,
              'calendar_local_id': localCalendarId,
              'summary': remoteEvent['summary'],
              'last_etag': etag,
              'remote_href': remoteEvent['href'],
              'sync_status': 0,
            }, conflictAlgorithm: ConflictAlgorithm.replace);
          }
        }
      }

      // 4. 处理 物理删除 (本地有但远端没了)
      for (var uid in localSyncMap.keys) {
        if (!remoteUids.contains(uid)) {
          final recordToDelete = localSyncMap[uid]!;
          final bool isDeleted = await nativeApi.deleteEvent(recordToDelete['local_id']);
          if (isDeleted) {
            await db.delete('sync_map', where: 'uid = ?', whereArgs: [uid]);
          }
        }
      }

      // 5. 更新日历 CTAG
      await db.update('calendar_map',
          {'last_ctag': newCtag, 'is_provisioned': 1},
          where: 'remote_path = ? AND account_name = ?',
          whereArgs: [remotePath, accountName]);

      debugPrint("✅ FullSyncPull 完成，CTAG 更新为: $newCtag");
    } catch (e) {
      debugPrint("❌ FullSyncPull 异常: $e");
    }
  }

}