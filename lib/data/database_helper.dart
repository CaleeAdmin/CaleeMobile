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


    // 3. 远端集合注册表（按账号+类型+路径唯一）
    await db.execute('''
      CREATE TABLE IF NOT EXISTS remote_collections (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        account_name TEXT NOT NULL,
        collection_type TEXT NOT NULL,
        remote_path TEXT NOT NULL,
        display_name TEXT,
        color TEXT,
        synced_ctag TEXT,
        sync_mode INTEGER DEFAULT 0,
        is_enabled INTEGER DEFAULT 0,
        is_subscription INTEGER DEFAULT 0,
        subscription_url TEXT
      )
    ''');

    await db.execute('''
      CREATE UNIQUE INDEX IF NOT EXISTS uq_rc_account_type_path
      ON remote_collections(account_name, collection_type, remote_path)
    ''');

    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_rc_account_type_enabled
      ON remote_collections(account_name, collection_type, is_enabled)
    ''');

    // 4. 远端集合与本地集合绑定关系
    await db.execute('''
      CREATE TABLE IF NOT EXISTS local_bindings (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        remote_collection_id INTEGER NOT NULL,
        local_collection_id TEXT NOT NULL,
        local_account_type TEXT,
        binding_origin INTEGER DEFAULT 1,
        created_at INTEGER,
        updated_at INTEGER,
        FOREIGN KEY (remote_collection_id) REFERENCES remote_collections(id) ON DELETE CASCADE
      )
    ''');

    await db.execute('''
      CREATE UNIQUE INDEX IF NOT EXISTS uq_lb_remote
      ON local_bindings(remote_collection_id)
    ''');

    await db.execute('''
      CREATE UNIQUE INDEX IF NOT EXISTS uq_lb_local
      ON local_bindings(local_collection_id)
    ''');

    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_lb_local_type
      ON local_bindings(local_account_type)
    ''');

    // 5. 同步条目映射（事件/任务）
    await db.execute('''
      CREATE TABLE IF NOT EXISTS sync_items (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        remote_collection_id INTEGER NOT NULL,
        item_type TEXT DEFAULT 'event',
        remote_href TEXT,
        remote_uid TEXT,
        local_item_id TEXT,
        summary TEXT,
        description TEXT,
        dtstart INTEGER,
        dtend INTEGER,
        last_etag TEXT,
        last_mtime INTEGER,
        sync_status INTEGER DEFAULT 3,
        FOREIGN KEY (remote_collection_id) REFERENCES remote_collections(id) ON DELETE CASCADE
      )
    ''');

    await db.execute('''
      CREATE UNIQUE INDEX IF NOT EXISTS uq_si_coll_href
      ON sync_items(remote_collection_id, remote_href)
    ''');

    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_si_local_item
      ON sync_items(local_item_id)
    ''');

    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_si_coll_status
      ON sync_items(remote_collection_id, sync_status)
    ''');

    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_si_coll_uid
      ON sync_items(remote_collection_id, remote_uid)
    ''');
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
