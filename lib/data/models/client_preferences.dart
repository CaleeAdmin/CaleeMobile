import '../auth/calee_preferences.dart';

class ClientPreferences {
  const ClientPreferences({
    required this.firstDayOfWeek,
    required this.timeFormat,
    this.defaultCalendarId,
    this.defaultTaskListId,
    this.version = 1,
    this.updatedAt,
  });

  factory ClientPreferences.fromJson(Map<String, dynamic> json) {
    return ClientPreferences(
      firstDayOfWeek: FirstDayOfWeek.fromString(
        json['firstDayOfWeek'] as String?,
      ),
      timeFormat: TimeFormatPref.fromString(json['timeFormat'] as String?),
      defaultCalendarId: json['defaultCalendarId'] as String?,
      defaultTaskListId: json['defaultTaskListId'] as String?,
      version: json['version'] as int? ?? 1,
      updatedAt: switch (json['updatedAt']) {
        String value => DateTime.tryParse(value),
        _ => null,
      },
    );
  }

  final FirstDayOfWeek firstDayOfWeek;
  final TimeFormatPref timeFormat;
  final String? defaultCalendarId;
  final String? defaultTaskListId;
  final int version;
  final DateTime? updatedAt;

  StoredPreferences toStoredPreferences() => StoredPreferences(
    firstDayOfWeek: firstDayOfWeek,
    timeFormat: timeFormat,
    defaultCalendarId: defaultCalendarId,
    defaultTaskListId: defaultTaskListId,
  );
}
