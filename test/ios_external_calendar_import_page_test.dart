import 'package:caleesync/feature/ios_external_calendar_import_page.dart';
import 'package:caleesync/home/sync_settings_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';

void main() {
  setUp(() {
    Get.testMode = true;
  });

  testWidgets('provider picker switches provider-specific content', (tester) async {
    await tester.pumpWidget(
      const GetMaterialApp(home: IosExternalCalendarImportPage()),
    );

    expect(find.text('Import iCloud Calendar'), findsOneWidget);
    expect(find.textContaining('Apple\'s public calendar link flow'), findsOneWidget);

    await tester.tap(find.text('Google'));
    await tester.pumpAndSettle();

    expect(find.text('Import Google Calendar'), findsOneWidget);
    expect(find.textContaining('Secret address in iCal format'), findsOneWidget);
  });

  testWidgets('empty URL blocks submit', (tester) async {
    await tester.pumpWidget(
      const GetMaterialApp(home: IosExternalCalendarImportPage()),
    );

    await tester.tap(find.text('Import iCloud Calendar'));
    await tester.pumpAndSettle();

    expect(find.text('Subscription URL is required.'), findsOneWidget);
  });

  testWidgets('second iOS connections tile opens new import page', (tester) async {
    await tester.pumpWidget(
      const GetMaterialApp(
        home: Scaffold(
          body: SyncSettingsPage(forceIosConnectionsMode: true),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Import iCloud / Google / Outlook into Calee'));
    await tester.pumpAndSettle();

    expect(find.text('Import Calendar into Calee'), findsOneWidget);
    expect(find.text('Imported calendars are read-only'), findsOneWidget);
  });
}
