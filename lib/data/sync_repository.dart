import 'package:caleesync/common/app_constant.dart';
import 'package:caleesync/common/utils/mmkv_utils.dart';
import 'package:caleesync/core/platform/pigeon/calendar_api.g.dart';
import 'package:sqflite/sqflite.dart';

import '../common/utils/IcsParser.dart';
import '../common/utils/UidGenerator.dart';
import '../entity/SyncContext.dart';
import '../services/nextcloud_service.dart';
import 'database_helper.dart';

class SyncRepository {
  final NativeCalendarApi _nativeApi = NativeCalendarApi();
  final DatabaseHelper _dbHelper = DatabaseHelper.instance;

  /// 扫描并更新本地日历表，返回所有可双向同步的日历 ID
  Future<List<SyncContext>> prepareSyncContexts() async {
    final db = await _dbHelper.database;

    // 1. 从原生侧拉取手机系统当前的日历列表
    final List<PlatformCalendar?> locals = await _nativeApi.getCalendars();

    for (var cal in locals) {
      if (cal == null || cal.isReadOnly == true) continue;

      // 2. 使用 ConflictAlgorithm.replace 或者特定逻辑更新
      // 这样可以确保如果用户改了日历颜色或名字，本地数据库也能同步更新
      await db.insert('calendar_map', {
        'local_id': cal.id,
        'account_name': cal.accountName,
        'account_type': cal.accountType,
        'display_name': cal.name,
        'color': cal.color,
        // 注意：这里不要覆盖 remote_path，如果已存在应保留
      }, conflictAlgorithm: ConflictAlgorithm.ignore);

      // 如果想更新名字但保留 remote_path，可以用 update + where local_id
    }

    // 3. 统一从数据库拉取所有“可写”的日历映射
    // 这样逻辑更清晰：原生负责采集，数据库负责持久化配置
    final List<Map<String, dynamic>> maps = await db.query(
      'calendar_map',
      // 假设你在 scanLocalCalendars 里已经标记了只读状态，或者这里直接查
    );

    List<SyncContext> contexts = [];
    for (var row in maps) {
      // 💡 这里的关键：即使 remote_path 为空，也要加入 contexts
      // 这样 executeFullSync 才能感知到这是一个需要“自动创建”的新日历
      contexts.add(SyncContext(
        calendarId: row['local_id'] as String,
        remotePath: row['remote_path'] as String? ?? "", // 允许为空字符串
        accountName: row['account_name'] as String? ?? '',
        accountType: row['account_type'] as String? ?? '',
        displayName: row['display_name'] as String? ?? '未命名日历', // 对应你之前的需求
      ));
    }

    return contexts;
  }

  /// 步骤 A: 扫描系统变更（新增/修改/删除）
  Future<void> scanSystemChanges(SyncContext ctx) async {
    final db = await _dbHelper.database;
    // 获取最近 30 天的数据
    final start = DateTime.now().subtract(const Duration(days: 30)).millisecondsSinceEpoch;
    final end = DateTime.now().add(const Duration(days: 30)).millisecondsSinceEpoch;

    // 1. 从原生获取系统当前的日程列表
    final List<PlatformItem?> items = await _nativeApi.getEvents(ctx.calendarId, start, end);
    final currentEvents = items.whereType<PlatformItem>().toList();

    // 记录本次扫描到的所有系统 ID，用于后续判断哪些被删除了
    final currentLocalIds = currentEvents.map((e) => e.localId).toList();

    await db.transaction((txn) async {
      // --- 步骤 1: 处理删除 (本地库有映射，但系统日历里找不到了) ---
      // 注意：只针对已同步(status=0)的记录，且 local_id 不在当前系统列表里的
      if (currentLocalIds.isNotEmpty) {
        final placeholders = currentLocalIds.map((_) => '?').join(',');
        await txn.update(
          'sync_map',
          {'sync_status': 2}, // 标记为待同步删除
          where: 'calendar_local_id = ? AND sync_status = 0 AND local_id NOT IN ($placeholders)',
          whereArgs: [ctx.calendarId, ...currentLocalIds],
        );
      } else {
        // 如果系统里一个日程都没有了，该日历下所有已同步的都标记为删除
        await txn.update('sync_map', {'sync_status': 2},
            where: 'calendar_local_id = ? AND sync_status = 0',
            whereArgs: [ctx.calendarId]);
      }

      // --- 步骤 2: 处理新增或修改 ---
      for (var event in currentEvents) {
        // 💡 核心改动：通过 local_id（系统唯一标识）来查找映射表
        final localRows = await txn.query('sync_map', where: 'local_id = ?', whereArgs: [event.localId]);

        if (localRows.isEmpty) {
          // A. 系统里有，但映射表没有 -> 用户手动在手机上新建的
          await txn.insert('sync_map', {
            'uid': event.uid, // 使用原生生成的 system_event_$id
            'local_id': event.localId,
            'calendar_local_id': ctx.calendarId,
            'summary': event.title,
            'dtstart': event.startTime,
            'dtend': event.endTime,
            'sync_status': 1, // 标记为待推送至云端
          });
          print("🔍 发现手机端新建日程: ${event.title}");
        } else {
          // B. 映射表存在 -> 检查是否有内容变更
          final local = localRows.first;
          bool isChanged = local['summary'] != event.title ||
              local['dtstart'] != event.startTime ||
              local['dtend'] != event.endTime;

          if (isChanged && local['sync_status'] == 0) {
            // 如果内容变了且当前是已同步状态，则标记为待更新推送
            await txn.update('sync_map', {
              'summary': event.title,
              'dtstart': event.startTime,
              'dtend': event.endTime,
              'sync_status': 1,
            }, where: 'local_id = ?', whereArgs: [event.localId]);
            print("🔍 发现手机端修改日程: ${event.title}");
          }
        }
      }
    });
  }

// ==========================================
  // 1. 日历扫描
  // ==========================================
  Future<void> scanLocalCalendars(String accountId) async {
    final db = await _dbHelper.database;
    final List<PlatformCalendar?> localCalendars = await _nativeApi.getCalendars();

    await db.transaction((txn) async {
      for (var cal in localCalendars) {
        if (cal == null) continue;
        await txn.rawInsert('''
        INSERT INTO calendar_map (
          local_id, account_name, account_type, display_name, color, sync_status
        )
        VALUES (?, ?, ?, ?, ?, ?)
        ON CONFLICT(local_id) DO UPDATE SET 
          display_name = excluded.display_name,
          color = excluded.color
      ''', [cal.id, cal.accountName, cal.accountType, cal.name, cal.color, 0]);
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
    int deleted = 0;

    final start = DateTime.now().subtract(const Duration(days: 45)).millisecondsSinceEpoch;
    final end = DateTime.now().add(const Duration(days: 45)).millisecondsSinceEpoch;

    // 1. 获取系统当前存在的事件
    final List<PlatformItem?> items = await _nativeApi.getEvents(calendarLocalId, start, end);
    final currentEvents = items.where((i) => i != null && (i.isTask == false)).cast<PlatformItem>().toList();

    // 提取系统当前的 UID 集合
    final currentUids = currentEvents.map((e) => e.uid).toSet();

    await db.transaction((txn) async {
      // 2. 【核心逻辑】处理删除：找出数据库里有，但系统里没了的记录
      // 注意：只处理状态不为 2 的，避免重复处理
      final List<Map<String, dynamic>> dbRows = await txn.query(
        'sync_map',
        where: 'calendar_local_id = ? AND sync_status != ?',
        whereArgs: [calendarLocalId, 2],
      );

      for (var row in dbRows) {
        final String dbUid = row['uid'];
        if (!currentUids.contains(dbUid)) {
          // 系统里找不到了 -> 用户在日历 App 里删了
          await txn.update(
            'sync_map',
            {'sync_status': 2}, // 标记为“待同步删除”
            where: 'uid = ?',
            whereArgs: [dbUid],
          );
          deleted++;
          print('🗑️ 标记待删除 (软删除): $dbUid');
        }
      }

      // 3. 处理新增或修改 (你原来的逻辑)
      for (var event in currentEvents) {
        // 核心改动：优先使用原生层返回的 event.uid (来自系统的 _SYNC_ID)
        final String eventUid = (event.uid != null && !event.uid!.startsWith('local_'))
            ? event.uid!
            : CaleeUid.generate();

        final List<Map<String, dynamic>> maps = await txn.query(
          'sync_map',
          where: 'uid = ?',
          whereArgs: [event.uid],
        );

        if (maps.isEmpty) {
          // 新增逻辑... (保持你原来的代码)
          await txn.insert('sync_map', {
            'uid': eventUid,
            'local_id': event.localId,
            'calendar_local_id': calendarLocalId,
            'summary': event.title ?? '无标题',
            'description': event.notes,
            'dtstart': event.startTime,
            'dtend': event.endTime,
            'last_mtime': event.lastModified ?? DateTime.now().millisecondsSinceEpoch,
            'item_type': 'event',
            'sync_status': 1,
          });
          newlyAdded++;
        } else {
          // 更新逻辑... (保持你原来的对比逻辑)
          // ... (省略你已有的 contentChanged 和 timeChanged 判断)
          // 如果检测到变化，更新并将 sync_status 设为 1
        }
      }
    });

    return {'added': newlyAdded, 'modified': modified, 'deleted': deleted};
  }

  Future<void> pullFromRemote(String calendarLocalId) async {
    final db = await _dbHelper.database;

    // 1. 🚀 动态获取日历配置（账号信息、远程路径等）
    final List<Map<String, dynamic>> calMaps = await db.query(
      'calendar_map',
      where: 'local_id = ?',
      whereArgs: [calendarLocalId],
    );

    if (calMaps.isEmpty) {
      print("❌ 未找到日历映射配置: $calendarLocalId");
      return;
    }

    final calConfig = calMaps.first;
    final String remotePath = calConfig['remote_path'] ?? "";
    // 这里的 userId 和 password 建议以后从账号管理模块获取，目前先沿用你的 MMKV


    if (remotePath.isEmpty) {
      print("⚠️ 该日历未绑定云端路径，跳过拉取。");
      return;
    }

    print("📡 准备从分组 [${calConfig['account_name']}] 拉取路径: $remotePath");

    // 2. 获取云端所有事件
    final remoteEvents = await NextcloudService().fetchRemoteEvents(
      calendarPath: remotePath,
    );

    // --- 【删除逻辑】对比云端与本地 UID 集合 ---
    final Set<String> remoteUids = remoteEvents.map((e) {
      final String href = e['href'];
      return Uri.decodeComponent(href.split('/').last).replaceAll('.ics', '');
    }).toSet();

    final localEntries = await db.query(
        'sync_map',
        where: 'calendar_local_id = ?',
        whereArgs: [calendarLocalId]
    );

    for (var local in localEntries) {
      final String uid = local['uid'] as String;
      final String? localId = local['local_id'] as String?;
      final String summary = (local['summary'] ?? "无标题") as String;

      // 如果本地标记为已同步(0)但云端没了，说明云端删除了
      if (!remoteUids.contains(uid)) {
        if (local['sync_status'] == 0) {
          print('🗑️ 云端已删除，同步移除本地: $summary');
          if (localId != null) await _nativeApi.deleteEvent(localId);
          await db.delete('sync_map', where: 'uid = ?', whereArgs: [uid]);
        }
      }
    }

    // 3. 处理新增或更新
    for (var remoteEvent in remoteEvents) {
      final String href = remoteEvent['href'];
      final String uid = Uri.decodeComponent(href.split('/').last).replaceAll('.ics', '');
      final String etag = (remoteEvent['etag'] as String? ?? "").replaceAll('"', '');

      final local = await db.query('sync_map', where: 'uid = ?', whereArgs: [uid]);

      if (local.isNotEmpty) {
        final int currentStatus = local.first['sync_status'] as int;
        // 冲突处理：本地待删除但云端还在，以云端为准重置
        if (currentStatus == 2) {
          await db.delete('sync_map', where: 'uid = ?', whereArgs: [uid]);
        } else {
          final String localEtag = (local.first['last_etag'] as String?) ?? "";
          if (localEtag == etag) continue; // ETag 一致，跳过
        }
      }

      // 4. 📥 下载详情并写入系统日历
      print('📥 正在更新事件详情: $uid');
      final icsData = await NextcloudService().getEventDetail(
          eventPath: href,
      );

      if (icsData != null) {
        final parsed = IcsParser.parse(icsData, uid);

        // 🚀 核心改动：调用 createEvent 时传入云端的 UID
        // 这会让 Android 的 _SYNC_ID 字段被填充，实现真正的 UUID 统一
        final String? newLocalId = await _nativeApi.createEvent(
          calendarLocalId,
          parsed['summary'] ?? "无标题",
          parsed['dtstart'],
          parsed['dtend'],
          parsed['description'],
          uid, // <--- 关键参数：传入生成的/云端的 UID
        );

        if (newLocalId != null) {
          await db.insert('sync_map', {
            'uid': uid,
            'local_id': newLocalId,
            'calendar_local_id': calendarLocalId,
            'summary': parsed['summary'],
            'last_etag': etag,
            'sync_status': 0,
            'item_type': 'event',
          }, conflictAlgorithm: ConflictAlgorithm.replace);
        }
      }
    }
  }

  Future<void> pushDeletesToRemote(String calendarLocalId) async {
    final db = await _dbHelper.database;
    final String userId = MMKVUtils.instance.getString(AppConstant.loginName) ?? "";

    // 1. 获取手机系统日历目前所有的 Event ID
    final List<String?> systemEventIds = await _nativeApi.getSystemEventIds(calendarLocalId);

    // 2. 找出那些在 sync_map 里有记录，但系统里已经没了的
    final List<Map<String, dynamic>> trackedEvents = await db.query(
        'sync_map',
        where: 'calendar_local_id = ?',
        whereArgs: [calendarLocalId]
    );

    for (var entry in trackedEvents) {
      final String localId = entry['local_id'];
      final String uid = entry['uid'];

      if (!systemEventIds.contains(localId)) {
        print('🗑️ 检测到本地已手动删除，同步删除云端: ${entry['summary']}');

        // 拼接云端路径 (如果是标准结构，通常是 calendarPath + uid + .ics)
        final String eventPath = "/remote.php/dav/calendars/$userId/cal_sync_6/$uid.ics";

        final bool ok = await NextcloudService().deleteEvent(
          eventPath: eventPath,
        );

        if (ok) {
          await db.delete('sync_map', where: 'uid = ?', whereArgs: [uid]);
        }
      }
    }
  }

  /// 统一的路径更新方法：用于将云端日历路径绑定到本地日历
  Future<void> updateRemotePath(String localId, String path) async {
    final db = await _dbHelper.database;

    // 确保路径不为 null
    int count = await db.update(
      'calendar_map',
      {'remote_path': path},
      where: 'local_id = ?',
      whereArgs: [localId],
    );

    if (count > 0) {
      print('✅ [Repository] 路径绑定成功: $localId -> $path');
    } else {
      print('⚠️ [Repository] 路径绑定失败: 未找到 ID 为 $localId 的本地日历');
    }
  }

  // ==========================================
  // 3. 云端反馈更新 (Cloud Response Handling)
  // ==========================================

  /// 当 Push 成功后，更新云端返回的 ETag 和路径
  /// 当 Push 成功后，同步本地状态
  Future<void> updateAfterSuccessfulPush(String uid, String etag, {String? remoteHref}) async {
    final db = await _dbHelper.database;

    // 构建更新 Map
    Map<String, dynamic> updateValues = {
      'last_etag': etag,
      'sync_status': 0, // 0: 已同步，本地与云端一致
      'last_mtime': DateTime.now().millisecondsSinceEpoch, // 更新本地记录的最后维护时间
    };

    // 如果提供了新的路径（比如首次创建），则更新
    if (remoteHref != null) {
      updateValues['remote_href'] = remoteHref;
    }

    await db.update(
      'sync_map',
      updateValues,
      where: 'uid = ?',
      whereArgs: [uid],
    );
    print('✅ 数据库已同步: UID $uid, New ETag: $etag');
  }

  /// 将从云端同步下来的事件记录到本地数据库
  Future<void> saveSyncedEvent(String localId, dynamic remote) async {
    final db = await _dbHelper.database;

    // 从 remote 数据中提取信息（注意：remote 是我们在 SyncEngine 中定义的 map）
    final String uid = remote['uid'] as String;
    // 去掉 ETag 的引号
    final String etag = (remote['etag'] as String).replaceAll('"', '');

    await db.insert(
      'sync_map',
      {
        'uid': uid,
        'local_id': localId,
        'calendar_local_id': remote['calendar_local_id'], // 确保这个字段被传入
        'last_etag': etag,
        'sync_status': 0,    // 0 表示已同步状态
        'item_type': 'event',
        'last_mtime': DateTime.now().millisecondsSinceEpoch,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    print('✅ 云端事件已保存到本地数据库: UID $uid');
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

  // SyncRepository.dart

  /// 彻底删除一个事件：包括系统日历格子和本地数据库追踪记录
  Future<bool> deleteEventTotally(String localId, String uid) async {
    try {
      // 1. 调用 Pigeon 接口删除手机系统日历里的事件
      final bool systemOk = await _nativeApi.deleteEvent(localId);

      if (systemOk) {
        // 2. 删除本地数据库 sync_map 中的追踪记录
        final db = await _dbHelper.database;
        await db.delete(
          'sync_map',
          // where: 'uid = ?',
          // whereArgs: [uid],
        );
        print('✅ 彻底删除成功: UID $uid');
        return true;
      } else {
        print('❌ 系统日历删除失败: ID $localId');
        return false;
      }
    } catch (e) {
      print('❌ 删除操作异常: $e');
      return false;
    }
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