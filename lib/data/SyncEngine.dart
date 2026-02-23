import 'package:caleesync/common/app_constant.dart';
import 'package:caleesync/common/utils/mmkv_utils.dart';
import 'package:caleesync/core/platform/pigeon/calendar_api.g.dart';
import 'package:caleesync/data/sync_repository.dart';
import 'package:sqflite/sqflite.dart';

import '../common/utils/IcsGenerator.dart';
import '../common/utils/IcsParser.dart';
import '../entity/SyncContext.dart';
import '../entity/SyncSummary.dart';
import '../services/nextcloud_auth_service.dart';
import '../services/nextcloud_service.dart';
import 'database_helper.dart';

class SyncEngine {
  final SyncRepository _repo = SyncRepository();
  final NextcloudService _nc = NextcloudService();
  final NativeCalendarApi _native = NativeCalendarApi();
  final NextcloudAuthService _authService = NextcloudAuthService(serverBaseUrl: AppConstant.nextcloudServer);

  /// 引入一个回调函数，让 UI 能实时拿到 summary 对象
  Future<SyncSummary> executeFullSync({Function(SyncSummary)? onProgress}) async {
    final summary = SyncSummary();
    final String? loginName = MMKVUtils.instance.getString(AppConstant.loginName);
    if (loginName == null) return summary;

    // 1. 扫描本地系统日历
    await _repo.scanLocalCalendars(loginName);

    // 2. 发现云端新日历
    await discoverRemoteCalendars(loginName);

    // 3. 获取任务列表
    final List<SyncContext> tasks = await _repo.prepareSyncContexts();
    summary.reset(tasks.length);

    for (var originalCtx in tasks) {
      summary.processing++;
      onProgress?.call(summary);

      SyncContext ctx = originalCtx;
      // 💡 关键变量：记录这次循环是否刚刚完成了 ID 洗白
      bool isJustConverted = false;

      try {
        // --- 💡 ID 洗白逻辑 ---
        // --- 💡 路径处理逻辑重构：针对回流场景的“先认亲，后新建” ---
        // 1. 获取当前远程路径
        String? currentRemotePath = ctx.remotePath;

        // 2. 如果没有路径，去云端建一个（原来的逻辑）
        if (currentRemotePath == null || currentRemotePath.isEmpty) {
          final String safeId = ctx.calendarId.replaceAll('rc_', '');
          String targetPathId = "calee_$safeId";

          currentRemotePath = await _nc.createRemoteCalendar(
            userId: loginName,
            calendarName: ctx.displayName,
            calendarId: targetPathId,
          );

          if (currentRemotePath != null) {
            await _repo.updateRemotePath(ctx.calendarId, currentRemotePath);
            print("✅ 成功绑定云端路径: $currentRemotePath");
          }
        }

        // 3. 🌟 【核心修正】独立判断：只要本地还是 rc_ 影子 ID，就必须补建本地系统日历
        if (ctx.calendarId.startsWith('rc_')) {
          print("🛠️ 检测到影子 ID (${ctx.calendarId})，准备洗白为系统日历...");

          final String? systemId = await _native.createCalendar(ctx.displayName, loginName);

          if (systemId != null) {
            // 内存洗白
            ctx = ctx.copyWith(calendarId: systemId);
            // 数据库洗白（重要：确保你已经写了 updateSystemCalendarId 方法）
            await _repo.updateSystemCalendarId(originalCtx.calendarId, systemId);

            print("✅ 本地系统日历洗白完成，新 ID: $systemId");
          } else {
            print("❌ 本地系统日历创建失败");
          }
        }

        // --- 🌟 关键安全检查：彻底杜绝 Null check operator 错误 ---
        if (currentRemotePath == null || currentRemotePath.isEmpty) {
          print("❌ 无法确定日历 [${ctx.displayName}] 的远程路径，跳过同步");
          continue;
        }

        print("🚀 开始处理日历: ${ctx.displayName} (Status: ${ctx.syncStatus})");

        // --- 💡 修正 4. 本地变更捕获 (逻辑不变) ---
        if (ctx.syncStatus == 1 && !ctx.calendarId.startsWith('rc_')) {
          if (!isJustConverted) {
            print("🔍 正在扫描系统日历变更...");
            await _repo.scanSystemChanges(ctx);
          }
        }
        // 5. 获取云端快照
        final remoteItems = await _nc.fetchRemoteEvents(
            calendarPath: currentRemotePath);
        final Map<String, dynamic> remoteMap = {};

        for (var item in remoteItems) {
          final href = item['href']?.toString() ?? "";
          if (href.endsWith('.ics')) {
            String extractedUid = item['uid']?.toString() ?? "";
            if (extractedUid.isEmpty) {
              extractedUid = href.split('/').last.replaceAll('.ics', '');
            }
            item['uid'] = extractedUid;
            remoteMap[extractedUid] = item;
          }
        }

        // 6. 双向合并逻辑
        // 在这里，_processMerging 会通过补建逻辑 (v_ 判断) 把数据写入新创建的系统日历中
        await _processMerging(ctx, currentRemotePath, remoteMap);

        // 标记为成功并记录展示名
        summary.success++;
        try {
          summary.successLog.add(ctx.displayName);
        } catch (_) {}
      } catch (e) {
        // 记录失败并加入错误日志
        summary.failed++;
        try {
          summary.errorLog.add(ctx.displayName);
        } catch (_) {}
        print("❌ 同步异常 [${ctx.displayName}]: $e");
      } finally {
        summary.processing--;
        onProgress?.call(summary);
      }
    }
    return summary;
  }

  // 在 SyncEngine 类中
  Future<void> discoverRemoteCalendars(String userId) async {
    print("🔍 [云端发现] 开始扫描用户 $userId 的云端日历...");

    try {
      final String password = MMKVUtils.instance.getString(AppConstant.password) ?? "";

      // 1. 获取云端当前真实的日历列表
      final List<Map<String, dynamic>> remoteCalendars = await _nc.fetchRemoteCalendars(
        serverUrl: _authService.normalizedUrl,
        userId: userId,
        password: password,
      );

      // 🛡️ 安全阀：如果云端请求彻底失败（抛出异常会进 catch），
      // 但如果接口返回成功却为空，需根据业务判断。这里假设用户至少有一个主日历。
      // 如果返回空且没有任何异常，说明云端确实清空了。

      final db = await DatabaseHelper.instance.database;

      // 2. 获取本地数据库中该用户已有的所有日历记录
      final List<Map<String, dynamic>> localRecords = await db.query(
        'calendar_map',
        where: 'account_name = ?',
        whereArgs: [userId],
      );

      // 3. 提取云端路径集合，用于快速对比
      final Set<String> remotePaths = remoteCalendars
          .map((rc) => rc['remote_path'] as String)
          .toSet();

      // --- 💡 核心修复：同步删除逻辑 (本地有但云端没了) ---
      for (var local in localRecords) {
        final String accountName = local['account_name'] ?? '';
        final String accountType = local['account_type'] ?? '';
        final String? localRemotePath = local['remote_path'];
        final String localId = local['local_id'];
        final String displayName = local['display_name'];

        // 如果本地记录有远程路径，且该路径不在这次云端获取的列表中
        if (localRemotePath != null && !remotePaths.contains(localRemotePath)) {
          print("🗑️ [清理] 云端已不存在路径 $localRemotePath，同步删除本地: $displayName");

          // A. 如果已经洗白成系统日历，调用原生接口从系统日历 App 中删除
          if (!localId.startsWith('rc_')) {
            try {
              await _native.deleteCalendar(localId,accountName,accountType);
              print("  ✅ 系统日历实体已移除: $localId");
            } catch (e) {
              print("  ⚠️ 系统日历移除失败 (可能已被手动删除): $e");
            }
          }

          // B. 从数据库映射表中彻底抹除
          await db.delete(
            'calendar_map',
            where: 'local_id = ?',
            whereArgs: [localId],
          );
        }
      }

      // --- 4. 现有的更新与插入逻辑 ---
      for (var rc in remoteCalendars) {
        final String path = rc['remote_path'];
        final String displayName = rc['display_name'] ?? '未命名';

        final List<Map<String, dynamic>> existing = await db.query(
          'calendar_map',
          where: 'remote_path = ?',
          whereArgs: [path],
        );

        if (existing.isNotEmpty) {
          // ✅ 场景 A: 路径已存在 -> 更新元数据
          print("🔗 [同步] 路径 $path 已匹配，更新元数据: $displayName");
          await db.update(
            'calendar_map',
            {
              'display_name': displayName,
              'account_name': userId,
              'account_type': 'com.nextcloud.caleesync',
            },
            where: 'remote_path = ?',
            whereArgs: [path],
          );
        } else {
          final List<Map<String, dynamic>> orphans = await db.query(
            'calendar_map',
            where: 'display_name = ? AND account_name = ? AND remote_path IS NULL',
            whereArgs: [displayName, userId],
          );
          if (orphans.isNotEmpty) {
            final String orphanLocalId = orphans.first['local_id'];
            print("♻️ [认领] 发现残留本地日历 $displayName ($orphanLocalId)，正在绑定路径...");
            await db.update(
              'calendar_map',
              {
                'remote_path': path,
                'sync_status': 1, // 既然有 local_id 了，说明是已存在的系统日历，设为已洗白
              },
              where: 'local_id = ?',
              whereArgs: [orphanLocalId],
            );
          } else {
            // ✅ 场景 B: 全新云端日历 -> 插入新记录
            print("🆕 [云端发现] 创建新映射: $displayName");
            final String virtualId = 'rc_${DateTime.now().millisecondsSinceEpoch}_${path.hashCode % 1000}';
            await db.insert('calendar_map', {
              'local_id': virtualId,
              'account_name': userId,
              'account_type': 'com.nextcloud.caleesync',
              'display_name': displayName,
              'remote_path': path,
              'sync_status': 0, // 初始状态，等待后续同步洗白
            });
          }
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
        'sync_map',
        where: 'calendar_local_id = ?',
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
      final String localId = local['local_id']?.toString() ?? "";
      final String? remoteHref = local['remote_href']?.toString();

      // --- 场景 A：本地标记为已删除 (Status 2) ---
      if (status == 2) {
        print("\n🗑️ [删除] 正在同步删除云端日程: [$title]");
        final String deletePath = remoteHref ??
            "${currentRemotePath.endsWith('/') ? currentRemotePath : '$currentRemotePath/'}$uid.ics";

        try {
          bool success = await _nc.deleteEvent(eventPath: deletePath);
          if (success) {
            await db.delete('sync_map', where: 'uid = ?', whereArgs: [uid]);
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
        if (status == 0) {
          print("   -> 🗑️ 判定动作: 云端已删，清理本地记录");
          // 只有真实的系统 ID 才调用系统删除，虚拟 ID 只删本地库
          if (localId.isNotEmpty && !localId.startsWith('v_')) {
            try {
              await _native.deleteEvent(localId);
            } catch (e) {
              print("      ! 系统事件删除失败 (可能已手动删除): $e");
            }
          }
          await db.delete('sync_map', where: 'uid = ?', whereArgs: [uid]);
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
    final icsData = await _nc.getEventDetail(eventPath: remote['href']);
    if (icsData == null) return;
    final parsed = IcsParser.parse(icsData, remote['uid']);

    String? systemEventId;

    // 💡 只有当：1. 用户勾选了同步  且 2. 日历 ID 已经洗白成数字
    // 我们才真正调用原生 API 在手机系统里创建事件
    if (ctx.syncStatus == 1 && !ctx.calendarId.startsWith('rc_')) {
      try {
        systemEventId = await _native.createEvent(
          ctx.calendarId, // 必须是数字字符串，如 "6"
          parsed['summary'],
          parsed['dtstart'],
          parsed['dtend'],
          parsed['description'],
          remote['uid'],
        );
        print("✅ 原生事件创建成功: $systemEventId");
      } catch (e) {
        print("❌ 原生创建失败 (可能是权限问题): $e");
      }
    }

    // 更新数据库（无论原生是否成功，都要更新数据库里的信息，确保 Dashboard 正确）
    final db = await DatabaseHelper.instance.database;
    await db.insert('sync_map', {
      'uid': remote['uid'],
      'local_id': systemEventId ?? 'v_${remote['uid']}', // 有系统 ID 用系统 ID，没有用虚拟
      'calendar_local_id': ctx.calendarId,
      'last_etag': remote['etag'],
      'summary': parsed['summary'],
      'dtstart': parsed['dtstart'],
      'dtend': parsed['dtend'],
      'sync_status': ctx.syncStatus,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }
}