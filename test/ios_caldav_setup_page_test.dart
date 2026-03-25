import 'package:caleesync/common/app_constant.dart';
import 'package:caleesync/common/utils/mmkv_utils.dart';
import 'package:caleesync/feature/ios_caldav_setup_page.dart';
import 'package:caleesync/home/sync_settings_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'test_bootstrap.dart';

void main() {
  setUp(() async {
    await bootstrapTestStorage();
    MMKVUtils.instance.clear();
    Get.testMode = true;
  });

  testWidgets('blocked state shown when password missing', (tester) async {
    MMKVUtils.instance.setString(AppConstant.loginNameKey, 'ios-user@example.com');

    await tester.pumpWidget(
      const GetMaterialApp(
        home: IosCalDavSetupPage(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Setup blocked'), findsOneWidget);
    expect(find.textContaining('Please reconnect and sign in again'), findsOneWidget);
  });

  testWidgets('copyable rows shown when setup info is ready', (tester) async {
    MMKVUtils.instance.setString(AppConstant.serverKey, 'portal.calee.com.au/dav/user');
    MMKVUtils.instance.setString(AppConstant.loginNameKey, 'ios-user@example.com');
    MMKVUtils.instance.setString(AppConstant.appPasswordKey, 'app-pass-123');
    MMKVUtils.instance.setString(AppConstant.calendarAccountNameKey, 'Calee Work');

    await tester.pumpWidget(
      const GetMaterialApp(
        home: IosCalDavSetupPage(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('CalDAV account values'), findsOneWidget);
    expect(find.text('Server'), findsOneWidget);
    expect(find.text('Username'), findsOneWidget);
    expect(find.text('Password'), findsOneWidget);
    expect(find.text('Description'), findsOneWidget);
    expect(find.byIcon(Icons.copy), findsNWidgets(4));
  });

  testWidgets('iOS connection tile opens the new setup page', (tester) async {
    await tester.pumpWidget(
      const GetMaterialApp(
        home: Scaffold(
          body: SyncSettingsPage(forceIosConnectionsMode: true),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Add Calee Calendar to iPhone'));
    await tester.pumpAndSettle();

    expect(find.text('Add Calee Calendar to iPhone'), findsWidgets);
    expect(find.text('iPhone setup steps'), findsOneWidget);
  });
}
