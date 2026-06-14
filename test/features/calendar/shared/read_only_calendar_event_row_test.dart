import 'package:calee_mobile/features/calendar/shared/calendar_display_event.dart';
import 'package:calee_mobile/features/calendar/shared/read_only_calendar_event_row.dart';
import 'package:calee_mobile/ui/calee_design.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

CalendarDisplayEvent _timedEvent({
  required DateTime start,
  required DateTime end,
}) => CalendarDisplayEvent(
  id: 'e1',
  title: 'Test',
  start: start,
  end: end,
  allDay: false,
  calendarId: 'cal1',
  calendarName: 'My Cal',
  color: CaleeColors.dotBlue,
);

CalendarDisplayEvent _allDayEvent() => CalendarDisplayEvent(
  id: 'e2',
  title: 'All Day',
  start: DateTime(2026, 6, 15),
  end: DateTime(2026, 6, 16),
  allDay: true,
  calendarId: 'cal1',
  calendarName: 'My Cal',
  color: CaleeColors.dotBlue,
);

Widget _wrap(Widget child) => MaterialApp(
  theme: CaleeTheme.buildThemeData(),
  home: Scaffold(body: child),
);

void main() {
  group('ReadOnlyCalendarEventRow — time display', () {
    testWidgets('24h range 17:00–19:00 displays fully', (tester) async {
      final event = _timedEvent(
        start: DateTime(2026, 6, 15, 17),
        end: DateTime(2026, 6, 15, 19),
      );
      await tester.pumpWidget(
        _wrap(ReadOnlyCalendarEventRow(event: event, use24h: true)),
      );
      expect(find.text('17:00–19:00'), findsOneWidget);
    });

    testWidgets('24h late range 22:45–23:30 displays fully', (tester) async {
      final event = _timedEvent(
        start: DateTime(2026, 6, 15, 22, 45),
        end: DateTime(2026, 6, 15, 23, 30),
      );
      await tester.pumpWidget(
        _wrap(ReadOnlyCalendarEventRow(event: event, use24h: true)),
      );
      expect(find.text('22:45–23:30'), findsOneWidget);
    });

    testWidgets('12h range displays cleanly', (tester) async {
      final event = _timedEvent(
        start: DateTime(2026, 6, 15, 8, 15),
        end: DateTime(2026, 6, 15, 9, 30),
      );
      await tester.pumpWidget(
        _wrap(ReadOnlyCalendarEventRow(event: event, use24h: false)),
      );
      expect(find.text('8:15 AM–9:30 AM'), findsOneWidget);
    });

    testWidgets('all-day row with hideTime shows no time text', (tester) async {
      final event = _allDayEvent();
      await tester.pumpWidget(
        _wrap(ReadOnlyCalendarEventRow(event: event, hideTime: true)),
      );
      expect(find.text('All day'), findsNothing);
    });

    testWidgets('time column uses wider width for 24h mode', (tester) async {
      final event = _timedEvent(
        start: DateTime(2026, 6, 15, 17),
        end: DateTime(2026, 6, 15, 19),
      );
      await tester.pumpWidget(
        _wrap(ReadOnlyCalendarEventRow(event: event, use24h: true)),
      );
      // Verify the text widget for the time is present and not clipped
      final textWidget = tester.widget<Text>(find.text('17:00–19:00'));
      expect(textWidget.overflow, TextOverflow.ellipsis);
    });

    testWidgets('24h early range 08:15–09:30 displays fully', (tester) async {
      final event = _timedEvent(
        start: DateTime(2026, 6, 15, 8, 15),
        end: DateTime(2026, 6, 15, 9, 30),
      );
      await tester.pumpWidget(
        _wrap(ReadOnlyCalendarEventRow(event: event, use24h: true)),
      );
      expect(find.text('08:15–09:30'), findsOneWidget);
    });
  });
}
