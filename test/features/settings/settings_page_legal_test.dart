// The Legal section in signed-in Settings (CaleeAdmin/calee-hub-web#107).
//
// Before this, a signed-in Calee user had no way to reach the Privacy Policy
// or the Terms of Use from inside the app at all — the only legal link
// anywhere was a single Portal Terms button on the signed-out screens.
//
// SettingsPage loads local preferences via CaleePreferences, which performs a
// one-time migration from FlutterSecureStorage. Setting the migration-done flag
// in mock SharedPreferences (plus stubbing the secure-storage channel) keeps
// the platform channels from hanging the test — same setup as
// settings_page_content_test.dart.

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

// The Legal section renders near the bottom of SettingsPage's ListView. The
// default 800x600 test surface never lays those rows out via the sliver list's
// cache extent, so a finder reports nothing even though the widget exists.
// Widen the surface instead of simulating a scroll gesture -- same approach as
// settings_page_content_test.dart.
Future<List<String>> _pumpSettings(WidgetTester tester) async {
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  tester.view.physicalSize = const Size(800, 2400);
  tester.view.devicePixelRatio = 1.0;

  final opened = <String>[];
  await tester.pumpWidget(
    MaterialApp(
      theme: CaleeTheme.buildThemeData(),
      home: Scaffold(
        body: SettingsPage(
          hubClient: _StubHubClient(),
          accessToken: 'tok',
          bootstrap: _bootstrap(),
          onSignOut: () {},
          legalLinkLauncher: (url) async => opened.add(url),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return opened;
}

void main() {
  setUp(() {
    // Mark the secure-storage -> shared-prefs migration as already done so
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

  testWidgets('Settings has a Legal section with both documents', (
    tester,
  ) async {
    await _pumpSettings(tester);

    final privacy = find.byKey(const Key('settings_privacy_policy_row'));
    final terms = find.byKey(const Key('settings_terms_of_use_row'));

    await tester.ensureVisible(privacy);
    await tester.pumpAndSettle();

    expect(privacy, findsOneWidget);
    expect(terms, findsOneWidget);
    expect(find.text('LEGAL'), findsOneWidget);
  });

  testWidgets('the Privacy Policy row opens the canonical URL', (tester) async {
    final opened = await _pumpSettings(tester);

    final privacy = find.byKey(const Key('settings_privacy_policy_row'));
    await tester.ensureVisible(privacy);
    await tester.pumpAndSettle();
    await tester.tap(privacy);
    await tester.pumpAndSettle();

    expect(opened, ['https://calee.com.au/privacy/']);
  });

  testWidgets('the Terms of Use row opens the canonical URL', (tester) async {
    final opened = await _pumpSettings(tester);

    final terms = find.byKey(const Key('settings_terms_of_use_row'));
    await tester.ensureVisible(terms);
    await tester.pumpAndSettle();
    await tester.tap(terms);
    await tester.pumpAndSettle();

    expect(opened, ['https://calee.com.au/terms/']);
  });

  // The legal rows are informational. Settings must not turn them into an
  // acceptance step: #107 leaves terms acceptance as an open product/legal
  // decision, and a re-consent prompt here would imply recorded consent that
  // nothing stores.
  testWidgets('the Legal section records no acceptance', (tester) async {
    await _pumpSettings(tester);

    await tester.ensureVisible(
      find.byKey(const Key('settings_privacy_policy_row')),
    );
    await tester.pumpAndSettle();

    expect(find.text('Accept'), findsNothing);
    expect(find.text('I agree'), findsNothing);
    expect(find.textContaining('accepted on'), findsNothing);
  });
}
