import 'package:caleesync/entity/SyncContext.dart';
import 'package:caleesync/entity/SyncSummary.dart';
import 'package:flutter/cupertino.dart';
import 'package:sqflite/sqflite.dart';

import '../../core/platform/pigeon/calendar_api.g.dart';
import 'SyncStrategy.dart';


class FullSyncPushStrategy extends SyncStrategy {
  @override
  Future<void> execute(SyncContext ctx, SyncSummary summary) async {
    if (loginName == null ||
        loginName?.isEmpty == true ||
        password == null ||
        password?.isEmpty == true) {
      return;
    }
    try {
      final db = await dbHelper.database;
      final String remotePath = ctx.remotePath;

      // 1. 扫描本地系统日程 (建议范围：过去 1 年到未来 2 年)
      final start = DateTime.now().subtract(const Duration(days: 365)).millisecondsSinceEpoch;
      final end = DateTime.now().add(const Duration(days: 730)).millisecondsSinceEpoch;

      final List<PlatformItem?> items = await nativeApi.getEvents(ctx.calendarId, start, end);
      final List<PlatformItem> localEvents = items.whereType<PlatformItem>().toList();

      // 2. 获取本地已有的同步映射表
      final List<Map<String, dynamic>> mappedRecords = await db.query(
        'sync_items',
        where: 'remote_collection_id = ?',
        whereArgs: [ctx.calendarId],
      );

      // 转换为 Map 方便快速查找: {local_id: record}
      final Map<String, Map<String, dynamic>> localSyncMap = {
        for (var r in mappedRecords) r['local_id'].toString(): r
      };

      int changeCount = 0;

      // 3. 处理 [新增] 与 [更新]
      for (var local in localEvents) {
        final String localId = local.localId.toString();
        final String uid = local.uid ?? "";
        final int lastModified = local.lastModified ?? 0;

        bool needsPush = false;

        if (!localSyncMap.containsKey(localId)) {
          // A. 场景：本地有，映射表没有 -> 新增
          needsPush = true;
        } else {
          // B. 场景：本地有，映射表也有 -> 比对修改时间
          final record = localSyncMap[localId]!;
          // 如果系统最后的修改时间大于上次同步存的时间戳，则需要推送
          if (lastModified > (record['remote_mtime'] ?? 0)) {
            needsPush = true;
          }
        }

        if (needsPush) {
          final String? newEtag = await nc.uploadEventData(
            userId: loginName!,
            calendarPath: remotePath,
            uid: uid,
            title: local.title ?? "无标题",
            start: DateTime.fromMillisecondsSinceEpoch(local.startTime ?? 0),
            end: DateTime.fromMillisecondsSinceEpoch(local.endTime ?? 0),
          );

          if (newEtag != null) {
            // 更新映射表记录最新的 ETag 和修改时间
            await db.insert('sync_items', {
              'uid': uid,
              'local_id': localId,
              'remote_collection_id': ctx.calendarId,
              'summary': local.title,
              'remote_etag': newEtag.replaceAll('"', ''),
              'remote_mtime': lastModified,
              'remote_href': "${remotePath.endsWith('/') ? remotePath : '$remotePath/'}$uid.ics",
              'sync_status': 0,
            }, conflictAlgorithm: ConflictAlgorithm.replace);
            changeCount++;
          }
        }
      }

      // 4. 处理 [删除]：如果映射表里有，但系统日历里已经找不到了
      final Set<String> currentLocalIds = localEvents.map((e) => e.localId.toString()).toSet();

      for (var localId in localSyncMap.keys) {
        if (!currentLocalIds.contains(localId)) {
          // 在 FullSyncPushStrategy 的删除逻辑循环中
          final record = localSyncMap[localId]!;
          final String? href = record['remote_href']; // 数据库里存的路径

          if (href != null) {
            final bool isDeletedOnRemote = await nc.deleteEvent(eventPath: href);
            if (isDeletedOnRemote) {
              await db.delete('sync_items', where: 'local_id = ?', whereArgs: [localId]);
              changeCount++;
            }
          }
        }
      }

      summary.success++;
      summary.successLog.add("📤 发布同步完成: ${ctx.displayName} (处理了 $changeCount 项变动)");
    } catch (e) {
      summary.failed++;
      summary.errorLog.add("❌ ${ctx.displayName} 发布失败: $e");
    }
  }
}