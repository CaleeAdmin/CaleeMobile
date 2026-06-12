class CalendarFollowIntent {
  const CalendarFollowIntent({required this.token, required this.sourceUri});

  final String token;
  final Uri sourceUri;
}

class ResolvedCalendarFollowIntent {
  ResolvedCalendarFollowIntent({
    required this.title,
    required this.url,
    required this.source,
    this.expiresAt,
  });

  final String title;
  final String url;
  final String source;
  final DateTime? expiresAt;
}
