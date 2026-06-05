import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Lightweight local user preferences stored in SharedPreferences.
/// One-time migration from FlutterSecureStorage is performed on first load.
class CaleePreferences {
  CaleePreferences();

  static const _firstDayOfWeekKey = 'calee_pref_first_day_of_week';
  static const _timeFormatKey = 'calee_pref_time_format';
  static const _defaultCalendarIdKey = 'calee_pref_default_calendar_id';
  static const _defaultTaskListIdKey = 'calee_pref_default_task_list_id';

  static const _migrationDoneKey = 'calee_pref_migrated_to_shared_prefs';

  // ── Load all ─────────────────────────────────────────────────────────────

  Future<StoredPreferences> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await _migrateIfNeeded(prefs);
      return StoredPreferences(
        firstDayOfWeek:
            FirstDayOfWeek.fromString(prefs.getString(_firstDayOfWeekKey)),
        timeFormat:
            TimeFormatPref.fromString(prefs.getString(_timeFormatKey)),
        defaultCalendarId: prefs.getString(_defaultCalendarIdKey),
        defaultTaskListId: prefs.getString(_defaultTaskListIdKey),
      );
    } catch (_) {
      return const StoredPreferences();
    }
  }

  // ── Save individual ───────────────────────────────────────────────────────

  Future<void> saveFirstDayOfWeek(FirstDayOfWeek value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_firstDayOfWeekKey, value.storageValue);
  }

  Future<void> saveTimeFormat(TimeFormatPref value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_timeFormatKey, value.storageValue);
  }

  Future<void> saveDefaultCalendarId(String? calendarId) async {
    final prefs = await SharedPreferences.getInstance();
    if (calendarId == null) {
      await prefs.remove(_defaultCalendarIdKey);
    } else {
      await prefs.setString(_defaultCalendarIdKey, calendarId);
    }
  }

  Future<void> saveDefaultTaskListId(String? taskListId) async {
    final prefs = await SharedPreferences.getInstance();
    if (taskListId == null) {
      await prefs.remove(_defaultTaskListIdKey);
    } else {
      await prefs.setString(_defaultTaskListIdKey, taskListId);
    }
  }

  // ── Migration ─────────────────────────────────────────────────────────────

  Future<void> _migrateIfNeeded(SharedPreferences prefs) async {
    if (prefs.getBool(_migrationDoneKey) == true) return;

    try {
      const secure = FlutterSecureStorage();
      final all = await secure.readAll();

      for (final key in [
        _firstDayOfWeekKey,
        _timeFormatKey,
        _defaultCalendarIdKey,
        _defaultTaskListIdKey,
      ]) {
        final value = all[key];
        if (value != null && value.isNotEmpty) {
          await prefs.setString(key, value);
          await secure.delete(key: key);
        }
      }
    } catch (_) {
      // Migration is best-effort; failures should not block app startup.
    }

    await prefs.setBool(_migrationDoneKey, true);
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
