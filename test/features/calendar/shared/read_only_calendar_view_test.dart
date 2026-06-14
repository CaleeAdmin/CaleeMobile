import 'package:calee_mobile/features/calendar/shared/calendar_display_event.dart';
import 'package:calee_mobile/features/calendar/shared/read_only_calendar_event_row.dart';
import 'package:calee_mobile/features/calendar/shared/read_only_calendar_view.dart';
import 'package:calee_mobile/features/calendar/widgets/calendar_day_cell.dart';
import 'package:calee_mobile/ui/calee_design.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

// ── Helpers ───────────────────────────────────────────────────────────────────

final _today = DateTime(2026, 6, 15);

CalendarDisplayEvent _event({
  String id = 'e1',
  String title = 'Test Event',
  DateTime? start,
  bool allDay = false,
  Color color = CaleeColors.dotBlue,
}) => CalendarDisplayEvent(
  id: id,
  title: title,
  start: start ?? DateTime(2026, 6, 15, 10),
  end: allDay ? null : DateTime(2026, 6, 15, 11),
  allDay: allDay,
  calendarId: 'cal1',
  calendarName: 'My Calendar',
  color: color,
);

Widget _buildView({
  List<CalendarDisplayEvent> events = const [],
  CalendarDisplayViewMode viewMode = CalendarDisplayViewMode.month,
  DateTime? selectedDay,
  void Function(CalendarDisplayEvent)? onEventTap,
  List<Widget> actionWidgets = const [],
}) {
  return MaterialApp(
    theme: CaleeTheme.buildThemeData(),
    home: Scaffold(
      body: ReadOnlyCalendarView(
        selectedMonth: DateTime(2026, 6),
        selectedDay: selectedDay ?? _today,
        today: _today,
        firstDayOfWeek: 0,
        events: events,
        viewMode: viewMode,
        onViewModeChanged: (_) {},
        onPreviousMonth: () {},
        onNextMonth: () {},
        onGoToToday: () {},
        onSelectDay: (_) {},
        onEventTap: onEventTap,
        actionWidgets: actionWidgets,
      ),
    ),
  );
}

// ── Tests ─────────────────────────────────────────────────────────────────────

void main() {
  group('ReadOnlyCalendarView — structure', () {
    testWidgets('renders Month and Agenda segmented button', (tester) async {
      await tester.pumpWidget(_buildView());
      expect(find.text('Month'), findsOneWidget);
      expect(find.text('Agenda'), findsOneWidget);
    });

    testWidgets('renders Today button', (tester) async {
      await tester.pumpWidget(_buildView());
      expect(find.text('Today'), findsOneWidget);
    });

    testWidgets('renders previous and next month navigation', (tester) async {
      await tester.pumpWidget(_buildView());
      expect(find.byTooltip('Previous month'), findsOneWidget);
      expect(find.byTooltip('Next month'), findsOneWidget);
    });

    testWidgets('renders month year label', (tester) async {
      await tester.pumpWidget(_buildView());
      expect(find.text('June 2026'), findsOneWidget);
    });

    testWidgets('month mode shows weekday header', (tester) async {
      await tester.pumpWidget(_buildView());
      // Sunday-first: S M T W T F S
      expect(find.text('S'), findsWidgets);
      expect(find.text('M'), findsOneWidget);
    });

    testWidgets('month mode renders 42-cell grid', (tester) async {
      await tester.pumpWidget(_buildView());
      expect(find.byType(CalendarDayCell), findsNWidgets(42));
    });

    testWidgets('switching to Agenda mode does not crash', (tester) async {
      CalendarDisplayViewMode current = CalendarDisplayViewMode.month;
      await tester.pumpWidget(
        MaterialApp(
          theme: CaleeTheme.buildThemeData(),
          home: StatefulBuilder(
            builder: (context, setState) => Scaffold(
              body: ReadOnlyCalendarView(
                selectedMonth: DateTime(2026, 6),
                selectedDay: _today,
                today: _today,
                firstDayOfWeek: 0,
                events: const [],
                viewMode: current,
                onViewModeChanged: (m) => setState(() => current = m),
                onPreviousMonth: () {},
                onNextMonth: () {},
                onGoToToday: () {},
                onSelectDay: (_) {},
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Agenda'));
      await tester.pumpAndSettle();

      expect(find.byType(ReadOnlyCalendarView), findsOneWidget);
    });

    testWidgets('renders extra actionWidgets in top bar', (tester) async {
      await tester.pumpWidget(
        _buildView(
          actionWidgets: [
            IconButton(
              key: const ValueKey('test-action'),
              icon: const Icon(Icons.calendar_month_outlined),
              onPressed: () {},
            ),
          ],
        ),
      );
      expect(find.byKey(const ValueKey('test-action')), findsOneWidget);
    });
  });

  group('ReadOnlyCalendarView — month grid event dots', () {
    testWidgets('shows event dot on a day with events', (tester) async {
      final events = [
        _event(start: DateTime(2026, 6, 15, 10), color: CaleeColors.dotBlue),
      ];
      await tester.pumpWidget(_buildView(events: events));

      // CalendarDayCell for 15 June should have a non-empty dotColors list.
      // We verify via the dot container (colored circle) being present.
      final cells = tester.widgetList<CalendarDayCell>(
        find.byType(CalendarDayCell),
      );
      final june15 = cells.firstWhere(
        (c) => c.date.month == 6 && c.date.day == 15,
      );
      expect(june15.dotColors, isNotEmpty);
      expect(june15.dotColors.first, CaleeColors.dotBlue);
    });

    testWidgets('day with no events has empty dotColors', (tester) async {
      await tester.pumpWidget(_buildView(events: []));
      final cells = tester.widgetList<CalendarDayCell>(
        find.byType(CalendarDayCell),
      );
      for (final c in cells) {
        expect(c.dotColors, isEmpty);
      }
    });

    testWidgets('shows up to 3 dot colors per day', (tester) async {
      final events = [
        _event(id: 'e1', start: DateTime(2026, 6, 15, 9), color: CaleeColors.dotBlue),
        _event(id: 'e2', start: DateTime(2026, 6, 15, 10), color: CaleeColors.dotGreen),
        _event(id: 'e3', start: DateTime(2026, 6, 15, 11), color: CaleeColors.dotOrange),
        _event(id: 'e4', start: DateTime(2026, 6, 15, 12), color: CaleeColors.dotPurple),
      ];
      await tester.pumpWidget(_buildView(events: events));
      final cells = tester.widgetList<CalendarDayCell>(
        find.byType(CalendarDayCell),
      );
      final june15 = cells.firstWhere(
        (c) => c.date.month == 6 && c.date.day == 15,
      );
      expect(june15.dotColors.length, 3);
    });
  });

  group('ReadOnlyCalendarView — selected-day agenda', () {
    testWidgets('shows event title in day agenda', (tester) async {
      final events = [_event(title: 'Dentist', start: DateTime(2026, 6, 15, 10))];
      await tester.pumpWidget(_buildView(events: events, selectedDay: _today));
      expect(find.text('Dentist'), findsOneWidget);
    });

    testWidgets('shows ReadOnlyCalendarEventRow for each day event', (
      tester,
    ) async {
      final events = [
        _event(id: 'e1', title: 'Meeting', start: DateTime(2026, 6, 15, 9)),
        _event(id: 'e2', title: 'Lunch', start: DateTime(2026, 6, 15, 12)),
      ];
      await tester.pumpWidget(_buildView(events: events, selectedDay: _today));
      expect(find.byType(ReadOnlyCalendarEventRow), findsNWidgets(2));
    });

    testWidgets('shows no-events message when day has no events', (
      tester,
    ) async {
      await tester.pumpWidget(_buildView(events: [], selectedDay: _today));
      expect(find.text('No events this day'), findsOneWidget);
    });

    testWidgets('onEventTap fires when row is tapped', (tester) async {
      CalendarDisplayEvent? tapped;
      final event = _event(title: 'Tap Me', start: DateTime(2026, 6, 15, 10));
      await tester.pumpWidget(
        _buildView(
          events: [event],
          selectedDay: _today,
          onEventTap: (e) => tapped = e,
        ),
      );
      await tester.tap(find.text('Tap Me'));
      await tester.pumpAndSettle();
      expect(tapped?.title, 'Tap Me');
    });

    testWidgets('row is not tappable when onEventTap is null', (tester) async {
      final event = _event(title: 'No Tap', start: DateTime(2026, 6, 15, 10));
      await tester.pumpWidget(_buildView(events: [event]));
      // Should not throw when tapping
      await tester.tap(find.text('No Tap'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  });

  group('ReadOnlyCalendarView — monthly agenda view', () {
    testWidgets('shows events across multiple days', (tester) async {
      final events = [
        _event(id: 'e1', title: 'Day 5 Event', start: DateTime(2026, 6, 5, 10)),
        _event(id: 'e2', title: 'Day 20 Event', start: DateTime(2026, 6, 20, 14)),
      ];
      await tester.pumpWidget(
        _buildView(events: events, viewMode: CalendarDisplayViewMode.agenda),
      );
      expect(find.text('Day 5 Event'), findsOneWidget);
      expect(find.text('Day 20 Event'), findsOneWidget);
    });

    testWidgets('shows no-events-this-month when list is empty', (
      tester,
    ) async {
      await tester.pumpWidget(
        _buildView(events: [], viewMode: CalendarDisplayViewMode.agenda),
      );
      expect(find.text('No events this month'), findsOneWidget);
    });

    testWidgets('shows ReadOnlyCalendarEventRow per event in agenda month view',
        (tester) async {
      final events = [
        _event(id: 'e1', start: DateTime(2026, 6, 10, 9)),
        _event(id: 'e2', start: DateTime(2026, 6, 22, 14)),
      ];
      await tester.pumpWidget(
        _buildView(events: events, viewMode: CalendarDisplayViewMode.agenda),
      );
      expect(find.byType(ReadOnlyCalendarEventRow), findsNWidgets(2));
    });
  });
}
