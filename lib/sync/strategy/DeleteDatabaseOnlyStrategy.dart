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
        debugPrint('[INFO] deleteDatabaseOnly: No action needed; matching remote collection record not found.');
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
        await txn.delete(
          'collection_states',
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

    debugPrint('[INFO] deleteDatabaseOnly: Only DB mapping cleaned; no local/remote deletion triggered.');
  }
}
