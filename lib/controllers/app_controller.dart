import 'package:caleesync/common/app_constant.dart';
import 'package:caleesync/common/route_constant.dart';
import 'package:caleesync/common/utils/mmkv_utils.dart';
import 'package:get/get.dart';

class AppController extends GetxController {
  // 登录状态
  final RxBool _isLoggedIn = false.obs;

  bool get isLoggedIn => _isLoggedIn.value;

  // 初始化
  Future<void> init() async {
    await _checkLoginStatus();
  }

  // 检查登录状态
  Future<void> _checkLoginStatus() async {
    final serverUrl = MMKVUtils.instance.getString(AppConstant.Server);
    final loginName = MMKVUtils.instance.getString(AppConstant.loginName);
    final appPassword = MMKVUtils.instance.getString(AppConstant.password);

    _isLoggedIn.value = serverUrl != null &&
        serverUrl.isNotEmpty &&
        loginName != null &&
        loginName.isNotEmpty &&
        appPassword != null &&
        appPassword.isNotEmpty;
  }

  // 设置登录状态
  void setLoggedIn(bool value) {
    _isLoggedIn.value = value;
  }

  // 登录成功处理
  Future<void> onLoginSuccess() async {
    await _checkLoginStatus();
    setLoggedIn(true);

    // 跳转到主页
    Get.offAllNamed(RouteConstant.home);
  }

  // 登出处理
  void logout() {
    // 清除登录凭据
    MMKVUtils.instance.remove(AppConstant.Server);
    MMKVUtils.instance.remove(AppConstant.loginName);
    MMKVUtils.instance.remove(AppConstant.password);

    setLoggedIn(false);

    // 跳转到登录页
    Get.offAllNamed(RouteConstant.login);
  }

  // 获取初始路由
  String getInitialRoute() {
    return isLoggedIn ? RouteConstant.home : RouteConstant.login;
  }

  // 检查路由权限
  String? checkRoutePermission(String route) {
    final isLoggedIn = this.isLoggedIn;

    // 如果已登录，但访问登录页面，重定向到主页
    if (isLoggedIn && route == RouteConstant.login) {
      return RouteConstant.home;
    }

    // 如果未登录，但访问需要登录的页面，重定向到登录页
    if (!isLoggedIn && (route == RouteConstant.home || route == RouteConstant.profile)) {
      return RouteConstant.login;
    }

    // 其他情况不重定向
    return null;
  }
}
