import 'package:caleesync/entity/SyncContext.dart';
import 'package:caleesync/entity/SyncSummary.dart';
import 'package:flutter/cupertino.dart';

import 'SyncStrategy.dart';

class Deletedatabaseonlystrategy extends SyncStrategy {
  @override
  Future<void> execute(SyncContext ctx, SyncSummary summary) async {
    // 无需原生操作，直接从数据库抹除映射关系
    final db = await dbHelper.database;
    await db.delete(
      'calendar_map',
      where: 'remote_path = ? AND account_name = ?',
      whereArgs: [ctx.remotePath, ctx.accountName],
    );
    debugPrint("🧹 已从数据库彻底移除未落地的日历记录");
  }

}