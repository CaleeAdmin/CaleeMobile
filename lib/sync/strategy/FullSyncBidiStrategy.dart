import 'package:caleesync/common/utils/UidGenerator.dart';
import 'package:caleesync/entity/SyncContext.dart';
import 'package:caleesync/entity/SyncSummary.dart';
import 'package:caleesync/sync/SyncEnum.dart';
import 'package:caleesync/sync/strategy/SyncStrategy.dart';
import 'package:flutter/cupertino.dart';
import 'package:sqflite/sqflite.dart';

import '../../common/utils/EventParsedUtils.dart';
import '../../core/platform/pigeon/calendar_api.g.dart';

class FullSyncBidiStrategy extends SyncStrategy {
  String _keyUid(PlatformItem e) {
    final u = (e.uid ?? '').trim();
    if (u.isNotEmpty) return u;
    return 'local_${e.localId}';
  }

  @override
  Future<void> execute(SyncContext ctx, SyncSummary summary) async {
    try {
      if (loginName == null ||
          loginName?.isEmpty == true ||
          password == null ||
          password?.isEmpty == true) {
        return;
      }
      final db = await dbHelper.database;
      final String localCalendarId = ctx.localCalendarId;
      final int remoteCollectionId = ctx.remoteCollectionId;
      final String remotePath = ctx.remotePath;

      final List<Map<String, dynamic>> remoteEvents = await nc.fetchUnifiedEvents(
        calendarPath: remotePath,
        isSubscription: ctx.isSubscription ?? false,
      );

      final List<Map<String, dynamic>> mappedRecords = await db.query(
        'sync_items',
        where: 'remote_collection_id = ?',
        whereArgs: [remoteCollectionId],
      );
      final Map<String, Map<String, dynamic>> syncMap = {
        for (var r in mappedRecords) r['remote_uid'].toString(): r
      };

      final start = DateTime.now().subtract(const Duration(days: 365)).millisecondsSinceEpoch;
      final end = DateTime.now().add(const Duration(days: 730)).millisecondsSinceEpoch;
      final items = await nativeApi.getEvents(localCalendarId, start, end);
      final Map<String, PlatformItem> localItemsMap = {
        for (var e in items.whereType<PlatformItem>()) _keyUid(e): e
      };

      final Set<String> processedUids = {};
      int changeCount = 0;

      for (var remote in remoteEvents) {
        final String uid = (remote['remote_uid'] ?? '').toString().trim();
        if (uid.isEmpty) continue;
        processedUids.add(uid);

        final String remoteEtag = (remote['etag'] ?? '').toString().replaceAll('"', '');
        final localBase = syncMap[uid];
        final localReal = localItemsMap[uid];

        final String localBaseEtag = (localBase?['last_etag'] ?? '').toString().replaceAll('"', '');
        bool cloudChanged = localBase == null || localBaseEtag != remoteEtag;
        bool localChanged = localReal != null &&
            (localBase == null || (localReal.lastModified ?? 0) > (localBase['last_mtime'] ?? 0));

        if (cloudChanged && localChanged) {
          debugPrint("⚠️ 冲突检测: $uid, 采用云端覆盖本地");
          await _pullFromRemote(remote, localCalendarId, remoteCollectionId, localBase?['local_item_id']?.toString(), remoteEtag, db);
          changeCount++;
        } else if (cloudChanged) {
          await _pullFromRemote(remote, localCalendarId, remoteCollectionId, localBase?['local_item_id']?.toString(), remoteEtag, db);
          changeCount++;
        } else if (localChanged) {
          await _pushToRemote(localReal, remotePath, db, localCalendarId, remoteCollectionId);
          changeCount++;
        }
      }

      for (var uid in syncMap.keys) {
        final record = syncMap[uid]!;
        final String? localId = record['local_item_id']?.toString();
        final String? href = record['remote_href'];
        final String? etag = record['last_etag'];

        final bool existsInRemote = processedUids.contains(uid);
        final bool existsInLocal = localItemsMap.containsKey(uid);

        if (existsInRemote) {
          if (!existsInLocal) {
            if (href != null && href.isNotEmpty) {
              debugPrint("🗑️ 检测到本地物理删除，同步清理云端: ${record['summary']}");
              final bool ok = await nc.deleteEvent(eventPath: href);
              if (ok) {
                await db.delete(
                  'sync_items',
                  where: 'remote_collection_id = ? AND remote_uid = ?',
                  whereArgs: [remoteCollectionId, uid],
                );
                changeCount++;
              }
            }
          }
        } else {
          if (existsInLocal) {
            if (etag == null || etag.isEmpty || record['sync_status'] == SyncItemStatus.pendingPush) {
              debugPrint("🚀 发现本地新增事件，准备上传: ${record['summary']}");
              await _pushToRemote(localItemsMap[uid]!, remotePath, db, localCalendarId, remoteCollectionId);
              changeCount++;
            } else {
              debugPrint("🧹 云端已删，同步清理本地实物: ${record['summary']}");
              if (localId != null && localId.isNotEmpty) {
                await nativeApi.deleteEvent(localId);
              }
              await db.delete(
                'sync_items',
                where: 'remote_collection_id = ? AND remote_uid = ?',
                whereArgs: [remoteCollectionId, uid],
              );
              changeCount++;
            }
          } else {
            await db.delete(
              'sync_items',
              where: 'remote_collection_id = ? AND remote_uid = ?',
              whereArgs: [remoteCollectionId, uid],
            );
          }
        }
      }

      for (var uid in localItemsMap.keys) {
        if (!processedUids.contains(uid) && !syncMap.containsKey(uid)) {
          debugPrint("🆕 发现纯本地新增(未记录)，准备上传: ${localItemsMap[uid]!.title}");
          await _pushToRemote(localItemsMap[uid]!, remotePath, db, localCalendarId, remoteCollectionId);
          changeCount++;
        }
      }

      summary.success++;
      summary.successLog.add("🔄 双向同步完成: ${ctx.displayName} (变动: $changeCount)");
    } catch (e) {
      summary.failed++;
      summary.errorLog.add("❌ ${ctx.displayName} 双向同步异常: $e");
    }
  }

  Future<void> _pullFromRemote(
    Map<String, dynamic> remote,
    String localCalendarId,
    int remoteCollectionId,
    String? localId,
    String etag,
    dynamic db,
  ) async {
    final eventData = await Eventparsedutils.resolveEventData(remote: remote, isSubscription: false);
    if (eventData == null) return;

    final String normalizedEtag = etag.replaceAll('"', '');

    final String? newSystemId = await nativeApi.createOrUpdateEvent(CalendarEventRequest(
      calendarId: localCalendarId,
      title: eventData.summary,
      start: eventData.dtstart,
      end: eventData.dtend,
      uid: eventData.uid,
      notes: eventData.description,
      eventId: localId,
    ));

    if (newSystemId != null) {
      await db.insert('sync_items', {
        'remote_uid': eventData.uid,
        'local_item_id': newSystemId,
        'remote_collection_id': remoteCollectionId,
        'last_etag': normalizedEtag,
        'last_mtime': DateTime.now().millisecondsSinceEpoch,
        'remote_href': remote['href'],
        'sync_status': SyncItemStatus.synced,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    }
  }

  Future<void> _pushToRemote(
    PlatformItem? local,
    String remotePath,
    dynamic db,
    String localCalendarId,
    int remoteCollectionId,
  ) async {
    if (local == null) return;

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
      final normalizedEtag = newEtag.replaceAll('"', '');
      await db.insert('sync_items', {
        'remote_uid': uid,
        'local_item_id': local.localId,
        'remote_collection_id': remoteCollectionId,
        'last_etag': normalizedEtag,
        'last_mtime': local.lastModified,
        'remote_href': "${remotePath.endsWith('/') ? remotePath : '$remotePath/'}$uid.ics",
        'sync_status': SyncItemStatus.synced,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    }
  }
}
