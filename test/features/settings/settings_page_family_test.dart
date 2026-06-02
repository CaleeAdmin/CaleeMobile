import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:calee_mobile/data/api/calee_hub_client.dart';
import 'package:calee_mobile/data/models/client_bootstrap.dart';
import 'package:calee_mobile/data/models/client_calendar.dart';
import 'package:calee_mobile/data/models/client_person.dart';
import 'package:calee_mobile/features/settings/settings_page.dart';

// ── Fake client ───────────────────────────────────────────────────────────────

class _FakeHubClient extends CaleeHubClient {
  _FakeHubClient({
    required this.ensureResult,
    required this.freshBootstrap,
  }) : super(baseUri: Uri.parse('http://localhost'));

  final Object? ensureResult; // null = succeed; Exception subtype = throw
  final ClientBootstrap freshBootstrap;

  @override
  Future<ClientContext> ensureDefaultFamily({
    required String accessToken,
  }) async {
    final r = ensureResult;
    if (r is Exception) throw r;
    return const ClientContext(
      id: 'h1',
      type: 'household',
      name: 'My Family',
      role: 'admin',
      status: 'active',
    );
  }

  @override
  Future<ClientBootstrap> bootstrap({required String accessToken}) async {
    return freshBootstrap;
  }

  @override
  Future<ClientCalendarList> calendars({required String accessToken}) async {
    return const ClientCalendarList(calendars: []);
  }

  @override
  Future<ClientPersonList> people({
    required String accessToken,
    required String householdId,
    bool includeArchived = false,
  }) async {
    return const ClientPersonList(people: []);
  }
}

// ── Fixtures ─────────────────────────────────────────────────────────────────

ClientBootstrap _emptyBootstrap() => ClientBootstrap(
      account: const ClientAccount(
        id: 'acc1',
        displayName: 'Test User',
        primaryEmail: 'test@example.com',
        timeZone: null,
        status: 'active',
      ),
      services: const [],
      contexts: const ClientContexts(households: [], organisations: []),
      availableContexts: const [],
      capabilities: const {},
    );

ClientBootstrap _bootstrapWithHousehold() => ClientBootstrap(
      account: const ClientAccount(
        id: 'acc1',
        displayName: 'Test User',
        primaryEmail: 'test@example.com',
        timeZone: null,
        status: 'active',
      ),
      services: const [],
      contexts: ClientContexts(
        households: [
          const ClientContext(
            id: 'h1',
            type: 'household',
            name: 'My Family',
            role: 'admin',
            status: 'active',
          ),
        ],
        organisations: const [],
      ),
      availableContexts: const [],
      capabilities: const {},
    );

// ── Widget wrapper ─────────────────────────────────────────────────────────────
//
// SettingsPage.build() returns a ListView directly (no Scaffold) because in
// production it lives inside CaleeHomePage's Scaffold body. Tests must supply
// their own Scaffold so that InkWell / DropdownButton widgets can find the
// required Material ancestor.

Widget _wrapSettings({
  required CaleeHubClient client,
  required ClientBootstrap bootstrap,
  void Function(ClientBootstrap)? onBootstrapRefreshed,
}) {
  return MaterialApp(
    home: Scaffold(
      body: SettingsPage(
        hubClient: client,
        accessToken: 'test-token',
        bootstrap: bootstrap,
        onSignOut: () {},
        onBootstrapRefreshed: onBootstrapRefreshed,
      ),
    ),
  );
}

// Scrolls the first Scrollable until 'Family Members' is visible, then taps it.
// Required because SettingsPage uses a lazy ListView that may not build
// off-screen items in a constrained test viewport.
Future<void> _tapFamilyMembers(WidgetTester tester) async {
  await tester.scrollUntilVisible(
    find.text('Family Members'),
    300.0,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.tap(find.text('Family Members'));
}

// ── Tests ──────────────────────────────────────────────────────────────────────

void main() {
  group('SettingsPage family members flow', () {
    testWidgets(
        'empty households → ensureDefaultFamily succeeds → opens Family Members',
        (tester) async {
      final client = _FakeHubClient(
        ensureResult: null,
        freshBootstrap: _bootstrapWithHousehold(),
      );

      ClientBootstrap? receivedBootstrap;
      await tester.pumpWidget(_wrapSettings(
        client: client,
        bootstrap: _emptyBootstrap(),
        onBootstrapRefreshed: (b) => receivedBootstrap = b,
      ));

      // Wait for _loadAll to complete.
      await tester.pumpAndSettle();

      await _tapFamilyMembers(tester);
      await tester.pumpAndSettle();

      // HouseholdPeoplePage is pushed (not FamilySetupPage).
      expect(find.text('Family setup needed'), findsNothing);
      // autoOpenCreate fires _openCreateSheet — AddPersonSheet shows Cancel/Add buttons.
      expect(find.text('Cancel'), findsOneWidget);

      // Callback fired with the fresh bootstrap.
      expect(receivedBootstrap, isNotNull);
      expect(receivedBootstrap!.contexts.households, hasLength(1));
    });

    testWidgets(
        'non-empty households → navigates directly without ensureDefaultFamily',
        (tester) async {
      final client = _FakeHubClient(
        ensureResult: null,
        freshBootstrap: _bootstrapWithHousehold(),
      );

      await tester.pumpWidget(_wrapSettings(
        client: client,
        bootstrap: _bootstrapWithHousehold(),
      ));
      await tester.pumpAndSettle();

      await _tapFamilyMembers(tester);
      await tester.pumpAndSettle();

      // HouseholdPeoplePage pushed directly — shows Add Person row, not the fallback.
      expect(find.text('Family setup needed'), findsNothing);
      expect(find.text('Add Person'), findsAtLeastNWidgets(1));
    });

    testWidgets(
        'ensureDefaultFamily failure → shows family setup fallback page',
        (tester) async {
      final client = _FakeHubClient(
        ensureResult: const CaleeHubException(
          statusCode: 500,
          message: 'Server error',
        ),
        freshBootstrap: _emptyBootstrap(),
      );

      await tester.pumpWidget(_wrapSettings(
        client: client,
        bootstrap: _emptyBootstrap(),
      ));
      await tester.pumpAndSettle();

      await _tapFamilyMembers(tester);
      await tester.pumpAndSettle();

      // FamilySetupPage body text is shown.
      expect(find.text('Family setup needed'), findsOneWidget);
    });

    testWidgets(
        'ensureDefaultFamily succeeds but bootstrap still empty → shows family setup fallback',
        (tester) async {
      // ensureDefaultFamily returns a household but the fresh bootstrap has none.
      final client = _FakeHubClient(
        ensureResult: null,
        freshBootstrap: _emptyBootstrap(),
      );

      await tester.pumpWidget(_wrapSettings(
        client: client,
        bootstrap: _emptyBootstrap(),
      ));
      await tester.pumpAndSettle();

      await _tapFamilyMembers(tester);
      await tester.pumpAndSettle();

      expect(find.text('Family setup needed'), findsOneWidget);
    });
  });
}
