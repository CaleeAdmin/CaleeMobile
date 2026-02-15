import 'package:caleesync/common/app_constant.dart';
import 'package:caleesync/common/utils/mmkv_utils.dart';
import 'package:caleesync/core/platform/pigeon/calendar_api.g.dart';
import 'package:flutter/cupertino.dart';
import 'package:sqflite/sqflite.dart';

import '../common/utils/IcsParser.dart';
import '../common/utils/UidGenerator.dart';
import '../entity/SyncContext.dart';
import '../services/nextcloud_service.dart';
import 'database_helper.dart';

class SyncRepository {
  final NativeCalendarApi _nativeApi = NativeCalendarApi();
  final DatabaseHelper _dbHelper = DatabaseHelper.instance;

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
      // 1. 提取当前系统“活着的”ID白名单
      final List<String> currentLocalIds = localCalendars
          .where((cal) => cal != null)
          .map((cal) => cal!.id.toString())
          .toList();

      // 2. 增量更新或插入
      for (var cal in localCalendars) {
        if (cal == null) continue;

        // 注意：如果之前是状态 2（待删除），但现在又扫到了（用户可能撤销了删除或手动加回了同名日历）
        // 我们通过更新将其恢复为状态 1（就绪）或保持现状
        await txn.rawInsert('''
        INSERT INTO calendar_map (
          local_id, account_name, account_type, display_name, color, 
          sync_mode, is_enabled, is_provisioned, origin
        )
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(local_id) DO UPDATE SET 
          display_name = excluded.display_name,
          color = excluded.color,
          account_type = excluded.account_type,
          sync_mode = excluded.sync_mode,
          -- 如果之前被标记为待删除(2)，现在重新扫到了，恢复为就绪状态(1)
          is_provisioned = CASE WHEN is_provisioned = 2 THEN 1 ELSE is_provisioned END
      ''', [
          cal.id, accountId, cal.accountType, cal.name, cal.color,
          cal.isReadOnly == true ? 1 : 0,
          0, // is_enabled: 本地日历扫描到默认开启
          0, // is_provisioned: 本地扫到的已经是实物，设为就绪
          0 // origin: 本地起源
        ]);
      }

      // 3. 【状态机转换】：标记消失的日历为“待删除”
      // 逻辑：属于该账号、本地起源(0)、且不在白名单内、且目前不是待删除状态
      if (currentLocalIds.isNotEmpty) {
        final placeholders = List.filled(currentLocalIds.length, '?').join(',');
        await txn.update(
          'calendar_map',
          {'is_provisioned': 2},
          where: 'account_name = ? AND origin = 0 AND local_id NOT IN ($placeholders) AND is_provisioned != 2',
          whereArgs: [accountId, ...currentLocalIds],
        );
      } else {
        // 系统日历全空了
        await txn.update(
          'calendar_map',
          {'is_provisioned': 2},
          where: 'account_name = ? AND origin = 0 AND is_provisioned != 2',
          whereArgs: [accountId],
        );
      }
    });
  }

  Future<void> refreshAllLocalEvents(String accountId) async {
    final db = await _dbHelper.database;

    // 1. 获取所有当前已就绪的本地日历
    final List<Map<String, dynamic>> activeCalendars = await db.query(
      'calendar_map',
      where: 'account_name = ? AND local_id IS NOT NULL AND is_provisioned = 1',
      whereArgs: [accountId],
    );

    for (var cal in activeCalendars) {
      final String localCalId = cal['local_id'].toString();

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
        'sync_map',
        where: 'calendar_local_id = ?',
        whereArgs: [localCalId],
      );
      final Map<String, Map<String, dynamic>> dbMap = {
        for (var r in dbRecords) r['local_id'].toString(): r
      };

      await db.transaction((txn) async {
        // --- 环节一：处理【修改】和【漏网之鱼】 ---
        for (var entry in systemSnap.entries) {
          final String sid = entry.key;
          final PlatformItem systemEvent = entry.value;
          final record = dbMap[sid];

          if (record == null) {
            // 💡 情况 A：系统有，数据库没。这就是你说的【新增事件b】
            debugPrint("🆕 发现本地物理新增: ${systemEvent.title}");
            await txn.insert('sync_map', {
              'uid': systemEvent.uid ?? 'local_${DateTime.now().microsecondsSinceEpoch}',
              'local_id': sid,
              'calendar_local_id': localCalId,
              'summary': systemEvent.title,
              'last_mtime': systemEvent.lastModified,
              'sync_status': 1, // 标记为 Dirty，待 Push
              'item_type': 'event'
            });
          } else {
            // 💡 情况 B：数据库有。对比修改时间戳，这就是你说的【修改名称】
            final int systemMtime = systemEvent.lastModified ?? 0;
            final int dbMtime = record['last_mtime'] ?? 0;

            if (systemMtime > dbMtime) {
              debugPrint("📝 发现本地物理修改: ${systemEvent.title}");
              await txn.update(
                'sync_map',
                {
                  'summary': systemEvent.title,
                  'last_mtime': systemMtime,
                  'sync_status': 1, // 标记为 Dirty，待 Push
                },
                where: 'local_id = ?',
                whereArgs: [sid],
              );
            }
          }
        }

        // --- 环节二：处理【删除】 ---
        for (var record in dbRecords) {
          final String mappedId = record['local_id'].toString();
          if (!systemSnap.containsKey(mappedId)) {
            // 💡 情况 C：数据库有，系统没了。说明用户在系统日历删了。
            debugPrint("🗑️ 发现本地物理删除: ${record['summary']}");
            await txn.update(
              'sync_map',
              {'sync_status': 2}, // 标记为 Deleted，待通知云端
              where: 'local_id = ?',
              whereArgs: [mappedId],
            );
          }
        }
      });
    }
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
    final remoteEvents = await NextcloudService().fetchUnifiedEvents(
      calendarPath: remotePath,
      isSubscription: false
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
      final icsData = "";// await NextcloudService().getEventDetail(
      //     eventPath: href,
      // );

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

  Future<Map<String, dynamic>> getCalendarDetailData(String localId) async {
    final db = await DatabaseHelper.instance.database;

    // 1. 查询基础配置
    final List<Map<String, dynamic>> maps = await db.query(
      'calendar_map',
      where: 'local_id = ?',
      whereArgs: [localId],
    );

    if (maps.isEmpty) return {};
    final cal = maps.first;

    // 2. 统计该日历下的本地有效事件数（过滤 status 2）
    final countResult = await db.rawQuery(
        'SELECT COUNT(*) as count FROM sync_map WHERE calendar_local_id = ? AND sync_status != 2',
        [localId]
    );

    // 3. 逻辑判定：纯靠 account_type 区分
    final String accType = cal['account_type'] ?? '';
    // 如果是 Nextcloud 说明是云端发现的，否则视为系统日历
    final bool isNextcloudNative = (accType == 'Nextcloud');

    return {
      'title': cal['display_name'] ?? 'Primary Calendar',
      'source': isNextcloudNative ? 'Nextcloud' : 'System',
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
        'calendar_map',
        where: 'local_id = ?',
        whereArgs: [oldId],
      );

      if (oldRecords.isEmpty) {
        print("⚠️ [ID 洗白] 未找到旧 ID: $oldId，可能已处理过。");
        return;
      }

      final oldRecord = oldRecords.first;
      // 提取关键属性，确保它们能带到新 ID 身上
      final String? remotePath = oldRecord['remote_path'];
      final String? accountType = oldRecord['account_type'];

      // 2. 🌟 预清理冲突：如果新 ID (比如 '7') 已经存在记录（例如 scanLocalCalendars 扫出来的）
      // 我们先删除它，因为我们要把“带路径”的老记录合并过去
      await txn.delete('calendar_map', where: 'local_id = ?', whereArgs: [newId]);

      // 3. 执行核心洗白：将虚拟 ID 改为真实系统 ID
      // 注意：我们这里不显式 update account_type，它会随着整行保留下来
      final calendarUpdateCount = await txn.update(
        'calendar_map',
        {
          'local_id': newId,
          'remote_path': remotePath, // 确保路径被继承
          // 这里不改 account_type，它依然是最初定义的 Nextcloud 或 com.google
        },
        where: 'local_id = ?',
        whereArgs: [oldId],
      );

      // 4. 更新事件关联的外键
      final eventUpdateCount = await txn.update(
        'sync_map',
        {'calendar_local_id': newId},
        where: 'calendar_local_id = ?',
        whereArgs: [oldId],
      );

      print("✅ [ID 洗白成功] $oldId -> $newId");
      print("📌 属性保留: AccountType=$accountType, RemotePath=$remotePath");
      print("📊 统计: 日历更新($calendarUpdateCount), 事件外键关联($eventUpdateCount)");
    });
  }

  /// 🗑️ 核心合并删除逻辑：物理销毁或解除绑定
  Future<void> performAbsoluteDelete({String? localId, String? remotePath}) async {
    final db = await _dbHelper.database;
    final String userId = MMKVUtils.instance.getString(AppConstant.loginName) ?? "";

    final String? sanitizedLocalId = (localId != null && localId.isNotEmpty) ? localId : null;
    final String? sanitizedRemotePath = (remotePath != null && remotePath.isNotEmpty) ? remotePath : null;

    if (sanitizedLocalId == null && sanitizedRemotePath == null) {
      debugPrint("⚠️ [Delete] 传入参数为空，跳过删除");
      return;
    }

    // 1. 提取元数据（优先 local_id，兜底 remote_path）
    final List<Map<String, dynamic>> maps = sanitizedLocalId != null
        ? await db.query(
            'calendar_map',
            where: 'local_id = ?',
            whereArgs: [sanitizedLocalId],
          )
        : await db.query(
            'calendar_map',
            where: 'remote_path = ?',
            whereArgs: [sanitizedRemotePath],
          );

    if (maps.isEmpty) {
      debugPrint("⚠️ [Delete] 数据库中已无此日历，无需重复操作: local=$sanitizedLocalId remote=$sanitizedRemotePath");
      return;
    }

    final cal = maps.first;
    final String accountName = cal['account_name'] ?? '';
    final String resolvedLocalId = cal['local_id']?.toString() ?? sanitizedLocalId ?? '';
    final String? resolvedRemotePath = cal['remote_path']?.toString() ?? sanitizedRemotePath;
    final int? syncMode = cal['sync_mode'];

    debugPrint("🚀 启动彻底删除流程: ID $resolvedLocalId, Path: $resolvedRemotePath");

    try {
      // --- Step A: 云端删除 ---
      // 逻辑：有远端路径且非只读时才尝试
      if (resolvedRemotePath != null && resolvedRemotePath.isNotEmpty && syncMode == 0) {
        bool cloudOk = await NextcloudService().deleteRemoteCalendar(
          userId: userId,
          calendarPath: resolvedRemotePath,
        );
        debugPrint(cloudOk ? "✅ 云端销毁成功" : "❌ 云端销毁失败 (状态码不符)");
      }

      // --- Step B: 本地系统层删除 ---
      if (resolvedLocalId.isNotEmpty && !resolvedLocalId.startsWith('rc_') && syncMode == 0) {
        await _nativeApi.deleteCalendar(resolvedLocalId, accountName);
        debugPrint("✅ 手机系统日历已移除");
      }
    } catch (e) {
      // 即使 Step A 或 B 出错（比如断网），也要捕获它，防止程序中断
      debugPrint("⚠️ 物理层删除报错 (但这不影响清理本地库): $e");
    } finally {
      // --- Step C: 核心保底 - 本地数据库清理 ---
      // 无论前面是成功还是失败，必须抹掉本地记录，防止“死而复生”
      await db.transaction((txn) async {
        // 1. 删除关联的事件追踪 (sync_map)
        int sCount = 0;
        if (resolvedLocalId.isNotEmpty) {
          sCount = await txn.delete(
            'sync_map',
            where: 'calendar_local_id = ?',
            whereArgs: [resolvedLocalId],
          );
        }

        // 2. 删除日历自身的配置 (calendar_map)
        final int cCount = resolvedLocalId.isNotEmpty
            ? await txn.delete(
                'calendar_map',
                where: 'local_id = ?',
                whereArgs: [resolvedLocalId],
              )
            : await txn.delete(
                'calendar_map',
                where: 'remote_path = ?',
                whereArgs: [resolvedRemotePath],
              );

        debugPrint("🗑️ 数据库清理完毕: 删除了 $sCount 条事件, $cCount 条日历记录");
      });
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
      throw Exception('缺少日历标识，无法改名');
    }

    // 1. 获取当前日历元数据（优先 local_id，兜底 remote_path）
    List<Map<String, dynamic>> maps = [];
    if (sanitizedLocalId != null) {
      maps = await db.query(
        'calendar_map',
        where: 'local_id = ?',
        whereArgs: [sanitizedLocalId],
        limit: 1,
      );
    }

    if (maps.isEmpty && sanitizedRemotePath != null) {
      maps = await db.query(
        'calendar_map',
        where: 'remote_path = ?',
        whereArgs: [sanitizedRemotePath],
        limit: 1,
      );
    }

    if (maps.isEmpty) {
      throw Exception('未找到目标日历记录');
    }
    final cal = maps.first;
// 如果字段可能为空，用 String?
    final String? path = cal['remote_path'] as String?;

// 如果你确定 account_name 绝对有值，用 String
    final String userId = cal['account_name'] as String;
    final String accountType = (cal['account_type'] as String?)?.trim().isNotEmpty == true
        ? (cal['account_type'] as String)
        : 'com.nextcloud.caleesync';

    try {
      // 2. 先改云端 (如果失败，建议直接抛异常，不改本地)
      if (path != null) {
        bool isCloudOk = await NextcloudService().renameRemoteCalendar(
            userId: userId,
            calendarPath: path,
            newName: newName
        );
        if (!isCloudOk) throw Exception("云端改名失败");
      }

      // 3. 修改手机系统日历 (Android/iOS 系统层)
      // 仅当存在 local_id（且不是虚拟 rc_）时尝试系统改名
      final String? resolvedLocalId = cal['local_id']?.toString();
      if (resolvedLocalId != null && resolvedLocalId.isNotEmpty && !resolvedLocalId.startsWith('rc_')) {
        final bool localRenameOk = await _nativeApi.modifyCalendarTitle(
          resolvedLocalId,
          newName,
          userId,
          accountType == 'NextCloud' ? 'com.nextcloud.caleesync' : accountType,
        );
        if (!localRenameOk) {
          throw Exception('系统日历改名失败');
        }
      }

      // 4. 修改本地数据库记录
      if (resolvedLocalId != null && resolvedLocalId.isNotEmpty) {
        await db.update(
          'calendar_map',
          {'display_name': newName},
          where: 'local_id = ?',
          whereArgs: [resolvedLocalId],
        );
      } else {
        await db.update(
          'calendar_map',
          {'display_name': newName},
          where: 'remote_path = ?',
          whereArgs: [path],
        );
      }

      print("✅ 日历 ${resolvedLocalId ?? path} 已在三端同步更名为: $newName");

    } catch (e) {
      print("❌ 改名流程中断: $e");
      rethrow;
    }
  }

  /// 创建一个全新的本地日历条目
  /// 此时只在【系统日历】和【本地数据库】占位，暂不推送到云端
  Future<bool> createNewLocalCalendar(String displayName) async {
    final String userId = MMKVUtils.instance.getString(AppConstant.loginName) ?? "";
    if (userId.isEmpty) {
      print("❌ [Repository] 当前未登录，无法创建日历");
      return false;
    }

    try {
      // 1. 优先在云端创建，逻辑与订阅功能保持一致。
      final String cloudId = "cal_${DateTime.now().millisecondsSinceEpoch}";
      final String? remotePath = await NextcloudService().createRemoteCalendar(
        userId: userId,
        calendarName: displayName,
        calendarId: cloudId,
        color: '#4CAF50',
      );

      if (remotePath == null) {
        print("❌ [Repository] 云端创建失败，放弃本地入库");
        return false;
      }

      // 2. 创建成功后立即重扫远端列表，由统一流程落库。
      await NextcloudService().scanRemoteCalendars(
        serverUrl: AppConstant.nextcloudServer,
        userId: userId,
      );

      return true;
    } catch (e) {
      print("❌ [Repository] 创建逻辑发生异常: $e");
      return false;
    }
  }

  Future<bool> handlePublicSubscription(String icsUrl) async {
    // 1. 使用你提供的方法获取原始名称
    String? originalName = await NextcloudService().getIcsNameFromUrl(icsUrl);

    // 确定用于显示的名称
    final String displayName = originalName ?? "公共订阅_${DateTime.now().millisecond}";
    final String userId = MMKVUtils.instance.getString(AppConstant.loginName)!;

    // 2. 生成一个“干净”的 ID 用于 URL 路径
    // 比如将 "公司 2024" 转换为 "sub_1712345678"
    final String safeCalendarId = "sub_${DateTime.now().millisecondsSinceEpoch}";

    // 3. 提交给云端
    final String? remotePath = await NextcloudService().subscribeRemotePublicIcs(
      userId: userId,
      calendarName: displayName,  // 🌟 这里用你抓取到的原始中文名
      calendarId: safeCalendarId, // 🌟 这里用纯数字/字母的 ID
      icsUrl: icsUrl,
    );

    if (remotePath != null) {
      // 插入本地数据库...
      return true;
    }
    return false;
  }

  /// 获取订阅日历列表及其对应的事件总数（含详细打印）
  Future<List<Map<String, dynamic>>> getSubscribedCalendarsWithCount() async {
    final db = await _dbHelper.database;

    try {
      print("------------------------------------------------------------");
      print("🔍 [Repository] 开始查询订阅列表 (基于 local_id 排序)...");

      // 🌟 核心修正：
      // 1. 去掉 c.id，全部使用 c.local_id
      // 2. COUNT(s.uid) 统计 sync_map 中的事件总数
      final String sql = '''
      SELECT 
        c.*, 
        COUNT(s.uid) as event_count 
      FROM calendar_map c
      LEFT JOIN sync_map s ON c.local_id = s.calendar_local_id
      WHERE c.local_id LIKE ? OR c.remote_path LIKE ? OR c.remote_path LIKE ?
      GROUP BY c.local_id
      ORDER BY c.local_id DESC
    ''';

      final List<Map<String, dynamic>> results = await db.rawQuery(
          sql,
          ['%sub%', '%sub_%', '%?export%']
      );

      print("📊 [Repository] 查询完成，共找到 ${results.length} 条订阅记录");

      for (var i = 0; i < results.length; i++) {
        final item = results[i];
        final String currentLocalId = item['local_id'].toString();
        final bool isVirtual = currentLocalId.startsWith('rc_');

        print("""
  📍 记录 [#$i]
     显示名称: ${item['display_name']}
     本地 ID : $currentLocalId ${isVirtual ? "[未同步到系统]" : "[已同步到系统]"}
     事件数量: ${item['event_count']}
     同步状态: ${item['sync_status'] == 1 ? "✅ 开启" : "⚪ 关闭"}
     远程路径: ${item['remote_path']}
  ------------------------------------------------------------""");
      }

      return results;
    } catch (e) {
      print("❌ [Repository] 获取带计数的订阅列表失败: $e");
      return [];
    }
  }

  Future<void> updateSystemCalendarId(String oldRcId, String newSystemId) async {
    final db = await DatabaseHelper.instance.database;

    // 使用事务确保两张表同步更新
    await db.transaction((txn) async {
      // 1. 更新日历主表，把临时 ID 换成系统数字 ID
      await txn.update(
        'calendar_map',
        {'local_id': newSystemId},
        where: 'local_id = ?',
        whereArgs: [oldRcId],
      );

      // 2. 更新同步映射表（如果有外键关联，这一步非常重要）
      // 确保属于这个日历的所有事件记录都能关联到新的系统 ID
      await txn.update(
        'sync_map',
        {'local_id': newSystemId},
        where: 'local_id = ?',
        whereArgs: [oldRcId],
      );
    });

    print("[DB] 日历 ID 已从 $oldRcId 成功洗白为 $newSystemId");
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
