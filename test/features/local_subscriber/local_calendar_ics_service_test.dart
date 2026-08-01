import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/data/latest.dart' as tz_data;
import 'package:timezone/timezone.dart' as tz;

import 'package:calee_mobile/features/local_subscriber/local_calendar_ics_service.dart';
import 'package:calee_mobile/features/local_subscriber/local_calendar_subscription.dart';
import 'package:calee_mobile/features/local_subscriber/local_calendar_subscription_repository.dart';

void main() {
  setUpAll(() {
    tz_data.initializeTimeZones();
  });

  const service = LocalCalendarIcsService();

  // ── Helpers ───────────────────────────────────────────────────────────────

  LocalCalendarSubscription fakeSub({
    String id = 'test_id',
    String url = 'https://example.com/cal.ics',
  }) {
    return LocalCalendarSubscription(
      id: id,
      title: 'Test Calendar',
      url: url,
      source: 'test',
      createdAt: DateTime(2024, 1, 1),
    );
  }

  String icsWrap(String vevent) =>
      'BEGIN:VCALENDAR\r\nVERSION:2.0\r\n$vevent\r\nEND:VCALENDAR';

  String fmtDate(DateTime dt) => '${dt.year}${_pad(dt.month)}${_pad(dt.day)}';

  String fmtDateTime(DateTime dt) =>
      '${fmtDate(dt)}T${_pad(dt.hour)}${_pad(dt.minute)}${_pad(dt.second)}';

  // Anchored to a clean local time so tests are date-arithmetic-deterministic.
  final now = DateTime.now();
  final tomorrow = DateTime(
    now.year,
    now.month,
    now.day,
    10,
    0,
    0,
  ).add(const Duration(days: 1));

  // ── 1. One-off timed VEVENT ───────────────────────────────────────────────

  group('one-off timed VEVENT', () {
    test('is parsed and returned with correct fields', () {
      final start = tomorrow;
      final end = tomorrow.add(const Duration(hours: 1));
      final ics = icsWrap(
        [
          'BEGIN:VEVENT',
          'UID:timed@example.com',
          'SUMMARY:Team Meeting',
          'DTSTART:${fmtDateTime(start)}',
          'DTEND:${fmtDateTime(end)}',
          'END:VEVENT',
        ].join('\r\n'),
      );

      final events = service.parseBody(ics, fakeSub());
      expect(events.length, 1);
      expect(events[0].title, 'Team Meeting');
      expect(events[0].isAllDay, isFalse);
      expect(events[0].start.hour, 10);
      expect(events[0].end, isNotNull);
      expect(events[0].subscriptionId, 'test_id');
    });

    test('UTC datetime is parsed correctly', () {
      final ics = icsWrap(
        [
          'BEGIN:VEVENT',
          'UID:utc@example.com',
          'SUMMARY:UTC Event',
          'DTSTART:${fmtDate(tomorrow)}T080000Z',
          'END:VEVENT',
        ].join('\r\n'),
      );

      final events = service.parseBody(ics, fakeSub());
      expect(events.length, 1);
      expect(events[0].start.isUtc, isTrue);
    });
  });

  // ── 2. One-off all-day VEVENT ─────────────────────────────────────────────

  group('one-off all-day VEVENT', () {
    test('is parsed and flagged isAllDay=true', () {
      final nextWeek = tomorrow.add(const Duration(days: 6));
      final ics = icsWrap(
        [
          'BEGIN:VEVENT',
          'UID:allday@example.com',
          'SUMMARY:Public Holiday',
          'DTSTART;VALUE=DATE:${fmtDate(tomorrow)}',
          'DTEND;VALUE=DATE:${fmtDate(nextWeek)}',
          'END:VEVENT',
        ].join('\r\n'),
      );

      final events = service.parseBody(ics, fakeSub());
      expect(events.length, 1);
      expect(events[0].title, 'Public Holiday');
      expect(events[0].isAllDay, isTrue);
    });
  });

  // ── 3. SUMMARY with parameters ────────────────────────────────────────────

  group('SUMMARY with parameters', () {
    test('SUMMARY;LANGUAGE=en:Title is parsed correctly', () {
      final ics = icsWrap(
        [
          'BEGIN:VEVENT',
          'UID:lang@example.com',
          'SUMMARY;LANGUAGE=en:Multilingual Event',
          'DTSTART:${fmtDateTime(tomorrow)}',
          'END:VEVENT',
        ].join('\r\n'),
      );

      final events = service.parseBody(ics, fakeSub());
      expect(events.length, 1);
      expect(events[0].title, 'Multilingual Event');
    });

    test('SUMMARY;LANGUAGE=fr:Titre is parsed correctly', () {
      final ics = icsWrap(
        [
          'BEGIN:VEVENT',
          'UID:langfr@example.com',
          'SUMMARY;LANGUAGE=fr:Réunion hebdomadaire',
          'DTSTART:${fmtDateTime(tomorrow)}',
          'END:VEVENT',
        ].join('\r\n'),
      );

      final events = service.parseBody(ics, fakeSub());
      expect(events.length, 1);
      expect(events[0].title, 'Réunion hebdomadaire');
    });
  });

  // ── 4. UID with parameters ────────────────────────────────────────────────

  group('UID with parameters', () {
    test('UID;VALUE=TEXT:abc123 is used as event ID', () {
      final ics = icsWrap(
        [
          'BEGIN:VEVENT',
          'UID;VALUE=TEXT:abc123',
          'SUMMARY:Text UID Event',
          'DTSTART:${fmtDateTime(tomorrow)}',
          'END:VEVENT',
        ].join('\r\n'),
      );

      final events = service.parseBody(ics, fakeSub());
      expect(events.length, 1);
      expect(events[0].id, 'abc123');
    });
  });

  // ── 5. Stable fallback ID when UID is missing ─────────────────────────────

  group('stable fallback ID', () {
    test('same event parsed twice produces the same ID', () {
      final ics = icsWrap(
        [
          'BEGIN:VEVENT',
          'SUMMARY:No UID Event',
          'DTSTART:${fmtDateTime(tomorrow)}',
          'END:VEVENT',
        ].join('\r\n'),
      );

      final events1 = service.parseBody(ics, fakeSub());
      final events2 = service.parseBody(ics, fakeSub());
      expect(events1.length, 1);
      expect(events1[0].id, events2[0].id);
    });

    test('different start times produce different fallback IDs', () {
      final start1 = tomorrow;
      final start2 = tomorrow.add(const Duration(hours: 2));

      final ics = icsWrap(
        [
          'BEGIN:VEVENT',
          'SUMMARY:Event A',
          'DTSTART:${fmtDateTime(start1)}',
          'END:VEVENT',
          'BEGIN:VEVENT',
          'SUMMARY:Event A',
          'DTSTART:${fmtDateTime(start2)}',
          'END:VEVENT',
        ].join('\r\n'),
      );

      final events = service.parseBody(ics, fakeSub());
      expect(events.length, 2);
      expect(events[0].id, isNot(events[1].id));
    });
  });

  // ── 6. Weekly RRULE with COUNT ────────────────────────────────────────────

  group('weekly RRULE with COUNT', () {
    test('FREQ=WEEKLY;COUNT=4 produces exactly 4 occurrences', () {
      final nextMonday = _nextWeekday(now, DateTime.monday);
      final ics = icsWrap(
        [
          'BEGIN:VEVENT',
          'UID:wkcount@example.com',
          'SUMMARY:Weekly 4x',
          'DTSTART:${fmtDateTime(nextMonday)}',
          'RRULE:FREQ=WEEKLY;COUNT=4',
          'END:VEVENT',
        ].join('\r\n'),
      );

      final events = service.parseBody(ics, fakeSub());
      expect(events.length, 4);
      // Each occurrence should be exactly 7 days apart.
      for (var i = 1; i < events.length; i++) {
        final diff = events[i].start.difference(events[i - 1].start).inDays;
        expect(diff, 7);
      }
    });

    test('FREQ=WEEKLY;BYDAY=MO;COUNT=3 produces 3 Mondays', () {
      final nextMonday = _nextWeekday(now, DateTime.monday);
      final ics = icsWrap(
        [
          'BEGIN:VEVENT',
          'UID:wkbdcount@example.com',
          'SUMMARY:MO 3x',
          'DTSTART:${fmtDateTime(nextMonday)}',
          'RRULE:FREQ=WEEKLY;BYDAY=MO;COUNT=3',
          'END:VEVENT',
        ].join('\r\n'),
      );

      final events = service.parseBody(ics, fakeSub());
      expect(events.length, 3);
      for (final e in events) {
        expect(e.start.weekday, DateTime.monday);
      }
    });
  });

  // ── 7. Weekly RRULE with UNTIL ────────────────────────────────────────────

  group('weekly RRULE with UNTIL', () {
    test('FREQ=WEEKLY stops on UNTIL date (inclusive)', () {
      final start = _nextWeekday(now, DateTime.monday);
      // 3 weeks of Mondays: week0, week1, week2
      final until = start.add(const Duration(days: 14));
      final ics = icsWrap(
        [
          'BEGIN:VEVENT',
          'UID:wkuntil@example.com',
          'SUMMARY:Weekly Until',
          'DTSTART:${fmtDateTime(start)}',
          'RRULE:FREQ=WEEKLY;UNTIL=${fmtDateTime(until)}',
          'END:VEVENT',
        ].join('\r\n'),
      );

      final events = service.parseBody(ics, fakeSub());
      expect(events.length, 3); // start, start+7, start+14
      expect(
        events.last.start.isAfter(until.add(const Duration(seconds: 1))),
        isFalse,
        reason: 'No occurrence after UNTIL',
      );
    });
  });

  // ── 8. Daily RRULE ────────────────────────────────────────────────────────

  group('daily RRULE', () {
    test('FREQ=DAILY;COUNT=5 produces 5 consecutive days', () {
      final ics = icsWrap(
        [
          'BEGIN:VEVENT',
          'UID:daily5@example.com',
          'SUMMARY:Daily 5x',
          'DTSTART:${fmtDateTime(tomorrow)}',
          'RRULE:FREQ=DAILY;COUNT=5',
          'END:VEVENT',
        ].join('\r\n'),
      );

      final events = service.parseBody(ics, fakeSub());
      expect(events.length, 5);
      for (var i = 1; i < events.length; i++) {
        final diff = events[i].start.difference(events[i - 1].start).inDays;
        expect(diff, 1);
      }
    });

    test('FREQ=DAILY;UNTIL stops inclusively', () {
      final start = tomorrow;
      final until = start.add(const Duration(days: 4));
      final ics = icsWrap(
        [
          'BEGIN:VEVENT',
          'UID:dailyuntil@example.com',
          'SUMMARY:Daily Until',
          'DTSTART:${fmtDateTime(start)}',
          'RRULE:FREQ=DAILY;UNTIL=${fmtDateTime(until)}',
          'END:VEVENT',
        ].join('\r\n'),
      );

      final events = service.parseBody(ics, fakeSub());
      expect(events.length, 5); // day 0 through day 4
    });

    test('FREQ=DAILY with INTERVAL=2 steps every other day', () {
      final ics = icsWrap(
        [
          'BEGIN:VEVENT',
          'UID:daily2@example.com',
          'SUMMARY:Every Other Day',
          'DTSTART:${fmtDateTime(tomorrow)}',
          'RRULE:FREQ=DAILY;INTERVAL=2;COUNT=3',
          'END:VEVENT',
        ].join('\r\n'),
      );

      final events = service.parseBody(ics, fakeSub());
      expect(events.length, 3);
      final diff = events[1].start.difference(events[0].start).inDays;
      expect(diff, 2);
    });
  });

  // ── 9. Monthly RRULE ──────────────────────────────────────────────────────

  group('monthly RRULE', () {
    test('FREQ=MONTHLY;COUNT=3 produces 3 monthly occurrences', () {
      final ics = icsWrap(
        [
          'BEGIN:VEVENT',
          'UID:monthly3@example.com',
          'SUMMARY:Monthly 3x',
          'DTSTART:${fmtDateTime(tomorrow)}',
          'RRULE:FREQ=MONTHLY;COUNT=3',
          'END:VEVENT',
        ].join('\r\n'),
      );

      final events = service.parseBody(ics, fakeSub());
      expect(events.length, 3);
      // Each occurrence should be a different month (roughly 28–31 days apart).
      for (var i = 1; i < events.length; i++) {
        final diff = events[i].start.difference(events[i - 1].start).inDays;
        expect(diff, greaterThanOrEqualTo(28));
        expect(diff, lessThanOrEqualTo(31));
      }
    });

    test('monthly occurrences preserve day-of-month from DTSTART', () {
      // Pick a day that exists in all months (the 5th).
      final baseDate = DateTime(now.year, now.month, 5, 10, 0, 0);
      // Start in the past window (within 30 days) so it shows.
      final start = baseDate.isBefore(now.subtract(const Duration(days: 30)))
          ? DateTime(now.year, now.month, 5, 10, 0, 0).add(
              const Duration(days: 1),
            ) // fallback to tomorrow-ish
          : baseDate;

      final ics = icsWrap(
        [
          'BEGIN:VEVENT',
          'UID:monthlyday@example.com',
          'SUMMARY:Monthly Same Day',
          'DTSTART:${fmtDateTime(start)}',
          'RRULE:FREQ=MONTHLY;COUNT=3',
          'END:VEVENT',
        ].join('\r\n'),
      );

      final events = service.parseBody(ics, fakeSub());
      // Day 5 exists in every month, so each occurrence must be on day 5.
      for (final e in events) {
        expect(e.start.day, start.day);
      }
    });
  });

  // ── 10. EXDATE exclusion ──────────────────────────────────────────────────

  group('EXDATE', () {
    test('EXDATE removes the matching occurrence', () {
      final start = tomorrow;
      final excluded = start.add(const Duration(days: 1));
      final ics = icsWrap(
        [
          'BEGIN:VEVENT',
          'UID:exdate@example.com',
          'SUMMARY:Daily Except Day 2',
          'DTSTART:${fmtDateTime(start)}',
          'RRULE:FREQ=DAILY;COUNT=4',
          'EXDATE:${fmtDateTime(excluded)}',
          'END:VEVENT',
        ].join('\r\n'),
      );

      final events = service.parseBody(ics, fakeSub());
      // COUNT=4 candidates: day1, day2, day3, day4.
      // EXDATE removes day2; visible: day1, day3, day4.
      expect(events.length, 3);
      for (final e in events) {
        expect(
          e.start.day == excluded.day &&
              e.start.month == excluded.month &&
              e.start.year == excluded.year,
          isFalse,
          reason: 'Excluded date must not appear',
        );
      }
    });

    test('multiple EXDATE values on one line are all excluded', () {
      final start = tomorrow;
      final ex1 = start.add(const Duration(days: 1));
      final ex2 = start.add(const Duration(days: 2));
      final ics = icsWrap(
        [
          'BEGIN:VEVENT',
          'UID:exdate2@example.com',
          'SUMMARY:Daily Skip 2',
          'DTSTART:${fmtDateTime(start)}',
          'RRULE:FREQ=DAILY;COUNT=5',
          'EXDATE:${fmtDateTime(ex1)},${fmtDateTime(ex2)}',
          'END:VEVENT',
        ].join('\r\n'),
      );

      final events = service.parseBody(ics, fakeSub());
      // COUNT=5 candidates; 2 excluded → 3 visible.
      expect(events.length, 3);
    });
  });

  // ── 11. Does not expand outside the local window ──────────────────────────

  group('window enforcement', () {
    test('event 400 days in the future is excluded', () {
      final farFuture = DateTime(
        now.year,
        now.month,
        now.day,
        10,
        0,
        0,
      ).add(const Duration(days: 400));
      final ics = icsWrap(
        [
          'BEGIN:VEVENT',
          'UID:farfuture@example.com',
          'SUMMARY:Far Future',
          'DTSTART:${fmtDateTime(farFuture)}',
          'END:VEVENT',
        ].join('\r\n'),
      );

      expect(service.parseBody(ics, fakeSub()), isEmpty);
    });

    test('RRULE occurrences past windowEnd are not included', () {
      // Daily starting tomorrow; only within the 365-day window should appear.
      final ics = icsWrap(
        [
          'BEGIN:VEVENT',
          'UID:windowrrule@example.com',
          'SUMMARY:Infinite Daily',
          'DTSTART:${fmtDateTime(tomorrow)}',
          'RRULE:FREQ=DAILY',
          'END:VEVENT',
        ].join('\r\n'),
      );

      final events = service.parseBody(ics, fakeSub());
      expect(events, isNotEmpty);
      final windowEnd = now.add(const Duration(days: 365));
      for (final e in events) {
        expect(
          e.start.isBefore(windowEnd.add(const Duration(days: 1))),
          isTrue,
          reason: 'No event should be past windowEnd',
        );
      }
    });
  });

  // ── 12. Oversized ICS body throws friendly error ──────────────────────────

  group('readBody size limit', () {
    test('reads body within the 5 MB limit', () async {
      final data = 'BEGIN:VCALENDAR'.codeUnits;
      final stream = Stream<List<int>>.value(data);
      final result = await service.readBody(stream);
      expect(result, 'BEGIN:VCALENDAR');
    });

    test('throws LocalCalendarIcsException when body exceeds 5 MB', () async {
      final chunk = List<int>.filled(1024 * 1024, 65); // 1 MB of 'A'
      final stream = Stream<List<int>>.fromIterable(
        List.generate(6, (_) => chunk), // 6 MB total
      );

      await expectLater(
        service.readBody(stream),
        throwsA(
          isA<LocalCalendarIcsException>().having(
            (e) => e.message,
            'message',
            contains('too large'),
          ),
        ),
      );
    });

    test('body at exactly 5 MB is accepted', () async {
      final chunk = List<int>.filled(1024 * 1024, 65);
      final stream = Stream<List<int>>.fromIterable(
        List.generate(5, (_) => chunk), // exactly 5 MB
      );
      await expectLater(service.readBody(stream), completes);
    });
  });

  // ── 13. Invalid ICS does not crash ────────────────────────────────────────

  group('robustness', () {
    test('invalid ICS body does not throw', () {
      expect(
        () => service.parseBody('this is not valid ics\x00\xFF', fakeSub()),
        returnsNormally,
      );
    });

    test('empty VCALENDAR returns empty list', () {
      const ics = 'BEGIN:VCALENDAR\r\nVERSION:2.0\r\nEND:VCALENDAR';
      expect(service.parseBody(ics, fakeSub()), isEmpty);
    });

    test('VEVENT missing DTSTART is skipped without crash', () {
      final ics = icsWrap(
        [
          'BEGIN:VEVENT',
          'UID:nodtstart@example.com',
          'SUMMARY:No Start',
          'END:VEVENT',
        ].join('\r\n'),
      );

      expect(() => service.parseBody(ics, fakeSub()), returnsNormally);
      expect(service.parseBody(ics, fakeSub()), isEmpty);
    });

    test('DTSTART with TZID parameter is converted to UTC', () {
      final ics = icsWrap(
        [
          'BEGIN:VEVENT',
          'UID:tzid@example.com',
          'SUMMARY:Timezone Event',
          'DTSTART;TZID=Australia/Sydney:${fmtDateTime(tomorrow)}',
          'END:VEVENT',
        ].join('\r\n'),
      );

      expect(() => service.parseBody(ics, fakeSub()), returnsNormally);
      final events = service.parseBody(ics, fakeSub());
      expect(events.length, 1);
      expect(events[0].start.isUtc, isTrue);
    });

    test(
      'DTSTART;TZID=Australia/Sydney converts to the correct UTC instant',
      () {
        // Anchored to `now` (like the `tomorrow` helper above) rather than a
        // fixed calendar date -- a hardcoded absolute DTSTART (e.g.
        // 20260701T100000) silently falls out of the service's 30-day past
        // window once "today" drifts more than 30 days past it, making the
        // event vanish from parseBody()'s output and this test fail with no
        // code change involved. The expected UTC instant is computed via the
        // same `timezone` package/location production code uses
        // (LocalCalendarIcsService resolves TZID through
        // tz.getLocation()/tz.TZDateTime()), so this stays correct whether
        // "yesterday" falls in AEST or AEDT.
        final recentPast = DateTime(
          now.year,
          now.month,
          now.day,
          10,
          0,
          0,
        ).subtract(const Duration(days: 1));
        final expectedUtc = tz.TZDateTime(
          tz.getLocation('Australia/Sydney'),
          recentPast.year,
          recentPast.month,
          recentPast.day,
          recentPast.hour,
          recentPast.minute,
          recentPast.second,
        ).toUtc();

        final ics =
            'BEGIN:VEVENT\r\n'
            'UID:tzid-utc@example.com\r\n'
            'SUMMARY:Sydney to UTC\r\n'
            'DTSTART;TZID=Australia/Sydney:${fmtDateTime(recentPast)}\r\n'
            'END:VEVENT';

        final events = service.parseBody(icsWrap(ics), fakeSub());
        expect(events.length, 1);
        expect(events[0].start.isUtc, isTrue);
        expect(events[0].start, expectedUtc);
      },
    );

    test('DTSTART with unknown TZID falls back to floating local time', () {
      final ics = icsWrap(
        [
          'BEGIN:VEVENT',
          'UID:tzid-unknown@example.com',
          'SUMMARY:Unknown Zone Event',
          'DTSTART;TZID=Unknown/Timezone:${fmtDateTime(tomorrow)}',
          'END:VEVENT',
        ].join('\r\n'),
      );

      expect(() => service.parseBody(ics, fakeSub()), returnsNormally);
      final events = service.parseBody(ics, fakeSub());
      expect(events.length, 1);
    });

    test('events are returned sorted by start time', () {
      final d1 = tomorrow;
      final d2 = tomorrow.add(const Duration(days: 2));
      final d3 = tomorrow.add(const Duration(days: 1));

      final ics = icsWrap(
        [
          'BEGIN:VEVENT',
          'UID:s1@example.com',
          'SUMMARY:First',
          'DTSTART:${fmtDateTime(d1)}',
          'END:VEVENT',
          'BEGIN:VEVENT',
          'UID:s2@example.com',
          'SUMMARY:Third',
          'DTSTART:${fmtDateTime(d2)}',
          'END:VEVENT',
          'BEGIN:VEVENT',
          'UID:s3@example.com',
          'SUMMARY:Second',
          'DTSTART:${fmtDateTime(d3)}',
          'END:VEVENT',
        ].join('\r\n'),
      );

      final events = service.parseBody(ics, fakeSub());
      expect(events.length, 3);
      expect(events[0].start.isBefore(events[1].start), isTrue);
      expect(events[1].start.isBefore(events[2].start), isTrue);
    });

    test('DESCRIPTION and LOCATION lines are silently ignored', () {
      final ics = icsWrap(
        [
          'BEGIN:VEVENT',
          'UID:descr@example.com',
          'SUMMARY:Has Description',
          'DTSTART:${fmtDateTime(tomorrow)}',
          'DESCRIPTION:A long description that should be ignored.',
          'LOCATION:Conference Room 1',
          'END:VEVENT',
        ].join('\r\n'),
      );

      expect(() => service.parseBody(ics, fakeSub()), returnsNormally);
      final events = service.parseBody(ics, fakeSub());
      expect(events.length, 1);
      expect(events[0].title, 'Has Description');
    });
  });

  // ── Weekly BYDAY multi-day expansion ─────────────────────────────────────

  group('weekly BYDAY expansion', () {
    test('FREQ=WEEKLY;BYDAY=MO only produces Mondays', () {
      final nextMonday = _nextWeekday(now, DateTime.monday);
      final ics = icsWrap(
        [
          'BEGIN:VEVENT',
          'UID:mondays@example.com',
          'SUMMARY:Every Monday',
          'DTSTART:${fmtDateTime(nextMonday)}',
          'RRULE:FREQ=WEEKLY;BYDAY=MO',
          'END:VEVENT',
        ].join('\r\n'),
      );

      final events = service.parseBody(ics, fakeSub());
      expect(events.length, greaterThan(5));
      for (final e in events) {
        expect(e.start.weekday, DateTime.monday);
      }
    });

    test('FREQ=WEEKLY;BYDAY=MO,WE,FR produces three weekdays each week', () {
      final nextMonday = _nextWeekday(now, DateTime.monday);
      final until = nextMonday.add(const Duration(days: 6)); // one full week
      final ics = icsWrap(
        [
          'BEGIN:VEVENT',
          'UID:mwf@example.com',
          'SUMMARY:MWF',
          'DTSTART:${fmtDateTime(nextMonday)}',
          'RRULE:FREQ=WEEKLY;BYDAY=MO,WE,FR;UNTIL=${fmtDateTime(until)}',
          'END:VEVENT',
        ].join('\r\n'),
      );

      final events = service.parseBody(ics, fakeSub());
      expect(events.length, 3);
      final weekdays = events.map((e) => e.start.weekday).toList()..sort();
      expect(weekdays, [DateTime.monday, DateTime.wednesday, DateTime.friday]);
    });
  });

  // ── Yearly RRULE ──────────────────────────────────────────────────────────

  group('yearly RRULE', () {
    test('FREQ=YEARLY produces occurrences with same month/day as DTSTART', () {
      final ics = icsWrap(
        [
          'BEGIN:VEVENT',
          'UID:yearly@example.com',
          'SUMMARY:Annual',
          'DTSTART:${fmtDateTime(tomorrow)}',
          'RRULE:FREQ=YEARLY;COUNT=3',
          'END:VEVENT',
        ].join('\r\n'),
      );

      final events = service.parseBody(ics, fakeSub());
      // At least the first occurrence (tomorrow) must be in window.
      expect(events, isNotEmpty);
      for (final e in events) {
        expect(e.start.month, tomorrow.month);
        expect(e.start.day, tomorrow.day);
        expect(e.start.hour, 10);
      }
    });

    test('FREQ=YEARLY;COUNT=2 with UTC DTSTART preserves UTC and produces '
        'the correct second occurrence', () {
      // DTSTART:20260202T090000Z, COUNT=2.
      // Candidate 1: 2026-02-02 (before 30-day past window → not visible).
      // Candidate 2: 2027-02-02 (within window → visible).
      const ics =
          'BEGIN:VEVENT\r\n'
          'UID:yearly2@example.com\r\n'
          'SUMMARY:Annual UTC\r\n'
          'DTSTART:20260202T090000Z\r\n'
          'RRULE:FREQ=YEARLY;COUNT=2\r\n'
          'END:VEVENT';

      final events = service.parseBody(icsWrap(ics), fakeSub());
      expect(events.length, 1);
      expect(events[0].start, DateTime.utc(2027, 2, 2, 9, 0, 0));
      expect(events[0].start.isUtc, isTrue);
    });

    test('consecutive YEARLY occurrences are 365 or 366 days apart', () {
      // Use a date whose next two yearly occurrences both fit inside the window.
      // tomorrow → tomorrow+1yr and tomorrow+2yr may straddle the window end,
      // so we just assert on the gap between any two consecutive results.
      final ics = icsWrap(
        [
          'BEGIN:VEVENT',
          'UID:yearlygap@example.com',
          'SUMMARY:Annual Gap',
          'DTSTART:${fmtDateTime(tomorrow)}',
          'RRULE:FREQ=YEARLY',
          'END:VEVENT',
        ].join('\r\n'),
      );

      final events = service.parseBody(ics, fakeSub());
      expect(events, isNotEmpty);
      for (var i = 1; i < events.length; i++) {
        final diff = events[i].start.difference(events[i - 1].start).inDays;
        expect(diff, greaterThanOrEqualTo(365));
        expect(diff, lessThanOrEqualTo(366));
      }
    });
  });

  // ── Ordinal BYDAY rejection ───────────────────────────────────────────────

  group('ordinal BYDAY', () {
    test('BYDAY=2MO is ignored entirely — no occurrences produced', () {
      final nextMonday = _nextWeekday(now, DateTime.monday);
      final ics = icsWrap(
        [
          'BEGIN:VEVENT',
          'UID:ordinal2mo@example.com',
          'SUMMARY:2nd Monday',
          'DTSTART:${fmtDateTime(nextMonday)}',
          'RRULE:FREQ=WEEKLY;BYDAY=2MO;COUNT=4',
          'END:VEVENT',
        ].join('\r\n'),
      );

      final events = service.parseBody(ics, fakeSub());
      // 2MO is ordinal → ignored → no events.
      expect(events, isEmpty);
    });

    test('BYDAY=MO,2TU includes MO and ignores 2TU', () {
      final nextMonday = _nextWeekday(now, DateTime.monday);
      // One full week only.
      final until = nextMonday.add(const Duration(days: 6));
      final ics = icsWrap(
        [
          'BEGIN:VEVENT',
          'UID:ordinalMixed@example.com',
          'SUMMARY:MO and 2TU',
          'DTSTART:${fmtDateTime(nextMonday)}',
          'RRULE:FREQ=WEEKLY;BYDAY=MO,2TU;UNTIL=${fmtDateTime(until)}',
          'END:VEVENT',
        ].join('\r\n'),
      );

      final events = service.parseBody(ics, fakeSub());
      // Only Monday should appear (2TU is ordinal and ignored).
      expect(events.length, 1);
      expect(events[0].start.weekday, DateTime.monday);
    });
  });

  // ── UTC recurrence preservation ───────────────────────────────────────────

  group('UTC recurrence', () {
    test('FREQ=DAILY with UTC DTSTART produces UTC occurrences', () {
      final dtStart = DateTime.utc(
        tomorrow.year,
        tomorrow.month,
        tomorrow.day,
        9,
        0,
        0,
      );
      final ics = icsWrap(
        [
          'BEGIN:VEVENT',
          'UID:utcdaily@example.com',
          'SUMMARY:UTC Daily',
          'DTSTART:${fmtDate(dtStart)}T090000Z',
          'RRULE:FREQ=DAILY;COUNT=3',
          'END:VEVENT',
        ].join('\r\n'),
      );

      final events = service.parseBody(ics, fakeSub());
      expect(events.length, 3);
      for (final e in events) {
        expect(e.start.isUtc, isTrue);
      }
    });

    test('FREQ=WEEKLY with UTC DTSTART produces UTC occurrences', () {
      final dtStart = DateTime.utc(
        tomorrow.year,
        tomorrow.month,
        tomorrow.day,
        9,
        0,
        0,
      );
      final ics = icsWrap(
        [
          'BEGIN:VEVENT',
          'UID:utcweekly@example.com',
          'SUMMARY:UTC Weekly',
          'DTSTART:${fmtDate(dtStart)}T090000Z',
          'RRULE:FREQ=WEEKLY;COUNT=3',
          'END:VEVENT',
        ].join('\r\n'),
      );

      final events = service.parseBody(ics, fakeSub());
      expect(events.length, 3);
      for (final e in events) {
        expect(e.start.isUtc, isTrue);
      }
    });

    test('FREQ=WEEKLY;BYDAY with UTC DTSTART produces UTC occurrences', () {
      final nextMonday = _nextWeekday(now, DateTime.monday);
      final dtStart = DateTime.utc(
        nextMonday.year,
        nextMonday.month,
        nextMonday.day,
        9,
        0,
        0,
      );
      final ics = icsWrap(
        [
          'BEGIN:VEVENT',
          'UID:utcbyday@example.com',
          'SUMMARY:UTC BYDAY',
          'DTSTART:${fmtDate(dtStart)}T090000Z',
          'RRULE:FREQ=WEEKLY;BYDAY=MO;COUNT=3',
          'END:VEVENT',
        ].join('\r\n'),
      );

      final events = service.parseBody(ics, fakeSub());
      expect(events.length, 3);
      for (final e in events) {
        expect(e.start.isUtc, isTrue);
      }
    });

    test('FREQ=MONTHLY with UTC DTSTART produces UTC occurrences', () {
      final dtStart = DateTime.utc(
        tomorrow.year,
        tomorrow.month,
        tomorrow.day,
        9,
        0,
        0,
      );
      final ics = icsWrap(
        [
          'BEGIN:VEVENT',
          'UID:utcmonthly@example.com',
          'SUMMARY:UTC Monthly',
          'DTSTART:${fmtDate(dtStart)}T090000Z',
          'RRULE:FREQ=MONTHLY;COUNT=3',
          'END:VEVENT',
        ].join('\r\n'),
      );

      final events = service.parseBody(ics, fakeSub());
      expect(events.length, 3);
      for (final e in events) {
        expect(e.start.isUtc, isTrue);
      }
    });

    test('FREQ=YEARLY with UTC DTSTART produces UTC occurrences', () {
      final dtStart = DateTime.utc(
        tomorrow.year,
        tomorrow.month,
        tomorrow.day,
        9,
        0,
        0,
      );
      final ics = icsWrap(
        [
          'BEGIN:VEVENT',
          'UID:utcyearly@example.com',
          'SUMMARY:UTC Yearly',
          'DTSTART:${fmtDate(dtStart)}T090000Z',
          'RRULE:FREQ=YEARLY;COUNT=2',
          'END:VEVENT',
        ].join('\r\n'),
      );

      final events = service.parseBody(ics, fakeSub());
      expect(events, isNotEmpty);
      for (final e in events) {
        expect(e.start.isUtc, isTrue);
      }
    });
  });

  // ── Repository duplicate URL tests ────────────────────────────────────────

  group('LocalCalendarSubscriptionRepository — duplicate handling', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
    });

    test(
      'adding the same URL twice returns the existing subscription',
      () async {
        final repo = LocalCalendarSubscriptionRepository();

        final first = await repo.add(
          title: 'My Calendar',
          url: 'https://example.com/cal.ics',
          source: 'test',
        );
        final second = await repo.add(
          title: 'My Calendar Again',
          url: 'https://example.com/cal.ics',
          source: 'test',
        );

        expect(second.id, first.id);
        final all = await repo.list();
        expect(all.length, 1);
      },
    );

    test(
      'webcal:// and https:// for the same host are treated as duplicates',
      () async {
        final repo = LocalCalendarSubscriptionRepository();

        await repo.add(
          title: 'Cal A',
          url: 'webcal://example.com/cal.ics',
          source: 'test',
        );
        await repo.add(
          title: 'Cal B',
          url: 'https://example.com/cal.ics',
          source: 'test',
        );

        final all = await repo.list();
        expect(all.length, 1);
        expect(all[0].url, 'https://example.com/cal.ics');
      },
    );
  });
}

// ── Utilities ─────────────────────────────────────────────────────────────────

String _pad(int n) => n.toString().padLeft(2, '0');

/// Returns the next occurrence of [weekday] at 10:00 strictly after [from].
DateTime _nextWeekday(DateTime from, int weekday) {
  var dt = from.add(const Duration(days: 1));
  while (dt.weekday != weekday) {
    dt = dt.add(const Duration(days: 1));
  }
  return DateTime(dt.year, dt.month, dt.day, 10, 0, 0);
}
