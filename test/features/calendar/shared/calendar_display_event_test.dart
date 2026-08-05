import 'dart:io';

import 'package:calee_mobile/features/calendar/shared/calendar_display_event.dart';
import 'package:calee_mobile/features/calendar/shared/calendar_display_event_adapters.dart';
import 'package:calee_mobile/features/local_subscriber/local_calendar_event.dart';
import 'package:calee_mobile/features/local_subscriber/local_calendar_subscription.dart';
import 'package:calee_mobile/ui/calee_design.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

LocalCalendarSubscription _sub({
  String id = 'sub1',
  String title = 'My Calendar',
}) => LocalCalendarSubscription(
  id: id,
  title: title,
  url: 'https://example.com/cal.ics',
  source: 'example.com',
  createdAt: DateTime(2024, 1, 1),
);

LocalCalendarEvent _event({
  String id = 'evt1',
  String subId = 'sub1',
  String subTitle = 'My Calendar',
  String title = 'Team Meeting',
  DateTime? start,
  DateTime? end,
  bool isAllDay = false,
}) => LocalCalendarEvent(
  id: id,
  subscriptionId: subId,
  subscriptionTitle: subTitle,
  title: title,
  start: start ?? DateTime(2026, 6, 15, 10),
  end: end ?? DateTime(2026, 6, 15, 11),
  isAllDay: isAllDay,
  sourceUrl: 'https://example.com/cal.ics',
);

void main() {
  group('CalendarDisplayEvent — pure model', () {
    test('direct constructor sets all fields', () {
      final display = CalendarDisplayEvent(
        id: 'x',
        title: 'Test',
        start: DateTime.fromMillisecondsSinceEpoch(0),
        allDay: false,
        calendarId: 'cal',
        calendarName: 'Cal',
        color: Colors.blue,
        readOnly: false,
      );
      expect(display.id, 'x');
      expect(display.title, 'Test');
      expect(display.readOnly, isFalse);
      expect(display.location, isNull);
      expect(display.description, isNull);
    });

    test('readOnly defaults to true', () {
      final display = CalendarDisplayEvent(
        id: 'x',
        title: 'Test',
        start: DateTime.fromMillisecondsSinceEpoch(0),
        allDay: false,
        calendarId: 'cal',
        calendarName: 'Cal',
        color: Colors.blue,
      );
      expect(display.readOnly, isTrue);
    });
  });

  group('calendarDisplayEventFromLocalEvent', () {
    test('maps all fields from event and subscription', () {
      final sub = _sub(id: 'sub1', title: 'Work');
      final event = _event(
        id: 'e1',
        title: 'Standup',
        start: DateTime(2026, 6, 15, 9),
        end: DateTime(2026, 6, 15, 9, 30),
      );

      final display = calendarDisplayEventFromLocalEvent(
        event,
        subscription: sub,
      );

      expect(display.id, 'e1');
      expect(display.title, 'Standup');
      expect(display.start, DateTime(2026, 6, 15, 9));
      expect(display.end, DateTime(2026, 6, 15, 9, 30));
      expect(display.allDay, isFalse);
      expect(display.calendarId, 'sub1');
      expect(display.calendarName, 'Work');
      expect(display.readOnly, isTrue);
    });

    test('defaults color to dotBlue when not provided', () {
      final display = calendarDisplayEventFromLocalEvent(
        _event(),
        subscription: _sub(),
      );
      expect(display.color, CaleeColors.dotBlue);
    });

    test('uses provided color when given', () {
      final display = calendarDisplayEventFromLocalEvent(
        _event(),
        subscription: _sub(),
        color: CaleeColors.dotGreen,
      );
      expect(display.color, CaleeColors.dotGreen);
    });

    test('maps all-day event correctly', () {
      final event = _event(
        isAllDay: true,
        start: DateTime(2026, 6, 20),
        end: null,
      );
      final display = calendarDisplayEventFromLocalEvent(
        event,
        subscription: _sub(),
      );
      expect(display.allDay, isTrue);
      expect(display.end, event.end);
    });

    test('location and description are null', () {
      final display = calendarDisplayEventFromLocalEvent(
        _event(),
        subscription: _sub(),
      );
      expect(display.location, isNull);
      expect(display.description, isNull);
    });

    test('is always readOnly', () {
      final display = calendarDisplayEventFromLocalEvent(
        _event(),
        subscription: _sub(),
      );
      expect(display.readOnly, isTrue);
    });
  });

  group('calendarDisplayEventFromLocalEvent — timezone', () {
    // Regression: "Have a go day" on the Morley Eagles (Club) calendar is
    // 2:00 PM–4:00 PM on Sunday 9 August 2026 in Australia/Perth, published as
    //   DTSTART;TZID=Australia/Perth:20260809T140000
    //   DTEND;TZID=Australia/Perth:20260809T160000
    // LocalCalendarIcsService correctly resolves those to the UTC instants
    // below. The phone-only calendar rendered them verbatim and showed
    // 06:00–08:00; they must be localized before reaching the shared view.
    final perthIncidentStart = DateTime.utc(2026, 8, 9, 6);
    final perthIncidentEnd = DateTime.utc(2026, 8, 9, 8);

    test('timed UTC instants are localized, not rendered as UTC', () {
      final display = calendarDisplayEventFromLocalEvent(
        _event(
          title: 'Have a go day',
          start: perthIncidentStart,
          end: perthIncidentEnd,
        ),
        subscription: _sub(title: 'Morley Eagles (Club)'),
      );

      expect(display.start.isUtc, isFalse);
      expect(display.end!.isUtc, isFalse);
      // Localizing must not move the instant, only how it is expressed.
      expect(display.start.toUtc(), perthIncidentStart);
      expect(display.end!.toUtc(), perthIncidentEnd);
      expect(display.start, perthIncidentStart.toLocal());
      expect(display.end, perthIncidentEnd.toLocal());
    });

    test(
      'the Perth incident event displays 14:00–16:00 on 9 August 2026',
      () {
        final display = calendarDisplayEventFromLocalEvent(
          _event(
            title: 'Have a go day',
            start: perthIncidentStart,
            end: perthIncidentEnd,
          ),
          subscription: _sub(title: 'Morley Eagles (Club)'),
        );

        expect(display.start.year, 2026);
        expect(display.start.month, 8);
        expect(display.start.day, 9);
        expect(display.start.hour, 14);
        expect(display.start.minute, 0);
        expect(display.end!.day, 9);
        expect(display.end!.hour, 16);
        expect(display.end!.minute, 0);
      },
      skip: Platform.environment['TZ'] == 'Australia/Perth'
          ? false
          : 'Requires the test process to run with TZ=Australia/Perth.',
    );

    test('a timed event with no end keeps a null end', () {
      final display = calendarDisplayEventFromLocalEvent(
        LocalCalendarEvent(
          id: 'e-no-end',
          subscriptionId: 'sub1',
          subscriptionTitle: 'My Calendar',
          title: 'Have a go day',
          start: perthIncidentStart,
          isAllDay: false,
          sourceUrl: 'https://example.com/cal.ics',
        ),
        subscription: _sub(),
      );

      expect(display.end, isNull);
      expect(display.start.isUtc, isFalse);
    });

    test('all-day values are passed through untouched', () {
      // All-day ICS dates are floating calendar dates, not instants. Converting
      // one could move it to the previous or next day.
      final start = DateTime.utc(2026, 8, 9);
      final end = DateTime.utc(2026, 8, 10);
      final display = calendarDisplayEventFromLocalEvent(
        _event(isAllDay: true, start: start, end: end),
        subscription: _sub(),
      );

      expect(display.allDay, isTrue);
      expect(display.start, same(start));
      expect(display.end, same(end));
      expect(display.start.isUtc, isTrue);
      expect(display.end!.isUtc, isTrue);
      expect(display.start.day, 9);
      expect(display.end!.day, 10);
    });
  });
}
