import 'database_helper.dart';
import 'package:sqflite/sqflite.dart';

class AccountRepository {
  final DatabaseHelper _dbHelper = DatabaseHelper.instance;

  /// 保存账号并返回 ID
  Future<int> saveAccount({
    required String url,
    required String username,
  }) async {
    final db = await _dbHelper.database;

    // 1. 插入或更新账号信息
    // 使用 replace 确保如果用户重新登录，我们会更新服务器信息
    return await db.insert(
      'account_map',
      {
        'server_url': url,
        'username': username,
        'display_name': '$username@Nextcloud',
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// 获取当前登录的第一个账号 (演示用)
  Future<Map<String, dynamic>?> getFirstAccount() async {
    final db = await _dbHelper.database;
    final List<Map<String, dynamic>> maps = await db.query('account_map', limit: 1);
    if (maps.isNotEmpty) return maps.first;
    return null;
  }
}