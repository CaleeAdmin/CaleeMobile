import 'package:caleesync/entity/SyncContext.dart';

import 'package:caleesync/entity/SyncSummary.dart';
import 'package:flutter/cupertino.dart';
import 'package:sqflite/sqflite.dart';

import '../common/utils/EventParsedUtils.dart';
import '../core/platform/pigeon/calendar_api.g.dart';
import 'SyncStrategy.dart';

class CreateLocalStrategy extends SyncStrategy {
  @override
  Future<void> execute(SyncContext ctx, SyncSummary summary) async{
    if (loginName == null ||
        loginName?.isEmpty == true ||
        password == null ||
        password?.isEmpty == true) {
      return;
    }
    print('🚀 开始执行 createLocal: ${ctx.displayName}');

    // 1. 在 Android 系统侧创建日历
    final int colorValue = int.tryParse(ctx.color.replaceAll('#', '0x')) ?? 0xFF2196F3;
    final String? newLocalId = await nativeApi.createCalendar(
      ctx.displayName,
      loginName!,
      colorValue,
    );

    if (newLocalId == null) {
      print('❌ 原生创建日历失败');
      summary.failed++;
      return;
    }

    final db = await dbHelper.database;

    // 2. 关联本地 ID 并预设状态
    await db.update('calendar_map', {
      'local_id': newLocalId,
      'is_enabled': 1,
      'is_provisioned': 0,
    }, where: 'remote_path = ?', whereArgs: [ctx.remotePath]);

    try {
      // 3. 统一获取远端事件元数据
      final List<Map<String, dynamic>> remoteEvents = await nc.fetchUnifiedEvents(
        calendarPath: ctx.remotePath,
        isSubscription: ctx.isSubscription ?? false,
      );

      // 4. 加载本地 sync_map 缓存用于 Diff 比对
      final List<Map<String, dynamic>> localEntries = await db.query(
        'sync_map',
        where: 'calendar_local_id = ?',
        whereArgs: [newLocalId],
      );
      final Map<String, Map<String, dynamic>> localSyncMap = {
        for (var entry in localEntries) entry['uid'] as String: entry
      };

      int eventSuccessCount = 0;
      final _api = NativeCalendarApi(); // Pigeon API

      for (var remote in remoteEvents) {
        final String remoteUid = remote['uid'] ?? '';
        final String remoteEtag = (remote['etag'] ?? '').replaceAll('"', '');

        // 5. 差异比对：ETag 没变且本地已有系统 ID 则跳过
        if (localSyncMap.containsKey(remoteUid)) {
          final localEtag = localSyncMap[remoteUid]!['last_etag'];
          final localSystemId = localSyncMap[remoteUid]!['local_id'];
          if (localEtag == remoteEtag && localSystemId != null) {
            eventSuccessCount++;
            continue;
          }
        }

        // 6. 获取事件详情（内部兼容订阅/普通日历，解决 404 问题）
        final eventData = await Eventparsedutils.resolveEventData(
          remote: remote,
          isSubscription: ctx.isSubscription ?? false,
        );

        if (eventData == null) continue;

        // 7. 构建 Pigeon 请求对象
        final request = CalendarEventRequest(
          calendarId: newLocalId.toString(),
          title: eventData.summary,
          start: eventData.dtstart,
          end: eventData.dtend,
          notes: eventData.description,
          uid: eventData.uid,
          // 关键：传入已有的 local_id 则触发原生 Update
          eventId: localSyncMap[eventData.uid]?['local_id']?.toString(),
        );

        try {
          // 8. 调用原生 createOrUpdateEvent
          final String? systemEventId = await _api.createOrUpdateEvent(request);

          if (systemEventId != null) {
            // 9. 更新 sync_map 映射
            await db.insert('sync_map', {
              'uid': eventData.uid,
              'local_id': systemEventId,
              'calendar_local_id': newLocalId,
              'summary': eventData.summary,
              'last_etag': remoteEtag,
              'remote_href': eventData.href,
              'sync_status': 0,
              'dtstart': eventData.dtstart,
              'dtend': eventData.dtend,
            }, conflictAlgorithm: ConflictAlgorithm.replace);

            eventSuccessCount++;
          }
        } catch (e) {
          debugPrint("❌ 同步单条事件失败: $e");
        }
      }

      // 10. 标记初始拉取完成
      await db.update('calendar_map', {
        'is_provisioned': 1
      }, where: 'local_id = ?', whereArgs: [newLocalId]);

      print('✅ createLocal 完成: 已处理 $eventSuccessCount 个事件');
      summary.success++;
    } catch (e) {
      print('❌ createLocal 过程发生异常: $e');
      summary.failed++;
    }
  }
  
}