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
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ── Stubs ──────────────────────────────────────────────────────────────────────

class _StubHub extends CaleeHubClient {
  _StubHub() : super();

  @override
  Future<ClientCalendarList> calendars({required String accessToken}) async =>
      const ClientCalendarList(calendars: []);

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
    SharedPreferences.setMockInitialValues({});
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
          ),
        ),
      );
      await tester.pump();
      await tester.pump();

      expect(find.byType(CalendarPage), findsOneWidget);
    });

    testWidgets(
      'Month / Agenda switcher (SegmentedButton) is visible',
      (tester) async {
        await tester.pumpWidget(
          MaterialApp(
            theme: CaleeTheme.buildThemeData(),
            home: CalendarPage(
              hubClient: _StubHub(),
              accessToken: 'tok',
              services: const [_service],
            ),
          ),
        );
        await tester.pump();
        await tester.pump();

        expect(find.text('Month'), findsOneWidget);
        expect(find.text('Agenda'), findsOneWidget);
      },
    );

    testWidgets('switching to Agenda mode does not crash', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: CaleeTheme.buildThemeData(),
          home: CalendarPage(
            hubClient: _StubHub(),
            accessToken: 'tok',
            services: const [_service],
          ),
        ),
      );
      await tester.pump();
      await tester.pump();

      await tester.tap(find.text('Agenda'));
      await tester.pump();
      await tester.pump();

      expect(find.byType(CalendarPage), findsOneWidget);
    });
  });
}
