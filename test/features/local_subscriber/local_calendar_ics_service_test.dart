import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:calee_mobile/features/local_subscriber/local_calendar_ics_service.dart';
import 'package:calee_mobile/features/local_subscriber/local_calendar_subscription.dart';
import 'package:calee_mobile/features/local_subscriber/local_calendar_subscription_repository.dart';

void main() {
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

  String fmtDate(DateTime dt) =>
      '${dt.year}${_pad(dt.month)}${_pad(dt.day)}';

  String fmtDateTime(DateTime dt) =>
      '${fmtDate(dt)}T${_pad(dt.hour)}${_pad(dt.minute)}${_pad(dt.second)}';

  // Anchored to a clean local time so tests are deterministic.
  final now = DateTime.now();
  final tomorrow = DateTime(now.year, now.month, now.day, 10, 0, 0)
      .add(const Duration(days: 1));
  final nextWeekDate = DateTime(now.year, now.month, now.day, 10, 0, 0)
      .add(const Duration(days: 7));

  // ── parseBody tests ───────────────────────────────────────────────────────

  group('parseBody — one-off events', () {
    test('timed event is parsed and returned', () {
      final start = tomorrow;
      final end = tomorrow.add(const Duration(hours: 1));
      final ics = icsWrap([
        'BEGIN:VEVENT',
        'UID:timed@example.com',
        'SUMMARY:Team Meeting',
        'DTSTART:${fmtDateTime(start)}',
        'DTEND:${fmtDateTime(end)}',
        'END:VEVENT',
      ].join('\r\n'));

      final events = service.parseBody(ics, fakeSub());
      expect(events.length, 1);
      expect(events[0].title, 'Team Meeting');
      expect(events[0].isAllDay, isFalse);
      expect(events[0].start.hour, 10);
      expect(events[0].end, isNotNull);
    });

    test('all-day event is parsed and returned', () {
      final ics = icsWrap([
        'BEGIN:VEVENT',
        'UID:allday@example.com',
        'SUMMARY:Public Holiday',
        'DTSTART;VALUE=DATE:${fmtDate(tomorrow)}',
        'DTEND;VALUE=DATE:${fmtDate(nextWeekDate)}',
        'END:VEVENT',
      ].join('\r\n'));

      final events = service.parseBody(ics, fakeSub());
      expect(events.length, 1);
      expect(events[0].title, 'Public Holiday');
      expect(events[0].isAllDay, isTrue);
    });

    test('event outside window is not returned', () {
      // 400 days from now — beyond the 365-day window
      final farFuture = DateTime(now.year, now.month, now.day)
          .add(const Duration(days: 400));
      final ics = icsWrap([
        'BEGIN:VEVENT',
        'UID:future@example.com',
        'SUMMARY:Far Future',
        'DTSTART:${fmtDateTime(farFuture)}',
        'END:VEVENT',
      ].join('\r\n'));

      final events = service.parseBody(ics, fakeSub());
      expect(events, isEmpty);
    });
  });

  group('parseBody — RRULE expansion', () {
    test('weekly RRULE with BYDAY expands to correct weekday', () {
      // Find next Monday.
      final nextMonday = _nextWeekday(now, DateTime.monday);
      final ics = icsWrap([
        'BEGIN:VEVENT',
        'UID:weekly@example.com',
        'SUMMARY:Weekly Standup',
        'DTSTART:${fmtDateTime(nextMonday)}',
        'DTEND:${fmtDateTime(nextMonday.add(const Duration(hours: 1)))}',
        'RRULE:FREQ=WEEKLY;BYDAY=MO',
        'END:VEVENT',
      ].join('\r\n'));

      final events = service.parseBody(ics, fakeSub());
      // ~52 Mondays in 365 days; expect at least several.
      expect(events.length, greaterThan(5));
      for (final e in events) {
        expect(e.start.weekday, DateTime.monday,
            reason: 'All occurrences should be Mondays');
        expect(e.title, 'Weekly Standup');
      }
    });

    test('RRULE FREQ=DAILY with UNTIL stops inclusively at UNTIL', () {
      final start = tomorrow;
      final until = start.add(const Duration(days: 20));
      final ics = icsWrap([
        'BEGIN:VEVENT',
        'UID:until@example.com',
        'SUMMARY:Daily Until',
        'DTSTART:${fmtDateTime(start)}',
        'RRULE:FREQ=DAILY;UNTIL=${fmtDateTime(until)}',
        'END:VEVENT',
      ].join('\r\n'));

      final events = service.parseBody(ics, fakeSub());
      // start, start+1, …, start+20 = 21 occurrences, all within window.
      expect(events.length, 21);
      expect(
        events.last.start.isBefore(until.add(const Duration(seconds: 1))),
        isTrue,
      );
    });

    test('RRULE FREQ=DAILY with COUNT limits to exact count', () {
      final start = tomorrow;
      final ics = icsWrap([
        'BEGIN:VEVENT',
        'UID:count@example.com',
        'SUMMARY:Three Times',
        'DTSTART:${fmtDateTime(start)}',
        'RRULE:FREQ=DAILY;COUNT=3',
        'END:VEVENT',
      ].join('\r\n'));

      final events = service.parseBody(ics, fakeSub());
      expect(events.length, 3);
    });

    test('RRULE occurrences in EXDATE are excluded', () {
      final start = tomorrow;
      final excluded = start.add(const Duration(days: 1));
      final ics = icsWrap([
        'BEGIN:VEVENT',
        'UID:exdate@example.com',
        'SUMMARY:Daily Except Day 2',
        'DTSTART:${fmtDateTime(start)}',
        'RRULE:FREQ=DAILY;COUNT=4',
        'EXDATE:${fmtDateTime(excluded)}',
        'END:VEVENT',
      ].join('\r\n'));

      final events = service.parseBody(ics, fakeSub());
      // 4 total - 1 excluded = 3
      expect(events.length, 3);
      for (final e in events) {
        expect(e.start.day, isNot(excluded.day));
      }
    });

    test('unsupported FREQ is ignored without crash', () {
      final ics = icsWrap([
        'BEGIN:VEVENT',
        'UID:yearly@example.com',
        'SUMMARY:Annual',
        'DTSTART:${fmtDateTime(tomorrow)}',
        'RRULE:FREQ=YEARLY',
        'END:VEVENT',
      ].join('\r\n'));

      // Should not throw; unsupported FREQ yields no expanded occurrences.
      expect(() => service.parseBody(ics, fakeSub()), returnsNormally);
      final events = service.parseBody(ics, fakeSub());
      expect(events, isEmpty);
    });
  });

  group('parseBody — robustness', () {
    test('invalid ICS body does not throw', () {
      expect(
        () => service.parseBody(
          'this is not valid ics at all\x00\xFF',
          fakeSub(),
        ),
        returnsNormally,
      );
    });

    test('empty VCALENDAR returns empty list', () {
      const ics = 'BEGIN:VCALENDAR\r\nVERSION:2.0\r\nEND:VCALENDAR';
      expect(service.parseBody(ics, fakeSub()), isEmpty);
    });

    test('VEVENT missing DTSTART is skipped without crash', () {
      final ics = icsWrap([
        'BEGIN:VEVENT',
        'UID:nodtstart@example.com',
        'SUMMARY:No Start',
        'END:VEVENT',
      ].join('\r\n'));

      expect(() => service.parseBody(ics, fakeSub()), returnsNormally);
      expect(service.parseBody(ics, fakeSub()), isEmpty);
    });

    test('events are returned sorted by start time', () {
      final d1 = tomorrow;
      final d2 = tomorrow.add(const Duration(days: 2));
      final d3 = tomorrow.add(const Duration(days: 1));

      final ics = icsWrap([
        'BEGIN:VEVENT',
        'UID:ev1@example.com',
        'SUMMARY:Event 1',
        'DTSTART:${fmtDateTime(d1)}',
        'END:VEVENT',
        'BEGIN:VEVENT',
        'UID:ev2@example.com',
        'SUMMARY:Event 3',
        'DTSTART:${fmtDateTime(d2)}',
        'END:VEVENT',
        'BEGIN:VEVENT',
        'UID:ev3@example.com',
        'SUMMARY:Event 2',
        'DTSTART:${fmtDateTime(d3)}',
        'END:VEVENT',
      ].join('\r\n'));

      final events = service.parseBody(ics, fakeSub());
      expect(events.length, 3);
      expect(events[0].start.isBefore(events[1].start), isTrue);
      expect(events[1].start.isBefore(events[2].start), isTrue);
    });
  });

  // ── readBody tests ────────────────────────────────────────────────────────

  group('readBody', () {
    test('reads body within the size limit', () async {
      final data = 'BEGIN:VCALENDAR'.codeUnits;
      final stream = Stream<List<int>>.value(data);
      final result = await service.readBody(stream);
      expect(result, 'BEGIN:VCALENDAR');
    });

    test('throws LocalCalendarIcsException when body exceeds 5 MB', () async {
      // 6 chunks of 1 MB each.
      final chunk = List<int>.filled(1024 * 1024, 65); // 'A'
      final stream = Stream<List<int>>.fromIterable(
        List.generate(6, (_) => chunk),
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

    test('body at exactly the limit is accepted', () async {
      // 5 MB exactly — should succeed.
      final chunk = List<int>.filled(1024 * 1024, 65);
      final stream = Stream<List<int>>.fromIterable(
        List.generate(5, (_) => chunk),
      );
      // Must not throw.
      await expectLater(service.readBody(stream), completes);
    });
  });

  // ── Repository duplicate URL tests ───────────────────────────────────────

  group('LocalCalendarSubscriptionRepository — duplicate handling', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
    });

    test('adding the same URL twice returns the existing subscription', () async {
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
    });

    test('webcal:// and https:// for the same host are treated as duplicates',
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
    });
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
