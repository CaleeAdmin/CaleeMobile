// 仅用于 SyncEngine worker 的动作类型（项目级别同步，不含日历创建/删除）
enum SyncAction {
  // --- 同步阶段 (数据交换) ---
  // sync_mode 约定：0 = 只读（仅 Pull），1 = 双向同步（Pull + Push）
  fullSyncBidi,   // 双向流：允许 Pull 和 Push (个人日历)
  fullSyncPull,   // 单向流：仅允许从云端 Pull (订阅 A)
  fullSyncPush,   // 单向流：仅允许向云端 Push (发布 B)
}

// 仅用于显式 UI 工作流（非 SyncEngine worker）
enum ProvisioningAction {
  uiCreateRemoteCalendar,
  uiDeleteLocalCalendar,
  uiDeleteRemoteCalendar,
  uiDeleteDatabaseOnly,
}

class CalendarStatus {
  static const int pending = 0;   // 初始状态：只有映射记录，还没去两端创建/同步数据
  static const int provisioned = 1; // 已洗白：本地系统日历 ID 已绑定，可以正常同步日程
  static const int deletedLocal = 2; // 墓碑状态：本地已删，等待下一次同步时清理云端
}
