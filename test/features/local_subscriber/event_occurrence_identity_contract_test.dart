// Adapter for the cross-repository canonical event occurrence identity
// contract, version 1 — CaleeAdmin/calee-hub-core#421, part 3 of 3.
//
// An Event Link minted by one Calee client is resolved by another, so Hub Core,
// CalEmbed and signed-out CaleeMobile must all name one logical occurrence the
// same way. calee-hub-core#424 authored the contract; calee-hub-calembed#74
// mirrored it and proved CalEmbed conforms; this file mirrors the same fixture
// byte for byte and proves signed-out CaleeMobile conforms.
//
// Two rules govern everything below.
//
//   1. It drives the REAL production code — LocalCalendarIcsService.parseBody()
//      (the real parser, the real recurrence engine, the real reconciler) and
//      the real canonical helpers in local_calendar_occurrence_identity.dart.
//      It never restates an expected string through a private test-only
//      formatter, which would only prove the fixture agrees with itself.
//
//   2. Every comparison keys on the FULL identity triple
//      (calendarRef + sourceUid + recurrenceId). Two source series may
//      legitimately share one recurrenceId — scenario
//      two-recurring-series-distinct-boundary-whitespace-uids is exactly that —
//      so a recurrenceId-only map silently keeps the last of them and then
//      checks one series' expectations against another series' event.
//
// The suite is ambient-timezone independent by construction and is run under
// TZ=Australia/Perth, TZ=UTC and TZ=Pacific/Kiritimati.

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timezone/data/latest.dart' as tz_data;
import 'package:timezone/timezone.dart' as tz;

import 'package:calee_mobile/features/local_subscriber/local_calendar_event.dart';
import 'package:calee_mobile/features/local_subscriber/local_calendar_ics_service.dart';
import 'package:calee_mobile/features/local_subscriber/local_calendar_occurrence_identity.dart';
import 'package:calee_mobile/features/local_subscriber/local_calendar_subscription.dart';

/// The mirrored fixture. Read-only here: CaleeMobile never edits it and never
/// regenerates it from Dart.
const String contractPath =
    'contracts/event-occurrence-identity/v1/contract.json';

/// Pinned digest of the fixture merged in CaleeAdmin/calee-hub-core#424
/// (merge commit dada4334). This is how the mirror proves byte identity
/// locally, without fetching anything at test time.
const String contractSha256 =
    '930d09c6760b88bb335c550afa52d100e19b7c888d72f35743653e2b0e1028f3';

const int contractByteLength = 88754;

/// Printed only after every contract check below has run, so CI can prove the
/// suite actually executed rather than being skipped or renamed away.
const String contractMarker = 'event occurrence identity contract tests passed';

/// Number of contract assertions executed, reported with the marker.
int contractChecks = 0;

void check(String what, Object? actual, Object? matcher) {
  contractChecks++;
  expect(actual, matcher, reason: what);
}

void main() {
  tz_data.initializeTimeZones();

  final fixture = File(contractPath);
  if (!fixture.existsSync()) {
    test('the canonical fixture is present at the contract path', () {
      fail('missing $contractPath — the v1 mirror is required');
    });
    return;
  }

  final contractBytes = fixture.readAsBytesSync();
  final contractText = utf8.decode(contractBytes);
  final contract = jsonDecode(contractText) as Map<String, dynamic>;

  List<Map<String, dynamic>> section(String key) =>
      (contract[key] as List<dynamic>).cast<Map<String, dynamic>>();

  final identityCases = section('identityCases');
  final uidCases = section('uidCases');
  final uidDistinctSets = section('uidDistinctSets');
  final scenarios = section('scenarios');
  final equivalences = section('logicalIdentityEquivalences');
  final distinctions = section('logicalIdentityDistinctions');
  final formats = contract['formats'] as Map<String, dynamic>;
  final sourceStatuses = (contract['sourceStatuses'] as List).cast<String>();
  final identityStatuses = (contract['identityStatuses'] as List)
      .cast<String>();

  const service = LocalCalendarIcsService();

  // ── Adapter plumbing ──────────────────────────────────────────────────────

  /// A CaleeMobile subscription standing in for one fixture calendar. The
  /// fixture's symbolic `cal-a` / `cal-b` are the CALENDAR REFERENCE, which is
  /// part of the identity: byte-identical source data in a different calendar
  /// is a different logical event.
  LocalCalendarSubscription subscriptionFor(String calendarRef) =>
      LocalCalendarSubscription(
        id: calendarRef,
        title: 'Contract calendar $calendarRef',
        url: 'https://contract.example/$calendarRef.ics',
        source: 'contract',
        createdAt: DateTime.utc(2026, 1, 1),
      );

  /// The scenario's ICS lines, VERBATIM, joined with CRLF. Nothing is injected:
  /// `calendarFallbackTimezone` is defined by the fixture as the context
  /// supplied by the CALLER, so it is passed to parseBody() as an argument and
  /// never smuggled into the feed, which would collapse the very separation
  /// between display fallback and declared context that this contract draws.
  String feedFor(Map<String, dynamic> scenario) =>
      '${(scenario['ics'] as List).cast<String>().join('\r\n')}\r\n';

  /// A fixed parser clock placing the scenario's whole window inside
  /// CaleeMobile's own 30-day-past / 365-day-future fetch window. Every fixture
  /// window is at most two months wide, so `from + 20 days` leaves the mobile
  /// window spanning `from - 10 days` .. `from + 385 days`.
  DateTime clockFor(Map<String, dynamic> scenario) {
    final parts = (scenario['window']['from'] as String)
        .split('-')
        .map(int.parse)
        .toList();
    return DateTime.utc(
      parts[0],
      parts[1],
      parts[2],
      12,
    ).add(const Duration(days: 20));
  }

  /// The DISPLAY run: the real production path with every legacy fallback in
  /// play and NO declared context, exactly as a signed-out phone parses a feed
  /// today. It answers `expected.displayFallback`.
  List<LocalCalendarEvent> displayRun(Map<String, dynamic> scenario) =>
      service.parseBody(
        feedFor(scenario),
        subscriptionFor(scenario['calendarRef'] as String),
        now: clockFor(scenario),
      );

  /// The CANONICAL run: the same production path with the fixture's declared
  /// calendar timezone context supplied as a caller argument. It answers
  /// everything about identity.
  List<LocalCalendarEvent> canonicalRun(Map<String, dynamic> scenario) =>
      service.parseBody(
        feedFor(scenario),
        subscriptionFor(scenario['calendarRef'] as String),
        now: clockFor(scenario),
        calendarTzid: scenario['calendarFallbackTimezone'] as String?,
      );

  /// One occurrence's start, mapped from CaleeMobile's own display
  /// representation into the contract key space with the PRODUCTION
  /// formatters — never a private one.
  String startsAtOf(LocalCalendarEvent event) => event.isAllDay
      ? canonicalAllDayIdentity(
          event.start.year,
          event.start.month,
          event.start.day,
        )
      : canonicalTimedIdentity(event.start);

  /// The full identity triple, structurally encoded so no UID content can be
  /// mistaken for a field separator. Must agree byte for byte with
  /// [CanonicalOccurrenceIdentity.key], which production builds the same way.
  String tripleKey(
    String? calendarRef,
    String? sourceUid,
    String? recurrenceId,
  ) => jsonEncode(<String?>[calendarRef, sourceUid, recurrenceId]);

  /// The shareable occurrences of one run, keyed by identity triple.
  ///
  /// An occurrence the canonical layer refuses is still DISPLAYED; it simply
  /// mints no Event Link identity, so it is absent from this map.
  Map<String, Map<String, Object?>> canonicalOccurrences(
    Map<String, dynamic> scenario,
    List<LocalCalendarEvent> events,
  ) {
    final result = <String, Map<String, Object?>>{};
    for (final event in events) {
      final identity = canonicalEventLinkIdentity(
        scenario['calendarRef'] as String?,
        event,
      );
      if (!identity.isOk) continue;
      result[identity.key] = <String, Object?>{
        'startsAt': startsAtOf(event),
        'allDay': event.isAllDay,
        // A component carrying a RECURRENCE-ID, or generated by an RRULE, is an
        // occurrence OF a series; a one-off carries no recurrence key at all.
        'recurring': event.recurrenceId != null,
        'title': event.title,
      };
    }
    return result;
  }

  /// Every identity triple a run emits, as a LIST — keying by triple would let
  /// a double emission overwrite itself and hide the duplicate.
  List<String> emittedTriples(
    Map<String, dynamic> scenario,
    List<LocalCalendarEvent> events,
  ) => <String>[
    for (final event in events)
      if (canonicalEventLinkIdentity(
        scenario['calendarRef'] as String?,
        event,
      ).isOk)
        canonicalEventLinkIdentity(
          scenario['calendarRef'] as String?,
          event,
        ).key,
  ];

  /// The same scenario with its suppressing property removed.
  ///
  /// A suppressed occurrence is UNAVAILABLE, not absent: the resolver must be
  /// able to answer 'cancelled' or 'excluded' for the identity it names rather
  /// than a bare 'not found'. Deleting only the `STATUS:CANCELLED` or `EXDATE`
  /// line and re-running the real parser proves the suppressed identity is
  /// still recoverable from the source bytes, without restating it here.
  Map<String, dynamic> withoutSuppression(
    Map<String, dynamic> scenario,
    String reason,
  ) {
    final lines = (scenario['ics'] as List).cast<String>().where((line) {
      final upper = line.toUpperCase();
      return reason == 'cancelled'
          ? upper.trim() != 'STATUS:CANCELLED'
          : !upper.startsWith('EXDATE');
    }).toList();
    return <String, dynamic>{...scenario, 'ics': lines};
  }

  /// startsAt of every shareable occurrence, sorted — the fingerprint compared
  /// across hostile ambient timezones.
  Map<String, Object?> canonicalFingerprint(Map<String, dynamic> scenario) {
    final rows = canonicalOccurrences(scenario, canonicalRun(scenario));
    final keys = rows.keys.toList()..sort();
    return <String, Object?>{
      for (final key in keys) key: rows[key]!['startsAt'],
    };
  }

  final displayByScenario = <String, List<LocalCalendarEvent>>{};
  final canonicalEventsByScenario = <String, List<LocalCalendarEvent>>{};
  final canonicalByScenario = <String, Map<String, Map<String, Object?>>>{};
  final scenarioById = <String, Map<String, dynamic>>{
    for (final scenario in scenarios) scenario['id'] as String: scenario,
  };

  setUpAll(() {
    for (final scenario in scenarios) {
      final id = scenario['id'] as String;
      displayByScenario[id] = displayRun(scenario);
      final canonicalEvents = canonicalRun(scenario);
      canonicalEventsByScenario[id] = canonicalEvents;
      canonicalByScenario[id] = canonicalOccurrences(scenario, canonicalEvents);
    }
  });

  // ── 1. Fixture integrity and version ──────────────────────────────────────

  group('1 fixture integrity', () {
    test('the mirror is byte-identical to the Hub Core fixture', () {
      check(
        'fixture SHA-256 matches CaleeAdmin/calee-hub-core#424',
        sha256.convert(contractBytes).toString(),
        contractSha256,
      );
      check('fixture byte length', contractBytes.length, contractByteLength);
      check(
        'the fixture is LF-terminated with no CR bytes',
        contractText.contains('\r'),
        isFalse,
      );
      check(
        'the fixture round-trips as UTF-8',
        utf8.encode(contractText),
        contractBytes,
      );
    });

    test('the fixture is the contract this code implements', () {
      check(
        'contract name',
        contract['contract'],
        'calee.event-occurrence-identity',
      );
      check(
        'contract version',
        contract['contractVersion'],
        localCalendarOccurrenceIdentityContractVersion,
      );
      check(
        'identity is exactly calendarRef + sourceUid + recurrenceId',
        contract['identityFields'],
        <String>['calendarRef', 'sourceUid', 'recurrenceId'],
      );
      check(
        'the canonical timed format is the true UTC instant',
        formats['timed']['strftime'],
        'YmdTHisZ',
      );
      check(
        'the canonical all-day format is a literal calendar date',
        formats['allDay']['strftime'],
        'Ymd',
      );
      check(
        'CaleeMobile local identifiers are declared non-normative',
        contract['nonNormativeFields']['mobile'],
        <String>['id'],
      );
      check(
        'production reports only contract sourceStatuses',
        CanonicalSourceStatus.values,
        sourceStatuses,
      );
      check(
        'production reports only contract identityStatuses',
        CanonicalIdentityStatus.values,
        identityStatuses,
      );
      check(
        'the fixture carries every section this adapter drives',
        <bool>[
          contract.containsKey('identityCases'),
          contract.containsKey('uidCases'),
          contract.containsKey('uidDistinctSets'),
          contract.containsKey('scenarios'),
          contract.containsKey('logicalIdentityEquivalences'),
          contract.containsKey('logicalIdentityDistinctions'),
          contract.containsKey('timezoneRule'),
          contract.containsKey('resolutionOrder'),
        ],
        everyElement(isTrue),
      );
    });
  });

  // ── 2. Canonical identity conversion ──────────────────────────────────────

  group('2 canonical identity conversion', () {
    for (final identityCase in identityCases) {
      test('identity case ${identityCase['id']}', () {
        final expected = identityCase['expected'] as Map<String, dynamic>;
        final actual = canonicalOccurrenceIdentity(
          identityCase['value'] as String?,
          allDay: identityCase['kind'] == 'allDay',
          propertyTzid: identityCase['tzid'] as String?,
          calendarTzid: identityCase['calendarFallbackTimezone'] as String?,
        );

        check(
          '${identityCase['id']} status',
          actual.status,
          expected['status'],
        );
        check(
          '${identityCase['id']} canonical identity',
          actual.canonicalIdentity,
          expected['canonicalIdentity'],
        );
        check(
          '${identityCase['id']} reports a contract sourceStatus',
          sourceStatuses,
          contains(actual.status),
        );
      });
    }

    test('the normative timezone rule is enforced, not delegated', () {
      final rule = contract['timezoneRule'] as Map<String, dynamic>;
      check(
        'the fixture still states the normative pattern',
        rule['acceptedPattern'],
        isNotNull,
      );
      check('TZID=UTC is accepted', canonicalTimezone('UTC'), isNotNull);
      check(
        'an IANA Area/Location TZID is accepted',
        canonicalTimezone('Australia/Perth'),
        isNotNull,
      );
      for (final rejected in <String>[
        'W. Australia Standard Time',
        'AWST',
        'EST',
        '+08:00',
        'Mars/Olympus_Mons',
        '',
        '   ',
        '"Australia/Perth"',
      ]) {
        check(
          'TZID $rejected is refused canonically',
          canonicalTimezone(rejected),
          isNull,
        );
      }

      // The rule is NORMATIVE, not delegated to whichever database happens to
      // be linked. Dart's timezone package and PHP's DateTimeZone each resolve
      // spellings the other does not, so the fixture's own pattern is applied
      // here and any name failing it must be refused even when this platform
      // could resolve it. `GMT` is exactly that name on Dart: the database
      // carries it, it has no Area/Location segment, and PHP resolves a
      // different set again — so trusting the platform would mint identities
      // CaleeMobile's siblings could never reproduce.
      final acceptedPattern = RegExp(rule['acceptedPattern'] as String);
      final acceptedLiterals = (rule['acceptedLiterals'] as List)
          .cast<String>();
      check(
        'the fixture still accepts UTC as a literal',
        acceptedLiterals,
        <String>['UTC'],
      );
      for (final name in <String>[
        'GMT',
        'UTC',
        'Australia/Perth',
        'Australia/Sydney',
        'America/New_York',
        'US/Eastern',
        'EST',
        'AWST',
        '+08:00',
        'W. Australia Standard Time',
        'Mars/Olympus_Mons',
      ]) {
        if (acceptedLiterals.contains(name) || acceptedPattern.hasMatch(name)) {
          continue;
        }
        check(
          '$name fails the fixture shape rule and is refused whatever the '
          'platform database says',
          canonicalTimezone(name),
          isNull,
        );
      }
    });

    test('a quoted TZID is unquoted exactly once, by the real parser', () {
      // Production never hands a quoted name to the canonical layer: by then
      // the property parser has stripped the RFC 5545 3.1 quotes once. Stripping
      // twice would accept TZID=""Australia/Perth"", which the display resolver
      // refuses — canonical would then call ok an instant resolved on the
      // device clock.
      String statusFor(String dtstartParams) {
        final events = service.parseBody(
          <String>[
            'BEGIN:VCALENDAR',
            'VERSION:2.0',
            'BEGIN:VEVENT',
            'UID:quoted@contract.example',
            'SUMMARY:Quoted',
            'DTSTART$dtstartParams:20260818T153000',
            'DTEND$dtstartParams:20260818T163000',
            'END:VEVENT',
            'END:VCALENDAR',
          ].join('\r\n'),
          subscriptionFor('cal-a'),
          now: DateTime.utc(2026, 8, 18, 4),
        );
        return events.single.canonicalStatus;
      }

      check(
        'a quoted TZID resolves like the unquoted spelling',
        statusFor(';TZID="Australia/Perth"'),
        CanonicalSourceStatus.ok,
      );
      check(
        'an unquoted TZID resolves',
        statusFor(';TZID=Australia/Perth'),
        CanonicalSourceStatus.ok,
      );
      check(
        'a doubly quoted TZID is NOT unquoted twice',
        statusFor(';TZID=""Australia/Perth""'),
        CanonicalSourceStatus.unsupportedTzid,
      );
    });

    test('required cross-client parity values', () {
      String? identityOf(String value, String? tzid, {bool allDay = false}) =>
          canonicalOccurrenceIdentity(
            value,
            allDay: allDay,
            propertyTzid: tzid,
          ).canonicalIdentity;

      check(
        'Perth 15:30 is 07:30Z',
        identityOf('20260818T153000', 'Australia/Perth'),
        '20260818T073000Z',
      );
      check(
        'Sydney AEST 10:00 on 29 Sep 2026',
        identityOf('20260929T100000', 'Australia/Sydney'),
        '20260929T000000Z',
      );
      check(
        'Sydney AEDT 10:00 on 6 Oct 2026',
        identityOf('20261006T100000', 'Australia/Sydney'),
        '20261005T230000Z',
      );
      check(
        'Sydney AEDT 10:00 on 13 Oct 2026',
        identityOf('20261013T100000', 'Australia/Sydney'),
        '20261012T230000Z',
      );
      check(
        'the literal wall time 20261006T000000Z is never minted',
        <String?>[
          identityOf('20260929T100000', 'Australia/Sydney'),
          identityOf('20261006T100000', 'Australia/Sydney'),
          identityOf('20261013T100000', 'Australia/Sydney'),
        ],
        isNot(contains('20261006T000000Z')),
      );
      check(
        'an all-day date stays a literal calendar date',
        identityOf('20260818', 'Australia/Sydney', allDay: true),
        '20260818',
      );
    });
  });

  // ── 3. UID opacity, through the real parser ───────────────────────────────

  group('3 UID contract', () {
    /// The source UID the REAL parser keeps for a component carrying this UID
    /// property — the grouping step is where a folded UID actually does damage,
    /// so the reader is never tested in isolation.
    String? parsedUidFor(Map<String, dynamic> uidCase) {
      final present = uidCase['uidPropertyPresent'] as bool;
      final value = uidCase['uidPropertyValue'] as String?;
      final events = service.parseBody(
        <String>[
          'BEGIN:VCALENDAR',
          'VERSION:2.0',
          'BEGIN:VEVENT',
          if (present) 'UID:$value',
          'SUMMARY:Uid case',
          'DTSTART;TZID=Australia/Perth:20260818T153000',
          'DTEND;TZID=Australia/Perth:20260818T163000',
          'END:VEVENT',
          'END:VCALENDAR',
        ].join('\r\n'),
        subscriptionFor('cal-a'),
        now: DateTime.utc(2026, 8, 18, 4),
      );
      return events.single.uid;
    }

    for (final uidCase in uidCases) {
      test('uid case ${uidCase['id']}', () {
        final expected = uidCase['expected'] as Map<String, dynamic>;
        check(
          '${uidCase['id']} through canonicalSourceUid',
          canonicalSourceUid(
            (uidCase['uidPropertyPresent'] as bool)
                ? uidCase['uidPropertyValue'] as String?
                : null,
          ),
          expected['sourceUid'],
        );
        check(
          '${uidCase['id']} through the real parser',
          parsedUidFor(uidCase),
          expected['sourceUid'],
        );
      });
    }

    for (final set in uidDistinctSets) {
      test('uid distinct set ${set['id']}', () {
        final uids = <String?>[
          for (final caseId in (set['caseIds'] as List).cast<String>())
            parsedUidFor(uidCases.firstWhere((c) => c['id'] == caseId)),
        ];
        check(
          '${set['id']} names real fixture cases',
          uids.length,
          (set['caseIds'] as List).length,
        );
        check(
          '${set['id']} stays pairwise distinct',
          uids.toSet().length,
          uids.length,
        );
      });
    }

    test('a UID-less component is not shareable and groups with itself', () {
      const uidless = <String>[
        'BEGIN:VEVENT',
        'SUMMARY:No uid',
        'DTSTART;TZID=Australia/Perth:20260818T153000',
        'DTEND;TZID=Australia/Perth:20260818T163000',
        'END:VEVENT',
      ];
      final events = service.parseBody(
        <String>[
          'BEGIN:VCALENDAR',
          'VERSION:2.0',
          ...uidless,
          ...uidless,
          'END:VCALENDAR',
        ].join('\r\n'),
        subscriptionFor('cal-a'),
        now: DateTime.utc(2026, 8, 18, 4),
      );

      check('both UID-less components survive', events.length, 2);
      for (final event in events) {
        check('no manufactured source UID', event.uid, isNull);
        check(
          'no canonical identity is minted',
          canonicalEventLinkIdentity('cal-a', event).status,
          CanonicalIdentityStatus.noSourceUid,
        );
      }
    });
  });

  // ── 4. Whole ICS scenarios ────────────────────────────────────────────────

  group('4 whole ICS scenarios', () {
    for (final scenario in scenarios) {
      final id = scenario['id'] as String;
      final expected = scenario['expected'] as Map<String, dynamic>;
      final calendarRef = scenario['calendarRef'] as String;
      final expectedOccurrences = (expected['occurrences'] as List)
          .cast<Map<String, dynamic>>();

      test('scenario $id', () {
        final canonical = canonicalByScenario[id]!;
        final canonicalEvents = canonicalEventsByScenario[id]!;
        final display = displayByScenario[id]!;

        // 4a. Every expected occurrence, under its FULL triple.
        for (final occurrence in expectedOccurrences) {
          final key = tripleKey(
            calendarRef,
            occurrence['sourceUid'] as String?,
            occurrence['recurrenceId'] as String?,
          );
          final found = canonical[key];
          check('$id mints $key', found, isNotNull);
          if (found == null) continue;

          check('$id $key startsAt', found['startsAt'], occurrence['startsAt']);
          check(
            '$id $key all-day shape',
            found['allDay'],
            occurrence['allDay'],
          );
          check(
            '$id $key recurring shape',
            found['recurring'],
            occurrence['recurring'],
          );
          check('$id $key source title', found['title'], occurrence['title']);
        }

        // 4b. expected.occurrences is the complete SHAREABLE set for the
        //     window, so the upper bound applies whether or not the fixture
        //     also accounts for every DISPLAYED component. Without it a
        //     component the contract calls unidentifiable could mint an extra
        //     link and nothing here would notice.
        final wanted = <String>{
          for (final occurrence in expectedOccurrences)
            tripleKey(
              calendarRef,
              occurrence['sourceUid'] as String?,
              occurrence['recurrenceId'] as String?,
            ),
        };
        check(
          '$id mints no identity beyond the expected set',
          canonical.keys.where((key) => !wanted.contains(key)),
          isEmpty,
        );
        check(
          '$id mints exactly ${expectedOccurrences.length} identities',
          canonical.length,
          expectedOccurrences.length,
        );

        final emitted = emittedTriples(scenario, canonicalEvents);
        check(
          '$id emits no identity triple twice',
          emitted.toSet().length,
          emitted.length,
        );

        // 4c. A canonical status other than ok means the source cannot be
        //     shared at all — and the fixture states what still DISPLAYS.
        final statuses = <String>{
          for (final event in canonicalEvents) event.canonicalStatus,
        };
        for (final status in statuses) {
          check(
            '$id status $status is a contract sourceStatus',
            sourceStatuses,
            contains(status),
          );
        }
        if (expected['canonicalStatus'] != CanonicalSourceStatus.ok) {
          check(
            '$id every component reports ${expected['canonicalStatus']}',
            statuses,
            <String>{expected['canonicalStatus'] as String},
          );
          check('$id mints no canonical identity at all', canonical, isEmpty);
        } else {
          // ...and an 'ok' scenario must contain a component that really is,
          // rather than passing because nothing was checked.
          check(
            '$id at least one component reports ok',
            statuses,
            contains(CanonicalSourceStatus.ok),
          );
        }

        // Every minted identity matches the fixture's own format patterns.
        for (final entry in canonical.entries) {
          final triple = (jsonDecode(entry.key) as List).cast<String?>();
          final row = entry.value;
          final format =
              (row['allDay'] as bool ? formats['allDay'] : formats['timed'])
                  as Map<String, dynamic>;
          check(
            '$id ${row['startsAt']} matches the contract format',
            row['startsAt'],
            allOf(
              matches(RegExp(format['pattern'] as String)),
              hasLength(format['length'] as int),
            ),
          );
          if (triple[2] != null) {
            check(
              '$id recurrence identity ${triple[2]} matches a contract format',
              triple[2],
              anyOf(
                matches(RegExp(formats['allDay']['pattern'] as String)),
                matches(RegExp(formats['timed']['pattern'] as String)),
              ),
            );
          }
        }

        // The legacy display fallback is unchanged: failing closed on identity
        // must never blank the calendar.
        final displayFallback =
            expected['displayFallback'] as Map<String, dynamic>?;
        if (displayFallback != null) {
          check(
            '$id still displays under the legacy fallback',
            display.length,
            displayFallback['occurrenceCount'],
          );
        }

        // 4d. A component whose RECURRENCE-ID cannot be interpreted claims
        //     nothing — through the helper AND through the real pipeline, where
        //     it is still displayed and simply mints no link.
        final unidentifiable =
            (expected['unidentifiableComponents'] as List?)
                ?.cast<Map<String, dynamic>>() ??
            const <Map<String, dynamic>>[];
        for (final component in unidentifiable) {
          check(
            '$id RECURRENCE-ID ${component['recurrenceIdValue']} is '
            '${component['expectedStatus']}',
            canonicalOccurrenceIdentity(
              component['recurrenceIdValue'] as String?,
              allDay: component['kind'] == 'allDay',
              propertyTzid: component['recurrenceIdTzid'] as String?,
              calendarTzid: scenario['calendarFallbackTimezone'] as String?,
            ).status,
            component['expectedStatus'],
          );
        }
        if (unidentifiable.isNotEmpty) {
          final refused = canonicalEvents
              .where(
                (event) => event.canonicalStatus != CanonicalSourceStatus.ok,
              )
              .toList();
          check(
            '$id the unidentifiable components are present in the expansion',
            refused.length,
            unidentifiable.length,
          );
          for (final event in refused) {
            check(
              '$id the unidentifiable component mints no link',
              canonicalEventLinkIdentity(calendarRef, event).status,
              CanonicalIdentityStatus.noCanonicalRecurrenceIdentity,
            );
            check(
              '$id the unidentifiable component has no canonical recurrence id',
              event.canonicalRecurrenceId,
              isNull,
            );
          }
          check(
            '$id the unidentifiable component is still displayed',
            display.length,
            expectedOccurrences.length + unidentifiable.length,
          );
        }
      });
    }

    test('no calendar reference means no Event Link identity', () {
      final event = canonicalEventsByScenario['perth-weekly-series']!.first;
      check(
        'a null calendar reference is refused',
        canonicalEventLinkIdentity(null, event).status,
        CanonicalIdentityStatus.noCalendarReference,
      );
      check(
        'a blank calendar reference is refused',
        canonicalEventLinkIdentity('   ', event).status,
        CanonicalIdentityStatus.noCalendarReference,
      );
    });

    test('a source naming its own zone ignores the caller context', () {
      final scenario = scenarioById['perth-weekly-series']!;
      final withHostileContext = <String, dynamic>{
        ...scenario,
        'calendarFallbackTimezone': 'Pacific/Kiritimati',
      };
      check(
        'a TZID-qualified series is unaffected by a foreign calendar context',
        canonicalFingerprint(withHostileContext),
        canonicalFingerprint(scenario),
      );
    });

    test('a floating source is refused under every wrong context', () {
      final scenario = scenarioById['floating-series-without-timezone']!;
      for (final context in <String?>[
        null,
        'Australia/Sydney',
        'W. Australia Standard Time',
      ]) {
        final events = service.parseBody(
          feedFor(scenario),
          subscriptionFor('cal-a'),
          now: clockFor(scenario),
          calendarTzid: context,
        );
        final statuses = <String>{
          for (final event in events) event.canonicalStatus,
        };
        check(
          'floating series still displays under context $context',
          events.length,
          4,
        );
        if (context == 'Australia/Sydney') {
          // A DIFFERENT declared context is a different, legitimate answer —
          // but never this fixture's, and never the device's.
          check(
            'a foreign declared context does not mint the fixture identity',
            events.map((e) => e.canonicalRecurrenceId),
            isNot(contains('20260804T073000Z')),
          );
        } else {
          check(
            'no context and an unresolvable context both mint nothing',
            events.map((e) => e.canonicalRecurrenceId),
            everyElement(isNull),
          );
          check('the refusal is named', statuses, <String>{
            context == null
                ? CanonicalSourceStatus.floatingWithoutContext
                : CanonicalSourceStatus.unsupportedTzid,
          });
        }
      }
    });
  });

  // ── 5. Suppression ────────────────────────────────────────────────────────

  group('5 suppression', () {
    for (final scenario in scenarios) {
      final id = scenario['id'] as String;
      final expected = scenario['expected'] as Map<String, dynamic>;
      final calendarRef = scenario['calendarRef'] as String;
      final suppressed = (expected['suppressed'] as List)
          .cast<Map<String, dynamic>>();
      final forbiddenRecurrenceIds =
          (expected['forbiddenRecurrenceIds'] as List).cast<String>();
      final forbiddenCanonical =
          (expected['forbiddenCanonicalIdentities'] as List?)?.cast<String>() ??
          const <String>[];

      if (suppressed.isEmpty &&
          forbiddenRecurrenceIds.isEmpty &&
          forbiddenCanonical.isEmpty) {
        continue;
      }

      test('scenario $id suppression', () {
        final canonical = canonicalByScenario[id]!;
        final canonicalEvents = canonicalEventsByScenario[id]!;

        for (final entry in suppressed) {
          final key = tripleKey(
            calendarRef,
            entry['sourceUid'] as String?,
            entry['recurrenceId'] as String?,
          );
          check(
            '$id ${entry['reason']} occurrence $key is not visible',
            canonical.containsKey(key),
            isFalse,
          );

          // Suppressed, not merely renamed: no visible occurrence of that
          // source UID sits at that identity under any title.
          check(
            '$id no stale twin survives at $key',
            canonicalEvents.where(
              (event) =>
                  event.uid == entry['sourceUid'] &&
                  event.recurrenceId == entry['recurrenceId'],
            ),
            isEmpty,
          );

          // ...and the identity stays recoverable from the source: lift the
          // suppressing property and exactly that identity comes back.
          check(
            '$id $key is unavailable, not absent',
            canonicalOccurrences(
              withoutSuppression(scenario, entry['reason'] as String),
              canonicalRun(
                withoutSuppression(scenario, entry['reason'] as String),
              ),
            ).keys,
            contains(key),
          );
        }

        // A recurrence identity the fixture forbids is the identity a
        // mis-parse would invent. It must appear nowhere, display key included.
        for (final forbidden in forbiddenRecurrenceIds) {
          check(
            '$id never generates recurrence identity $forbidden',
            canonicalEvents.map((event) => event.recurrenceId),
            isNot(contains(forbidden)),
          );
        }

        // A forbidden CANONICAL identity is the weaker, different claim: a
        // display key produced by a legacy fallback may exist, it just must
        // never be minted into a shareable identity.
        for (final forbidden in forbiddenCanonical) {
          check(
            '$id never mints canonical identity $forbidden',
            <String?>[
              for (final key in canonical.keys)
                (jsonDecode(key) as List).cast<String?>()[2],
            ],
            isNot(contains(forbidden)),
          );
        }
      });
    }
  });

  // ── 6. Logical identity equivalence ───────────────────────────────────────

  group('6 logical identity equivalence', () {
    for (final group in equivalences) {
      test('equivalence ${group['id']}', () {
        final members = (group['members'] as List).cast<Map<String, dynamic>>();
        final keys = <String>[];
        for (final member in members) {
          final scenario = scenarioById[member['scenario']];
          check('${group['id']} names a real scenario', scenario, isNotNull);
          if (scenario == null) continue;

          final key = tripleKey(
            scenario['calendarRef'] as String?,
            member['sourceUid'] as String?,
            member['recurrenceId'] as String?,
          );
          keys.add(key);

          // 'unavailable' members are the cancelled/excluded side of the group:
          // they keep the SAME identity while not being visible.
          final visible = canonicalByScenario[member['scenario']]!.containsKey(
            key,
          );
          final expectVisible =
              (member['availability'] as String? ?? 'available') == 'available';
          check(
            '${group['id']} ${member['scenario']} '
            '${expectVisible ? 'offers' : 'withholds'} $key',
            visible,
            expectVisible,
          );
        }

        check(
          '${group['id']} is one identity across ${members.length} scenarios',
          keys.toSet().length,
          1,
        );
        check(
          '${group['id']} covers every member',
          keys.length,
          members.length,
        );
      });
    }
  });

  // ── 7. Logical identity distinction ───────────────────────────────────────

  group('7 logical identity distinction', () {
    for (final group in distinctions) {
      test('distinction ${group['id']}', () {
        final members = (group['members'] as List).cast<Map<String, dynamic>>();
        final keys = <String>[];
        for (final member in members) {
          final scenario = scenarioById[member['scenario']];
          check('${group['id']} names a real scenario', scenario, isNotNull);
          if (scenario == null) continue;
          keys.add(
            tripleKey(
              scenario['calendarRef'] as String?,
              member['sourceUid'] as String?,
              member['recurrenceId'] as String?,
            ),
          );
        }

        check(
          '${group['id']} stays ${members.length} separate identities',
          keys.toSet().length,
          members.length,
        );

        // ...and each really is minted, so "distinct" is not satisfied by an
        // identity simply going missing.
        for (var i = 0; i < members.length; i++) {
          check(
            '${group['id']} ${members[i]['scenario']} mints its identity',
            canonicalByScenario[members[i]['scenario']]!.keys,
            contains(keys[i]),
          );
        }
      });
    }
  });

  // ── 8. Reconciliation collisions ──────────────────────────────────────────

  group('8 reconciliation collisions', () {
    // These caught real defects in Hub Core and CalEmbed, so they are asserted
    // directly against the real reconciler rather than only through the generic
    // scenario loop above.
    const collisions = <String, int>{
      'two-recurring-series-distinct-boundary-whitespace-uids': 8,
      'uid-collision-classes-through-reconciliation': 8,
      'falsy-uid-zero-detached-move': 4,
      'falsy-uid-zero-detached-cancelled': 3,
    };

    collisions.forEach((scenarioId, expectedCount) {
      test('collision $scenarioId', () {
        final scenario = scenarioById[scenarioId];
        check('$scenarioId is present in the fixture', scenario, isNotNull);
        if (scenario == null) return;

        final canonical = canonicalByScenario[scenarioId]!;
        final canonicalEvents = canonicalEventsByScenario[scenarioId]!;
        final expectedOccurrences =
            ((scenario['expected'] as Map<String, dynamic>)['occurrences']
                    as List)
                .cast<Map<String, dynamic>>();

        check(
          '$scenarioId the fixture still expects $expectedCount occurrences',
          expectedOccurrences.length,
          expectedCount,
        );
        check(
          '$scenarioId the real reconciler produces $expectedCount events',
          canonicalEvents.length,
          expectedCount,
        );
        check(
          '$scenarioId mints $expectedCount shareable identities',
          canonical.length,
          expectedCount,
        );

        // Counted as a LIST as well: keying on the triple would hide a
        // duplicate emission by overwriting it.
        final emitted = emittedTriples(scenario, canonicalEvents);
        check(
          '$scenarioId emits $expectedCount distinct triples',
          emitted.toSet().length,
          expectedCount,
        );
        check(
          '$scenarioId emits no triple twice',
          emitted.length,
          emitted.toSet().length,
        );

        // Per source UID, so a merged pair cannot pass by totalling correctly.
        final perUid = <String?, int>{};
        for (final event in canonicalEvents) {
          perUid[event.uid] = (perUid[event.uid] ?? 0) + 1;
        }
        final expectedPerUid = <String?, int>{};
        for (final occurrence in expectedOccurrences) {
          final uid = occurrence['sourceUid'] as String?;
          expectedPerUid[uid] = (expectedPerUid[uid] ?? 0) + 1;
        }
        check(
          '$scenarioId keeps each source UID apart',
          perUid,
          expectedPerUid,
        );
      });
    });
  });

  // ── 9. Ambient timezone independence ──────────────────────────────────────

  group('9 ambient timezone independence', () {
    // Two halves, and they prove different things.
    //
    // This test varies `tz.local`, which is the timezone package's own idea of
    // the device zone. Nothing in the canonical layer reads it today, and that
    // is precisely what is pinned: reaching for it is the obvious way to
    // "helpfully" resolve a floating value later.
    //
    // The PROCESS timezone — what `DateTime(...)` in the display parser reads —
    // cannot be changed from inside a running VM, so it is varied by the CI
    // matrix instead, which runs this whole file under several ambient zones
    // (positive and negative UTC offsets) and greps the zone back out of the
    // marker. Every expectation in this file is ambient-invariant, so a
    // canonical identity that leaked the device clock fails there.
    test('canonical identities never depend on the reader', () {
      final baseline = <String, Map<String, Object?>>{
        for (final scenario in scenarios)
          scenario['id'] as String: canonicalFingerprint(scenario),
      };

      final previousLocal = tz.local;
      try {
        for (final zone in <String>[
          'Pacific/Kiritimati',
          'UTC',
          'Australia/Perth',
          'America/New_York',
        ]) {
          tz.setLocalLocation(tz.getLocation(zone));

          for (final scenario in scenarios) {
            check(
              '${scenario['id']} is byte-identical with tz.local = $zone',
              canonicalFingerprint(scenario),
              baseline[scenario['id']],
            );
          }

          // A floating source with no declared context stays unmintable
          // whatever the ambient zone is.
          check(
            'a floating value is not rescued by tz.local = $zone',
            canonicalOccurrenceIdentity(
              '20260818T153000',
              allDay: false,
            ).status,
            CanonicalSourceStatus.floatingWithoutContext,
          );
          check(
            'a floating value mints nothing with tz.local = $zone',
            canonicalOccurrenceIdentity(
              '20260818T153000',
              allDay: false,
            ).canonicalIdentity,
            isNull,
          );
        }
      } finally {
        tz.setLocalLocation(previousLocal);
      }
    });
  });

  // ── 10. Rules the contract states in prose that v1's fixture never runs ────

  group('10 beyond the fixture', () {
    // Every case here is a rule the contract README states normatively but no
    // fixture scenario exercises, so each one is a mutation that would
    // otherwise survive. Expected values are taken from the contract text and
    // cross-checked against the Hub Core and CalEmbed implementations.

    List<LocalCalendarEvent> parse(
      List<String> body, {
      String? calendarTzid,
      DateTime? now,
    }) => service.parseBody(
      <String>[
        'BEGIN:VCALENDAR',
        'VERSION:2.0',
        ...body,
        'END:VCALENDAR',
      ].join('\r\n'),
      subscriptionFor('cal-a'),
      // The fetch window is 30 days back / 365 forward, so a fixture placed in
      // early 2026 has to move the clock with it.
      now: now ?? DateTime.utc(2026, 8, 18, 4),
      calendarTzid: calendarTzid,
    );

    List<String?> mintedFor(List<LocalCalendarEvent> events) => <String?>[
      for (final event in events)
        if (canonicalEventLinkIdentity('cal-a', event).isOk)
          canonicalEventLinkIdentity('cal-a', event).recurrenceId,
    ];

    test('a UTC-anchored series names its occurrences in UTC', () {
      // The commonest DATE-TIME form in the wild, and absent from the fixture.
      final events = parse(<String>[
        'BEGIN:VEVENT',
        'UID:standup@contract.example',
        'SUMMARY:Standup',
        'DTSTART:20260818T073000Z',
        'DTEND:20260818T080000Z',
        'RRULE:FREQ=DAILY;COUNT=3',
        'END:VEVENT',
      ]);

      check('three occurrences', events.length, 3);
      check(
        'every occurrence is shareable',
        <String>{for (final event in events) event.canonicalStatus},
        <String>{CanonicalSourceStatus.ok},
      );
      check('minted in UTC', mintedFor(events), <String>[
        '20260818T073000Z',
        '20260819T073000Z',
        '20260820T073000Z',
      ]);
    });

    test('an unzoned RECURRENCE-ID does not inherit a UTC anchor', () {
      // Contract ladder step 3 is the DTSTART TZID PARAMETER. Hub Core and
      // CalEmbed pass nothing for a Z-suffixed DTSTART, so an unzoned
      // RECURRENCE-ID beneath one falls to the calendar context and then
      // refuses. Synthesising 'UTC' here would mint an identity the other two
      // clients answer differently — the exact split this contract prevents.
      const feed = <String>[
        'BEGIN:VEVENT',
        'UID:utc-anchor@contract.example',
        'SUMMARY:Anchored',
        'DTSTART:20260818T073000Z',
        'RRULE:FREQ=DAILY;COUNT=2',
        'END:VEVENT',
        'BEGIN:VEVENT',
        'UID:utc-anchor@contract.example',
        'SUMMARY:Anchored - moved',
        'RECURRENCE-ID:20260819T073000',
        'DTSTART:20260819T090000Z',
        'END:VEVENT',
      ];

      final override = parse(
        feed,
      ).firstWhere((e) => e.title == 'Anchored - moved');
      check(
        'no context: the override names nothing',
        override.canonicalRecurrenceId,
        isNull,
      );
      check(
        'no context: and mints nothing',
        canonicalEventLinkIdentity('cal-a', override).status,
        CanonicalIdentityStatus.noCanonicalRecurrenceIdentity,
      );

      final withContext = parse(
        feed,
        calendarTzid: 'Australia/Perth',
      ).firstWhere((e) => e.title == 'Anchored - moved');
      check(
        'with a declared context the override is read on it, as Hub Core reads it',
        withContext.canonicalRecurrenceId,
        '20260818T233000Z',
      );
    });

    test('a malformed DTSTART cannot be rescued by a valid stepped date', () {
      // Dart renames 30 February to 2 March. The rule then steps from a real
      // date, so every generated occurrence resolves perfectly well — and each
      // one would be an identity built on a value the contract refuses.
      final events = parse(<String>[
        'BEGIN:VEVENT',
        'UID:rolled@contract.example',
        'SUMMARY:Rolled',
        'DTSTART;TZID=Australia/Perth:20260230T153000',
        'RRULE:FREQ=WEEKLY;COUNT=3',
        'END:VEVENT',
      ], now: DateTime.utc(2026, 3, 10, 4));

      check('the occurrences still display', events, isNotEmpty);
      check(
        'every one is refused',
        <String>{for (final event in events) event.canonicalStatus},
        <String>{CanonicalSourceStatus.malformedValue},
      );
      check('and none is minted', mintedFor(events), isEmpty);
      check('no rolled-over identity survives', <String?>[
        for (final event in events) event.canonicalRecurrenceId,
      ], everyElement(isNull));
    });

    test('a malformed RECURRENCE-ID never claims a real occurrence', () {
      // 20260230 is 2 March to Dart. Reconciling on that would CANCEL the
      // genuine 2 March occurrence — contract §6.2: a malformed value must
      // never name another valid occurrence.
      final events = parse(<String>[
        'BEGIN:VEVENT',
        'UID:allday-2@contract.example',
        'SUMMARY:All day',
        'DTSTART;VALUE=DATE:20260226',
        'DTEND;VALUE=DATE:20260227',
        'RRULE:FREQ=DAILY;COUNT=8',
        'END:VEVENT',
        'BEGIN:VEVENT',
        'UID:allday-2@contract.example',
        'SUMMARY:All day - impossible cancel',
        'RECURRENCE-ID;VALUE=DATE:20260230',
        'DTSTART;VALUE=DATE:20260230',
        'STATUS:CANCELLED',
        'END:VEVENT',
      ], now: DateTime.utc(2026, 3, 1, 4));

      check('all eight real occurrences survive', mintedFor(events), <String>[
        '20260226',
        '20260227',
        '20260228',
        '20260301',
        '20260302',
        '20260303',
        '20260304',
        '20260305',
      ]);
    });

    test('a malformed EXDATE excludes nothing', () {
      final events = parse(<String>[
        'BEGIN:VEVENT',
        'UID:exdate-bad@contract.example',
        'SUMMARY:Choir',
        'DTSTART;TZID=Australia/Perth:20260817T013000',
        'RRULE:FREQ=DAILY;COUNT=4',
        'EXDATE;TZID=Australia/Perth:20260818T253000',
        'END:VEVENT',
      ]);

      check('all four occurrences survive', mintedFor(events), <String>[
        '20260816T173000Z',
        '20260817T173000Z',
        '20260818T173000Z',
        '20260819T173000Z',
      ]);
    });

    test('a one-off is named without its DTSTART being placed', () {
      // Contract §1: a non-recurring identity is calendarRef + sourceUid, and
      // a DTSTART change must not alter it. Hub Core and CalEmbed both mint
      // here; refusing would make a link shared from the web unresolvable on a
      // signed-out phone.
      for (final dtStart in <String>[
        'DTSTART:20260812T090000',
        'DTSTART;TZID=W. Australia Standard Time:20260812T090000',
      ]) {
        final event = parse(<String>[
          'BEGIN:VEVENT',
          'UID:one-off@contract.example',
          'SUMMARY:One off',
          dtStart,
          'END:VEVENT',
        ]).single;

        final identity = canonicalEventLinkIdentity('cal-a', event);
        check('$dtStart still mints', identity.status, 'ok');
        check(
          '$dtStart carries no recurrence id',
          identity.recurrenceId,
          isNull,
        );
        check(
          '$dtStart keeps the source uid',
          identity.sourceUid,
          'one-off@contract.example',
        );
        check(
          '$dtStart still reports why it could not be placed',
          event.canonicalStatus,
          isNot(CanonicalSourceStatus.ok),
        );
      }
    });

    test('an override moved onto an unplaceable zone keeps its name', () {
      // RECURRENCE-ID names the occurrence; the moved DTSTART only says where
      // it now happens. Losing the identity here would silently drop one
      // occurrence out of the shareable set, because the override has already
      // replaced the generated twin.
      final events = parse(<String>[
        'BEGIN:VEVENT',
        'UID:choir-1@contract.example',
        'SUMMARY:Choir',
        'DTSTART;TZID=Australia/Perth:20260804T153000',
        'RRULE:FREQ=WEEKLY;COUNT=4',
        'END:VEVENT',
        'BEGIN:VEVENT',
        'UID:choir-1@contract.example',
        'SUMMARY:Choir - moved somewhere unplaceable',
        'RECURRENCE-ID;TZID=Australia/Perth:20260818T153000',
        'DTSTART;TZID=W. Australia Standard Time:20260818T160000',
        'END:VEVENT',
      ]);

      check(
        'the series keeps four shareable occurrences',
        mintedFor(events),
        <String>[
          '20260804T073000Z',
          '20260811T073000Z',
          '20260818T073000Z',
          '20260825T073000Z',
        ],
      );
      check(
        'and the override still reports its unplaceable DTSTART',
        events
            .firstWhere((e) => e.title == 'Choir - moved somewhere unplaceable')
            .canonicalStatus,
        CanonicalSourceStatus.unsupportedTzid,
      );
    });

    test('an unkeyable cancellation stays hidden', () {
      // A STATUS:CANCELLED component that names no occurrence cancels nothing —
      // and must not be rendered as a real event beside the series, which is
      // the duplicate this parser was rewritten to remove.
      final events = parse(<String>[
        'BEGIN:VEVENT',
        'UID:choir-2@contract.example',
        'SUMMARY:Choir',
        'DTSTART;TZID=Australia/Perth:20260818T153000',
        'RRULE:FREQ=DAILY;COUNT=3',
        'END:VEVENT',
        'BEGIN:VEVENT',
        'UID:choir-2@contract.example',
        'SUMMARY:Choir - unkeyable cancellation',
        'RECURRENCE-ID;VALUE=DATE:20260819',
        'DTSTART;TZID=Australia/Perth:20260819T153000',
        'STATUS:CANCELLED',
        'END:VEVENT',
      ]);

      check('the cancellation is not displayed', events.length, 3);
      check('and it cancelled nothing', mintedFor(events), <String>[
        '20260818T073000Z',
        '20260819T073000Z',
        '20260820T073000Z',
      ]);
    });

    test('a missing UID is reported before an unresolvable value', () {
      final event = parse(<String>[
        'BEGIN:VEVENT',
        'SUMMARY:No uid, no zone',
        'DTSTART:20260818T153000',
        'END:VEVENT',
      ]).single;

      check(
        'the missing UID is the reason, as in Hub Core and CalEmbed',
        event.canonicalStatus,
        CanonicalSourceStatus.noSourceUid,
      );
      check(
        'and no link is minted',
        canonicalEventLinkIdentity('cal-a', event).status,
        CanonicalIdentityStatus.noSourceUid,
      );
    });

    test('a UID-less component carries no half-identity', () {
      // A recurrence identity with no source UID to pair it with is not an
      // identity: it is two thirds of a triple that a future mint path could
      // read straight off the DTO. Contract §3 also forbids substituting a
      // manufactured stand-in for the missing UID.
      final series = parse(<String>[
        'BEGIN:VEVENT',
        'SUMMARY:No uid series',
        'DTSTART;TZID=Australia/Perth:20260804T153000',
        'RRULE:FREQ=WEEKLY;COUNT=4',
        'END:VEVENT',
      ]);

      check('the series still displays', series.length, 4);
      check('no manufactured source uid', <String?>[
        for (final event in series) event.uid,
      ], everyElement(isNull));
      check('and no recurrence identity either', <String?>[
        for (final event in series) event.canonicalRecurrenceId,
      ], everyElement(isNull));

      final orphan = parse(<String>[
        'BEGIN:VEVENT',
        'SUMMARY:No uid override',
        'RECURRENCE-ID;TZID=Australia/Perth:20260818T153000',
        'DTSTART;TZID=Australia/Perth:20260818T160000',
        'END:VEVENT',
      ]).single;

      check('the override still displays', orphan.title, 'No uid override');
      check(
        'a UID-less override names nothing either',
        orphan.canonicalRecurrenceId,
        isNull,
      );
      check(
        'and mints nothing',
        canonicalEventLinkIdentity('cal-a', orphan).status,
        CanonicalIdentityStatus.noSourceUid,
      );
    });

    test('the canonical trim is ASCII, like PHP trim()', () {
      // Dart's String.trim() also strips U+00A0. Hub Core does not, so a value
      // carrying one is malformed_value there; minting it here would be one
      // source occurrence with two answers.
      check(
        'a trailing non-breaking space is not trimmed away',
        canonicalOccurrenceIdentity('20260818T073000Z ', allDay: false).status,
        CanonicalSourceStatus.malformedValue,
      );
      check(
        'ASCII whitespace still is',
        canonicalOccurrenceIdentity(
          ' \t20260818T073000Z\r\n',
          allDay: false,
        ).canonicalIdentity,
        '20260818T073000Z',
      );
    });
  });

  // ── 11. Execution marker ──────────────────────────────────────────────────

  group('11 marker', () {
    test('the contract suite ran to completion', () {
      check(
        'every fixture section was driven',
        contractChecks,
        greaterThan(500),
      );
      // ignore: avoid_print
      print(
        '$contractMarker: $contractChecks checks, contract v'
        '${contract['contractVersion']}, ambient TZ='
        '${Platform.environment['TZ'] ?? '(unset)'} '
        '(${DateTime.now().timeZoneName}), '
        'fixture ${contractBytes.length} bytes '
        '${sha256.convert(contractBytes)}',
      );
    });
  });
}
