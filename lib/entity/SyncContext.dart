// 定义同步任务的配置上下文
class SyncContext {
  final String calendarId;    // 系统 ID (如 "6")
  final String remotePath;    // 云端路径 (如 "/.../cal_sync_6/")
  final String accountName;   // 账户名 (如 "google@gmail.com")
  final String accountType;   // 账户类型 (如 "com.google")
  final String displayName;   // ⚠️ 新增：日历显示名称 (如 "我的工作日历")

  SyncContext({
    required this.calendarId,
    required this.remotePath,
    required this.accountName,
    required this.accountType,
    required this.displayName, // 必须传入
  });
}