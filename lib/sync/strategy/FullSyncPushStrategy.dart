import 'package:caleesync/common/utils/UidGenerator.dart';
import 'package:caleesync/entity/SyncContext.dart';
import 'package:caleesync/entity/SyncSummary.dart';
import 'package:caleesync/sync/SyncEnum.dart';
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
      final String localCalendarId = ctx.localCalendarId;
      final int remoteCollectionId = ctx.remoteCollectionId;

      final start = DateTime.now().subtract(const Duration(days: 365)).millisecondsSinceEpoch;
      final end = DateTime.now().add(const Duration(days: 730)).millisecondsSinceEpoch;

      final List<PlatformItem?> items = await nativeApi.getEvents(localCalendarId, start, end);
      final List<PlatformItem> localEvents = items.whereType<PlatformItem>().toList();

      final List<Map<String, dynamic>> mappedRecords = await db.query(
        'sync_items',
        where: 'remote_collection_id = ?',
        whereArgs: [remoteCollectionId],
      );

      final Map<String, Map<String, dynamic>> localSyncMap = {
        for (var r in mappedRecords) r['local_item_id'].toString(): r
      };

      int changeCount = 0;

      for (var local in localEvents) {
        final String localId = local.localId.toString();
        final int lastModified = local.lastModified ?? 0;

        bool needsPush = false;

        if (!localSyncMap.containsKey(localId)) {
          needsPush = true;
        } else {
          final record = localSyncMap[localId]!;
          final int syncStatus = (record['sync_status'] as int?) ?? SyncItemStatus.synced;
          if (syncStatus == SyncItemStatus.pendingPush ||
              lastModified > (record['last_mtime'] ?? 0)) {
            needsPush = true;
          }
        }

        if (needsPush) {
          var uid = (local.uid ?? '').trim();
          if (uid.isEmpty) {
            uid = CaleeUid.generate();
            await nativeApi.createOrUpdateEvent(CalendarEventRequest(
              calendarId: localCalendarId,
              eventId: local.localId,
              uid: uid,
              title: local.title ?? "无标题",
              start: DateTime.fromMillisecondsSinceEpoch(local.startTime ?? 0).millisecondsSinceEpoch,
              end: DateTime.fromMillisecondsSinceEpoch(local.endTime ?? 0).millisecondsSinceEpoch,
              notes: local.notes,
            ));
          }

          final String? newEtag = await nc.uploadEventData(
            userId: loginName!,
            calendarPath: remotePath,
            uid: uid,
            title: local.title ?? "无标题",
            start: DateTime.fromMillisecondsSinceEpoch(local.startTime ?? 0),
            end: DateTime.fromMillisecondsSinceEpoch(local.endTime ?? 0),
          );

          if (newEtag != null) {
            await db.insert('sync_items', {
              'remote_uid': uid,
              'local_item_id': localId,
              'remote_collection_id': remoteCollectionId,
              'summary': local.title,
              'last_etag': newEtag.replaceAll('"', ''),
              'last_mtime': lastModified,
              'remote_href': "${remotePath.endsWith('/') ? remotePath : '$remotePath/'}$uid.ics",
              'sync_status': SyncItemStatus.synced,
            }, conflictAlgorithm: ConflictAlgorithm.replace);
            changeCount++;
          }
        }
      }

      final Set<String> currentLocalIds = localEvents.map((e) => e.localId.toString()).toSet();

      for (var localId in localSyncMap.keys) {
        if (!currentLocalIds.contains(localId)) {
          final record = localSyncMap[localId]!;
          final String? href = record['remote_href'];
          final String uid = (record['remote_uid'] ?? '').toString();
          final int syncStatus = (record['sync_status'] as int?) ?? SyncItemStatus.synced;

          if (href != null && syncStatus == SyncItemStatus.pendingDelete) {
            final bool isDeletedOnRemote = await nc.deleteEvent(eventPath: href);
            if (isDeletedOnRemote) {
              await db.delete(
                'sync_items',
                where: 'remote_collection_id = ? AND remote_uid = ?',
                whereArgs: [remoteCollectionId, uid],
              );
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
