import 'package:calee_mobile/data/models/client_calendar.dart';
import 'package:calee_mobile/features/notifications/calendar_notification_candidates.dart';
import 'package:flutter_test/flutter_test.dart';

// ── Helpers ───────────────────────────────────────────────────────────────────

ClientEvent _event(
  String id, {
  String startsAt = '2026-07-05T09:00:00',
  String endsAt = '2026-07-05T10:00:00',
  bool allDay = false,
  String? occurrenceId,
}) => ClientEvent(
  id: id,
  calendarId: 'cal1',
  serviceId: 'svc',
  serviceName: 'Test',
  title: 'Event $id',
  startsAt: startsAt,
  endsAt: endsAt,
  allDay: allDay,
  recurring: occurrenceId != null,
  source: 'test',
  occurrenceId: occurrenceId,
);

// Fixed "now" used across tests: 2026-07-04T12:00:00 local
final _now = DateTime(2026, 7, 4, 12, 0, 0);

// ── Tests ─────────────────────────────────────────────────────────────────────

void main() {
  group('buildNotificationCandidates — eligibility', () {
    test('includes timed event with reminder in the future', () {
      // Event at 09:00 on 2026-07-05 — reminder at 08:50, which is after _now
      final events = [_event('e1', startsAt: '2026-07-05T09:00:00')];

      final result = buildNotificationCandidates(events, now: _now);

      expect(result, hasLength(1));
      expect(result.first.event.id, 'e1');
    });

    test('skips all-day events', () {
      final events = [
        _event('e1', startsAt: '2026-07-05', endsAt: '2026-07-06', allDay: true),
      ];

      final result = buildNotificationCandidates(events, now: _now);

      expect(result, isEmpty);
    });

    test('skips events with unparseable startsAt', () {
      final events = [_event('e1', startsAt: 'not-a-date')];

      final result = buildNotificationCandidates(events, now: _now);

      expect(result, isEmpty);
    });

    test('skips events where reminder time is already past', () {
      // Starts at 12:05 on the same day; reminder = 11:55, which is before noon
      final events = [_event('e1', startsAt: '2026-07-04T12:05:00')];

      final result = buildNotificationCandidates(events, now: _now);

      expect(result, isEmpty);
    });

    test('skips events starting more than 7 days out', () {
      final events = [_event('e1', startsAt: '2026-07-12T09:00:00')];

      final result = buildNotificationCandidates(events, now: _now);

      expect(result, isEmpty);
    });

    test('includes event exactly at horizon boundary', () {
      // now + 7d = 2026-07-11T12:00:00; event at 2026-07-11T11:59:00 is inside
      final events = [_event('e1', startsAt: '2026-07-11T11:59:00')];

      final result = buildNotificationCandidates(events, now: _now);

      expect(result, hasLength(1));
    });

    test('excludes event just past the horizon', () {
      // now + 7d = 2026-07-11T12:00:00; event at 2026-07-11T12:01:00 is outside
      final events = [_event('e1', startsAt: '2026-07-11T12:01:00')];

      final result = buildNotificationCandidates(events, now: _now);

      expect(result, isEmpty);
    });

    test('respects custom reminderOffset', () {
      // Default reminder 10 min before a 12:05 start would be 11:55 (past).
      // With a 1-minute offset the reminder is 12:04, which is after _now (12:00).
      final events = [_event('e1', startsAt: '2026-07-04T12:05:00')];

      final result = buildNotificationCandidates(
        events,
        now: _now,
        reminderOffset: const Duration(minutes: 1),
      );

      expect(result, hasLength(1));
    });

    test('mixes eligible and ineligible events correctly', () {
      final events = [
        _event('ok', startsAt: '2026-07-05T09:00:00'),
        _event('past', startsAt: '2026-07-04T11:00:00'),
        _event('allday', startsAt: '2026-07-05', allDay: true),
      ];

      final result = buildNotificationCandidates(events, now: _now);

      expect(result, hasLength(1));
      expect(result.first.event.id, 'ok');
    });
  });

  group('buildNotificationCandidates — reminder time', () {
    test('reminderTime is startLocal minus 10 minutes', () {
      final events = [_event('e1', startsAt: '2026-07-05T09:00:00')];
      final result = buildNotificationCandidates(events, now: _now);

      expect(result.first.startLocal.hour, 9);
      expect(result.first.startLocal.minute, 0);
      expect(result.first.reminderTime.hour, 8);
      expect(result.first.reminderTime.minute, 50);
    });
  });

  group('notificationIdForEvent — stability', () {
    test('same event yields the same id on repeated calls', () {
      final event = _event('e1', startsAt: '2026-07-05T09:00:00');

      final id1 = notificationIdForEvent(event);
      final id2 = notificationIdForEvent(event);

      expect(id1, id2);
    });

    test('different occurrenceId yields a different id', () {
      final base = _event('e1', startsAt: '2026-07-05T09:00:00');
      final withOccurrence = _event(
        'e1',
        startsAt: '2026-07-05T09:00:00',
        occurrenceId: 'occ-42',
      );

      expect(notificationIdForEvent(base), isNot(notificationIdForEvent(withOccurrence)));
    });

    test('different startsAt yields a different id', () {
      final a = _event('e1', startsAt: '2026-07-05T09:00:00');
      final b = _event('e1', startsAt: '2026-07-06T09:00:00');

      expect(notificationIdForEvent(a), isNot(notificationIdForEvent(b)));
    });

    test('id is a non-negative integer', () {
      final event = _event('e1');
      final id = notificationIdForEvent(event);
      expect(id, isNonNegative);
    });

    test('id fits in a signed 31-bit range', () {
      final event = _event('e1');
      final id = notificationIdForEvent(event);
      expect(id, lessThanOrEqualTo(0x7FFFFFFF));
    });
  });
}
