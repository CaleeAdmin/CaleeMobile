import 'dart:developer';
import 'package:caleesync/providers/nextcloud_auth_provider.dart';
import 'package:flutter/material.dart';
import '../data/account_repository.dart';
import '../data/database_helper.dart';
import '../data/sync_repository.dart';
import '../services/nextcloud_service.dart';

class TestPage extends StatefulWidget {
  const TestPage({super.key});

  @override
  State<TestPage> createState() => _TestPageState();
}

class _TestPageState extends State<TestPage> {
  final SyncRepository _syncRepo = SyncRepository();
  final AccountRepository _accountRepo = AccountRepository();
  final DatabaseHelper _dbHelper = DatabaseHelper.instance;
  final NextcloudService _nextcloudService = NextcloudService();

  String _logText = '测试日志：\n';
  int? _currentAccountId;
  String? _username;

  @override
  void initState() {
    super.initState();
    // 页面加载时自动获取第一个账号
    _autoFetchAccount();
  }

  /// 自动获取数据库中的第一个用户
  Future<void> _autoFetchAccount() async {
    try {
      final db = await _dbHelper.database;
      final List<Map<String, dynamic>> accounts = await db.query('account_map', limit: 1);

      if (accounts.isNotEmpty) {
        setState(() {
          _currentAccountId = accounts.first['id'] as int;
          _username = accounts.first['username'] as String;
        });
        _addLog('👤 已自动关联账号: $_username (ID: $_currentAccountId)');
      } else {
        _addLog('⚠️ 数据库中没有账号，请先完成登录！');
      }
    } catch (e) {
      _addLog('❌ 获取账号失败: $e');
    }
  }

  void _addLog(String message) {
    if (!mounted) return;
    setState(() {
      _logText += '${DateTime.now().toString().substring(11, 19)}: $message\n';
    });
    log(message, name: 'SyncTest');
  }

  // 1. 扫描日历 (依赖自动获取的 _currentAccountId)
  Future<void> _scanCalendars() async {
    if (_currentAccountId == null) {
      // 再次尝试获取，防止手动重置后状态丢失
      await _autoFetchAccount();
      if (_currentAccountId == null) return;
    }
    try {
      _addLog('📡 正在为账号[$_username]扫描日历...');
      await _syncRepo.scanLocalCalendars(_currentAccountId!);

      final db = await _dbHelper.database;
      final List<Map<String, dynamic>> maps = await db.query('calendar_map');

      _addLog('📅 映射完成。本地数据库日历数: ${maps.length}');
      for (var cal in maps) {
        _addLog('   - [ID:${cal['local_id']}] ${cal['display_name']} (Status: ${cal['sync_status']})');
      }
    } catch (e) {
      _addLog('❌ 日历扫描失败: $e');
    }
  }

  // 2. 扫描事件 (增量扫描测试)
  Future<void> _scanEvents() async {
    try {
      const String targetCalId = "6"; // 确保这是你手机里真实存在的 ID
      _addLog('🔍 正在扫描日历[$targetCalId]的增量事件...');

      final result = await _syncRepo.scanLocalEvents(targetCalId);

      _addLog('✨ 扫描成功：新增 ${result['added']} 个，修改 ${result['modified']} 个');

      final db = await _dbHelper.database;
      // 正确的代码：使用 calendar_local_id
      final count = await db.rawQuery(
          'SELECT COUNT(*) as cnt FROM sync_map WHERE calendar_local_id = ?',
          [targetCalId]
      );
      _addLog('📊 数据库中该日历条目总数: ${count.first['cnt']}');
    } catch (e) {
      _addLog('❌ 事件扫描失败: $e');
    }
  }

  // 3. 查看待 Push 数据
  Future<void> _checkPending() async {
    try {
      final pending = await _syncRepo.getPendingUploads();
      _addLog('📤 发现 ${pending.length} 条待上传(sync_status=1)的本地变动');
      if (pending.isNotEmpty) {
        _addLog('   示例 UID: ${pending.first['uid'].toString().substring(0, 10)}...');
      }
    } catch (e) {
      _addLog('❌ 获取失败: $e');
    }
  }

  Future<void> _testPullFromNextcloud() async {
    try {
      _addLog('🚀 开始拉取云端数据...');

      // 1. 获取账号信息 (假设你已经完成 saveAccount)
      final account = await _accountRepo.getFirstAccount();
      if (account == null) return;

      // 2. 拉取云端日历列表
      final remoteCals = await _nextcloudService.fetchRemoteCalendars(
        serverUrl: account['server_url'],
        userId: account['username'],
        password: 'Asd446400714',
      );

      _addLog('📅 云端日历发现: ${remoteCals.length} 个');

      for (var cal in remoteCals) {
        _addLog('  - 日历: ${cal['display_name']}');

        // 3. 深入拉取具体日历下的事件
        final remoteEvents = await _nextcloudService.fetchRemoteEvents(
          calendarPath: cal['remote_path'],
          userId: account['username'],
        );
        _addLog('    ✨ 包含事件数: ${remoteEvents.length}');
      }
    } catch (e) {
      _addLog('❌ 拉取失败: $e');
    }
  }



  Future<void> _reset() async {
    final db = await _dbHelper.database;
    await db.delete('sync_map');
    await db.delete('calendar_map');
    await db.delete('account_map'); // 慎用：这会删掉你登录存好的账号
    setState(() {
      _currentAccountId = null;
      _username = null;
    });
    _addLog('🧹 数据库已完全重置 (账号已清空)');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_username == null ? '同步实验室' : '实验室: $_username'),
        backgroundColor: Colors.indigo.shade50,
        actions: [
          IconButton(icon: const Icon(Icons.person_search), onPressed: _autoFetchAccount, tooltip: '重新检测账号'),
          IconButton(icon: const Icon(Icons.refresh), onPressed: _reset, tooltip: '清空数据库'),
          IconButton(icon: const Icon(Icons.clear), onPressed: () => setState(() => _logText = '')),
        ],
      ),
      body: Column(
        children: [
          _buildControlPanel(),
          Expanded(child: _buildLogView()),
        ],
      ),
    );
  }

  Widget _buildControlPanel() {
    return Card(
      margin: const EdgeInsets.all(12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            _actionBtn('1. 映射日历', _scanCalendars, Colors.blue),
            _actionBtn('2. 扫描增量事件', _scanEvents, Colors.green),
            _actionBtn('3. 拉取云端数据', _testPullFromNextcloud, Colors.orange),
          ],
        ),
      ),
    );
  }

  Widget _actionBtn(String label, VoidCallback action, Color color) {
    return ActionChip(
      label: Text(label, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
      backgroundColor: color,
      onPressed: action,
    );
  }

  Widget _buildLogView() {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(12, 0, 12, 12),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: Colors.grey.shade900,
        borderRadius: BorderRadius.circular(12),
      ),
      child: SingleChildScrollView(
        reverse: true,
        child: Text(
          _logText,
          style: const TextStyle(color: Colors.greenAccent, fontFamily: 'monospace', fontSize: 11),
        ),
      ),
    );
  }
}