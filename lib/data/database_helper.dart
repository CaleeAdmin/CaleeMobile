import 'package:path/path.dart';
import 'package:sqflite/sqflite.dart';

class DatabaseHelper {
  static final DatabaseHelper instance = DatabaseHelper._init();
  static Database? _database;

  DatabaseHelper._init();

  // 提供一个供 GetX 初始化调用的方法
  Future<DatabaseHelper> init() async {
    await database; // 触发数据库初始化
    return this;
  }

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
        remote_path TEXT UNIQUE,     -- 远端路径，允许 NULL (但必须唯一)
        display_name TEXT,
        color TEXT,                  -- 存储 #AARRGGBB
        synced_ctag TEXT,
        sync_mode INTEGER DEFAULT 0,    -- 0:只读, 1:双向
        is_enabled INTEGER DEFAULT 0,   -- 0:暂停, 1:正常
        origin INTEGER DEFAULT 0,       -- 0:本地创建 (Local), 1:远端同步 (Remote)
        is_subscription INTEGER DEFAULT 0, -- 0:普通日历, 1:订阅日历
        subscription_url TEXT         -- 订阅来源 URL (仅订阅日历)
      )
    ''');

    // 2. 事件映射表：保持 UID 核心，增加索引优化查询
    // 彻底补全后的 sync_map
    await db.execute('''
     CREATE TABLE IF NOT EXISTS sync_map (
        uid TEXT PRIMARY KEY,
        local_id TEXT,                  -- 系统日历 _ID
        calendar_local_id TEXT,         -- 关联 calendar_map.local_id
        summary TEXT,
        description TEXT,
        dtstart INTEGER,                -- 毫秒时间戳
        dtend INTEGER,                  -- 毫秒时间戳
        last_etag TEXT,
        last_mtime INTEGER,             -- 系统日历的最后修改时间
        item_type TEXT DEFAULT 'event', -- event / task
        remote_href TEXT,
        sync_status INTEGER DEFAULT 3   -- 0:Synced, 1:Dirty, 2:Deleted, 3:Pending
    );
''');

    // 建议增加索引，提高同步扫描时的查询速度
    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_sync_local_event ON sync_map (local_id)');
    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_sync_calendar_group ON sync_map (calendar_local_id, sync_status)');
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
