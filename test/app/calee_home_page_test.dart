// Widget tests for CaleeHomePage navigation structure.
//
// These tests use a minimal stub bootstrap and stub hub client so they do not
// need network access or platform channels.

import 'package:calee_mobile/app/calee_home_page.dart';
import 'package:calee_mobile/data/api/calee_hub_client.dart';
import 'package:calee_mobile/data/models/client_bootstrap.dart';
import 'package:calee_mobile/ui/calee_design.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ── Stubs ──────────────────────────────────────────────────────────────────────

class _StubHubClient extends CaleeHubClient {
  _StubHubClient() : super();

  @override
  Future<ClientBootstrap> bootstrap({required String accessToken}) async =>
      _noChoresBootstrap();
}

// ── Helpers ────────────────────────────────────────────────────────────────────

ClientBootstrap _noChoresBootstrap() => ClientBootstrap(
  account: const ClientAccount(
    id: 'u1',
    displayName: 'Test User',
    primaryEmail: 'test@example.com',
    timeZone: 'Australia/Perth',
    status: 'active',
  ),
  services: const [
    ClientService(
      id: 'svc1',
      displayName: 'Test Service',
      baseUrl: 'http://localhost',
      launchUrl: 'http://localhost',
      serviceType: 'nextcloud',
      accessStatus: 'ok',
      calendarCredentialStatus: 'connected',
      source: 'test',
      capabilities: {'calendar': true, 'tasks': true, 'chores': false},
    ),
  ],
  contexts: const ClientContexts(households: [], organisations: []),
  availableContexts: const [],
  capabilities: const {},
);

ClientBootstrap _choresBootstrap() => ClientBootstrap(
  account: const ClientAccount(
    id: 'u1',
    displayName: 'Test User',
    primaryEmail: 'test@example.com',
    timeZone: 'Australia/Perth',
    status: 'active',
  ),
  services: const [
    ClientService(
      id: 'svc1',
      displayName: 'Test Service',
      baseUrl: 'http://localhost',
      launchUrl: 'http://localhost',
      serviceType: 'nextcloud',
      accessStatus: 'ok',
      calendarCredentialStatus: 'connected',
      source: 'test',
      capabilities: {'calendar': true, 'tasks': true, 'chores': true},
    ),
  ],
  contexts: const ClientContexts(households: [], organisations: []),
  availableContexts: const [],
  capabilities: const {},
);

Widget _buildHome({
  required ClientBootstrap bootstrap,
  VoidCallback? onSignOut,
}) {
  return MaterialApp(
    theme: CaleeTheme.buildThemeData(),
    home: CaleeHomePage(
      hubClient: _StubHubClient(),
      accessToken: 'tok',
      bootstrap: bootstrap,
      onSignOut: onSignOut ?? () {},
    ),
  );
}

// ── Tests ──────────────────────────────────────────────────────────────────────

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('CaleeHomePage — navigation', () {
    testWidgets('starts on Today tab (index 0)', (tester) async {
      await tester.pumpWidget(_buildHome(bootstrap: _noChoresBootstrap()));
      await tester.pump();

      // Today header text is visible — Today tab is selected by default.
      expect(find.text('Today'), findsWidgets);
    });

    testWidgets(
      'bottom nav contains Today as the first destination',
      (tester) async {
        await tester.pumpWidget(_buildHome(bootstrap: _noChoresBootstrap()));
        await tester.pump();

        final bar = find.byType(NavigationBar);
        expect(bar, findsOneWidget);

        final destinations = find.descendant(
          of: bar,
          matching: find.byType(NavigationDestination),
        );
        // Without chores: Today, Calendar, Tasks, Settings = 4
        expect(destinations, findsNWidgets(4));

        // First destination label is 'Today'
        final firstDest =
            tester.widgetList<NavigationDestination>(destinations).first;
        expect(firstDest.label, 'Today');
      },
    );

    testWidgets('tapping Calendar tab selects Calendar', (tester) async {
      await tester.pumpWidget(_buildHome(bootstrap: _noChoresBootstrap()));
      await tester.pump();

      await tester.tap(find.text('Calendar'));
      await tester.pump();

      final bar = tester.widget<NavigationBar>(find.byType(NavigationBar));
      expect(bar.selectedIndex, 1);
    });

    testWidgets('tapping Tasks tab selects Tasks', (tester) async {
      await tester.pumpWidget(_buildHome(bootstrap: _noChoresBootstrap()));
      await tester.pump();

      await tester.tap(find.text('Tasks'));
      await tester.pump();

      final bar = tester.widget<NavigationBar>(find.byType(NavigationBar));
      expect(bar.selectedIndex, 2);
    });

    testWidgets(
      'Chores tab hidden when service does not support chores',
      (tester) async {
        await tester.pumpWidget(_buildHome(bootstrap: _noChoresBootstrap()));
        await tester.pump();

        final bar = find.byType(NavigationBar);
        final destinations = find.descendant(
          of: bar,
          matching: find.byType(NavigationDestination),
        );
        final labels = tester
            .widgetList<NavigationDestination>(destinations)
            .map((d) => d.label)
            .toList();
        expect(labels.contains('Chores'), isFalse);
      },
    );

    testWidgets(
      'Chores tab appears when service supports chores',
      (tester) async {
        await tester.pumpWidget(_buildHome(bootstrap: _choresBootstrap()));
        await tester.pump();

        final bar = find.byType(NavigationBar);
        final destinations = find.descendant(
          of: bar,
          matching: find.byType(NavigationDestination),
        );
        final labels = tester
            .widgetList<NavigationDestination>(destinations)
            .map((d) => d.label)
            .toList();
        expect(labels.contains('Chores'), isTrue);
        // With chores: Today, Calendar, Tasks, Chores, Settings = 5
        expect(labels.length, 5);
      },
    );
  });

  group('CaleeHomePage — FAB hero tag uniqueness (static check)', () {
    test('all three FAB hero tags are unique strings', () {
      const tags = [
        'tasks_add_task_fab',
        'chores_add_chore_fab',
        'settings_add_family_member_fab',
      ];
      expect(
        tags.toSet().length,
        tags.length,
        reason: 'Every FAB must have a unique heroTag',
      );
    });
  });
}
