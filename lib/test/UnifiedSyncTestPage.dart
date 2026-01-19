import 'dart:developer';
import 'package:flutter/material.dart';
import 'package:sqflite/sqflite.dart';
import '../common/app_constant.dart';
import '../common/utils/mmkv_utils.dart';
import '../data/database_helper.dart';
import '../data/sync_repository.dart';
import '../services/nextcloud_service.dart';
import '../common/utils/IcsSerializer.dart';

class UnifiedSyncTestPage extends StatefulWidget {
  const UnifiedSyncTestPage({super.key});

  @override
  State<UnifiedSyncTestPage> createState() => _UnifiedSyncTestPageState();
}

class _UnifiedSyncTestPageState extends State<UnifiedSyncTestPage> {
  final SyncRepository _syncRepo = SyncRepository();
  final DatabaseHelper _dbHelper = DatabaseHelper.instance;
  final NextcloudService _ncService = NextcloudService();

  String _logs = "🚀 统一同步流程测试就绪\n";
  String? _username;
  final String _targetCalId = "6"; // 目标日历 ID

  @override
  void initState() {
    super.initState();
  }

  void _addLog(String msg) {
    if (!mounted) return;
    setState(() => _logs += "${DateTime.now().toString().substring(11, 19)}: $msg\n");
    log(msg, name: 'UnifiedSync');
  }

  // ================= 步骤 1：本地日历与云端容器绑定 =================
  Future<void> _step1MapAndCreate() async {
    try {
      _addLog('--- 步骤1: 映射日历并创建云端容器 ---');

      final String? loginName = MMKVUtils.instance.getString(AppConstant.loginName);
      final String? password = MMKVUtils.instance.getString(AppConstant.password);

      if (loginName == null || password == null) {
        _addLog("❌ 错误：MMKV 中找不到账号信息");
        return;
      }

      _addLog("👤 关联账号: $loginName");

      // 1. 扫描本地日历并存库
      // 这一步会执行 INSERT INTO calendar_map (local_id, ...)
      await _syncRepo.scanLocalCalendars(loginName);

      // 2. 在云端创建日历容器
      // 理论返回: /remote.php/dav/calendars/用户名/cal_sync_6/
      var remotePath = await _ncService.createRemoteCalendar(
          userId: loginName,
          calendarName: "cal_sync_2",
          calendarId: "cal_sync_2"
      );

      _addLog("===remotePath==${remotePath}");

      // // 强制补全路径兜底：如果接口返回不全，手动拼接确保步骤3不报错
      // if (remotePath == null || !remotePath.contains('remote.php')) {
      //   remotePath = "/remote.php/dav/calendars/$loginName/cal_sync_7/";
      //   _addLog("⚠️ 云端返回路径异常，已启用手动拼接路径");
      // }

      // 确保以 / 结尾
      // if (!remotePath.endsWith('/')) remotePath += '/';

      final db = await _dbHelper.database;

      // 3. 使用 INSERT OR REPLACE 确保数据一定写入
      // 如果之前没有这行，update 会失效；所以改用 insert
      await db.insert(
        'calendar_map',
        {
          'local_id': _targetCalId,
          'account_name': loginName,    // 🚀 修正：由 account_id 改为 account_name
          'remote_path': remotePath,
          'sync_status': 0,
          'display_name': 'cal_sync_2'
        },
        conflictAlgorithm: ConflictAlgorithm.replace, // 如果 ID 存在则覆盖
      );

      _addLog("✅ 云端路径已强制绑定: $remotePath");

    } catch (e) {
      _addLog("❌ 步骤1异常: $e");
    }
  }

  // ================= 步骤 2：扫描本地增量 (手机 -> DB) =================
  Future<void> _step2ScanLocal() async {
    try {
      _addLog('--- 步骤2: 扫描手机系统日历增量 ---');
      final result = await _syncRepo.scanLocalEvents(_targetCalId);
      _addLog('✨ 扫描结果: 新增 ${result['added']}, 修改 ${result['modified']}');

      final db = await _dbHelper.database;
      final count = await db.rawQuery('SELECT COUNT(*) as cnt FROM sync_map WHERE calendar_local_id = ?', [_targetCalId]);
      _addLog('📊 当前数据库条目总数: ${count.first['cnt']}');
    } catch (e) { _addLog("❌ 扫描失败: $e"); }
  }

  // ================= 步骤 3：单向推送 (本地 DB -> 云端) =================
  Future<void> _step3PushToRemote() async {
    try {
      _addLog('--- 步骤3: 推送本地变动到云端 ---');
      final db = await _dbHelper.database;

      // 1. 获取云端路径
      final calResult = await db.query('calendar_map', where: 'local_id = ?', whereArgs: [_targetCalId]);
      if (calResult.isEmpty || calResult.first['remote_path'] == null) {
        _addLog("❌ 错误：请先执行步骤 1 绑定路径");
        return;
      }
      final String remotePath = calResult.first['remote_path'] as String;
      final String userId = MMKVUtils.instance.getString(AppConstant.loginName)!;

      // ================= 分支 A: 处理新增或修改 (sync_status = 1) =================
      final List<Map<String, dynamic>> pendingUpload = await db.query(
        'sync_map',
        where: 'calendar_local_id = ? AND (sync_status = 1 OR last_etag IS NULL)',
        whereArgs: [_targetCalId],
      );

      if (pendingUpload.isNotEmpty) {
        _addLog('📤 发现 ${pendingUpload.length} 个待上传/更新事件');
        for (var event in pendingUpload) {
          final uid = event['uid'];
          final ics = IcsSerializer.toIcs(
            uid: uid,
            summary: event['summary'] ?? "无标题",
            start: DateTime.fromMillisecondsSinceEpoch(event['dtstart'] ?? 0),
            end: DateTime.fromMillisecondsSinceEpoch(event['dtend'] ?? 0),
            description: event['description'] ?? "",
          );

          final etag = await _ncService.putEvent(
              calendarPath: remotePath,
              uid: uid,
              icsData: ics,
              userId: userId
          );

          if (etag != null) {
            await db.update(
                'sync_map',
                {'last_etag': etag, 'sync_status': 0},
                where: 'uid = ?',
                whereArgs: [uid]
            );
            _addLog('✅ 已上传: ${event['summary']}');
          }
        }
      }

      // ================= 分支 B: 处理本地已删需同步删除云端 (sync_status = 2) =================
      final List<Map<String, dynamic>> pendingDelete = await db.query(
        'sync_map',
        where: 'calendar_local_id = ? AND sync_status = 2',
        whereArgs: [_targetCalId],
      );

      if (pendingDelete.isNotEmpty) {
        _addLog('🗑️ 发现 ${pendingDelete.length} 个待同步删除事件');
        for (var event in pendingDelete) {
          final uid = event['uid'];
          final summary = event['summary'] ?? "未知标题";

          // 构造完整的事件 ics 路径
          final String eventPath = "${remotePath.endsWith('/') ? remotePath : '$remotePath/'}$uid.ics";

          // 调用 Nextcloud 的删除接口 (请确保 NextcloudService 中有 deleteEvent 方法)
          final bool isDeleted = await _ncService.deleteEvent(
            eventPath: eventPath,
          );

          if (isDeleted) {
            // 云端删除成功，物理删除本地数据库记录
            await db.delete('sync_map', where: 'uid = ?', whereArgs: [uid]);
            _addLog('🔥 云端同步删除成功: $summary');
          } else {
            _addLog('⚠️ 云端删除失败: $summary (可能已手动删除)');
            // 可选：如果报 404，也可以认为删除成功并清理数据库
            await db.delete('sync_map', where: 'uid = ?', whereArgs: [uid]);
          }
        }
      }

      if (pendingUpload.isEmpty && pendingDelete.isEmpty) {
        _addLog('平稳状态：暂无本地变动需要推送');
      }

    } catch (e) {
      _addLog("❌ 推送异常: $e");
    }
  }

  // ================= 步骤 4：单向拉取 (云端 -> 手机) =================
  Future<void> _step4PullFromRemote() async {
    try {
      _addLog('--- 步骤4: 拉取云端新事件并写入手机 ---');
      // 注意：这里不再清空 sync_map，实现真正的增量拉取
      await _syncRepo.pullFromRemote(_targetCalId);
      _addLog('✅ 拉取流程执行完毕');
    } catch (e) { _addLog("❌ 拉取失败: $e"); }
  }

  // ================= 步骤 5：验证与清理 =================
  Future<void> _step5ViewDetails() async {
    _addLog('--- 步骤5: 数据库最终明细 ---');
    final db = await _dbHelper.database;
    final List<Map<String, dynamic>> events = await db.query('sync_map', where: 'calendar_local_id = ?', whereArgs: [_targetCalId]);
    for (var e in events) {
      _addLog('📍 ${e['summary']} | UID: ${e['uid'].toString().substring(0, 8)} | ETag: ${e['last_etag'] != null ? "YES" : "NO"}');
    }
  }

  // 步骤 6: 检查手机里少了谁，就去云端删谁
  Future<void> _step6PushDeletes() async {
    try {
      _addLog('--- 步骤6: 同步本地删除到云端 ---');
      await _syncRepo.pushDeletesToRemote(_targetCalId);
      _addLog('✅ 推送删除完成，请刷新网页查看');
    } catch (e) {
      _addLog("❌ 推送删除异常: $e");
    }
  }

// 模拟工具: 不用退出 App 就能测试本地删除
  Future<void> _simulateSystemDelete() async {
    final db = await _dbHelper.database;
    // 找一条已经同步过的记录
    final List<Map<String, dynamic>> results = await db.query(
        'sync_map',
        where: 'calendar_local_id = ? AND last_etag IS NOT NULL',
        whereArgs: [_targetCalId],
        limit: 1
    );

    if (results.isNotEmpty) {
      final String localId = results.first['local_id'] as String;
      final String summary = results.first['summary'] as String;

      // 调用 Pigeon 接口删除系统日历
      final bool ok = await _syncRepo.deleteEventTotally(localId,MMKVUtils.instance.getString(AppConstant.loginName)!);

      if (ok) {
        _addLog("🗑️ 模拟成功: 已从系统删除 [$summary]");
        _addLog("💡 提示: 现在点“步骤6”即可同步到云端");
      } else {
        _addLog("❌ 模拟删除系统事件失败");
      }
    } else {
      _addLog("⚠️ 没有可删除的同步记录，请先执行步骤 2 和 3");
    }
  }

  Future<void> _fullReset() async {
    final db = await _dbHelper.database;
    await db.delete('sync_map');
    await db.delete('calendar_map');
    _addLog('🧹 数据库已重置 (保留账号)');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("Nextcloud 同步实验室 (终极合并版)")),
      body: Column(
        children: [
          _buildControlPanel(),
          Expanded(
            child: Container(
              width: double.infinity, color: Colors.black,
              padding: const EdgeInsets.all(8),
              child: SingleChildScrollView(reverse: true, child: Text(_logs, style: const TextStyle(color: Colors.greenAccent, fontSize: 11, fontFamily: 'monospace'))),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildControlPanel() {
    return Container(
      padding: const EdgeInsets.all(12),
      color: Colors.grey.shade100,
      child: Wrap(
        spacing: 8, runSpacing: 8,
        children: [
          _testBtn("1.建立远端映射", _step1MapAndCreate, Colors.blue),
          _testBtn("2.扫描本地增量", _step2ScanLocal, Colors.green),
          _testBtn("3.推送本地->云端", _step3PushToRemote, Colors.orange),
          _testBtn("4.拉取(含同步删除)", _step4PullFromRemote, Colors.deepOrange), // 你的步骤4已经带了删除逻辑
          _testBtn("5.结果明细", _step5ViewDetails, Colors.purple),
          _testBtn("6.同步本地删除", _step6PushDeletes, Colors.redAccent), // 新增
          _testBtn("🔥清空云端", _simulateSystemDelete, Colors.black), // 新增测试工具
          _testBtn("重置DB", _fullReset, Colors.red),
        ],
      ),
    );
  }

  Widget _testBtn(String text, VoidCallback press, Color color) {
    return ElevatedButton(
      style: ElevatedButton.styleFrom(backgroundColor: color, foregroundColor: Colors.white),
      onPressed: press,
      child: Text(text, style: const TextStyle(fontSize: 12)),
    );
  }
}