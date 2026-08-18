/// One event shown for a phone-only ("Added on this phone only") calendar
/// subscription.
///
/// Two distinct identity contracts live on this class and must not be confused:
///
///  * [id] is the LOCAL UI key. It keeps its historical shape (the source UID
///    or a stable per-subscription fallback, suffixed with the occurrence's
///    milliseconds-since-epoch for a recurring occurrence) because widgets key
///    off it. It is not a cross-client identifier.
///  * [uid] + [recurrenceId] are the SOURCE identity of the logical occurrence.
///    They are the pair a cross-client event reference is built from, and they
///    are byte-compatible with the Hub Core and CalEmbed contracts.
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

  /// Canonical identity of THIS logical occurrence within the series, or null
  /// for a one-off event.
  ///
  ///  * all-day: `Ymd` (a literal calendar date, never timezone-converted)
  ///  * timed:   `YmdTHisZ` at the TRUE UTC instant
  ///
  /// For a detached (modified) occurrence this is the identity its
  /// `RECURRENCE-ID` names — the occurrence's ORIGINAL position — never a value
  /// derived from the moved `DTSTART`.
  final String? recurrenceId;
}
