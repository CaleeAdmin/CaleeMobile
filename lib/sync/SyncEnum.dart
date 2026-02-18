// 1. 定义动作类型
enum SyncAction {
  // --- 创建阶段 (物理开坑) ---
  createRemote,   // 物理动作：WebDAV MKCALENDAR
  createLocal,    // 物理动作：DB Insert (仅记录，不含数据)

  // --- 同步阶段 (数据交换) ---
  // sync_mode 约定：0 = 只读（仅 Pull），1 = 双向同步（Pull + Push）
  fullSyncBidi,   // 双向流：允许 Pull 和 Push (个人日历)
  fullSyncPull,   // 单向流：仅允许从云端 Pull (订阅 A)
  fullSyncPush,   // 单向流：仅允许向云端 Push (发布 B)

  // --- 销毁阶段 (清理门户) ---
  deleteLocal,    // 物理动作：DB Delete
  deleteRemote,   // 物理动作：WebDAV DELETE
  deleteDatabaseOnly,
  ignore          // 物理动作：静默 (保护 B)
}

class CalendarStatus {
  static const int pending = 0;   // 初始状态：只有映射记录，还没去两端创建/同步数据
  static const int provisioned = 1; // 已洗白：本地系统日历 ID 已绑定，可以正常同步日程
  static const int deletedLocal = 2; // 墓碑状态：本地已删，等待下一次同步时清理云端
}
