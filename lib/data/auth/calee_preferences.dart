import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/calendar_reminder_manifest.dart';

/// Thrown when the calendar reminder manifest cannot be persisted or cleared.
///
/// Manifest persistence is part of the reconciliation transaction, so its
/// failures must be observable (not silently swallowed). Deliberately carries
/// only the [operation] and an optional underlying [cause] — never manifest
/// contents — so it stays safe to log.
class CalendarReminderManifestStorageException implements Exception {
  const CalendarReminderManifestStorageException(this.operation, [this.cause]);

  /// The failed operation: `'save'` or `'clear'`.
  final String operation;

  /// The underlying error, if any.
  final Object? cause;

  @override
  String toString() =>
      'CalendarReminderManifestStorageException(operation: $operation)';
}

/// Lightweight local user preferences stored in SharedPreferences.
/// One-time migration from FlutterSecureStorage is performed on first load.
class CaleePreferences {
  CaleePreferences();

  static const _firstDayOfWeekKey = 'calee_pref_first_day_of_week';
  static const _timeFormatKey = 'calee_pref_time_format';
  static const _defaultCalendarIdKey = 'calee_pref_default_calendar_id';
  static const _defaultTaskListIdKey = 'calee_pref_default_task_list_id';

  static const _calendarRemindersEnabledKey =
      'calee_pref_calendar_reminders_enabled';
  static const _calendarReminderManifestKey =
      'calee_pref_calendar_reminder_manifest';
  static const _migrationDoneKey = 'calee_pref_migrated_to_shared_prefs';

  // ── Load all ─────────────────────────────────────────────────────────────

  Future<StoredPreferences> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await _migrateIfNeeded(prefs);
      return StoredPreferences(
        firstDayOfWeek: FirstDayOfWeek.fromString(
          prefs.getString(_firstDayOfWeekKey),
        ),
        timeFormat: TimeFormatPref.fromString(prefs.getString(_timeFormatKey)),
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

  /// Overwrites the local cache with [preferences] in one call, e.g. after a
  /// successful Hub load or PATCH whose response is the new source of truth.
  Future<void> saveAll(StoredPreferences preferences) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _firstDayOfWeekKey,
      preferences.firstDayOfWeek.storageValue,
    );
    await prefs.setString(_timeFormatKey, preferences.timeFormat.storageValue);
    if (preferences.defaultCalendarId == null) {
      await prefs.remove(_defaultCalendarIdKey);
    } else {
      await prefs.setString(
        _defaultCalendarIdKey,
        preferences.defaultCalendarId!,
      );
    }
    if (preferences.defaultTaskListId == null) {
      await prefs.remove(_defaultTaskListIdKey);
    } else {
      await prefs.setString(
        _defaultTaskListIdKey,
        preferences.defaultTaskListId!,
      );
    }
  }

  // ── Calendar reminders ────────────────────────────────────────────────────

  Future<bool> loadCalendarRemindersEnabled() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getBool(_calendarRemindersEnabledKey) ?? false;
    } catch (_) {
      return false;
    }
  }

  Future<void> saveCalendarRemindersEnabled(bool enabled) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_calendarRemindersEnabledKey, enabled);
    } catch (_) {
      // Best-effort.
    }
  }

  // ── Calendar reminder manifest ────────────────────────────────────────────
  //
  // Tracks the notification IDs calendar reminders have scheduled on the
  // device so reconciliation can cancel only IDs it owns, never touching
  // notifications belonging to other Calee features.

  Future<CalendarReminderManifest> loadCalendarReminderManifest() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_calendarReminderManifestKey);
      if (raw == null || raw.isEmpty) return CalendarReminderManifest.empty;
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) {
        return CalendarReminderManifest.empty;
      }
      return CalendarReminderManifest.fromJson(decoded);
    } catch (_) {
      return CalendarReminderManifest.empty;
    }
  }

  /// Persists the calendar reminder manifest.
  ///
  /// Manifest persistence is part of the reconciliation transaction, not
  /// inconsequential best-effort storage: a newly scheduled notification that
  /// cannot be recorded here would become an untracked notification. Failures
  /// are therefore surfaced as a [CalendarReminderManifestStorageException]
  /// rather than swallowed, so callers can roll back or report.
  Future<void> saveCalendarReminderManifest(
    CalendarReminderManifest manifest,
  ) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final ok = await prefs.setString(
        _calendarReminderManifestKey,
        jsonEncode(manifest.toJson()),
      );
      if (!ok) {
        throw const CalendarReminderManifestStorageException('save');
      }
    } on CalendarReminderManifestStorageException {
      rethrow;
    } catch (e) {
      throw CalendarReminderManifestStorageException('save', e);
    }
  }

  /// Clears the calendar reminder manifest. Like [saveCalendarReminderManifest],
  /// failures are surfaced (not swallowed) so cleanup can be retried. A `false`
  /// return from [SharedPreferences.remove] is not treated as an error — it does
  /// not indicate a failed write, only that there may have been nothing to
  /// remove — but a thrown storage error propagates.
  Future<void> clearCalendarReminderManifest() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_calendarReminderManifestKey);
    } on CalendarReminderManifestStorageException {
      rethrow;
    } catch (e) {
      throw CalendarReminderManifestStorageException('clear', e);
    }
  }

  // ── Calendar onboarding ───────────────────────────────────────────────────

  static String _calendarOnboardingKey(String accountId) =>
      'calee_calendar_onboarding_status_$accountId';

  Future<String> loadCalendarOnboardingStatus(String accountId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getString(_calendarOnboardingKey(accountId)) ??
          'not_started';
    } catch (_) {
      return 'not_started';
    }
  }

  Future<void> saveCalendarOnboardingStatus(
    String accountId,
    String status,
  ) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_calendarOnboardingKey(accountId), status);
    } catch (_) {
      // Best-effort; failures should not block the app.
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

  /// Returns a copy with the given fields replaced. Pass [clearDefaultCalendarId]
  /// or [clearDefaultTaskListId] to explicitly reset those fields to Automatic
  /// (null), since a plain `defaultCalendarId: null` argument is indistinguishable
  /// from "leave unchanged" with named parameters.
  StoredPreferences copyWith({
    FirstDayOfWeek? firstDayOfWeek,
    TimeFormatPref? timeFormat,
    String? defaultCalendarId,
    bool clearDefaultCalendarId = false,
    String? defaultTaskListId,
    bool clearDefaultTaskListId = false,
  }) {
    return StoredPreferences(
      firstDayOfWeek: firstDayOfWeek ?? this.firstDayOfWeek,
      timeFormat: timeFormat ?? this.timeFormat,
      defaultCalendarId: clearDefaultCalendarId
          ? null
          : (defaultCalendarId ?? this.defaultCalendarId),
      defaultTaskListId: clearDefaultTaskListId
          ? null
          : (defaultTaskListId ?? this.defaultTaskListId),
    );
  }
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
