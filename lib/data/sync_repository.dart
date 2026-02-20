import 'dart:async';

import 'package:caleesync/common/app_constant.dart';
import 'package:caleesync/common/utils/mmkv_utils.dart';
import 'package:caleesync/core/platform/pigeon/calendar_api.g.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:sqflite/sqflite.dart';

import '../common/utils/IcsParser.dart';
import '../common/utils/UidGenerator.dart';
import '../entity/SyncSummary.dart';
import '../sync/SyncEnum.dart';
import '../sync/SyncEngine.dart';
import '../services/calee_server_service.dart';
import 'database_helper.dart';

class SyncRepository {
  final NativeCalendarApi _nativeApi = NativeCalendarApi();
  final DatabaseHelper _dbHelper = DatabaseHelper.instance;

  static final Map<String, Future<bool>> _connectFlights = <String, Future<bool>>{};
  String? _lastConnectError;

  String? takeLastConnectErrorMessage() {
    final String? message = _lastConnectError;
    _lastConnectError = null;
    return message;
  }



  Future<int?> _resolveRemoteCollectionIdByLocalCalendarId(DatabaseExecutor db, String localCalendarId) async {
    final rows = await db.rawQuery(
      """
      SELECT remote_collection_id
      FROM local_bindings
      WHERE local_collection_id = ?
      LIMIT 1
      """,
      [localCalendarId],
    );
    final Object? value = rows.isNotEmpty ? rows.first['remote_collection_id'] : null;
    if (value is int) return value;
    if (value is String) return int.tryParse(value);
    return null;
  }

  Future<Map<String, dynamic>?> _resolveCollectionConfigByLocalCalendarId(Database db, String localCalendarId) async {
    final rows = await db.rawQuery(
      """
      SELECT rc.id, rc.account_name, rc.remote_path, rc.is_subscription
      FROM remote_collections rc
      INNER JOIN local_bindings lb ON lb.remote_collection_id = rc.id
      WHERE lb.local_collection_id = ?
      LIMIT 1
      """,
      [localCalendarId],
    );
    if (rows.isEmpty) return null;
    return rows.first;
  }

// ==========================================
  // 1. 日历扫描
  // ==========================================
  Future<void> scanLocalCalendars(String accountId) async {
    // remote_collections 现在作为“远端中心”注册表使用：
    // 本地扫描仅用于触发原生侧读取, 不再向 remote_collections 写入任何本地日历。
    final List<PlatformCalendar?> calendars = await _nativeApi.getCalendars();

    // 扫描本地日历, 保持 remote-origin 绑定记录的更新时间。
    final db = await _dbHelper.database;
    await db.transaction((txn) async {
      for (final PlatformCalendar calendar in calendars.whereType<PlatformCalendar>()) {
        final String localId = calendar.id ?? '';
        if (localId.isEmpty) {
          continue;
        }

        await txn.update(
          'local_bindings',
          {
            'updated_at': DateTime.now().millisecondsSinceEpoch,
          },
          where: 'local_collection_id = ? AND binding_origin = 1',
          whereArgs: [localId],
        );
      }
    });
  }

  Future<void> refreshAllLocalEvents(String accountId) async {
    final db = await _dbHelper.database;

    // 1. 获取所有已绑定本地系统日历的远端集合
    final List<Map<String, dynamic>> activeCalendars = await db.rawQuery(
      '''
      SELECT rc.id AS remote_collection_id, lb.local_collection_id
      FROM remote_collections rc
      INNER JOIN local_bindings lb ON lb.remote_collection_id = rc.id
      WHERE rc.account_name = ?
        AND lb.local_collection_id IS NOT NULL
        AND lb.local_collection_id != ''
      ''',
      [accountId],
    );

    for (var cal in activeCalendars) {
      final int remoteCollectionId = cal['remote_collection_id'] as int;
      final String localCalId = cal['local_collection_id'].toString();

      // 2. 拍一张系统日历的“物理快照”
      final start = DateTime.now().subtract(const Duration(days: 365)).millisecondsSinceEpoch;
      final end = DateTime.now().add(const Duration(days: 730)).millisecondsSinceEpoch;
      final List<PlatformItem?> items = await _nativeApi.getEvents(localCalId, start, end);

      // 转换为 Map: { local_id : PlatformItem }
      final Map<String, PlatformItem> systemSnap = {
        for (var e in items.whereType<PlatformItem>()) e.localId.toString(): e
      };

      // 3. 获取该日历在数据库里的“旧记录”
      final List<Map<String, dynamic>> dbRecords = await db.query(
        'sync_items',
        where: 'remote_collection_id = ?',
        whereArgs: [remoteCollectionId],
      );
      final Map<String, Map<String, dynamic>> dbMap = {
        for (var r in dbRecords) r['local_item_id'].toString(): r
      };

      await db.transaction((txn) async {
        // --- 环节一：处理【修改】和【漏网之鱼】 ---
        for (var entry in systemSnap.entries) {
          final String sid = entry.key;
          final PlatformItem systemEvent = entry.value;
          final record = dbMap[sid];

          if (record == null) {
            // 💡 情况 A：系统有, 数据库没。这就是你说的【新增事件b】
            debugPrint("[INFO] Detected local physical addition: ${systemEvent.title}");
            await txn.insert('sync_items', {
              'remote_uid': (systemEvent.uid?.trim().isNotEmpty == true) ? systemEvent.uid!.trim() : 'local_${systemEvent.localId}',
              'local_item_id': sid,
              'remote_collection_id': remoteCollectionId,
              'summary': systemEvent.title,
              'last_mtime': systemEvent.lastModified,
              'sync_status': SyncItemStatus.pendingPush, // 标记为 Dirty, 待 Push
              'item_type': 'event'
            });
          } else {
            // 💡 情况 B：数据库有。对比修改时间戳, 这就是你说的【修改名称】
            final int systemMtime = systemEvent.lastModified ?? 0;
            final int dbMtime = record['last_mtime'] ?? 0;

            if (systemMtime > dbMtime) {
              debugPrint("[INFO] Detected local physical update: ${systemEvent.title}");
              await txn.update(
                'sync_items',
                {
                  'summary': systemEvent.title,
                  'last_mtime': systemMtime,
                  'sync_status': SyncItemStatus.pendingPush, // 标记为 Dirty, 待 Push
                },
                where: 'local_item_id = ?',
                whereArgs: [sid],
              );
            }
          }
        }

        // --- 环节二：处理【删除】 ---
        for (var record in dbRecords) {
          final String mappedId = record['local_item_id'].toString();
          if (!systemSnap.containsKey(mappedId)) {
            // 💡 情况 C：数据库有, 系统没了。说明用户在系统日历删了。
            debugPrint("[INFO] Detected local physical deletion: ${record['summary']}");
            await txn.update(
              'sync_items',
              {'sync_status': SyncItemStatus.pendingDelete}, // 标记为 Deleted, 待通知云端
              where: 'local_item_id = ?',
              whereArgs: [mappedId],
            );
          }
        }
      });
    }
  }

  // ==========================================
  // 2. 事件扫描 (已修正字段名为 remote_collection_id)
  // ==========================================
  Future<Map<String, int>> scanLocalEvents(String calendarLocalId) async {
    final db = await _dbHelper.database;
    int newlyAdded = 0;
    int modified = 0;
    int deleted = 0;

    final int? remoteCollectionId = await _resolveRemoteCollectionIdByLocalCalendarId(db, calendarLocalId);
    if (remoteCollectionId == null) {
      debugPrint('[WARN] Local calendar binding not found, skipping scanLocalEvents: $calendarLocalId');
      return {'added': 0, 'modified': 0, 'deleted': 0};
    }

    final start = DateTime.now().subtract(const Duration(days: 45)).millisecondsSinceEpoch;
    final end = DateTime.now().add(const Duration(days: 45)).millisecondsSinceEpoch;

    // 1. 获取系统当前存在的事件
    final List<PlatformItem?> items = await _nativeApi.getEvents(calendarLocalId, start, end);
    final currentEvents = items.where((i) => i != null && (i.isTask == false)).cast<PlatformItem>().toList();

    // 提取系统当前的 UID 集合
    final currentUids = currentEvents.map((e) => e.uid).toSet();

    await db.transaction((txn) async {
      // 2. 【核心逻辑】处理删除：找出数据库里有, 但系统里没了的记录
      // 注意：只处理状态不为 2 的, 避免重复处理
      final List<Map<String, dynamic>> dbRows = await txn.query(
        'sync_items',
        where: 'remote_collection_id = ? AND sync_status != ?',
        whereArgs: [remoteCollectionId, SyncItemStatus.pendingDelete],
      );

      for (var row in dbRows) {
        final String dbUid = row['remote_uid'];
        if (!currentUids.contains(dbUid)) {
          // 系统里找不到了 -> 用户在日历 App 里删了
          await txn.update(
            'sync_items',
            {'sync_status': SyncItemStatus.pendingDelete}, // 标记为“待同步删除”
            where: 'remote_collection_id = ? AND remote_uid = ?',
            whereArgs: [remoteCollectionId, dbUid],
          );
          deleted++;
          print('[INFO] Marked pending delete (soft delete): $dbUid');
        }
      }

      // 3. 处理新增或修改 (你原来的逻辑)
      for (var event in currentEvents) {
        // 核心改动：优先使用原生层返回的 event.uid (来自系统的 _SYNC_ID)
        final String eventUid = (event.uid != null && !event.uid!.startsWith('local_'))
            ? event.uid!
            : CaleeUid.generate();

        final List<Map<String, dynamic>> maps = await txn.query(
          'sync_items',
          where: 'remote_collection_id = ? AND remote_uid = ?',
          whereArgs: [remoteCollectionId, event.uid],
        );

        if (maps.isEmpty) {
          // 新增逻辑... (保持你原来的代码)
          await txn.insert('sync_items', {
            'remote_uid': eventUid,
            'local_item_id': event.localId,
            'remote_collection_id': remoteCollectionId,
            'summary': event.title ?? 'Untitled',
            'description': event.notes,
            'dtstart': event.startTime,
            'dtend': event.endTime,
            'last_mtime': event.lastModified ?? DateTime.now().millisecondsSinceEpoch,
            'item_type': 'event',
            'sync_status': SyncItemStatus.pendingPush,
          });
          newlyAdded++;
        } else {
          // 更新逻辑... (保持你原来的对比逻辑)
          // ... (省略你已有的 contentChanged 和 timeChanged 判断)
          // 如果检测到变化, 更新并将 sync_status 设为 1
        }
      }
    });

    return {'added': newlyAdded, 'modified': modified, 'deleted': deleted};
  }

  Future<void> pullFromRemote(String calendarLocalId) async {
    final db = await _dbHelper.database;

    // 1. [INFO] 动态获取日历配置（账号信息、远程路径等）
    final Map<String, dynamic>? calConfig = await _resolveCollectionConfigByLocalCalendarId(db, calendarLocalId);

    if (calConfig == null) {
      print("[ERROR] Calendar mapping config not found: $calendarLocalId");
      return;
    }

    final int? remoteCollectionId = calConfig['id'] as int?;
    if (remoteCollectionId == null) {
      print("[ERROR] Calendar mapping missing remote_collection_id: $calendarLocalId");
      return;
    }
    final String remotePath = calConfig['remote_path'] ?? "";
    final bool isSubscription =
        (calConfig['is_subscription'] == 1 || calConfig['is_subscription'] == true);
    // 这里的 userId 和 password 建议以后从账号管理模块获取, 目前先沿用你的 MMKV


    if (remotePath.isEmpty) {
      print("[WARN] Calendar is not bound to a remote path, skipping pull.");
      return;
    }

    print("[INFO] Preparing to pull from account [${calConfig['account_name']}] path: $remotePath");

    // 2. 获取云端所有事件
    final remoteEvents = await CaleeServerService().fetchUnifiedEvents(
      calendarPath: remotePath,
      isSubscription: isSubscription,
    );

    // --- 【删除逻辑】对比云端与本地 UID 集合 ---
    final Set<String> remoteUids = remoteEvents.map((e) {
      final String href = e['href'];
      return Uri.decodeComponent(href.split('/').last).replaceAll('.ics', '');
    }).toSet();

    final localEntries = await db.query(
        'sync_items',
        where: 'remote_collection_id = ?',
        whereArgs: [remoteCollectionId]
    );

    for (var local in localEntries) {
      final String uid = local['remote_uid'] as String;
      final String? localId = local['local_item_id'] as String?;
      final String summary = (local['summary'] ?? "Untitled") as String;

      // 如果本地标记为已同步(0)但云端没了, 说明云端删除了
      if (!remoteUids.contains(uid)) {
        if (local['sync_status'] == SyncItemStatus.synced) {
          print('[INFO] Deleted remotely, removing locally: $summary');
          if (localId != null) await _nativeApi.deleteEvent(localId);
          await db.delete('sync_items', where: 'remote_collection_id = ? AND remote_uid = ?', whereArgs: [remoteCollectionId, uid]);
        }
      }
    }

    // 3. 处理新增或更新
    for (var remoteEvent in remoteEvents) {
      final String href = remoteEvent['href'];
      final String uid = Uri.decodeComponent(href.split('/').last).replaceAll('.ics', '');
      final String etag = (remoteEvent['etag'] as String? ?? "").replaceAll('"', '');

      final local = await db.query('sync_items', where: 'remote_collection_id = ? AND remote_uid = ?', whereArgs: [remoteCollectionId, uid]);

      if (local.isNotEmpty) {
        final int currentStatus = local.first['sync_status'] as int;
        // 冲突处理：本地待删除但云端还在, 以云端为准重置
        if (currentStatus == SyncItemStatus.pendingDelete) {
          await db.delete('sync_items', where: 'remote_collection_id = ? AND remote_uid = ?', whereArgs: [remoteCollectionId, uid]);
        } else {
          final String localEtag = (local.first['last_etag'] as String?) ?? "";
          if (localEtag == etag) continue; // ETag 一致, 跳过
        }
      }

      // 4. [INFO] 下载详情并写入系统日历
      print('[INFO] Updating event details: $uid');
      final String icsData = (remoteEvent['calendar_data'] as String?) ?? '';
      if (icsData.trim().isEmpty) {
        print('[WARN] Skipping empty ICS data: $uid');
        continue;
      }

      final parsed = IcsParser.parse(icsData, uid);

        // [INFO] 核心改动：调用 createEvent 时传入云端的 UID
        // 这会让 Android 的 _SYNC_ID 字段被填充, 实现真正的 UUID 统一
      final String? newLocalId = await _nativeApi.createEvent(
        calendarLocalId,
        parsed['summary'] ?? "Untitled",
        parsed['dtstart'],
        parsed['dtend'],
        parsed['description'],
        uid, // <--- 关键参数：传入生成的/云端的 UID
      );

      if (newLocalId != null) {
        await db.insert('sync_items', {
          'remote_uid': uid,
          'local_item_id': newLocalId,
          'remote_collection_id': remoteCollectionId,
          'summary': parsed['summary'],
          'last_etag': etag,
          'sync_status': SyncItemStatus.synced,
          'item_type': 'event',
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }
    }
  }

  Future<void> pushDeletesToRemote(String calendarLocalId) async {
    final db = await _dbHelper.database;
    final String userId = MMKVUtils.instance.getString(AppConstant.loginNameKey) ?? "";
    final int? remoteCollectionId = await _resolveRemoteCollectionIdByLocalCalendarId(db, calendarLocalId);
    if (remoteCollectionId == null) {
      debugPrint('[WARN] Local calendar binding not found, skipping pushDeletesToRemote: $calendarLocalId');
      return;
    }

    // 1. 获取手机系统日历目前所有的 Event ID
    final List<String?> systemEventIds = await _nativeApi.getSystemEventIds(calendarLocalId);

    // 2. 找出那些在 sync_items 里有记录, 但系统里已经没了的
    final List<Map<String, dynamic>> trackedEvents = await db.query(
        'sync_items',
        where: 'remote_collection_id = ?',
        whereArgs: [remoteCollectionId]
    );

    for (var entry in trackedEvents) {
      final String localId = entry['local_item_id'];
      final String uid = entry['remote_uid'];

      if (!systemEventIds.contains(localId)) {
        print('[INFO] Detected manual local deletion, deleting remote copy: ${entry['summary']}');

        // 拼接云端路径 (如果是标准结构, 通常是 calendarPath + uid + .ics)
        final String eventPath = "/remote.php/dav/calendars/$userId/cal_sync_6/$uid.ics";

        final bool ok = await CaleeServerService().deleteEvent(
          eventPath: eventPath,
        );

        if (ok) {
          await db.delete('sync_items', where: 'remote_collection_id = ? AND remote_uid = ?', whereArgs: [remoteCollectionId, uid]);
        }
      }
    }
  }

  /// 统一的路径更新方法：用于将云端日历路径绑定到本地日历
  Future<void> updateRemotePath(String localId, String path) async {
    final db = await _dbHelper.database;

    // 确保路径不为 null
    final int? remoteCollectionId = await _resolveRemoteCollectionIdByLocalCalendarId(db, localId);
    if (remoteCollectionId == null) {
      print('[WARN] [Repository] Path binding failed: no local calendar binding for ID $localId ');
      return;
    }

    int count = await db.update(
      'remote_collections',
      {'remote_path': path},
      where: 'id = ?',
      whereArgs: [remoteCollectionId],
    );

    if (count > 0) {
      print('[OK] [Repository] Path binding succeeded: $localId -> $path');
    } else {
      print('[WARN] [Repository] Path binding failed: no local calendar for ID $localId');
    }
  }

  // ==========================================
  // 3. 云端反馈更新 (Cloud Response Handling)
  // ==========================================

  /// 当 Push 成功后, 更新云端返回的 ETag 和路径
  /// 当 Push 成功后, 同步本地状态
  Future<void> updateAfterSuccessfulPush(String uid, String etag, {String? remoteHref}) async {
    final db = await _dbHelper.database;

    // 构建更新 Map
    Map<String, dynamic> updateValues = {
      'last_etag': etag,
      'sync_status': SyncItemStatus.synced, // 0: 已同步, 本地与云端一致
      'last_mtime': DateTime.now().millisecondsSinceEpoch, // 更新本地记录的最后维护时间
    };

    // 如果提供了新的路径（比如首次创建）, 则更新
    if (remoteHref != null) {
      updateValues['remote_href'] = remoteHref;
    }

    await db.update(
      'sync_items',
      updateValues,
      where: 'remote_uid = ?',
      whereArgs: [uid],
    );
    print('[OK] Database synced: UID $uid, New ETag: $etag');
  }

  /// 将从云端同步下来的事件记录到本地数据库
  Future<void> saveSyncedEvent(String localId, dynamic remote) async {
    final db = await _dbHelper.database;

    // 从 remote 数据中提取信息（注意：remote 是我们在 SyncEngine 中定义的 map）
    final String uid = remote['remote_uid'] as String;
    // 去掉 ETag 的引号
    final String etag = (remote['etag'] as String).replaceAll('"', '');

    await db.insert(
      'sync_items',
      {
        'remote_uid': uid,
        'local_item_id': localId,
        'remote_collection_id': remote['remote_collection_id'], // 确保这个字段被传入
        'last_etag': etag,
        'sync_status': SyncItemStatus.synced,    // 0 表示已同步状态
        'item_type': 'event',
        'last_mtime': DateTime.now().millisecondsSinceEpoch,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    print('[OK] Remote event saved to local database: UID $uid');
  }

  /// 彻底删除一events：包括系统日历格子和本地数据库追踪记录
  Future<bool> deleteEventTotally(String localId, String uid) async {
    try {
      // 1. 调用 Pigeon 接口删除手机系统日历里的事件
      final bool systemOk = await _nativeApi.deleteEvent(localId);

      if (systemOk) {
        // 2. 删除本地数据库 sync_items 中的追踪记录
        final db = await _dbHelper.database;
        await db.delete(
          'sync_items',
          where: 'remote_uid = ?',
          whereArgs: [uid],
        );
        print('[OK] Hard delete succeeded: UID $uid');
        return true;
      } else {
        print('[ERROR] System calendar deletion failed: ID $localId');
        return false;
      }
    } catch (e) {
      print('[ERROR] Delete operation exception: $e');
      return false;
    }
  }

  Future<Map<String, dynamic>> getCalendarDetailData(String localId) async {
    final db = await DatabaseHelper.instance.database;

    // 1. 查询基础配置
    final List<Map<String, dynamic>> maps = await db.rawQuery(
      '''
      SELECT rc.*, lb.local_collection_id
      FROM remote_collections rc
      INNER JOIN local_bindings lb ON lb.remote_collection_id = rc.id
      WHERE lb.local_collection_id = ?
      LIMIT 1
      ''',
      [localId],
    );

    if (maps.isEmpty) return {};
    final cal = maps.first;

    // 2. Stats该日历下的本地有效事件数（过滤 status 2）
    final int? remoteCollectionId = cal['id'] as int?;
    final countResult = await db.rawQuery(
        'SELECT COUNT(*) as count FROM sync_items WHERE remote_collection_id = ? AND sync_status != ${SyncItemStatus.pendingDelete}',
        [remoteCollectionId ?? -1]
    );

    // 3. 逻辑判定：有远端路径视为云端来源
    final bool isCaleeNative = (cal['remote_path'] ?? '').toString().isNotEmpty;

    return {
      'title': cal['display_name'] ?? 'Primary Calendar',
      'source': isCaleeNative ? 'Calee' : 'System',
      'url': cal['remote_path'] ?? 'Not linked',
      'owner': cal['account_name'] ?? 'Unknown',
      'eventCount': countResult.first['count'] ?? 0,
      'isTwoWay': cal['remote_path'] != null && cal['remote_path'].toString().isNotEmpty,
    };
  }

  Future<void> updateCalendarLocalId(String oldId, String newId) async {
    final db = await DatabaseHelper.instance.database;

    await db.transaction((txn) async {
      // 1. 查找老记录（带有虚拟 ID 和可能已存在的 remote_path 的记录）
      final List<Map<String, dynamic>> oldRecords = await txn.query(
        'local_bindings',
        where: 'local_collection_id = ?',
        whereArgs: [oldId],
      );

      if (oldRecords.isEmpty) {
        print("[WARN] [ID sanitize] Old ID not found: $oldId, possibly already processed.");
        return;
      }

      final oldRecord = oldRecords.first;
      // 提取关键属性, 确保它们能带到新 ID 身上
      final int? remoteCollectionId = oldRecord['remote_collection_id'] as int?;

      // 2. 🌟 预清理冲突：如果新 ID (比如 '7') 已经存在记录（例如 scanLocalCalendars 扫出来的）
      // 我们先删除它, 因为我们要把“带路径”的老记录合并过去
      await txn.delete('local_bindings', where: 'local_collection_id = ?', whereArgs: [newId]);

      // 3. 执行核心洗白：将虚拟 ID 改为真实系统 ID
      final calendarUpdateCount = await txn.update(
        'local_bindings',
        {
          'local_collection_id': newId,
          'updated_at': DateTime.now().millisecondsSinceEpoch,
        },
        where: 'local_collection_id = ?',
        whereArgs: [oldId],
      );

      // 4. 更新事件关联的外键
      final eventUpdateCount = 0;

      print("[OK] [ID sanitize success] $oldId -> $newId");
      print("[INFO] Properties retained: RemoteCollectionId=$remoteCollectionId");
      print("[INFO] Stats: calendar updates($calendarUpdateCount), event FK updates($eventUpdateCount)");
    });
  }

  /// [INFO] 核心合并删除逻辑：物理销毁或解除绑定
  Future<void> performAbsoluteDelete({String? localId, String? remotePath}) async {
    final db = await _dbHelper.database;
    final String userId = MMKVUtils.instance.getString(AppConstant.loginNameKey) ?? "";

    final String? sanitizedLocalId = (localId != null && localId.isNotEmpty) ? localId : null;
    final String? sanitizedRemotePath = (remotePath != null && remotePath.isNotEmpty) ? remotePath : null;

    if (sanitizedLocalId == null && sanitizedRemotePath == null) {
      debugPrint("[WARN] [Delete] Empty input args, skipping delete");
      return;
    }

    // 1. 提取元数据（优先 local_id, 兜底 remote_path）
    final List<Map<String, dynamic>> maps = sanitizedLocalId != null
        ? await db.rawQuery(
            '''
            SELECT rc.*, lb.local_collection_id, lb.binding_origin
            FROM remote_collections rc
            INNER JOIN local_bindings lb ON lb.remote_collection_id = rc.id
            WHERE lb.local_collection_id = ?
            LIMIT 1
            ''',
            [sanitizedLocalId],
          )
        : await db.rawQuery(
            '''
            SELECT rc.*, lb.local_collection_id, lb.binding_origin
            FROM remote_collections rc
            LEFT JOIN local_bindings lb ON lb.remote_collection_id = rc.id
            WHERE rc.remote_path = ?
            LIMIT 1
            ''',
            [sanitizedRemotePath],
          );

    if (maps.isEmpty) {
      debugPrint("[WARN] [Delete] Calendar already absent in DB, no repeated action needed: local=$sanitizedLocalId remote=$sanitizedRemotePath");
      return;
    }

    final cal = maps.first;
    final String accountName = cal['account_name'] ?? '';
    final String resolvedLocalId = cal['local_collection_id']?.toString() ?? sanitizedLocalId ?? '';
    final String? resolvedRemotePath = cal['remote_path']?.toString() ?? sanitizedRemotePath;
    final int origin = cal['binding_origin'] ?? 0;
    final bool shouldDeleteLocalCalendar = origin == 1;

    debugPrint("[INFO] Starting hard delete workflow: ID $resolvedLocalId, Path: $resolvedRemotePath");

    try {
      await db.transaction((txn) async {
        // --- Step A: 云端删除 ---
        // 逻辑：只要有远端路径就先尝试删除云端；failed则回滚事务, 不删本地映射
        if (resolvedRemotePath != null && resolvedRemotePath.isNotEmpty) {
          final bool cloudOk = await CaleeServerService().deleteRemoteCalendar(
            userId: userId,
            calendarPath: resolvedRemotePath,
          );
          if (!cloudOk) {
            throw Exception('Failed to delete remote calendar; aborting local mapping deletion');
          }
          debugPrint("[OK] Remote deletion succeeded");
        }

        // --- Step B: 本地系统层删除 ---
        // origin == 0: 日历由本地初始化, 只清理云端；保留本地系统日历
        // origin == 1: 日历由云端初始化, 按顺序先删云端, 再删本地系统日历
        if (shouldDeleteLocalCalendar && resolvedLocalId.isNotEmpty) {
          final bool localOk = await _nativeApi.deleteCalendar(resolvedLocalId, accountName);
          if (!localOk) {
            throw Exception('Failed to delete local system calendar; aborting local mapping deletion');
          }
          debugPrint("[OK] Mobile system calendar removed");
        } else if (!shouldDeleteLocalCalendar) {
          debugPrint("[INFO] Calendar originated locally, skipping local system calendar deletion");
        }

        // --- Step C: 物理删除成功后, 清理数据库 ---
        int sCount = 0;
        final int? resolvedRemoteCollectionId = cal['id'] as int?;
        if (resolvedRemoteCollectionId != null) {
          sCount = await txn.delete(
            'sync_items',
            where: 'remote_collection_id = ?',
            whereArgs: [resolvedRemoteCollectionId],
          );
        }

        if (resolvedLocalId.isNotEmpty) {
          await txn.delete(
            'local_bindings',
            where: 'local_collection_id = ?',
            whereArgs: [resolvedLocalId],
          );
        }

        final int cCount = await txn.delete(
          'remote_collections',
          where: 'id = ?',
          whereArgs: [resolvedRemoteCollectionId],
        );

        debugPrint("[INFO] Database cleanup finished: deleted $sCount events, $cCount calendar records");
      });
    } catch (e) {
      debugPrint("[WARN] Calendar deletion incomplete; retained remote_collections/sync_items: $e");
      rethrow;
    }
  }

  Future<void> renameCalendar({
    String? localId,
    String? remotePath,
    required String newName,
  }) async {
    final db = await _dbHelper.database;

    final String? sanitizedLocalId = (localId != null && localId.trim().isNotEmpty && localId.trim().toLowerCase() != 'null')
        ? localId.trim()
        : null;
    final String? sanitizedRemotePath = (remotePath != null && remotePath.trim().isNotEmpty && remotePath.trim().toLowerCase() != 'null')
        ? remotePath.trim()
        : null;

    if (sanitizedLocalId == null && sanitizedRemotePath == null) {
      throw Exception('Missing calendar identifier; unable to rename');
    }

    // 1. 获取当前日历元数据（优先 local_id, 兜底 remote_path）
    List<Map<String, dynamic>> maps = [];
    if (sanitizedLocalId != null) {
      maps = await db.rawQuery(
        '''
        SELECT rc.*, lb.local_collection_id
        FROM remote_collections rc
        INNER JOIN local_bindings lb ON lb.remote_collection_id = rc.id
        WHERE lb.local_collection_id = ?
        LIMIT 1
        ''',
        [sanitizedLocalId],
      );
    }

    if (maps.isEmpty && sanitizedRemotePath != null) {
      maps = await db.rawQuery(
        '''
        SELECT rc.*, lb.local_collection_id
        FROM remote_collections rc
        LEFT JOIN local_bindings lb ON lb.remote_collection_id = rc.id
        WHERE rc.remote_path = ?
        LIMIT 1
        ''',
        [sanitizedRemotePath],
      );
    }

    if (maps.isEmpty) {
      throw Exception('Target calendar record not found');
    }
    final cal = maps.first;
// 如果字段可能为空, 用 String?
    final String? path = cal['remote_path'] as String?;

// 如果你确定 account_name 绝对有值, 用 String
    final String userId = cal['account_name'] as String;
    try {
      // 2. 先改云端 (如果failed, 建议直接抛exception, 不改本地)
      if (path != null) {
        bool isCloudOk = await CaleeServerService().renameRemoteCalendar(
            userId: userId,
            calendarPath: path,
            newName: newName
        );
        if (!isCloudOk) throw Exception("Remote rename failed");
      }

      // 3. 修改手机系统日历 (Android/iOS 系统层)
      // 仅当存在 local_id 时尝试系统改名
      final String? resolvedLocalId = cal['local_collection_id']?.toString();
      if (resolvedLocalId != null && resolvedLocalId.isNotEmpty) {
        final bool localRenameOk = await _nativeApi.modifyCalendarTitle(
          resolvedLocalId,
          newName,
          userId,
          'com.viso.caleesync',
        );
        if (!localRenameOk) {
          throw Exception('System calendar rename failed');
        }
      }

      // 4. 修改本地数据库记录
      if (resolvedLocalId != null && resolvedLocalId.isNotEmpty) {
        await db.update(
          'remote_collections',
          {'display_name': newName},
          where: 'id = ?',
          whereArgs: [cal['id']],
        );
      } else {
        await db.update(
          'remote_collections',
          {'display_name': newName},
          where: 'remote_path = ?',
          whereArgs: [path],
        );
      }

      print("[OK] Calendar ${resolvedLocalId ?? path} renamed across all three sides to: $newName");

    } catch (e) {
      print("[ERROR] Rename workflow interrupted: $e");
      rethrow;
    }
  }


  Future<bool> connectAndEnableRemoteCalendarByPath(String remotePath) async {
    final String trimmedRemotePath = CaleeServerService.normalizeRemotePath(remotePath);
    if (trimmedRemotePath.isEmpty) {
      _lastConnectError = 'Invalid remote path. Please refresh and try again.';
      return false;
    }

    final Future<bool>? inFlight = _connectFlights[trimmedRemotePath];
    if (inFlight != null) {
      return inFlight;
    }

    final Future<bool> task = _provisionAndEnableRemoteCalendarByPath(trimmedRemotePath);
    _connectFlights[trimmedRemotePath] = task;
    try {
      return await task;
    } finally {
      _connectFlights.remove(trimmedRemotePath);
    }
  }

  Future<bool> _provisionAndEnableRemoteCalendarByPath(String remotePath) async {
    _lastConnectError = null;
    remotePath = CaleeServerService.normalizeRemotePath(remotePath);
    final String loginName = MMKVUtils.instance.getString(AppConstant.loginNameKey) ?? '';
    if (loginName.isEmpty) {
      _lastConnectError = 'Session expired. Please sign in again and retry.';
      return false;
    }

    final db = await _dbHelper.database;
    String? createdLocalIdForEnableAttempt;
    int bindingOriginForEnableAttempt = SyncBindingOrigin.remote;

    try {
      final List<Map<String, dynamic>> remoteRows = await db.query(
        'remote_collections',
        columns: ['id', 'display_name', 'color', 'remote_path'],
        where: 'account_name = ? AND collection_type = ? AND remote_path = ?',
        whereArgs: [loginName, 'calendar', remotePath],
        limit: 1,
      );

      if (remoteRows.isEmpty) {
        _lastConnectError = 'Remote calendar not found. Pull to refresh and try again.';
        return false;
      }

      final Map<String, dynamic> remote = remoteRows.first;
      final int remoteCollectionId = remote['id'] as int;
      final String persistedRemotePath =
          CaleeServerService.normalizeRemotePath((remote['remote_path'] ?? '').toString());
      if (persistedRemotePath.isEmpty) {
        _lastConnectError = 'Invalid remote calendar path. Please refresh and try again.';
        return false;
      }

      final String displayName = (remote['display_name']?.toString().isNotEmpty ?? false)
          ? remote['display_name'].toString()
          : 'Untitled calendar';

      final List<Map<String, dynamic>> bindingRows = await db.query(
        'local_bindings',
        columns: ['id', 'local_collection_id', 'binding_origin'],
        where: 'remote_collection_id = ?',
        whereArgs: [remoteCollectionId],
        limit: 1,
      );

      final String existingLocalId = bindingRows.isNotEmpty
          ? (bindingRows.first['local_collection_id']?.toString() ?? '')
          : '';
      final int existingBindingOrigin = bindingRows.isNotEmpty
          ? ((bindingRows.first['binding_origin'] as int?) ?? SyncBindingOrigin.remote)
          : SyncBindingOrigin.remote;
      bindingOriginForEnableAttempt = existingBindingOrigin;

      final Set<String> nativeCalendarIds = (await _nativeApi.getCalendars())
          .whereType<PlatformCalendar>()
          .map((calendar) => calendar.id ?? '')
          .where((id) => id.isNotEmpty)
          .toSet();

      if (existingLocalId.isNotEmpty && nativeCalendarIds.contains(existingLocalId)) {
        await db.update(
          'remote_collections',
          {'is_enabled': 1},
          where: 'id = ?',
          whereArgs: [remoteCollectionId],
        );
        _triggerOneShotForceSyncInBackground(remoteCollectionId);
        return true;
      }

      int colorInt = 0xFF4CAF50;
      final String colorHex = remote['color']?.toString() ?? '';
      if (colorHex.isNotEmpty) {
        final String normalized = colorHex.replaceAll('#', '');
        final String argb = normalized.length == 6 ? 'FF$normalized' : normalized;
        final int? parsed = int.tryParse(argb, radix: 16);
        if (parsed != null) {
          colorInt = parsed;
        }
      }

      final String? newLocalId = await _nativeApi.createCalendar(displayName, loginName, colorInt);
      if (newLocalId == null || newLocalId.isEmpty) {
        _lastConnectError = 'Failed to create local calendar. Check calendar permissions and try again.';
        return false;
      }
      createdLocalIdForEnableAttempt = newLocalId;

      try {
        await db.transaction((txn) async {
          final int now = DateTime.now().millisecondsSinceEpoch;
          await txn.insert(
            'local_bindings',
            {
              'remote_collection_id': remoteCollectionId,
              'local_collection_id': newLocalId,
              'binding_origin': existingBindingOrigin,
              'created_at': now,
              'updated_at': now,
            },
            conflictAlgorithm: ConflictAlgorithm.replace,
          );

          await txn.update(
            'remote_collections',
            {'is_enabled': 1},
            where: 'id = ?',
            whereArgs: [remoteCollectionId],
          );
        });
      } on DatabaseException catch (e) {
        final String msg = e.toString().toLowerCase();
        if (msg.contains('database is locked') || msg.contains('locked')) {
          _lastConnectError = 'Local database is busy. Please try again later.';
        } else if (msg.contains('full') || msg.contains('disk i/o')) {
          _lastConnectError = 'Insufficient storage. Please free space and try again.';
        } else if (msg.contains('unique constraint') || msg.contains('uq_lb_local')) {
          _lastConnectError = 'This local calendar is already bound to another remote calendar. Unbind first and retry.';
        } else {
          _lastConnectError = 'Failed to save local binding. Please try again later.';
        }
        if (createdLocalIdForEnableAttempt != null &&
            createdLocalIdForEnableAttempt!.isNotEmpty &&
            bindingOriginForEnableAttempt == SyncBindingOrigin.remote) {
          try {
            await _nativeApi.deleteCalendar(createdLocalIdForEnableAttempt!, loginName);
          } catch (_) {}
        }
        return false;
      }

      createdLocalIdForEnableAttempt = null;
      _triggerOneShotForceSyncInBackground(remoteCollectionId);
      return true;
    } on PlatformException catch (e) {
      final String msg = '${e.code} ${e.message ?? ''}'.toLowerCase();
      if (msg.contains('permission')) {
        _lastConnectError = 'Calendar permission missing. Grant permission in system settings and retry.';
      } else if (msg.contains('provider')) {
        _lastConnectError = 'System calendar provider error. Restart the calendar app and retry.';
      } else if (msg.contains('already')) {
        _lastConnectError = 'This calendar is already connected elsewhere. Check binding status.';
      } else {
        _lastConnectError = 'System calendar API error. Please try again later.';
      }
      debugPrint('[ERROR] connectAndEnableRemoteCalendarByPath platform exception: $e');
      if (createdLocalIdForEnableAttempt != null &&
          createdLocalIdForEnableAttempt!.isNotEmpty &&
          bindingOriginForEnableAttempt == SyncBindingOrigin.remote) {
        try {
          await _nativeApi.deleteCalendar(createdLocalIdForEnableAttempt!, loginName);
        } catch (_) {}
      }
      return false;
    } catch (e) {
      _lastConnectError = 'Connection failed. Please try again later.';
      debugPrint('[ERROR] connectAndEnableRemoteCalendarByPath failed: $e');
      if (createdLocalIdForEnableAttempt != null &&
          createdLocalIdForEnableAttempt!.isNotEmpty &&
          bindingOriginForEnableAttempt == SyncBindingOrigin.remote) {
        try {
          await _nativeApi.deleteCalendar(createdLocalIdForEnableAttempt!, loginName);
        } catch (_) {}
      }
      return false;
    }
  }

  void _triggerOneShotForceSyncInBackground(int remoteCollectionId) {
    unawaited(_triggerOneShotForceSync(remoteCollectionId));
  }

  Future<void> _triggerOneShotForceSync(int remoteCollectionId) async {
    if (remoteCollectionId <= 0) return;
    SyncEngine.requestForceSyncForCollection(remoteCollectionId);
    final SyncSummary summary = await SyncEngine().executeFullSync();
    if (summary.failed > 0) {
      final String detail = summary.errorLog.isNotEmpty ? summary.errorLog.join('; ') : 'Sync failed';
      _lastConnectError = 'Sync failed: $detail';
      return;
    }
    if (summary.total == 0) {
      final String? hint = await _deriveEligibilityHint(remoteCollectionId);
      if (hint != null) {
        _lastConnectError = hint;
      }
    }
  }

  Future<String?> _deriveEligibilityHint(int remoteCollectionId) async {
    final db = await _dbHelper.database;
    final rows = await db.rawQuery('''
      SELECT rc.remote_path, rc.is_enabled, lb.local_collection_id
      FROM remote_collections rc
      LEFT JOIN local_bindings lb ON lb.remote_collection_id = rc.id
      WHERE rc.id = ?
      LIMIT 1
    ''', [remoteCollectionId]);
    if (rows.isEmpty) return 'Remote path mismatch';
    final row = rows.first;
    if ((row['is_enabled'] as int? ?? 0) != 1) return 'Bind to a local calendar to sync';
    final String remotePath = (row['remote_path']?.toString() ?? '').trim();
    if (remotePath.isEmpty) return 'Remote path mismatch';
    final String localId = row['local_collection_id']?.toString() ?? '';
    if (localId.isEmpty) return 'Bind to a local calendar to sync';

    final Set<String> nativeCalendarIds = (await _nativeApi.getCalendars())
        .whereType<PlatformCalendar>()
        .map((calendar) => calendar.id ?? '')
        .where((id) => id.isNotEmpty)
        .toSet();
    if (!nativeCalendarIds.contains(localId)) {
      return 'Local calendar not found';
    }
    return 'Remote path mismatch';
  }

  /// 创建一个新的远端日历草稿（默认禁用）。
  ///
  /// 注意：本地系统日历只允许在“启用同步”流程中创建，
  /// 这里不再创建本地日历，也不再预建 local_bindings。
  Future<bool> createNewLocalCalendar(String displayName) async {
    final String userId = MMKVUtils.instance.getString(AppConstant.loginNameKey) ?? "";
    if (userId.isEmpty) {
      print("[ERROR] [Repository] Not logged in, cannot create calendar");
      return false;
    }

    try {
      // 1) 创建云端日历。
      final String cloudId = "cal_${DateTime.now().millisecondsSinceEpoch}";
      final String? remotePath = await CaleeServerService().createRemoteCalendar(
        userId: userId,
        calendarName: displayName,
        calendarId: cloudId,
        color: '#4CAF50',
      );

      if (remotePath == null) {
        print("[ERROR] [Repository] Remote creation failed");
        return false;
      }

      // 2) 确保 remote_collections 记录存在，且保持 disabled。
      await _ensureRemoteCalendarDraft(
        accountName: userId,
        displayName: displayName,
        remotePath: remotePath,
      );

      // 3) 重扫远端并落库（不创建本地日历，不创建 binding）。
      await CaleeServerService().scanRemoteCalendars(
        serverUrl: AppConstant.caleeServer,
        userId: userId,
      );

      return true;
    } catch (e) {
      print("[ERROR] [Repository] Create workflow exception: $e");
      return false;
    }
  }

  Future<void> _ensureRemoteCalendarDraft({
    required String accountName,
    required String displayName,
    required String remotePath,
  }) async {
    final db = await _dbHelper.database;
    final List<Map<String, dynamic>> rows = await db.query(
      'remote_collections',
      columns: ['id'],
      where: 'account_name = ? AND collection_type = ? AND remote_path = ?',
      whereArgs: [accountName, 'calendar', remotePath],
      limit: 1,
    );

    if (rows.isNotEmpty) {
      final int id = rows.first['id'] as int;
      await db.update(
        'remote_collections',
        {
          'display_name': displayName,
          'color': '#4CAF50',
        },
        where: 'id = ?',
        whereArgs: [id],
      );
      return;
    }

    await db.insert('remote_collections', {
      'account_name': accountName,
      'collection_type': 'calendar',
      'display_name': displayName,
      'color': '#4CAF50',
      'is_enabled': 0,
      'sync_mode': 0,
      'remote_path': remotePath,
    });
  }

  Future<bool> handlePublicSubscription(String icsUrl) async {
    // 1. 使用你提供的方法获取原始名称
    String? originalName = await CaleeServerService().getIcsNameFromUrl(icsUrl);

    // 确定用于显示的名称
    final String displayName = originalName ?? "Public subscription_${DateTime.now().millisecond}";
    final String userId = MMKVUtils.instance.getString(AppConstant.loginNameKey)!;

    // 2. 生成一个“干净”的 ID 用于 URL 路径
    // For example, convert "Company 2024" to "sub_1712345678"
    final String safeCalendarId = "sub_${DateTime.now().millisecondsSinceEpoch}";

    // 3. 提交给云端
    final String? remotePath = await CaleeServerService().subscribeRemotePublicIcs(
      userId: userId,
      calendarName: displayName,  // 🌟 这里用你抓取到的原始中文名
      calendarId: safeCalendarId, // 🌟 这里用纯数字/字母的 ID
      icsUrl: icsUrl,
    );

    if (remotePath != null) {
      // 通过统一远端扫描流程落库, 再补充来源 URL。
      await CaleeServerService().scanRemoteCalendars(
        serverUrl: AppConstant.caleeServer,
        userId: userId,
      );

      final db = await _dbHelper.database;
      await db.update(
        'remote_collections',
        {
          'is_subscription': 1,
          'subscription_url': icsUrl,
        },
        where: 'remote_path = ?',
        whereArgs: [remotePath],
      );
      return true;
    }
    return false;
  }

  /// 获取Subscribed calendar列表及其对应的事件总数（含详细打印）
  Future<List<Map<String, dynamic>>> getSubscribedCalendarsWithCount() async {
    final db = await _dbHelper.database;

    try {
      print("------------------------------------------------------------");
      print("[INFO] [Repository] Start querying subscriptions (sorted by local_id)...");

      // 🌟 核心修正：
      // 1. 去掉 c.id, 全部使用 c.local_id
      // 2. COUNT(s.uid) Stats sync_items 中的事件总数
      final String sql = '''
      SELECT 
        c.*, 
        COUNT(s.id) as event_count 
      FROM remote_collections c
      LEFT JOIN sync_items s ON c.id = s.remote_collection_id
      WHERE c.is_subscription = 1
      GROUP BY c.id
      ORDER BY c.id DESC
    ''';

      final List<Map<String, dynamic>> results = await db.rawQuery(sql);

      print("[INFO] [Repository] Query complete, found ${results.length} subscription records");

      for (var i = 0; i < results.length; i++) {
        final item = results[i];
        final String currentLocalId = item['id'].toString();
        print("""
  [INFO] Record [#$i]
     Display name: ${item['display_name']}
     Local ID    : $currentLocalId
     Event count : ${item['event_count']}
     Sync state  : ${item['sync_status'] == SyncItemStatus.pendingPush ? "[OK] enabled" : "[INFO] disabled"}
     Remote path : ${item['remote_path']}
  ------------------------------------------------------------""");
      }

      return results;
    } catch (e) {
      print("[ERROR] [Repository] Failed to fetch counted subscription list: $e");
      return [];
    }
  }

  Future<void> updateSystemCalendarId(String oldLocalId, String newSystemId) async {
    final db = await DatabaseHelper.instance.database;

    // 使用事务确保两张表同步更新
    await db.transaction((txn) async {
      // 1. 更新日历主表, 把临时 ID 换成系统数字 ID
      await txn.update(
        'local_bindings',
        {'local_collection_id': newSystemId, 'updated_at': DateTime.now().millisecondsSinceEpoch},
        where: 'local_collection_id = ?',
        whereArgs: [oldLocalId],
      );

      // 2. 更新同步映射表（如果有外键关联, 这一步非常重要）
      // 确保属于这个日历的所有事件记录都能关联到新的系统 ID
      await txn.update(
        'sync_items',
        {'local_item_id': newSystemId},
        where: 'local_item_id = ?',
        whereArgs: [oldLocalId],
      );
    });

    print("[DB] Calendar ID updated from $oldLocalId to $newSystemId");
  }

  // ==========================================
  // 4. 数据提取 (For Sync Engine)
  // ==========================================

  /// 获取所有需要上传到 Calee 的记录
  Future<List<Map<String, dynamic>>> getPendingUploads() async {
    final db = await _dbHelper.database;
    return await db.query(
      'sync_items',
      where: 'sync_status = ?',
      whereArgs: [1],
    );
  }
}
