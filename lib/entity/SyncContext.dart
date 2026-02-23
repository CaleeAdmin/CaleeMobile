// 定义同步任务的配置上下文
import '../sync/SyncEnum.dart';

class SyncContext {
  final int remoteCollectionId; // remote_collections.id
  final String localCalendarId; // Android Calendar provider calendarId
  final String remotePath;    // 云端路径
  final String accountName;   // 账户名
  final String displayName;   // 日历显示名称
  final String color;   // 日历显示名称
  final int syncStatus;       // ⚠️ 新增：同步状态 (0: 仅本地库, 1: 同步至系统)
  final int syncMode;
// 💡 新增执行指令
  final SyncAction action;
  final String? ctag;               // 增量同步版本号
  final bool? isSubscription;
  final Map<String, dynamic> extra; // 存放描述、报错信息等

  SyncContext({
    required this.remoteCollectionId,
    required this.localCalendarId,
    required this.remotePath,
    required this.accountName,
    required this.displayName,
    required this.color,
    required this.syncMode,
    this.syncStatus = 0,       // 默认为 0
    required this.action, // 必须指定要做什么
    this.ctag,
    this.isSubscription,
    this.extra = const {},
  });

  /// 💡 新增 copyWith：用于在同步过程中动态更新 ID 或状态
  SyncContext copyWith({
    int? remoteCollectionId,
    String? localCalendarId,
    String? remotePath,
    String? accountName,
    String? displayName,
    String? color,
    int? syncMode,
    int? syncStatus,
    SyncAction? action,
    String? ctag,
    bool? isSubscription,
    Map<String, dynamic>? extra
  }) {
    return SyncContext(
      remoteCollectionId: remoteCollectionId ?? this.remoteCollectionId,
      localCalendarId: localCalendarId ?? this.localCalendarId,
      remotePath: remotePath ?? this.remotePath,
      accountName: accountName ?? this.accountName,
      displayName: displayName ?? this.displayName,
      color: color ?? this.color,
      syncMode: syncMode ?? this.syncMode,
      syncStatus: syncStatus ?? this.syncStatus,
      action: action ?? this.action,
      ctag: ctag ?? this.ctag,
      isSubscription: isSubscription ?? this.isSubscription,
      extra: extra ?? this.extra,
    );
  }

  @override
  String toString() {
    return 'SyncContext{remoteCollectionId: $remoteCollectionId, localCalendarId: $localCalendarId, remotePath: $remotePath, accountName: $accountName, displayName: $displayName, color: $color, syncStatus: $syncStatus, syncMode: $syncMode, action: $action, ctag: $ctag, isSubscription: $isSubscription, extra: $extra}';
  }


}