import 'package:caleesync/common/app_constant.dart';
import 'package:caleesync/common/utils/mmkv_utils.dart';
import 'package:caleesync/core/platform/pigeon/calendar_api.g.dart';
import 'package:caleesync/data/sync_repository.dart';
import 'package:mmkv/mmkv.dart';
import 'package:sqflite/sqflite.dart';

import '../common/utils/IcsGenerator.dart';
import '../common/utils/IcsParser.dart';
import '../entity/SyncContext.dart';
import '../entity/SyncSummary.dart';
import '../services/nextcloud_service.dart';
import 'database_helper.dart';

class SyncEngine {
  final SyncRepository _repo = SyncRepository();
  final NextcloudService _nc = NextcloudService();
  final NativeCalendarApi _native = NativeCalendarApi();

  /// 引入一个回调函数，让 UI 能实时拿到 summary 对象
  Future<SyncSummary> executeFullSync({Function(SyncSummary)? onProgress}) async {
    final summary = SyncSummary();

    // 1. 扫描本地系统日历（确保数据库里的 local_id, account_name 等是最新的）
    // 拿到权限后这一步必做，它是同步的基石
    await _repo.scanLocalCalendars(MMKVUtils.instance.getString(AppConstant.loginName)!);

    final List<SyncContext> tasks = await _repo.prepareSyncContexts();
    summary.reset(tasks.length);

    for (var ctx in tasks) {
      summary.processing++;
      onProgress?.call(summary);

      try {
        // --- 💡 关键：路径自动补全/创建逻辑 ---
        String? currentRemotePath = ctx.remotePath;

        if (currentRemotePath.isEmpty) {
          print("⚠️ 发现未绑定的日历，准备在云端创建...");
          // 这里的 userId 需要根据你的登录状态获取
          final String userId = MMKVUtils.instance.getString(AppConstant.loginName)!;

          // 调用创建方法 (假设方法名为 createRemoteCalendar)
          // 注意：建议使用 ctx.displayName 作为日历名
          currentRemotePath = await _nc.createRemoteCalendar(
            userId: userId,
            calendarName: ctx.displayName,
            calendarId: "calee_${ctx.calendarId}",
          );

          // 立即更新数据库，防止下次同步又重新创建
          await _repo.updateRemotePath(ctx.calendarId, currentRemotePath!);
          print("✅ 云端路径创建成功: $currentRemotePath");
        }

        print("开始同步日历: ${ctx.accountName} - ${ctx.calendarId}");

        // 2. 本地变更捕获
        await _repo.scanSystemChanges(ctx);

        // 3. 获取云端快照
        // 获取云端数据后的解析部分
        final remoteItems = await _nc.fetchRemoteEvents(calendarPath: currentRemotePath!);
        final Map<String, dynamic> remoteMap = {};

        for (var item in remoteItems) {
          final href = item['href']?.toString() ?? "";
          if (href.endsWith('.ics')) {
            // 💡 核心修复：如果云端属性里没有 uid，则从文件名提取
            // 例如 /.../local_event_812.ics -> local_event_812
            String extractedUid = item['uid']?.toString() ?? "";
            if (extractedUid.isEmpty) {
              extractedUid = href.split('/').last.replaceAll('.ics', '');
            }

            // 重新把确定的 UID 塞回 item，防止传给 _downloadFromCloud 时报错
            item['uid'] = extractedUid;

            remoteMap[extractedUid] = item;
            print("✅ 准备处理云端事件: $extractedUid");
          }
        }

        // 4. 双向合并逻辑
        // 💡 调用抽离出来的合并方法
        await _processMerging(ctx, currentRemotePath, remoteMap);
        // ... 下载逻辑 ...
        summary.success++;
      } catch (e) {
        summary.failed++;
        print("❌ 同步异常: $e");
      } finally {
        summary.processing--;
        onProgress?.call(summary);
      }
    }
    return summary;
  }

  Future<void> _processMerging(SyncContext ctx, String currentRemotePath, Map<String, dynamic> remoteMap) async {
    final db = await DatabaseHelper.instance.database;

    final List<Map<String, dynamic>> locals = await db.query(
        'sync_map',
        where: 'calendar_local_id = ?',
        whereArgs: [ctx.calendarId]
    );

    print("--------------------------------------------------");
    print("🕵️ [同步监控] 开始对比日历: ${ctx.accountName} (ID: ${ctx.calendarId})");
    print("🕵️ [数据量] 本地库: ${locals.length} 条 | 云端返回: ${remoteMap.length} 条");

    for (var local in locals) {
      final String uid = local['uid'] as String;
      final int status = local['sync_status'] as int;
      final String title = local['summary'] ?? "无标题";
      final String localId = local['local_id'] as String;
      final String? remoteHref = local['remote_href'] as String?; // 截图最后一列

      // --- 💡 核心新增：处理本地已删除的情况 (Status 2) ---
      if (status == 2) {
        print("\n🗑️ 正在同步删除云端日程: [$title]");
        print("   - UID: $uid");

        // 优先使用数据库存的完整路径，没有则拼接
        final String deletePath = remoteHref ?? "${currentRemotePath.endsWith('/') ? currentRemotePath : '$currentRemotePath/'}$uid.ics";

        try {
          // 调用 Nextcloud 的删除接口
          bool success = await _nc.deleteEvent(eventPath: deletePath);
          if (success) {
            // 云端删除成功，彻底清理本地“墓碑”记录
            await db.delete('sync_map', where: 'uid = ?', whereArgs: [uid]);
            print("   -> ✅ 云端删除成功，本地映射已移除");
          }
        } catch (e) {
          print("   -> ❌ 云端删除失败: $e");
        }

        // 处理完删除后移除 remoteMap 里的对应项（防止误判为云端新增），然后跳过当前循环
        remoteMap.remove(uid);
        continue;
      }

      // --- 以下是原有的逻辑，不做改动 ---
      print("\n🧐 正在检查本地日程: [$title]");
      bool existsInRemote = remoteMap.containsKey(uid);

      if (existsInRemote) {
        final remote = remoteMap[uid];
        if (status == 1) {
          print("   -> 🚀 判定动作: 本地有修改，执行上传 (Push)");
          await _uploadToCloud(local, currentRemotePath);
        } else if (local['last_etag'] != remote['etag']) {
          print("   -> 📥 判定动作: 云端 ETag 变更，执行下载 (Pull)");
          await _downloadFromCloud(remote, ctx);
        } else {
          print("   -> ✅ 判定动作: 双端一致");
        }
        remoteMap.remove(uid);
      } else {
        if (status == 0) {
          print("   -> 🗑️ 判定动作: 云端已删，清理本地");
          await _native.deleteEvent(localId);
          await db.delete('sync_map', where: 'uid = ?', whereArgs: [uid]);
        } else if (status == 1) {
          print("   -> 🚀 判定动作: 本地新增，上传云端");
          await _uploadToCloud(local, currentRemotePath);
        }
      }
    }

    // 处理云端多出来的记录
    if (remoteMap.isNotEmpty) {
      for (var remote in remoteMap.values) {
        await _downloadFromCloud(remote, ctx);
      }
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
    final parsed = IcsParser.parse(icsData!, remote['uid']);

    // 1. 系统只负责存内容，不存 UID
    final newLocalId = await _native.createEvent(
      ctx.calendarId,
      parsed['summary'],
      parsed['dtstart'],
      parsed['dtend'],
      parsed['description'],
      null, // 👈 传 null，原生那边也不再写这个字段
    );

    if (newLocalId != null) {
      // 2. 关键：在自己的数据库里保存 {UID <-> SystemID} 的映射
      // 这样下次扫描看到系统 ID 102，就能通过这张表知道它对应的云端 UID
      final db = await DatabaseHelper.instance.database;
      await db.insert('sync_map', {
        'uid': remote['uid'],
        'local_id': newLocalId,
        'calendar_local_id': ctx.calendarId,
        'last_etag': remote['etag'],
        'sync_status': 0,
        'summary': parsed['summary'],
        'dtstart': parsed['dtstart'],
        'dtend': parsed['dtend'],
      }, conflictAlgorithm: ConflictAlgorithm.replace);

      print("✅ 已通过本地映射同步: ${parsed['summary']} (SystemID: $newLocalId)");
    }
  }
}