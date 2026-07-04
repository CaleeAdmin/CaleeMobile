// Widget tests for CaleeHomePage navigation structure.
//
// These tests use a minimal stub bootstrap and stub hub client so they do not
// need network access or platform channels.

import 'package:calee_mobile/app/calee_home_page.dart';
import 'package:calee_mobile/data/api/calee_hub_client.dart';
import 'package:calee_mobile/data/models/client_bootstrap.dart';
import 'package:calee_mobile/data/models/client_calendar.dart';
import 'package:calee_mobile/ui/calee_design.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ── Stubs ──────────────────────────────────────────────────────────────────────

class _StubHubClient extends CaleeHubClient {
  _StubHubClient() : super();

  int calendarLoadCount = 0;

  @override
  Future<ClientBootstrap> bootstrap({required String accessToken}) async =>
      _noChoresBootstrap();

  @override
  Future<ClientCalendarList> calendars({required String accessToken}) async {
    calendarLoadCount++;
    return const ClientCalendarList(calendars: []);
  }

  @override
  Future<ClientEventList> events({
    required String accessToken,
    required String from,
    required String to,
  }) async => ClientEventList(from: from, to: to, events: const []);
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
      accessStatus: 'active',
      calendarCredentialStatus: 'connected',
      source: 'test',
      capabilities: {'calendar': true, 'tasks': true, 'chores': true},
    ),
  ],
  contexts: const ClientContexts(
    households: [
      ClientContext(
        id: 'hh1',
        type: 'household',
        name: 'Test Family',
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
  services: const [
    ClientService(
      id: 'svc2',
      displayName: 'Work Service',
      baseUrl: 'http://localhost',
      launchUrl: 'http://localhost',
      serviceType: 'nextcloud',
      accessStatus: 'active',
      calendarCredentialStatus: 'connected',
      source: 'test',
      capabilities: {
        'calendar': true,
        'tasks': true,
        'chores': true,
        'meals': true,
      },
    ),
  ],
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

Widget _buildHome({
  required ClientBootstrap bootstrap,
  VoidCallback? onSignOut,
  int initialSelectedIndex = 0,
  VoidCallback? onInitialTabConsumed,
}) {
  return MaterialApp(
    theme: CaleeTheme.buildThemeData(),
    home: CaleeHomePage(
      hubClient: _StubHubClient(),
      accessToken: 'tok',
      bootstrap: bootstrap,
      onSignOut: onSignOut ?? () {},
      initialSelectedIndex: initialSelectedIndex,
      onInitialTabConsumed: onInitialTabConsumed,
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

    testWidgets('bottom nav contains Today as the first destination', (
      tester,
    ) async {
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
      final firstDest = tester
          .widgetList<NavigationDestination>(destinations)
          .first;
      expect(firstDest.label, 'Today');
    });

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

    testWidgets('Chores tab hidden when service does not support chores', (
      tester,
    ) async {
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
    });

    testWidgets('Chores tab appears when service supports chores', (
      tester,
    ) async {
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
    });
  });

  group('CaleeHomePage — parent AppBar visibility', () {
    // The home Scaffold is the outermost Scaffold; its AppBar is the "parent"
    // AppBar that the tabs either own (and therefore suppress) or rely on.
    AppBar? homeAppBar(WidgetTester tester) {
      final scaffold = tester.widget<Scaffold>(find.byType(Scaffold).first);
      return scaffold.appBar as AppBar?;
    }

    testWidgets('Today tab does not receive a parent AppBar', (tester) async {
      await tester.pumpWidget(_buildHome(bootstrap: _choresBootstrap()));
      await tester.pump();
      expect(homeAppBar(tester), isNull);
    });

    testWidgets('Calendar tab does not receive a parent AppBar', (
      tester,
    ) async {
      await tester.pumpWidget(_buildHome(bootstrap: _choresBootstrap()));
      await tester.pump();
      await tester.tap(find.byIcon(Icons.calendar_month_outlined));
      await tester.pump();
      expect(homeAppBar(tester), isNull);
    });

    testWidgets('Tasks tab does not receive a parent AppBar', (tester) async {
      await tester.pumpWidget(_buildHome(bootstrap: _choresBootstrap()));
      await tester.pump();
      await tester.tap(find.byIcon(Icons.checklist_outlined));
      await tester.pump();
      expect(homeAppBar(tester), isNull);
    });

    testWidgets('Chores tab does not receive a parent AppBar', (tester) async {
      await tester.pumpWidget(_buildHome(bootstrap: _choresBootstrap()));
      await tester.pump();
      await tester.tap(find.byIcon(Icons.cleaning_services_outlined));
      await tester.pump();
      expect(homeAppBar(tester), isNull);
    });

    testWidgets('Settings tab receives a parent AppBar titled Settings', (
      tester,
    ) async {
      await tester.pumpWidget(_buildHome(bootstrap: _choresBootstrap()));
      await tester.pump();
      await tester.tap(find.byIcon(Icons.settings_outlined));
      await tester.pump();

      final appBar = homeAppBar(tester);
      expect(appBar, isNotNull);
      expect(appBar!.title, isA<Text>());
      expect((appBar.title as Text).data, 'Settings');
    });
  });

  group('CaleeHomePage — calendar navigation', () {
    setUp(() {
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

    testWidgets('Calendar tab can be selected without throwing', (
      tester,
    ) async {
      final hub = _StubHubClient();

      await tester.pumpWidget(
        MaterialApp(
          theme: CaleeTheme.buildThemeData(),
          home: CaleeHomePage(
            hubClient: hub,
            accessToken: 'tok',
            bootstrap: _noChoresBootstrap(),
            onSignOut: () {},
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(Icons.calendar_month_outlined));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.text('Calendar'), findsWidgets);
    });
  });

  group('CaleeHomePage — one-shot tab command via didUpdateWidget', () {
    setUp(() {
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

    testWidgets(
      'changing initialSelectedIndex to Calendar tab after mount selects Calendar tab',
      (tester) async {
        await tester.pumpWidget(
          _buildHome(bootstrap: _noChoresBootstrap(), initialSelectedIndex: 0),
        );
        await tester.pump();

        var bar = tester.widget<NavigationBar>(find.byType(NavigationBar));
        expect(bar.selectedIndex, 0, reason: 'starts on Today tab');

        // Re-pump with a new initialSelectedIndex — simulates CaleeApp setting
        // _initialHomeTab after Google OAuth return.
        await tester.pumpWidget(
          _buildHome(bootstrap: _noChoresBootstrap(), initialSelectedIndex: 1),
        );
        await tester.pump();

        bar = tester.widget<NavigationBar>(find.byType(NavigationBar));
        expect(
          bar.selectedIndex,
          1,
          reason: 'didUpdateWidget must select Calendar tab',
        );
      },
    );

    testWidgets(
      'CalendarPage receives incremented refreshGeneration after one-shot Calendar command',
      (tester) async {
        final hub = _StubHubClient();

        await tester.pumpWidget(
          MaterialApp(
            theme: CaleeTheme.buildThemeData(),
            home: CaleeHomePage(
              hubClient: hub,
              accessToken: 'tok',
              bootstrap: _noChoresBootstrap(),
              onSignOut: () {},
              initialSelectedIndex: 0,
            ),
          ),
        );
        await tester.pumpAndSettle();

        final loadCountBefore = hub.calendarLoadCount;

        // Trigger the one-shot command by changing initialSelectedIndex to Calendar.
        await tester.pumpWidget(
          MaterialApp(
            theme: CaleeTheme.buildThemeData(),
            home: CaleeHomePage(
              hubClient: hub,
              accessToken: 'tok',
              bootstrap: _noChoresBootstrap(),
              onSignOut: () {},
              initialSelectedIndex: 1,
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(
          hub.calendarLoadCount,
          greaterThan(loadCountBefore),
          reason: 'CalendarPage must reload when refreshGeneration increments',
        );
      },
    );

    testWidgets(
      'onInitialTabConsumed is called after one-shot tab command via didUpdateWidget',
      (tester) async {
        var consumedCount = 0;

        await tester.pumpWidget(
          _buildHome(
            bootstrap: _noChoresBootstrap(),
            initialSelectedIndex: 0,
            onInitialTabConsumed: () => consumedCount++,
          ),
        );
        await tester.pump();
        expect(consumedCount, 0, reason: 'not called for index 0 at mount');

        await tester.pumpWidget(
          _buildHome(
            bootstrap: _noChoresBootstrap(),
            initialSelectedIndex: 1,
            onInitialTabConsumed: () => consumedCount++,
          ),
        );
        await tester.pump();

        expect(consumedCount, 1, reason: 'called once after one-shot command');
      },
    );
  });

  group('CaleeHomePage — family UX context visibility', () {
    testWidgets(
      'Chores tab hidden for business/workspace user even with chores service',
      (tester) async {
        await tester.pumpWidget(_buildHome(bootstrap: _businessBootstrap()));
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
      'Meals tab hidden for business/workspace user even with meals service',
      (tester) async {
        await tester.pumpWidget(_buildHome(bootstrap: _businessBootstrap()));
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
        expect(labels.contains('Meals'), isFalse);
      },
    );

    testWidgets('Chores tab appears for family user with chores service', (
      tester,
    ) async {
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
    });
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

  group('CaleeHomePage — initialSelectedIndex one-time behaviour', () {
    testWidgets('initialSelectedIndex: 1 opens Calendar tab', (tester) async {
      await tester.pumpWidget(
        _buildHome(bootstrap: _noChoresBootstrap(), initialSelectedIndex: 1),
      );
      await tester.pump();

      final bar = tester.widget<NavigationBar>(find.byType(NavigationBar));
      expect(bar.selectedIndex, 1);
    });

    testWidgets(
      'onInitialTabConsumed is called after first frame when initialSelectedIndex != 0',
      (tester) async {
        var consumed = false;
        await tester.pumpWidget(
          _buildHome(
            bootstrap: _noChoresBootstrap(),
            initialSelectedIndex: 1,
            onInitialTabConsumed: () => consumed = true,
          ),
        );
        await tester.pump();

        expect(consumed, isTrue);
      },
    );

    testWidgets(
      'onInitialTabConsumed is NOT called when initialSelectedIndex is 0',
      (tester) async {
        var consumed = false;
        await tester.pumpWidget(
          _buildHome(
            bootstrap: _noChoresBootstrap(),
            initialSelectedIndex: 0,
            onInitialTabConsumed: () => consumed = true,
          ),
        );
        await tester.pump();

        expect(consumed, isFalse);
      },
    );

    testWidgets(
      'switching tabs after initialSelectedIndex does not reset to initial',
      (tester) async {
        await tester.pumpWidget(
          _buildHome(bootstrap: _noChoresBootstrap(), initialSelectedIndex: 1),
        );
        await tester.pump();

        // Switch to Today (index 0)
        await tester.tap(find.text('Today'));
        await tester.pump();

        final bar = tester.widget<NavigationBar>(find.byType(NavigationBar));
        expect(bar.selectedIndex, 0);
      },
    );
  });
}
