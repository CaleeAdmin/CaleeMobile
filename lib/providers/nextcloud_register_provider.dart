import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:caleesync/models/nextcloud_register_state.dart';
import 'package:caleesync/services/nextcloud_register_service.dart';

/// Nextcloud 注册服务 Provider
final nextcloudRegisterServiceProvider = Provider<NextcloudRegisterService>((ref) {
  return NextcloudRegisterService();
});

/// Nextcloud 注册状态 Provider
final nextcloudRegisterStateProvider =
    StateNotifierProvider<NextcloudRegisterNotifier, NextcloudRegisterState>((ref) {
  final service = ref.watch(nextcloudRegisterServiceProvider);
  return NextcloudRegisterNotifier(service);
});

/// Nextcloud 注册状态管理器
class NextcloudRegisterNotifier extends StateNotifier<NextcloudRegisterState> {
  final NextcloudRegisterService _service;

  NextcloudRegisterNotifier(this._service)
      : super(const NextcloudRegisterState());

  /// 注册新用户
  /// 
  /// [userid] 用户名（Nextcloud 使用 userid）
  /// [password] 密码
  /// [email] 邮箱地址
  Future<void> register({
    required String userid,
    required String password,
    required String email,
  }) async {
    if (state.isLoading) return;

    state = state.copyWith(
      status: NextcloudRegisterStatus.registering,
      clearError: true,
    );

    try {
      final success = await _service.register(
        userid: userid,
        password: password,
        email: email,
      );

      if (success) {
        state = state.copyWith(
          status: NextcloudRegisterStatus.success,
        );
      } else {
        throw Exception('Registration failed');
      }
    } catch (e) {
      state = state.copyWith(
        status: NextcloudRegisterStatus.error,
        errorMessage: e.toString().replaceFirst('Exception: ', ''),
      );
    }
  }

  /// 重置状态
  void reset() {
    state = const NextcloudRegisterState();
  }
}

