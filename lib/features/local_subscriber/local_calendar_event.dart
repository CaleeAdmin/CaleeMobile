import 'local_calendar_occurrence_identity.dart';

/// One event shown for a phone-only ("Added on this phone only") calendar
/// subscription.
///
/// THREE distinct identity contracts live on this class and must not be
/// confused:
///
///  * [id] is the LOCAL UI key. It keeps its historical shape (the source UID
///    or a stable per-subscription fallback, suffixed with the occurrence's
///    milliseconds-since-epoch for a recurring occurrence) because widgets key
///    off it. It is not a cross-client identifier, and the
///    `calee.event-occurrence-identity` contract declares it non-normative.
///  * [uid] + [recurrenceId] are the SOURCE identity used for DISPLAY and for
///    reconciling a detached override against the occurrence it replaces.
///    [recurrenceId] keeps every legacy display fallback, so it is always
///    present for a recurring occurrence the parser could interpret — even one
///    whose zone this phone had to guess at.
///  * [uid] + [canonicalRecurrenceId] are the CANONICAL Event Link identity,
///    byte-compatible with Hub Core and CalEmbed. [canonicalRecurrenceId] is
///    null whenever the source cannot mint a portable identity, and
///    [canonicalStatus] says why.
///
/// The split is the same one Hub Core's event DTO carries, and it exists
/// because display parsing MAY guess while share identity MUST NOT: see
/// `local_calendar_occurrence_identity.dart` and
/// `contracts/event-occurrence-identity/v1/`.
class LocalCalendarEvent {
  const LocalCalendarEvent({
    required this.id,
    required this.subscriptionId,
    required this.subscriptionTitle,
    required this.title,
    required this.start,
    this.end,
    required this.isAllDay,
    required this.sourceUrl,
    this.uid,
    this.recurrenceId,
    this.recurring = false,
    this.canonicalRecurrenceId,
    this.canonicalStatus = CanonicalSourceStatus.noSourceUid,
  });

  /// Local UI key — stable across refreshes, unique within a fetch. See the
  /// class docs: this is NOT the cross-client occurrence identity.
  final String id;
  final String subscriptionId;
  final String subscriptionTitle;
  final String title;
  final DateTime start;
  final DateTime? end;
  final bool isAllDay;
  final String sourceUrl;

  /// The true source `UID`, preserved exactly as the feed wrote it, or null
  /// when the component carried no usable UID.
  ///
  /// Never a manufactured stand-in, never derived from a title or a date, and
  /// never run through a display sanitiser: `series  one` and `series one` are
  /// different series and must stay different identities.
  final String? uid;

  /// DISPLAY and reconciliation identity of THIS logical occurrence within the
  /// series, or null for a one-off event (and for a detached component whose
  /// `RECURRENCE-ID` could not be interpreted at all).
  ///
  ///  * all-day: `Ymd` (a literal calendar date, never timezone-converted)
  ///  * timed:   `YmdTHisZ` at the UTC instant the DISPLAY parser resolved
  ///
  /// For a detached (modified) occurrence this is the identity its
  /// `RECURRENCE-ID` names — the occurrence's ORIGINAL position — never a value
  /// derived from the moved `DTSTART`.
  ///
  /// This is the key an override is matched against, so it keeps the display
  /// parser's fallbacks: a feed naming an unknown timezone still reconciles on
  /// this phone. That is exactly why it is NOT the Event Link identity — see
  /// [canonicalRecurrenceId].
  final String? recurrenceId;

  /// Whether this event is an occurrence OF a recurring series.
  ///
  /// True for a generated occurrence and for a detached component carrying a
  /// `RECURRENCE-ID` — including one whose `RECURRENCE-ID` could not be
  /// interpreted, which is why this is not simply `recurrenceId != null`. False
  /// for a one-off, whose canonical identity is the calendar reference plus the
  /// source `UID` and carries no recurrence identity at all.
  ///
  /// It is the gate on minting a link: an occurrence of a series that cannot be
  /// named must not be minted, while a one-off does not need naming.
  final bool recurring;

  /// CANONICAL recurrence identity for a cross-client Event Link, or null when
  /// this source cannot mint one.
  ///
  /// Identical in shape to [recurrenceId], and identical in value whenever the
  /// source resolves canonically. It is null — and [canonicalStatus] says why —
  /// when the source named a timezone no database resolves, floated with no
  /// declared calendar timezone context, carried a malformed value, or had no
  /// usable `UID`. A guess is a local convenience for [recurrenceId] and a
  /// broken link for this field, so this one fails closed.
  ///
  /// Null for a non-recurring event: its identity is the calendar reference
  /// plus the source `UID`, and moving its `DTSTART` must not change it. Null
  /// too whenever the component carries no source `UID`, so this field is never
  /// a recurrence identity nothing can be paired with.
  final String? canonicalRecurrenceId;

  /// Status of the SOURCE COMPONENT this occurrence came from — one of
  /// [CanonicalSourceStatus.values].
  ///
  /// It answers "could this component be canonically placed", which is what a
  /// future mint endpoint has to report to a user, and is the same question
  /// Hub Core's `client_caldav_canonical_source_identity()` answers. It is NOT
  /// the mintability test: a detached override moved onto an unresolvable zone
  /// reports `unsupported_tzid` here and still names its occurrence from
  /// `RECURRENCE-ID`. Use `canonicalEventLinkIdentity()` to decide mintability.
  ///
  /// Defaults to [CanonicalSourceStatus.noSourceUid]: an event built by hand
  /// (a widget fixture, say) has no source component behind it.
  final String canonicalStatus;
}
