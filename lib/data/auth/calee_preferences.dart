import 'dart:async';
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

/// A versioned, atomic record of the calendar-reminders-enabled preference for
/// every account on this device, plus the one-time legacy-claim bookkeeping.
///
/// The whole record is persisted as a single JSON string under one
/// SharedPreferences key (see [CaleePreferences._reminderSettingsV2Key]), so a
/// successful `setString()` is the transaction commit and a failed one leaves
/// the previously committed logical state unchanged — there is no window in
/// which a scoped value is stored while its migration marker is not (the
/// two-key hazard the previous multi-write design suffered from).
///
/// Privacy: keys in [valuesByOwner] and [legacyClaimOwner] are privacy-safe
/// owner digests (see `reminderOwnerKey`), never raw account IDs. No event data
/// is stored here.
class CalendarReminderPreferenceRecord {
  const CalendarReminderPreferenceRecord({
    this.version = currentVersion,
    this.legacyClaimConsumed = false,
    this.legacyClaimOwner,
    this.legacyValue,
    this.valuesByOwner = const <String, bool>{},
  });

  /// The only schema version this build understands. A stored record carrying
  /// any other version is treated as unavailable/corrupt, never silently reset.
  static const int currentVersion = 1;

  static const CalendarReminderPreferenceRecord empty =
      CalendarReminderPreferenceRecord();

  final int version;

  /// Whether the one-time legacy device-global claim has been taken. Once true,
  /// no later account may inherit the legacy value.
  final bool legacyClaimConsumed;

  /// The owner digest that consumed the legacy claim, or `null` when the claim
  /// was consumed without granting the value to any specific account (e.g.
  /// several pre-existing owner-scoped values were found at migration time).
  final String? legacyClaimOwner;

  /// The as-yet-unclaimed legacy device-global value, preserved through
  /// migration so the first valid account load may claim it exactly once. Once
  /// claimed (or once the claim is otherwise consumed) this is `null`.
  final bool? legacyValue;

  /// Explicit per-account values, keyed by owner digest.
  final Map<String, bool> valuesByOwner;

  CalendarReminderPreferenceRecord copyWith({
    bool? legacyClaimConsumed,
    String? legacyClaimOwner,
    bool clearLegacyClaimOwner = false,
    bool? legacyValue,
    bool clearLegacyValue = false,
    Map<String, bool>? valuesByOwner,
  }) {
    return CalendarReminderPreferenceRecord(
      version: currentVersion,
      legacyClaimConsumed: legacyClaimConsumed ?? this.legacyClaimConsumed,
      legacyClaimOwner: clearLegacyClaimOwner
          ? null
          : (legacyClaimOwner ?? this.legacyClaimOwner),
      legacyValue: clearLegacyValue ? null : (legacyValue ?? this.legacyValue),
      valuesByOwner: valuesByOwner ?? this.valuesByOwner,
    );
  }

  Map<String, dynamic> toJson() => {
    'version': version,
    'legacyClaimConsumed': legacyClaimConsumed,
    if (legacyClaimOwner != null) 'legacyClaimOwner': legacyClaimOwner,
    if (legacyValue != null) 'legacyValue': legacyValue,
    'values': valuesByOwner,
  };

  /// Parses [decoded] JSON into a record, or returns `null` when the shape is
  /// malformed or the version is unsupported — so the caller reports an
  /// unavailable/corrupt result rather than defaulting to `false`.
  static CalendarReminderPreferenceRecord? fromJson(Object? decoded) {
    if (decoded is! Map) return null;
    final version = decoded['version'];
    if (version is! int || version != currentVersion) return null;

    final consumed = decoded['legacyClaimConsumed'];
    if (consumed is! bool) return null;

    final owner = decoded['legacyClaimOwner'];
    if (owner != null && owner is! String) return null;

    final legacy = decoded['legacyValue'];
    if (legacy != null && legacy is! bool) return null;

    final rawValues = decoded['values'];
    final values = <String, bool>{};
    if (rawValues != null) {
      if (rawValues is! Map) return null;
      for (final entry in rawValues.entries) {
        final key = entry.key;
        final value = entry.value;
        if (key is! String || value is! bool) return null;
        values[key] = value;
      }
    }

    return CalendarReminderPreferenceRecord(
      version: currentVersion,
      legacyClaimConsumed: consumed,
      legacyClaimOwner: owner as String?,
      legacyValue: legacy as bool?,
      valuesByOwner: values,
    );
  }
}

/// Narrow storage seam for the calendar-reminder preference record and its
/// legacy migration keys.
///
/// Injecting an implementation lets tests deterministically simulate failed or
/// delayed writes (and read the committed value back) without depending on real
/// SharedPreferences behaviour. The production implementation
/// ([_SharedPreferencesReminderStore]) is a thin wrapper over
/// [SharedPreferences]. Never adds a package.
abstract class ReminderPreferenceStore {
  Future<String?> readString(String key);
  Future<bool?> readBool(String key);

  /// Persists [value]. Returns `true` on a confirmed write; a `false` return (or
  /// a thrown error) is treated by callers as a failed commit.
  Future<bool> writeString(String key, String value);
  Future<bool> remove(String key);
  Future<Set<String>> keys();
}

class _SharedPreferencesReminderStore implements ReminderPreferenceStore {
  _SharedPreferencesReminderStore(this._prefs);

  final SharedPreferences _prefs;

  @override
  Future<String?> readString(String key) async => _prefs.getString(key);

  @override
  Future<bool?> readBool(String key) async => _prefs.getBool(key);

  @override
  Future<bool> writeString(String key, String value) =>
      _prefs.setString(key, value);

  @override
  Future<bool> remove(String key) => _prefs.remove(key);

  @override
  Future<Set<String>> keys() async => _prefs.getKeys();
}

/// Lightweight local user preferences stored in SharedPreferences.
/// One-time migration from FlutterSecureStorage is performed on first load.
class CaleePreferences {
  CaleePreferences({ReminderPreferenceStore? reminderStore})
    : _reminderStoreOverride = reminderStore;

  /// Optional injected storage seam for the reminder-preference record (tests).
  /// `null` in production, where the store is created from [SharedPreferences].
  final ReminderPreferenceStore? _reminderStoreOverride;

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
  // Single transactional record holding the reminder-enabled state for every
  // account plus the one-time legacy-claim bookkeeping. Written through one
  // [SharedPreferences.setString] call, so its commit is atomic. Supersedes the
  // three keys above, which are read once at migration and then removed.
  static const _reminderSettingsV2Key =
      'calee_pref_calendar_reminder_settings_v2';
  // Prefix shared by the legacy per-account keys. Enumerated during migration to
  // import every discoverable owner-scoped value. NOTE: the migration marker key
  // also begins with this prefix and must be excluded when enumerating.
  static const _calendarRemindersEnabledOwnerPrefix =
      'calee_pref_calendar_reminders_enabled_';
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
  /// device-global value (the account-agnostic path, retained for lower-level
  /// tests — production reminder reads always carry a real owner).
  ///
  /// State lives in one versioned JSON record (see
  /// [CalendarReminderPreferenceRecord]) written through a single
  /// `SharedPreferences.setString()`, so there is no partial-commit window. All
  /// read-modify-write access runs on a process-wide serialization queue, so two
  /// accounts racing to migrate can never both inherit the legacy value.
  ///
  /// On the first access, the legacy multi-key format is migrated into the
  /// record and committed atomically; only after that commit succeeds are the
  /// old keys removed best-effort. A migration/claim commit failure — or a
  /// storage access failure, or a malformed/unsupported record — is reported as
  /// [CalendarReminderPreferenceLoadStatus.unavailable] (never silently as
  /// `false`), so the caller preserves existing reminders and retries.
  Future<CalendarReminderPreferenceLoadResult>
  loadCalendarRemindersEnabledResult({String? ownerKey}) {
    return _runSerialized(() async {
      final ReminderPreferenceStore store;
      try {
        store = await _openReminderStore();
      } catch (e) {
        return CalendarReminderPreferenceLoadResult.unavailable(
          _prefErrorCategory(e),
        );
      }

      try {
        final loaded = await _loadOrMigrateRecord(store);
        if (loaded.unavailableCategory != null) {
          return CalendarReminderPreferenceLoadResult.unavailable(
            loaded.unavailableCategory,
          );
        }
        var record = loaded.record!;

        // The account-agnostic (legacy/test) path reads the unclaimed legacy
        // value directly and never mutates the record.
        if (ownerKey == null) {
          return record.legacyValue == null
              ? const CalendarReminderPreferenceLoadResult.absent()
              : CalendarReminderPreferenceLoadResult.loaded(
                  record.legacyValue!,
                );
        }

        // An explicit account-scoped value always wins.
        if (record.valuesByOwner.containsKey(ownerKey)) {
          return CalendarReminderPreferenceLoadResult.loaded(
            record.valuesByOwner[ownerKey]!,
          );
        }

        // First account to arrive may claim the unclaimed legacy value exactly
        // once. This mutates the record, so it must be committed.
        if (!record.legacyClaimConsumed && record.legacyValue != null) {
          final claimed = record.legacyValue!;
          record = record.copyWith(
            legacyClaimConsumed: true,
            legacyClaimOwner: ownerKey,
            clearLegacyValue: true,
            valuesByOwner: {...record.valuesByOwner, ownerKey: claimed},
          );
          if (!await _commitRecord(store, record)) {
            return const CalendarReminderPreferenceLoadResult.unavailable(
              'record_write_failed',
            );
          }
          return CalendarReminderPreferenceLoadResult.loaded(claimed);
        }

        // No value for this account and nothing left to inherit: a clean
        // default-off absent (no write needed — the legacy value, if any, was
        // already claimed or never existed).
        return const CalendarReminderPreferenceLoadResult.absent();
      } catch (e) {
        return CalendarReminderPreferenceLoadResult.unavailable(
          _prefErrorCategory(e),
        );
      }
    });
  }

  /// Saves whether calendar reminders are enabled for a specific account in one
  /// serialized, atomic read-modify-write transaction.
  ///
  /// The account-scoped value for [ownerKey] (or the account-agnostic legacy
  /// value when [ownerKey] is `null`) is updated inside the single versioned
  /// record and committed with one `setString()`. An explicit account-scoped
  /// write also consumes the one-time legacy claim in the same commit, so no
  /// later account can inherit the stale global value, and saving one account
  /// never changes another. Concurrent saves for two accounts each run serially,
  /// so both updates are retained rather than the earlier one being lost.
  ///
  /// A persistence failure is surfaced as a
  /// [CalendarReminderPreferenceStorageException] (never swallowed): on failure
  /// the previously committed value remains, so a later reload can never reveal
  /// the value from a failed save and the caller can safely leave a Settings
  /// switch unchanged.
  Future<void> saveCalendarRemindersEnabled({
    String? ownerKey,
    required bool enabled,
  }) {
    return _runSerialized(() async {
      try {
        final store = await _openReminderStore();
        final loaded = await _loadOrMigrateRecord(store);
        if (loaded.unavailableCategory != null) {
          throw const CalendarReminderPreferenceStorageException('save');
        }
        var record = loaded.record!;

        if (ownerKey == null) {
          // Account-agnostic legacy/test path: store the value as the legacy
          // global so a null-owner load reads it back.
          record = record.copyWith(legacyValue: enabled);
        } else {
          record = record.copyWith(
            valuesByOwner: {...record.valuesByOwner, ownerKey: enabled},
            // An explicit save consumes the one-time legacy claim so no later
            // account inherits the stale global value.
            legacyClaimConsumed: true,
            legacyClaimOwner: record.legacyClaimConsumed
                ? record.legacyClaimOwner
                : ownerKey,
            clearLegacyValue: true,
          );
        }

        if (!await _commitRecord(store, record)) {
          throw const CalendarReminderPreferenceStorageException('save');
        }
      } on CalendarReminderPreferenceStorageException {
        rethrow;
      } catch (e) {
        throw CalendarReminderPreferenceStorageException('save', e);
      }
    });
  }

  /// Opens the reminder-preference storage seam: the injected override in tests,
  /// or a thin wrapper over [SharedPreferences] in production.
  Future<ReminderPreferenceStore> _openReminderStore() async {
    final override = _reminderStoreOverride;
    if (override != null) return override;
    return _SharedPreferencesReminderStore(
      await SharedPreferences.getInstance(),
    );
  }

  /// Reads the committed v2 record, or migrates the legacy multi-key format into
  /// one on first access and commits it atomically. Old keys are removed only
  /// after a successful commit (best-effort — their removal failing does not
  /// invalidate the committed record). A commit failure, or a malformed/
  /// unsupported stored record, yields an [_unavailableCategory] and leaves any
  /// old keys untouched.
  Future<_ReminderRecordLoad> _loadOrMigrateRecord(
    ReminderPreferenceStore store,
  ) async {
    final raw = await store.readString(_reminderSettingsV2Key);
    if (raw != null && raw.isNotEmpty) {
      Object? decoded;
      try {
        decoded = jsonDecode(raw);
      } catch (_) {
        return const _ReminderRecordLoad.unavailable('record_corrupt_json');
      }
      final record = CalendarReminderPreferenceRecord.fromJson(decoded);
      if (record == null) {
        return const _ReminderRecordLoad.unavailable('record_unsupported');
      }
      return _ReminderRecordLoad.ok(record);
    }

    // No v2 record yet: migrate the legacy multi-key format.
    final migrated = await _buildMigratedRecord(store);
    if (migrated.needsCommit) {
      if (!await _commitRecord(store, migrated.record)) {
        // Leave old keys untouched so migration is retried later.
        return const _ReminderRecordLoad.unavailable('record_write_failed');
      }
      await _removeLegacyKeys(store, migrated.legacyKeys);
    }
    return _ReminderRecordLoad.ok(migrated.record);
  }

  /// Builds the v2 record from the legacy keys, applying the documented policy
  /// for ambiguous partial state left by the previous format:
  ///
  /// * every discoverable owner-scoped boolean is preserved;
  /// * if the old migration marker exists, its claimant is preserved as the
  ///   legacy claimant (claim consumed);
  /// * else if exactly one owner-scoped value exists, that owner is
  ///   conservatively treated as having consumed the legacy claim;
  /// * else if several owner-scoped values exist, the claim is consumed without
  ///   granting the legacy value to any account;
  /// * else if only a legacy global value exists, it is preserved as an
  ///   unclaimed value the first valid account load may claim;
  /// * else the record is empty (no legacy state).
  Future<_MigratedRecord> _buildMigratedRecord(
    ReminderPreferenceStore store,
  ) async {
    final keys = await store.keys();
    final legacyKeys = <String>[];

    final valuesByOwner = <String, bool>{};
    for (final key in keys) {
      if (!key.startsWith(_calendarRemindersEnabledOwnerPrefix)) continue;
      if (key == _calendarRemindersEnabledMigratedKey) continue;
      final owner = key.substring(_calendarRemindersEnabledOwnerPrefix.length);
      if (owner.isEmpty) continue;
      final value = await store.readBool(key);
      if (value == null) continue;
      valuesByOwner[owner] = value;
      legacyKeys.add(key);
    }

    final marker = await store.readString(_calendarRemindersEnabledMigratedKey);
    if (marker != null) legacyKeys.add(_calendarRemindersEnabledMigratedKey);

    final legacyGlobal = await store.readBool(_calendarRemindersEnabledKey);
    if (legacyGlobal != null) legacyKeys.add(_calendarRemindersEnabledKey);

    final hadAnyLegacy = legacyKeys.isNotEmpty;

    bool legacyClaimConsumed;
    String? legacyClaimOwner;
    bool? legacyValue;

    if (marker != null) {
      legacyClaimConsumed = true;
      legacyClaimOwner = marker.isEmpty ? null : marker;
    } else if (valuesByOwner.length == 1) {
      legacyClaimConsumed = true;
      legacyClaimOwner = valuesByOwner.keys.first;
    } else if (valuesByOwner.length > 1) {
      legacyClaimConsumed = true;
      legacyClaimOwner = null;
    } else if (legacyGlobal != null) {
      legacyClaimConsumed = false;
      legacyValue = legacyGlobal;
    } else {
      legacyClaimConsumed = false;
    }

    final record = CalendarReminderPreferenceRecord(
      legacyClaimConsumed: legacyClaimConsumed,
      legacyClaimOwner: legacyClaimOwner,
      legacyValue: legacyValue,
      valuesByOwner: valuesByOwner,
    );
    // Only commit (and thus write) when there was pre-existing legacy state to
    // migrate; a brand-new install has nothing to persist until an actual save.
    return _MigratedRecord(
      record: record,
      needsCommit: hadAnyLegacy,
      legacyKeys: legacyKeys,
    );
  }

  Future<bool> _commitRecord(
    ReminderPreferenceStore store,
    CalendarReminderPreferenceRecord record,
  ) async {
    try {
      return await store.writeString(
        _reminderSettingsV2Key,
        jsonEncode(record.toJson()),
      );
    } catch (_) {
      return false;
    }
  }

  Future<void> _removeLegacyKeys(
    ReminderPreferenceStore store,
    List<String> legacyKeys,
  ) async {
    for (final key in legacyKeys) {
      try {
        await store.remove(key);
      } catch (_) {
        // Best-effort cleanup: a failed removal does not invalidate the already
        // committed v2 record.
      }
    }
  }

  /// Short, non-sensitive category for a preference storage error suitable for
  /// logs — the runtime type only, never a raw value, key, or account ID.
  String _prefErrorCategory(Object error) => error.runtimeType.toString();

  // ── Reminder-preference serialization boundary ────────────────────────────
  //
  // Process-wide serial queue for every read-modify-write on the reminder
  // record. Multiple [CaleePreferences] instances (Settings, the coordinator,
  // lifecycle handlers) may load or save concurrently; running them serially is
  // what makes "two accounts racing to migrate" and "concurrent A/B saves"
  // safe. Mirrors the notification service's mutation queue in intent.

  /// Tail of the serialization chain. Advanced past each operation's completion,
  /// swallowing that operation's error so a single failure never poisons the
  /// queue for later callers.
  static Future<void> _reminderPrefTail = Future<void>.value();

  /// Number of operations currently queued or running. When it is zero the queue
  /// is idle and the next operation starts a fresh chain rather than chaining off
  /// a retained-but-completed future — which matters in widget tests, where a
  /// future retained across test async-zones would otherwise stall the
  /// framework's async tracking (and is harmless in production, where the queue
  /// is a single long-lived chain).
  static int _pendingReminderOps = 0;

  /// Runs [operation] after every previously-queued reminder-preference
  /// operation completes. The returned future always completes (with the
  /// operation's value or error); the queue tail advances regardless of outcome
  /// so a single failure never poisons the queue.
  static Future<T> _runSerialized<T>(Future<T> Function() operation) {
    final completer = Completer<T>();
    // Only chain off the existing tail while operations actually overlap; when
    // the queue is idle, begin a fresh chain in the current zone.
    final previous = _pendingReminderOps == 0
        ? Future<void>.value()
        : _reminderPrefTail;
    _pendingReminderOps++;
    _reminderPrefTail = completer.future.then((_) {}, onError: (_) {});
    previous.whenComplete(() async {
      try {
        completer.complete(await operation());
      } catch (e, st) {
        completer.completeError(e, st);
      } finally {
        _pendingReminderOps--;
      }
    });
    return completer.future;
  }

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

  /// Removes the onboarding status for ONE account.
  ///
  /// Targeted by account id so a shared device keeps every other account's
  /// onboarding progress. Used by the Account Deletion V1 completion cleanup
  /// (CaleeMobile #556); never a prefix sweep, which would take other
  /// accounts' rows with it.
  Future<void> clearCalendarOnboardingStatus(String accountId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_calendarOnboardingKey(accountId));
    } catch (_) {
      // Best-effort; a cleanup failure must not block terminal handling.
    }
  }

  /// Removes the four account-owned display preferences cached on this device.
  ///
  /// These mirror Hub-owned account settings (week start, clock format, and the
  /// two default collection ids, which are Hub calendar identifiers belonging to
  /// the deleted account). They are device-global keys but ACCOUNT-OWNED data,
  /// so a completed deletion must not leave them behind for the next account to
  /// inherit. Guest/local calendar subscriptions live under their own key and
  /// are deliberately untouched -- as is every other preference on the device.
  Future<void> clearAccountOwnedPreferences() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      for (final key in const [
        _firstDayOfWeekKey,
        _timeFormatKey,
        _defaultCalendarIdKey,
        _defaultTaskListIdKey,
      ]) {
        await prefs.remove(key);
      }
    } catch (_) {
      // Best-effort; a cleanup failure must not block terminal handling.
    }
  }

  /// Forgets the reminder-enabled value belonging to ONE account.
  ///
  /// Runs through the same serialized read-modify-write transaction as
  /// [saveCalendarRemindersEnabled], so removing one account's row can never
  /// lose a concurrent write for another. Every other account's value, and the
  /// legacy-claim bookkeeping, are preserved exactly: this removes a row, it
  /// does not reset the record.
  ///
  /// Deliberately silent about failure. It is called from terminal deletion
  /// handling, where a stale boolean for an account that no longer exists is a
  /// nuisance, not a correctness problem -- and where nothing useful could be
  /// retried anyway.
  Future<void> forgetCalendarRemindersForOwner(String ownerKey) {
    return _runSerialized(() async {
      try {
        final store = await _openReminderStore();
        final loaded = await _loadOrMigrateRecord(store);
        final record = loaded.record;
        if (record == null) return;
        if (!record.valuesByOwner.containsKey(ownerKey)) return;

        final remaining = Map<String, bool>.from(record.valuesByOwner)
          ..remove(ownerKey);
        await _commitRecord(store, record.copyWith(valuesByOwner: remaining));
      } catch (_) {
        // Best-effort; see the doc comment.
      }
    });
  }

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

// ── Reminder-record load/migration helpers ────────────────────────────────────

/// Result of reading or migrating the reminder-preference record: either a
/// usable [record], or an [unavailableCategory] describing why it could not be
/// obtained (storage failure, malformed/unsupported record, or a failed
/// migration commit) — never a fabricated default.
class _ReminderRecordLoad {
  const _ReminderRecordLoad.ok(this.record) : unavailableCategory = null;
  const _ReminderRecordLoad.unavailable(this.unavailableCategory)
    : record = null;

  final CalendarReminderPreferenceRecord? record;
  final String? unavailableCategory;
}

/// A record freshly built from the legacy multi-key format, plus whether it must
/// be committed (there was pre-existing state to migrate) and which old keys to
/// remove best-effort after a successful commit.
class _MigratedRecord {
  const _MigratedRecord({
    required this.record,
    required this.needsCommit,
    required this.legacyKeys,
  });

  final CalendarReminderPreferenceRecord record;
  final bool needsCommit;
  final List<String> legacyKeys;
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
