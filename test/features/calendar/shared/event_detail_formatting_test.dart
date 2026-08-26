// Date and time wording for one event's details (CaleeAdmin/CaleeMobile#566).
//
// The rule under test is a product rule, not a formatting preference: the
// range a user reads must be the range the event actually covers. An all-day
// event's transport `endsAt` is EXCLUSIVE on both the Hub contract and in
// iCalendar, so a Friday-to-Sunday camp arrives carrying the Monday — and
// "Monday" is simply not when it finishes.
//
// Every case here is built from floating local values, so the assertions hold
// in any host timezone and nothing depends on a timezone database.

import 'package:calee_mobile/features/calendar/shared/calendar_display_event.dart';
import 'package:calee_mobile/features/calendar/shared/event_detail_formatting.dart';
import 'package:calee_mobile/ui/calee_design.dart';
import 'package:flutter_test/flutter_test.dart';

CalendarDisplayEvent _display({
  required DateTime start,
  DateTime? end,
  bool allDay = false,
}) => CalendarDisplayEvent(
  id: 'e1',
  title: 'An Event',
  start: start,
  end: end,
  allDay: allDay,
  calendarId: 'cal1',
  calendarName: 'A Calendar',
  color: CaleeColors.dotBlue,
);

void main() {
  group('all-day events use the INCLUSIVE last day', () {
    test('a one-day event shows a single date', () {
      final label = eventDetailDateLabel(
        _display(
          start: DateTime(2026, 8, 21),
          end: DateTime(2026, 8, 22),
          allDay: true,
        ),
      );

      expect(label, 'Friday 21 August 2026');
      expect(label, isNot(contains('22 August')));
    });

    test('a Friday-to-Sunday event carrying the exclusive Monday shows '
        'Friday to Sunday', () {
      final label = eventDetailDateLabel(
        _display(
          start: DateTime(2026, 8, 21),
          end: DateTime(2026, 8, 24),
          allDay: true,
        ),
      );

      expect(label, 'Friday 21 August 2026 – Sunday 23 August 2026');
      expect(label, isNot(contains('24 August')));
    });

    test('a range that crosses a month boundary reads correctly', () {
      expect(
        eventDetailDateLabel(
          _display(
            start: DateTime(2026, 8, 30),
            end: DateTime(2026, 9, 2),
            allDay: true,
          ),
        ),
        'Sunday 30 August 2026 – Tuesday 1 September 2026',
      );
    });

    test('a range that crosses a year boundary reads correctly', () {
      expect(
        eventDetailDateLabel(
          _display(
            start: DateTime(2026, 12, 31),
            end: DateTime(2027, 1, 2),
            allDay: true,
          ),
        ),
        'Thursday 31 December 2026 – Friday 1 January 2027',
      );
    });

    test('a feed that sent no end at all shows one date', () {
      expect(
        eventDetailDateLabel(
          _display(start: DateTime(2026, 8, 21), allDay: true),
        ),
        'Friday 21 August 2026',
      );
    });

    test('a degenerate end equal to the start shows one date', () {
      expect(
        eventDetailDateLabel(
          _display(
            start: DateTime(2026, 8, 21),
            end: DateTime(2026, 8, 21),
            allDay: true,
          ),
        ),
        'Friday 21 August 2026',
      );
    });

    test('the inclusive end is computed by calendar date, not by subtracting '
        'a fixed 24 hours', () {
      // A Duration is an absolute span, so subtracting one from a local
      // DateTime lands on 23:00 of the previous day across a DST transition —
      // a different calendar date on some devices. Asserted as a date so the
      // expectation is about the day, not the clock.
      final inclusive = inclusiveEndDate(
        _display(
          start: DateTime(2026, 10, 3),
          end: DateTime(2026, 10, 6),
          allDay: true,
        ),
      );

      expect(inclusive, DateTime(2026, 10, 5));
      expect(inclusive!.hour, 0);
    });
  });

  group('timed events', () {
    test('a same-day event shows one date', () {
      expect(
        eventDetailDateLabel(
          _display(
            start: DateTime(2026, 8, 21, 13),
            end: DateTime(2026, 8, 21, 14),
          ),
        ),
        'Friday 21 August 2026',
      );
    });

    test('an event crossing midnight represents both dates', () {
      expect(
        eventDetailDateLabel(
          _display(
            start: DateTime(2026, 8, 21, 23),
            end: DateTime(2026, 8, 22, 1),
          ),
        ),
        'Friday 21 August 2026 – Saturday 22 August 2026',
      );
    });

    test('an event ending exactly at midnight closes its own day', () {
      expect(
        eventDetailDateLabel(
          _display(
            start: DateTime(2026, 8, 21, 22),
            end: DateTime(2026, 8, 22),
          ),
        ),
        'Friday 21 August 2026',
      );
    });

    test('a multi-day timed event shows the first and last day', () {
      expect(
        eventDetailDateLabel(
          _display(
            start: DateTime(2026, 8, 21, 9),
            end: DateTime(2026, 8, 23, 17),
          ),
        ),
        'Friday 21 August 2026 – Sunday 23 August 2026',
      );
    });
  });

  group('time labels', () {
    final sameDay = _display(
      start: DateTime(2026, 8, 21, 13, 30),
      end: DateTime(2026, 8, 21, 14),
    );

    test('an all-day event says All day, whatever its end', () {
      expect(
        eventDetailTimeLabel(
          _display(
            start: DateTime(2026, 8, 21),
            end: DateTime(2026, 8, 24),
            allDay: true,
          ),
          use24h: true,
        ),
        'All day',
      );
    });

    test('24-hour', () {
      expect(eventDetailTimeLabel(sameDay, use24h: true), '13:30–14:00');
    });

    test('12-hour drops :00 minutes', () {
      expect(eventDetailTimeLabel(sameDay, use24h: false), '1:30 PM–2 PM');
    });

    test('midnight and noon read correctly on a 12-hour clock', () {
      expect(
        eventDetailTimeLabel(
          _display(
            start: DateTime(2026, 8, 21),
            end: DateTime(2026, 8, 21, 12),
          ),
          use24h: false,
        ),
        '12 AM–12 PM',
      );
    });

    test('an event with no end shows just its start', () {
      expect(
        eventDetailTimeLabel(
          _display(start: DateTime(2026, 8, 21, 13, 5)),
          use24h: true,
        ),
        '13:05',
      );
    });

    test('a cross-midnight event keeps both clock times', () {
      expect(
        eventDetailTimeLabel(
          _display(
            start: DateTime(2026, 8, 21, 23),
            end: DateTime(2026, 8, 22, 1),
          ),
          use24h: true,
        ),
        '23:00–01:00',
      );
    });
  });
}
