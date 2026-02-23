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
        // A. 清理 sync_items（关联的事件映射）
        // 理由：日历都没了, 它下面所有 ics 文件的 ETag 记录必须清空
        int sCount = await txn.delete(
          'sync_items',
          where: 'remote_collection_id IN (SELECT remote_collection_id FROM local_bindings WHERE local_collection_id = ?)',
          whereArgs: [ctx.localCalendarId],
        );

        // B. 清理 local_bindings/remote_collections（日历自身配置）
        await txn.delete('local_bindings', where: 'local_collection_id = ?', whereArgs: [ctx.localCalendarId]);
        int cCount = await txn.delete(
          'remote_collections',
          where: 'id NOT IN (SELECT remote_collection_id FROM local_bindings)',
        );
        debugPrint("[INFO] Remote delete succeeded; local cleanup completed: deleted $cCount calendar configs, $sCount sync mappings");
      });
      // 3. 通知 UI 刷新 (如果是使用 GetX 或 Provider)
      // calendarController.removeItemFromUI(ctx.localCalendarId);
    } else {
      debugPrint("[ERROR] Remote delete failed; stopped local DB cleanup to avoid inconsistent state");
    }
  }
  
}