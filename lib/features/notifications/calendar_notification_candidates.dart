import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../../data/models/client_calendar.dart';

class CalendarNotificationCandidate {
  const CalendarNotificationCandidate({
    required this.event,
    required this.reminderTime,
    required this.startLocal,
    required this.notificationId,
    this.ownerKey,
  });

  final ClientEvent event;
  final DateTime reminderTime;
  final DateTime startLocal;
  final int notificationId;

  /// Privacy-safe digest of the account this candidate's notification belongs
  /// to, or `null` for the account-agnostic (legacy/test) path. Folded into the
  /// notification ID and schedule fingerprint so identical events under
  /// different accounts never collide.
  final String? ownerKey;

  /// Returns a copy with [notificationId] replaced. Used by collision
  /// resolution to record a deterministically-probed ID without mutating the
  /// immutable candidate.
  CalendarNotificationCandidate copyWith({int? notificationId}) =>
      CalendarNotificationCandidate(
        event: event,
        reminderTime: reminderTime,
        startLocal: startLocal,
        notificationId: notificationId ?? this.notificationId,
        ownerKey: ownerKey,
      );
}

/// Default number of days to look ahead when selecting reminder candidates.
///
/// Reminders are scheduled from an independent upcoming-event window rather
/// than the calendar month currently on screen, so this horizon is what bounds
/// how far ahead reminders are pre-scheduled on the device.
const Duration kCalendarReminderHorizon = Duration(days: 30);

/// Returns events eligible for a local reminder notification, sorted by
/// ascending reminder time so the earliest reminders are selected first.
///
/// Pure function — no platform or I/O dependencies.
///
/// Skips:
/// * all-day events (all-day reminder behaviour is out of scope),
/// * events with an unparseable [ClientEvent.startsAt],
/// * events whose reminder time has already passed,
/// * events starting beyond [horizon].
///
/// When [maxCandidates] is provided, the list is sorted first and only then
/// truncated, so the earliest-firing reminders are always the ones kept.
///
/// The [notificationId] on each returned candidate is the *initial* (probe-0)
/// SHA-256-derived ID. Collision-free final IDs are assigned by
/// [allocateNotificationIds] once the selected set is known, so two candidates
/// whose initial IDs collide both survive with distinct IDs.
List<CalendarNotificationCandidate> buildNotificationCandidates(
  List<ClientEvent> events, {
  required DateTime now,
  Duration reminderOffset = const Duration(minutes: 10),
  Duration horizon = kCalendarReminderHorizon,
  int? maxCandidates,
  String? ownerKey,
}) {
  final cutoff = now.add(horizon);
  final result = <CalendarNotificationCandidate>[];

  for (final event in events) {
    if (event.allDay) continue;

    final startLocal = DateTime.tryParse(event.startsAt)?.toLocal();
    if (startLocal == null) continue;

    final reminderTime = startLocal.subtract(reminderOffset);
    if (!reminderTime.isAfter(now)) continue;
    if (startLocal.isAfter(cutoff)) continue;

    result.add(
      CalendarNotificationCandidate(
        event: event,
        reminderTime: reminderTime,
        startLocal: startLocal,
        notificationId: notificationIdForEvent(event, ownerKey: ownerKey),
        ownerKey: ownerKey,
      ),
    );
  }

  // Earliest reminders first. When more than the maximum are eligible, the
  // maximum is applied only after sorting so the soonest reminders win.
  result.sort((a, b) => a.reminderTime.compareTo(b.reminderTime));
  if (maxCandidates != null && result.length > maxCandidates) {
    return result.sublist(0, maxCandidates);
  }
  return result;
}

// ── Notification-ID collision resolution ──────────────────────────────────────

/// The largest notification ID we ever produce — the non-negative signed 31-bit
/// range required by the platform notification plugins.
const int kMaxNotificationId = 0x7FFFFFFF;

/// Upper bound on deterministic probe attempts when resolving a notification-ID
/// collision. With SHA-256 identities a real collision is astronomically
/// unlikely, so this bound is defensive: it exists only so a pathological input
/// (or a forced test collision) reports failure instead of looping forever.
const int kMaxNotificationIdProbes = 64;

/// Derives a candidate's notification ID for a given [probe] attempt. Injected
/// in tests so collisions can be forced deterministically without brute-forcing
/// SHA-256 pre-images. `probe == 0` must return the candidate's base ID (the
/// one [notificationIdForEvent] would produce).
typedef NotificationIdDerivation =
    int Function(CalendarNotificationCandidate candidate, int probe);

/// The outcome of assigning collision-free notification IDs to a candidate set.
///
/// Log-safe: holds only candidates (which carry no raw private content in this
/// structure's own fields) and counts.
class NotificationIdAllocation {
  const NotificationIdAllocation({
    required this.candidates,
    required this.collisionsResolved,
    required this.unresolved,
  });

  /// Candidates with their final, collision-free [notificationId], preserving
  /// the input (reminder-time) ordering so the earliest candidates keep
  /// priority for their base ID.
  final List<CalendarNotificationCandidate> candidates;

  /// How many candidates needed a probe greater than zero to avoid colliding
  /// with an already-allocated ID.
  final int collisionsResolved;

  /// Candidates that could not be allocated a unique ID within the probe limit.
  /// Never silently dropped: the caller must surface this as a failure.
  final List<CalendarNotificationCandidate> unresolved;

  bool get hasUnresolved => unresolved.isNotEmpty;
}

/// Assigns a unique 31-bit notification ID to every candidate in
/// [sortedCandidates] (assumed already ordered by reminder time), resolving
/// collisions deterministically.
///
/// Process (see also [NotificationIdAllocation]):
///   1. Pre-occupy every ID in [reservedIds] so no candidate is ever assigned
///      one — these are IDs still owned on the device by another account, or by
///      an ownerless legacy entry, that this pass must not overwrite.
///   2. Walk candidates in priority order (earliest reminder first).
///   3. Compute the initial (probe-0) SHA-256 identity ID.
///   4. If it is already taken — by [reservedIds] or by an earlier candidate —
///      probe with `probe = 1, 2, …` (each probe hashes the same identity plus
///      the probe index) until an unused ID is found.
///   5. Stop at [maxProbes]; a candidate that exhausts its probes is reported in
///      [NotificationIdAllocation.unresolved] rather than silently overwriting
///      another candidate or a reserved ID (the Defect-6 map-overwrite hazard).
///
/// Deterministic: identical inputs always produce identical IDs, and the
/// earliest candidate always keeps its base ID (unless that base ID is
/// reserved, in which case it probes to the next free ID). An existing
/// current-owner ID for the same occurrence is safely reused because such IDs
/// are deliberately NOT reserved by the caller.
NotificationIdAllocation allocateNotificationIds(
  List<CalendarNotificationCandidate> sortedCandidates, {
  Set<int> reservedIds = const <int>{},
  int maxProbes = kMaxNotificationIdProbes,
  NotificationIdDerivation? idDerivation,
}) {
  final used = <int>{...reservedIds};
  final resolved = <CalendarNotificationCandidate>[];
  final unresolved = <CalendarNotificationCandidate>[];
  var collisions = 0;

  for (final candidate in sortedCandidates) {
    int? chosen;
    for (var probe = 0; probe <= maxProbes; probe++) {
      final id = idDerivation != null
          ? (idDerivation(candidate, probe) & kMaxNotificationId)
          : _notificationIdForIdentity(
              _notificationIdentity(candidate.event, candidate.ownerKey),
              probe,
            );
      if (used.add(id)) {
        chosen = id;
        if (probe > 0) collisions++;
        break;
      }
    }
    if (chosen == null) {
      // Probe limit exhausted — do not overwrite an existing candidate's ID or a
      // reserved (foreign/legacy) ID.
      unresolved.add(candidate);
      continue;
    }
    resolved.add(candidate.copyWith(notificationId: chosen));
  }

  return NotificationIdAllocation(
    candidates: resolved,
    collisionsResolved: collisions,
    unresolved: unresolved,
  );
}

// ── Privacy-safe SHA-256 digests ──────────────────────────────────────────────

/// Derives a stable 31-bit notification ID from an event's identity fields,
/// scoped to the owning account.
///
/// Recurring occurrences differ by [ClientEvent.occurrenceId] and/or
/// [ClientEvent.startsAt], so each occurrence gets a stable, distinct ID. When
/// [ownerKey] is provided it is folded into the input so identical events under
/// two different accounts produce different IDs — preventing one account's
/// reminders from being interpreted as another's on a shared device. A `null`
/// [ownerKey] preserves the historical account-agnostic ID (used by legacy
/// data and account-independent tests).
///
/// This is the *initial* (probe-0) ID; on the rare event of two candidates
/// sharing it, [allocateNotificationIds] resolves the collision.
int notificationIdForEvent(ClientEvent event, {String? ownerKey}) =>
    _notificationIdForIdentity(_notificationIdentity(event, ownerKey), 0);

/// Derives a deterministic, privacy-safe owner key from a raw [accountId].
///
/// The key is an **unkeyed** SHA-256 digest of a fixed schema tag plus the raw
/// [accountId]. Its security properties, stated accurately:
///
/// * The raw account ID is **not persisted** — neither in the manifest nor
///   folded verbatim into a notification ID; only this digest is stored.
/// * The digest is **deterministic**: the same account ID always yields the
///   same key (stable across app launches), and different account IDs yield
///   different keys, which is what lets a shared device keep accounts' reminders
///   isolated.
/// * This is a one-way hash, **not encryption**: it cannot be "decrypted", but
///   because it is unkeyed and deterministic it is not a secret-preserving
///   transform either.
/// * A **low-entropy account ID** (e.g. a small integer, an email, or any
///   guessable value) is therefore susceptible to **offline guessing**: an
///   attacker who obtains the stored digest can confirm a candidate account ID
///   by hashing it and comparing, since no per-install secret is mixed in.
/// * The recommended stronger future design is a **per-install HMAC-SHA-256**
///   keyed with a random secret held only in secure storage, so the stored key
///   cannot be brute-forced offline from a guessed account ID. That migration is
///   intentionally out of scope here and is NOT implemented by this function.
///
/// Returned as lowercase hexadecimal (64 characters).
///
/// Throws an [ArgumentError] for an empty or whitespace-only [accountId]: an
/// owner key must never be derived from a missing/blank identity (which would
/// collapse every unauthenticated caller onto one shared owner). Callers that
/// may hold an absent ID must gate on [isValidReminderAccountId] or use
/// [tryReminderOwnerKey] instead of relying on this throwing.
String reminderOwnerKey(String accountId) {
  if (!isValidReminderAccountId(accountId)) {
    throw ArgumentError.value(
      accountId,
      'accountId',
      'reminderOwnerKey requires a non-empty, non-whitespace account ID',
    );
  }
  return _sha256Hex('$_ownerSchema\x00$accountId');
}

/// Whether [accountId] is a usable reminder identity: non-null and not blank
/// once surrounding whitespace is trimmed. An owner key, an active reminder
/// session, and a reminder refresh must all require a valid identity, so a
/// missing or temporarily-unavailable bootstrap never creates a bogus owner.
bool isValidReminderAccountId(String? accountId) =>
    accountId != null && accountId.trim().isNotEmpty;

/// The owner key for [accountId], or `null` when the ID is missing or blank.
///
/// Prefer this at call sites where the account ID may be absent or only
/// temporarily available (e.g. bootstrap not yet loaded): it returns `null`
/// rather than throwing, so an invalid identity is skipped instead of crashing
/// the UI or fabricating an empty-account owner.
String? tryReminderOwnerKey(String? accountId) =>
    isValidReminderAccountId(accountId) ? reminderOwnerKey(accountId!) : null;

/// A deterministic, privacy-safe fingerprint of everything that affects the
/// notification a [candidate] would schedule.
///
/// The manifest stores only this digest — never the raw title, location,
/// description, calendar URL, or any credential — so schedule-relevant changes
/// (e.g. a title-only edit that keeps the same [notificationIdForEvent]) can be
/// detected and the existing notification replaced, without persisting private
/// event content. The digest is a one-way SHA-256 hash of absolute instants and
/// server-stable identity strings, stable across app launches for the same
/// schedule and independent of runtime object identity or `hashCode`. Returned
/// as lowercase hexadecimal (64 characters).
///
/// Inputs (all of which change the scheduled notification):
/// * the owning account key;
/// * the notification ID;
/// * the reminder trigger instant;
/// * the rendered body inputs (event title and local start instant);
/// * the payload identity fields (event/occurrence/calendar);
/// * the event start value.
String scheduleFingerprint(CalendarNotificationCandidate candidate) {
  final event = candidate.event;
  // Absolute instants (UTC microseconds) keep the digest independent of how
  // local time happens to be formatted for display.
  final trigger = candidate.reminderTime.toUtc().microsecondsSinceEpoch;
  final start = candidate.startLocal.toUtc().microsecondsSinceEpoch;
  final canonical = <String>[
    'owner=${candidate.ownerKey ?? ''}',
    'id=${candidate.notificationId}',
    'trigger=$trigger',
    'start=$start',
    'eid=${event.id}',
    'oid=${event.occurrenceId ?? ''}',
    'cid=${event.calendarId}',
    'sa=${event.startsAt}',
    'title=${event.title}',
  ].join('\x00');
  return _sha256Hex('$_scheduleSchema\x00$canonical');
}

// Schema prefixes and canonicalisation. Each digest input starts with a
// versioned schema tag and uses explicit NUL (\x00) field separators over
// UTF-8 bytes, so no field boundary can be forged by concatenation and the
// schema can be evolved without ambiguity.
const String _ownerSchema = 'calee-reminder-owner-v1';
const String _scheduleSchema = 'calee-reminder-schedule-v1';
const String _notificationSchema = 'calee-reminder-notification-v1';

/// Server-stable identity of an event occurrence (never raw private content
/// beyond identifiers the payload already carries).
String _eventIdentity(ClientEvent event) =>
    '${event.id}|${event.occurrenceId ?? ''}|${event.startsAt}';

/// Canonical notification-identity input: schema, owner key, event identity.
String _notificationIdentity(ClientEvent event, String? ownerKey) =>
    '$_notificationSchema\x00${ownerKey ?? ''}\x00${_eventIdentity(event)}';

/// Reduces a notification identity (optionally with a probe index) to a
/// non-negative 31-bit ID via the leading bytes of its SHA-256 digest.
int _notificationIdForIdentity(String identity, int probe) {
  final input = probe == 0 ? identity : '$identity\x00probe=$probe';
  final bytes = sha256.convert(utf8.encode(input)).bytes;
  final value =
      (bytes[0] << 24) | (bytes[1] << 16) | (bytes[2] << 8) | bytes[3];
  return value & kMaxNotificationId;
}

/// SHA-256 of [canonical]'s UTF-8 bytes as lowercase hexadecimal (64 chars).
/// One-way and reversibility-free — suitable for a persisted privacy digest.
String _sha256Hex(String canonical) =>
    sha256.convert(utf8.encode(canonical)).toString();
