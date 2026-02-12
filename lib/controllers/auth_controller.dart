import 'package:caleesync/common/app_constant.dart';
import 'package:caleesync/models/nextcloud_auth_state.dart';
import 'package:caleesync/models/nextcloud_register_state.dart';
import 'package:caleesync/services/nextcloud_auth_service.dart';
import 'package:caleesync/services/nextcloud_register_service.dart';
import 'package:get/get.dart';

class AuthController extends GetxController {
  final NextcloudAuthService _authService = NextcloudAuthService(serverBaseUrl: AppConstant.nextcloudServer);
  final NextcloudRegisterService _registerService = NextcloudRegisterService();

  // 认证状态
  final Rx<NextcloudAuthState> authStateRx = const NextcloudAuthState().obs;
  NextcloudAuthState get authState => authStateRx.value;

  // 注册状态
  final Rx<NextcloudRegisterState> registerStateRx = const NextcloudRegisterState().obs;
  NextcloudRegisterState get registerState => registerStateRx.value;

  // 登录状态
  final Rx<NextcloudAuthStatus> _authStatus = NextcloudAuthStatus.initial.obs;
  NextcloudAuthStatus get authStatus => _authStatus.value;

  // 注册状态
  final Rx<NextcloudRegisterStatus> _registerStatus = NextcloudRegisterStatus.initial.obs;
  NextcloudRegisterStatus get registerStatus => _registerStatus.value;

  @override
  void onInit() {
    super.onInit();
    // 监听认证状态变化
    ever(authStateRx, _handleAuthStateChange);
  }

  void _handleAuthStateChange(NextcloudAuthState state) {
    _authStatus.value = state.status;
  }

  // 登录方法
  Future<void> loginWithCredentials({
    required String loginName,
    required String password,
  }) async {
    try {
      authStateRx.value = const NextcloudAuthState(status: NextcloudAuthStatus.initiating);

      final success = await _authService.loginWithCredentials(
        loginName: loginName,
        password: password,
      );

      if (success) {
        final appPassword = await _authService.getAppPassword(
          loginName: loginName,
          password: password,
        );

        authStateRx.value = NextcloudAuthState(
          status: NextcloudAuthStatus.success,
          serverUrl: _authService.normalizedUrl,
          loginName: loginName,
          appPassword: appPassword,
        );
      } else {
        authStateRx.value = const NextcloudAuthState(
          status: NextcloudAuthStatus.error,
          errorMessage: 'Invalid username or password',
        );
      }
    } catch (e) {
      authStateRx.value = NextcloudAuthState(
        status: NextcloudAuthStatus.error,
        errorMessage: e.toString().replaceFirst('Exception: ', ''),
      );
    }
  }

  // 注册方法
  Future<void> registerWithCredentials({
    required String loginName,
    required String displayName,
    required String email,
    required String password,
  }) async {
    try {
      registerStateRx.value = const NextcloudRegisterState(status: NextcloudRegisterStatus.registering);

      final success = await _registerService.register(
        userid: loginName,
        password: password,
        email: email,
      );

      if (success) {
        registerStateRx.value = const NextcloudRegisterState(status: NextcloudRegisterStatus.success);
      } else {
        registerStateRx.value = const NextcloudRegisterState(
          status: NextcloudRegisterStatus.error,
          errorMessage: 'Registration failed',
        );
      }
    } catch (e) {
      registerStateRx.value = NextcloudRegisterState(
        status: NextcloudRegisterStatus.error,
        errorMessage: e.toString().replaceFirst('Exception: ', ''),
      );
    }
  }

  // 重置认证状态
  void resetAuthState() {
    authStateRx.value = const NextcloudAuthState();
  }

  // 重置注册状态
  void resetRegisterState() {
    registerStateRx.value = const NextcloudRegisterState();
  }
}
