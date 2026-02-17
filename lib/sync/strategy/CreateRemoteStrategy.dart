import 'package:caleesync/core/platform/pigeon/calendar_api.g.dart';
import 'package:caleesync/entity/SyncContext.dart';
import 'package:caleesync/entity/SyncSummary.dart';
import 'package:sqflite/sqflite.dart';

import 'SyncStrategy.dart';

class CreateRemoteStrategy extends SyncStrategy {
  @override
  Future<void> execute(SyncContext ctx, SyncSummary summary) async {
    if (loginName == null ||
        loginName?.isEmpty == true ||
        password == null ||
        password?.isEmpty == true) {
      return;
    }
    final String targetPathId = "calee_${DateTime.now().millisecondsSinceEpoch}";

    // 调用创建接口
    final resultPath = await nc.createRemoteCalendar(
      userId: loginName!,
      calendarName: ctx.displayName,
      calendarId: targetPathId,
      color: ctx.color, // 记得带上我们之前讨论的颜色
    );
    if (resultPath != null) {
      final db = await dbHelper.database;

      // 2. 扩大扫描窗口，确保存量数据全部覆盖
      // 首次上云：取过去 2 年到未来 10 年
      final start = DateTime.now()
          .subtract(const Duration(days: 30))
          .millisecondsSinceEpoch;
      final end = DateTime.now()
          .add(const Duration(days: 30))
          .millisecondsSinceEpoch;

      // 3. 抓取本地系统日程
      final String localCalendarProviderId = ctx.extra['local_id']?.toString() ?? '';
      if (localCalendarProviderId.isEmpty) return;

      final List<PlatformItem?> items = await nativeApi.getEvents(
        localCalendarProviderId,
        start,
        end,
      );
      final currentEvents = items.whereType<PlatformItem>().toList();

      print("[Sync] 正在为新日历推送 ${currentEvents.length} 条存量日程...");

      // 4. 遍历并执行 Initial Push (建议串行或限制并发)
      for (var event in currentEvents) {
        // 1. 提取并处理空值
        final String uid = event.uid ?? "";
        final String title = event.title ?? "无标题";
        final int startTime =
            event.startTime ?? DateTime.now().millisecondsSinceEpoch;
        final int endTime = event.endTime ?? startTime + 3600000; // 默认 1 小时后

        // 2. 执行上传
        final String? etag = await nc.uploadEventData(
          userId: loginName!,
          calendarPath: resultPath,
          uid: uid,
          // 现在是 String
          title: title,
          start: DateTime.fromMillisecondsSinceEpoch(startTime),
          // 现在是 int
          end: DateTime.fromMillisecondsSinceEpoch(endTime),
        );

        if (etag != null) {
          // 3. 写入 sync_map
          await db.insert('sync_map', {
            'uid': uid,
            'local_id': event.localId,
            'calendar_id': ctx.calendarId,
            'summary': title,
            'description': event.notes,
            'dtstart': startTime,
            'dtend': endTime,
            'last_etag': etag,
            'last_mtime': event.lastModified ?? 0,
            'remote_href':
                "${resultPath.endsWith('/') ? resultPath : '$resultPath/'}$uid.ics",
            'sync_status': 0,
          }, conflictAlgorithm: ConflictAlgorithm.replace);
        }
      }

      await db.update(
        'calendar_map',
        {
          'remote_path': resultPath, // 核心：存入刚开好的云端坑位路径
        },
        where: 'id = ?',
        whereArgs: [ctx.calendarId],
      );
      summary.success++;
    }
  }
}
