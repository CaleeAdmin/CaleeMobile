import 'dart:convert';

import 'package:caleesync/common/app_constant.dart';
import 'package:caleesync/common/utils/mmkv_utils.dart';
import 'package:caleesync/core/platform/pigeon/calendar_api.g.dart';
import 'package:caleesync/data/sync_repository.dart';
import 'package:flutter/cupertino.dart';
import 'package:http/http.dart' as http;
import 'package:sqflite/sqflite.dart';

import '../common/enums/SyncEnum.dart';
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
  final DatabaseHelper _dbHelper = DatabaseHelper.instance;

  //依赖表格 https://docs.google.com/spreadsheets/d/1QG-OfRUdYpY5G-_rrLWNYgUVUaAKNnHNQDPPexwckHE/edit?gid=975224459#gid=975224459
  Future<List<SyncContext>> generateSyncTasks(
      String userId,
      List<Map<String, dynamic>> remoteResults,
      ) async {
    // 1. 获取该用户下的所有本地日历记录
    final db = await _dbHelper.database;
    final List<Map<String, dynamic>> localRecords = await db.query(
      'calendar_map',
      where: 'account_name = ?',
      whereArgs: [userId],
    );

    debugPrint("==remoteResults==${remoteResults}");
    debugPrint("==localRecords==${localRecords}");

    List<SyncContext> contexts = [];

    // 2. 建立远端索引 (href -> remoteMap)
    final remoteMap = {for (var r in remoteResults) r['remote_path'] as String: r};

    // 3. 建立本地索引 (remote_path -> localMap)
    final localMapByPath = {
      for (var l in localRecords)
        if (l['remote_path'] != null && (l['remote_path'] as String).isNotEmpty)
          l['remote_path'] as String: l
    };

    // --- 策略 A：以远端发现为准 (涵盖场景 2, 3, 4, 5, 6, 11, 12, 13, 14) ---
    for (var remote in remoteResults) {
      final path = remote['remote_path'];
      final local = localMapByPath[path];
      debugPrint("===local==$local");
      //I/flutter (21325): ===local=={local_id: null, account_name: yiwen, account_type: null, remote_path: /remote.php/dav/calendars/yiwen/personal/, display_name: Personal, color: null, last_ctag: http://sabre.io/ns/sync/43, sync_mode: 0, is_enabled: 0, is_provisioned: 0, origin: 1}
      if (local == null) {
        // 【场景 2】：云端有新坑，本地无记录 -> createLocal
        contexts.add(_buildContext(remote, null, SyncAction.createLocal));
      } else {
        // 🛡️ 核心修复：即使本地有记录，但如果 local_id 为空，说明系统日历尚未初始化
        if (local['local_id'] == null) {
          debugPrint("⚠️ 发现本地占位记录但无系统 ID，触发创建动作: $path");
          // 强制走创建流程，让原生端去生成 calendarId 并回填数据库
          contexts.add(_buildContext(remote, local, SyncAction.createLocal));
          continue; // 处理完这个，跳过后续的同步判定
        }

        // 只有 local_id 存在时，下方的同步模式判定才有意义
        final int origin = local['origin'] ?? 0;
        final int mode = local['sync_mode'] ?? 0;

        // 这里的逻辑保持你原来的业务判定
        final bool isPendingDeletion = false;

        SyncAction action;
        if (isPendingDeletion) {
          action = (mode == 0) ? SyncAction.deleteRemote : SyncAction.deleteLocal;
        } else {
          // 这里的 fullSync 系列动作前提是 local_id 必须已经有效
          if (mode == 0) {
            action = SyncAction.fullSyncBidi;
          } else {
            action = (origin == 1) ? SyncAction.fullSyncPull : SyncAction.fullSyncPush;
          }
        }
        contexts.add(_buildContext(remote, local, action));
      }
    }

    // --- 策略 B：以本地记录为准，查漏补缺 (涵盖场景 1, 7, 8, 9, 10) ---
    for (var local in localRecords) {
      final String? path = local['remote_path'];
      final bool remoteExists = (path != null && path.isNotEmpty) && remoteMap.containsKey(path);

      if (!remoteExists) {
        final int origin = local['origin'] ?? 0;
        final int mode = local['sync_mode'] ?? 0;

        if (path == null || path.isEmpty) {
          // 【场景 1】：本地新建日历，remote_path 尚未分配 -> createRemote
          contexts.add(_buildContext({}, local, SyncAction.createRemote));
        } else {
          // 远端路径在最新扫描中消失了
          if (mode == 1) {
            if (origin == 1) {
              // 【场景 7】：远程源消失 (ReadOnly) -> deleteLocal
              contexts.add(_buildContext({}, local, SyncAction.deleteLocal));
            } else {
              // 【场景 8】：远程源消失 (母本保护) -> ignore
              contexts.add(_buildContext({}, local, SyncAction.ignore));
            }
          } else {
            // 【场景 9, 10】：双向日历远端删，本地跟进 -> deleteLocal
            contexts.add(_buildContext({}, local, SyncAction.deleteLocal));
          }
        }
      }
    }
    return contexts;
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
      ctag: remote['last_ctag'] ?? local?['last_ctag'],
      extra: {
        'is_provisioned': local?['is_provisioned'] ?? 0,
        'origin': local?['origin'] ?? 0,
      },
    );
  }

  /// 引入一个回调函数，让 UI 能实时拿到 summary 对象
  Future<SyncSummary> executeFullSync({Function(SyncSummary)? onProgress}) async {
    final summary = SyncSummary();
    final String? loginName = MMKVUtils.instance.getString(AppConstant.loginName);
    if (loginName == null) return summary;

    // 1. 扫描本地系统日历
    await _repo.scanLocalCalendars(loginName);

    // 2. 发现云端新日历
    final List<Map<String, dynamic>> remoteCalendars = await _nc.scanRemoteCalendars(
        serverUrl: _authService.normalizedUrl,
        userId: loginName);

    // 3. 获取任务列表
    final List<SyncContext> tasks = await generateSyncTasks(loginName, remoteCalendars);
    summary.reset(tasks.length);

    for (var originalCtx in tasks) {
      summary.processing++;
      onProgress?.call(summary);

      SyncContext ctx = originalCtx;

      switch (ctx.action) {

      // --- 【场景 1】：本地 -> 云端 (新建) ---
        case SyncAction.createRemote:
          final String safeId = ctx.calendarId.replaceAll('rc_', '');
          // 建议对 ID 进行一次 URL 编码安全处理
          final String targetPathId = "calee_${Uri.encodeComponent(safeId)}";

          // 调用创建接口
          final resultPath = await _nc.createRemoteCalendar(
            userId: loginName,
            calendarName: ctx.displayName,
            calendarId: targetPathId,
            color: ctx.color, // 记得带上我们之前讨论的颜色
          );
          if (resultPath != null) {
            final db = await _dbHelper.database;

            // 2. 扩大扫描窗口，确保存量数据全部覆盖
            // 首次上云：取过去 2 年到未来 10 年
            final start = DateTime.now().subtract(const Duration(days: 30)).millisecondsSinceEpoch;
            final end = DateTime.now().add(const Duration(days: 30)).millisecondsSinceEpoch;

            // 3. 抓取本地系统日程
            final List<PlatformItem?> items = await _native.getEvents(ctx.calendarId, start, end);
            final currentEvents = items.whereType<PlatformItem>().toList();

            print("[Sync] 正在为新日历推送 ${currentEvents.length} 条存量日程...");

            // 4. 遍历并执行 Initial Push (建议串行或限制并发)
            for (var event in currentEvents) {
              // 1. 提取并处理空值
              final String uid = event.uid ?? "";
              final String title = event.title ?? "无标题";
              final int startTime = event.startTime ?? DateTime.now().millisecondsSinceEpoch;
              final int endTime = event.endTime ?? startTime + 3600000; // 默认 1 小时后

              // 2. 执行上传
              final String? etag = await _nc.uploadEventData(
                userId: loginName,
                calendarPath: resultPath,
                uid: uid, // 现在是 String
                title: title,
                start: DateTime.fromMillisecondsSinceEpoch(startTime), // 现在是 int
                end: DateTime.fromMillisecondsSinceEpoch(endTime),
              );

              if (etag != null) {
                // 3. 写入 sync_map
                await db.insert('sync_map', {
                  'uid': uid,
                  'local_id': event.localId,
                  'calendar_local_id': ctx.calendarId,
                  'summary': title,
                  'description': event.notes,
                  'dtstart': startTime,
                  'dtend': endTime,
                  'last_etag': etag,
                  'last_mtime': event.lastModified ?? 0,
                  'remote_href': "${resultPath.endsWith('/') ? resultPath : '$resultPath/'}$uid.ics",
                  'sync_status': 0,
                }, conflictAlgorithm: ConflictAlgorithm.replace);
              }
            }

            await db.update('calendar_map',
                {
                  'remote_path': resultPath,   // 核心：存入刚开好的云端坑位路径
                  'is_provisioned': 1,         // 激活：本地是母本，开坑即就绪
                },
                where: 'local_id = ?',
                whereArgs: [ctx.calendarId]
            );
            summary.success++;
          }
          break;
        case SyncAction.createLocal:
          print('🚀 开始执行 createLocal: ${ctx.displayName}');

          // 1. 在 Android 系统侧创建日历坑位
          final int colorValue = int.tryParse(ctx.color.replaceAll('#', '0x')) ?? 0xFF2196F3;

          final String? newLocalId = await _native.createCalendar(
            ctx.displayName ,
            loginName,
            colorValue,
          );

          if (newLocalId == null) {
            print('❌ 原生创建日历失败');
            summary.failed++;
            break;
          }

          final db = await _dbHelper.database;

          // 2. 立即关联本地 ID 并更新状态，防止后续流程崩溃导致重复创建日历
          await db.update('calendar_map', {
            'local_id': newLocalId,
            'is_enabled': 1,      // 既然是同步下来的，默认开启
            'is_provisioned': 0,  // 标记为“洗白中”，尚未完成初始拉取
          }, where: 'remote_path = ?', whereArgs: [ctx.remotePath]);

          // 3. 准备批量下载环境 (复用 Client 提升性能)
          final client = http.Client();
          final String auth = 'Basic ${base64Encode(utf8.encode('$loginName:${MMKVUtils.instance.getString(AppConstant.password)}'))}';

          try {
            // 4. 获取远端该日历下所有事件的列表 (Href 和 ETag)
            final List<Map<String, dynamic>> remoteEvents = await _nc.fetchRemoteEvents(
              calendarPath: ctx.remotePath,
            );

            int eventSuccessCount = 0;

            for (var remote in remoteEvents) {
              final String href = remote['href'];
              final String etag = remote['etag'];

              // 5. 调用你复用的 getEventDetail 下载具体的 .ics 内容
              final icsData = await _nc.getEventDetail(
                client: client,
                eventPath: href,
                authHeader: auth,
              );

              if (icsData == null) {
                print('⚠️ 无法下载事件内容: $href');
                continue;
              }

              // 6. 解析 ICS (利用你之前的 IcsParser)
              // 即使 remote['uid'] 为空，我们也传一个基于 href 的标识符进去
              final String fallbackUid = href.split('/').last.replaceAll('.ics', '');
              final parsed = IcsParser.parse(icsData, remote['uid'] ?? fallbackUid);
              // 7. 调用原生的 createEvent 写入 Android 系统日历
              String title = parsed['summary'] ?? parsed['SUMMARY'] ?? '未命名事件';
              final String? systemEventId = await _native.createEvent(
                newLocalId,
                title,
                parsed['dtstart'],      // 毫秒级 Long
                parsed['dtend'],        // 毫秒级 Long
                parsed['description'],
                parsed['uid'],        // 核心：存入系统 _SYNC_ID
              );
              if (systemEventId != null) {
                // 8. 建立 sync_map 关系映射
                await db.insert('sync_map', {
                  'uid': parsed['uid'],
                  'local_id': systemEventId,
                  'calendar_local_id': newLocalId,
                  'summary': parsed['title'],
                  'last_etag': etag,      // 存下 ETag，下次同步时比对
                  'remote_href': href,
                  'sync_status': 0,       // 0 代表正常同步状态
                });
                eventSuccessCount++;
              }
            }
            // 9. 初始拉取全量完成，更新日历状态为“就绪”
            await db.update('calendar_map', {
              'is_provisioned': 1
            }, where: 'local_id = ?', whereArgs: [newLocalId]);

            print('✅ createLocal 完成: 已拉取 $eventSuccessCount 个事件');
            summary.success++;
          } catch (e,s) {
            print('❌ createLocal 过程发生异常: $e');
            print('📍 错误位置追踪:\n$s'); // 👈 打印堆栈
            summary.failed++;
          } finally {
            client.close(); // 释放长连接资源
          }
          break;
        case SyncAction.deleteLocal:
          try {
          bool result = await _native.deleteCalendar(ctx.calendarId, ctx.accountName);
          if(result){
            final db = await _dbHelper.database;
            await db.transaction((txn) async {
              // 1. 删除关联的事件追踪 (sync_map)
              int sCount = await txn.delete(
                  'sync_map',
                  where: 'calendar_local_id = ?',
                  whereArgs: [ctx.calendarId]
              );
              // 2. 删除日历自身的配置 (calendar_map)
              int cCount = await txn.delete(
                  'calendar_map',
                  where: 'local_id = ?',
                  whereArgs: [ctx.calendarId]
              );
              debugPrint("🗑️ 数据库清理完毕: 删除了 $sCount 条事件, $cCount 条日历记录");
            });
          }
          }catch (e){
            debugPrint("❌ 删除本地日历失败: $e");
          }
          break;
          default:{}
      }

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
        'calendar_map',
        where: 'account_name = ?',
        whereArgs: [userId],
      );

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
              await _native.deleteCalendar(localId,accountName);
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
              'is_provisioned': 0, // 初始状态，等待后续同步洗白
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
    // final icsData = await _nc.getEventDetail(eventPath: remote['href']);
    // if (icsData == null) return;
    // final parsed = IcsParser.parse(icsData, remote['uid']);
    //
    // String? systemEventId;
    //
    // // 💡 只有当：1. 用户勾选了同步  且 2. 日历 ID 已经洗白成数字
    // // 我们才真正调用原生 API 在手机系统里创建事件
    // if (ctx.syncStatus == 1 && !ctx.calendarId.startsWith('rc_')) {
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
    // await db.insert('sync_map', {
    //   'uid': remote['uid'],
    //   'local_id': systemEventId ?? 'v_${remote['uid']}', // 有系统 ID 用系统 ID，没有用虚拟
    //   'calendar_local_id': ctx.calendarId,
    //   'last_etag': remote['etag'],
    //   'summary': parsed['summary'],
    //   'dtstart': parsed['dtstart'],
    //   'dtend': parsed['dtend'],
    //   'sync_status': ctx.syncStatus,
    // }, conflictAlgorithm: ConflictAlgorithm.replace);
  }
}