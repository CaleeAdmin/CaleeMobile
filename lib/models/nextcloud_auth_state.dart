/// Nextcloud 登录状态
enum NextcloudAuthStatus {
  initial,      // 初始状态
  initiating,   // 正在初始化登录流程
  polling,      // 正在轮询登录状态
  success,      // 登录成功
  error,        // 登录失败
}

/// Nextcloud 登录状态模型
class NextcloudAuthState {
  final NextcloudAuthStatus status;
  final String? loginUrl;           // 需要打开的登录 URL
  final String? pollToken;          // 轮询 token
  final String? pollEndpoint;       // 轮询 endpoint
  final String? serverUrl;          // 服务器 URL
  final String? loginName;          // 登录用户名
  final String? appPassword;        // 应用密码
  final String? errorMessage;       // 错误信息

  const NextcloudAuthState({
    this.status = NextcloudAuthStatus.initial,
    this.loginUrl,
    this.pollToken,
    this.pollEndpoint,
    this.serverUrl,
    this.loginName,
    this.appPassword,
    this.errorMessage,
  });

  NextcloudAuthState copyWith({
    NextcloudAuthStatus? status,
    String? loginUrl,
    String? pollToken,
    String? pollEndpoint,
    String? serverUrl,
    String? loginName,
    String? appPassword,
    String? errorMessage,
    bool clearError = false,
    bool clearCredentials = false,
  }) {
    return NextcloudAuthState(
      status: status ?? this.status,
      loginUrl: loginUrl ?? this.loginUrl,
      pollToken: pollToken ?? this.pollToken,
      pollEndpoint: pollEndpoint ?? this.pollEndpoint,
      serverUrl: serverUrl ?? this.serverUrl,
      loginName: clearCredentials ? null : (loginName ?? this.loginName),
      appPassword: clearCredentials ? null : (appPassword ?? this.appPassword),
      errorMessage: clearError
          ? null
          : (errorMessage ?? this.errorMessage),
    );
  }

  /// 是否正在加载中
  bool get isLoading =>
      status == NextcloudAuthStatus.initiating ||
      status == NextcloudAuthStatus.polling;

  /// 是否已登录成功
  bool get isAuthenticated => status == NextcloudAuthStatus.success;

  /// 是否有错误
  bool get hasError => status == NextcloudAuthStatus.error && errorMessage != null;
}

