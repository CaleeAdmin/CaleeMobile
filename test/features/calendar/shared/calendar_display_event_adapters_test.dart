import 'dart:io';

import 'package:calee_mobile/data/models/client_calendar.dart';
import 'package:calee_mobile/features/calendar/shared/calendar_display_event_adapters.dart';
import 'package:calee_mobile/ui/calee_design.dart';
import 'package:flutter_test/flutter_test.dart';

ClientCalendar _calendar({
  String id = 'cal1',
  String name = 'Work',
  String? color,
  bool readOnly = false,
}) => ClientCalendar(
  id: id,
  serviceId: 'svc1',
  serviceName: 'Test',
  name: name,
  color: color,
  components: const ['VEVENT'],
  primaryKind: 'calendar',
  supportsEvents: true,
  supportsTasks: false,
  supportsChores: false,
  readOnly: readOnly,
  isSubscription: false,
  source: 'test',
);

ClientEvent _event({
  String id = 'evt1',
  String calendarId = 'cal1',
  String title = 'Team Meeting',
  String startsAt = '2026-06-15T10:00:00.000Z',
  String endsAt = '2026-06-15T11:00:00.000Z',
  bool allDay = false,
  String? location,
  String? description,
}) => ClientEvent(
  id: id,
  calendarId: calendarId,
  serviceId: 'svc1',
  serviceName: 'Test',
  title: title,
  startsAt: startsAt,
  endsAt: endsAt,
  allDay: allDay,
  source: 'test',
  recurring: false,
  location: location,
  description: description,
);

void main() {
  group('calendarDisplayEventFromClientEvent', () {
    test('maps id and title', () {
      final display = calendarDisplayEventFromClientEvent(
        _event(id: 'e42', title: 'Sprint Review'),
        calendar: _calendar(),
      );
      expect(display.id, 'e42');
      expect(display.title, 'Sprint Review');
    });

    test('parses startsAt and endsAt to local DateTime', () {
      final display = calendarDisplayEventFromClientEvent(
        _event(
          startsAt: '2026-06-15T10:00:00.000Z',
          endsAt: '2026-06-15T11:00:00.000Z',
        ),
        calendar: _calendar(),
      );
      // Should be non-null DateTime objects
      expect(display.start, isNotNull);
      expect(display.end, isNotNull);
    });

    test(
      'converts backend UTC instants to the Perth device timezone',
      () {
        final display = calendarDisplayEventFromClientEvent(
          _event(
            startsAt: '2026-06-15T01:00:00Z',
            endsAt: '2026-06-15T02:00:00Z',
          ),
          calendar: _calendar(),
        );

        expect(display.start.year, 2026);
        expect(display.start.month, 6);
        expect(display.start.day, 15);
        expect(display.start.hour, 9);
        expect(display.start.minute, 0);
        expect(display.start.isUtc, isFalse);
        expect(display.end, isNotNull);
        expect(display.end!.hour, 10);
      },
      skip: Platform.environment['TZ'] == 'Australia/Perth'
          ? false
          : 'Requires the test process to run with TZ=Australia/Perth.',
    );

    test('keeps all-day date-only values on their local calendar dates', () {
      final display = calendarDisplayEventFromClientEvent(
        _event(allDay: true, startsAt: '2026-06-15', endsAt: '2026-06-16'),
        calendar: _calendar(),
      );

      expect(display.allDay, isTrue);
      expect(display.start, DateTime(2026, 6, 15));
      expect(display.start.isUtc, isFalse);
      expect(display.end, DateTime(2026, 6, 16));
      expect(display.end!.isUtc, isFalse);
    });

    test('maps calendarId and calendarName from calendar', () {
      final display = calendarDisplayEventFromClientEvent(
        _event(calendarId: 'cal1'),
        calendar: _calendar(id: 'cal1', name: 'Personal'),
      );
      expect(display.calendarId, 'cal1');
      expect(display.calendarName, 'Personal');
    });

    test('uses fallbackColor when calendar has no color', () {
      final display = calendarDisplayEventFromClientEvent(
        _event(),
        calendar: _calendar(color: null),
      );
      expect(display.color, CaleeColors.dotBlue);
    });

    test('parses calendar hex color when present', () {
      final display = calendarDisplayEventFromClientEvent(
        _event(),
        calendar: _calendar(color: '#FF5733'),
      );
      // Color should be parsed from hex, not the fallback
      expect(display.color, isNot(CaleeColors.dotBlue));
    });

    test('readOnly comes from calendar.readOnly', () {
      final writable = calendarDisplayEventFromClientEvent(
        _event(),
        calendar: _calendar(readOnly: false),
      );
      expect(writable.readOnly, isFalse);

      final readOnly = calendarDisplayEventFromClientEvent(
        _event(),
        calendar: _calendar(readOnly: true),
      );
      expect(readOnly.readOnly, isTrue);
    });

    test('readOnly defaults false when calendar is null', () {
      final display = calendarDisplayEventFromClientEvent(
        _event(),
        calendar: null,
      );
      expect(display.readOnly, isFalse);
    });

    test('maps location and description', () {
      final display = calendarDisplayEventFromClientEvent(
        _event(location: 'Room 5', description: 'Sprint demo'),
        calendar: _calendar(),
      );
      expect(display.location, 'Room 5');
      expect(display.description, 'Sprint demo');
    });

    test('maps allDay flag', () {
      final display = calendarDisplayEventFromClientEvent(
        _event(allDay: true, startsAt: '2026-06-15', endsAt: '2026-06-16'),
        calendar: _calendar(),
      );
      expect(display.allDay, isTrue);
    });

    test('uses fallbackColor when calendar is null', () {
      final display = calendarDisplayEventFromClientEvent(
        _event(),
        calendar: null,
        fallbackColor: CaleeColors.dotGreen,
      );
      expect(display.color, CaleeColors.dotGreen);
    });
  });
}
