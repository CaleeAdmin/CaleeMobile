import 'package:caleesync/entity/SyncContext.dart';
import 'package:caleesync/entity/SyncSummary.dart';
import 'package:caleesync/sync/strategy/SyncStrategy.dart';
import 'package:flutter/cupertino.dart';

class DeleteRemoteStrategy extends SyncStrategy {
  @override
  Future<void> execute(SyncContext ctx, SyncSummary summary) async{
    if (loginName == null ||
        loginName?.isEmpty == true
    ) {
      return;
    }
    // 1. 执行远程删除任务
    bool isRemoteDeleted = await nc.deleteRemoteCalendar(
      userId: loginName!,
      calendarPath: ctx.remotePath, // 确保 ctx 包含这个路径
    );

    if (isRemoteDeleted) {
      final db = await dbHelper.database;

      // 2. 开启事务进行本地“斩草除根”
      await db.transaction((txn) async {
        // A. 清理 sync_map (关联的事件映射)
        // 理由：日历都没了，它下面所有 ics 文件的 ETag 记录必须清空
        int sCount = await txn.delete(
          'sync_map',
          where: 'calendar_id = ? OR remote_path LIKE ?',
          whereArgs: [ctx.calendarId, '${ctx.remotePath}%'],
        );

        // B. 清理 calendar_map (日历自身配置)
        int cCount = await txn.delete(
          'calendar_map',
          where: 'id = ?',
          whereArgs: [ctx.calendarId],
        );
        debugPrint("🧹 云端删除成功，本地清理完成: 删除了 $cCount 个日历配置, $sCount 条同步映射");
      });
      // 3. 通知 UI 刷新 (如果是使用 GetX 或 Provider)
      // calendarController.removeItemFromUI(ctx.calendarId);
    } else {
      debugPrint("❌ 云端删除失败，停止清理本地数据库以防状态不一致");
    }
  }
  
}