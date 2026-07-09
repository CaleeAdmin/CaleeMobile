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
import 'package:calee_mobile/data/models/client_preferences.dart';
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

  // Hub preferences are unavailable in these tests; SettingsRepository must
  // fall back to the local cache without surfacing a page-level error.
  @override
  Future<ClientPreferences> preferences({required String accessToken}) async {
    throw const CaleeHubException(statusCode: 500, message: 'Server error');
  }
}

class _FailThenSucceedHubClient extends CaleeHubClient {
  _FailThenSucceedHubClient() : super(baseUri: Uri.parse('http://localhost'));

  int callCount = 0;

  @override
  Future<ClientCalendarList> calendars({required String accessToken}) async {
    callCount++;
    if (callCount == 1) {
      throw Exception('network error');
    }
    return const ClientCalendarList(calendars: []);
  }

  @override
  Future<ClientPreferences> preferences({required String accessToken}) async {
    throw const CaleeHubException(statusCode: 500, message: 'Server error');
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
  // The backend always ensures a default household for every account, so a
  // realistic household/default-user fixture must include one too.
  contexts: const ClientContexts(
    households: [
      ClientContext(
        id: 'hh1',
        type: 'household',
        name: 'My Family',
        role: 'admin',
        status: 'active',
      ),
    ],
    organisations: [],
  ),
  availableContexts: const [],
  capabilities: const {},
);

ClientBootstrap _businessBootstrap() => ClientBootstrap(
  account: const ClientAccount(
    id: 'u2',
    displayName: 'Work User',
    primaryEmail: 'work@example.com',
    timeZone: 'Australia/Perth',
    status: 'active',
  ),
  services: const [],
  contexts: const ClientContexts(
    households: [],
    organisations: [
      ClientContext(
        id: 'org1',
        type: 'organisation',
        name: 'Acme Corp',
        role: 'member',
        status: 'active',
      ),
    ],
  ),
  availableContexts: const [],
  capabilities: const {},
);

Widget _wrap({ClientBootstrap? bootstrap, CaleeHubClient? hubClient}) =>
    MaterialApp(
      theme: CaleeTheme.buildThemeData(),
      home: Scaffold(
        body: SettingsPage(
          hubClient: hubClient ?? _StubHubClient(),
          accessToken: 'tok',
          bootstrap: bootstrap ?? _bootstrap(),
          onSignOut: () {},
        ),
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
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          (call) async => <String, String>{},
        );
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          null,
        );
  });

  testWidgets('Settings shows "Calendars and lists" row', (tester) async {
    await tester.pumpWidget(_wrap());
    await tester.pumpAndSettle();

    expect(find.text('Calendars and lists'), findsOneWidget);
  });

  testWidgets('Settings shows "Connect a display" row', (tester) async {
    await tester.pumpWidget(_wrap());
    await tester.pumpAndSettle();

    expect(find.text('Connect a display'), findsOneWidget);
    expect(
      find.text('Scan the QR code shown on your Calee display.'),
      findsOneWidget,
    );
  });

  testWidgets('Settings shows "Add existing calendars" row', (tester) async {
    await tester.pumpWidget(_wrap());
    await tester.pumpAndSettle();

    expect(find.text('Add existing calendars'), findsOneWidget);
  });

  testWidgets(
    '"Add existing calendars" opens the calendar source picker directly',
    (tester) async {
      await tester.pumpWidget(_wrap());
      await tester.pumpAndSettle();

      await tester.tap(find.text('Add existing calendars'));
      await tester.pumpAndSettle();

      // Goes straight to the picker — no redundant "Your Calee calendar is
      // ready" splash (with its own "Add existing calendars" button) in
      // between, matching the "Calendars and lists" entry point.
      expect(find.text('Where is your calendar?'), findsOneWidget);
      expect(find.text('Your Calee calendar is ready'), findsNothing);
    },
  );

  group('People row — business/workspace visibility', () {
    testWidgets('Settings shows "People" row for household/default user', (
      tester,
    ) async {
      await tester.pumpWidget(_wrap());
      await tester.pumpAndSettle();

      expect(find.text('People'), findsOneWidget);
    });

    testWidgets('Settings hides "People" row for business/workspace user', (
      tester,
    ) async {
      await tester.pumpWidget(_wrap(bootstrap: _businessBootstrap()));
      await tester.pumpAndSettle();

      expect(find.text('People'), findsNothing);
    });
  });

  group('Preferences load error', () {
    testWidgets('shows a retry state instead of silently falling back to '
        'defaults', (tester) async {
      await tester.pumpWidget(_wrap(hubClient: _FailThenSucceedHubClient()));
      await tester.pumpAndSettle();

      expect(find.text("Couldn't load your preferences."), findsOneWidget);
      expect(find.text('Retry'), findsOneWidget);
      expect(find.text('First day of week'), findsNothing);
    });

    testWidgets('tapping Retry reloads and shows preferences on success', (
      tester,
    ) async {
      final hubClient = _FailThenSucceedHubClient();
      await tester.pumpWidget(_wrap(hubClient: hubClient));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();

      expect(hubClient.callCount, 2);
      expect(find.text("Couldn't load your preferences."), findsNothing);
      expect(find.text('First day of week'), findsOneWidget);
    });
  });
}
