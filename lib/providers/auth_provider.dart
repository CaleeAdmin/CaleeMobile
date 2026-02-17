import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:caleesync/common/app_constant.dart';
import 'package:caleesync/models/auth_state.dart';
import 'package:caleesync/services/calee_auth_service.dart';

/// Nextcloud 认证服务 Provider（使用常量中的服务器地址）
final caleeAuthServiceProvider = Provider<CaleeAuthService>((ref) {
  return CaleeAuthService(serverBaseUrl: AppConstant.nextcloudServer);
});

/// Nextcloud 登录状态 Provider
final authStateProvider =
    StateNotifierProvider<AuthNotifier, AuthState>((ref) {
  final service = ref.watch(caleeAuthServiceProvider);
  return AuthNotifier(service);
});

/// Nextcloud 登录状态管理器
class AuthNotifier extends StateNotifier<AuthState> {
  final CaleeAuthService _service;
  Timer? _pollTimer;
  int _pollAttempts = 0;
  static const int _maxPollAttempts = 60; // 最多轮询 60 次（约 5 分钟）
  static const Duration _pollInterval = Duration(seconds: 5);

  AuthNotifier(this._service)
      : super(const AuthState());

  /// 使用用户名密码登录
  /// 
  /// [loginName] 用户名
  /// [password] 密码
  Future<void> loginWithCredentials({
    required String loginName,
    required String password,
  }) async {
    if (state.isLoading) return;

    state = state.copyWith(
      status: AuthStatus.initiating,
      clearError: true,
    );

    try {
      final success = await _service.loginWithCredentials(
        loginName: loginName,
        password: password,
      );

      if (success) {
        final appPassword = await _service.getAppPassword(
          loginName: loginName,
          password: password,
        );

        state = state.copyWith(
          status: AuthStatus.success,
          serverUrl: _service.normalizedUrl,
          loginName: loginName,
          appPassword: appPassword,
        );
      } else {
        throw Exception('Invalid username or password');
      }
    } catch (e) {
      state = state.copyWith(
        status: AuthStatus.error,
        errorMessage: e.toString().replaceFirst('Exception: ', ''),
      );
    }
  }

  /// 初始化登录流程（Login Flow v2，保留用于未来需要）
  /// 
  /// [serverUrl] 可选的服务器地址，如果不提供则使用服务中已配置的地址
  Future<void> initiateLogin({String? serverUrl}) async {
    if (state.isLoading) return;

    // 如果提供了新的服务器地址，创建新的服务实例
    final service = serverUrl != null
        ? CaleeAuthService(serverBaseUrl: serverUrl)
        : _service;

    state = state.copyWith(
      status: AuthStatus.initiating,
      clearError: true,
    );

    try {
      final response = await service.initiateLoginFlow();
      
      final loginUrl = response['login'] as String?;
      final poll = response['poll'] as Map<String, dynamic>?;
      final pollToken = poll?['token'] as String?;
      final pollEndpoint = poll?['endpoint'] as String?;

      if (loginUrl == null || pollToken == null || pollEndpoint == null) {
        throw Exception('Invalid login flow response from server');
      }

      state = state.copyWith(
        status: AuthStatus.polling,
        loginUrl: loginUrl,
        pollToken: pollToken,
        pollEndpoint: pollEndpoint,
      );

      // 开始轮询（使用新的服务实例）
      _startPolling(service);
    } catch (e) {
      state = state.copyWith(
        status: AuthStatus.error,
        errorMessage: e.toString().replaceFirst('Exception: ', ''),
      );
    }
  }

  /// 开始轮询登录状态
  void _startPolling([CaleeAuthService? service]) {
    final authService = service ?? _service;
    _pollAttempts = 0;
    _pollTimer?.cancel();
    
    _pollTimer = Timer.periodic(_pollInterval, (timer) async {
      if (_pollAttempts >= _maxPollAttempts) {
        _stopPolling();
        state = state.copyWith(
          status: AuthStatus.error,
          errorMessage: 'Login timeout. Please try again.',
        );
        return;
      }

      _pollAttempts++;

      try {
        final result = await authService.pollLoginStatus(
          pollToken: state.pollToken!,
          pollEndpoint: state.pollEndpoint!,
        );

        // 如果返回了 server, loginName, appPassword，说明登录成功
        if (result.containsKey('server') &&
            result.containsKey('loginName') &&
            result.containsKey('appPassword')) {
          _stopPolling();
          
          state = state.copyWith(
            status: AuthStatus.success,
            serverUrl: result['server'] as String?,
            loginName: result['loginName'] as String?,
            appPassword: result['appPassword'] as String?,
          );
        }
        // 如果返回 status: 'pending'，继续轮询
        else if (result['status'] == 'pending') {
          // 继续轮询，状态不变
        } else {
          // 其他情况，可能出错
          _stopPolling();
          state = state.copyWith(
            status: AuthStatus.error,
            errorMessage: 'Unexpected response from server',
          );
        }
      } catch (e) {
        // 轮询出错，可能是网络问题，继续尝试
        // 如果超过最大次数，会由上面的超时逻辑处理
      }
    });
  }

  /// 停止轮询
  void _stopPolling() {
    _pollTimer?.cancel();
    _pollTimer = null;
    _pollAttempts = 0;
  }

  /// 取消登录流程
  void cancelLogin() {
    _stopPolling();
    state = const AuthState();
  }

  /// 重置状态
  void reset() {
    _stopPolling();
    state = const AuthState();
  }

  @override
  void dispose() {
    _stopPolling();
    super.dispose();
  }
}

