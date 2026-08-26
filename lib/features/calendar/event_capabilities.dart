/// What a signed-in user may DO with one exact calendar event, and the exact
/// context a details surface needs to describe it
/// (CaleeAdmin/CaleeMobile#566).
///
/// This file exists because the three questions below were previously
/// answered in different places, in a fixed order, with one able to suppress
/// another:
///
///  * may this event be EDITED/DELETED — a permission question about the
///    calendar it lives on;
///  * may this event be SHARED as a public Event Link — a PUBLICATION
///    question about the source the calendar was published from;
///  * what should the user be TOLD about where it came from.
///
/// They are independent. A private family event is writable and unshareable.
/// A followed public club calendar is read-only and shareable. A club admin's
/// own public calendar is BOTH — the combination the previous routing could
/// not express at all, because it returned as soon as it found the event
/// writable and never reached the share decision.
///
/// So they are computed here, together, from the exact [ClientEvent] and the
/// exact [ClientCalendar] it was read from — never from [CalendarDisplayEvent],
/// which is a presentation model shared with the signed-out calendar and
/// carries neither source identity nor permission.
///
/// Nothing here is a new rule. Mutation eligibility is the same expression the
/// calendar page has always used, deliberately NOT replaced by
/// `calendar.capabilities.canEditEvents`: that field fails closed on an older
/// Hub that predates it (see [CalendarCapabilities.fallback]) while legacy
/// writable calendars still work, so switching to it would silently take Edit
/// away from working accounts. Share eligibility is
/// [signedInEventShareState] unchanged, gates and all.
library;

import 'package:flutter/foundation.dart';

import '../../data/models/client_calendar.dart';
import 'shared/calendar_display_event.dart';
import 'shared/event_share_action.dart';
import 'signed_in_event_share.dart';

/// Everything one details surface needs about one tapped event.
///
/// [event] and [calendar] are the EXACT objects the row was built from, held
/// so a later refresh cannot make an action resolve to a different row.
/// [display] is presentation-ready values only.
///
/// Extension point for CaleeAdmin/CaleeMobile#564: authoritative publisher /
/// organisation provenance attaches HERE, as additional fields populated from
/// the contract that issue defines. It must not be inferred from the calendar
/// name, the subscription URL, the hostname, `readOnly`, `source` or the
/// account's signed-in state — none of which say anything about who published
/// a calendar.
@immutable
class EventDetailsContext {
  const EventDetailsContext({
    required this.event,
    required this.calendar,
    required this.display,
    required this.capabilities,
  });

  final ClientEvent event;

  /// Null when the controller could not resolve which calendar this event was
  /// read from. Such an event has no provable source, so every capability
  /// below fails closed.
  final ClientCalendar? calendar;

  final CalendarDisplayEvent display;
  final EventCapabilities capabilities;
}

/// The three independent answers, plus the wording that goes with them.
@immutable
class EventCapabilities {
  const EventCapabilities({
    required this.canEdit,
    required this.canDelete,
    required this.isReadOnlyInCalee,
    required this.shareState,
    required this.readOnlyNote,
  });

  /// Whether CaleeMobile may open its existing editor for this event.
  final bool canEdit;

  /// Whether CaleeMobile may run its existing delete flow for this event.
  ///
  /// Equal to [canEdit] today, and kept separate rather than aliased: they are
  /// different permissions and a backend that separates them should not need
  /// this type changed.
  final bool canDelete;

  /// Whether Calee itself cannot change this event — the fact the details
  /// surface explains to the user. NOT a statement about publication: a
  /// private Google feed is read-only and a public club calendar can be
  /// writable, so this must never be consulted to decide sharing.
  final bool isReadOnlyInCalee;

  /// The public Event Link decision for this exact occurrence, from the
  /// unchanged strict source validation and canonical occurrence identity.
  final SignedInEventShareState shareState;

  /// Truthful, source-appropriate wording for a read-only event, or null when
  /// the event is editable in Calee.
  ///
  /// Never claims Calee can open or edit the event somewhere else: Calee has
  /// no authoritative per-event provider deep link, so offering one would be
  /// an invented URL.
  final String? readOnlyNote;

  bool get canShare =>
      shareState.availability == LocalEventShareAvailability.available;
}

/// Google's own read-only wording. Calee's Google integration reads events; it
/// cannot write them and has no per-event Google URL, so the copy says exactly
/// that and offers nothing further.
const String kGoogleReadOnlyNote =
    'This event is from Google Calendar and is read-only in Calee.';

/// Source-neutral wording for any other read-only calendar — Outlook, a school
/// or club feed, an arbitrary subscribed `.ics`.
const String kExternalReadOnlyNote =
    'This event is from a read-only calendar. '
    'Changes must be made in the original calendar.';

/// Wording when the event's calendar could not be resolved at all. Says only
/// what is known to be true, and invents no provider or publisher.
const String kUnknownSourceReadOnlyNote = 'This event is read-only in Calee.';

/// Resolves the complete capability set for [event] as read from [calendar].
EventCapabilities resolveEventCapabilities({
  required ClientEvent event,
  required ClientCalendar? calendar,
}) {
  // The EXISTING mutation rule, unchanged. An unresolvable calendar fails
  // closed here, which is why a null calendar can never be editable.
  final isReadOnlyInCalee =
      calendar == null ||
      calendar.readOnly ||
      calendar.isExternal ||
      event.isReadOnly;

  return EventCapabilities(
    canEdit: !isReadOnlyInCalee,
    canDelete: !isReadOnlyInCalee,
    isReadOnlyInCalee: isReadOnlyInCalee,
    // Computed INDEPENDENTLY, and in particular not skipped when the event
    // turns out to be writable.
    shareState: signedInEventShareState(event, calendar),
    readOnlyNote: isReadOnlyInCalee ? _readOnlyNote(event, calendar) : null,
  );
}

String _readOnlyNote(ClientEvent event, ClientCalendar? calendar) {
  if (event.isGoogleEvent || (calendar?.isGoogleCalendar ?? false)) {
    return kGoogleReadOnlyNote;
  }
  if (calendar == null) return kUnknownSourceReadOnlyNote;
  return kExternalReadOnlyNote;
}
