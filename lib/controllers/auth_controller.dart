import 'package:caleesync/common/app_constant.dart';
import 'package:caleesync/models/auth_state.dart';
import 'package:caleesync/services/calee_auth_service.dart';
import 'package:get/get.dart';

class AuthController extends GetxController {
  final CaleeAuthService _authService = CaleeAuthService(serverBaseUrl: AppConstant.caleeServer);

  // 认证状态
  final Rx<AuthState> authStateRx = const AuthState().obs;
  AuthState get authState => authStateRx.value;

  // 登录状态
  final Rx<AuthStatus> _authStatus = AuthStatus.initial.obs;
  AuthStatus get authStatus => _authStatus.value;

  @override
  void onInit() {
    super.onInit();
    // 监听认证状态变化
    ever(authStateRx, _handleAuthStateChange);
  }

  void _handleAuthStateChange(AuthState state) {
    _authStatus.value = state.status;
  }

  // 登录方法
  Future<void> loginWithCredentials({
    required String loginName,
    required String password,
  }) async {
    try {
      authStateRx.value = const AuthState(status: AuthStatus.initiating);

      final success = await _authService.loginWithCredentials(
        loginName: loginName,
        password: password,
      );

      if (success) {
        final appPassword = await _authService.getAppPassword(
          loginName: loginName,
          password: password,
        );

        authStateRx.value = AuthState(
          status: AuthStatus.success,
          serverUrl: _authService.normalizedUrl,
          loginName: loginName,
          appPassword: appPassword,
        );
      } else {
        authStateRx.value = const AuthState(
          status: AuthStatus.error,
          errorMessage: 'Invalid username or password',
        );
      }
    } catch (e) {
      authStateRx.value = AuthState(
        status: AuthStatus.error,
        errorMessage: e.toString().replaceFirst('Exception: ', ''),
      );
    }
  }

  // 重置认证状态
  void resetAuthState() {
    authStateRx.value = const AuthState();
  }
}
