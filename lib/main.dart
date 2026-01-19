import 'package:caleesync/common/app_constant.dart';
import 'package:caleesync/common/route_constant.dart';
import 'package:caleesync/common/utils/mmkv_utils.dart';
import 'package:caleesync/user/login_page.dart';
import 'package:caleesync/user/profile_page.dart';
import 'package:caleesync/user/register_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'data/database_helper.dart';
import 'home/calendar_probe_page.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await DatabaseHelper.instance.database;
  // 初始化 MMKV
  await MMKVUtils.instance.init();
  
  runApp(
    const ProviderScope(
      child: CaleeApp(),
    ),
  );
}

/// 检查用户是否已登录
bool _isLoggedIn() {
  final serverUrl = MMKVUtils.instance.getString(AppConstant.Server);
  final loginName = MMKVUtils.instance.getString(AppConstant.loginName);
  final appPassword = MMKVUtils.instance.getString(AppConstant.password);

  // 如果三个凭据都存在，则认为已登录
  return serverUrl != null && 
         serverUrl.isNotEmpty &&
         loginName != null && 
         loginName.isNotEmpty &&
         appPassword != null && 
         appPassword.isNotEmpty;
}

class CaleeApp extends StatelessWidget {
  const CaleeApp({super.key});

  @override
  Widget build(BuildContext context) {
    // 根据登录状态决定初始路由
    final initialLocation = _isLoggedIn() ? RouteConstant.home : RouteConstant.login;
    
    final router = GoRouter(
      initialLocation: initialLocation,
      redirect: (context, state) {
        final isLoggedIn = _isLoggedIn();
        final isGoingToLogin = state.matchedLocation == RouteConstant.login;
        final isGoingToRegister = state.matchedLocation == RouteConstant.register;
        
        // 如果已登录，但访问登录或注册页面，重定向到主页
        if (isLoggedIn && (isGoingToLogin || isGoingToRegister)) {
          return RouteConstant.home;
        }
        
        // 如果未登录，但访问主页或 Profile，重定向到登录页
        if (!isLoggedIn && 
            (state.matchedLocation == RouteConstant.home ||
             state.matchedLocation == RouteConstant.profile)) {
          return RouteConstant.login;
        }
        
        // 其他情况不重定向
        return null;
      },
      routes: [
        GoRoute(
          path: RouteConstant.login,
          builder: (context, state) => const LoginPage(),
        ),
        GoRoute(
          path: RouteConstant.register,
          builder: (context, state) => const RegisterPage(),
      ),
        GoRoute(
          path: RouteConstant.home,
          builder: (context, state) => const CalendarProbePage(),
        ),
        GoRoute(
          path: RouteConstant.profile,
          builder: (context, state) => const ProfilePage(),
        ),
      ],
    );

    return MaterialApp.router(
      title: 'Calee',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
        useMaterial3: true,
      ),
      routerConfig: router,
    );
  }
}
