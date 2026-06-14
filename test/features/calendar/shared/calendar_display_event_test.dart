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
      const display = CalendarDisplayEvent(
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
      const display = CalendarDisplayEvent(
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

      final display = calendarDisplayEventFromLocalEvent(event, subscription: sub);

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
      expect(display.end, isNull);
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
}
