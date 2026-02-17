import 'package:caleesync/entity/SyncContext.dart';
import 'package:caleesync/entity/SyncSummary.dart';
import 'package:caleesync/sync/strategy/SyncStrategy.dart';
import 'package:flutter/cupertino.dart';
import 'package:sqflite/sqflite.dart';

import '../../common/utils/EventParsedUtils.dart';
import '../../core/platform/pigeon/calendar_api.g.dart';

class FullSyncBidiStrategy extends SyncStrategy {
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
      final String localCalendarId = ctx.calendarId;
      final String remotePath = ctx.remotePath;

      // 1. 准备数据：获取云端列表与本地映射缓存
      final List<Map<String, dynamic>> remoteEvents = await nc.fetchUnifiedEvents(
        calendarPath: remotePath,
        isSubscription: ctx.isSubscription ?? false,
      );

      final List<Map<String, dynamic>> mappedRecords = await db.query(
        'sync_items',
        where: 'remote_collection_id = ?',
        whereArgs: [localCalendarId],
      );
      final Map<String, Map<String, dynamic>> syncMap = {
        for (var r in mappedRecords) r['uid'].toString(): r
      };

      // 2. 准备数据：获取本地系统实时日程
      final start = DateTime.now().subtract(const Duration(days: 365)).millisecondsSinceEpoch;
      final end = DateTime.now().add(const Duration(days: 730)).millisecondsSinceEpoch;
      final items = await nativeApi.getEvents(localCalendarId, start, end);
      final Map<String, PlatformItem> localItemsMap = {
        for (var e in items.whereType<PlatformItem>()) e.uid ?? '': e
      };

      final Set<String> processedUids = {};
      int changeCount = 0;

      // --- 阶段 A: 以云端列表为基准进行比对 ---
      for (var remote in remoteEvents) {
        final String uid = remote['uid'] ?? '';
        if (uid.isEmpty) continue;
        processedUids.add(uid);

        final String remoteEtag = (remote['etag'] ?? '').replaceAll('"', '');
        final localBase = syncMap[uid];
        final localReal = localItemsMap[uid];

        // 核心冲突判定逻辑
        bool cloudChanged = localBase == null || localBase['remote_etag'] != remoteEtag;
        bool localChanged = localReal != null &&
            (localBase == null || (localReal.lastModified ?? 0) > (localBase['remote_mtime'] ?? 0));

        if (cloudChanged && localChanged) {
          // 💡 场景：冲突！双方都改了。策略：以云端为准（或你可以根据 mtime 判定谁更晚）
          debugPrint("⚠️ 冲突检测: $uid, 采用云端覆盖本地");
          await _pullFromRemote(remote, localCalendarId, localBase?['local_item_id']?.toString(), remoteEtag, db);
          changeCount++;
        } else if (cloudChanged) {
          // 💡 场景：仅云端更新或新增 -> 下拉
          await _pullFromRemote(remote, localCalendarId, localBase?['local_item_id']?.toString(), remoteEtag, db);
          changeCount++;
        } else if (localChanged) {
          // 💡 场景：仅本地更新 -> 上传
          await _pushToRemote(localReal, remotePath, db, localCalendarId);
          changeCount++;
        }
      }

      // --- 阶段 B: 处理删除与本地新增 ---
      for (var uid in syncMap.keys) {
        final record = syncMap[uid]!;
        final String? localId = record['local_item_id']?.toString();
        final String? href = record['remote_href'];
        final String? etag = record['remote_etag'];

        final bool existsInRemote = processedUids.contains(uid);
        final bool existsInLocal = localItemsMap.containsKey(uid);

        if (existsInRemote) {
          // --- 场景：云端有这条记录 ---
          if (!existsInLocal) {
            // 💡 判定：本地删了！(账本有，云端有，但系统实物没了)
            // 动作：同步删除云端
            if (href != null && href.isNotEmpty) {
              debugPrint("🗑️ 检测到本地物理删除，同步清理云端: ${record['summary']}");
              final bool ok = await nc.deleteEvent(eventPath: href);
              if (ok) {
                await db.delete('sync_items', where: 'uid = ?', whereArgs: [uid]);
                changeCount++;
              }
            }
          }
        } else {
          // --- 场景：云端没有这条记录 ---
          if (existsInLocal) {
            // 💡 判定：这可能是个本地新增，或者云端把它删了
            if (etag == null || etag.isEmpty || record['sync_status'] == 1) {
              // A. 账本里没 Etag，说明是新来的 -> 上传
              debugPrint("🚀 发现本地新增事件，准备上传: ${record['summary']}");
              await _pushToRemote(localItemsMap[uid]!, remotePath, db, localCalendarId);
              changeCount++;
            } else {
              // B. 账本里有 Etag，说明以前同步过，但现在云端没了 -> 判定为云端删了
              debugPrint("🧹 云端已删，同步清理本地实物: ${record['summary']}");
              await nativeApi.deleteEvent(localId!);
              await db.delete('sync_items', where: 'uid = ?', whereArgs: [uid]);
              changeCount++;
            }
          } else {
            // C. 场景：两边都没了，只有账本残留
            await db.delete('sync_items', where: 'uid = ?', whereArgs: [uid]);
          }
        }
      }

// 最后扫一遍：处理那些“连账本(syncMap)都还没记录”的彻底新增
      for (var uid in localItemsMap.keys) {
        if (!processedUids.contains(uid) && !syncMap.containsKey(uid)) {
          debugPrint("🆕 发现纯本地新增(未记录)，准备上传: ${localItemsMap[uid]!.title}");
          await _pushToRemote(localItemsMap[uid]!, remotePath, db, localCalendarId);
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

  /// 辅助方法：从云端拉取并更新本地
  Future<void> _pullFromRemote(Map<String, dynamic> remote, String calendarId, String? localId, String etag, dynamic db) async {
    final eventData = await Eventparsedutils.resolveEventData(remote: remote, isSubscription: false);
    if (eventData == null) return;

    final String? newSystemId = await nativeApi.createOrUpdateEvent(CalendarEventRequest(
      calendarId: calendarId,
      title: eventData.summary,
      start: eventData.dtstart,
      end: eventData.dtend,
      uid: eventData.uid,
      notes: eventData.description,
      eventId: localId,
    ));

    if (newSystemId != null) {
      await db.insert('sync_items', {
        'uid': eventData.uid,
        'local_item_id': newSystemId,
        'remote_collection_id': calendarId,
        'remote_etag': etag,
        'remote_mtime': DateTime.now().millisecondsSinceEpoch, // 更新基准时间，避免刚拉下来又推上去
        'remote_href': remote['href'],
        'sync_status': 0,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    }
  }

  /// 辅助方法：将本地变更推送到云端
  Future<void> _pushToRemote(PlatformItem local, String remotePath, dynamic db, String calendarId) async {
    final String uid = local.uid ?? '';
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
        'uid': uid,
        'local_item_id': local.localId,
        'remote_collection_id': calendarId,
        'remote_etag': newEtag.replaceAll('"', ''),
        'remote_mtime': local.lastModified,
        'remote_href': "${remotePath.endsWith('/') ? remotePath : '$remotePath/'}$uid.ics",
        'sync_status': 0,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    }
  }
}