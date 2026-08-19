/// The canonical, cross-client identity of one source event occurrence.
///
/// This library is the STRICT layer that sits beside the permissive display
/// parser in `local_calendar_ics_service.dart`. The two answer different
/// questions and are deliberately allowed to disagree:
///
///  * **Display** MAY guess. If a feed names a timezone no database resolves,
///    showing the event at its wall-clock time on this phone is a local,
///    reversible convenience — worst case one wrong hour on one screen until
///    the source is fixed. Signed-out local subscriptions have relied on that
///    fallback since they shipped and it is not changed here.
///  * **Canonical share identity** MUST NOT guess. A link minted from a guess
///    is neither local nor reversible: two clients guessing differently mint
///    two identities for one source occurrence, and the link then resolves to
///    the wrong occurrence — or to nothing — on somebody else's phone, days
///    later, with no way to tell a guess was ever made. So this layer FAILS
///    CLOSED wherever display falls back.
///
/// Everything here implements
/// `contracts/event-occurrence-identity/v1/contract.json`, mirrored byte for
/// byte from CaleeAdmin/calee-hub-core#424 and executed by
/// `test/features/local_subscriber/event_occurrence_identity_contract_test.dart`.
/// The same rules are implemented in Hub Core
/// (`client_caldav_canonical_*` in `public/lib/core_client_caldav.php`) and in
/// CalEmbed (`calee_calendar_canonical_*` in `lib/calendar_data.php`).
///
/// Nothing in this file reads the device timezone, `DateTime.now()`,
/// `DateTime.local`, `tz.local`, or an environment variable. That is the whole
/// point: an identity that depends on the reader is not an identity.
///
/// ## Known divergences from Hub Core and CalEmbed
///
/// The v1 fixture does not cover these, so they are recorded rather than
/// silently resolved. In every one of them CaleeMobile REFUSES where a PHP
/// client would mint, which costs a shareable occurrence but never produces a
/// contradictory identity. Each needs its own issue before v2.
///
///  * **Timezone database contents and vintage.** After the shape gate the
///    contract defers to "the platform timezone database", and the two
///    platforms do not carry the same one. `package:timezone`'s bundled
///    `latest` data (431 zones, pinned at 0.9.4) has no `Etc/*` zones and few
///    IANA backward links, so `Etc/UTC`, `Asia/Calcutta`, `Australia/Canberra`
///    and `Europe/Kiev` all resolve in PHP and are refused here. Where both
///    resolve, stale data can still disagree — Paraguay's 2024 DST abolition is
///    absent, so an `America/Asuncion` event is an hour apart — and the bundled
///    rules stop projecting DST after 2037. Closing this is a dependency
///    upgrade (and possibly `latest_all`), not a contract change.
///  * **Case.** PHP's `DateTimeZone` resolves `australia/perth`; Dart's
///    `tz.getLocation` is case sensitive, and IANA names are too.
///  * **UID whitespace.** The UID-presence test uses Dart's `String.trim()`,
///    which strips the whole Unicode whitespace class where PHP's `trim()`
///    strips only ASCII, so a UID of one non-breaking space is "no UID" here
///    and a real UID in Hub Core. The VALUE gate below deliberately does not
///    share that behaviour.
library;

import 'dart:convert';

import 'package:timezone/timezone.dart' as tz;

import 'local_calendar_event.dart';

/// Version of the `calee.event-occurrence-identity` contract implemented here.
const int localCalendarOccurrenceIdentityContractVersion = 1;

/// Why resolving ONE source value or component did or did not produce a
/// canonical identity. These are the contract's `sourceStatuses`.
abstract final class CanonicalSourceStatus {
  /// The value resolved; a canonical identity is available.
  static const String ok = 'ok';

  /// The source named a timezone this contract cannot resolve portably.
  static const String unsupportedTzid = 'unsupported_tzid';

  /// A floating value with no explicitly declared calendar timezone context.
  static const String floatingWithoutContext = 'floating_without_context';

  /// Not a real ICS `DATE`/`DATE-TIME`, or the wrong shape for this series.
  static const String malformedValue = 'malformed_value';

  /// The component carries no usable `UID`.
  static const String noSourceUid = 'no_source_uid';

  /// Every status this layer can report, in contract order.
  static const List<String> values = <String>[
    ok,
    unsupportedTzid,
    floatingWithoutContext,
    malformedValue,
    noSourceUid,
  ];
}

/// Why assembling the identity TRIPLE did or did not succeed. These are the
/// contract's `identityStatuses`.
abstract final class CanonicalIdentityStatus {
  static const String ok = 'ok';
  static const String noCalendarReference = 'no_calendar_reference';
  static const String noSourceUid = 'no_source_uid';
  static const String noCanonicalRecurrenceIdentity =
      'no_canonical_recurrence_identity';

  static const List<String> values = <String>[
    ok,
    noCalendarReference,
    noSourceUid,
    noCanonicalRecurrenceIdentity,
  ];
}

/// The outcome of resolving one raw ICS `DATE` / `DATE-TIME` value.
///
/// [canonicalIdentity] is non-null only when [status] is
/// [CanonicalSourceStatus.ok].
class CanonicalValueResolution {
  const CanonicalValueResolution._(this.status, this.canonicalIdentity);

  const CanonicalValueResolution.refused(String status) : this._(status, null);

  const CanonicalValueResolution.resolved(String identity)
    : this._(CanonicalSourceStatus.ok, identity);

  final String status;
  final String? canonicalIdentity;

  bool get isOk => status == CanonicalSourceStatus.ok;

  /// Whether the value is not a real ICS `DATE`/`DATE-TIME` in this key space.
  ///
  /// This is the one canonical judgement the DISPLAY layer must honour too: a
  /// value that names no real instant must never be allowed to name SOME OTHER
  /// valid occurrence. It is decided before any timezone is consulted, so it is
  /// the same answer on every client and needs no context to ask.
  bool get isMalformed => status == CanonicalSourceStatus.malformedValue;
}

/// The clock ONE source component is canonically named on, resolved once.
///
/// A recurrence rule is a source WALL-CLOCK rule, so every occurrence it
/// generates is named on this one zone. Resolving it per occurrence costs a
/// regex, a string build and a database lookup for every event in the feed —
/// measurable on a large calendar, on the isolate that draws the UI — and it
/// cannot change between occurrences, so it is resolved here instead.
class CanonicalSourceClock {
  const CanonicalSourceClock._(this.status, this.location, this.allDay);

  /// The contract status of the component's own `DTSTART`.
  final String status;

  /// The zone occurrences are named on. Null for an all-day series (literal
  /// calendar dates have no zone) and for a refused clock.
  final tz.Location? location;

  final bool allDay;

  bool get isOk => status == CanonicalSourceStatus.ok;

  /// Whether an identity already formatted on [displayLocation] IS the
  /// canonical identity, because the display parser resolved this component on
  /// the very zone the canonical layer names it on.
  ///
  /// The two agree whenever the source resolves canonically — the strict gate
  /// only ever narrows which names are accepted, never which zone a name means
  /// — and this lets the expansion reuse the identity it has already built.
  bool namesOn(tz.Location? displayLocation) =>
      isOk && (allDay || identical(location, displayLocation));

  /// The canonical identity of the occurrence at this source wall clock.
  String? identityAt(
    int year,
    int month,
    int day,
    int hour,
    int minute,
    int second,
  ) {
    if (!isOk) return null;
    if (allDay) return canonicalAllDayIdentity(year, month, day);
    return canonicalTimedIdentity(
      tz.TZDateTime(location!, year, month, day, hour, minute, second),
    );
  }
}

/// The full canonical identity triple of one logical occurrence.
///
/// The three fields travel SEPARATELY. No delimiter-joined composite is ever
/// minted here, because a `UID` may legally contain any delimiter you would
/// choose — `urn:uuid:5b7f0f6e-…` already contains `:` — so a composite cannot
/// be split back apart. [key] exists only so a test or a cache can index on the
/// triple; it is a structural JSON encoding, never a wire identifier.
class CanonicalOccurrenceIdentity {
  const CanonicalOccurrenceIdentity({
    required this.status,
    this.calendarRef,
    this.sourceUid,
    this.recurrenceId,
  });

  final String status;

  /// The calendar the source component was read from. Part of the identity:
  /// the same UID in a different calendar is a different logical event.
  final String? calendarRef;

  /// The verbatim source `UID`.
  final String? sourceUid;

  /// The canonical recurrence identity, or null for a non-recurring event.
  final String? recurrenceId;

  bool get isOk => status == CanonicalIdentityStatus.ok;

  /// Structured encoding of the triple, for indexing only. JSON so that no
  /// UID content can be mistaken for a field separator.
  String get key => jsonEncode(<String?>[calendarRef, sourceUid, recurrenceId]);
}

/// The timezone a canonical identity may be resolved on, or null.
///
/// Contract v1 accepts the literal name `UTC` and IANA `Area/Location`
/// identifiers, and nothing else. Windows names (`W. Australia Standard Time`),
/// bare abbreviations (`AWST`, `EST`) and numeric offsets (`+08:00`) are
/// refused rather than mapped: mapping them is a timezone-database project
/// whose answers would have to agree in PHP and in Dart forever.
///
/// The shape test comes FIRST and is normative, rather than deferring to the
/// platform. PHP's `DateTimeZone` and Dart's [tz.getLocation] each accept
/// several non-IANA spellings and they do not accept the same ones, so a name
/// one engine resolves and the other does not must be refused by both.
///
/// A `TZID` parameter may be quoted (RFC 5545 3.1). The quotes are parameter
/// syntax, not part of the zone name, and are stripped exactly once — at the
/// property parser — before a name ever reaches this function.
tz.Location? canonicalTimezone(String? name) {
  if (name == null) return null;
  final trimmed = name.trim();
  if (trimmed.isEmpty) return null;
  if (trimmed != 'UTC' && !_ianaAreaLocation.hasMatch(trimmed)) return null;

  try {
    return tz.getLocation(trimmed);
  } catch (_) {
    return null;
  }
}

/// The verbatim source `UID` of a component, or null when it carries none.
///
/// `UID` is OPAQUE source identity: the value is every byte after the property
/// colon. Case, internal whitespace and boundary whitespace are all part of it,
/// so ` series-one`, `series-one` and `series-one ` are three different source
/// events. Trimming decides only whether a UID is PRESENT; the value returned
/// is the untrimmed original.
///
/// The literal string `0` is a valid UID and is never discarded. An absent,
/// empty or whitespace-only UID means there is NO canonical source UID: a
/// caller may manufacture a local stand-in to keep display grouping working,
/// but must not present that stand-in as a source UID — a link minted from one
/// breaks the moment the component body is edited and cannot be reproduced by
/// another client.
String? canonicalSourceUid(String? uidPropertyValue) {
  if (uidPropertyValue == null) return null;
  return uidPropertyValue.trim().isEmpty ? null : uidPropertyValue;
}

/// The canonical identity of ONE raw ICS `DATE` / `DATE-TIME` value.
///
/// [allDay] is the SERIES' key space, not a hint about this value: an all-day
/// series is keyed by literal calendar date and a timed series by UTC instant,
/// and a value of the wrong shape cannot be converted between them without
/// inventing an identity.
///
/// The timezone resolution ladder, in order (contract §4.1):
///
///  1. a trailing `Z` designates UTC and OUTRANKS a `TZID` on the same
///     property (RFC 5545 3.3.5 form 2);
///  2. [propertyTzid] — the property's own `TZID`. If it does not resolve the
///     ladder STOPS at [CanonicalSourceStatus.unsupportedTzid]; the calendar
///     context must not rescue it, because the source named a zone and
///     substituting a different one invents an instant;
///  3. [componentDtstartTzid] — for `RECURRENCE-ID` and `EXDATE` only, so a
///     property with no `TZID` of its own is read on the clock its series is
///     expanded on. Never applies to `DTSTART` itself;
///  4. [calendarTzid] — the explicit calendar/source timezone context supplied
///     by the CALLER. There is no device, process, host or recipient fallback
///     below it;
///  5. refuse: [CanonicalSourceStatus.floatingWithoutContext].
///
/// A malformed value is refused rather than normalised. Dart's [DateTime]
/// would silently rename `20260230` to 2 March and roll second `60` into the
/// following minute; a malformed value must never NAME another valid
/// occurrence, so the components are range-checked before any [DateTime] is
/// constructed.
CanonicalValueResolution canonicalOccurrenceIdentity(
  String? rawValue, {
  required bool allDay,
  String? propertyTzid,
  String? componentDtstartTzid,
  String? calendarTzid,
}) {
  const malformed = CanonicalValueResolution.refused(
    CanonicalSourceStatus.malformedValue,
  );

  // ASCII whitespace only, matching PHP's trim(). Dart's String.trim()
  // strips the whole Unicode whitespace class, so a value carrying a
  // non-breaking space would mint here and be malformed_value in Hub Core
  // and CalEmbed — one source occurrence, two answers.
  final value = _asciiTrim(rawValue ?? '');
  if (value.isEmpty) return malformed;

  if (allDay) {
    // A DATE is a literal calendar date. A TZID parameter is meaningless on it
    // (RFC 5545 3.3.4) and it is NEVER routed through a UTC conversion, so no
    // offset can move an all-day occurrence onto the adjacent day.
    final match = _dateValue.firstMatch(value);
    if (match == null) return malformed;

    final year = int.parse(match[1]!);
    final month = int.parse(match[2]!);
    final day = int.parse(match[3]!);
    if (!_isRealDate(year, month, day)) return malformed;

    return CanonicalValueResolution.resolved(
      canonicalAllDayIdentity(year, month, day),
    );
  }

  final match = _dateTimeValue.firstMatch(value);
  if (match == null) return malformed;

  final year = int.parse(match[1]!);
  final month = int.parse(match[2]!);
  final day = int.parse(match[3]!);
  final hour = int.parse(match[4]!);
  final minute = int.parse(match[5]!);
  // RFC 5545 permits second 60 as a leap second. It is not portable, so it is
  // refused rather than rolled into the following minute.
  final second = int.parse(match[6]!);
  if (!_isRealDate(year, month, day) ||
      hour > 23 ||
      minute > 59 ||
      second > 59) {
    return malformed;
  }

  if (match[7] == 'Z') {
    return CanonicalValueResolution.resolved(
      canonicalTimedIdentity(
        DateTime.utc(year, month, day, hour, minute, second),
      ),
    );
  }

  for (final name in <String?>[
    propertyTzid,
    componentDtstartTzid,
    calendarTzid,
  ]) {
    final declared = _blankToNull(name);
    if (declared == null) continue;

    final zone = canonicalTimezone(declared);
    if (zone == null) {
      return const CanonicalValueResolution.refused(
        CanonicalSourceStatus.unsupportedTzid,
      );
    }

    return CanonicalValueResolution.resolved(
      canonicalTimedIdentity(
        tz.TZDateTime(zone, year, month, day, hour, minute, second),
      ),
    );
  }

  return const CanonicalValueResolution.refused(
    CanonicalSourceStatus.floatingWithoutContext,
  );
}

/// Resolves the clock one component's occurrences are canonically named on.
///
/// [dtStartValue] and [propertyTzid] are the component's own raw `DTSTART`;
/// step 3 of the ladder never applies to `DTSTART` itself, so no component zone
/// is taken. A trailing `Z` means the series steps in UTC — the same reading
/// the expansion already uses, so the two can never disagree.
CanonicalSourceClock canonicalSourceClock({
  required String? dtStartValue,
  required bool allDay,
  String? propertyTzid,
  String? calendarTzid,
}) {
  final resolved = canonicalOccurrenceIdentity(
    dtStartValue,
    allDay: allDay,
    propertyTzid: propertyTzid,
    calendarTzid: calendarTzid,
  );
  if (!resolved.isOk) {
    return CanonicalSourceClock._(resolved.status, null, allDay);
  }
  if (allDay) {
    return CanonicalSourceClock._(CanonicalSourceStatus.ok, null, true);
  }

  // Non-null by construction: the resolution above only succeeds for a timed
  // value when one of these three answered.
  final zone = _asciiTrim(dtStartValue ?? '').endsWith('Z')
      ? tz.UTC
      : (canonicalTimezone(propertyTzid) ?? canonicalTimezone(calendarTzid));

  return CanonicalSourceClock._(CanonicalSourceStatus.ok, zone, false);
}

/// The canonical Event Link identity of one parsed occurrence.
///
/// The identity is [calendarRef] + [LocalCalendarEvent.uid] +
/// [LocalCalendarEvent.canonicalRecurrenceId]. It is deliberately NOT the
/// event's own [LocalCalendarEvent.id]: that is a CaleeMobile-local UI key the
/// contract declares non-normative, it concatenates a UID with a millisecond
/// stamp, and a UID may itself contain the separator.
///
/// The CANONICAL recurrence identity is used, never the display key. They agree
/// whenever the source resolves canonically; where they differ — an
/// unresolvable TZID, a floating value with no context, an out-of-range
/// `RECURRENCE-ID` — the display key is a local best effort, and minting a link
/// from it would hand another client an identity it cannot reproduce.
///
/// [LocalCalendarEvent.canonicalStatus] is deliberately NOT consulted: it
/// answers whether the SOURCE COMPONENT could be canonically placed, which is a
/// different question from whether this occurrence can be named. A detached
/// override moved onto a zone no database resolves still names its occurrence
/// from `RECURRENCE-ID`, and a one-off is named without any instant at all.
CanonicalOccurrenceIdentity canonicalEventLinkIdentity(
  String? calendarRef,
  LocalCalendarEvent event,
) {
  final reference = _blankToNull(calendarRef);
  if (reference == null) {
    return const CanonicalOccurrenceIdentity(
      status: CanonicalIdentityStatus.noCalendarReference,
    );
  }

  final sourceUid = canonicalSourceUid(event.uid);
  if (sourceUid == null) {
    return CanonicalOccurrenceIdentity(
      status: CanonicalIdentityStatus.noSourceUid,
      calendarRef: reference,
    );
  }

  // An occurrence OF a series that cannot be named is unshareable. A
  // NON-recurring event is not gated here at all: its identity is the calendar
  // reference plus the source UID, so whether its DTSTART could be placed is
  // beside the point — contract §1 requires that moving a one-off must not
  // change its identity, and Hub Core and CalEmbed gate on exactly the same
  // condition.
  if (event.recurring && event.canonicalRecurrenceId == null) {
    return CanonicalOccurrenceIdentity(
      status: CanonicalIdentityStatus.noCanonicalRecurrenceIdentity,
      calendarRef: reference,
      sourceUid: sourceUid,
    );
  }

  return CanonicalOccurrenceIdentity(
    status: CanonicalIdentityStatus.ok,
    calendarRef: reference,
    sourceUid: sourceUid,
    recurrenceId: event.canonicalRecurrenceId,
  );
}

/// `Ymd` — the canonical identity of an all-day occurrence, a literal calendar
/// date that is never routed through a timezone conversion.
String canonicalAllDayIdentity(int year, int month, int day) =>
    '${_pad(year, 4)}${_pad(month, 2)}${_pad(day, 2)}';

/// `YmdTHisZ` — the canonical identity of a timed occurrence, at its TRUE UTC
/// instant. `15:30 Australia/Perth` is `20260818T073000Z`, never
/// `20260818T153000Z`.
String canonicalTimedIdentity(DateTime instant) {
  final utc = instant.toUtc();
  return '${_pad(utc.year, 4)}${_pad(utc.month, 2)}${_pad(utc.day, 2)}'
      'T${_pad(utc.hour, 2)}${_pad(utc.minute, 2)}${_pad(utc.second, 2)}Z';
}

/// The normative accepted-TZID shape: `UTC`, or an IANA `Area/Location`.
final RegExp _ianaAreaLocation = RegExp(
  r'^[A-Za-z][A-Za-z0-9_+-]*(?:/[A-Za-z0-9_+-]+)+$',
);

final RegExp _dateValue = RegExp(r'^(\d{4})(\d{2})(\d{2})$');

final RegExp _dateTimeValue = RegExp(
  r'^(\d{4})(\d{2})(\d{2})T(\d{2})(\d{2})(\d{2})(Z?)$',
);

/// Whether these components name a real calendar date.
///
/// Computed arithmetically rather than by round-tripping a [DateTime], because
/// `DateTime(2026, 2, 30)` is 2 March and would rename a malformed value into a
/// valid occurrence of the same series.
bool _isRealDate(int year, int month, int day) {
  if (year < 1 || month < 1 || month > 12 || day < 1) return false;
  return day <= _daysInMonth(year, month);
}

int _daysInMonth(int year, int month) {
  const lengths = <int>[31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31];
  if (month == 2 && _isLeapYear(year)) return 29;
  return lengths[month - 1];
}

bool _isLeapYear(int year) =>
    (year % 4 == 0 && year % 100 != 0) || year % 400 == 0;

String? _blankToNull(String? value) {
  if (value == null) return null;
  final trimmed = value.trim();
  return trimmed.isEmpty ? null : trimmed;
}

/// Strips the characters PHP's `trim()` strips, and only those.
String _asciiTrim(String value) {
  const cut = <int>[0x20, 0x09, 0x0a, 0x0d, 0x00, 0x0b];
  var start = 0;
  var end = value.length;
  while (start < end && cut.contains(value.codeUnitAt(start))) {
    start++;
  }
  while (end > start && cut.contains(value.codeUnitAt(end - 1))) {
    end--;
  }
  return value.substring(start, end);
}

String _pad(int value, int width) => value.toString().padLeft(width, '0');
