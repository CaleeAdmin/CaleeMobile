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
import 'factory/SyncStrategyFactory.dart';

class SyncEngine {
  final SyncRepository _repo = SyncRepository();
  final CaleeServerService _nc = CaleeServerService();
  final NativeCalendarApi _native = NativeCalendarApi();
  final CaleeAuthService _authService = CaleeAuthService(serverBaseUrl: AppConstant.caleeServer);
  final DatabaseHelper _dbHelper = DatabaseHelper.instance;

  //依赖表格 https://docs.google.com/spreadsheets/d/1QG-OfRUdYpY5G-_rrLWNYgUVUaAKNnHNQDPPexwckHE/edit?gid=975224459#gid=975224459
  Future<List<SyncContext>> generateSyncTasks(
      String userId,
      List<Map<String, dynamic>> remoteResults,
      ) async {
    // 1. 获取该用户下的所有本地数据库记录（包含状态为 2 的记录）
    final db = await _dbHelper.database;
    final List<Map<String, dynamic>> localRecords = await db.query(
      'remote_collections',
      where: 'account_name = ? AND remote_path IS NOT NULL AND remote_path != ""',
      whereArgs: [userId],
    );

    List<SyncContext> contexts = [];

    // 2. 建立索引
    final remoteMap = {for (var r in remoteResults) r['remote_path'] as String: r};
    final localMapByPath = {
      for (var l in localRecords)
        if (l['remote_path'] != null && (l['remote_path'] as String).isNotEmpty)
          l['remote_path'] as String: l
    };

    // --- 策略 A：处理远端发现的日历 (针对：同步、初始化) ---
    for (var remote in remoteResults) {
      final path = remote['remote_path'];
      final local = localMapByPath[path];

      if (local == null) {
        contexts.add(_buildContext(remote, null, SyncAction.createLocal));
        continue;
      }

      final int isEnabled = local['is_enabled'] ?? 0;
      final int origin = local['origin'] ?? 0;
      final int mode = local['sync_mode'] ?? 0;
      final String localId = local['local_id'] ?? '';

      if (localId.isEmpty) {
        if (isEnabled == 1) {
          contexts.add(_buildContext(remote, local, SyncAction.createLocal));
        }
        continue;
      }

      if (isEnabled == 1) {
        final String? dbCtag = local['ctag'];
        final String? remoteCtag = remote['ctag'];
        final bool remoteChanged = (remoteCtag != null && remoteCtag != dbCtag);
        final bool localChanged = await _isCalendarDirty(db, localId);
        final bool metaChanged = remote['displayname'] != local['display_name'] ||
            remote['color'] != local['color'];

        final bool shouldSync;
        final SyncAction action;

        if (mode == 1) {
          // 双向同步：任意一端变化都应触发
          shouldSync = remoteChanged || localChanged || metaChanged;
          action = SyncAction.fullSyncBidi;
        } else if (origin == 1) {
          // 只读映射（远端起源）：仅允许远端 -> 本地
          shouldSync = remoteChanged || metaChanged;
          action = SyncAction.fullSyncPull;
        } else {
          // 只读映射（本地起源）：仅允许本地 -> 远端
          shouldSync = localChanged;
          action = SyncAction.fullSyncPush;
        }

        if (!shouldSync) {
          debugPrint("💤 日历无可同步变动，跳过任务生成: ${remote['displayname']}");
          continue;
        }

        contexts.add(_buildContext(remote, local, action));
      }
    }

    // --- 策略 B：以本地数据库记录为准 (针对：远端删除兜底) ---
    for (var local in localRecords) {
      final String? path = local['remote_path'];
      final int origin = local['origin'] ?? 0;
      final int mode = local['sync_mode'] ?? 0;

      if (path == null || path.isEmpty) {
        debugPrint('⏭️ 跳过无远端路径记录: ${local['local_id']}');
        continue;
      }

      final bool remoteExists = remoteMap.containsKey(path);
      if (!remoteExists && (origin == 1 || (origin == 0 && mode == 1))) {
        contexts.add(_buildContext({}, local, SyncAction.deleteLocal));
      }
    }

    return contexts;
  }

  Future<bool> _isCalendarDirty(Database db, String localId) async {
    // 这里的状态码对应：1 (Dirty/Modified), 2 (Deleted)
    final List<Map<String, dynamic>> dirtyCheck = await db.rawQuery('''
    SELECT 1 FROM sync_items
    WHERE remote_collection_id = ? AND sync_status IN (1, 2)
    LIMIT 1
  ''', [localId]);
    return dirtyCheck.isNotEmpty;
  }

  SyncContext _buildContext(Map remote, Map? local, SyncAction action) {
    return SyncContext(
      calendarId: local?['local_id'] ?? "",
      remotePath: remote['remote_path'] ?? local?['remote_path'] ?? "",
      accountName: local?['account_name'] ?? "",
      accountType: local?['account_type'] ?? "", // 从数据库字段读取，不再从参数传
      displayName: remote['display_name'] ?? local?['display_name'] ?? "未命名日历",
      color: remote['color'] ?? local?['color'] ?? "#AARRGGBB",
      syncMode: local?['sync_mode'] ?? remote['sync_mode'] ?? 0,
      action: action,
      ctag: remote['ctag'] ?? local?['ctag'],
      isSubscription: remote['is_subscription'] ?? false,
      extra: {
        'origin': local?['origin'] ?? 0,
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
      final strategy = SyncStrategyFactory.getStrategy(ctx.action);

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
      //       String extractedUid = item['uid']?.toString() ?? "";
      //       if (extractedUid.isEmpty) {
      //         extractedUid = href.split('/').last.replaceAll('.ics', '');
      //       }
      //       item['uid'] = extractedUid;
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
      final List<Map<String, dynamic>> localRecords = await db.query(
        'remote_collections',
        where: 'account_name = ? AND remote_path IS NOT NULL AND remote_path != ""',
        whereArgs: [userId],
      );

      // --- 💡 核心修复：同步删除逻辑 (本地有但云端没了) ---
      for (var local in localRecords) {
        final String accountName = local['account_name'] ?? '';
        final String? localRemotePath = local['remote_path'];
        final String localId = local['local_id']?.toString() ?? '';
        final String displayName = local['display_name'];

        // 如果本地记录有远程路径，且该路径不在这次云端获取的列表中
        if (localRemotePath != null && !remotePaths.contains(localRemotePath)) {
          print("🗑️ [清理] 云端已不存在路径 $localRemotePath，同步删除本地: $displayName");

          // A. 如果已经洗白成系统日历，调用原生接口从系统日历 App 中删除
          if (localId.isNotEmpty) {
            try {
              await _native.deleteCalendar(localId,accountName);
              print("  ✅ 系统日历实体已移除: $localId");
            } catch (e) {
              print("  ⚠️ 系统日历移除失败 (可能已被手动删除): $e");
            }
          }

          // B. 从数据库映射表中彻底抹除
          await db.delete(
            'remote_collections',
            where: localId.isNotEmpty ? 'local_id = ?' : 'remote_path = ?',
            whereArgs: [localId.isNotEmpty ? localId : localRemotePath],
          );
        }
      }

      // --- 4. 现有的更新与插入逻辑 ---
      for (var rc in remoteCalendars) {
        final String path = rc['remote_path'];
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
              'account_type': 'com.viso.caleesync',
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
            'account_type': 'com.viso.caleesync',
            'display_name': displayName,
            'remote_path': path,
            'sync_mode': rc['sync_mode'] ?? 0,
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
        whereArgs: [ctx.calendarId]
    );

    print("--------------------------------------------------");
    print("🕵️ [同步监控] 开始对比日历: ${ctx.displayName} (ID: ${ctx.calendarId})");
    print("🕵️ [同步状态] 账户同步开关 (syncStatus): ${ctx.syncStatus}");
    print("🕵️ [数据量] 本地库: ${locals.length} 条 | 云端返回: ${remoteMap.length} 条");

    for (var local in locals) {
      // 💡 容错处理：确保所有 ID 都是字符串，且状态有默认值
      final String uid = local['uid']?.toString() ?? "";
      final int status = local['sync_status'] as int? ?? 0;
      final String title = local['summary'] ?? "无标题";
      final String localId = local['local_item_id']?.toString() ?? "";
      final String? remoteHref = local['remote_href']?.toString();

      // --- 场景 A：本地标记为已删除 (Status 2) ---
      if (status == 2) {
        print("\n🗑️ [删除] 正在同步删除云端日程: [$title]");
        final String deletePath = remoteHref ??
            "${currentRemotePath.endsWith('/') ? currentRemotePath : '$currentRemotePath/'}$uid.ics";

        try {
          bool success = await _nc.deleteEvent(eventPath: deletePath);
          if (success) {
            await db.delete('sync_items', where: 'uid = ?', whereArgs: [uid]);
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

        if (status == 1) {
          print("   -> 🚀 判定动作: 本地修改，执行上传 (Push)");
          await _uploadToCloud(local, currentRemotePath);
        }
        // 1. 云端 ETag 变更，需要拉取更新
        else if (local['remote_etag'] != remote['etag']) {
          print("   -> 📥 判定动作: 云端 ETag 变更，执行下载更新 (Pull)");
          await _downloadFromCloud(remote, ctx);
        }
        else {
          print("   -> ✅ 判定动作: 双端完全一致");
        }
        remoteMap.remove(uid);
      } else {
        // --- 场景 C：本地有但云端没有 ---
        if (status == 0) {
          print("   -> 🗑️ 判定动作: 云端已删，清理本地记录");
          if (localId.isNotEmpty) {
            try {
              await _native.deleteEvent(localId);
            } catch (e) {
              print("      ! 系统事件删除失败 (可能已手动删除): $e");
            }
          }
          await db.delete('sync_items', where: 'uid = ?', whereArgs: [uid]);
        } else if (status == 1) {
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
          print("   -> 📥 拉取新事件: ${remote['uid']}");
          await _downloadFromCloud(remote, ctx);
        } catch (e) {
          print("❌ 拉取事件 [${remote['uid']}] 失败: $e");
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
    final String fullFilePath = "$folderPath${local['uid']}.ics";

    print("🚀 准备上传至: $fullFilePath");

    final etag = await _nc.uploadEvent(
        path: fullFilePath,
        content: ics
    );

    if (etag != null) {
      await _repo.updateAfterSuccessfulPush(
        local['uid'] as String,
        etag,
        remoteHref: fullFilePath, // 记录完整路径，方便后续维护
      );
    }
  }

  // 下载云端到本地
  Future<void> _downloadFromCloud(dynamic remote, SyncContext ctx) async {
    // final icsData = await _nc.getEventDetail(eventPath: remote['href']);
    // if (icsData == null) return;
    // final parsed = IcsParser.parse(icsData, remote['uid']);
    //
    // String? systemEventId;
    //
    // // 💡 只有当：1. 用户勾选了同步  且 2. 日历 ID 已经洗白成数字
    // // 我们才真正调用原生 API 在手机系统里创建事件
    // if (ctx.syncStatus == 1) {
    //   try {
    //     systemEventId = await _native.createEvent(
    //       ctx.calendarId, // 必须是数字字符串，如 "6"
    //       parsed['summary'],
    //       parsed['dtstart'],
    //       parsed['dtend'],
    //       parsed['description'],
    //       remote['uid'],
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
    //   'uid': remote['uid'],
    //   'local_item_id': systemEventId ?? 'v_${remote['uid']}', // 有系统 ID 用系统 ID，没有用虚拟
    //   'remote_collection_id': ctx.calendarId,
    //   'remote_etag': remote['etag'],
    //   'summary': parsed['summary'],
    //   'dtstart': parsed['dtstart'],
    //   'dtend': parsed['dtend'],
    //   'sync_status': ctx.syncStatus,
    // }, conflictAlgorithm: ConflictAlgorithm.replace);
  }
}
