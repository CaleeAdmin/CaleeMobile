class CalendarDisplayItem {
  // 1. 标识符
  final String? localId;     // Android/iOS 系统日历 ID (对应数据库 local_id), 可能为 null
  final String? remotePath;   // 远程 WebDAV 路径 (作为数据库更新的绝对 Key), 不应为 null

  // 2. 显示内容
  final String name;
  final String color;
  final int eventCount;

  // 3. 状态控制
  final bool isReadOnly;
  final bool isSubscription;
  final bool isLocalReadOnly;
  final String? subscriptionUrl;
  final String accountName;
  bool isEnabled;            // 对应数据库 collection_states.is_enabled
  final String? syncGateReason;
  final int origin;          // Shared provenance only: where the remote calendar came from, not this-device sync behavior.
  final String? originKey;
  final int bindingId;
  final int bindingRole;     // This-device role: mirror vs ownerLink, and it drives runtime behavior.
  final int remoteCollectionId;
  bool hasRelinkSuggestion;
  bool allowMassDeletionDangerous;

  CalendarDisplayItem({
    this.localId,            // 允许为空
    required this.remotePath, // 必须有, 否则无法同步
    required this.name,
    required this.color,
    required this.eventCount,
    required this.isReadOnly,
    required this.isSubscription,
    required this.isLocalReadOnly,
    this.subscriptionUrl,
    required this.accountName,
    required this.isEnabled,
    this.syncGateReason,
    required this.origin,
    this.originKey,
    required this.bindingId,
    required this.bindingRole,
    required this.remoteCollectionId,
    this.hasRelinkSuggestion = false,
    required this.allowMassDeletionDangerous,
  });

}

