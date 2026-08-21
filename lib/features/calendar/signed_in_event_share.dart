/// Whether ONE signed-in Hub event may be shared as a public Event Link, and
/// with exactly which values (CaleeAdmin/CaleeMobile#559).
///
/// This is the signed-in twin of the eligibility rule the signed-out page
/// applies in `local_subscriber_calendar_page.dart`, and it deliberately
/// reaches the SAME answer for the same logical occurrence. Only the inputs
/// differ: a signed-out phone reads a `LocalCalendarEvent` it parsed itself, a
/// signed-in phone reads a `ClientEvent` Hub already resolved. Both end in one
/// [LocalEventShareTarget], handed to the one mint service.
///
/// Two independent gates, in this order:
///
///  1. the SOURCE must be an already-public Calee calendar. That is decided
///     ONLY by [ClientCalendar.isSubscription] plus
///     [CaleePublicCalendarSource.tryParse] over the stored
///     [ClientCalendar.subscriptionUrl]. It is NOT decided by
///     [ClientCalendar.readOnly], `source`, `serviceId`, `providerKey` or
///     `accessMode`: those describe how a calendar behaves in the app, and a
///     private Google feed is read-only too. Publication is a property of the
///     URL, so the URL is what is checked;
///
///  2. the OCCURRENCE must carry the canonical identity Hub computed for it —
///     [ClientEvent.sourceUid], plus [ClientEvent.canonicalRecurrenceId] when
///     the event recurs.
///
/// Nothing here rebuilds a canonical identity. Hub Core already did that under
/// CaleeAdmin/calee-hub-core#420/#421 and CalEmbed re-derives the same values
/// from the same public feed; a third implementation in Dart would be a third
/// thing that has to agree forever.
library;

import '../../data/models/client_calendar.dart';
import '../local_subscriber/calee_public_calendar_source.dart';
import '../local_subscriber/local_calendar_occurrence_identity.dart';
import '../local_subscriber/local_event_details_sheet.dart';

/// The share decision for one signed-in event.
///
/// [target] is non-null exactly when [availability] is
/// [LocalEventShareAvailability.available].
typedef SignedInEventShareState = ({
  LocalEventShareAvailability availability,
  LocalEventShareTarget? target,
});

const SignedInEventShareState _unsupportedSource = (
  availability: LocalEventShareAvailability.unsupportedSource,
  target: null,
);

const SignedInEventShareState _unavailableForEvent = (
  availability: LocalEventShareAvailability.unavailableForEvent,
  target: null,
);

/// Whether [event], as read from [calendar], may be shared — and with what.
///
/// [calendar] is nullable because [CalendarController.calendarForEvent] can
/// legitimately fail to resolve one. An event whose calendar is unknown has no
/// provable source, so it is refused rather than assumed public.
SignedInEventShareState signedInEventShareState(
  ClientEvent event,
  ClientCalendar? calendar,
) {
  // Gate 1a: only a followed subscription can be an already-public calendar.
  // A URL alone is not enough — a row that stores a subscriptionUrl but is not
  // actually a subscription is not a published feed.
  if (calendar == null || !calendar.isSubscription) return _unsupportedSource;

  // Gate 1b: the exact strict validator the signed-out path uses, over the
  // exact stored URL. Reused rather than reimplemented so a host, path or
  // token spelling can never be accepted on one screen and refused on the
  // other — and so a private feed's URL is never assembled into a request at
  // all.
  final source = CaleePublicCalendarSource.tryParse(calendar.subscriptionUrl);
  if (source == null) return _unsupportedSource;

  // Gate 2a: a usable source UID must be PRESENT. canonicalSourceUid() decides
  // presence by trimming but returns the ORIGINAL value, so ` uid ` is present
  // and is still ` uid `, and the literal `0` is present rather than falsy.
  final uid = canonicalSourceUid(event.sourceUid);
  if (uid == null) return _unavailableForEvent;

  // Gate 2b: a recurring occurrence is named by its canonical recurrence
  // identity or not at all. Hub emits null when it could not name the
  // occurrence portably (an unresolvable TZID, a floating value with no
  // context), and guessing one here would hand a recipient an identity no
  // other client can reproduce.
  final recurrenceId = event.recurring
      ? _presentOrNull(event.canonicalRecurrenceId)
      : null;
  if (event.recurring && recurrenceId == null) return _unavailableForEvent;

  return (
    availability: LocalEventShareAvailability.available,
    target: LocalEventShareTarget(
      source: source,
      // Byte for byte as Hub sent it.
      uid: uid,
      // Null for a one-off, so the mint request OMITS the key entirely.
      // Contract §1: moving a non-recurring event must not change its
      // identity, so its startsAt never enters this.
      occurrenceId: recurrenceId,
    ),
  );
}

/// [value] when it carries something, or null when it is absent or blank.
///
/// Presence only. A canonical recurrence identity is `Ymd` or `YmdTHisZ` and
/// carries no whitespace, so a blank one is a Hub that had nothing to say —
/// but the value returned is still the untrimmed original, because this
/// function must never be the place a transmitted identity quietly changes.
String? _presentOrNull(String? value) {
  if (value == null) return null;
  return value.trim().isEmpty ? null : value;
}
