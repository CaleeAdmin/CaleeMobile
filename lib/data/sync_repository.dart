import 'dart:async';

import 'package:caleesync/common/app_constant.dart';
import 'package:caleesync/common/utils/mmkv_utils.dart';
import 'package:caleesync/core/platform/pigeon/calendar_api.g.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:sqflite/sqflite.dart';

import '../entity/SyncSummary.dart';
import '../sync/SyncEnum.dart';
import '../sync/sync_trigger_orchestrator.dart';
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

    // 2. Stats该日历下的本地有效事件数
    final int? remoteCollectionId = cal['id'] as int?;
    final countResult = await db.rawQuery(
        'SELECT COUNT(*) as count FROM sync_items WHERE remote_collection_id = ?',
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
    final SyncTriggerOrchestrator orchestrator = Get.isRegistered<SyncTriggerOrchestrator>()
        ? Get.find<SyncTriggerOrchestrator>()
        : Get.put(SyncTriggerOrchestrator(), permanent: true);
    final SyncSummary summary = await orchestrator.triggerForce(remoteCollectionId);
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
