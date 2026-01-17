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
      // 如果需要外键支持（级联删除），必须开启此配置
      onConfigure: (db) async => await db.execute('PRAGMA foreign_keys = ON'),
    );
  }

  Future _createDB(Database db, int version) async {
    // 1. 账号表
    await db.execute('''
      CREATE TABLE account_map (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        server_url TEXT NOT NULL,
        username TEXT NOT NULL,
        display_name TEXT,
        sync_token TEXT
      )
    ''');

    // 2. 日历映射表
    await db.execute('''
      CREATE TABLE calendar_map (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        local_id TEXT UNIQUE,      -- Android 系统 ID
        account_id INTEGER NOT NULL,
        remote_path TEXT,          -- 云端 URL 路径（Push 成功后获得）
        display_name TEXT,
        last_ctag TEXT,            -- 核心：云端日历整体变化的标识
        sync_status INTEGER DEFAULT 0, -- 0:同步, 1:本地新建, 2:本地修改
        is_active INTEGER DEFAULT 1,
        FOREIGN KEY (account_id) REFERENCES account_map (id) ON DELETE CASCADE
      )
    ''');

    // 3. 条目详情映射表 (Event/Task)
    await db.execute('''
      CREATE TABLE sync_map (
        uid TEXT PRIMARY KEY,      -- 跨端唯一的 UID
        local_id TEXT NOT NULL,    -- 系统日历中的 Event ID
        calendar_local_id TEXT NOT NULL, -- 关联 calendar_map 的 local_id
        remote_href TEXT,          -- 服务器上的路径，如 'xxx.ics'
        last_etag TEXT,            -- 服务器条目版本标识
        last_mtime INTEGER NOT NULL, -- 本地最后修改时间戳
        item_type TEXT,            -- 'event' 或 'task'
        sync_status INTEGER DEFAULT 0, -- 0:同步完成, 1:本地更新待上传, 2:待删除
        FOREIGN KEY (calendar_local_id) REFERENCES calendar_map (local_id) ON DELETE CASCADE
      )
    ''');
  }
}