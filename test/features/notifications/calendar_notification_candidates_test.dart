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
  String? title,
}) => ClientEvent(
  id: id,
  calendarId: 'cal1',
  serviceId: 'svc',
  serviceName: 'Test',
  title: title ?? 'Event $id',
  startsAt: startsAt,
  endsAt: endsAt,
  allDay: allDay,
  recurring: occurrenceId != null,
  source: 'test',
  occurrenceId: occurrenceId,
);

// Fixed "now" used across tests: 2026-07-04T12:00:00 local.
// Default 30-day horizon → cutoff 2026-08-03T12:00:00.
final _now = DateTime(2026, 7, 4, 12, 0, 0);

// ── Tests ─────────────────────────────────────────────────────────────────────

void main() {
  group('buildNotificationCandidates — eligibility', () {
    test('includes timed event with reminder in the future', () {
      final events = [_event('e1', startsAt: '2026-07-05T09:00:00')];

      final result = buildNotificationCandidates(events, now: _now);

      expect(result, hasLength(1));
      expect(result.first.event.id, 'e1');
    });

    test('skips all-day events', () {
      final events = [
        _event(
          'e1',
          startsAt: '2026-07-05',
          endsAt: '2026-07-06',
          allDay: true,
        ),
      ];

      final result = buildNotificationCandidates(events, now: _now);

      expect(result, isEmpty);
    });

    test('skips events with unparseable startsAt (does not crash)', () {
      final events = [_event('e1', startsAt: 'not-a-date')];

      final result = buildNotificationCandidates(events, now: _now);

      expect(result, isEmpty);
    });

    test('skips events where reminder time is already past', () {
      // Starts at 12:05 on the same day; reminder = 11:55, which is before noon.
      final events = [_event('e1', startsAt: '2026-07-04T12:05:00')];

      final result = buildNotificationCandidates(events, now: _now);

      expect(result, isEmpty);
    });

    test('skips events starting beyond the 30-day horizon', () {
      // now + 30d = 2026-08-03T12:00; an event on 2026-08-10 is outside.
      final events = [_event('e1', startsAt: '2026-08-10T09:00:00')];

      final result = buildNotificationCandidates(events, now: _now);

      expect(result, isEmpty);
    });

    test('includes event within the 30-day window', () {
      // Well inside the 30-day horizon (would be excluded by the old 7-day one).
      final events = [_event('e1', startsAt: '2026-07-20T09:00:00')];

      final result = buildNotificationCandidates(events, now: _now);

      expect(result, hasLength(1));
    });

    test('includes event just inside the 30-day horizon boundary', () {
      // now + 30d = 2026-08-03T12:00; event at 2026-08-03T11:59 is inside.
      final events = [_event('e1', startsAt: '2026-08-03T11:59:00')];

      final result = buildNotificationCandidates(events, now: _now);

      expect(result, hasLength(1));
    });

    test('excludes event just past the 30-day horizon', () {
      // now + 30d = 2026-08-03T12:00; event at 2026-08-03T12:01 is outside.
      final events = [_event('e1', startsAt: '2026-08-03T12:01:00')];

      final result = buildNotificationCandidates(events, now: _now);

      expect(result, isEmpty);
    });

    test('respects custom reminderOffset', () {
      // Default reminder 10 min before a 12:05 start would be 11:55 (past).
      // With a 1-minute offset the reminder is 12:04, which is after _now.
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
        _event('far', startsAt: '2026-09-01T09:00:00'),
      ];

      final result = buildNotificationCandidates(events, now: _now);

      expect(result, hasLength(1));
      expect(result.first.event.id, 'ok');
    });
  });

  group('buildNotificationCandidates — sorting and limiting', () {
    test('candidates are sorted by ascending reminder time', () {
      final events = [
        _event('c', startsAt: '2026-07-20T09:00:00'),
        _event('a', startsAt: '2026-07-05T09:00:00'),
        _event('b', startsAt: '2026-07-10T09:00:00'),
      ];

      final result = buildNotificationCandidates(events, now: _now);

      expect(result.map((c) => c.event.id).toList(), ['a', 'b', 'c']);
      for (var i = 1; i < result.length; i++) {
        expect(
          result[i].reminderTime.isBefore(result[i - 1].reminderTime),
          isFalse,
          reason: 'reminder times must be non-decreasing',
        );
      }
    });

    test(
      'selects the earliest candidates when more than the max are eligible',
      () {
        // Five eligible events; keep only the two earliest.
        final events = [
          _event('day8', startsAt: '2026-07-12T09:00:00'),
          _event('day2', startsAt: '2026-07-06T09:00:00'),
          _event('day16', startsAt: '2026-07-20T09:00:00'),
          _event('day1', startsAt: '2026-07-05T09:00:00'),
          _event('day24', startsAt: '2026-07-28T09:00:00'),
        ];

        final result = buildNotificationCandidates(
          events,
          now: _now,
          maxCandidates: 2,
        );

        expect(result, hasLength(2));
        expect(result.map((c) => c.event.id).toList(), ['day1', 'day2']);
      },
    );

    test('maxCandidates is applied only after sorting', () {
      // The soonest reminder is last in input order; it must still be kept.
      final events = [
        _event('late', startsAt: '2026-07-25T09:00:00'),
        _event('mid', startsAt: '2026-07-15T09:00:00'),
        _event('soon', startsAt: '2026-07-05T09:00:00'),
      ];

      final result = buildNotificationCandidates(
        events,
        now: _now,
        maxCandidates: 1,
      );

      expect(result, hasLength(1));
      expect(result.first.event.id, 'soon');
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

    test('recurring occurrences get stable, distinct ids', () {
      final occ1 = _event(
        'series1',
        startsAt: '2026-07-05T09:00:00',
        occurrenceId: 'occ-1',
      );
      final occ2 = _event(
        'series1',
        startsAt: '2026-07-12T09:00:00',
        occurrenceId: 'occ-2',
      );

      // Distinct across occurrences...
      expect(notificationIdForEvent(occ1), isNot(notificationIdForEvent(occ2)));
      // ...and stable for each occurrence.
      expect(notificationIdForEvent(occ1), notificationIdForEvent(occ1));
      expect(notificationIdForEvent(occ2), notificationIdForEvent(occ2));
    });

    test('different occurrenceId yields a different id', () {
      final base = _event('e1', startsAt: '2026-07-05T09:00:00');
      final withOccurrence = _event(
        'e1',
        startsAt: '2026-07-05T09:00:00',
        occurrenceId: 'occ-42',
      );

      expect(
        notificationIdForEvent(base),
        isNot(notificationIdForEvent(withOccurrence)),
      );
    });

    test('different startsAt yields a different id', () {
      final a = _event('e1', startsAt: '2026-07-05T09:00:00');
      final b = _event('e1', startsAt: '2026-07-06T09:00:00');

      expect(notificationIdForEvent(a), isNot(notificationIdForEvent(b)));
    });

    test('id fits in a non-negative signed 31-bit range', () {
      final event = _event('e1');
      final id = notificationIdForEvent(event);
      expect(id, isNonNegative);
      expect(id, lessThanOrEqualTo(0x7FFFFFFF));
    });
  });

  group('scheduleFingerprint', () {
    CalendarNotificationCandidate candidate(ClientEvent e) =>
        buildNotificationCandidates([e], now: _now).single;

    test(
      'is identical across separate but field-equal event model instances',
      () {
        final a = candidate(_event('e1', startsAt: '2026-07-05T09:00:00'));
        final b = candidate(_event('e1', startsAt: '2026-07-05T09:00:00'));
        expect(scheduleFingerprint(a), scheduleFingerprint(b));
      },
    );

    test('changes when only the title changes (same notification ID)', () {
      final original = candidate(_event('e1', title: 'Original'));
      final renamed = candidate(_event('e1', title: 'Renamed'));
      expect(
        original.notificationId,
        renamed.notificationId,
        reason: 'the ID is identity-based and unchanged by a title edit',
      );
      expect(
        scheduleFingerprint(original),
        isNot(scheduleFingerprint(renamed)),
      );
    });

    test('changes when the start time changes', () {
      final a = candidate(_event('e1', startsAt: '2026-07-05T09:00:00'));
      final b = candidate(_event('e1', startsAt: '2026-07-05T10:00:00'));
      expect(scheduleFingerprint(a), isNot(scheduleFingerprint(b)));
    });

    test('is a SHA-256 hex digest that does not embed the raw title', () {
      final fp = scheduleFingerprint(
        candidate(_event('e1', title: 'Secret dinner plans')),
      );
      expect(fp, matches(RegExp(r'^[0-9a-f]{64}$')));
      expect(
        fp.toLowerCase().contains('secret'),
        isFalse,
        reason: 'the digest must not carry raw private event content',
      );
    });
  });

  group('reminderOwnerKey', () {
    test('is deterministic and distinct across accounts', () {
      expect(reminderOwnerKey('acct-A'), reminderOwnerKey('acct-A'));
      expect(reminderOwnerKey('acct-A'), isNot(reminderOwnerKey('acct-B')));
    });

    test('is a SHA-256 hex digest that does not embed the raw account ID', () {
      final key = reminderOwnerKey('super-secret-account-id');
      expect(key, matches(RegExp(r'^[0-9a-f]{64}$')));
      expect(key.contains('secret'), isFalse);
    });
  });

  group('account isolation — notification identity', () {
    test(
      'identical events under two accounts get different notification IDs',
      () {
        final event = _event('e1', startsAt: '2026-07-05T09:00:00');
        final keyA = reminderOwnerKey('acct-A');
        final keyB = reminderOwnerKey('acct-B');

        final idA = notificationIdForEvent(event, ownerKey: keyA);
        final idB = notificationIdForEvent(event, ownerKey: keyB);

        expect(idA, isNot(idB));
        // Still stable per account and within the valid 31-bit range.
        expect(idA, notificationIdForEvent(event, ownerKey: keyA));
        expect(idA, isNonNegative);
        expect(idA, lessThanOrEqualTo(0x7FFFFFFF));
      },
    );

    test('a null owner preserves the historical account-agnostic ID', () {
      final event = _event('e1', startsAt: '2026-07-05T09:00:00');
      expect(
        notificationIdForEvent(event),
        notificationIdForEvent(event, ownerKey: null),
      );
    });

    test('identical events under two accounts get different fingerprints', () {
      final event = _event('e1', startsAt: '2026-07-05T09:00:00');
      final keyA = reminderOwnerKey('acct-A');
      final keyB = reminderOwnerKey('acct-B');

      final candA = buildNotificationCandidates(
        [event],
        now: _now,
        ownerKey: keyA,
      ).single;
      final candB = buildNotificationCandidates(
        [event],
        now: _now,
        ownerKey: keyB,
      ).single;

      expect(scheduleFingerprint(candA), isNot(scheduleFingerprint(candB)));
    });

    test(
      'buildNotificationCandidates threads the owner into ID and candidate',
      () {
        final event = _event('e1', startsAt: '2026-07-05T09:00:00');
        final keyA = reminderOwnerKey('acct-A');
        final cand = buildNotificationCandidates(
          [event],
          now: _now,
          ownerKey: keyA,
        ).single;
        expect(cand.ownerKey, keyA);
        expect(
          cand.notificationId,
          notificationIdForEvent(event, ownerKey: keyA),
        );
      },
    );
  });

  group('allocateNotificationIds — collision resolution (Defect 6)', () {
    CalendarNotificationCandidate cand(
      String id, {
      String startsAt = '2026-07-05T09:00:00',
    }) => buildNotificationCandidates([
      _event(id, startsAt: startsAt),
    ], now: _now).single;

    test('two forced-collision candidates both survive with distinct '
        'deterministic IDs', () {
      final a = cand('a', startsAt: '2026-07-05T09:00:00');
      final b = cand('b', startsAt: '2026-07-06T09:00:00');
      // Force both to base id 100; probe p resolves to 100 + p.
      int derive(CalendarNotificationCandidate c, int probe) => 100 + probe;

      final result = allocateNotificationIds([a, b], idDerivation: derive);

      expect(result.candidates, hasLength(2), reason: 'no candidate is lost');
      final ids = result.candidates.map((c) => c.notificationId).toList();
      expect(ids.toSet(), hasLength(2), reason: 'IDs are distinct');
      expect(
        ids.first,
        100,
        reason: 'the earliest candidate keeps the base ID',
      );
      expect(ids[1], 101, reason: 'the collider deterministically probes');
      expect(result.collisionsResolved, 1);
      expect(result.hasUnresolved, isFalse);
    });

    test('repeated construction produces the same resolved IDs', () {
      final a = cand('a', startsAt: '2026-07-05T09:00:00');
      final b = cand('b', startsAt: '2026-07-06T09:00:00');
      int derive(CalendarNotificationCandidate c, int probe) => 100 + probe;

      final first = allocateNotificationIds([a, b], idDerivation: derive);
      final second = allocateNotificationIds([a, b], idDerivation: derive);

      expect(
        first.candidates.map((c) => c.notificationId).toList(),
        second.candidates.map((c) => c.notificationId).toList(),
      );
    });

    test('candidate count equals the number of allocated IDs (no map '
        'overwrite)', () {
      final list = buildNotificationCandidates([
        _event('a', startsAt: '2026-07-05T09:00:00'),
        _event('b', startsAt: '2026-07-06T09:00:00'),
        _event('c', startsAt: '2026-07-07T09:00:00'),
      ], now: _now);

      final result = allocateNotificationIds(list);

      expect(result.candidates, hasLength(3));
      expect(
        result.candidates.map((c) => c.notificationId).toSet(),
        hasLength(3),
        reason: 'distinct events get distinct IDs with no overwrite',
      );
      expect(result.collisionsResolved, 0);
      expect(result.hasUnresolved, isFalse);
    });

    test('an exhausted probe limit is reported rather than dropping an event '
        'silently', () {
      final a = cand('a', startsAt: '2026-07-05T09:00:00');
      final b = cand('b', startsAt: '2026-07-06T09:00:00');
      // Every probe returns the same ID, so the second candidate can never find
      // a free slot within the probe budget.
      int derive(CalendarNotificationCandidate c, int probe) => 500;

      final result = allocateNotificationIds(
        [a, b],
        maxProbes: 4,
        idDerivation: derive,
      );

      expect(
        result.candidates.single.notificationId,
        500,
        reason: 'the first candidate still gets the ID',
      );
      expect(result.unresolved, hasLength(1));
      expect(result.unresolved.single.event.id, 'b');
      expect(result.hasUnresolved, isTrue);
    });

    test('notification ID zero is a valid allocation', () {
      final a = cand('a');
      int derive(CalendarNotificationCandidate c, int probe) => 0;
      final result = allocateNotificationIds([a], idDerivation: derive);
      expect(result.candidates.single.notificationId, 0);
      expect(result.hasUnresolved, isFalse);
    });
  });
}
