import 'package:caleesync/common/app_constant.dart';
import 'package:caleesync/common/utils/mmkv_utils.dart';
import 'package:caleesync/core/platform/pigeon/calendar_api.g.dart';
import 'package:caleesync/data/sync_repository.dart';
import 'package:flutter/cupertino.dart';
import 'package:sqflite/sqflite.dart';

import 'SyncEnum.dart';
import '../common/utils/IcsGenerator.dart';
import '../data/database_helper.dart';
import '../entity/SyncContext.dart';
import '../entity/SyncSummary.dart';
import '../services/calee_auth_service.dart';
import '../services/calee_server_service.dart';
import 'dart:collection';
import 'factory/SyncStrategyFactory.dart';

class SyncEngine {
  final SyncRepository _repo = SyncRepository();
  final CaleeServerService _nc = CaleeServerService();
  final NativeCalendarApi _native = NativeCalendarApi();
  final CaleeAuthService _authService = CaleeAuthService(serverBaseUrl: AppConstant.caleeServer);
  final DatabaseHelper _dbHelper = DatabaseHelper.instance;

  static final Set<int> _pendingForceSyncCollectionIds = HashSet<int>();

  static void requestForceSyncForCollection(int remoteCollectionId) {
    if (remoteCollectionId > 0) {
      _pendingForceSyncCollectionIds.add(remoteCollectionId);
    }
  }

  static bool consumeForceSyncForCollection(int remoteCollectionId) {
    if (remoteCollectionId <= 0) return false;
    return _pendingForceSyncCollectionIds.remove(remoteCollectionId);
  }

  //依赖表格 https://docs.google.com/spreadsheets/d/1QG-OfRUdYpY5G-_rrLWNYgUVUaAKNnHNQDPPexwckHE/edit?gid=975224459#gid=975224459

  /// Build sync tasks only for bindings that pass the hard eligibility gate.
  ///
  /// Flow:
  /// 1) Load remote/local binding snapshots.
  /// 2) Evaluate binding eligibility (enabled, path, binding row, local id, local exists, remote exists).
  /// 3) Detect collection-level change signals.
  /// 4) Emit a context only when this binding should run a strategy.
  ///
  /// Note on push behavior:
  /// - READ_ONLY bindings schedule [SyncAction.fullSyncPull] (no push allowed).
  /// - TWO_WAY bindings schedule [SyncAction.fullSyncBidi], whose matrix can both
  ///   pull and push (including local-create -> remote create via push path).
  Future<List<SyncContext>> generateSyncTasks(
      String userId,
      List<Map<String, dynamic>> remoteResults,
      ) async {
    final db = await _dbHelper.database;

    final List<Map<String, dynamic>> collectionRows = await db.rawQuery('''
      SELECT
        rc.id,
        rc.account_name,
        rc.remote_path,
        rc.display_name,
        rc.color,
        rc.synced_ctag,
        rc.sync_mode,
        rc.is_enabled,
        rc.is_subscription,
        lb.id AS binding_id,
        lb.local_collection_id,
        lb.binding_origin
      FROM remote_collections rc
      LEFT JOIN local_bindings lb ON lb.remote_collection_id = rc.id
      WHERE rc.account_name = ?
        AND rc.collection_type = 'calendar'
    ''', [userId]);

    final List<SyncContext> contexts = [];
    final remoteMap = {
      for (final r in remoteResults)
        if ((r['remote_path']?.toString() ?? '').isNotEmpty) CaleeServerService.normalizeRemotePath(r['remote_path'].toString()): r
    };

    final List<PlatformCalendar?> nativeCalendars = await _native.getCalendars();
    final Set<String> nativeIds = nativeCalendars
        .whereType<PlatformCalendar>()
        .map((calendar) => calendar.id ?? '')
        .where((id) => id.isNotEmpty)
        .toSet();

    for (final local in collectionRows) {
      final String path = CaleeServerService.normalizeRemotePath(local['remote_path']?.toString() ?? '');
      final Map<String, dynamic>? remote = remoteMap[path];
      final int remoteCollectionId = (local['id'] as int?) ?? 0;

      final bool forceRequested = consumeForceSyncForCollection(remoteCollectionId);

      final Map<String, dynamic> gate = _evaluateBindingEligibility(
        row: local,
        nativeCalendarIds: nativeIds,
        remoteExists: remote != null,
      );

      if (!(gate['eligible'] as bool)) {
        final String reason = gate['reason']?.toString() ?? 'unknown';
        final String uiHint = gate['ui_hint']?.toString() ?? '';
        final int bindingId = (local['binding_id'] as int?) ?? 0;
        final int bindingOrigin = (local['binding_origin'] as int?) ?? SyncBindingOrigin.remote;
        debugPrint('[SYNC_GATE][binding_id=$bindingId][path=$path][origin=$bindingOrigin] skipped reason=$reason hint=$uiHint');
        if (forceRequested) {
          debugPrint('[SYNC_FORCE][binding_id=$bindingId][path=$path][origin=$bindingOrigin] force=true consumed_but_ineligible reason=$reason');
        }
        if (reason == 'local_calendar_missing' && remoteCollectionId > 0) {
          await db.update(
            'remote_collections',
            {'is_enabled': 0},
            where: 'id = ?',
            whereArgs: [remoteCollectionId],
          );
          debugPrint('[SYNC_GATE][binding_id=$bindingId][origin=$bindingOrigin] disabled_due_to_missing_local_calendar');
        }
        continue;
      }

      final int mode = (local['sync_mode'] as int?) ?? SyncBindingMode.readOnly;
      final int bindingId = (local['binding_id'] as int?) ?? 0;
      final int bindingOrigin = (local['binding_origin'] as int?) ?? SyncBindingOrigin.remote;
      final String? dbCtag = local['synced_ctag']?.toString();
      final String? remoteCtag = remote?['ctag']?.toString();
      final bool remoteChanged = (remoteCtag != null && remoteCtag != dbCtag);
      final bool localChanged = await _isCalendarDirty(db, local['id']);
      final bool metaChanged =
          (remote?['display_name']?.toString() ?? '') != (local['display_name']?.toString() ?? '') ||
          (remote?['color']?.toString() ?? '') != (local['color']?.toString() ?? '');

      final bool isTwoWay = mode == SyncBindingMode.twoWay;
      final bool isOneWayRemoteOrigin = !isTwoWay && bindingOrigin == SyncBindingOrigin.remote;
      final bool isOneWayLocalOrigin = !isTwoWay && bindingOrigin == SyncBindingOrigin.local;

      final bool shouldSync = isTwoWay
          ? (remoteChanged || localChanged || metaChanged)
          : isOneWayRemoteOrigin
              ? (remoteChanged || metaChanged)
              : (localChanged || metaChanged);
      final bool bootstrapRequired = await _isBootstrapRequired(db, remoteCollectionId);
      final bool forceMode = forceRequested || bootstrapRequired;

      if (!shouldSync && !forceMode) {
        debugPrint('[SYNC_GATE][binding_id=$bindingId][path=$path][origin=$bindingOrigin] skipped reason=no_detected_change');
        continue;
      }

      if (forceMode) {
        final String localCollectionId = local['local_collection_id']?.toString() ?? '';
        final String modeName = isTwoWay
            ? 'bidi'
            : isOneWayLocalOrigin
                ? 'push'
                : 'pull';
        debugPrint('[SYNC_FORCE][binding_id=$bindingId][path=$path][local=$localCollectionId][origin=$bindingOrigin][mode=$modeName] force=true requested=$forceRequested bootstrap=$bootstrapRequired');
      }

      final SyncAction action = isTwoWay
          ? SyncAction.fullSyncBidi
          : isOneWayLocalOrigin
              ? SyncAction.fullSyncPush
              : SyncAction.fullSyncPull;

      final String modeName = action == SyncAction.fullSyncBidi
          ? 'bidi'
          : action == SyncAction.fullSyncPush
              ? 'push'
              : 'pull';
      debugPrint('[SYNC_PLAN][binding_id=$bindingId][path=$path][origin=$bindingOrigin][mode=$modeName] changed(remote=$remoteChanged local=$localChanged meta=$metaChanged)');

      // Strategy selection is where push capability is enabled:
      // - fullSyncPull: remote -> local only
      // - fullSyncBidi: remote <-> local (contains _pushToRemote path)
      contexts.add(_buildContext(
        remote ?? {},
        local,
        action,
      ));
    }

    return contexts;
  }

  /// Centralized hard gate used before any per-binding strategy can run.
  /// Return shape: {eligible: bool, reason: string}.
  Map<String, dynamic> _evaluateBindingEligibility({
    required Map<String, dynamic> row,
    required Set<String> nativeCalendarIds,
    required bool remoteExists,
  }) {
    final int isEnabled = (row['is_enabled'] as int?) ?? 0;
    if (isEnabled != 1) {
      return {'eligible': false, 'reason': 'remote_collection_disabled'};
    }

    final String remotePath = row['remote_path']?.toString() ?? '';
    if (remotePath.isEmpty) {
      return {'eligible': false, 'reason': 'missing_remote_path'};
    }

    final int bindingId = (row['binding_id'] as int?) ?? 0;
    if (bindingId <= 0) {
      return {'eligible': false, 'reason': 'missing_binding_id', 'ui_hint': 'Bind to a local calendar to sync'};
    }

    final String localCollectionId = row['local_collection_id']?.toString() ?? '';
    if (localCollectionId.isEmpty) {
      return {'eligible': false, 'reason': 'missing_local_collection_id', 'ui_hint': 'Bind to a local calendar to sync'};
    }

    if (!nativeCalendarIds.contains(localCollectionId)) {
      return {'eligible': false, 'reason': 'local_calendar_missing', 'ui_hint': 'Local calendar not found'};
    }

    if (!remoteExists) {
      return {'eligible': false, 'reason': 'remote_collection_missing', 'ui_hint': 'Remote path mismatch'};
    }

    return {'eligible': true, 'reason': 'ok'};
  }

  /// Collection-level local dirty check for task scheduling only.
  ///
  /// Item-level conflict/change decisions are handled in strategy decision matrices.
  Future<bool> _isCalendarDirty(Database db, Object? remoteCollectionId) async {
    if (remoteCollectionId == null) return false;
    // 这里的状态码对应：pendingPush, pendingDelete
    final List<Map<String, dynamic>> dirtyCheck = await db.rawQuery('''
    SELECT 1 FROM sync_items
    WHERE remote_collection_id = ? AND sync_status IN (${SyncItemStatus.pendingPush}, ${SyncItemStatus.pendingDelete})
    LIMIT 1
  ''', [remoteCollectionId]);
    return dirtyCheck.isNotEmpty;
  }


  Future<bool> _isBootstrapRequired(Database db, int remoteCollectionId) async {
    if (remoteCollectionId <= 0) return false;
    final List<Map<String, dynamic>> rows = await db.rawQuery('''
      SELECT COUNT(1) AS count
      FROM sync_items
      WHERE remote_collection_id = ?
    ''', [remoteCollectionId]);
    final int count = (rows.firstOrNull?['count'] as int?) ?? 0;
    return count == 0;
  }

  SyncContext _buildContext(Map remote, Map? local, SyncAction action) {
    return SyncContext(
      remoteCollectionId: (local?['id'] as int?) ?? 0,
      localCalendarId: local?['local_collection_id']?.toString() ?? "",
      remotePath: remote['remote_path'] ?? local?['remote_path'] ?? "",
      accountName: local?['account_name'] ?? "",
      displayName: remote['display_name'] ?? local?['display_name'] ?? "未命名日历",
      color: remote['color'] ?? local?['color'] ?? "#AARRGGBB",
      syncMode: local?['sync_mode'] ?? remote['sync_mode'] ?? 0,
      action: action,
      ctag: remote['ctag'] ?? local?['synced_ctag'],
      isSubscription: remote['is_subscription'] ?? local?['is_subscription'] ?? false,
      extra: {
        'binding_id': local?['binding_id'] ?? 0,
        'binding_origin': local?['binding_origin'] ?? 0,
      },
    );
  }

  /// 引入一个回调函数，让 UI 能实时拿到 summary 对象
  Future<SyncSummary> executeFullSync({Function(SyncSummary)? onProgress}) async {
    final summary = SyncSummary();
    final String? loginName = MMKVUtils.instance.getString(AppConstant.loginNameKey);
    if (loginName == null) return summary;

    // 1. 扫描本地系统日历
    await _repo.scanLocalCalendars(loginName);
    await _repo.refreshAllLocalEvents(loginName);

    // 2. 发现云端新日历
    final List<Map<String, dynamic>> remoteCalendars = await _nc.scanRemoteCalendars(
        serverUrl: _authService.normalizedUrl,
        userId: loginName);

    // 3. 获取任务列表
    final List<SyncContext> tasks = await generateSyncTasks(loginName, remoteCalendars);

    debugPrint("====generateSyncTasks===$tasks");

    summary.reset(tasks.length);

    for (var originalCtx in tasks) {
      summary.processing++;
      onProgress?.call(summary);

      SyncContext ctx = originalCtx;

      // 2. 根据任务类型获取策略类
      final strategy = SyncStrategyFactory.getSyncStrategy(ctx.action);

      if (strategy != null) {
        try {
          await strategy.execute(ctx, summary);
        } catch (e) {
          summary.failed++;
          summary.errorLog.add("${ctx.displayName} 异常: $e");
        }
      } else {
        debugPrint("未定义的同步策略: ${ctx.action}");
      }

      onProgress?.call(summary);


      // try {
      //   // --- 💡 ID 洗白逻辑 ---
      //   // --- 💡 路径处理逻辑重构：针对回流场景的“先认亲，后新建” ---
      //   // 1. 获取当前远程路径
      //   String? currentRemotePath = ctx.remotePath;
      //
      //   // 2. 如果没有路径，去云端建一个（原来的逻辑）
      //   if (currentRemotePath == null || currentRemotePath.isEmpty) {
      //
      //   }
      //
      //   // 5. 获取云端快照
      //   final remoteItems = await _nc.fetchRemoteEvents(
      //       calendarPath: currentRemotePath);
      //   final Map<String, dynamic> remoteMap = {};
      //
      //   for (var item in remoteItems) {
      //     final href = item['href']?.toString() ?? "";
      //     if (href.endsWith('.ics')) {
      //       String extractedUid = item['remote_uid']?.toString() ?? "";
      //       if (extractedUid.isEmpty) {
      //         extractedUid = href.split('/').last.replaceAll('.ics', '');
      //       }
      //       item['remote_uid'] = extractedUid;
      //       remoteMap[extractedUid] = item;
      //     }
      //   }
      //
      //   // 6. 双向合并逻辑
      //   // 在这里，_processMerging 会通过补建逻辑 (v_ 判断) 把数据写入新创建的系统日历中
      //   await _processMerging(ctx, currentRemotePath, remoteMap);
      //
      //   // 标记为成功并记录展示名
      //   summary.success++;
      //   try {
      //     summary.successLog.add(ctx.displayName);
      //   } catch (_) {}
      // } catch (e) {
      //   // 记录失败并加入错误日志
      //   summary.failed++;
      //   try {
      //     summary.errorLog.add(ctx.displayName);
      //   } catch (_) {}
      //   print("❌ 同步异常 [${ctx.displayName}]: $e");
      // } finally {
      //   summary.processing--;
      //   onProgress?.call(summary);
      // }
    }
    return summary;
  }



  // 在 SyncEngine 类中
  Future<void> discoverRemoteCalendars(String userId) async {
    print("🔍 [云端发现] 开始扫描用户 $userId 的云端日历...");

    try {
      // 1. 获取云端当前真实的日历列表
      final List<Map<String, dynamic>> remoteCalendars = await _nc.scanRemoteCalendars(
        serverUrl: _authService.normalizedUrl,
        userId: userId);
      // 2. 提取云端路径集合，用于快速对比
      final Set<String> remotePaths = remoteCalendars
          .map((rc) => rc['remote_path'] as String)
          .toSet();

      // 2. 获取本地数据库中该用户已有的所有日历记录
      final db = await DatabaseHelper.instance.database;
      final List<Map<String, dynamic>> localRecords = await db.rawQuery(
        '''
        SELECT rc.*, lb.local_collection_id, lb.binding_origin
        FROM remote_collections rc
        LEFT JOIN local_bindings lb ON lb.remote_collection_id = rc.id
        WHERE rc.account_name = ?
          AND rc.remote_path IS NOT NULL
          AND rc.remote_path != ''
        ''',
        [userId],
      );

      // --- 💡 核心修复：同步删除逻辑 (本地有但云端没了) ---
      for (var local in localRecords) {
        final String accountName = local['account_name'] ?? '';
        final String? localRemotePath = local['remote_path'];
        final String localId = local['local_collection_id']?.toString() ?? '';
        final int bindingOrigin = (local['binding_origin'] as int?) ?? 0;
        final String displayName = local['display_name'];

        // 如果本地记录有远程路径，且该路径不在这次云端获取的列表中
        if (localRemotePath != null && !remotePaths.contains(localRemotePath)) {
          print("🗑️ [清理] 云端已不存在路径 $localRemotePath，同步删除本地: $displayName");

          // A. 仅删除“远端初始化”的本地系统日历；本地初始化(origin=0)保留
          if (bindingOrigin == 1 && localId.isNotEmpty) {
            try {
              await _native.deleteCalendar(localId,accountName);
              print("  ✅ 系统日历实体已移除: $localId");
            } catch (e) {
              print("  ⚠️ 系统日历移除失败 (可能已被手动删除): $e");
            }
          } else if (bindingOrigin != 1) {
            print("  ℹ️ 跳过系统日历删除: 本地初始化日历 (origin=$bindingOrigin)");
          }

          // B. 从数据库映射表中彻底抹除
          await db.delete(
            'remote_collections',
            where: 'id = ?',
            whereArgs: [local['id']],
          );
        }
      }

      // --- 4. 现有的更新与插入逻辑 ---
      for (var rc in remoteCalendars) {
        final String path = CaleeServerService.normalizeRemotePath((rc['remote_path'] ?? '').toString());
        if (path.isEmpty) continue;
        final String displayName = rc['display_name'] ?? '未命名';

        final List<Map<String, dynamic>> existing = await db.query(
          'remote_collections',
          where: 'remote_path = ?',
          whereArgs: [path],
        );

        if (existing.isNotEmpty) {
          // ✅ 场景 A: 路径已存在 -> 更新元数据
          print("🔗 [同步] 路径 $path 已匹配，更新元数据: $displayName");
          await db.update(
            'remote_collections',
            {
              'display_name': displayName,
              'account_name': userId,
              'is_subscription': (rc['is_subscription'] == true || rc['is_subscription'] == 1) ? 1 : 0,
              'subscription_url': rc['subscription_url'],
            },
            where: 'remote_path = ?',
            whereArgs: [path],
          );
        } else {
          // ✅ 场景 B: 全新云端日历 -> 插入新记录
          print("🆕 [云端发现] 创建新映射: $displayName");
          await db.insert('remote_collections', {
            'account_name': userId,
            'display_name': displayName,
            'remote_path': path,
            'sync_mode': rc['sync_mode'] ?? 0,
            'is_enabled': 0,
            'is_subscription': (rc['is_subscription'] == true || rc['is_subscription'] == 1) ? 1 : 0,
            'subscription_url': rc['subscription_url'],
          });
        }
      }

      print("✅ [云端发现] 扫描并清理完成。");

    } catch (e, stackTrace) {
      print("❌ [云端发现] 严重错误: $e");
      print(stackTrace);
    }
  }

  Future<void> _processMerging(SyncContext ctx, String currentRemotePath, Map<String, dynamic> remoteMap) async {
    final db = await DatabaseHelper.instance.database;

    // 1. 获取本地数据库中该日历下的所有同步记录
    final List<Map<String, dynamic>> locals = await db.query(
        'sync_items',
        where: 'remote_collection_id = ?',
        whereArgs: [ctx.remoteCollectionId]
    );

    print("--------------------------------------------------");
    print("🕵️ [同步监控] 开始对比日历: ${ctx.displayName} (remoteCollectionId: ${ctx.remoteCollectionId}, localCalendarId: ${ctx.localCalendarId})");
    print("🕵️ [同步状态] 账户同步开关 (syncStatus): ${ctx.syncStatus}");
    print("🕵️ [数据量] 本地库: ${locals.length} 条 | 云端返回: ${remoteMap.length} 条");

    for (var local in locals) {
      // 💡 容错处理：确保所有 ID 都是字符串，且状态有默认值
      final String uid = local['remote_uid']?.toString() ?? "";
      final int status = local['sync_status'] as int? ?? SyncItemStatus.synced;
      final String title = local['summary'] ?? "无标题";
      final String localId = local['local_item_id']?.toString() ?? "";
      final String? remoteHref = local['remote_href']?.toString();

      // --- 场景 A：本地标记为已删除 (Status 2) ---
      if (status == SyncItemStatus.pendingDelete) {
        print("\n🗑️ [删除] 正在同步删除云端日程: [$title]");
        final String deletePath = remoteHref ??
            "${currentRemotePath.endsWith('/') ? currentRemotePath : '$currentRemotePath/'}$uid.ics";

        try {
          bool success = await _nc.deleteEvent(eventPath: deletePath);
          if (success) {
            await db.delete('sync_items', where: 'remote_collection_id = ? AND remote_uid = ?', whereArgs: [ctx.remoteCollectionId, uid]);
            print("   -> ✅ 云端删除成功，本地映射已移除");
          }
        } catch (e) {
          print("   -> ❌ 云端删除失败: $e");
        }
        remoteMap.remove(uid);
        continue;
      }

      // --- 场景 B：两端都有的数据对比 ---
      print("\n🧐 正在检查本地日程: [$title] (LocalID: $localId)");
      bool existsInRemote = remoteMap.containsKey(uid);

      if (existsInRemote) {
        final remote = remoteMap[uid];

        if (status == SyncItemStatus.pendingPush) {
          print("   -> 🚀 判定动作: 本地修改，执行上传 (Push)");
          await _uploadToCloud(local, currentRemotePath);
        }
        // 1. 云端 ETag 变更，需要拉取更新
        else if (local['last_etag'] != remote['etag']) {
          print("   -> 📥 判定动作: 云端 ETag 变更，执行下载更新 (Pull)");
          await _downloadFromCloud(remote, ctx);
        }
        // 2. 🌟 关键补救：ETag 没变，但本地 local_id 还是 'v_' 开头（影子数据）
        // 且此时 ctx.syncStatus 为 1，说明用户刚开启同步，需要补建系统事件
        else if (ctx.syncStatus == 1 && localId.startsWith('v_')) {
          print("   -> 🏗️ 补救动作: 影子数据转系统事件 (补建)");
          await _downloadFromCloud(remote, ctx);
        }
        else {
          print("   -> ✅ 判定动作: 双端完全一致");
        }
        remoteMap.remove(uid);
      } else {
        // --- 场景 C：本地有但云端没有 ---
        if (status == SyncItemStatus.synced) {
          print("   -> 🗑️ 判定动作: 云端已删，清理本地记录");
          // 只有真实的系统 ID 才调用系统删除，虚拟 ID 只删本地库
          if (localId.isNotEmpty && !localId.startsWith('v_')) {
            try {
              await _native.deleteEvent(localId);
            } catch (e) {
              print("      ! 系统事件删除失败 (可能已手动删除): $e");
            }
          }
          await db.delete('sync_items', where: 'remote_collection_id = ? AND remote_uid = ?', whereArgs: [ctx.remoteCollectionId, uid]);
        } else if (status == SyncItemStatus.pendingPush) {
          print("   -> 🚀 判定动作: 本地新增，准备同步至云端");
          await _uploadToCloud(local, currentRemotePath);
        }
      }
    }

    // --- 场景 D：处理云端全新数据 (本地完全没有记录) ---
    if (remoteMap.isNotEmpty) {
      print("\n🚚 发现云端新增 ${remoteMap.length} 条数据，准备拉取...");
      for (var remote in remoteMap.values) {
        try {
          print("   -> 📥 拉取新事件: ${remote['remote_uid']}");
          await _downloadFromCloud(remote, ctx);
        } catch (e) {
          print("❌ 拉取事件 [${remote['remote_uid']}] 失败: $e");
        }
      }
    } else {
      print("\n🏁 无新增云端记录，同步完成。");
    }
  }

  // 推送本地到云端
// 修改参数，直接接收确定的 remotePath 字符串
  Future<void> _uploadToCloud(Map<String, dynamic> local, String remotePath) async {
    final ics = IcsGenerator.generate(local);

    // 💡 安全拼接路径：确保 remotePath 结尾有 /
    final String folderPath = remotePath.endsWith('/') ? remotePath : '$remotePath/';
    final String fullFilePath = "$folderPath${local['remote_uid']}.ics";

    print("🚀 准备上传至: $fullFilePath");

    final etag = await _nc.uploadEvent(
        path: fullFilePath,
        content: ics
    );

    if (etag != null) {
      await _repo.updateAfterSuccessfulPush(
        local['remote_uid'] as String,
        etag,
        remoteHref: fullFilePath, // 记录完整路径，方便后续维护
      );
    }
  }

  // 下载云端到本地
  Future<void> _downloadFromCloud(dynamic remote, SyncContext ctx) async {
    // final icsData = await _nc.getEventDetail(eventPath: remote['href']);
    // if (icsData == null) return;
    // final parsed = IcsParser.parse(icsData, remote['remote_uid']);
    //
    // String? systemEventId;
    //
    // // 💡 只有当：1. 用户勾选了同步  且 2. 日历 ID 已经洗白成数字
    // // 我们才真正调用原生 API 在手机系统里创建事件
    // if (ctx.syncStatus == 1) {
    //   try {
    //     systemEventId = await _native.createEvent(
    //       ctx.localCalendarId, // 必须是数字字符串，如 "6"
    //       parsed['summary'],
    //       parsed['dtstart'],
    //       parsed['dtend'],
    //       parsed['description'],
    //       remote['remote_uid'],
    //     );
    //     print("✅ 原生事件创建成功: $systemEventId");
    //   } catch (e) {
    //     print("❌ 原生创建失败 (可能是权限问题): $e");
    //   }
    // }
    //
    // // 更新数据库（无论原生是否成功，都要更新数据库里的信息，确保 Dashboard 正确）
    // final db = await DatabaseHelper.instance.database;
    // await db.insert('sync_items', {
    //   'remote_uid': remote['remote_uid'],
    //   'local_item_id': systemEventId ?? 'v_${remote['remote_uid']}', // 有系统 ID 用系统 ID，没有用虚拟
    //   'remote_collection_id': ctx.localCalendarId,
    //   'last_etag': remote['etag'],
    //   'summary': parsed['summary'],
    //   'dtstart': parsed['dtstart'],
    //   'dtend': parsed['dtend'],
    //   'sync_status': ctx.syncStatus,
    // }, conflictAlgorithm: ConflictAlgorithm.replace);
  }
}
