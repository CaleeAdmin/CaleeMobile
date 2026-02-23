// 定义同步任务的配置上下文
class SyncContext {
  final String calendarId;    // 本地数据库中的 ID (可能是 "rc_..." 或数字 "6")
  final String remotePath;    // 云端路径
  final String accountName;   // 账户名
  final String accountType;   // 账户类型
  final String displayName;   // 日历显示名称
  final int syncStatus;       // ⚠️ 新增：同步状态 (0: 仅本地库, 1: 同步至系统)

  SyncContext({
    required this.calendarId,
    required this.remotePath,
    required this.accountName,
    required this.accountType,
    required this.displayName,
    this.syncStatus = 0,       // 默认为 0
  });

  /// 💡 新增 copyWith：用于在同步过程中动态更新 ID 或状态
  SyncContext copyWith({
    String? calendarId,
    String? remotePath,
    String? accountName,
    String? accountType,
    String? displayName,
    int? syncStatus,
  }) {
    return SyncContext(
      calendarId: calendarId ?? this.calendarId,
      remotePath: remotePath ?? this.remotePath,
      accountName: accountName ?? this.accountName,
      accountType: accountType ?? this.accountType,
      displayName: displayName ?? this.displayName,
      syncStatus: syncStatus ?? this.syncStatus,
    );
  }
}