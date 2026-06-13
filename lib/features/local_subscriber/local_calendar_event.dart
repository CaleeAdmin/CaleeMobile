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
  });

  final String id;
  final String subscriptionId;
  final String subscriptionTitle;
  final String title;
  final DateTime start;
  final DateTime? end;
  final bool isAllDay;
  final String sourceUrl;
}
