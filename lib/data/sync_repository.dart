import 'package:caleesync/core/platform/pigeon/calendar_api.g.dart';
import 'package:sqflite/sqflite.dart';

import 'database_helper.dart';

class SyncRepository {
  final NativeCalendarApi _nativeApi = NativeCalendarApi();
  final DatabaseHelper _dbHelper = DatabaseHelper.instance;

// ==========================================
  // 1. 日历扫描
  // ==========================================
  Future<void> scanLocalCalendars(int accountId) async {
    final db = await _dbHelper.database;
    final List<PlatformCalendar?> localCalendars = await _nativeApi.getCalendars();

    await db.transaction((txn) async {
      for (var cal in localCalendars) {
        if (cal == null) continue;
        await txn.rawInsert('''
          INSERT INTO calendar_map (local_id, account_id, remote_path, display_name, sync_status)
          VALUES (?, ?, ?, ?, ?)
          ON CONFLICT(local_id) DO UPDATE SET display_name = excluded.display_name
        ''', [cal.id, accountId, '', cal.name, 1]);
      }
    });
  }

  // ==========================================
  // 2. 事件扫描 (已修正字段名为 calendar_local_id)
  // ==========================================
  Future<Map<String, int>> scanLocalEvents(String calendarLocalId) async {
    final db = await _dbHelper.database;
    int newlyAdded = 0;
    int modified = 0;

    final start = DateTime.now().subtract(const Duration(days: 45)).millisecondsSinceEpoch;
    final end = DateTime.now().add(const Duration(days: 45)).millisecondsSinceEpoch;

    final List<PlatformItem?> items = await _nativeApi.getItems(calendarLocalId, start, end);
    // 过滤掉任务，只留事件
    final events = items.where((i) => i != null && (i.isTask == false)).cast<PlatformItem>().toList();

    await db.transaction((txn) async {
      for (var event in events) {
        final List<Map<String, dynamic>> maps = await txn.query(
          'sync_map',
          where: 'uid = ?',
          whereArgs: [event.uid],
        );

        if (maps.isEmpty) {
          // ✅ 这里已修正为 calendar_local_id
          await txn.insert('sync_map', {
            'uid': event.uid,
            'local_id': event.localId,
            'calendar_local_id': calendarLocalId,
            'last_mtime': event.lastModified ?? DateTime.now().millisecondsSinceEpoch,
            'item_type': 'event',
            'sync_status': 1,
          });
          newlyAdded++;
        } else {
          final savedMtime = maps.first['last_mtime'] as int;
          final currentMtime = event.lastModified ?? 0;

          if (currentMtime > savedMtime) {
            await txn.update(
              'sync_map',
              {
                'last_mtime': currentMtime,
                'sync_status': 1,
              },
              where: 'uid = ?',
              whereArgs: [event.uid],
            );
            modified++;
          }
        }
      }
    });
    return {'added': newlyAdded, 'modified': modified};
  }

  // ==========================================
  // 3. 云端反馈更新 (Cloud Response Handling)
  // ==========================================

  /// 当 Push 成功后，更新云端返回的 ETag 和路径
  Future<void> updateAfterSuccessfulPush(String uid, String etag, String remoteHref) async {
    final db = await _dbHelper.database;
    await db.update(
      'sync_map',
      {
        'last_etag': etag,
        'remote_href': remoteHref,
        'sync_status': 0, // 0: 已同步，本地与云端一致
      },
      where: 'uid = ?',
      whereArgs: [uid],
    );
  }

// ==========================================
  // 3. 云端反馈更新
  // ==========================================

  Future<void> updateFromCloud(PlatformItem item, String etag, String href, String calendarId) async {
    final db = await _dbHelper.database;
    await db.insert(
      'sync_map',
      {
        'uid': item.uid,
        'local_id': item.localId,
        'calendar_id': calendarId, // 修正错误 2：由于 PlatformItem 可能没存 calendarId，我们作为参数传入
        'remote_href': href,
        'last_etag': etag,
        'last_mtime': item.lastModified ?? DateTime.now().millisecondsSinceEpoch,
        'item_type': 'event',
        'sync_status': 0,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  // ==========================================
  // 4. 数据提取 (For Sync Engine)
  // ==========================================

  /// 获取所有需要上传到 Nextcloud 的记录
  Future<List<Map<String, dynamic>>> getPendingUploads() async {
    final db = await _dbHelper.database;
    return await db.query(
      'sync_map',
      where: 'sync_status = ?',
      whereArgs: [1],
    );
  }
}