import 'package:path/path.dart';
import 'package:sqflite/sqflite.dart';

class DatabaseHelper {
  static final DatabaseHelper instance = DatabaseHelper._init();
  static Database? _database;

  DatabaseHelper._init();

  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDB('caleesync.db');
    return _database!;
  }

  Future<Database> _initDB(String filePath) async {
    final dbPath = await getDatabasesPath();
    final path = join(dbPath, filePath);

    return await openDatabase(
      path,
      version: 1,
      onCreate: _createDB,
      // 开启外键支持
      onConfigure: (db) async => await db.execute('PRAGMA foreign_keys = ON'),
    );
  }

  Future _createDB(Database db, int version) async {
    // 1. 日历映射表：增加账号维度和同步模式
    await db.execute('''
      CREATE TABLE IF NOT EXISTS calendar_map (
        local_id TEXT PRIMARY KEY,
        account_name TEXT,           -- 账号标识 (e.g. gmail_user)
        account_type TEXT,           -- 账号来源 (e.g. com.google / iCloud)
        remote_path TEXT,
        display_name TEXT,
        color TEXT,                  -- 存储 #AARRGGBB
        last_ctag TEXT,
        sync_mode INTEGER DEFAULT 0, -- 0:双向, 1:只读
        sync_status INTEGER DEFAULT 0
      )
    ''');

    // 2. 事件映射表：保持 UID 核心，增加索引优化查询
    await db.execute('''
      CREATE TABLE IF NOT EXISTS sync_map (
        uid TEXT PRIMARY KEY,
        local_id TEXT,
        calendar_local_id TEXT,
        summary TEXT,
        description TEXT,
        dtstart INTEGER,
        dtend INTEGER,
        last_etag TEXT,
        last_mtime INTEGER,
        item_type TEXT,
        sync_status INTEGER DEFAULT 0
      )
    ''');

    // 建议增加索引，提高同步扫描时的查询速度
    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_sync_cal ON sync_map (calendar_local_id)');
    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_sync_local ON sync_map (local_id)');
  }
  // 物理删除数据库（调试用：调用后需重启 App）
  Future<void> deleteMyDatabase() async {
    final dbPath = await getDatabasesPath();
    final path = join(dbPath, 'caleesync.db');
    await _database?.close();
    _database = null;
    await deleteDatabase(path);
  }

  Future<void> close() async {
    if (_database != null) {
      await _database!.close();
      _database = null;
    }
  }
}