// Widget tests for CalendarPage structure.
//
// Verifies that the Month/Agenda switcher renders and that switching between
// modes does not crash the page. Uses a stub CaleeHubClient so no platform
// channels or network access are needed. SharedPreferences is mocked because
// CalendarPage creates CaleePreferences internally.

import 'package:calee_mobile/data/api/calee_hub_client.dart';
import 'package:calee_mobile/data/models/client_bootstrap.dart';
import 'package:calee_mobile/data/models/client_calendar.dart';
import 'package:calee_mobile/features/calendar/calendar_page.dart';
import 'package:calee_mobile/ui/calee_design.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ── Stubs ──────────────────────────────────────────────────────────────────────

class _StubHub extends CaleeHubClient {
  _StubHub() : super();

  int calendarLoadCount = 0;

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

// ── Tests ──────────────────────────────────────────────────────────────────────

const _service = ClientService(
  id: 'svc1',
  displayName: 'Test',
  baseUrl: 'http://localhost',
  launchUrl: 'http://localhost',
  serviceType: 'nextcloud',
  accessStatus: 'ok',
  calendarCredentialStatus: 'connected',
  source: 'test',
  capabilities: {'calendar': true, 'tasks': false, 'chores': false},
);

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({
      'calee_pref_migrated_to_shared_prefs': true,
    });

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

  group('CalendarPage', () {
    testWidgets('renders without crashing', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: CaleeTheme.buildThemeData(),
          home: CalendarPage(
            hubClient: _StubHub(),
            accessToken: 'tok',
            services: const [_service],
            accountId: 'acct1',
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byType(CalendarPage), findsOneWidget);
    });

    testWidgets('Month / Agenda switcher (SegmentedButton) is visible', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: CaleeTheme.buildThemeData(),
          home: CalendarPage(
            hubClient: _StubHub(),
            accessToken: 'tok',
            services: const [_service],
            accountId: 'acct1',
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Month'), findsOneWidget);
      expect(find.text('Agenda'), findsOneWidget);
    });

    testWidgets('switching to Agenda mode does not crash', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: CaleeTheme.buildThemeData(),
          home: CalendarPage(
            hubClient: _StubHub(),
            accessToken: 'tok',
            services: const [_service],
            accountId: 'acct1',
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Agenda'));
      await tester.pumpAndSettle();

      expect(find.byType(CalendarPage), findsOneWidget);
    });

    testWidgets('refreshes when refreshGeneration increments', (tester) async {
      final hub = _StubHub();
      int generation = 0;

      await tester.pumpWidget(
        StatefulBuilder(
          builder: (context, setState) => MaterialApp(
            theme: CaleeTheme.buildThemeData(),
            home: Scaffold(
              body: Column(
                children: [
                  Expanded(
                    child: CalendarPage(
                      hubClient: hub,
                      accessToken: 'tok',
                      services: const [_service],
                      accountId: 'acct1',
                      refreshGeneration: generation,
                    ),
                  ),
                  ElevatedButton(
                    onPressed: () => setState(() => generation++),
                    child: const Text('Bump'),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final countAfterInit = hub.calendarLoadCount;
      expect(countAfterInit, greaterThan(0));

      await tester.tap(find.text('Bump'));
      await tester.pumpAndSettle();

      expect(hub.calendarLoadCount, greaterThan(countAfterInit));
    });
  });
}
