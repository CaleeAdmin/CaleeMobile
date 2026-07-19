import 'dart:convert';

import 'package:crypto/crypto.dart';
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

/// Thrown when the calendar-reminders-enabled preference cannot be persisted.
///
/// Persisting the toggle is not inconsequential best-effort storage: a failed
/// write must be surfaced so the caller (Settings, or the permission-denied
/// path) can roll the displayed value back and avoid acting on a value that did
/// not actually persist. Carries only the [operation] and an optional [cause]
/// — never a raw account ID or preference value — so it is safe to log.
class CalendarReminderPreferenceStorageException implements Exception {
  const CalendarReminderPreferenceStorageException(
    this.operation, [
    this.cause,
  ]);

  /// The failed operation, e.g. `'save'`.
  final String operation;

  /// The underlying error, if any.
  final Object? cause;

  @override
  String toString() =>
      'CalendarReminderPreferenceStorageException(operation: $operation)';
}

/// How the calendar-reminders-enabled preference was resolved for an account.
enum CalendarReminderPreferenceLoadStatus {
  /// An account-scoped (or migratable legacy) value was read successfully.
  loaded,

  /// No stored value applies to this account: the effective product default
  /// (disabled) governs, and it is safe to run the default-disabled path.
  absent,

  /// SharedPreferences access — or a write required to complete the one-time
  /// migration — failed. The real value is unknown, so callers must preserve
  /// existing reminders and NOT reinterpret this as `false`.
  unavailable,
}

/// Structured, log-safe result of loading the reminders-enabled preference.
///
/// A SharedPreferences failure is represented as
/// [CalendarReminderPreferenceLoadStatus.unavailable], never as a `false`
/// value, so a transient storage error can never be mistaken for the user
/// having disabled reminders.
class CalendarReminderPreferenceLoadResult {
  const CalendarReminderPreferenceLoadResult({
    required this.status,
    this.enabled,
    this.errorCategory,
  });

  const CalendarReminderPreferenceLoadResult.loaded(bool value)
    : status = CalendarReminderPreferenceLoadStatus.loaded,
      enabled = value,
      errorCategory = null;

  const CalendarReminderPreferenceLoadResult.absent()
    : status = CalendarReminderPreferenceLoadStatus.absent,
      enabled = null,
      errorCategory = null;

  const CalendarReminderPreferenceLoadResult.unavailable([this.errorCategory])
    : status = CalendarReminderPreferenceLoadStatus.unavailable,
      enabled = null;

  final CalendarReminderPreferenceLoadStatus status;

  /// The stored boolean when [status] is
  /// [CalendarReminderPreferenceLoadStatus.loaded]; otherwise `null`.
  final bool? enabled;

  /// Short, non-sensitive category when [status] is
  /// [CalendarReminderPreferenceLoadStatus.unavailable]. Never a raw value.
  final String? errorCategory;

  bool get isLoaded => status == CalendarReminderPreferenceLoadStatus.loaded;
  bool get isAbsent => status == CalendarReminderPreferenceLoadStatus.absent;
  bool get isUnavailable =>
      status == CalendarReminderPreferenceLoadStatus.unavailable;

  @override
  String toString() =>
      'CalendarReminderPreferenceLoadResult(status: ${status.name}'
      '${enabled != null ? ', enabled: $enabled' : ''}'
      '${errorCategory != null ? ', error: $errorCategory' : ''})';
}

/// Lightweight local user preferences stored in SharedPreferences.
/// One-time migration from FlutterSecureStorage is performed on first load.
class CaleePreferences {
  CaleePreferences();

  static const _firstDayOfWeekKey = 'calee_pref_first_day_of_week';
  static const _timeFormatKey = 'calee_pref_time_format';
  static const _defaultCalendarIdKey = 'calee_pref_default_calendar_id';
  static const _defaultTaskListIdKey = 'calee_pref_default_task_list_id';

  // Legacy device-global reminder-enabled preference. Retained only as the
  // one-time migration source for the account-scoped keys below (and as the
  // account-agnostic value for the null-owner legacy path). New writes for a
  // signed-in account go to the namespaced key instead.
  static const _calendarRemindersEnabledKey =
      'calee_pref_calendar_reminders_enabled';
  // Marker recording that the one-time legacy→account migration has run. Its
  // value is the privacy-safe owner key that claimed the legacy value (never a
  // raw account ID); its mere presence prevents any later account from
  // inheriting the legacy value.
  static const _calendarRemindersEnabledMigratedKey =
      'calee_pref_calendar_reminders_enabled_migrated';
  static const _calendarReminderManifestKey =
      'calee_pref_calendar_reminder_manifest';
  // Legacy diagnostic slot that previously stored the *raw* corrupt manifest
  // value. That could capture unexpected content, so it is removed on sight and
  // superseded by the privacy-safe metadata key below.
  static const _calendarReminderManifestCorruptKey =
      'calee_pref_calendar_reminder_manifest_corrupt';
  // Privacy-safe diagnostic slot for the most recent corrupt manifest value:
  // stores only a SHA-256 digest and the length, never the raw value.
  static const _calendarReminderManifestCorruptMetaKey =
      'calee_pref_calendar_reminder_manifest_corrupt_meta';
  static const _migrationDoneKey = 'calee_pref_migrated_to_shared_prefs';

  /// Namespaced reminder-enabled key for a specific account [ownerKey] (a
  /// privacy-safe SHA-256 digest, never a raw account ID).
  static String _calendarRemindersEnabledOwnerKey(String ownerKey) =>
      'calee_pref_calendar_reminders_enabled_$ownerKey';

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

  /// Loads whether calendar reminders are enabled for a specific account,
  /// returning just the boolean (an unavailable/absent read collapses to
  /// `false`).
  ///
  /// Prefer [loadCalendarRemindersEnabledResult] where a storage failure must be
  /// distinguished from a genuine `false` — this convenience method deliberately
  /// cannot make that distinction and is retained for Settings/UI callers that
  /// only need a best-effort display value.
  Future<bool> loadCalendarRemindersEnabled({String? ownerKey}) async =>
      (await loadCalendarRemindersEnabledResult(ownerKey: ownerKey)).enabled ??
      false;

  /// Loads whether calendar reminders are enabled for a specific account,
  /// classifying how the value was obtained.
  ///
  /// The preference is account-scoped: two accounts on the same device keep
  /// independent values, and a new account defaults to off. Pass the current
  /// account's privacy-safe [ownerKey]; a `null` [ownerKey] reads the legacy
  /// device-global value (the account-agnostic path).
  ///
  /// On the first read for an account, the old device-global value is migrated
  /// exactly once — claimed for whichever account is active at migration time —
  /// so an existing user's setting is preserved without propagating a legacy
  /// `true` to every later account. The one-time migration marker is consumed
  /// only when the migration completed consistently: the migrated value is
  /// written first and the marker last, and a failure of either required write
  /// is reported as [CalendarReminderPreferenceLoadStatus.unavailable] (never
  /// silently as `false`) so the caller preserves existing reminders and retries.
  ///
  /// A SharedPreferences access failure is likewise reported as
  /// [CalendarReminderPreferenceLoadStatus.unavailable]; a clean read with no
  /// applicable value is [CalendarReminderPreferenceLoadStatus.absent]; a read
  /// that found a value is [CalendarReminderPreferenceLoadStatus.loaded].
  Future<CalendarReminderPreferenceLoadResult>
  loadCalendarRemindersEnabledResult({String? ownerKey}) async {
    final SharedPreferences prefs;
    try {
      prefs = await SharedPreferences.getInstance();
    } catch (e) {
      return CalendarReminderPreferenceLoadResult.unavailable(
        _prefErrorCategory(e),
      );
    }

    try {
      if (ownerKey == null) {
        final legacy = prefs.getBool(_calendarRemindersEnabledKey);
        return legacy == null
            ? const CalendarReminderPreferenceLoadResult.absent()
            : CalendarReminderPreferenceLoadResult.loaded(legacy);
      }

      final scopedKey = _calendarRemindersEnabledOwnerKey(ownerKey);
      final scoped = prefs.getBool(scopedKey);
      if (scoped != null) {
        return CalendarReminderPreferenceLoadResult.loaded(scoped);
      }

      // No account-scoped value yet. If migration was already claimed by another
      // account, default off so the legacy value never leaks — that is a clean
      // [absent], not a failure.
      if (prefs.getString(_calendarRemindersEnabledMigratedKey) != null) {
        return const CalendarReminderPreferenceLoadResult.absent();
      }

      // First read for any account: attempt the one-time legacy migration.
      final legacy = prefs.getBool(_calendarRemindersEnabledKey);
      if (legacy != null) {
        // Write the migrated value FIRST; only then consume the marker, so the
        // marker is never claimed unless the migration completed consistently.
        if (!await prefs.setBool(scopedKey, legacy)) {
          return const CalendarReminderPreferenceLoadResult.unavailable(
            'migrated_value_write_failed',
          );
        }
        if (!await prefs.setString(
          _calendarRemindersEnabledMigratedKey,
          ownerKey,
        )) {
          return const CalendarReminderPreferenceLoadResult.unavailable(
            'migration_marker_write_failed',
          );
        }
        return CalendarReminderPreferenceLoadResult.loaded(legacy);
      }

      // No legacy value to migrate: claim the marker so no later account can
      // inherit a stale global value. A failed claim is reported (not absent),
      // so the migration is retried rather than left half-done.
      if (!await prefs.setString(
        _calendarRemindersEnabledMigratedKey,
        ownerKey,
      )) {
        return const CalendarReminderPreferenceLoadResult.unavailable(
          'migration_marker_write_failed',
        );
      }
      return const CalendarReminderPreferenceLoadResult.absent();
    } catch (e) {
      return CalendarReminderPreferenceLoadResult.unavailable(
        _prefErrorCategory(e),
      );
    }
  }

  /// Saves whether calendar reminders are enabled for a specific account.
  ///
  /// Writes the account-scoped value for [ownerKey] (or the legacy device-global
  /// value when [ownerKey] is `null`). An explicit account-scoped write also
  /// consumes the one-time legacy migration, so no other account can later
  /// inherit the stale global value.
  ///
  /// A persistence failure is surfaced as a
  /// [CalendarReminderPreferenceStorageException] (never swallowed), and the
  /// boolean results SharedPreferences returns are checked, so the caller can
  /// roll a Settings switch back and avoid acting on a value that did not
  /// actually persist. The account-scoped value is written first and the
  /// migration marker last, so a marker-write failure never leaves a value
  /// that disagrees with a rolled-back switch.
  Future<void> saveCalendarRemindersEnabled({
    String? ownerKey,
    required bool enabled,
  }) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (ownerKey == null) {
        if (!await prefs.setBool(_calendarRemindersEnabledKey, enabled)) {
          throw const CalendarReminderPreferenceStorageException('save');
        }
        return;
      }
      // Persist the account-scoped value first (the essential write)...
      if (!await prefs.setBool(
        _calendarRemindersEnabledOwnerKey(ownerKey),
        enabled,
      )) {
        throw const CalendarReminderPreferenceStorageException('save');
      }
      // ...then consume the one-time legacy migration so no later account
      // inherits the stale global value.
      if (prefs.getString(_calendarRemindersEnabledMigratedKey) == null) {
        if (!await prefs.setString(
          _calendarRemindersEnabledMigratedKey,
          ownerKey,
        )) {
          throw const CalendarReminderPreferenceStorageException('save');
        }
      }
    } on CalendarReminderPreferenceStorageException {
      rethrow;
    } catch (e) {
      throw CalendarReminderPreferenceStorageException('save', e);
    }
  }

  /// Short, non-sensitive category for a preference storage error suitable for
  /// logs — the runtime type only, never a raw value, key, or account ID.
  String _prefErrorCategory(Object error) => error.runtimeType.toString();

  // ── Calendar reminder manifest ────────────────────────────────────────────
  //
  // Tracks the notification IDs calendar reminders have scheduled on the
  // device so reconciliation can cancel only IDs it owns, never touching
  // notifications belonging to other Calee features.

  /// Loads the manifest and classifies how it was obtained.
  ///
  /// Reads are conservative: nothing stored is reported as
  /// [CalendarReminderManifestLoadStatus.absent], a valid current-schema value
  /// as [CalendarReminderManifestLoadStatus.loaded], legacy/partially-malformed
  /// but recoverable data as [CalendarReminderManifestLoadStatus.recovered],
  /// and genuinely unparseable data (bad JSON, or an unrecoverable shape) as
  /// [CalendarReminderManifestLoadStatus.corrupt] — never silently collapsed to
  /// an empty manifest. On corrupt data only privacy-safe metadata (a SHA-256
  /// digest and length) is recorded for diagnostics — never the raw value,
  /// which could contain unexpected content — and the primary value is left
  /// untouched, so ownership is not discarded and callers can retry.
  Future<CalendarReminderManifestLoadResult>
  loadCalendarReminderManifestResult() async {
    final SharedPreferences prefs;
    final String? raw;
    try {
      prefs = await SharedPreferences.getInstance();
      raw = prefs.getString(_calendarReminderManifestKey);
    } catch (_) {
      // Storage itself is unavailable; ownership is unknown, so report corrupt
      // rather than fabricating an empty manifest that could be overwritten.
      return const CalendarReminderManifestLoadResult(
        manifest: CalendarReminderManifest.empty,
        status: CalendarReminderManifestLoadStatus.corrupt,
      );
    }

    if (raw == null || raw.isEmpty) {
      return const CalendarReminderManifestLoadResult(
        manifest: CalendarReminderManifest.empty,
        status: CalendarReminderManifestLoadStatus.absent,
      );
    }

    Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } catch (_) {
      // Unparseable JSON: record only privacy-safe metadata for diagnostics and
      // report corrupt without touching the primary key.
      await _preserveCorruptManifestMetadata(prefs, raw);
      return const CalendarReminderManifestLoadResult(
        manifest: CalendarReminderManifest.empty,
        status: CalendarReminderManifestLoadStatus.corrupt,
      );
    }

    final result = CalendarReminderManifest.parse(decoded);
    if (result.isCorrupt) {
      await _preserveCorruptManifestMetadata(prefs, raw);
    }
    return result;
  }

  /// Loads just the manifest, discarding the load status. Kept for callers that
  /// only need the owned IDs; prefer [loadCalendarReminderManifestResult] where
  /// corrupt data must be handled conservatively.
  Future<CalendarReminderManifest> loadCalendarReminderManifest() async =>
      (await loadCalendarReminderManifestResult()).manifest;

  /// Records privacy-safe diagnostics for a corrupt manifest value.
  ///
  /// Stores only a SHA-256 digest of the raw value and its length — never the
  /// raw value itself, which (being unparseable) could contain unexpected
  /// content. Also removes any legacy raw diagnostic value left by an earlier
  /// build so it does not linger.
  Future<void> _preserveCorruptManifestMetadata(
    SharedPreferences prefs,
    String raw,
  ) async {
    try {
      final digest = sha256.convert(utf8.encode(raw)).toString();
      await prefs.setString(
        _calendarReminderManifestCorruptMetaKey,
        jsonEncode({'sha256': digest, 'length': raw.length}),
      );
      // Migrate away from the old raw diagnostic value if present.
      await prefs.remove(_calendarReminderManifestCorruptKey);
    } catch (_) {
      // Best-effort diagnostics; never block on this.
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
