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
      onConfigure: (db) async => await db.execute('PRAGMA foreign_keys = ON'),
    );
  }

  Future _createDB(Database db, int version) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS remote_collections (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        server_id TEXT,
        account_name TEXT,
        account_type TEXT,
        kind TEXT,
        remote_path TEXT,
        display_name TEXT,
        color TEXT,
        ctag TEXT,
        sync_token TEXT,
        is_subscription INTEGER DEFAULT 0,
        subscription_url TEXT,
        is_read_only INTEGER DEFAULT 0,
        updated_at INTEGER,
        local_id TEXT,
        sync_mode INTEGER DEFAULT 0,
        is_enabled INTEGER DEFAULT 1,
        origin INTEGER DEFAULT 1,
        UNIQUE(server_id, account_name, kind, remote_path),
        UNIQUE(local_id)
      )
    ''');

    await db.execute('''
      CREATE TABLE IF NOT EXISTS local_bindings (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        remote_collection_id INTEGER NOT NULL,
        local_provider TEXT NOT NULL,
        local_container_id TEXT,
        sync_mode INTEGER DEFAULT 0,
        is_enabled INTEGER DEFAULT 1,
        origin INTEGER DEFAULT 1,
        created_at INTEGER,
        updated_at INTEGER,
        FOREIGN KEY(remote_collection_id) REFERENCES remote_collections(id) ON DELETE CASCADE,
        UNIQUE(remote_collection_id)
      )
    ''');

    await db.execute('''
      CREATE TABLE IF NOT EXISTS sync_items (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        remote_collection_id INTEGER NOT NULL,
        item_type TEXT NOT NULL DEFAULT 'event',
        uid TEXT NOT NULL,
        recurrence_id TEXT,
        local_item_id TEXT,
        local_id TEXT,
        remote_href TEXT,
        remote_etag TEXT,
        remote_mtime INTEGER,
        summary TEXT,
        description TEXT,
        dtstart INTEGER,
        dtend INTEGER,
        due INTEGER,
        completed_at INTEGER,
        sync_status INTEGER DEFAULT 3,
        updated_at INTEGER,
        FOREIGN KEY(remote_collection_id) REFERENCES remote_collections(id) ON DELETE CASCADE,
        UNIQUE(remote_collection_id, item_type, uid, recurrence_id)
      )
    ''');

    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_remote_collections_scope ON remote_collections (server_id, account_name, kind)');
    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_bindings_local_container ON local_bindings (local_provider, local_container_id)');
    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_sync_items_local ON sync_items (local_item_id)');
    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_sync_items_status ON sync_items (remote_collection_id, sync_status)');
  }

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
