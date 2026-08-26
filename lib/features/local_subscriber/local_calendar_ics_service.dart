import 'dart:convert';
import 'dart:io';

import 'package:timezone/timezone.dart' as tz;

import 'local_calendar_event.dart';
import 'local_calendar_occurrence_identity.dart';
import 'local_calendar_subscription.dart';

/// Fetches and parses an ICS feed for a phone-only calendar subscription.
///
/// A recurring master and its detached `RECURRENCE-ID` components describe ONE
/// series, so VEVENTs are parsed into internal components first, grouped by
/// source UID, expanded, reconciled, and only then turned into
/// [LocalCalendarEvent]s. Emitting at `END:VEVENT` — as this parser used to —
/// makes that reconciliation impossible: a modified occurrence appears twice
/// (once at its original time from the master, once at its moved time from the
/// override) and a detached `STATUS:CANCELLED` component appears as a second
/// visible event beside the occurrence it was meant to cancel.
///
/// Two identity layers run side by side here and are deliberately allowed to
/// disagree. The DISPLAY layer ([_parseIcsValue] and
/// [LocalCalendarEvent.recurrenceId]) keeps every legacy fallback, so a feed
/// naming a timezone this phone has no data for still renders and still
/// reconciles. The CANONICAL layer
/// (`local_calendar_occurrence_identity.dart`, surfaced as
/// [LocalCalendarEvent.canonicalRecurrenceId] and
/// [LocalCalendarEvent.canonicalStatus]) fails closed instead, because a
/// cross-client Event Link minted from a local guess resolves to the wrong
/// occurrence on somebody else's phone.
class LocalCalendarIcsService {
  const LocalCalendarIcsService();

  static const _timeout = Duration(seconds: 20);
  static const _windowPast = Duration(days: 30);
  static const _windowFuture = Duration(days: 365);
  static const _maxResponseBytes = 5 * 1024 * 1024; // 5 MB

  Future<List<LocalCalendarEvent>> fetchEvents(
    LocalCalendarSubscription subscription,
  ) async {
    final url = _normalizeUrl(subscription.url);
    final uri = Uri.parse(url);

    final client = HttpClient();
    try {
      client.connectionTimeout = _timeout;
      final request = await client.getUrl(uri).timeout(_timeout);
      request.headers.set(HttpHeaders.userAgentHeader, 'CaleeMobile/1');
      final response = await request.close().timeout(_timeout);

      if (response.statusCode != 200) {
        throw const LocalCalendarIcsException(
          'Unable to refresh this calendar. Please try again.',
        );
      }

      final body = await readBody(response).timeout(_timeout);
      return parseBody(body, subscription);
    } on LocalCalendarIcsException {
      rethrow;
    } catch (_) {
      throw const LocalCalendarIcsException(
        'Unable to refresh this calendar. Please try again.',
      );
    } finally {
      client.close();
    }
  }

  /// Reads a response stream up to [_maxResponseBytes].
  ///
  /// Throws [LocalCalendarIcsException] if the limit is exceeded.
  Future<String> readBody(Stream<List<int>> stream) async {
    final chunks = <List<int>>[];
    var totalBytes = 0;
    await for (final chunk in stream) {
      totalBytes += chunk.length;
      if (totalBytes > _maxResponseBytes) {
        throw const LocalCalendarIcsException(
          'This calendar is too large to open on this phone.',
        );
      }
      chunks.add(chunk);
    }
    return utf8.decode(chunks.expand((c) => c).toList());
  }

  /// Parses an ICS body and returns events within the fetch window.
  ///
  /// [now] overrides the clock the 30-day-past / 365-day-future window is
  /// derived from. Production leaves it null and uses [DateTime.now]; tests
  /// pass a fixed instant so fixtures do not expire as the real date moves.
  ///
  /// [calendarTzid] is the explicitly declared calendar/source timezone
  /// context — step 4 of the contract's resolution ladder. It is an ARGUMENT,
  /// never a persisted subscription field and never inferred from the device:
  /// a signed-out subscription has no such context, production passes none, and
  /// with none this parser behaves exactly as it always has. When a caller does
  /// supply one it becomes the last floating fallback ahead of device-local
  /// time, so a floating feed is displayed on the clock it was declared on and
  /// its canonical identity is minted on that same clock.
  List<LocalCalendarEvent> parseBody(
    String icsBody,
    LocalCalendarSubscription subscription, {
    DateTime? now,
    String? calendarTzid,
  }) {
    final reference = now ?? DateTime.now();
    final windowStart = reference.subtract(_windowPast);
    final windowEnd = reference.add(_windowFuture);

    // Resolved through the STRICT gate even for display: an explicit caller
    // context is only ever honoured when it is a name every Calee client
    // resolves the same way.
    final calendarLocation = canonicalTimezone(calendarTzid);

    final events = <LocalCalendarEvent>[];
    for (final group in _groupBySourceUid(
      _parseComponents(icsBody, calendarLocation),
    )) {
      events.addAll(
        _reconcileGroup(
          group,
          subscription,
          windowStart,
          windowEnd,
          calendarTzid,
          calendarLocation,
        ),
      );
    }

    // Ties are broken on the UI id so a feed always yields the same order.
    events.sort((a, b) {
      final byStart = a.start.compareTo(b.start);
      return byStart != 0 ? byStart : a.id.compareTo(b.id);
    });
    return events;
  }

  // ── Component parsing ─────────────────────────────────────────────────────

  /// Parses every VEVENT into an internal component. Nothing is emitted here:
  /// a component cannot be turned into events until its whole UID group is
  /// known.
  List<_VeventComponent> _parseComponents(
    String icsBody,
    tz.Location? calendarFallback,
  ) {
    final components = <_VeventComponent>[];
    _VeventComponent? current;
    var nested = 0;
    var order = 0;

    for (final line in _unfoldLines(icsBody)) {
      if (current == null) {
        // Everything outside a VEVENT is ignored, VTIMEZONE included.
        if (line == 'BEGIN:VEVENT') {
          current = _VeventComponent(order: order++);
          nested = 0;
        }
        continue;
      }

      // A VEVENT may contain sub-components (VALARM). Their properties belong
      // to them, not to the event: RFC 9074 gives a VALARM its own UID, and a
      // VALARM also carries SUMMARY and DESCRIPTION. Letting either reach the
      // event would hand the series an alarm's identity and break every
      // grouping decision made below.
      if (nested > 0) {
        if (_isComponentBoundary(line, 'BEGIN:')) {
          nested++;
        } else if (_isComponentBoundary(line, 'END:')) {
          nested--;
        }
        continue;
      }

      if (line == 'END:VEVENT') {
        if (current.dtStart != null) components.add(current);
        current = null;
        continue;
      }

      if (_isComponentBoundary(line, 'BEGIN:')) {
        nested++;
        continue;
      }

      final property = _parseProperty(line);
      if (property == null) continue;

      switch (property.name) {
        case 'UID':
          // Opaque source identity. canonicalSourceUid() decides only whether a
          // UID is PRESENT — the value kept is the untrimmed original, so ' a'
          // and 'a' stay distinct series. The historical UI base id keeps its
          // trimmed shape, tracked separately.
          final sourceUid = canonicalSourceUid(property.value);
          current.uid = sourceUid;
          current.legacyBaseUid = sourceUid?.trim();
        case 'SUMMARY':
          current.summary = _unescapeText(property.value);
        case 'DTSTART':
          // The raw property is kept alongside the parsed value: the canonical
          // layer needs the UNRESOLVED source bytes, because by the time the
          // display parser is done a Windows TZID looks exactly like a real one.
          current.dtStartProperty = property;
          current.dtStart = _parseIcsValue(
            property.value,
            property.params,
            calendarFallback: calendarFallback,
          );
        case 'DTEND':
          current.dtEnd = _parseIcsValue(
            property.value,
            property.params,
            calendarFallback: calendarFallback,
          );
        case 'RRULE':
          current.rrule = property.value;
        case 'EXDATE':
          // Each physical line keeps its own parameters, so a line naming a
          // different zone from DTSTART is read on its own clock.
          current.exdateLines.add(property);
        case 'RECURRENCE-ID':
          current.recurrenceIdProperty ??= property;
        case 'STATUS':
          current.status = property.value.trim().toUpperCase();
      }
    }

    return components;
  }

  /// Groups components that describe one series.
  ///
  /// A real source UID groups a series. A component with no usable UID groups
  /// with ITSELF and nothing else, so a UID-less feed keeps the
  /// one-component-per-event behaviour it has always had and no generated
  /// fallback is ever mistaken for a real UID. The two key spaces are disjoint
  /// BY CONSTRUCTION — `uid:` versus `ord:` — so no UID content can collide
  /// with the parse-order fallback, which is what lets the UID above be kept
  /// verbatim.
  Iterable<List<_VeventComponent>> _groupBySourceUid(
    List<_VeventComponent> components,
  ) {
    final groups = <String, List<_VeventComponent>>{};
    for (final component in components) {
      final key = component.uid != null
          ? 'uid:${component.uid}'
          : 'ord:${component.order}';
      (groups[key] ??= <_VeventComponent>[]).add(component);
    }
    return groups.values;
  }

  // ── Detached reconciliation ───────────────────────────────────────────────

  /// Reconciles one UID group's master(s) with its detached components.
  ///
  ///  * an override REPLACES the generated occurrence sharing its canonical
  ///    recurrence identity, so the logical occurrence count is unchanged and
  ///    no stale twin survives at the original time;
  ///  * a detached `STATUS:CANCELLED` component SUPPRESSES that occurrence and
  ///    is never itself emitted;
  ///  * a cancellation beats a modification for the same identity in either
  ///    document order;
  ///  * an override that claims no generated occurrence — moved in from outside
  ///    the window, or paired with an EXDATE that already removed its original
  ///    — is still emitted, window-filtered like any other one-off;
  ///  * an override whose `RECURRENCE-ID` cannot be interpreted keeps its
  ///    historical pass-through, so a malformed component is never silently
  ///    deleted, and it reconciles against nothing.
  List<LocalCalendarEvent> _reconcileGroup(
    List<_VeventComponent> group,
    LocalCalendarSubscription subscription,
    DateTime windowStart,
    DateTime windowEnd,
    String? calendarTzid,
    tz.Location? calendarFallback,
  ) {
    final masters = <_VeventComponent>[];
    final detached = <_DetachedComponent>[];

    for (final component in group) {
      final property = component.recurrenceIdProperty;
      if (property == null) {
        masters.add(component);
      } else {
        detached.add(
          _resolveDetached(component, property, calendarTzid, calendarFallback),
        );
      }
    }

    final overridesByKey = <String, _DetachedComponent>{};
    final cancelledKeys = <String>{};
    final unkeyedOverrides = <_DetachedComponent>[];

    for (final override in detached) {
      final key = override.identity;
      final isCancelled = override.component.status == 'CANCELLED';

      if (key == null) {
        // No identity to reconcile against. A cancellation that names no
        // occurrence cancels nothing and stays hidden; anything else keeps the
        // visibility it has always had.
        if (!isCancelled) unkeyedOverrides.add(override);
        continue;
      }

      if (isCancelled) {
        cancelledKeys.add(key);
        overridesByKey.remove(key);
        continue;
      }

      if (!cancelledKeys.contains(key)) overridesByKey[key] = override;
    }

    final events = <LocalCalendarEvent>[];

    for (final master in masters) {
      final dtStart = master.dtStart!;
      final baseId = _baseIdFor(master, subscription);
      final duration = master.dtEnd?.value.difference(dtStart.value);
      // Resolved ONCE per series: every occurrence a wall-clock rule generates
      // is named on the same zone, and re-resolving it per occurrence is pure
      // cost on the isolate that draws the calendar.
      final clock = _canonicalClock(master, calendarTzid);
      final componentStatus = _componentStatus(master, <String>[clock.status]);

      if (master.rrule != null) {
        final occurrences = _expandRrule(
          rruleValue: master.rrule!,
          dtStart: dtStart,
          windowStart: windowStart,
          windowEnd: windowEnd,
          exdateIdentities: _exdateIdentities(master, calendarFallback),
          clock: clock,
        );
        for (final occurrence in occurrences) {
          if (cancelledKeys.contains(occurrence.identity) ||
              overridesByKey.containsKey(occurrence.identity)) {
            // Cancelled outright, or superseded by the override emitted below
            // — either way the generated twin must not survive.
            continue;
          }
          events.add(
            LocalCalendarEvent(
              id: '$baseId:${occurrence.instant.millisecondsSinceEpoch}',
              subscriptionId: subscription.id,
              subscriptionTitle: subscription.title,
              title: master.summary ?? 'Untitled',
              start: occurrence.instant,
              end: duration != null ? occurrence.instant.add(duration) : null,
              isAllDay: dtStart.isAllDay,
              sourceUrl: subscription.url,
              uid: master.uid,
              recurrenceId: occurrence.identity,
              recurring: true,
              // Gated on the SERIES' own DTSTART, not just on this occurrence:
              // a malformed DTSTART is silently rolled onto a real date by the
              // display parser, and the rule then steps from there onto dates
              // that resolve perfectly well. A malformed value must never name
              // another valid occurrence. Gated on the UID too, so this field
              // is never a recurrence identity with nothing to pair it with.
              canonicalRecurrenceId: master.uid == null
                  ? null
                  : occurrence.canonicalIdentity,
              canonicalStatus: componentStatus,
            ),
          );
        }
      } else if (_inWindow(
        dtStart.value,
        master.dtEnd?.value,
        windowStart,
        windowEnd,
      )) {
        events.add(
          LocalCalendarEvent(
            id: baseId,
            subscriptionId: subscription.id,
            subscriptionTitle: subscription.title,
            title: master.summary ?? 'Untitled',
            start: dtStart.value,
            end: master.dtEnd?.value,
            isAllDay: dtStart.isAllDay,
            sourceUrl: subscription.url,
            uid: master.uid,
            // A one-off event's identity is the calendar reference plus the
            // source UID. Moving its DTSTART must NOT change it, so the start
            // is deliberately not part of it.
            recurrenceId: null,
            recurring: false,
            canonicalRecurrenceId: null,
            canonicalStatus: componentStatus,
          ),
        );
      }
    }

    for (final override in [...overridesByKey.values, ...unkeyedOverrides]) {
      final component = override.component;
      final dtStart = component.dtStart!;
      if (!_inWindow(
        dtStart.value,
        component.dtEnd?.value,
        windowStart,
        windowEnd,
      )) {
        continue;
      }

      // The occurrence keeps the UI id it had before it moved, so a detached
      // replacement does not create a stale/new pair for widgets keyed on it.
      final baseId = _baseIdFor(component, subscription);
      final originalInstant = override.identityInstant;
      events.add(
        LocalCalendarEvent(
          id: originalInstant != null
              ? '$baseId:${originalInstant.millisecondsSinceEpoch}'
              : baseId,
          subscriptionId: subscription.id,
          subscriptionTitle: subscription.title,
          title: component.summary ?? 'Untitled',
          start: dtStart.value,
          end: component.dtEnd?.value,
          isAllDay: dtStart.isAllDay,
          sourceUrl: subscription.url,
          uid: component.uid,
          recurrenceId: override.identity,
          recurring: true,
          // RECURRENCE-ID alone names the occurrence: the moved DTSTART only
          // says where it now happens, so a DTSTART this phone cannot place
          // must not unname it. Hub Core and CalEmbed resolve exactly this.
          canonicalRecurrenceId: component.uid == null
              ? null
              : override.canonical.canonicalIdentity,
          canonicalStatus: _componentStatus(component, <String>[
            _canonicalClock(component, calendarTzid).status,
            override.canonical.status,
          ]),
        ),
      );
    }

    return events;
  }

  /// Resolves a detached component's `RECURRENCE-ID` to a canonical identity.
  ///
  /// `RECURRENCE-ID` names the ORIGINAL logical occurrence the component
  /// replaces, so the identity is always read from it and never derived from
  /// the moved `DTSTART`. It is interpreted with the same rules `DTSTART` uses:
  /// a trailing `Z` is UTC, an explicit (possibly quoted) TZID wins next, and a
  /// floating value inherits the component's own `DTSTART` zone before falling
  /// back to device-local time.
  ///
  /// A null identity is not a silent drop — the caller keeps such a component
  /// visible rather than reconciling it against anything.
  _DetachedComponent _resolveDetached(
    _VeventComponent component,
    _IcsProperty property,
    String? calendarTzid,
    tz.Location? calendarFallback,
  ) {
    final dtStart = component.dtStart!;

    // The CANONICAL answer, read from the unresolved source bytes. It is
    // computed whatever the display parser makes of the same property, because
    // the display parser is allowed to guess and this is not.
    final canonical = canonicalOccurrenceIdentity(
      property.value,
      allDay: dtStart.isAllDay,
      propertyTzid: property.params['TZID'],
      componentDtstartTzid: _componentDtstartTzidParameter(component),
      calendarTzid: calendarTzid,
    );

    final parsed = _parseIcsValue(
      property.value,
      property.params,
      inherited: dtStart.isAllDay ? null : dtStart.location,
      calendarFallback: dtStart.isAllDay ? null : calendarFallback,
    );

    // A shape that disagrees with the component it belongs to (a date-only
    // RECURRENCE-ID on a timed component, say) names no occurrence we can
    // match — and neither does a value that is not a real date at all.
    //
    // The malformed test is the ONE canonical judgement the display key has to
    // honour as well. Dart renames 20260230 to 2 March and rolls hour 25 into
    // the next day, so without it a structurally impossible RECURRENCE-ID
    // reconciles against, and then replaces or cancels, a genuine occurrence
    // that other clients keep. It needs no timezone context, so display keeps
    // every fallback it has for values that ARE dates.
    if (parsed == null ||
        parsed.isAllDay != dtStart.isAllDay ||
        canonical.isMalformed) {
      return _DetachedComponent(component, null, null, canonical);
    }

    return _DetachedComponent(
      component,
      _canonicalOccurrenceId(parsed.value, parsed.isAllDay),
      parsed.value,
      canonical,
    );
  }

  /// Identity of ONE logical occurrence of a series, in the contract's key
  /// space, from an already-resolved instant.
  ///
  /// All-day occurrences are literal calendar dates (`Ymd`) and are NEVER
  /// routed through a timezone conversion — an all-day date has no instant
  /// behind it and converting one shifts it onto the wrong day. Timed
  /// occurrences are the TRUE UTC instant (`YmdTHisZ`), so the same occurrence
  /// written as `TZID=Australia/Perth:20260818T153000`, as `20260818T073000Z`,
  /// or in any other zone all reduce to one identity.
  ///
  /// This is the DISPLAY and reconciliation key, so the instant it is given may
  /// have come from a fallback. The shared formatters keep it byte-identical in
  /// shape to the canonical layer, which is what lets the two be compared.
  String _canonicalOccurrenceId(DateTime value, bool isAllDay) {
    return isAllDay
        ? canonicalAllDayIdentity(value.year, value.month, value.day)
        : canonicalTimedIdentity(value);
  }

  /// The `TZID` PARAMETER on this component's `DTSTART` — step 3 of the
  /// contract ladder, for `RECURRENCE-ID` and `EXDATE` only.
  ///
  /// Only the parameter. A trailing `Z` on the DTSTART VALUE is deliberately
  /// not turned into the name `UTC` here: Hub Core and CalEmbed both pass the
  /// parameter alone, and synthesising a zone they do not would make an unzoned
  /// RECURRENCE-ID on a UTC-anchored master resolve on a different clock in
  /// each client — two identities for one source occurrence, which is the exact
  /// failure this contract exists to prevent. The series' own EXPANSION clock
  /// still reads the `Z` (see [_canonicalClock]); that is a different question.
  String? _componentDtstartTzidParameter(_VeventComponent component) {
    final tzid = component.dtStartProperty?.params['TZID'];
    return (tzid == null || tzid.trim().isEmpty) ? null : tzid.trim();
  }

  /// The clock this component's occurrences are canonically named on.
  CanonicalSourceClock _canonicalClock(
    _VeventComponent component,
    String? calendarTzid,
  ) {
    final property = component.dtStartProperty;
    return canonicalSourceClock(
      dtStartValue: property?.value,
      allDay: component.dtStart?.isAllDay ?? false,
      propertyTzid: property?.params['TZID'],
      calendarTzid: calendarTzid,
    );
  }

  /// The contract source status of one component.
  ///
  /// The UID is checked first, so a component missing both a UID and a
  /// resolvable zone reports the missing UID — the same order Hub Core uses.
  String _componentStatus(_VeventComponent component, List<String> statuses) {
    if (component.uid == null) return CanonicalSourceStatus.noSourceUid;
    for (final status in statuses) {
      if (status != CanonicalSourceStatus.ok) return status;
    }
    return CanonicalSourceStatus.ok;
  }

  String _baseIdFor(
    _VeventComponent component,
    LocalCalendarSubscription subscription,
  ) {
    return component.legacyBaseUid ??
        _stableEventId(
          subscription,
          component.dtStart!.value,
          component.summary,
        );
  }

  /// Identities excluded by this component's EXDATE lines.
  ///
  /// Exclusion is by logical identity in the same key space the generated
  /// occurrences use, never by raw value and never by wall time — a UTC EXDATE
  /// and a TZID-qualified one naming the same instant are equivalent.
  Set<String> _exdateIdentities(
    _VeventComponent component,
    tz.Location? calendarFallback,
  ) {
    final dtStart = component.dtStart!;
    final identities = <String>{};

    for (final line in component.exdateLines) {
      for (final raw in line.value.split(',')) {
        final value = raw.trim();
        if (value.isEmpty) continue;
        // Same rule as a detached RECURRENCE-ID: an EXDATE that is not a real
        // date excludes nothing, rather than excluding whichever valid
        // occurrence Dart's normalisation happens to roll it onto.
        if (canonicalOccurrenceIdentity(
          value,
          allDay: dtStart.isAllDay,
        ).isMalformed) {
          continue;
        }

        final parsed = _parseIcsValue(
          value,
          line.params,
          // All-day EXDATEs stay literal dates and are never shifted by a TZID.
          inherited: dtStart.isAllDay ? null : dtStart.location,
          calendarFallback: dtStart.isAllDay ? null : calendarFallback,
        );
        if (parsed == null) continue;
        identities.add(_canonicalOccurrenceId(parsed.value, parsed.isAllDay));
      }
    }

    return identities;
  }

  // ── RRULE expansion ───────────────────────────────────────────────────────

  /// Expands a recurring master over the fetch window.
  ///
  /// A recurrence rule with a source timezone is a WALL-CLOCK rule: the next
  /// occurrence is the same local time on the next calendar position, not the
  /// same UTC instant plus a fixed [Duration]. Stepping instants would drift a
  /// Sydney 10:00 series to 11:00 the moment AEST becomes AEDT, which both
  /// shows the wrong time and makes the occurrence's canonical identity —
  /// and therefore every detached override that names it — fail to match.
  ///
  /// So the cursor here is a calendar DATE, advanced by the rule, and each
  /// occurrence's instant is rebuilt from that date plus DTSTART's wall-clock
  /// time in DTSTART's own zone.
  /// [clock] is the zone the series is CANONICALLY named on, resolved once from
  /// the source `DTSTART` by the strict layer. A series it refuses generates no
  /// canonical identities at all, so a feed the display parser had to guess a
  /// zone for mints nothing rather than something plausible and wrong.
  List<_Occurrence> _expandRrule({
    required String rruleValue,
    required _IcsDateTime dtStart,
    required DateTime windowStart,
    required DateTime windowEnd,
    required Set<String> exdateIdentities,
    required CanonicalSourceClock clock,
  }) {
    final params = _parseRruleParams(rruleValue);
    final freq = (params['FREQ'] ?? '').toUpperCase();
    if (!{'DAILY', 'WEEKLY', 'MONTHLY', 'YEARLY'}.contains(freq)) return [];

    // Fix 1: clamp returns num; force int explicitly.
    final parsedInterval = int.tryParse(params['INTERVAL'] ?? '') ?? 1;
    final interval = parsedInterval.clamp(1, 365).toInt();

    final countLimit = params['COUNT'] != null
        ? int.tryParse(params['COUNT']!)
        : null;

    DateTime? until;
    if (params['UNTIL'] != null) {
      until = _parseIcsValue(params['UNTIL']!, const {})?.value;
    }

    // BYDAY only supported for WEEKLY; ordinal values (e.g. 2MO, -1FR) are
    // filtered out by _weekdayOffset returning -1.
    final byDay = freq == 'WEEKLY'
        ? (params['BYDAY'] ?? '')
              .split(',')
              .map((s) => s.trim().toUpperCase())
              .where((s) => s.isNotEmpty)
              .toList()
        : <String>[];

    final isAllDay = dtStart.isAllDay;
    // The display parser resolved this series on the very zone the canonical
    // layer names it on, so the identity formatted below IS the canonical one
    // and does not need building twice. The else branch stays as defence: if
    // the two clocks ever diverge, the canonical identity is rebuilt from the
    // canonical clock rather than inherited from a display fallback.
    final canonicalTracksDisplay = clock.namesOn(dtStart.location);
    final results = <_Occurrence>[];
    // The cursor is a bare calendar date held in UTC purely so date
    // arithmetic is exact; it is never emitted.
    var cursor = DateTime.utc(dtStart.year, dtStart.month, dtStart.day);
    var current = dtStart.value;
    var occurrenceCount = 0;

    // Fast-forward past iterations before the window for DAILY/WEEKLY.
    // Only safe when there is no COUNT limit (COUNT requires accurate tracking
    // from the first occurrence, which precludes skipping ahead).
    if (current.isBefore(windowStart) &&
        byDay.isEmpty &&
        countLimit == null &&
        (freq == 'DAILY' || freq == 'WEEKLY')) {
      final daysPer = freq == 'WEEKLY' ? 7 * interval : interval;
      final gap = windowStart.difference(current).inDays;
      final skip = (gap / daysPer).floor() - 1;
      if (skip > 0) {
        cursor = cursor.add(Duration(days: skip * daysPer));
        current = _instantFor(dtStart, cursor);
      }
    }

    for (var iter = 0; iter < 3000; iter++) {
      if (until != null && current.isAfter(until)) break;
      if (countLimit != null && occurrenceCount >= countLimit) break;
      if (current.isAfter(windowEnd)) break;

      if (byDay.isNotEmpty) {
        // Expand each BYDAY within this interval week. The week is anchored on
        // the SOURCE wall-clock date, not on the UTC date of the instant — a
        // Sydney 10:00 occurrence is 23:00 UTC the previous day, which would
        // otherwise anchor the week a day early.
        final monday = cursor.subtract(Duration(days: cursor.weekday - 1));
        for (final dayAbbr in byDay) {
          final offset = _weekdayOffset(dayAbbr);
          if (offset < 0) continue; // ordinal or unknown — ignore safely
          if (countLimit != null && occurrenceCount >= countLimit) break;

          final occ = _instantFor(dtStart, monday.add(Duration(days: offset)));

          if (occ.isBefore(dtStart.value)) continue;
          if (until != null && occ.isAfter(until)) continue;

          // Fix 2: COUNT counts generated candidates before EXDATE removes
          // visible instances.
          occurrenceCount++;
          // Window before EXDATE: an out-of-window candidate is dropped either
          // way, and this keeps identity formatting off the hot path of a long
          // unbounded series. COUNT is unaffected — it was incremented above.
          if (occ.isAfter(windowStart) && !occ.isAfter(windowEnd)) {
            final identity = _canonicalOccurrenceId(occ, isAllDay);
            if (!exdateIdentities.contains(identity)) {
              final date = monday.add(Duration(days: offset));
              results.add(
                _Occurrence(
                  occ,
                  identity,
                  !clock.isOk
                      ? null
                      : canonicalTracksDisplay
                      ? identity
                      : clock.identityAt(
                          date.year,
                          date.month,
                          date.day,
                          dtStart.hour,
                          dtStart.minute,
                          dtStart.second,
                        ),
                ),
              );
            }
          }
        }
      } else {
        // Fix 2: count before EXDATE filter.
        occurrenceCount++;
        if (current.isAfter(windowStart) && !current.isAfter(windowEnd)) {
          final identity = _canonicalOccurrenceId(current, isAllDay);
          if (!exdateIdentities.contains(identity)) {
            results.add(
              _Occurrence(
                current,
                identity,
                !clock.isOk
                    ? null
                    : canonicalTracksDisplay
                    ? identity
                    : clock.identityAt(
                        cursor.year,
                        cursor.month,
                        cursor.day,
                        dtStart.hour,
                        dtStart.minute,
                        dtStart.second,
                      ),
              ),
            );
          }
        }
      }

      cursor = _advanceCursor(cursor, freq, interval, dtStart);
      current = _instantFor(dtStart, cursor);
    }

    return results;
  }

  /// Advances the calendar cursor by one step of the rule.
  DateTime _advanceCursor(
    DateTime cursor,
    String freq,
    int interval,
    _IcsDateTime dtStart,
  ) {
    switch (freq) {
      case 'DAILY':
        return cursor.add(Duration(days: interval));
      case 'WEEKLY':
        return cursor.add(Duration(days: 7 * interval));
      case 'MONTHLY':
        var month = cursor.month + interval;
        var year = cursor.year;
        while (month > 12) {
          month -= 12;
          year++;
        }
        // Fix 3/5: preserve the original day-of-month, clamping invalid dates.
        return DateTime.utc(
          year,
          month,
          dtStart.day.clamp(1, _daysInMonth(year, month)),
        );
      case 'YEARLY':
        final year = cursor.year + interval;
        final month = dtStart.month;
        return DateTime.utc(
          year,
          month,
          dtStart.day.clamp(1, _daysInMonth(year, month)),
        );
      default:
        return cursor.add(const Duration(days: 1));
    }
  }

  /// Rebuilds an occurrence's instant from a calendar [date] and [anchor]'s
  /// wall-clock time, in [anchor]'s own zone.
  ///
  /// The shape of the returned [DateTime] deliberately matches what
  /// [_parseIcsValue] produces for the same kind of value, so an occurrence and
  /// the DTSTART it came from stay directly comparable.
  DateTime _instantFor(_IcsDateTime anchor, DateTime date) {
    switch (anchor.kind) {
      case _ZoneKind.allDay:
        return DateTime(date.year, date.month, date.day);
      case _ZoneKind.utc:
        return DateTime.utc(
          date.year,
          date.month,
          date.day,
          anchor.hour,
          anchor.minute,
          anchor.second,
        );
      case _ZoneKind.zoned:
        return tz.TZDateTime(
          anchor.location!,
          date.year,
          date.month,
          date.day,
          anchor.hour,
          anchor.minute,
          anchor.second,
        ).toUtc();
      case _ZoneKind.floating:
        return DateTime(
          date.year,
          date.month,
          date.day,
          anchor.hour,
          anchor.minute,
          anchor.second,
        );
    }
  }

  /// Maps a plain BYDAY abbreviation (MO, TU, WE, TH, FR, SA, SU) to a
  /// 0-based offset from Monday.
  ///
  /// Fix 4: ordinal BYDAY values (e.g. 2MO, -1FR) contain digits and are
  /// NOT stripped — they are rejected by returning -1 so callers can skip
  /// them safely.
  int _weekdayOffset(String abbr) {
    const offsets = {
      'MO': 0,
      'TU': 1,
      'WE': 2,
      'TH': 3,
      'FR': 4,
      'SA': 5,
      'SU': 6,
    };
    // Reject ordinal values such as 2MO or -1FR (contain a digit).
    if (abbr.contains(RegExp(r'\d'))) return -1;
    return offsets[abbr] ?? -1;
  }

  Map<String, String> _parseRruleParams(String rrule) {
    final result = <String, String>{};
    for (final part in rrule.split(';')) {
      final idx = part.indexOf('=');
      if (idx == -1) continue;
      result[part.substring(0, idx).toUpperCase()] = part.substring(idx + 1);
    }
    return result;
  }

  int _daysInMonth(int year, int month) => DateTime(year, month + 1, 0).day;

  // ── Property parsing ──────────────────────────────────────────────────────

  /// Splits one unfolded content line into name, parameters and value.
  ///
  /// Parameter names are matched case-insensitively and quoted parameter values
  /// (`TZID="Australia/Perth"`) are unquoted, so a quoted zone containing a `:`
  /// or `;` cannot truncate the value.
  _IcsProperty? _parseProperty(String line) {
    var inQuotes = false;
    var colonIdx = -1;
    final separators = <int>[];

    for (var i = 0; i < line.length; i++) {
      final ch = line[i];
      if (ch == '"') {
        inQuotes = !inQuotes;
        continue;
      }
      if (inQuotes) continue;
      if (ch == ';') {
        separators.add(i);
        continue;
      }
      if (ch == ':') {
        colonIdx = i;
        break;
      }
    }

    // An unbalanced quote must not swallow the whole line.
    if (colonIdx == -1) {
      colonIdx = line.indexOf(':');
      if (colonIdx == -1) return null;
      separators.removeWhere((i) => i > colonIdx);
    }
    if (colonIdx == 0) return null;

    final nameEnd = separators.isEmpty ? colonIdx : separators.first;
    final name = line.substring(0, nameEnd).trim().toUpperCase();
    if (name.isEmpty) return null;

    final params = <String, String>{};
    for (var i = 0; i < separators.length; i++) {
      final start = separators[i] + 1;
      final end = i + 1 < separators.length ? separators[i + 1] : colonIdx;
      if (start >= end) continue;
      final part = line.substring(start, end);
      final eq = part.indexOf('=');
      if (eq == -1) continue;
      params[part.substring(0, eq).trim().toUpperCase()] = _unquoteParam(
        part.substring(eq + 1),
      );
    }

    return _IcsProperty(name, params, line.substring(colonIdx + 1));
  }

  /// True when [line] is a `BEGIN:`/`END:` component boundary.
  bool _isComponentBoundary(String line, String keyword) {
    return line.length > keyword.length &&
        line.substring(0, keyword.length).toUpperCase() == keyword;
  }

  String _unquoteParam(String value) {
    final trimmed = value.trim();
    if (trimmed.length >= 2 &&
        trimmed.startsWith('"') &&
        trimmed.endsWith('"')) {
      return trimmed.substring(1, trimmed.length - 1);
    }
    return trimmed;
  }

  /// Parses an ICS date/date-time value, KEEPING its source zone.
  ///
  /// Formats handled (ICS compact, not ISO 8601 with dashes):
  ///   VALUE=DATE:20240101        → all-day, a literal calendar date
  ///   20240101T120000Z           → UTC timed
  ///   TZID=America/New_York:...  → converted to the correct UTC instant
  ///   20240101T120000            → floating timed (device-local semantics)
  ///   20240101                   → date-only (no VALUE=DATE needed)
  ///
  /// [inherited] is the zone an unzoned value falls back to before
  /// [calendarFallback] and then device-local time. It is how a floating
  /// RECURRENCE-ID or EXDATE is read on its component's own clock; DTSTART
  /// itself passes none.
  ///
  /// [calendarFallback] is the caller-supplied calendar timezone context. It is
  /// null for every production caller, so the historical device-local behaviour
  /// below is unchanged; a caller that does declare one gets a floating feed
  /// rendered on the clock it was declared on.
  ///
  /// An unknown TZID falls through to [inherited], then [calendarFallback],
  /// then floating local time — this parser never fails an event over a zone it
  /// does not carry data for. That permissiveness is deliberate and is exactly
  /// why the result is NOT a canonical share identity; see
  /// `local_calendar_occurrence_identity.dart`.
  _IcsDateTime? _parseIcsValue(
    String rawValue,
    Map<String, String> params, {
    tz.Location? inherited,
    tz.Location? calendarFallback,
  }) {
    final value = rawValue.trim();
    if (value.isEmpty) return null;

    try {
      // 8-char value is always a date (covers VALUE=DATE and bare UNTIL dates).
      if (value.length == 8) {
        final year = int.parse(value.substring(0, 4));
        final month = int.parse(value.substring(4, 6));
        final day = int.parse(value.substring(6, 8));
        return _IcsDateTime(
          value: DateTime(year, month, day),
          kind: _ZoneKind.allDay,
          year: year,
          month: month,
          day: day,
        );
      }

      // Compact datetime: 20240101T120000Z or 20240101T120000
      if (value.length >= 15 && value[8] == 'T') {
        final year = int.parse(value.substring(0, 4));
        final month = int.parse(value.substring(4, 6));
        final day = int.parse(value.substring(6, 8));
        final hour = int.parse(value.substring(9, 11));
        final minute = int.parse(value.substring(11, 13));
        final second = int.parse(value.substring(13, 15));

        if (value.endsWith('Z')) {
          return _IcsDateTime(
            value: DateTime.utc(year, month, day, hour, minute, second),
            kind: _ZoneKind.utc,
            // Carried so an unzoned RECURRENCE-ID/EXDATE on a UTC component is
            // read on UTC's clock rather than the device's.
            location: tz.UTC,
            year: year,
            month: month,
            day: day,
            hour: hour,
            minute: minute,
            second: second,
          );
        }

        tz.Location? location;
        final tzid = params['TZID'];
        if (tzid != null && tzid.trim().isNotEmpty) {
          try {
            location = tz.getLocation(tzid.trim());
          } catch (_) {
            // Unknown TZID — fall through to the inherited zone, then floating.
            location = null;
          }
        }
        location ??= inherited;
        location ??= calendarFallback;

        if (location != null) {
          return _IcsDateTime(
            value: tz.TZDateTime(
              location,
              year,
              month,
              day,
              hour,
              minute,
              second,
            ).toUtc(),
            kind: _ZoneKind.zoned,
            location: location,
            year: year,
            month: month,
            day: day,
            hour: hour,
            minute: minute,
            second: second,
          );
        }

        return _IcsDateTime(
          value: DateTime(year, month, day, hour, minute, second),
          kind: _ZoneKind.floating,
          year: year,
          month: month,
          day: day,
          hour: hour,
          minute: minute,
          second: second,
        );
      }
    } catch (_) {
      return null;
    }

    return null;
  }

  // ── Helpers ───────────────────────────────────────────────────────────────

  String _stableEventId(
    LocalCalendarSubscription subscription,
    DateTime start,
    String? title,
  ) {
    return '${subscription.id}:${start.millisecondsSinceEpoch}:${title ?? ''}';
  }

  List<String> _unfoldLines(String body) {
    // RFC 5545: lines folded with CRLF (or LF) followed by a whitespace char.
    final unfolded = body
        .replaceAll('\r\n ', '')
        .replaceAll('\r\n\t', '')
        .replaceAll('\n ', '')
        .replaceAll('\n\t', '');
    return unfolded.split(RegExp(r'\r?\n')).where((l) => l.isNotEmpty).toList();
  }

  bool _inWindow(
    DateTime start,
    DateTime? end,
    DateTime windowStart,
    DateTime windowEnd,
  ) {
    final eventEnd = end ?? start;
    return eventEnd.isAfter(windowStart) && start.isBefore(windowEnd);
  }

  String _unescapeText(String value) {
    return value
        .replaceAll('\\n', '\n')
        .replaceAll('\\N', '\n')
        .replaceAll('\\,', ',')
        .replaceAll('\\;', ';')
        .replaceAll('\\\\', '\\');
  }

  String _normalizeUrl(String url) {
    if (url.startsWith('webcal://')) {
      return 'https://${url.substring('webcal://'.length)}';
    }
    return url;
  }
}

/// Which clock a parsed value belongs to, and therefore which clock the
/// recurrence rule that starts at it steps on.
enum _ZoneKind { allDay, utc, zoned, floating }

/// A parsed ICS date/date-time that keeps its SOURCE zone information.
///
/// [value] alone is enough to display a one-off event, but a recurring
/// wall-clock rule also needs the source wall-clock fields and the zone they
/// were written in.
class _IcsDateTime {
  const _IcsDateTime({
    required this.value,
    required this.kind,
    required this.year,
    required this.month,
    required this.day,
    this.hour = 0,
    this.minute = 0,
    this.second = 0,
    this.location,
  });

  /// The instant (or, for an all-day value, the literal calendar date).
  final DateTime value;
  final _ZoneKind kind;

  /// Source wall-clock fields, as written in the feed.
  final int year;
  final int month;
  final int day;
  final int hour;
  final int minute;
  final int second;

  /// The zone the value was written in, when one is known. Null for floating
  /// and all-day values.
  final tz.Location? location;

  bool get isAllDay => kind == _ZoneKind.allDay;
}

/// One unfolded ICS content line: `NAME;PARAM=value:VALUE`.
class _IcsProperty {
  const _IcsProperty(this.name, this.params, this.value);

  /// Upper-cased property name.
  final String name;

  /// Upper-cased parameter names mapped to unquoted values.
  final Map<String, String> params;

  /// Raw text after the value-separating colon.
  final String value;
}

/// One parsed VEVENT, before any event is emitted.
class _VeventComponent {
  _VeventComponent({required this.order});

  /// Parse order within the feed. Structurally separate from any source UID —
  /// it is only ever used to group a UID-less component with itself.
  final int order;

  /// Exact source UID, or null when absent/blank. Never normalised.
  String? uid;

  /// Trimmed UID kept ONLY to preserve the historical [LocalCalendarEvent.id]
  /// shape. Not source identity — see [uid].
  String? legacyBaseUid;

  String? summary;
  _IcsDateTime? dtStart;

  /// The raw, UNRESOLVED `DTSTART` property. The display fields above have
  /// already been through the legacy fallbacks, by which point a Windows TZID
  /// looks exactly like a real one, so the canonical layer reads this instead.
  /// Internal only: never surfaced in a widget model and never persisted.
  _IcsProperty? dtStartProperty;

  _IcsDateTime? dtEnd;
  String? rrule;
  final List<_IcsProperty> exdateLines = [];
  _IcsProperty? recurrenceIdProperty;
  String? status;
}

/// A detached component paired with the occurrence identity it names.
class _DetachedComponent {
  const _DetachedComponent(
    this.component,
    this.identity,
    this.identityInstant,
    this.canonical,
  );

  final _VeventComponent component;

  /// Display and reconciliation identity of the ORIGINAL occurrence, or null
  /// when the `RECURRENCE-ID` could not be interpreted.
  final String? identity;

  /// The parsed `RECURRENCE-ID` value behind [identity], used to rebuild the
  /// occurrence's historical UI id.
  final DateTime? identityInstant;

  /// What the STRICT layer makes of the same `RECURRENCE-ID`.
  final CanonicalValueResolution canonical;
}

/// One generated occurrence of a recurring master.
class _Occurrence {
  const _Occurrence(this.instant, this.identity, this.canonicalIdentity);

  final DateTime instant;

  /// Display and reconciliation identity.
  final String identity;

  /// Canonical Event Link recurrence identity, or null when the series cannot
  /// be canonically named.
  final String? canonicalIdentity;
}

class LocalCalendarIcsException implements Exception {
  const LocalCalendarIcsException(this.message);
  final String message;
  @override
  String toString() => message;
}
