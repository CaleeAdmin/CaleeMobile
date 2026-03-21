// 仅用于 SyncEngine worker 的动作类型（项目级别同步，不含日历创建/删除）
enum SyncAction {
  // --- 同步阶段 (数据交换) ---
  // sync_mode 约定：0 = 单向，1 = 双向同步（Pull + Push）；运行时方向后续将由 binding role 解析
  fullSyncBidi,   // 双向流：允许 Pull 和 Push (个人日历)
  fullSyncPull,   // 单向流：远端 -> 本地
  fullSyncPush,   // 单向流：本地 -> 远端
}

class SyncBindingMode {
  static const int readOnly = 0;
  static const int twoWay = 1;
}

class SyncBindingRole {
  static const int mirror = 0;
  static const int ownerLink = 1;
}

class SyncBindingOrigin {
  // remote provenance only
  static const int local = 0;
  static const int remote = 1;
}

class SyncDeletionPolicy {
  // TWO_WAY 默认策略：删除双向传播
  static const int bidirectional = 0;
  // 安全策略：仅远端删除生效，本地删除不会删远端
  static const int remoteDeleteWins = 1;
}

enum SyncItemAction {
  createLocal,
  updateLocal,
  deleteLocal,
  createRemote,
  updateRemote,
  deleteRemote,
  mappingUpsert,
  mappingDelete,
  skip,
}

// 仅用于显式 UI 工作流（非 SyncEngine worker）
enum ProvisioningAction {
  uiDeleteLocalCalendar,
  uiDeleteRemoteCalendar,
  uiDeleteDatabaseOnly,
}

class CalendarStatus {
  static const int pending = 0;   // 初始状态：只有映射记录，还没去两端创建/同步数据
  static const int provisioned = 1; // 已洗白：本地系统日历 ID 已绑定，可以正常同步日程
  static const int deletedLocal = 2; // 墓碑状态：本地已删，等待下一次同步时清理云端
}

class SyncItemStatus {
  static const int pendingPush = 0; // local changed/new -> push required
  static const int pendingPull = 1; // remote changed -> pull required
  // Value 2 is intentionally unused for backward-compatibility with existing DB rows.
  static const int synced = 3; // clean
}
