import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Lightweight local user preferences stored via flutter_secure_storage.
/// These are non-sensitive UI preferences; secure_storage is used simply
/// because it is already a project dependency.
class CaleePreferences {
  CaleePreferences();

  static const _firstDayOfWeekKey = 'calee_pref_first_day_of_week';
  static const _timeFormatKey = 'calee_pref_time_format';
  static const _defaultCalendarIdKey = 'calee_pref_default_calendar_id';
  static const _defaultTaskListIdKey = 'calee_pref_default_task_list_id';

  final FlutterSecureStorage _storage = const FlutterSecureStorage();

  // ── Load all ─────────────────────────────────────────────────────────────

  Future<StoredPreferences> load() async {
    try {
      final all = await _storage.readAll();
      return StoredPreferences(
        firstDayOfWeek:
            FirstDayOfWeek.fromString(all[_firstDayOfWeekKey]),
        timeFormat: TimeFormatPref.fromString(all[_timeFormatKey]),
        defaultCalendarId: all[_defaultCalendarIdKey],
        defaultTaskListId: all[_defaultTaskListIdKey],
      );
    } catch (_) {
      return const StoredPreferences();
    }
  }

  // ── Save individual ───────────────────────────────────────────────────────

  Future<void> saveFirstDayOfWeek(FirstDayOfWeek value) =>
      _storage.write(key: _firstDayOfWeekKey, value: value.storageValue);

  Future<void> saveTimeFormat(TimeFormatPref value) =>
      _storage.write(key: _timeFormatKey, value: value.storageValue);

  Future<void> saveDefaultCalendarId(String? calendarId) async {
    if (calendarId == null) {
      await _storage.delete(key: _defaultCalendarIdKey);
    } else {
      await _storage.write(key: _defaultCalendarIdKey, value: calendarId);
    }
  }

  Future<void> saveDefaultTaskListId(String? calendarId) async {
    if (calendarId == null) {
      await _storage.delete(key: _defaultTaskListIdKey);
    } else {
      await _storage.write(key: _defaultTaskListIdKey, value: calendarId);
    }
  }
}

// ── Value types ───────────────────────────────────────────────────────────────

class StoredPreferences {
  const StoredPreferences({
    this.firstDayOfWeek = FirstDayOfWeek.sunday,
    this.timeFormat = TimeFormatPref.system,
    this.defaultCalendarId,
    this.defaultTaskListId,
  });

  final FirstDayOfWeek firstDayOfWeek;
  final TimeFormatPref timeFormat;
  final String? defaultCalendarId;
  final String? defaultTaskListId;
}

enum FirstDayOfWeek {
  sunday,
  monday;

  static FirstDayOfWeek fromString(String? value) {
    if (value == 'monday') return FirstDayOfWeek.monday;
    return FirstDayOfWeek.sunday;
  }

  String get storageValue => name;

  String get displayLabel => switch (this) {
        FirstDayOfWeek.sunday => 'Sunday',
        FirstDayOfWeek.monday => 'Monday',
      };
}

enum TimeFormatPref {
  system,
  h12,
  h24;

  static TimeFormatPref fromString(String? value) {
    if (value == 'h12') return TimeFormatPref.h12;
    if (value == 'h24') return TimeFormatPref.h24;
    return TimeFormatPref.system;
  }

  String get storageValue => name;

  String get displayLabel => switch (this) {
        TimeFormatPref.system => 'System default',
        TimeFormatPref.h12 => '12-hour',
        TimeFormatPref.h24 => '24-hour',
      };
}
