// Regression suite for CaleeAdmin/CaleeMobile#557 — detached recurring events
// in signed-out local calendar subscriptions.
//
// Before this suite existed the parser emitted a LocalCalendarEvent at every
// END:VEVENT, so a recurring master and its detached RECURRENCE-ID components
// were unrelated events: a modified occurrence rendered twice (once at its
// original time from the master expansion, once at its moved time from the
// override) and a detached STATUS:CANCELLED component rendered as a second
// visible event beside the occurrence it was meant to cancel. Separately,
// DAILY/WEEKLY expansion advanced an already-UTC instant by a fixed Duration,
// which drifts a wall-clock rule by an hour across a DST boundary — so a
// Sydney 10:00 series became 11:00 and no correct RECURRENCE-ID could match it.
//
// Every fixture here is anchored to a FIXED parser clock (see [fixedNow]) so
// nothing expires as the real date moves, and the canonical identities asserted
// below are byte-identical to the contracts merged in
// CaleeAdmin/calee-hub-core#420 and CaleeAdmin/calee-hub-calembed#70:
//
//   Perth   15:30 on 18 Aug 2026  → 20260818T073000Z
//   Sydney  10:00 on 29 Sep 2026  → 20260929T000000Z   (AEST)
//   Sydney  10:00 on  6 Oct 2026  → 20261005T230000Z   (AEDT)
//   Sydney  10:00 on 13 Oct 2026  → 20261012T230000Z   (AEDT)
//   all-day        18 Aug 2026    → 20260818

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/data/latest.dart' as tz_data;
import 'package:timezone/timezone.dart' as tz;

import 'package:calee_mobile/features/local_subscriber/local_calendar_event.dart';
import 'package:calee_mobile/features/local_subscriber/local_calendar_ics_service.dart';
import 'package:calee_mobile/features/local_subscriber/local_calendar_subscription.dart';
import 'package:calee_mobile/features/local_subscriber/local_calendar_subscription_repository.dart';

void main() {
  setUpAll(() {
    tz_data.initializeTimeZones();
  });

  const service = LocalCalendarIcsService();

  /// Fixed parser clock. The window is 30 days back / 365 days forward, so
  /// every fixture below sits inside 2026-07-19 .. 2027-08-18 unless it is
  /// deliberately placed outside to exercise window behaviour.
  final fixedNow = DateTime.utc(2026, 8, 18, 4);

  LocalCalendarSubscription fakeSub({String id = 'test_id'}) {
    return LocalCalendarSubscription(
      id: id,
      title: 'Test Calendar',
      url: 'https://example.com/cal.ics',
      source: 'test',
      createdAt: DateTime(2024, 1, 1),
    );
  }

  String ics(List<String> lines) => [
    'BEGIN:VCALENDAR',
    'VERSION:2.0',
    ...lines,
    'END:VCALENDAR',
  ].join('\r\n');

  List<LocalCalendarEvent> parse(String body) =>
      service.parseBody(body, fakeSub(), now: fixedNow);

  /// Compact UTC stamp of an instant, in the same shape as a timed canonical
  /// recurrence identity — used to prove `start` independently of `recurrenceId`.
  String utcStamp(DateTime value) {
    final u = value.toUtc();
    String p(int v, [int w = 2]) => v.toString().padLeft(w, '0');
    return '${p(u.year, 4)}${p(u.month)}${p(u.day)}'
        'T${p(u.hour)}${p(u.minute)}${p(u.second)}Z';
  }

  List<String> identities(List<LocalCalendarEvent> events) =>
      events.map((e) => e.recurrenceId ?? '(none)').toList();

  List<String> starts(List<LocalCalendarEvent> events) =>
      events.map((e) => utcStamp(e.start)).toList();

  /// Floating values inherit device-local semantics, which CI pins with
  /// `TZ=Australia/Perth`. Elsewhere the expected identity would differ, so the
  /// affected fixtures skip rather than assert something host-dependent.
  final perthOnly = Platform.environment['TZ'] == 'Australia/Perth'
      ? null
      : 'floating-time parity requires TZ=Australia/Perth';

  // The Perth fixture from the issue: a weekly master plus one detached
  // component that moves the 18 Aug occurrence from 15:30 to 16:00.
  const perthMaster = [
    'BEGIN:VEVENT',
    'UID:choir-1@example',
    'SUMMARY:Choir',
    'DTSTART;TZID=Australia/Perth:20260804T153000',
    'DTEND;TZID=Australia/Perth:20260804T163000',
    'RRULE:FREQ=WEEKLY;COUNT=4',
    'END:VEVENT',
  ];

  const perthOverride = [
    'BEGIN:VEVENT',
    'UID:choir-1@example',
    'SUMMARY:Choir - changed',
    'RECURRENCE-ID;TZID=Australia/Perth:20260818T153000',
    'DTSTART;TZID=Australia/Perth:20260818T160000',
    'DTEND;TZID=Australia/Perth:20260818T170000',
    'END:VEVENT',
  ];

  // The Sydney fixture: a weekly master that crosses the 2026-10-04
  // AEST → AEDT transition.
  const sydneyMaster = [
    'BEGIN:VEVENT',
    'UID:syd-1@example',
    'SUMMARY:Sydney standup',
    'DTSTART;TZID=Australia/Sydney:20260929T100000',
    'DTEND;TZID=Australia/Sydney:20260929T110000',
    'RRULE:FREQ=WEEKLY;COUNT=3',
    'END:VEVENT',
  ];

  // ── 01-03. Behaviour that must not change ───────────────────────────────────

  group('01-03 unchanged behaviour', () {
    test('01 a one-off timed event is unchanged', () {
      final events = parse(
        ics([
          'BEGIN:VEVENT',
          'UID:one-off@example',
          'SUMMARY:Team Meeting',
          'DTSTART;TZID=Australia/Perth:20260818T153000',
          'DTEND;TZID=Australia/Perth:20260818T163000',
          'END:VEVENT',
        ]),
      );

      expect(events.length, 1);
      expect(events[0].title, 'Team Meeting');
      expect(events[0].isAllDay, isFalse);
      expect(utcStamp(events[0].start), '20260818T073000Z');
      expect(events[0].id, 'one-off@example');
      expect(events[0].uid, 'one-off@example');
      // A one-off names no occurrence within a series.
      expect(events[0].recurrenceId, isNull);
    });

    test('02 a one-off all-day event is unchanged', () {
      final events = parse(
        ics([
          'BEGIN:VEVENT',
          'UID:holiday@example',
          'SUMMARY:Public Holiday',
          'DTSTART;VALUE=DATE:20260818',
          'DTEND;VALUE=DATE:20260819',
          'END:VEVENT',
        ]),
      );

      expect(events.length, 1);
      expect(events[0].isAllDay, isTrue);
      expect(events[0].start.year, 2026);
      expect(events[0].start.month, 8);
      expect(events[0].start.day, 18);
      expect(events[0].id, 'holiday@example');
      expect(events[0].uid, 'holiday@example');
      expect(events[0].recurrenceId, isNull);
    });

    test('03 an ordinary COUNT=4 recurring series is unchanged', () {
      final events = parse(ics([...perthMaster]));

      expect(events.length, 4);
      expect(starts(events), [
        '20260804T073000Z',
        '20260811T073000Z',
        '20260818T073000Z',
        '20260825T073000Z',
      ]);
      expect(identities(events), [
        '20260804T073000Z',
        '20260811T073000Z',
        '20260818T073000Z',
        '20260825T073000Z',
      ]);
      for (final event in events) {
        expect(event.uid, 'choir-1@example');
        expect(event.title, 'Choir');
        // A one-hour occurrence keeps its duration.
        expect(event.end!.difference(event.start), const Duration(hours: 1));
      }
    });
  });

  // ── 04-07. The reported defect ──────────────────────────────────────────────

  group('04-07 detached override and cancellation', () {
    test('04 a Perth detached override produces exactly FOUR events', () {
      final events = parse(ics([...perthMaster, ...perthOverride]));

      // Pre-fix this returned FIVE: the generated 18 Aug 15:30 occurrence
      // survived alongside the override at 16:00.
      expect(events.length, 4);
      expect(starts(events), [
        '20260804T073000Z', // 04 Aug 15:30 Perth
        '20260811T073000Z', // 11 Aug 15:30 Perth
        '20260818T080000Z', // 18 Aug 16:00 Perth — the override
        '20260825T073000Z', // 25 Aug 15:30 Perth
      ]);
      expect(events[2].title, 'Choir - changed');
    });

    test('05 the stale generated Perth occurrence is absent', () {
      final events = parse(ics([...perthMaster, ...perthOverride]));

      expect(
        starts(events),
        isNot(contains('20260818T073000Z')),
        reason: 'the replaced occurrence must not survive at its original time',
      );
      // Exactly one event owns the 18 Aug identity, and it is the override.
      final owners = events
          .where((e) => e.recurrenceId == '20260818T073000Z')
          .toList();
      expect(owners.length, 1);
      expect(owners[0].title, 'Choir - changed');
    });

    test('06 the moved occurrence keeps its ORIGINAL recurrenceId', () {
      final events = parse(ics([...perthMaster, ...perthOverride]));
      final moved = events.firstWhere((e) => e.title == 'Choir - changed');

      // Identity comes from RECURRENCE-ID (15:30), never from the moved
      // DTSTART (16:00).
      expect(moved.recurrenceId, '20260818T073000Z');
      expect(utcStamp(moved.start), '20260818T080000Z');
      expect(moved.uid, 'choir-1@example');
      expect(utcStamp(moved.end!), '20260818T090000Z');
    });

    test('07 a detached cancellation leaves exactly THREE events', () {
      final events = parse(
        ics([
          ...perthMaster,
          'BEGIN:VEVENT',
          'UID:choir-1@example',
          'SUMMARY:Choir',
          'RECURRENCE-ID;TZID=Australia/Perth:20260818T153000',
          'DTSTART;TZID=Australia/Perth:20260818T153000',
          'STATUS:CANCELLED',
          'END:VEVENT',
        ]),
      );

      // Pre-fix this returned FIVE: the cancellation itself rendered as a
      // second visible event beside the occurrence it was meant to cancel.
      expect(events.length, 3);
      expect(starts(events), [
        '20260804T073000Z',
        '20260811T073000Z',
        '20260825T073000Z',
      ]);
    });

    test('07b a cancellation beats a modification in either order', () {
      const cancellation = [
        'BEGIN:VEVENT',
        'UID:choir-1@example',
        'SUMMARY:Choir',
        'RECURRENCE-ID;TZID=Australia/Perth:20260818T153000',
        'DTSTART;TZID=Australia/Perth:20260818T153000',
        'STATUS:CANCELLED',
        'END:VEVENT',
      ];

      final cancelFirst = parse(
        ics([...perthMaster, ...cancellation, ...perthOverride]),
      );
      final cancelLast = parse(
        ics([...perthMaster, ...perthOverride, ...cancellation]),
      );

      expect(cancelFirst.length, 3);
      expect(cancelLast.length, 3);
      expect(starts(cancelFirst), starts(cancelLast));
    });
  });

  // ── 08-10. RECURRENCE-ID property forms ─────────────────────────────────────

  group('08-10 RECURRENCE-ID forms', () {
    test('08 a UTC RECURRENCE-ID matches a TZID-qualified occurrence', () {
      final events = parse(
        ics([
          ...perthMaster,
          'BEGIN:VEVENT',
          'UID:choir-1@example',
          'SUMMARY:Choir - UTC id',
          'RECURRENCE-ID:20260818T073000Z',
          'DTSTART;TZID=Australia/Perth:20260818T160000',
          'END:VEVENT',
        ]),
      );

      expect(events.length, 4);
      final moved = events.firstWhere((e) => e.title == 'Choir - UTC id');
      expect(moved.recurrenceId, '20260818T073000Z');
      expect(starts(events), isNot(contains('20260818T073000Z')));
    });

    test('09 a Perth TZID recurrence identity is 20260818T073000Z', () {
      final events = parse(ics([...perthMaster, ...perthOverride]));

      expect(
        events.firstWhere((e) => e.title == 'Choir - changed').recurrenceId,
        '20260818T073000Z',
        reason: 'must match Hub #420 and CalEmbed #70 byte for byte',
      );
    });

    test('10 a quoted TZID is read the same as an unquoted one', () {
      final events = parse(
        ics([
          'BEGIN:VEVENT',
          'UID:quoted@example',
          'SUMMARY:Quoted',
          'DTSTART;TZID="Australia/Perth":20260804T153000',
          'RRULE:FREQ=WEEKLY;COUNT=4',
          'END:VEVENT',
          'BEGIN:VEVENT',
          'UID:quoted@example',
          'SUMMARY:Quoted - changed',
          'RECURRENCE-ID;TZID="Australia/Perth":20260818T153000',
          'DTSTART;TZID="Australia/Perth":20260818T160000',
          'END:VEVENT',
        ]),
      );

      expect(events.length, 4);
      expect(starts(events), [
        '20260804T073000Z',
        '20260811T073000Z',
        '20260818T080000Z',
        '20260825T073000Z',
      ]);
      expect(
        events.firstWhere((e) => e.title == 'Quoted - changed').recurrenceId,
        '20260818T073000Z',
      );
    });
  });

  // ── 11-16. DST-safe wall-clock recurrence ───────────────────────────────────

  group('11-16 source wall-clock recurrence across DST', () {
    test('11 a Sydney AEST → AEDT weekly series keeps 10:00 local', () {
      final events = parse(ics([...sydneyMaster]));

      expect(events.length, 3);
      // Pre-fix these were 20260929T000000Z, 20261006T000000Z and
      // 20261013T000000Z — i.e. 11:00 Sydney once AEDT began.
      expect(identities(events), [
        '20260929T000000Z',
        '20261005T230000Z',
        '20261012T230000Z',
      ]);
      expect(starts(events), identities(events));

      // Proven independently of the parser: the same wall time in the same zone.
      final sydney = tz.getLocation('Australia/Sydney');
      for (final date in [
        [2026, 9, 29],
        [2026, 10, 6],
        [2026, 10, 13],
      ]) {
        expect(
          starts(events),
          contains(
            utcStamp(
              tz.TZDateTime(sydney, date[0], date[1], date[2], 10).toUtc(),
            ),
          ),
        );
      }
    });

    test('12 a Sydney DST detached override owns 20261005T230000Z', () {
      final events = parse(
        ics([
          ...sydneyMaster,
          'BEGIN:VEVENT',
          'UID:syd-1@example',
          'SUMMARY:Sydney standup - moved',
          'RECURRENCE-ID;TZID=Australia/Sydney:20261006T100000',
          'DTSTART;TZID=Australia/Sydney:20261006T140000',
          'DTEND;TZID=Australia/Sydney:20261006T150000',
          'END:VEVENT',
        ]),
      );

      expect(events.length, 3);
      expect(identities(events), [
        '20260929T000000Z',
        '20261005T230000Z',
        '20261012T230000Z',
      ]);

      final moved = events.firstWhere(
        (e) => e.recurrenceId == '20261005T230000Z',
      );
      expect(moved.title, 'Sydney standup - moved');
      // 14:00 Sydney on 6 Oct is AEDT (UTC+11) → 03:00Z.
      expect(utcStamp(moved.start), '20261006T030000Z');
      expect(utcStamp(moved.end!), '20261006T040000Z');
    });

    test('13 no drifted 20261006T000000Z occurrence remains', () {
      final withOverride = parse(
        ics([
          ...sydneyMaster,
          'BEGIN:VEVENT',
          'UID:syd-1@example',
          'SUMMARY:Sydney standup - moved',
          'RECURRENCE-ID;TZID=Australia/Sydney:20261006T100000',
          'DTSTART;TZID=Australia/Sydney:20261006T140000',
          'END:VEVENT',
        ]),
      );

      for (final events in [
        parse(ics([...sydneyMaster])),
        withOverride,
      ]) {
        expect(
          identities(events),
          isNot(contains('20261006T000000Z')),
          reason: '20261006T000000Z is 11:00 Sydney — the DST drift',
        );
        expect(starts(events), isNot(contains('20261006T000000Z')));
      }
    });

    test('14 a Sydney AEDT → AEST series also keeps 10:00 local', () {
      final events = parse(
        ics([
          'BEGIN:VEVENT',
          'UID:syd-reverse@example',
          'SUMMARY:Autumn standup',
          'DTSTART;TZID=Australia/Sydney:20270330T100000',
          'RRULE:FREQ=WEEKLY;COUNT=2',
          'END:VEVENT',
        ]),
      );

      expect(events.length, 2);
      // 30 Mar 2027 is AEDT (UTC+11); 6 Apr 2027 is AEST (UTC+10).
      expect(identities(events), ['20270329T230000Z', '20270406T000000Z']);
    });

    test('15 WEEKLY;BYDAY anchors the week on the SOURCE date across DST', () {
      // A Sydney 10:00 occurrence is 23:00 UTC the PREVIOUS day once AEDT
      // begins, so anchoring the ISO week on the UTC date would slip it a day.
      final events = parse(
        ics([
          'BEGIN:VEVENT',
          'UID:syd-byday@example',
          'SUMMARY:Sydney Tuesdays',
          'DTSTART;TZID=Australia/Sydney:20260929T100000',
          'RRULE:FREQ=WEEKLY;BYDAY=TU;COUNT=3',
          'END:VEVENT',
        ]),
      );

      expect(events.length, 3);
      expect(identities(events), [
        '20260929T000000Z',
        '20261005T230000Z',
        '20261012T230000Z',
      ]);
    });

    test('16 a DST-side TZID EXDATE removes the same logical occurrence', () {
      final events = parse(
        ics([
          'BEGIN:VEVENT',
          'UID:syd-exdate@example',
          'SUMMARY:Sydney standup',
          'DTSTART;TZID=Australia/Sydney:20260929T100000',
          'RRULE:FREQ=WEEKLY;COUNT=3',
          'EXDATE;TZID=Australia/Sydney:20261006T100000',
          'END:VEVENT',
        ]),
      );

      expect(events.length, 2);
      expect(identities(events), ['20260929T000000Z', '20261012T230000Z']);
    });
  });

  // ── 17-19. All-day and floating identity ────────────────────────────────────

  group('17-19 all-day and floating identity', () {
    const allDayMaster = [
      'BEGIN:VEVENT',
      'UID:allday-series@example',
      'SUMMARY:Bin night',
      'DTSTART;VALUE=DATE:20260804',
      'DTEND;VALUE=DATE:20260805',
      'RRULE:FREQ=WEEKLY;COUNT=3',
      'END:VEVENT',
    ];

    test('17 an all-day override keeps identity 20260818 and moves the date', () {
      final events = parse(
        ics([
          ...allDayMaster,
          'BEGIN:VEVENT',
          'UID:allday-series@example',
          'SUMMARY:Bin night - moved',
          'RECURRENCE-ID;VALUE=DATE:20260818',
          'DTSTART;VALUE=DATE:20260819',
          'DTEND;VALUE=DATE:20260820',
          'END:VEVENT',
        ]),
      );

      expect(events.length, 3);
      expect(identities(events), ['20260804', '20260811', '20260818']);

      final moved = events.firstWhere((e) => e.recurrenceId == '20260818');
      expect(moved.isAllDay, isTrue);
      // Identity stays on the ORIGINAL date; the event is displayed on the 19th.
      expect(moved.start.year, 2026);
      expect(moved.start.month, 8);
      expect(moved.start.day, 19);
      // No literal date is ever routed through a timezone conversion.
      expect(identities(events), everyElement(hasLength(8)));
    });

    test('18 an all-day cancellation leaves exactly TWO events', () {
      final events = parse(
        ics([
          ...allDayMaster,
          'BEGIN:VEVENT',
          'UID:allday-series@example',
          'SUMMARY:Bin night',
          'RECURRENCE-ID;VALUE=DATE:20260818',
          'DTSTART;VALUE=DATE:20260818',
          'STATUS:CANCELLED',
          'END:VEVENT',
        ]),
      );

      expect(events.length, 2);
      expect(identities(events), ['20260804', '20260811']);
    });

    test('19 a floating recurrence and floating RECURRENCE-ID agree', () {
      final events = parse(
        ics([
          'BEGIN:VEVENT',
          'UID:floating@example',
          'SUMMARY:Floating choir',
          'DTSTART:20260804T153000',
          'RRULE:FREQ=WEEKLY;COUNT=4',
          'END:VEVENT',
          'BEGIN:VEVENT',
          'UID:floating@example',
          'SUMMARY:Floating choir - changed',
          'RECURRENCE-ID:20260818T153000',
          'DTSTART:20260818T160000',
          'END:VEVENT',
        ]),
      );

      expect(events.length, 4);
      // Under TZ=Australia/Perth a floating 15:30 is 07:30Z.
      expect(identities(events), [
        '20260804T073000Z',
        '20260811T073000Z',
        '20260818T073000Z',
        '20260825T073000Z',
      ]);
      expect(
        events
            .firstWhere((e) => e.title == 'Floating choir - changed')
            .recurrenceId,
        '20260818T073000Z',
      );
    }, skip: perthOnly);

    test(
      '19b a floating RECURRENCE-ID inherits the component DTSTART zone',
      () {
        // The override's own DTSTART is Perth-qualified, so its unzoned
        // RECURRENCE-ID is read on Perth's clock — the same rule Hub Core and
        // CalEmbed apply — rather than being turned into UTC by appending Z.
        final events = parse(
          ics([
            ...perthMaster,
            'BEGIN:VEVENT',
            'UID:choir-1@example',
            'SUMMARY:Choir - inherited zone',
            'RECURRENCE-ID:20260818T153000',
            'DTSTART;TZID=Australia/Perth:20260818T160000',
            'END:VEVENT',
          ]),
        );

        expect(events.length, 4);
        expect(
          events
              .firstWhere((e) => e.title == 'Choir - inherited zone')
              .recurrenceId,
          '20260818T073000Z',
        );
      },
    );
  });

  // ── 20-23. EXDATE ───────────────────────────────────────────────────────────

  group('20-23 EXDATE', () {
    test('20 a UTC EXDATE removes the matching occurrence', () {
      final events = parse(
        ics([
          'BEGIN:VEVENT',
          'UID:exdate-utc@example',
          'SUMMARY:Choir',
          'DTSTART;TZID=Australia/Perth:20260804T153000',
          'RRULE:FREQ=WEEKLY;COUNT=4',
          'EXDATE:20260818T073000Z',
          'END:VEVENT',
        ]),
      );

      expect(events.length, 3);
      expect(identities(events), isNot(contains('20260818T073000Z')));
    });

    test('21 a TZID EXDATE removes the matching occurrence', () {
      final events = parse(
        ics([
          'BEGIN:VEVENT',
          'UID:exdate-tzid@example',
          'SUMMARY:Choir',
          'DTSTART;TZID=Australia/Perth:20260804T153000',
          'RRULE:FREQ=WEEKLY;COUNT=4',
          'EXDATE;TZID=Australia/Perth:20260818T153000',
          'END:VEVENT',
        ]),
      );

      expect(events.length, 3);
      expect(identities(events), [
        '20260804T073000Z',
        '20260811T073000Z',
        '20260825T073000Z',
      ]);
    });

    test('22 a date-only EXDATE removes an all-day occurrence', () {
      final events = parse(
        ics([
          'BEGIN:VEVENT',
          'UID:exdate-date@example',
          'SUMMARY:Bin night',
          'DTSTART;VALUE=DATE:20260804',
          'RRULE:FREQ=WEEKLY;COUNT=3',
          'EXDATE;VALUE=DATE:20260811',
          'END:VEVENT',
        ]),
      );

      expect(events.length, 2);
      expect(identities(events), ['20260804', '20260818']);
    });

    test('23 an EXDATE never hides its own detached replacement', () {
      // Some producers pair an override with an EXDATE for the original
      // occurrence. The replacement must still appear.
      final events = parse(
        ics([
          'BEGIN:VEVENT',
          'UID:choir-1@example',
          'SUMMARY:Choir',
          'DTSTART;TZID=Australia/Perth:20260804T153000',
          'RRULE:FREQ=WEEKLY;COUNT=4',
          'EXDATE;TZID=Australia/Perth:20260818T153000',
          'END:VEVENT',
          ...perthOverride,
        ]),
      );

      expect(events.length, 4);
      expect(starts(events), [
        '20260804T073000Z',
        '20260811T073000Z',
        '20260818T080000Z',
        '20260825T073000Z',
      ]);
      expect(
        events.firstWhere((e) => e.title == 'Choir - changed').recurrenceId,
        '20260818T073000Z',
      );
    });
  });

  // ── 24-26. Window interaction and determinism ───────────────────────────────

  group('24-26 window interaction', () {
    test('24 an override moved INTO the window appears once', () {
      // Both generated occurrences (01 Jul, 08 Jul) sit before windowStart
      // (2026-07-19); the override moves the 08 Jul occurrence to 20 Aug.
      final events = parse(
        ics([
          'BEGIN:VEVENT',
          'UID:moved-in@example',
          'SUMMARY:Moved in',
          'DTSTART;TZID=Australia/Perth:20260701T153000',
          'RRULE:FREQ=WEEKLY;COUNT=2',
          'END:VEVENT',
          'BEGIN:VEVENT',
          'UID:moved-in@example',
          'SUMMARY:Moved in - now',
          'RECURRENCE-ID;TZID=Australia/Perth:20260708T153000',
          'DTSTART;TZID=Australia/Perth:20260820T153000',
          'END:VEVENT',
        ]),
      );

      expect(events.length, 1);
      expect(events[0].title, 'Moved in - now');
      expect(utcStamp(events[0].start), '20260820T073000Z');
      // The ORIGINAL identity, even though that occurrence was never generated.
      expect(events[0].recurrenceId, '20260708T073000Z');
    });

    test('25 an override moved OUT of the window takes its twin with it', () {
      final events = parse(
        ics([
          ...perthMaster,
          'BEGIN:VEVENT',
          'UID:choir-1@example',
          'SUMMARY:Choir - far future',
          'RECURRENCE-ID;TZID=Australia/Perth:20260818T153000',
          'DTSTART;TZID=Australia/Perth:20271001T153000',
          'END:VEVENT',
        ]),
      );

      expect(events.length, 3);
      expect(starts(events), [
        '20260804T073000Z',
        '20260811T073000Z',
        '20260825T073000Z',
      ]);
      expect(
        identities(events),
        isNot(contains('20260818T073000Z')),
        reason: 'the stale generated occurrence must be suppressed too',
      );
      expect(events.map((e) => e.title), isNot(contains('Choir - far future')));
    });

    test('26 no (uid, recurrenceId) pair is ever emitted twice', () {
      final events = parse(
        ics([
          ...perthMaster,
          ...perthOverride,
          ...sydneyMaster,
          'BEGIN:VEVENT',
          'UID:syd-1@example',
          'SUMMARY:Sydney standup - moved',
          'RECURRENCE-ID;TZID=Australia/Sydney:20261006T100000',
          'DTSTART;TZID=Australia/Sydney:20261006T140000',
          'END:VEVENT',
        ]),
      );

      expect(events.length, 7);
      final pairs = events.map((e) => '${e.uid}|${e.recurrenceId}').toList();
      expect(pairs.toSet().length, pairs.length);
      expect(
        events.map((e) => e.id).toSet().length,
        events.length,
        reason: 'UI ids must stay unique within one fetch',
      );
    });

    test('26b duplicate modifications for one identity emit one event', () {
      final events = parse(
        ics([
          ...perthMaster,
          ...perthOverride,
          'BEGIN:VEVENT',
          'UID:choir-1@example',
          'SUMMARY:Choir - changed again',
          'RECURRENCE-ID;TZID=Australia/Perth:20260818T153000',
          'DTSTART;TZID=Australia/Perth:20260818T170000',
          'END:VEVENT',
        ]),
      );

      expect(events.length, 4);
      final owners = events
          .where((e) => e.recurrenceId == '20260818T073000Z')
          .toList();
      expect(owners.length, 1);
      // Deterministic: the last modification in document order wins.
      expect(owners[0].title, 'Choir - changed again');
      expect(utcStamp(owners[0].start), '20260818T090000Z');
    });
  });

  // ── 27-31. Source UID identity ──────────────────────────────────────────────

  group('27-31 source UID identity', () {
    test('27 a UID is preserved exactly', () {
      final events = parse(
        ics([
          'BEGIN:VEVENT',
          'UID:Mixed-CASE_uid@Example.COM',
          'SUMMARY:Exact',
          'DTSTART;TZID=Australia/Perth:20260818T153000',
          'END:VEVENT',
        ]),
      );

      expect(events.length, 1);
      expect(events[0].uid, 'Mixed-CASE_uid@Example.COM');
    });

    test('28 leading/trailing-space UIDs stay distinct identities', () {
      final events = parse(
        ics([
          'BEGIN:VEVENT',
          'UID: series-one',
          'SUMMARY:Padded',
          'DTSTART;TZID=Australia/Perth:20260818T153000',
          'END:VEVENT',
          'BEGIN:VEVENT',
          'UID:series-one',
          'SUMMARY:Bare',
          'DTSTART;TZID=Australia/Perth:20260818T163000',
          'END:VEVENT',
        ]),
      );

      expect(events.length, 2);
      final uids = events.map((e) => e.uid).toList();
      expect(uids, containsAll([' series-one', 'series-one']));
      expect(uids.toSet().length, 2);
    });

    test('29 an internal double space in a UID does not collapse', () {
      // A display sanitiser would fold `series  one` and `series one` into one
      // value, so an override belonging to one series would suppress an
      // occurrence belonging to the OTHER.
      final events = parse(
        ics([
          'BEGIN:VEVENT',
          'UID:series  one',
          'SUMMARY:Double space',
          'DTSTART;TZID=Australia/Perth:20260804T153000',
          'RRULE:FREQ=WEEKLY;COUNT=3',
          'END:VEVENT',
          'BEGIN:VEVENT',
          'UID:series one',
          'SUMMARY:Single space',
          'DTSTART;TZID=Australia/Perth:20260804T153000',
          'RRULE:FREQ=WEEKLY;COUNT=3',
          'END:VEVENT',
          'BEGIN:VEVENT',
          'UID:series  one',
          'SUMMARY:Double space - moved',
          'RECURRENCE-ID;TZID=Australia/Perth:20260818T153000',
          'DTSTART;TZID=Australia/Perth:20260818T170000',
          'END:VEVENT',
        ]),
      );

      // 3 + 3 logical occurrences: the override replaces one of the
      // double-space series' occurrences and touches nothing else.
      expect(events.length, 6);
      expect(events.map((e) => e.uid).toSet(), {'series  one', 'series one'});

      final singleSpace = events.where((e) => e.uid == 'series one').toList();
      expect(singleSpace.length, 3);
      expect(
        singleSpace.map((e) => e.recurrenceId),
        contains('20260818T073000Z'),
        reason: 'the other series must keep its 18 Aug occurrence',
      );

      final doubleSpace = events.where((e) => e.uid == 'series  one').toList();
      expect(doubleSpace.length, 3);
      expect(
        doubleSpace
            .firstWhere((e) => e.recurrenceId == '20260818T073000Z')
            .title,
        'Double space - moved',
      );
    });

    test('30 UID-less events still parse normally', () {
      final events = parse(
        ics([
          'BEGIN:VEVENT',
          'SUMMARY:No UID A',
          'DTSTART;TZID=Australia/Perth:20260818T153000',
          'END:VEVENT',
          'BEGIN:VEVENT',
          'SUMMARY:No UID B',
          'DTSTART;TZID=Australia/Perth:20260818T163000',
          'END:VEVENT',
        ]),
      );

      expect(events.length, 2);
      // A missing UID reports null — never a manufactured stand-in.
      expect(events.map((e) => e.uid), everyElement(isNull));
      expect(events[0].id, isNot(events[1].id));
    });

    test('31 a UID-less detached component cannot replace another event', () {
      final events = parse(
        ics([
          'BEGIN:VEVENT',
          'SUMMARY:No UID master',
          'DTSTART;TZID=Australia/Perth:20260804T153000',
          'RRULE:FREQ=WEEKLY;COUNT=4',
          'END:VEVENT',
          'BEGIN:VEVENT',
          'SUMMARY:No UID override',
          'RECURRENCE-ID;TZID=Australia/Perth:20260818T153000',
          'DTSTART;TZID=Australia/Perth:20260818T160000',
          'END:VEVENT',
        ]),
      );

      // The master keeps all four occurrences; the detached component is its
      // own unrelated event, exactly as before this change.
      expect(events.length, 5);
      expect(starts(events), contains('20260818T073000Z'));
      expect(starts(events), contains('20260818T080000Z'));
      expect(events.map((e) => e.uid), everyElement(isNull));
    });

    test('31b a UID-less cancelled detached component cancels nothing', () {
      final events = parse(
        ics([
          'BEGIN:VEVENT',
          'SUMMARY:No UID master',
          'DTSTART;TZID=Australia/Perth:20260804T153000',
          'RRULE:FREQ=WEEKLY;COUNT=4',
          'END:VEVENT',
          'BEGIN:VEVENT',
          'SUMMARY:No UID cancellation',
          'RECURRENCE-ID;TZID=Australia/Perth:20260818T153000',
          'DTSTART;TZID=Australia/Perth:20260818T153000',
          'STATUS:CANCELLED',
          'END:VEVENT',
        ]),
      );

      expect(events.length, 4);
      expect(starts(events), contains('20260818T073000Z'));
      expect(
        events.map((e) => e.title),
        isNot(contains('No UID cancellation')),
      );
    });

    test('31d a nested VALARM never hijacks the event UID', () {
      // RFC 9074 gives a VALARM its own UID, and a VALARM also carries SUMMARY.
      // If either reached the enclosing VEVENT the series would be grouped
      // under the ALARM's identity and its override would no longer match.
      final events = parse(
        ics([
          'BEGIN:VEVENT',
          'UID:choir-1@example',
          'SUMMARY:Choir',
          'DTSTART;TZID=Australia/Perth:20260804T153000',
          'RRULE:FREQ=WEEKLY;COUNT=4',
          'BEGIN:VALARM',
          'ACTION:DISPLAY',
          'UID:alarm-uid-1',
          'SUMMARY:Reminder',
          'DESCRIPTION:Choir starts soon',
          'TRIGGER:-PT15M',
          'END:VALARM',
          'END:VEVENT',
          ...perthOverride,
        ]),
      );

      expect(events.length, 4);
      expect(events.map((e) => e.uid), everyElement('choir-1@example'));
      expect(events.map((e) => e.title), isNot(contains('Reminder')));
      expect(starts(events), [
        '20260804T073000Z',
        '20260811T073000Z',
        '20260818T080000Z',
        '20260825T073000Z',
      ]);
    });

    test('31e a VTIMEZONE block outside a VEVENT is still ignored', () {
      final events = parse(
        ics([
          'BEGIN:VTIMEZONE',
          'TZID:Australia/Perth',
          'BEGIN:STANDARD',
          'DTSTART:19700101T000000',
          'TZOFFSETFROM:+0800',
          'TZOFFSETTO:+0800',
          'END:STANDARD',
          'END:VTIMEZONE',
          'BEGIN:VEVENT',
          'UID:after-vtimezone@example',
          'SUMMARY:Real event',
          'DTSTART;TZID=Australia/Perth:20260818T153000',
          'END:VEVENT',
        ]),
      );

      expect(events.length, 1);
      expect(events[0].uid, 'after-vtimezone@example');
      expect(events[0].title, 'Real event');
    });

    test('31c a malformed RECURRENCE-ID never silently deletes an event', () {
      final events = parse(
        ics([
          ...perthMaster,
          'BEGIN:VEVENT',
          'UID:choir-1@example',
          'SUMMARY:Choir - unreadable id',
          'RECURRENCE-ID;TZID=Australia/Perth:not-a-datetime',
          'DTSTART;TZID=Australia/Perth:20260818T160000',
          'END:VEVENT',
          'BEGIN:VEVENT',
          'UID:choir-1@example',
          'SUMMARY:Choir - date id on a timed series',
          'RECURRENCE-ID;VALUE=DATE:20260811',
          'DTSTART;TZID=Australia/Perth:20260811T160000',
          'END:VEVENT',
        ]),
      );

      // Four generated occurrences plus two uninterpretable pass-throughs.
      expect(events.length, 6);
      expect(starts(events), contains('20260818T073000Z'));
      expect(starts(events), contains('20260811T073000Z'));
      final passThrough = events
          .where((e) => e.title.startsWith('Choir - '))
          .toList();
      expect(passThrough.length, 2);
      expect(passThrough.map((e) => e.recurrenceId), everyElement(isNull));
    });
  });

  // ── 32-36. Compatibility and safeguards ─────────────────────────────────────

  group('32-36 compatibility and safeguards', () {
    test('32 legacy LocalCalendarEvent.id shapes are unchanged', () {
      final oneOff = parse(
        ics([
          'BEGIN:VEVENT',
          'UID;VALUE=TEXT:abc123',
          'SUMMARY:Text UID Event',
          'DTSTART;TZID=Australia/Perth:20260818T153000',
          'END:VEVENT',
        ]),
      );
      expect(oneOff.single.id, 'abc123');

      final recurring = parse(ics([...perthMaster]));
      for (final event in recurring) {
        expect(
          event.id,
          'choir-1@example:${event.start.millisecondsSinceEpoch}',
        );
      }

      // A detached replacement keeps the UI id of the occurrence it replaces,
      // so moving an occurrence does not create a stale/new pair.
      final replacedId = recurring
          .firstWhere((e) => e.recurrenceId == '20260818T073000Z')
          .id;
      final withOverride = parse(ics([...perthMaster, ...perthOverride]));
      expect(
        withOverride.firstWhere((e) => e.title == 'Choir - changed').id,
        replacedId,
      );

      // A UID-less event keeps its stable, repeatable fallback id.
      const noUid = [
        'BEGIN:VEVENT',
        'SUMMARY:No UID Event',
        'DTSTART;TZID=Australia/Perth:20260818T153000',
        'END:VEVENT',
      ];
      expect(parse(ics(noUid)).single.id, parse(ics(noUid)).single.id);
      expect(parse(ics(noUid)).single.id, startsWith('test_id:'));
    });

    test('33 persisted LocalCalendarSubscription JSON still loads', () async {
      // An older payload: no `source`, no `enabled`, no `lastFetchedAt`.
      const legacy =
          '[{"id":"sub_legacy","title":"Legacy Calendar",'
          '"url":"https://example.com/legacy.ics",'
          '"createdAt":"2025-01-02T03:04:05.000Z"}]';

      final restored = LocalCalendarSubscription.listFromJsonString(legacy);
      expect(restored.length, 1);
      expect(restored[0].id, 'sub_legacy');
      expect(restored[0].source, '');
      expect(restored[0].enabled, isTrue);
      expect(restored[0].lastFetchedAt, isNull);

      // Round-trips through the current schema without migration.
      final again = LocalCalendarSubscription.listFromJsonString(
        LocalCalendarSubscription.listToJsonString(restored),
      );
      expect(again.length, 1);
      expect(again[0].url, 'https://example.com/legacy.ics');

      SharedPreferences.setMockInitialValues({
        'local_calendar_subscriptions_v1': legacy,
      });
      final loaded = await LocalCalendarSubscriptionRepository().list();
      expect(loaded.length, 1);
      expect(loaded[0].title, 'Legacy Calendar');
    });

    test(
      '34 local subscription add/refresh/remove behaviour is unchanged',
      () async {
        SharedPreferences.setMockInitialValues({});
        final repo = LocalCalendarSubscriptionRepository();

        final added = await repo.add(
          title: 'Morley Eagles',
          url: 'webcal://example.com/morley.ics',
          source: 'example.com',
        );
        expect(added.url, 'https://example.com/morley.ics');
        expect((await repo.list()).length, 1);

        final stamp = DateTime.utc(2026, 8, 18, 4);
        await repo.updateLastFetchedAt(added.id, stamp);
        expect((await repo.list())[0].lastFetchedAt!.toUtc(), stamp);

        await repo.remove(added.id);
        expect(await repo.list(), isEmpty);
      },
    );

    test('35 an unknown TZID still falls back safely', () {
      final oneOff = parse(
        ics([
          'BEGIN:VEVENT',
          'UID:unknown-tz@example',
          'SUMMARY:Unknown Zone Event',
          'DTSTART;TZID=Unknown/Timezone:20260818T153000',
          'END:VEVENT',
        ]),
      );
      expect(oneOff.length, 1);
      expect(oneOff[0].start.isUtc, isFalse);

      // A recurring series with an unknown TZID still expands, on floating
      // (device-local) time, rather than failing the whole feed.
      final recurring = parse(
        ics([
          'BEGIN:VEVENT',
          'UID:unknown-tz-rrule@example',
          'SUMMARY:Unknown Zone Series',
          'DTSTART;TZID=Unknown/Timezone:20260804T153000',
          'RRULE:FREQ=WEEKLY;COUNT=3',
          'END:VEVENT',
        ]),
      );
      expect(recurring.length, 3);
      for (final event in recurring) {
        expect(event.start.hour, 15);
        expect(event.start.minute, 30);
      }

      expect(() => parse('this is not valid ics '), returnsNormally);
    });

    test('36 the 5 MB response safeguard is unchanged', () async {
      final chunk = List<int>.filled(1024 * 1024, 65); // 1 MB of 'A'

      await expectLater(
        service.readBody(
          Stream<List<int>>.fromIterable(List.generate(5, (_) => chunk)),
        ),
        completes,
      );

      await expectLater(
        service.readBody(
          Stream<List<int>>.fromIterable(List.generate(6, (_) => chunk)),
        ),
        throwsA(
          isA<LocalCalendarIcsException>().having(
            (e) => e.message,
            'message',
            contains('too large'),
          ),
        ),
      );
    });
  });

  // ── STATUS scope (documented, deliberately unchanged) ───────────────────────

  group('STATUS:CANCELLED scope is deliberately narrow', () {
    test(
      'a cancelled NON-recurring VEVENT keeps its historical visibility',
      () {
        final events = parse(
          ics([
            'BEGIN:VEVENT',
            'UID:cancelled-one-off@example',
            'SUMMARY:Cancelled one-off',
            'DTSTART;TZID=Australia/Perth:20260818T153000',
            'STATUS:CANCELLED',
            'END:VEVENT',
          ]),
        );

        expect(events.length, 1, reason: 'widening this belongs to #421');
        expect(events[0].recurrenceId, isNull);
      },
    );

    test('a cancelled recurring MASTER still expands', () {
      final events = parse(
        ics([
          'BEGIN:VEVENT',
          'UID:cancelled-master@example',
          'SUMMARY:Cancelled master',
          'DTSTART;TZID=Australia/Perth:20260804T153000',
          'RRULE:FREQ=WEEKLY;COUNT=4',
          'STATUS:CANCELLED',
          'END:VEVENT',
        ]),
      );

      expect(events.length, 4, reason: 'widening this belongs to #421');
    });
  });
}
