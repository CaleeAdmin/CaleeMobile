class ClientEventDraft {
  const ClientEventDraft({
    required this.title,
    this.startsAt,
    this.endsAt,
    required this.allDay,
    this.timezone,
    this.location,
    this.description,
    required this.confidence,
    required this.missingFields,
    required this.warnings,
  });

  final String title;
  final DateTime? startsAt;
  final DateTime? endsAt;
  final bool allDay;
  final String? timezone;
  final String? location;
  final String? description;
  final double confidence;
  final List<String> missingFields;
  final List<String> warnings;

  factory ClientEventDraft.fromJson(Map<String, dynamic> json) {
    final rawStartsAt = json['starts_at'] ?? json['startsAt'];
    final rawEndsAt = json['ends_at'] ?? json['endsAt'];
    final rawAllDay = json['all_day'] ?? json['allDay'];
    final rawMissingFields = json['missing_fields'] ?? json['missingFields'];

    DateTime? startsAt;
    if (rawStartsAt is String) {
      startsAt = DateTime.tryParse(rawStartsAt);
    }

    DateTime? endsAt;
    if (rawEndsAt is String) {
      endsAt = DateTime.tryParse(rawEndsAt);
    }

    final missingFields = rawMissingFields is List
        ? rawMissingFields.whereType<String>().toList()
        : <String>[];

    final warnings = json['warnings'] is List
        ? (json['warnings'] as List).whereType<String>().toList()
        : <String>[];

    return ClientEventDraft(
      title: (json['title'] as String?) ?? '',
      startsAt: startsAt,
      endsAt: endsAt,
      allDay: rawAllDay is bool ? rawAllDay : false,
      timezone: json['timezone'] as String?,
      location: json['location'] as String?,
      description: json['description'] as String?,
      confidence: (json['confidence'] as num?)?.toDouble() ?? 0.0,
      missingFields: missingFields,
      warnings: warnings,
    );
  }
}

class EventDraftsFromImageResponse {
  const EventDraftsFromImageResponse({
    required this.drafts,
    this.sourceType,
    this.timezone,
    this.referenceDate,
  });

  final List<ClientEventDraft> drafts;
  final String? sourceType;
  final String? timezone;
  final String? referenceDate;

  factory EventDraftsFromImageResponse.fromJson(Map<String, dynamic> json) {
    final rawDrafts = json['drafts'];
    final drafts = rawDrafts is List
        ? rawDrafts
              .whereType<Map<String, dynamic>>()
              .map(ClientEventDraft.fromJson)
              .toList()
        : <ClientEventDraft>[];

    return EventDraftsFromImageResponse(
      drafts: drafts,
      sourceType: json['source_type'] as String?,
      timezone: json['timezone'] as String?,
      referenceDate: json['reference_date'] as String?,
    );
  }
}
