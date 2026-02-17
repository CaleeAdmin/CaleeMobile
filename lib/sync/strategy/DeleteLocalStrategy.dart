import 'package:caleesync/entity/SyncContext.dart';
import 'package:caleesync/entity/SyncSummary.dart';
import 'package:flutter/cupertino.dart';

import 'SyncStrategy.dart';

class Deletelocalstrategy extends SyncStrategy {
  @override
  Future<void> execute(SyncContext ctx, SyncSummary summary) async {
    try {
      bool result = await nativeApi.deleteCalendar(ctx.calendarId, ctx.accountName);
      if(result){
        final db = await dbHelper.database;
        await db.transaction((txn) async {
          // 1. 删除关联的事件追踪 (sync_items)
          int sCount = await txn.delete(
              'sync_items',
              where: 'remote_collection_id = ?',
              whereArgs: [ctx.calendarId]
          );
          // 2. 删除日历自身的配置 (remote_collections)
          int cCount = await txn.delete(
              'remote_collections',
              where: 'local_id = ?',
              whereArgs: [ctx.calendarId]
          );
          debugPrint("🗑️ 数据库清理完毕: 删除了 $sCount 条事件, $cCount 条日历记录");
        });
      }
    }catch (e){
      debugPrint("❌ 删除本地日历失败: $e");
    }
  }

}