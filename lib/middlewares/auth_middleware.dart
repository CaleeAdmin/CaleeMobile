import 'package:caleesync/common/route_constant.dart';
import 'package:caleesync/controllers/app_controller.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

class AuthMiddleware extends GetMiddleware {
  @override
  int? get priority => 1;

  @override
  RouteSettings? redirect(String? route) {
    final appController = Get.find<AppController>();

    // 等待控制器初始化完成
    if (!appController.isLoggedIn) {
      // 重新检查登录状态
      WidgetsBinding.instance.addPostFrameCallback((_) {
        appController.init();
      });
    }

    // 检查路由权限
    final redirectRoute = appController.checkRoutePermission(route ?? '');

    if (redirectRoute != null) {
      return RouteSettings(name: redirectRoute);
    }

    return null;
  }
}
