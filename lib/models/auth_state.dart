/// Calee 登录状态
enum AuthStatus {
  initial,      // 初始状态
  initiating,   // 正在初始化登录流程
  polling,      // 正在轮询登录状态
  success,      // 登录成功
  error,        // 登录失败
}

/// Calee 登录状态模型
class AuthState {
  final AuthStatus status;
  final String? loginUrl;           // 需要打开的登录 URL
  final String? pollToken;          // 轮询 token
  final String? pollEndpoint;       // 轮询 endpoint
  final String? serverUrl;          // 服务器 URL
  final String? loginName;          // 登录用户名
  final String? appPassword;        // 应用密码
  final String? errorMessage;       // Error信息

  const AuthState({
    this.status = AuthStatus.initial,
    this.loginUrl,
    this.pollToken,
    this.pollEndpoint,
    this.serverUrl,
    this.loginName,
    this.appPassword,
    this.errorMessage,
  });

  AuthState copyWith({
    AuthStatus? status,
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
    return AuthState(
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
      status == AuthStatus.initiating ||
      status == AuthStatus.polling;

  /// 是否已登录成功
  bool get isAuthenticated => status == AuthStatus.success;

  /// 是否有Error
  bool get hasError => status == AuthStatus.error && errorMessage != null;
}

