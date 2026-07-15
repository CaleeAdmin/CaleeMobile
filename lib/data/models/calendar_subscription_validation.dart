class CalendarSubscriptionPreview {
  const CalendarSubscriptionPreview({
    this.displayName,
    this.sourceHost,
    this.provider,
    this.eventCount,
  });

  factory CalendarSubscriptionPreview.fromJson(Map<String, dynamic> json) {
    return CalendarSubscriptionPreview(
      displayName: json['displayName'] as String?,
      sourceHost: json['sourceHost'] as String?,
      provider: json['provider'] as String?,
      eventCount: json['eventCount'] as int?,
    );
  }

  final String? displayName;
  final String? sourceHost;
  final String? provider;
  final int? eventCount;
}

class CalendarSubscriptionValidationResult {
  const CalendarSubscriptionValidationResult({
    required this.valid,
    this.normalizedUrl,
    this.message,
    this.errorCode,
    this.preview,
  });

  factory CalendarSubscriptionValidationResult.fromJson(
    Map<String, dynamic> json,
  ) {
    final previewJson = json['preview'];

    return CalendarSubscriptionValidationResult(
      valid: json['valid'] as bool? ?? false,
      normalizedUrl: json['normalizedUrl'] as String?,
      message: json['message'] as String?,
      errorCode: json['errorCode'] as String?,
      preview: previewJson is Map<String, dynamic>
          ? CalendarSubscriptionPreview.fromJson(previewJson)
          : null,
    );
  }

  final bool valid;
  final String? normalizedUrl;
  final String? message;
  final String? errorCode;
  final CalendarSubscriptionPreview? preview;
}
