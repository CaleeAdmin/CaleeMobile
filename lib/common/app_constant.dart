/// 应用常量配置类
class AppConstant {
  AppConstant._();

  /// Calee 服务器地址
  static const String caleeServer = 'nc-dev.ywpl.com.au';

  /// MMKV 存储 Key
  static const String serverKey = 'calee_server';
  static const String loginNameKey = 'calee_login_name';
  static const String appPasswordKey = 'calee_app_password';

  /// 同步策略开关：是否允许远端日历自动落地到系统本地日历。
  /// 默认关闭，避免未授权的 remote -> local 初始化。
  static const String autoCreateLocalFromRemoteKey = 'auto_create_local_from_remote';
}
