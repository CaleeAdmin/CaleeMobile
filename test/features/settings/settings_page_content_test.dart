// Widget tests for SettingsPage content.
//
// Verifies the "Calendars and lists" management row is present and that the
// retired "Calee displays" row is no longer shown.
//
// SettingsPage loads local preferences via CaleePreferences, which performs a
// one-time migration from FlutterSecureStorage. Setting the migration-done flag
// in mock SharedPreferences (plus stubbing the secure-storage channel) keeps the
// platform channels from hanging the test.

import 'package:calee_mobile/data/api/calee_hub_client.dart';
import 'package:calee_mobile/data/models/client_bootstrap.dart';
import 'package:calee_mobile/data/models/client_calendar.dart';
import 'package:calee_mobile/features/settings/settings_page.dart';
import 'package:calee_mobile/ui/calee_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _StubHubClient extends CaleeHubClient {
  _StubHubClient() : super(baseUri: Uri.parse('http://localhost'));

  @override
  Future<ClientCalendarList> calendars({required String accessToken}) async {
    return const ClientCalendarList(calendars: []);
  }
}

ClientBootstrap _bootstrap() => ClientBootstrap(
  account: const ClientAccount(
    id: 'u1',
    displayName: 'Test User',
    primaryEmail: 'test@example.com',
    timeZone: 'Australia/Perth',
    status: 'active',
  ),
  services: const [],
  contexts: const ClientContexts(households: [], organisations: []),
  availableContexts: const [],
  capabilities: const {},
);

Widget _wrap() => MaterialApp(
  theme: CaleeTheme.buildThemeData(),
  home: SettingsPage(
    hubClient: _StubHubClient(),
    accessToken: 'tok',
    bootstrap: _bootstrap(),
    onSignOut: () {},
  ),
);

void main() {
  setUp(() {
    // Mark the secure-storage → shared-prefs migration as already done so
    // CaleePreferences.load() never reaches the FlutterSecureStorage channel.
    SharedPreferences.setMockInitialValues({
      'calee_pref_migrated_to_shared_prefs': true,
    });

    // Defensive: stub the secure-storage channel in case it is still hit.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel(
            'plugins.it_nomads.com/flutter_secure_storage',
          ),
          (call) async => <String, String>{},
        );
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel(
            'plugins.it_nomads.com/flutter_secure_storage',
          ),
          null,
        );
  });

  testWidgets('Settings shows "Calendars and lists" row', (tester) async {
    await tester.pumpWidget(_wrap());
    await tester.pumpAndSettle();

    expect(find.text('Calendars and lists'), findsOneWidget);
  });

  testWidgets('Settings does not show a "Calee displays" row', (tester) async {
    await tester.pumpWidget(_wrap());
    await tester.pumpAndSettle();

    expect(find.text('Calee displays'), findsNothing);
  });
}
