import 'dart:io';

import 'package:caleesync/common/app_constant.dart';
import 'package:caleesync/common/route_constant.dart';
import 'package:caleesync/common/utils/mmkv_utils.dart';
import 'package:caleesync/controllers/CalendarPageController.dart';
import 'package:caleesync/controllers/app_controller.dart';
import 'package:caleesync/controllers/auth_controller.dart';
import 'package:caleesync/middlewares/auth_middleware.dart';
import 'package:caleesync/user/login_page.dart';
import 'package:caleesync/user/profile_page.dart';
import 'package:caleesync/user/security_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:get/get.dart';

import 'data/database_helper.dart';
import 'data/sync_repository.dart';
import 'home/calendar_probe_page.dart';
import 'sync/background_sync_scheduler.dart';
import 'sync/background_sync_worker_bridge.dart';
import 'sync/sync_trigger_orchestrator.dart';

@pragma('vm:entry-point')
Future<void> caleeSyncBackgroundEntrypoint() async {
  await BackgroundSyncWorkerBridge.start();
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

// 1. 先注入数据库（如果有依赖）
  await Get.putAsync(() => DatabaseHelper.instance.init());

  // 初始化 MMKV
  await MMKVUtils.instance.init();
  _migrateLegacyIosSyncMode();
  _seedDefaultSyncSettings();

  // 2. 注入 Repository
  // 使用 permanent: true 确保它在整个 App 运行期间不被销毁
  Get.put(SyncRepository(), permanent: true);

  // 初始化 GetX 和应用控制器
  final appController = Get.put(AppController());
  Get.put(AuthController());
  Get.put(CalendarPageController());
  Get.put(SyncTriggerOrchestrator(), permanent: true);
  if (Platform.isAndroid) {
    await BackgroundSyncScheduler.selfHealPeriodicIfNeeded();
  }
  await appController.init();

  runApp(const CaleeApp());
}

void _migrateLegacyIosSyncMode({bool? isIOSOverride}) {
  final bool isIOS = isIOSOverride ?? Platform.isIOS;
  if (!isIOS) return;

  // Phase 6: iOS hidden app-level sync is fully deprecated.
  // Always seed this marker so iOS users can see the migration notice once.
  MMKVUtils.instance.setBool(AppConstant.iosLegacySyncDeprecatedKey, true);

  MMKVUtils.instance.setBool(AppConstant.autoSyncEnabledKey, false);
  MMKVUtils.instance.setBool(AppConstant.periodicSyncEnabledKey, false);
}

@visibleForTesting
void migrateLegacyIosSyncModeForTesting({required bool isIOS}) {
  _migrateLegacyIosSyncMode(isIOSOverride: isIOS);
}

void _seedDefaultSyncSettings() {
  if (!MMKVUtils.instance.contains(AppConstant.autoSyncEnabledKey)) {
    MMKVUtils.instance.setBool(AppConstant.autoSyncEnabledKey, Platform.isAndroid);
  }
  if (Platform.isIOS && !MMKVUtils.instance.contains(AppConstant.periodicSyncEnabledKey)) {
    MMKVUtils.instance.setBool(AppConstant.periodicSyncEnabledKey, false);
  }
}

class CaleeApp extends StatelessWidget {
  const CaleeApp({super.key});

  @override
  Widget build(BuildContext context) {
    return GetMaterialApp(
      title: 'Calee',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.lightGreen,
          brightness: Brightness.light,
        ),
        scaffoldBackgroundColor: const Color(0xFFF3FAF3),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFFF3FAF3),
          foregroundColor: Color(0xFF1B5E20),
        ),
        cardColor: const Color(0xFFFFFFFF),
        useMaterial3: true,
      ),
      initialRoute: Get.find<AppController>().getInitialRoute(),
      getPages: [
        GetPage(
          name: RouteConstant.login,
          page: () => const LoginPage(),
          middlewares: [AuthMiddleware()],
        ),
        GetPage(
          name: RouteConstant.home,
          page: () => const CalendarProbePage(),
          middlewares: [AuthMiddleware()],
        ),
        GetPage(
          name: RouteConstant.profile,
          page: () => const ProfilePage(),
          middlewares: [AuthMiddleware()],
        ),
        GetPage(
          name: RouteConstant.security,
          page: () => const SecurityPage(),
          middlewares: [AuthMiddleware()],
        ),
      ],
    );
  }
}
