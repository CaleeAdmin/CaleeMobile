/// Nextcloud 注册状态
enum NextcloudRegisterStatus {
  initial,      // 初始状态
  registering,  // 正在注册
  success,      // 注册成功
  error,        // 注册失败
}

/// Nextcloud 注册状态模型
class NextcloudRegisterState {
  final NextcloudRegisterStatus status;
  final String? errorMessage;       // 错误信息

  const NextcloudRegisterState({
    this.status = NextcloudRegisterStatus.initial,
    this.errorMessage,
  });

  NextcloudRegisterState copyWith({
    NextcloudRegisterStatus? status,
    String? errorMessage,
    bool clearError = false,
  }) {
    return NextcloudRegisterState(
      status: status ?? this.status,
      errorMessage: clearError
          ? null
          : (errorMessage ?? this.errorMessage),
    );
  }

  /// 是否正在加载中
  bool get isLoading => status == NextcloudRegisterStatus.registering;

  /// 是否注册成功
  bool get isSuccess => status == NextcloudRegisterStatus.success;

  /// 是否有错误
  bool get hasError => status == NextcloudRegisterStatus.error && errorMessage != null;
}

