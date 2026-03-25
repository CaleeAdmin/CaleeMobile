import 'package:caleesync/common/app_constant.dart';
import 'package:caleesync/common/utils/mmkv_utils.dart';
import 'package:caleesync/controllers/calendar_probe_controller.dart';
import 'package:caleesync/entity/SyncSummary.dart';
import 'package:caleesync/home/DashboardPage.dart';
import 'package:caleesync/main.dart' as app_main;
import 'package:caleesync/sync/background_sync_scheduler.dart';
import 'package:caleesync/test_bootstrap.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';

class _FakeCalendarProbeController extends CalendarProbeController {
  @override
  Future<void> refreshOverviewState() async {}
}

void main() {
  setUp(() async {
    await bootstrapTestStorage();
    MMKVUtils.instance.clear();
    Get.reset();
    Get.testMode = true;
    BackgroundSyncScheduler.debugForceIosForTesting = null;
    CalendarProbeController.debugForceIosForTesting = null;
  });

  test('migrateLegacyIosSyncMode seeds deprecation flag and disables old toggles', () {
    MMKVUtils.instance.setBool(AppConstant.autoSyncEnabledKey, true);
    MMKVUtils.instance.setBool(AppConstant.periodicSyncEnabledKey, true);

    app_main.migrateLegacyIosSyncModeForTesting(isIOS: true);

    expect(MMKVUtils.instance.getBool(AppConstant.iosLegacySyncDeprecatedKey, defaultValue: false), isTrue);
    expect(MMKVUtils.instance.getBool(AppConstant.autoSyncEnabledKey, defaultValue: true), isFalse);
    expect(MMKVUtils.instance.getBool(AppConstant.periodicSyncEnabledKey, defaultValue: true), isFalse);
  });

  test('iOS scheduler methods are no-op and stay disabled', () async {
    BackgroundSyncScheduler.debugForceIosForTesting = true;

    await BackgroundSyncScheduler.setPeriodicEnabled(true);
    await BackgroundSyncScheduler.scheduleOneOff(reason: 'test_oneoff');
    final status = await BackgroundSyncScheduler.getStatus();

    expect(MMKVUtils.instance.getBool(AppConstant.periodicSyncEnabledKey, defaultValue: true), isFalse);
    expect(status.periodicEnabled, isFalse);
    expect(status.periodicConfigured, isFalse);
    expect(status.workerRunning, isFalse);
  });

  test('CalendarProbeController.syncNow returns immediately on iOS', () async {
    CalendarProbeController.debugForceIosForTesting = true;
    final controller = CalendarProbeController();
    final seeded = SyncSummary()
      ..success = 3
      ..failed = 1
      ..processing = 0;
    controller.summary.value = seeded;

    final result = await controller.syncNow();

    expect(result.success, 3);
    expect(result.failed, 1);
    expect(controller.isSyncing.value, isFalse);
    expect(controller.processing.value, 0);
  });

  testWidgets('dashboard migration notice appears and can be dismissed once', (tester) async {
    MMKVUtils.instance.setBool(AppConstant.iosLegacySyncDeprecatedKey, true);
    MMKVUtils.instance.setBool(AppConstant.iosLegacySyncNoticeDismissedKey, false);
    Get.put<CalendarProbeController>(_FakeCalendarProbeController());

    await tester.pumpWidget(
      const GetMaterialApp(
        home: Scaffold(
          body: DashboardPage(forceIosMode: true),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('iPhone sync has moved'), findsOneWidget);
    expect(find.text('Set Up Connections'), findsOneWidget);

    await tester.tap(find.text('Dismiss'));
    await tester.pumpAndSettle();

    expect(MMKVUtils.instance.getBool(AppConstant.iosLegacySyncNoticeDismissedKey, defaultValue: false), isTrue);
    expect(find.text('iPhone sync has moved'), findsNothing);
  });
}
