/// 应用常量配置类
class AppConstant {
  AppConstant._();

  /// Calee 服务器地址
  static const String caleeServer = 'portal.calee.com.au';

  /// MMKV 存储 Key
  static const String serverKey = 'calee_server';
  static const String loginNameKey = 'calee_login_name';
  static const String appPasswordKey = 'calee_app_password';

  /// 同步策略开关：是否允许远端日历自动落地到系统本地日历。
  /// 默认关闭，避免未授权的 remote -> local 初始化。
  static const String autoCreateLocalFromRemoteKey = 'auto_create_local_from_remote';
  static const String autoSyncEnabledKey = 'auto_sync_enabled';
  static const String periodicSyncEnabledKey = 'periodic_sync_enabled';
  static const String syncIntervalCalendarKey = 'sync_interval_calendar';

  /// Android calendar account type used by system calendar integration.
  static const String calendarAccountType = 'com.viso.caleesync';

  /// Per-binding dangerous override key prefix.
  ///
  /// Full key format: [allowMassDeletionByBindingKeyPrefix]{bindingId}
  static const String allowMassDeletionByBindingKeyPrefix = 'allow_mass_deletion_binding_';
}
