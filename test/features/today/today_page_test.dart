// Widget tests for TodayPage rendering.
//
// Uses a stub CaleeHubClient so no network access is required. The tests
// verify that empty states, section error rows, and pull-to-refresh all work
// without crashing the page.

import 'package:calee_mobile/data/api/calee_hub_client.dart';
import 'package:calee_mobile/data/models/client_bootstrap.dart';
import 'package:calee_mobile/data/models/client_calendar.dart';
import 'package:calee_mobile/data/models/client_chore.dart';
import 'package:calee_mobile/data/models/client_meal.dart';
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
    this.failMeals = false,
    List<ClientEvent>? events,
    List<ClientTask>? tasks,
    List<ClientChore>? chores,
    List<ClientMeal>? meals,
  }) : _events = events ?? const [],
       _tasks = tasks ?? const [],
       _chores = chores ?? const [],
       _meals = meals ?? const [],
       super();

  final bool failEvents;
  final bool failTasks;
  final bool failChores;
  final bool failMeals;
  final List<ClientEvent> _events;
  final List<ClientTask> _tasks;
  final List<ClientChore> _chores;
  final List<ClientMeal> _meals;

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

  @override
  Future<ClientMealList> meals({
    required String accessToken,
    required String from,
    required String to,
  }) async {
    if (failMeals) throw Exception('meals error');
    return ClientMealList(householdId: 'h1', from: from, to: to, meals: _meals);
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
  accessStatus: 'active',
  calendarCredentialStatus: 'connected',
  source: 'test',
  capabilities: {'calendar': true, 'tasks': true, 'chores': true},
);

const _mealsService = ClientService(
  id: 'portal',
  displayName: 'Portal',
  baseUrl: 'http://localhost',
  launchUrl: 'http://localhost',
  serviceType: 'nextcloud_portal',
  accessStatus: 'active',
  calendarCredentialStatus: 'connected',
  source: 'test',
  capabilities: {'calendar': true, 'meals': true},
);

/// TodayPage can grow past the default 800x600 test surface once the
/// Chores/Meals sections are populated. A plain (non-builder) ListView only
/// lays out slivers near the viewport, so rows below the fold exist in the
/// widget tree but are "offstage" to finders. Growing the surface keeps
/// everything reachable without scrolling in every test.
void _useTallViewport(WidgetTester tester) {
  tester.view.physicalSize = const Size(800, 2000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Widget _buildPage({
  required CaleeHubClient hub,
  List<ClientService> services = const [_calendarService],
  bool isFamilyUxContext = false,
}) {
  return MaterialApp(
    theme: CaleeTheme.buildThemeData(),
    home: TodayPage(
      hubClient: hub,
      accessToken: 'tok',
      services: services,
      households: const [],
      isFamilyUxContext: isFamilyUxContext,
    ),
  );
}

// ── Tests ──────────────────────────────────────────────────────────────────────

void main() {
  group('TodayPage — empty states', () {
    testWidgets('shows "No events today" when calendar has no events', (
      tester,
    ) async {
      final hub = _StubHub();
      await tester.pumpWidget(_buildPage(hub: hub));
      await tester.pump();
      await tester.pump();

      expect(find.text('No events today'), findsOneWidget);
    });

    testWidgets('shows "No tasks due today" when no tasks exist', (
      tester,
    ) async {
      final hub = _StubHub();
      await tester.pumpWidget(_buildPage(hub: hub));
      await tester.pump();
      await tester.pump();

      expect(find.text('No tasks due today'), findsOneWidget);
    });

    testWidgets(
      'shows "No chores due today" when chores service present and family context',
      (tester) async {
        final hub = _StubHub();
        await tester.pumpWidget(
          _buildPage(
            hub: hub,
            services: const [_choresService],
            isFamilyUxContext: true,
          ),
        );
        await tester.pump();
        await tester.pump();

        expect(find.text('No chores due today'), findsOneWidget);
      },
    );

    testWidgets('Chores section absent when no chores service', (tester) async {
      final hub = _StubHub();
      await tester.pumpWidget(
        _buildPage(hub: hub, services: const [_calendarService]),
      );
      await tester.pump();
      await tester.pump();

      expect(find.text('No chores due today'), findsNothing);
    });

    testWidgets(
      'Chores section absent when chores service present but not family context',
      (tester) async {
        final hub = _StubHub();
        // business/workspace: isFamilyUxContext = false
        await tester.pumpWidget(
          _buildPage(
            hub: hub,
            services: const [_choresService],
            isFamilyUxContext: false,
          ),
        );
        await tester.pump();
        await tester.pump();

        expect(find.text('No chores due today'), findsNothing);
      },
    );
  });

  group('TodayPage — section error rows', () {
    testWidgets('calendar error row renders without crashing the page', (
      tester,
    ) async {
      final hub = _StubHub(failEvents: true);
      await tester.pumpWidget(_buildPage(hub: hub));
      await tester.pump();
      await tester.pump();

      expect(find.byType(TodayPage), findsOneWidget);
      expect(find.text('Could not load calendar events.'), findsOneWidget);
    });

    testWidgets('tasks error row renders without crashing the page', (
      tester,
    ) async {
      final hub = _StubHub(failTasks: true);
      await tester.pumpWidget(_buildPage(hub: hub));
      await tester.pump();
      await tester.pump();

      expect(find.byType(TodayPage), findsOneWidget);
      expect(find.text('Could not load tasks.'), findsOneWidget);
    });

    testWidgets('chores error row renders without crashing the page', (
      tester,
    ) async {
      final hub = _StubHub(failChores: true);
      await tester.pumpWidget(
        _buildPage(
          hub: hub,
          services: const [_choresService],
          isFamilyUxContext: true,
        ),
      );
      await tester.pump();
      await tester.pump();

      expect(find.byType(TodayPage), findsOneWidget);
      expect(find.text('Could not load chores.'), findsOneWidget);
    });

    testWidgets('all sections error without crashing the page', (tester) async {
      final hub = _StubHub(failEvents: true, failTasks: true, failChores: true);
      await tester.pumpWidget(
        _buildPage(
          hub: hub,
          services: const [_choresService],
          isFamilyUxContext: true,
        ),
      );
      await tester.pump();
      await tester.pump();

      expect(find.byType(TodayPage), findsOneWidget);
    });
  });

  group('TodayPage — Calee grouped-list style', () {
    testWidgets('uses CaleeSection widgets for section grouping', (
      tester,
    ) async {
      final hub = _StubHub();
      await tester.pumpWidget(_buildPage(hub: hub));
      await tester.pump();
      await tester.pump();

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

      await tester.drag(find.byType(ListView).first, const Offset(0, 300));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump();

      expect(find.byType(TodayPage), findsOneWidget);
    });
  });

  group("TodayPage — Today's Meals card", () {
    testWidgets('shows "No meals planned today" when nothing is planned', (
      tester,
    ) async {
      _useTallViewport(tester);
      final hub = _StubHub();
      await tester.pumpWidget(
        _buildPage(
          hub: hub,
          services: const [_mealsService],
          isFamilyUxContext: true,
        ),
      );
      await tester.pump();
      await tester.pump();

      expect(find.text('No meals planned today'), findsOneWidget);
      expect(find.text('Not planned'), findsNothing);
      expect(find.byIcon(Icons.add), findsNothing);
    });

    testWidgets('shows only planned meals in breakfast/lunch/dinner order', (
      tester,
    ) async {
      _useTallViewport(tester);
      final dinner = ClientMeal(
        id: 1,
        householdId: 'h1',
        mealDate: '2024-01-01',
        mealType: 'dinner',
        title: 'ABC',
        status: 'planned',
        source: 'manual',
      );
      final breakfast = ClientMeal(
        id: 2,
        householdId: 'h1',
        mealDate: '2024-01-01',
        mealType: 'breakfast',
        title: 'Cereal',
        status: 'planned',
        source: 'manual',
      );

      final hub = _StubHub(meals: [dinner, breakfast]);
      await tester.pumpWidget(
        _buildPage(
          hub: hub,
          services: const [_mealsService],
          isFamilyUxContext: true,
        ),
      );
      await tester.pump();
      await tester.pump();

      // The leading icon and meal title render as separate Text widgets.
      expect(find.text('🍳'), findsOneWidget);
      expect(find.text('Cereal'), findsOneWidget);
      expect(find.text('🍴'), findsOneWidget);
      expect(find.text('ABC'), findsOneWidget);
      expect(find.text('Not planned'), findsNothing);
      expect(find.text('Lunch'), findsNothing);

      // Breakfast row appears above the dinner row.
      final breakfastY = tester.getTopLeft(find.text('Cereal')).dy;
      final dinnerY = tester.getTopLeft(find.text('ABC')).dy;
      expect(breakfastY, lessThan(dinnerY));
    });

    testWidgets('meals error row renders without crashing the page', (
      tester,
    ) async {
      _useTallViewport(tester);
      final hub = _StubHub(failMeals: true);
      await tester.pumpWidget(
        _buildPage(
          hub: hub,
          services: const [_mealsService],
          isFamilyUxContext: true,
        ),
      );
      await tester.pump();
      await tester.pump();

      expect(find.byType(TodayPage), findsOneWidget);
      expect(find.text('Could not load meals.'), findsOneWidget);
    });
  });

  group('TodayPage — Calee Display section', () {
    testWidgets('displays coming-soon placeholder section', (tester) async {
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
