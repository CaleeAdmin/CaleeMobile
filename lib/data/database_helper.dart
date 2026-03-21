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
    // 1. 远端集合注册表（按账号+类型+路径唯一）
    await db.execute('''
      CREATE TABLE IF NOT EXISTS remote_collections (
        id INTEGER PRIMARY KEY AUTOINCREMENT, /* 主键 */
        account_name TEXT NOT NULL, /* 账号标识（同一账号下可以有多个集合） */
        collection_type TEXT NOT NULL CHECK(collection_type IN ('calendar','tasklist')), /* 集合类型（calendar/tasklist） */
        remote_path TEXT NOT NULL, /* 远端集合路径（如 CalDAV 日历 URL） */
        display_name TEXT, /* 集合显示名 */
        color TEXT, /* 集合颜色（十六进制或平台定义值） */
        synced_ctag TEXT, /* 最近一次同步时记录的 ctag */
        sync_mode INTEGER DEFAULT 0, /* 同步模式（0 只读，1 双向） */
        is_subscription INTEGER DEFAULT 0, /* 是否为订阅型集合（0 否 / 1 是） */
        subscription_url TEXT, /* 订阅地址（仅订阅集合使用） */
        origin_kind INTEGER DEFAULT 1, /* 远端来源（0 本地，1 远端；默认 1） */
        origin_key TEXT /* 远端来源稳定标识 */
      )
    ''');

    await db.execute('''
      CREATE UNIQUE INDEX IF NOT EXISTS uq_rc_account_type_path
      ON remote_collections(account_name, collection_type, remote_path)
    ''');

    // 2. 远端集合与本地集合绑定关系
    await db.execute('''
      CREATE TABLE IF NOT EXISTS local_bindings (
        id INTEGER PRIMARY KEY AUTOINCREMENT, /* 主键 */
        remote_collection_id INTEGER NOT NULL, /* 关联 remote_collections.id */
        local_collection_id TEXT NOT NULL, /* 本地侧集合 ID（平台返回的日历/任务列表 ID） */
        binding_role INTEGER NOT NULL DEFAULT 0, /* 绑定角色（默认 mirror） */
        created_at INTEGER, /* 绑定创建时间（毫秒时间戳） */
        updated_at INTEGER, /* 绑定更新时间（毫秒时间戳） */
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
      CREATE TABLE IF NOT EXISTS collection_states (
        remote_collection_id INTEGER PRIMARY KEY,
        sync_gate_reason TEXT,
        is_enabled INTEGER DEFAULT 0,
        updated_at INTEGER,
        FOREIGN KEY (remote_collection_id) REFERENCES remote_collections(id) ON DELETE CASCADE
      )
    ''');

    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_cs_gate_reason
      ON collection_states(sync_gate_reason)
    ''');

    // 3. 同步条目映射（事件/任务）
    await db.execute('''
      CREATE TABLE IF NOT EXISTS sync_items (
        id INTEGER PRIMARY KEY AUTOINCREMENT, /* 主键 */
        remote_collection_id INTEGER NOT NULL, /* 关联 remote_collections.id */
        item_type TEXT NOT NULL DEFAULT 'event' CHECK(item_type IN ('event','task')), /* 条目类型（event/task） */
        remote_href TEXT, /* 远端对象路径（集合内唯一） */
        remote_uid TEXT, /* 远端对象 UID（业务标识） */
        local_item_id TEXT, /* 本地条目 ID */
        summary TEXT, /* 标题快照（可用于快速展示/排查） */
        description TEXT, /* 描述快照 */
        dtstart INTEGER, /* 开始时间（毫秒时间戳） */
        dtend INTEGER, /* 结束时间（毫秒时间戳） */
        last_etag TEXT, /* 最近同步到的 etag */
        last_mtime INTEGER, /* 最近同步时记录的修改时间（毫秒时间戳） */
        sync_status INTEGER NOT NULL DEFAULT 3 CHECK(sync_status IN (0,1,2,3)), /* 同步状态（0 待上传，1 待下载，2 兼容保留，3 已同步） */
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
      CREATE INDEX IF NOT EXISTS idx_si_coll_local_item
      ON sync_items(remote_collection_id, local_item_id)
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
