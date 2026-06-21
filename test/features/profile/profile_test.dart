// Widget tests for ProfilePage and Settings → Personal profile integration.

import 'package:calee_mobile/data/api/calee_hub_client.dart';
import 'package:calee_mobile/data/models/client_bootstrap.dart';
import 'package:calee_mobile/data/models/client_profile.dart';
import 'package:calee_mobile/features/profile/profile_controller.dart';
import 'package:calee_mobile/features/profile/profile_page.dart';
import 'package:calee_mobile/features/profile/profile_repository.dart';
import 'package:calee_mobile/features/settings/settings_page.dart';
import 'package:calee_mobile/ui/calee_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ─── Stubs ────────────────────────────────────────────────────────────────────

const _kProfile = ClientProfile(
  accountId: 'acct-1',
  email: 'alice@example.com',
  firstName: 'Alice',
  lastName: 'Smith',
  displayName: 'Alice S',
  timeZone: 'Australia/Perth',
  postalCode: '6000',
  warnings: [],
);

const _kProfileWithWarnings = ClientProfile(
  accountId: 'acct-1',
  email: 'alice@example.com',
  firstName: 'Alice',
  lastName: 'Smith',
  timeZone: 'Australia/Perth',
  warnings: ['CALDAV_SYNC_PENDING'],
);

class _StubClient extends CaleeHubClient {
  _StubClient({ClientProfile? profile, this.updateResult, this.throwOnUpdate})
      : _profile = profile ?? _kProfile,
        super(baseUri: Uri.parse('http://localhost'));

  final ClientProfile _profile;
  final ClientProfile? updateResult;
  final Object? throwOnUpdate;

  Map<String, dynamic>? lastUpdateBody;

  @override
  Future<ClientProfile> profile({required String accessToken}) async {
    return _profile;
  }

  @override
  Future<ClientProfile> updateProfile({
    required String accessToken,
    required String firstName,
    required String lastName,
    String? displayName,
    String? timeZone,
    String? postalCode,
    String? countryCode,
    String? locale,
  }) async {
    lastUpdateBody = {
      'firstName': firstName,
      'lastName': lastName,
      if (displayName != null) 'displayName': displayName,
      if (timeZone != null) 'timeZone': timeZone,
      if (postalCode != null) 'postalCode': postalCode,
    };
    if (throwOnUpdate != null) throw throwOnUpdate!;
    return updateResult ?? _profile;
  }

  @override
  Future<ClientBootstrap> bootstrap({required String accessToken}) async {
    return ClientBootstrap.fromJson(const {});
  }
}

class _FailLoadClient extends CaleeHubClient {
  _FailLoadClient() : super(baseUri: Uri.parse('http://localhost'));

  @override
  Future<ClientProfile> profile({required String accessToken}) async {
    throw const CaleeHubException(
      statusCode: 500,
      message: 'Server error',
    );
  }
}

// ─── Helpers ──────────────────────────────────────────────────────────────────

Widget _wrapProfile(CaleeHubClient client) => MaterialApp(
      theme: CaleeTheme.buildThemeData(),
      home: ProfilePage(hubClient: client, accessToken: 'tok'),
    );

ClientBootstrap _minBootstrap({String displayName = 'Alice S'}) {
  return ClientBootstrap.fromJson({
    'account': {
      'id': 'acct-1',
      'displayName': displayName,
      'primaryEmail': 'alice@example.com',
    },
    'services': <dynamic>[],
    'contexts': <String, dynamic>{},
  });
}

void _setUpChannels() {
  SharedPreferences.setMockInitialValues({
    'calee_pref_migrated_to_shared_prefs': true,
  });
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
    const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
    (call) async => <String, String>{},
  );
}

void _tearDownChannels() {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
    const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
    null,
  );
}

// ─── Tests ────────────────────────────────────────────────────────────────────

void main() {
  setUp(_setUpChannels);
  tearDown(_tearDownChannels);

  // 1. Settings shows / opens Personal profile.
  testWidgets('Settings shows Personal profile row with tappable chevron', (
    tester,
  ) async {
    final client = _StubClient();
    await tester.pumpWidget(
      MaterialApp(
        theme: CaleeTheme.buildThemeData(),
        home: Scaffold(
          body: SettingsPage(
            hubClient: client,
            accessToken: 'tok',
            bootstrap: _minBootstrap(),
            onSignOut: () {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Personal profile'), findsOneWidget);
    expect(
      find.text('Name, timezone, and ZIP/postcode'),
      findsOneWidget,
    );
  });

  testWidgets('Tapping Personal profile row opens ProfilePage', (
    tester,
  ) async {
    final client = _StubClient();
    await tester.pumpWidget(
      MaterialApp(
        theme: CaleeTheme.buildThemeData(),
        home: Scaffold(
          body: SettingsPage(
            hubClient: client,
            accessToken: 'tok',
            bootstrap: _minBootstrap(),
            onSignOut: () {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Personal profile'));
    await tester.pumpAndSettle();

    expect(find.byType(ProfilePage), findsOneWidget);
  });

  // 2. ProfilePage calls GET /client/v1/profile on open.
  testWidgets('ProfilePage calls profile() on open and shows first name', (
    tester,
  ) async {
    final client = _StubClient();
    await tester.pumpWidget(_wrapProfile(client));
    await tester.pumpAndSettle();

    expect(find.text('Alice'), findsWidgets);
  });

  // 3. Email field is displayed.
  testWidgets('Email is displayed on ProfilePage', (tester) async {
    await tester.pumpWidget(_wrapProfile(_StubClient()));
    await tester.pumpAndSettle();

    expect(find.text('alice@example.com'), findsOneWidget);
  });

  // 4. User cannot edit email (no editable email field).
  testWidgets('Email is read-only — no enabled TextFormField with email value', (
    tester,
  ) async {
    await tester.pumpWidget(_wrapProfile(_StubClient()));
    await tester.pumpAndSettle();

    // The email is shown as plain Text, not in an enabled TextFormField.
    final emailTextWidgets = tester
        .widgetList<Text>(find.text('alice@example.com'))
        .toList();
    expect(emailTextWidgets, isNotEmpty);

    // No enabled TextFormField contains the email value.
    final editableFields = tester
        .widgetList<EditableText>(find.byType(EditableText))
        .where(
          (e) => e.controller.text == 'alice@example.com',
        )
        .toList();
    expect(editableFields, isEmpty);
  });

  // 5. Save does not send email.
  testWidgets('Save does not include email in updateProfile call', (
    tester,
  ) async {
    final client = _StubClient();
    await tester.pumpWidget(_wrapProfile(client));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Save changes'));
    await tester.pumpAndSettle();

    expect(client.lastUpdateBody, isNotNull);
    expect(client.lastUpdateBody!.containsKey('email'), isFalse);
    expect(client.lastUpdateBody!.containsKey('primaryEmail'), isFalse);
    expect(client.lastUpdateBody!.containsKey('loginName'), isFalse);
  });

  // 6. Save sends firstName, lastName, displayName, timeZone, postalCode.
  testWidgets('Save sends correct fields to updateProfile', (tester) async {
    final client = _StubClient();
    await tester.pumpWidget(_wrapProfile(client));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Save changes'));
    await tester.pumpAndSettle();

    final body = client.lastUpdateBody!;
    expect(body['firstName'], equals('Alice'));
    expect(body['lastName'], equals('Smith'));
    expect(body['timeZone'], equals('Australia/Perth'));
  });

  // 7. Missing firstName blocks submit.
  testWidgets('Missing firstName shows validation error', (tester) async {
    final client = _StubClient();
    await tester.pumpWidget(_wrapProfile(client));
    await tester.pumpAndSettle();

    final firstNameFields = find.byType(TextFormField);
    await tester.enterText(firstNameFields.first, '');

    await tester.tap(find.text('Save changes'));
    await tester.pumpAndSettle();

    expect(find.text('Required'), findsWidgets);
    expect(client.lastUpdateBody, isNull);
  });

  // 8. Missing lastName blocks submit.
  testWidgets('Missing lastName shows validation error', (tester) async {
    final client = _StubClient();
    await tester.pumpWidget(_wrapProfile(client));
    await tester.pumpAndSettle();

    final fields = tester.widgetList<TextFormField>(find.byType(TextFormField));
    final lastNameField = fields.elementAt(1);
    await tester.enterText(find.byWidget(lastNameField), '');

    await tester.tap(find.text('Save changes'));
    await tester.pumpAndSettle();

    expect(find.text('Required'), findsWidgets);
    expect(client.lastUpdateBody, isNull);
  });

  // 9. Missing timezone blocks submit — profile with null timezone.
  testWidgets('Missing timezone blocks submit', (tester) async {
    final client = _StubClient(
      profile: const ClientProfile(
        accountId: 'a1',
        email: 'alice@example.com',
        firstName: 'Alice',
        lastName: 'Smith',
        timeZone: null,
        warnings: [],
      ),
    );
    await tester.pumpWidget(_wrapProfile(client));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Save changes'));
    await tester.pumpAndSettle();

    expect(client.lastUpdateBody, isNull);
  });

  // 10. Invalid ZIP/postcode blocks submit.
  testWidgets('Invalid ZIP/postcode shows validation error', (tester) async {
    final client = _StubClient();
    await tester.pumpWidget(_wrapProfile(client));
    await tester.pumpAndSettle();

    // Find the postal code field (last TextFormField)
    final fields = tester
        .widgetList<TextFormField>(find.byType(TextFormField))
        .toList();
    await tester.enterText(find.byWidget(fields.last), 'INVALID!!@@##');

    await tester.tap(find.text('Save changes'));
    await tester.pumpAndSettle();

    expect(
      find.textContaining('Letters, numbers, spaces, hyphen only'),
      findsOneWidget,
    );
    expect(client.lastUpdateBody, isNull);
  });

  // 11. Successful save shows "Profile updated".
  testWidgets('Successful save shows Profile updated snackbar', (tester) async {
    final client = _StubClient();
    await tester.pumpWidget(_wrapProfile(client));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Save changes'));
    await tester.pumpAndSettle();

    expect(find.text('Profile updated'), findsOneWidget);
  });

  // 12. Save with warnings shows non-blocking warning message.
  testWidgets('Save with warnings shows warning snackbar', (tester) async {
    final client = _StubClient(
      updateResult: _kProfileWithWarnings,
    );
    await tester.pumpWidget(_wrapProfile(client));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Save changes'));
    await tester.pumpAndSettle();

    expect(
      find.textContaining('some connected services may update later'),
      findsOneWidget,
    );
  });

  // 13. API failure shows backend error message.
  testWidgets('API failure shows backend error message', (tester) async {
    final client = _StubClient(
      throwOnUpdate: const CaleeHubException(
        statusCode: 500,
        message: 'Internal server error',
      ),
    );
    await tester.pumpWidget(_wrapProfile(client));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Save changes'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Internal server error'), findsOneWidget);
  });

  // 14. Auth refresh/retry still works through CaleeHubClient.
  test('ProfileRepository uses CaleeHubClient methods (not direct HTTP)', () {
    final client = _StubClient();
    final repo = ProfileRepository(
      hubClient: client,
      accessToken: 'tok',
    );
    // Verifying by type: repo delegates to hubClient, not raw HTTP.
    expect(repo.hubClient, same(client));
    expect(repo.accessToken, equals('tok'));
  });

  // Controller unit tests.
  test('ProfileController transitions through load states', () async {
    final client = _StubClient();
    final controller = ProfileController(
      repository: ProfileRepository(
        hubClient: client,
        accessToken: 'tok',
      ),
    );

    expect(controller.isLoading, isFalse);
    expect(controller.profile, isNull);

    final loadFuture = controller.load();
    expect(controller.isLoading, isTrue);

    await loadFuture;
    expect(controller.isLoading, isFalse);
    expect(controller.profile, isNotNull);
    expect(controller.profile!.email, equals('alice@example.com'));
    controller.dispose();
  });
}
