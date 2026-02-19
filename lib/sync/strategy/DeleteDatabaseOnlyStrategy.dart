import 'package:caleesync/entity/SyncContext.dart';
import 'package:caleesync/entity/SyncSummary.dart';
import 'package:flutter/cupertino.dart';

import 'SyncStrategy.dart';

class DeleteDatabaseOnlyStrategy extends SyncStrategy {
  @override
  Future<void> execute(SyncContext ctx, SyncSummary summary) async {
    final db = await dbHelper.database;
    await db.transaction((txn) async {
      final List<Map<String, dynamic>> rows = await txn.query(
        'remote_collections',
        columns: ['id'],
        where: 'remote_path = ? AND account_name = ?',
        whereArgs: [ctx.remotePath, ctx.accountName],
      );

      if (rows.isEmpty) {
        debugPrint('ℹ️ deleteDatabaseOnly: 无需处理，未找到对应远端集合记录。');
        return;
      }

      final List<int> remoteCollectionIds = rows
          .map((row) => row['id'])
          .whereType<int>()
          .toList();

      for (final remoteCollectionId in remoteCollectionIds) {
        await txn.delete(
          'sync_items',
          where: 'remote_collection_id = ?',
          whereArgs: [remoteCollectionId],
        );
        await txn.delete(
          'local_bindings',
          where: 'remote_collection_id = ?',
          whereArgs: [remoteCollectionId],
        );
      }

      await txn.delete(
        'remote_collections',
        where: 'id IN (${List.filled(remoteCollectionIds.length, '?').join(',')})',
        whereArgs: remoteCollectionIds,
      );
    });

    debugPrint('🧹 deleteDatabaseOnly: 已仅清理数据库映射，不触发本地/远端删除。');
  }
}
