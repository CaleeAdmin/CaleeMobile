import 'package:flutter_test/flutter_test.dart';
import 'package:calee_mobile/data/models/client_calendar.dart';
import 'package:calee_mobile/features/calendar/calendar_utils.dart';

ClientEvent _event(String startsAt, {bool allDay = false}) => ClientEvent(
      id: 'test',
      calendarId: 'cal',
      serviceId: 'svc',
      serviceName: 'Test',
      title: 'Test Event',
      startsAt: startsAt,
      endsAt: startsAt,
      allDay: allDay,
      source: 'test',
      recurring: false,
    );

void main() {
  group('eventTimeLabel', () {
    test('17:00 in 24-hour mode -> "17:00"', () {
      final event = _event('2026-06-02T17:00:00');
      expect(eventTimeLabel(event, use24h: true), '17:00');
    });

    test('10:45 in 24-hour mode -> "10:45"', () {
      final event = _event('2026-06-02T10:45:00');
      expect(eventTimeLabel(event, use24h: true), '10:45');
    });

    test('17:00 in 12-hour mode -> "5 PM"', () {
      final event = _event('2026-06-02T17:00:00');
      expect(eventTimeLabel(event, use24h: false), '5 PM');
    });

    test('22:45 in 12-hour mode -> "10:45 PM"', () {
      final event = _event('2026-06-02T22:45:00');
      expect(eventTimeLabel(event, use24h: false), '10:45 PM');
    });

    test('00:00 in 12-hour mode -> "12 AM"', () {
      final event = _event('2026-06-02T00:00:00');
      expect(eventTimeLabel(event, use24h: false), '12 AM');
    });

    test('12:00 in 12-hour mode -> "12 PM"', () {
      final event = _event('2026-06-02T12:00:00');
      expect(eventTimeLabel(event, use24h: false), '12 PM');
    });

    test('all-day event -> "All day"', () {
      final event = _event('2026-06-02T00:00:00', allDay: true);
      expect(eventTimeLabel(event, use24h: true), 'All day');
      expect(eventTimeLabel(event, use24h: false), 'All day');
    });
  });
}
