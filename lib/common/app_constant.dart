/// 应用常量配置类
class AppConstant {
  AppConstant._();

  /// Nextcloud 服务器地址
  static const String nextcloudServer = 'nc-dev.ywpl.com.au';

  /// Nextcloud 管理员凭据（用于 Provisioning API 创建用户）
  /// 注意：这些凭据应该从环境变量或安全配置中读取，不要硬编码
  /// TODO: 从环境变量或安全存储中读取
  static const String adminUsername = 'userrA5XMYSG'; // 需要配置管理员用户名
  static const String adminPassword = '4Geme5oLn8KQz4qrVpqm3w5wugHdmOsi'; // 需要配置管理员密码

  /// MMKV 存储 Key
  static const String mmkvKeyNextcloudServer = 'nextcloud_server';
  static const String mmkvKeyNextcloudLoginName = 'nextcloud_login_name';
  static const String mmkvKeyNextcloudAppPassword = 'nextcloud_app_password';
  static const String mmkvKeyAdminUsername = 'nextcloud_admin_username';
  static const String mmkvKeyAdminPassword = 'nextcloud_admin_password';
}

