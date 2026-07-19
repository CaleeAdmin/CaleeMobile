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
int notificationIdForEvent(ClientEvent event, {String? ownerKey}) {
  final identity = '${event.id}|${event.occurrenceId ?? ''}|${event.startsAt}';
  final key = ownerKey == null ? identity : '$ownerKey|$identity';
  return _fnv1a32(key, _fnvOffsetBasis) & 0x7FFFFFFF;
}

/// Owner-key scheme tag (algorithm + version). Embedded in the key itself so the
/// algorithm is explicit metadata, never inferred from the string length.
const String kReminderOwnerKeyScheme = 'v4';

/// Domain-separated namespace for the v4 owner-key derivation. The trailing NUL
/// separates the fixed namespace from the variable account ID so no two
/// (namespace, id) pairs can collide by concatenation.
const String _ownerKeyV4Namespace = 'calee-calendar-reminder-owner-v4\u0000';

/// Matches a v4 owner-key token: the scheme tag, a colon, then the 64-char
/// lowercase-hex SHA-256 digest. Used to validate persisted owner keys by
/// algorithm/version rather than by length alone.
final RegExp _ownerKeyV4Pattern = RegExp(r'^v4:[0-9a-f]{64}$');

/// Derives a deterministic, cryptographic owner key from a raw [accountId].
///
/// `ownerKey = "v4:" + SHA-256(namespace + accountId)` (64 lowercase hex chars,
/// 67 with the scheme tag). SHA-256 is a cryptographic hash, so the digest is
/// deterministic for the same account (stable across launches), distinct across
/// accounts, and the raw account ID is never persisted or folded verbatim into a
/// notification ID. This replaces the previous two-pass 32-bit FNV-1a
/// concatenation, which was NOT cryptographic (FNV is a fast non-cryptographic
/// hash) and only 64 bits wide.
///
/// Output length / collision trade-off: the full 256-bit digest (64 hex) makes
/// an accidental cross-account collision negligible (~2^-128 birthday bound).
///
/// PRIVACY LIMITATION (documented, per design): this is a *namespaced* digest,
/// not a keyed one. If the account-ID space is small/enumerable, an offline
/// attacker who can guess candidate account IDs can confirm a match by
/// recomputing this digest (a plain digest cannot hide a low-entropy input).
/// For that threat model the stronger derivation is
/// `HMAC-SHA-256(per-install secret, namespace + accountId)` with the secret
/// stored in the platform keystore (`flutter_secure_storage`) — recommended as a
/// follow-up when the reminder session can resolve the secret asynchronously.
/// The v4 scheme tag lets such an upgrade coexist with, and supersede, these
/// keys without inferring the algorithm from length.
///
/// Throws [ArgumentError] on an empty [accountId]: an empty account must never
/// own reminders (see the reminder session lifecycle).
String reminderOwnerKey(String accountId) {
  if (accountId.isEmpty) {
    throw ArgumentError.value(accountId, 'accountId', 'must be non-empty');
  }
  final digest = sha256.convert(utf8.encode('$_ownerKeyV4Namespace$accountId'));
  return '$kReminderOwnerKeyScheme:$digest';
}

/// Whether [value] is a well-formed v4 owner-key token (scheme + 64-hex digest).
/// Persisted owner keys that do not match (e.g. legacy FNV keys, or corrupt
/// values) are recognised as NOT current-scheme owner keys.
bool isV4OwnerKey(String value) => _ownerKeyV4Pattern.hasMatch(value);

/// A deterministic, privacy-safe fingerprint of everything that affects the
/// notification a [candidate] would schedule.
///
/// The manifest stores only this digest — never the raw title, location,
/// description, calendar URL, or any credential — so schedule-relevant changes
/// (e.g. a title-only edit that keeps the same [notificationIdForEvent]) can be
/// detected and the existing notification replaced, without persisting private
/// event content. The digest is stable across app launches for the same
/// schedule because it is built from absolute instants and server-stable
/// identity strings, not runtime object identity or `hashCode`.
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
  final canonical = [
    'v3',
    'owner=${candidate.ownerKey ?? ''}',
    'id=${candidate.notificationId}',
    'trigger=$trigger',
    'start=$start',
    'eid=${event.id}',
    'oid=${event.occurrenceId ?? ''}',
    'cid=${event.calendarId}',
    'sa=${event.startsAt}',
    'title=${event.title}',
  ].join('');

  // Two independent 32-bit FNV-1a passes concatenated into a 64-bit hex digest:
  // a collision would have to occur in both passes at once (~1/2^64), while
  // avoiding negative-integer / web-int hazards of a single 64-bit pass.
  final a = _fnv1a32(canonical, _fnvOffsetBasis);
  final b = _fnv1a32(canonical, _fnvAltOffsetBasis);
  return a.toRadixString(16).padLeft(8, '0') +
      b.toRadixString(16).padLeft(8, '0');
}

// Standard 32-bit FNV-1a offset basis, and a second, distinct basis used to
// widen the fingerprint to 64 effective bits.
const int _fnvOffsetBasis = 0x811c9dc5;
const int _fnvAltOffsetBasis = 0x7a3c59b1;
const int _fnvPrime = 0x01000193;

/// 32-bit FNV-1a over [input]'s UTF-16 code units, seeded with [offsetBasis].
/// Deterministic and reversibility-free — suitable for a persisted fingerprint.
int _fnv1a32(String input, int offsetBasis) {
  var hash = offsetBasis;
  for (final codeUnit in input.codeUnits) {
    hash ^= codeUnit;
    hash = (hash * _fnvPrime) & 0xFFFFFFFF;
  }
  return hash;
}
