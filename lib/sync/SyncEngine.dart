import 'dart:convert';

import 'package:caleesync/common/app_constant.dart';
import 'package:caleesync/common/utils/EventParsedUtils.dart';
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
import '../data/database_helper.dart';
import '../utils/TimeUtils.dart';

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
    // 1. 获取该用户下的所有本地数据库记录（包含状态为 2 的记录）
    final db = await _dbHelper.database;
    final List<Map<String, dynamic>> localRecords = await db.query(
      'calendar_map',
      where: 'account_name = ?',
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
        // 数据库彻底没记录 -> 真正的云端新坑
        contexts.add(_buildContext(remote, null, SyncAction.createLocal));
        continue;
      }

      final int provisionStatus = local['is_provisioned'] ?? 0;
      final int isEnabled = local['is_enabled'] ?? 0;
      final int origin = local['origin'] ?? 0;
      final int mode = local['sync_mode'] ?? 0;

      // 如果该记录已经被标记为待删除（状态2），跳过策略 A 的同步逻辑，交由策略 B 处理
      if (provisionStatus == 2) continue;

      // 处理尚未在本地系统创建的情况 (状态 0)
      if (local['local_id'] == null || local['local_id'].isEmpty ||
          provisionStatus == 0) {
        if (isEnabled == 1) {
          contexts.add(_buildContext(remote, local, SyncAction.createLocal));
        }
        continue;
      }

      // 正常同步 (状态 1)
      if (isEnabled == 1) {
        SyncAction action;
        if (mode == 0) {
          action = SyncAction.fullSyncBidi;
        } else {
          action = (origin == 1) ? SyncAction.fullSyncPull : SyncAction.fullSyncPush;
        }
        contexts.add(_buildContext(remote, local, action));
      }
    }

    // --- 策略 B：以本地数据库记录为准 (针对：删除、本地新建) ---
    for (var local in localRecords) {
      final String? path = local['remote_path'];
      final int origin = local['origin'] ?? 0;
      final int mode = local['sync_mode'] ?? 0;
      final int isEnabled = local['is_enabled'] ?? 0;
      final int provisionStatus = local['is_provisioned'] ?? 0;

      // 1. 【核心修复】：优先处理状态码 2 (待删除)
      if (provisionStatus == 2) {
        final String? localId = local['local_id'];

        // 核心判定：local_id 是否为一个真实的系统数字 ID
        // 如果 local_id 为空，或者包含 "rc_" (你之前定义的临时 ID 前缀)，说明本地无实物
        final bool hasPhysicalLocalEntity = localId != null &&
            localId.isNotEmpty &&
            !localId.startsWith('rc_') &&
            int.tryParse(localId) != null;

        if (origin == 1) {
          // 【场景 A】：远端起源（订阅/同步日历）
          if (hasPhysicalLocalEntity) {
            debugPrint("🗑️ 状态2：远端已删且本地有实物，执行本地物理清理: $path (ID: $localId)");
            contexts.add(_buildContext(remoteMap[path] ?? {}, local, SyncAction.deleteLocal));
          } else {
            // 关键修复：本地根本没创建过，直接标记为“仅清理数据库记录”
            debugPrint("⏭️ 状态2：远端已删但本地无实物，跳过原生调用，直接清理数据库: $path");
            // 这里可以复用一个 Action 或者在执行器里直接处理
            contexts.add(_buildContext({}, local, SyncAction.deleteDatabaseOnly));
          }
        } else {
          // 【场景 B】：本地起源（用户在手机上删了）
          // 既然本地已经删了（通过 scanLocal 发现的），肯定要通知远端清理
          debugPrint("🚫 状态2：本地系统已删，准备通知云端删除: $path");
          contexts.add(_buildContext(remoteMap[path] ?? {}, local, SyncAction.deleteRemote));
        }
        continue;
      }

      // 2. 处理本地新建尚未同步的情况 (没有路径)
      if (path == null || path.isEmpty) {
        if (isEnabled == 1 && provisionStatus == 0) {
          contexts.add(_buildContext({}, local, SyncAction.createRemote));
        }
        continue;
      }

      // 3. 处理查漏补缺：如果数据库里是状态 1，但远端结果里突然搜不到了
      // 虽然 persistRemoteCalendars 应该已经把这种记录改成了状态 2，
      // 但作为双保险，这里可以保留一个简单的判定逻辑
      final bool remoteExists = remoteMap.containsKey(path);
      if (!remoteExists && provisionStatus == 1) {
        // 这种情况理论上不应发生，因为 persistRemoteCalendars 会提前处理
        // 如果发生了，说明还没来得及执行 persist 就开始 generateTasks 了
        if (origin == 1 || (origin == 0 && mode == 0)) {
          contexts.add(_buildContext({}, local, SyncAction.deleteLocal));
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
      isSubscription: remote['is_subscription'] ?? false,
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

    debugPrint("====generateSyncTasks===$tasks");

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

          // 1. 在 Android 系统侧创建日历
          final int colorValue = int.tryParse(ctx.color.replaceAll('#', '0x')) ?? 0xFF2196F3;
          final String? newLocalId = await _native.createCalendar(
            ctx.displayName,
            loginName,
            colorValue,
          );

          if (newLocalId == null) {
            print('❌ 原生创建日历失败');
            summary.failed++;
            break;
          }

          final db = await _dbHelper.database;

          // 2. 关联本地 ID 并预设状态
          await db.update('calendar_map', {
            'local_id': newLocalId,
            'is_enabled': 1,
            'is_provisioned': 0,
          }, where: 'remote_path = ?', whereArgs: [ctx.remotePath]);

          try {
            // 3. 统一获取远端事件元数据
            final List<Map<String, dynamic>> remoteEvents = await _nc.fetchUnifiedEvents(
              calendarPath: ctx.remotePath,
              isSubscription: ctx.isSubscription ?? false,
            );

            // 4. 加载本地 sync_map 缓存用于 Diff 比对
            final List<Map<String, dynamic>> localEntries = await db.query(
              'sync_map',
              where: 'calendar_local_id = ?',
              whereArgs: [newLocalId],
            );
            final Map<String, Map<String, dynamic>> localSyncMap = {
              for (var entry in localEntries) entry['uid'] as String: entry
            };

            int eventSuccessCount = 0;
            final _api = NativeCalendarApi(); // Pigeon API

            for (var remote in remoteEvents) {
              final String remoteUid = remote['uid'] ?? '';
              final String remoteEtag = (remote['etag'] ?? '').replaceAll('"', '');

              // 5. 差异比对：ETag 没变且本地已有系统 ID 则跳过
              if (localSyncMap.containsKey(remoteUid)) {
                final localEtag = localSyncMap[remoteUid]!['last_etag'];
                final localSystemId = localSyncMap[remoteUid]!['local_id'];
                if (localEtag == remoteEtag && localSystemId != null) {
                  eventSuccessCount++;
                  continue;
                }
              }

              // 6. 获取事件详情（内部兼容订阅/普通日历，解决 404 问题）
              final eventData = await Eventparsedutils.resolveEventData(
                remote: remote,
                isSubscription: ctx.isSubscription ?? false,
              );

              if (eventData == null) continue;

              // 7. 构建 Pigeon 请求对象
              final request = CalendarEventRequest(
                calendarId: newLocalId.toString(),
                title: eventData.summary,
                start: eventData.dtstart,
                end: eventData.dtend,
                notes: eventData.description,
                uid: eventData.uid,
                // 关键：传入已有的 local_id 则触发原生 Update
                eventId: localSyncMap[eventData.uid]?['local_id']?.toString(),
              );

              try {
                // 8. 调用原生 createOrUpdateEvent
                final String? systemEventId = await _api.createOrUpdateEvent(request);

                if (systemEventId != null) {
                  // 9. 更新 sync_map 映射
                  await db.insert('sync_map', {
                    'uid': eventData.uid,
                    'local_id': systemEventId,
                    'calendar_local_id': newLocalId,
                    'summary': eventData.summary,
                    'last_etag': remoteEtag,
                    'remote_href': eventData.href,
                    'sync_status': 0,
                    'dtstart': eventData.dtstart,
                    'dtend': eventData.dtend,
                  }, conflictAlgorithm: ConflictAlgorithm.replace);

                  eventSuccessCount++;
                }
              } catch (e) {
                debugPrint("❌ 同步单条事件失败: $e");
              }
            }

            // 10. 标记初始拉取完成
            await db.update('calendar_map', {
              'is_provisioned': 1
            }, where: 'local_id = ?', whereArgs: [newLocalId]);

            print('✅ createLocal 完成: 已处理 $eventSuccessCount 个事件');
            summary.success++;
          } catch (e) {
            print('❌ createLocal 过程发生异常: $e');
            summary.failed++;
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
        case SyncAction.deleteRemote:
        // 1. 执行远程删除任务
          bool isRemoteDeleted = await _nc.deleteRemoteCalendar(
            userId: loginName,
            calendarPath: ctx.remotePath, // 确保 ctx 包含这个路径
          );

          if (isRemoteDeleted) {
            final db = await _dbHelper.database;

            // 2. 开启事务进行本地“斩草除根”
            await db.transaction((txn) async {
              // A. 清理 sync_map (关联的事件映射)
              // 理由：日历都没了，它下面所有 ics 文件的 ETag 记录必须清空
              int sCount = await txn.delete(
                'sync_map',
                where: 'calendar_local_id = ? OR remote_path LIKE ?',
                whereArgs: [ctx.calendarId, '${ctx.remotePath}%'],
              );

              // B. 清理 calendar_map (日历自身配置)
              int cCount = await txn.delete(
                'calendar_map',
                where: 'local_id = ?',
                whereArgs: [ctx.calendarId],
              );
              debugPrint("🧹 云端删除成功，本地清理完成: 删除了 $cCount 个日历配置, $sCount 条同步映射");
            });
            // 3. 通知 UI 刷新 (如果是使用 GetX 或 Provider)
            // calendarController.removeItemFromUI(ctx.calendarId);
          } else {
            debugPrint("❌ 云端删除失败，停止清理本地数据库以防状态不一致");
          }
          break;
        case SyncAction.fullSyncPull:
          final String localCalendarId = ctx.calendarId;
          final String remotePath = ctx.remotePath;
          final String? newCtag = ctx.ctag;
          final String accountName = ctx.accountName;

          if (localCalendarId.isEmpty) break;

          try {
            // 1. 获取远端最新全量数据
            final List<Map<String, dynamic>> remoteEvents = await _nc.fetchUnifiedEvents(calendarPath: remotePath,
                isSubscription: ctx.isSubscription ?? false
            );
            final db = await _dbHelper.database;

            // 2. 获取本地 sync_map 缓存
            final List<Map<String, dynamic>> localSyncRecords = await db.query(
              'sync_map',
              where: 'calendar_local_id = ?',
              whereArgs: [localCalendarId],
            );
            final Map<String, Map<String, dynamic>> localSyncMap = {
              for (var row in localSyncRecords) row['uid'] as String: row
            };

            final Set<String> remoteUids = {};

            // 3. 遍历远端，处理 新增/更新
            for (var remoteEvent in remoteEvents) {
              final String uid = remoteEvent['uid'];
              final String etag = remoteEvent['etag'];
              remoteUids.add(uid);

              final localRecord = localSyncMap[uid];

              // 只有 ETag 不一致时才触发原生操作
              if (localRecord == null || localRecord['last_etag'] != etag) {
                // 调用新增的 createOrUpdateEvent 接口
                // 如果 localRecord 为 null，eventId 传 null 触发原生 Insert
                final request = CalendarEventRequest(
                  calendarId: localCalendarId.toString(),
                  title: remoteEvent['summary'] ?? '无标题',
                  start: Timeutils.parseToMillis(remoteEvent['start']),
                  end: Timeutils.parseToMillis(remoteEvent['end']),
                  notes: remoteEvent['description'] ?? "UID: $uid",
                  uid: uid,
                  // 关键：如果 localRecord 存在，则传入其 local_id 告诉原生端执行 Update
                  eventId: localRecord?['local_id']?.toString(),
                );

                final String? systemEventId = await _native.createOrUpdateEvent(
                    request
                );

                if (systemEventId != null) {
                  await db.insert('sync_map', {
                    'uid': uid,
                    'local_id': systemEventId,
                    'calendar_local_id': localCalendarId,
                    'summary': remoteEvent['summary'],
                    'last_etag': etag,
                    'remote_href': remoteEvent['href'],
                    'sync_status': 0,
                  }, conflictAlgorithm: ConflictAlgorithm.replace);
                }
              }
            }

            // 4. 处理 物理删除 (本地有但远端没了)
            for (var uid in localSyncMap.keys) {
              if (!remoteUids.contains(uid)) {
                final recordToDelete = localSyncMap[uid]!;
                final bool isDeleted = await _native.deleteEvent(recordToDelete['local_id']);
                if (isDeleted) {
                  await db.delete('sync_map', where: 'uid = ?', whereArgs: [uid]);
                }
              }
            }

            // 5. 更新日历 CTAG
            await db.update('calendar_map',
                {'last_ctag': newCtag, 'is_provisioned': 1},
                where: 'remote_path = ? AND account_name = ?',
                whereArgs: [remotePath, accountName]);

            debugPrint("✅ FullSyncPull 完成，CTAG 更新为: $newCtag");
          } catch (e) {
            debugPrint("❌ FullSyncPull 异常: $e");
          }
          break;
        case SyncAction.deleteDatabaseOnly:
        // 无需原生操作，直接从数据库抹除映射关系
          final db = await _dbHelper.database;
          await db.delete(
            'calendar_map',
            where: 'remote_path = ? AND account_name = ?',
            whereArgs: [ctx.remotePath, ctx.accountName],
          );
          debugPrint("🧹 已从数据库彻底移除未落地的日历记录");
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