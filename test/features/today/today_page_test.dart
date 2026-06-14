// Widget tests for TodayPage rendering.
//
// Uses a stub CaleeHubClient so no network access is required. The tests
// verify that empty states, section error rows, and pull-to-refresh all work
// without crashing the page.

import 'package:calee_mobile/data/api/calee_hub_client.dart';
import 'package:calee_mobile/data/models/client_bootstrap.dart';
import 'package:calee_mobile/data/models/client_calendar.dart';
import 'package:calee_mobile/data/models/client_chore.dart';
import 'package:calee_mobile/data/models/client_task.dart';
import 'package:calee_mobile/features/today/today_page.dart';
import 'package:calee_mobile/ui/calee_design.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

// ── Stubs ──────────────────────────────────────────────────────────────────────

class _StubHub extends CaleeHubClient {
  _StubHub({
    this.failEvents = false,
    this.failTasks = false,
    this.failChores = false,
    List<ClientEvent>? events,
    List<ClientTask>? tasks,
    List<ClientChore>? chores,
  }) : _events = events ?? const [],
       _tasks = tasks ?? const [],
       _chores = chores ?? const [],
       super();

  final bool failEvents;
  final bool failTasks;
  final bool failChores;
  final List<ClientEvent> _events;
  final List<ClientTask> _tasks;
  final List<ClientChore> _chores;

  @override
  Future<ClientEventList> events({
    required String accessToken,
    required String from,
    required String to,
  }) async {
    if (failEvents) throw Exception('events error');
    return ClientEventList(from: from, to: to, events: _events);
  }

  @override
  Future<ClientTaskList> tasks({
    required String accessToken,
    required String from,
    required String to,
  }) async {
    if (failTasks) throw Exception('tasks error');
    return ClientTaskList(from: from, to: to, tasks: _tasks);
  }

  @override
  Future<ClientChoreList> chores({
    required String accessToken,
    required String from,
    required String to,
  }) async {
    if (failChores) throw Exception('chores error');
    return ClientChoreList(from: from, to: to, chores: _chores);
  }
}

// ── Helpers ────────────────────────────────────────────────────────────────────

const _calendarService = ClientService(
  id: 'svc1',
  displayName: 'Test',
  baseUrl: 'http://localhost',
  launchUrl: 'http://localhost',
  serviceType: 'nextcloud',
  accessStatus: 'ok',
  calendarCredentialStatus: 'connected',
  source: 'test',
  capabilities: {'calendar': true, 'tasks': true, 'chores': false},
);

const _choresService = ClientService(
  id: 'svc2',
  displayName: 'Portal',
  baseUrl: 'http://localhost',
  launchUrl: 'http://localhost',
  serviceType: 'nextcloud_portal',
  accessStatus: 'ok',
  calendarCredentialStatus: 'connected',
  source: 'test',
  capabilities: {'calendar': true, 'tasks': true, 'chores': true},
);

Widget _buildPage({
  required CaleeHubClient hub,
  List<ClientService> services = const [_calendarService],
}) {
  return MaterialApp(
    theme: CaleeTheme.buildThemeData(),
    home: TodayPage(
      hubClient: hub,
      accessToken: 'tok',
      services: services,
      households: const [],
    ),
  );
}

// ── Tests ──────────────────────────────────────────────────────────────────────

void main() {
  group('TodayPage — empty states', () {
    testWidgets('shows "No events today" when calendar has no events',
        (tester) async {
      final hub = _StubHub();
      await tester.pumpWidget(_buildPage(hub: hub));
      await tester.pump(); // allow initState _load() future to settle
      await tester.pump();

      expect(find.text('No events today'), findsOneWidget);
    });

    testWidgets('shows "No tasks due today" when no tasks exist',
        (tester) async {
      final hub = _StubHub();
      await tester.pumpWidget(_buildPage(hub: hub));
      await tester.pump();
      await tester.pump();

      expect(find.text('No tasks due today'), findsOneWidget);
    });

    testWidgets('shows "No chores due today" when chores service present',
        (tester) async {
      final hub = _StubHub();
      await tester.pumpWidget(
        _buildPage(hub: hub, services: const [_choresService]),
      );
      await tester.pump();
      await tester.pump();

      expect(find.text('No chores due today'), findsOneWidget);
    });

    testWidgets('Chores section is absent when no chores service',
        (tester) async {
      final hub = _StubHub();
      await tester.pumpWidget(
        _buildPage(hub: hub, services: const [_calendarService]),
      );
      await tester.pump();
      await tester.pump();

      expect(find.text('No chores due today'), findsNothing);
    });
  });

  group('TodayPage — section error rows', () {
    testWidgets('calendar error row renders without crashing the page',
        (tester) async {
      final hub = _StubHub(failEvents: true);
      await tester.pumpWidget(_buildPage(hub: hub));
      await tester.pump();
      await tester.pump();

      // Page should still be visible (not a blank screen)
      expect(find.byType(TodayPage), findsOneWidget);
      expect(find.text('Could not load calendar events.'), findsOneWidget);
    });

    testWidgets('tasks error row renders without crashing the page',
        (tester) async {
      final hub = _StubHub(failTasks: true);
      await tester.pumpWidget(_buildPage(hub: hub));
      await tester.pump();
      await tester.pump();

      expect(find.byType(TodayPage), findsOneWidget);
      expect(find.text('Could not load tasks.'), findsOneWidget);
    });

    testWidgets('chores error row renders without crashing the page',
        (tester) async {
      final hub = _StubHub(failChores: true);
      await tester.pumpWidget(
        _buildPage(hub: hub, services: const [_choresService]),
      );
      await tester.pump();
      await tester.pump();

      expect(find.byType(TodayPage), findsOneWidget);
      expect(find.text('Could not load chores.'), findsOneWidget);
    });

    testWidgets('all sections error without crashing the page', (tester) async {
      final hub = _StubHub(
        failEvents: true,
        failTasks: true,
        failChores: true,
      );
      await tester.pumpWidget(
        _buildPage(hub: hub, services: const [_choresService]),
      );
      await tester.pump();
      await tester.pump();

      expect(find.byType(TodayPage), findsOneWidget);
    });
  });

  group('TodayPage — Calee grouped-list style', () {
    testWidgets('uses CaleeSection widgets for section grouping',
        (tester) async {
      final hub = _StubHub();
      await tester.pumpWidget(_buildPage(hub: hub));
      await tester.pump();
      await tester.pump();

      // CaleeSection should be present for Calendar, Tasks, and Calee Display
      expect(find.byType(CaleeSection), findsWidgets);
    });

    testWidgets('uses CaleeListRow widgets within sections', (tester) async {
      final hub = _StubHub();
      await tester.pumpWidget(_buildPage(hub: hub));
      await tester.pump();
      await tester.pump();

      expect(find.byType(CaleeListRow), findsWidgets);
    });
  });

  group('TodayPage — pull-to-refresh', () {
    testWidgets('pull-to-refresh does not crash the page', (tester) async {
      final hub = _StubHub();
      await tester.pumpWidget(_buildPage(hub: hub));
      await tester.pump();
      await tester.pump();

      // Drag from top to trigger RefreshIndicator
      await tester.drag(find.byType(ListView).first, const Offset(0, 300));
      await tester.pump();
      // Allow the refresh future to complete
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump();

      expect(find.byType(TodayPage), findsOneWidget);
    });
  });

  group('TodayPage — Calee Display section', () {
    testWidgets('displays "coming soon" placeholder section', (tester) async {
      final hub = _StubHub();
      await tester.pumpWidget(_buildPage(hub: hub));
      await tester.pump();
      await tester.pump();

      expect(
        find.text('Display status and setup are coming soon.'),
        findsOneWidget,
      );
    });
  });
}
