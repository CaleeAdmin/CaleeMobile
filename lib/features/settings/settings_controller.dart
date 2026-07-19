import 'package:flutter/foundation.dart';

import '../../data/auth/calee_preferences.dart';
import '../../data/models/client_bootstrap.dart';
import '../../data/models/client_calendar.dart';
import '../notifications/calendar_notification_candidates.dart';
import 'settings_repository.dart';

class SettingsController extends ChangeNotifier {
  SettingsController({
    required this.repository,
    required ClientBootstrap initialBootstrap,
  }) : bootstrap = initialBootstrap;

  final SettingsRepository repository;

  /// Privacy-safe owner key for the current account, used to scope the
  /// reminder-enabled preference so two accounts on the same device keep
  /// independent values (never a raw account ID). `null` when the bootstrap
  /// carries no usable account ID, so an owner key is never derived from invalid
  /// bootstrap data.
  String? get _reminderOwnerKey => tryReminderOwnerKey(bootstrap.account.id);

  // ── State ─────────────────────────────────────────────────────────────────

  ClientBootstrap bootstrap;
  StoredPreferences preferences = const StoredPreferences();
  List<ClientCalendar> calendars = [];

  /// The displayed reminders-enabled value (product default off). Only ever set
  /// from a trustworthy source: a successful `loaded`/`absent` read or a
  /// confirmed save. An `unavailable` read never overwrites it, so a previously
  /// loaded value is preserved across a transient storage failure.
  bool calendarRemindersEnabled = false;

  /// How the last reminder-preference read resolved. Drives whether the switch
  /// may be trusted and whether the "couldn't load" message is shown.
  CalendarReminderPreferenceLoadStatus reminderPreferenceStatus =
      CalendarReminderPreferenceLoadStatus.absent;

  /// Whether any trustworthy reminder value has ever loaded for this account. If
  /// false while [reminderPreferenceStatus] is unavailable, the switch has no
  /// value to trust and must be disabled.
  bool _hasTrustworthyReminderValue = false;

  bool isLoadingPreferences = false;
  bool isOpeningFamily = false;
  Object? error;

  /// Whether the reminder setting is currently unavailable (storage read
  /// failed). Surfaced as a concise, non-blocking message — never a full-page
  /// error.
  bool get reminderPreferenceUnavailable =>
      reminderPreferenceStatus ==
      CalendarReminderPreferenceLoadStatus.unavailable;

  /// Whether the reminders switch should be interactive. Disabled while
  /// preferences are loading, or while the value is unavailable and no
  /// trustworthy value has ever loaded (so the switch shows nothing false).
  bool get isReminderSwitchEnabled =>
      !isLoadingPreferences &&
      !(reminderPreferenceUnavailable && !_hasTrustworthyReminderValue);

  /// Transient error from the most recent preference save attempt. Unlike
  /// [error], this never blocks the page: the previous preference value is
  /// restored and the caller (e.g. SettingsPage) surfaces this as a
  /// dismissable message such as a SnackBar.
  Object? preferencesSaveError;

  // ── Load / refresh ────────────────────────────────────────────────────────

  Future<void> load() async {
    isLoadingPreferences = true;
    error = null;
    notifyListeners();

    try {
      final overview = await repository.loadOverview();
      preferences = overview.preferences;
      calendars = overview.calendars;
      error = null;
      await _loadReminderPreference();
    } catch (e) {
      error = e;
    } finally {
      isLoadingPreferences = false;
      notifyListeners();
    }
  }

  Future<void> refresh() => load();

  /// Loads the reminders-enabled preference using the structured result, so an
  /// unavailable read is represented accurately instead of being shown as a
  /// trustworthy `false`.
  ///
  /// * `loaded` / `absent` set the displayed value from a trustworthy source.
  /// * `unavailable` preserves any previously loaded value (never overwriting it
  ///   with false) and flags the switch as untrustworthy; if nothing has ever
  ///   loaded, the switch is disabled. A concise, non-blocking message is
  ///   surfaced by the page — the page-level [error] is deliberately untouched
  ///   so other Settings sections remain usable and a retry stays possible.
  Future<void> _loadReminderPreference() async {
    final ownerKey = _reminderOwnerKey;
    if (ownerKey == null) return;
    final CalendarReminderPreferenceLoadResult result;
    try {
      result = await repository.loadCalendarRemindersEnabledResult(
        ownerKey: ownerKey,
      );
    } catch (_) {
      // Treat an unexpected throw like an unavailable read: preserve any
      // previously loaded value rather than fabricating false.
      reminderPreferenceStatus =
          CalendarReminderPreferenceLoadStatus.unavailable;
      return;
    }
    reminderPreferenceStatus = result.status;
    switch (result.status) {
      case CalendarReminderPreferenceLoadStatus.loaded:
        calendarRemindersEnabled = result.enabled ?? false;
        _hasTrustworthyReminderValue = true;
      case CalendarReminderPreferenceLoadStatus.absent:
        calendarRemindersEnabled = false;
        _hasTrustworthyReminderValue = true;
      case CalendarReminderPreferenceLoadStatus.unavailable:
        // Preserve the previously displayed value; do not present false.
        break;
    }
  }

  // ── Preference mutations ──────────────────────────────────────────────────

  Future<void> setFirstDayOfWeek(FirstDayOfWeek value) async {
    await _mutatePreferences(
      () => repository.setFirstDayOfWeek(current: preferences, value: value),
    );
  }

  Future<void> setTimeFormat(TimeFormatPref value) async {
    await _mutatePreferences(
      () => repository.setTimeFormat(current: preferences, value: value),
    );
  }

  Future<void> setDefaultCalendar(ClientCalendar? calendar) async {
    await _mutatePreferences(
      () => repository.setDefaultCalendar(
        current: preferences,
        calendar: calendar,
      ),
    );
  }

  Future<void> setDefaultTaskList(ClientCalendar? calendar) async {
    await _mutatePreferences(
      () => repository.setDefaultTaskList(
        current: preferences,
        calendar: calendar,
      ),
    );
  }

  /// Applies a preference-setter call, rolling back to the previous value and
  /// recording [preferencesSaveError] (without touching the page-level
  /// [error]) if the Hub PATCH fails.
  Future<void> _mutatePreferences(
    Future<StoredPreferences> Function() mutate,
  ) async {
    final previous = preferences;
    preferencesSaveError = null;
    try {
      preferences = await mutate();
    } catch (e) {
      preferences = previous;
      preferencesSaveError = e;
    } finally {
      notifyListeners();
    }
  }

  /// Persists the reminders-enabled preference for the current account.
  ///
  /// Returns `true` only when the new value actually persisted. On failure (a
  /// storage error, or an invalid account identity) the displayed
  /// [calendarRemindersEnabled] is left at its previous value — never showing a
  /// change that did not persist — and a transient [preferencesSaveError] is
  /// recorded (the page-level [error] is untouched, so the page stays usable and
  /// the SnackBar mechanism can surface it). The caller gates any reminder
  /// reconciliation or cleanup on the returned boolean.
  Future<bool> setCalendarRemindersEnabled(bool value) async {
    final ownerKey = _reminderOwnerKey;
    if (ownerKey == null) {
      // No usable account identity: never derive an owner key from invalid
      // bootstrap data. Preserve the switch and surface a transient error.
      preferencesSaveError = StateError(
        'reminder preference has no valid account owner',
      );
      notifyListeners();
      return false;
    }
    preferencesSaveError = null;
    try {
      await repository.saveCalendarRemindersEnabled(
        ownerKey: ownerKey,
        enabled: value,
      );
      // Only reflect the change after the write is confirmed. A confirmed save
      // is a trustworthy value and clears any prior unavailable state.
      calendarRemindersEnabled = value;
      reminderPreferenceStatus = CalendarReminderPreferenceLoadStatus.loaded;
      _hasTrustworthyReminderValue = true;
      notifyListeners();
      return true;
    } catch (e) {
      // Persistence failed — leave the previous switch value in place (rolled
      // back) and surface a transient, non-blocking error.
      preferencesSaveError = e;
      notifyListeners();
      return false;
    }
  }

  // ── Family setup ──────────────────────────────────────────────────────────

  Future<ClientBootstrap> ensureDefaultFamilyAndRefreshBootstrap() async {
    isOpeningFamily = true;
    error = null;
    notifyListeners();

    try {
      final fresh = await repository.ensureDefaultFamilyAndRefreshBootstrap();
      bootstrap = fresh;
      error = null;
      return fresh;
    } catch (e) {
      error = e;
      rethrow;
    } finally {
      isOpeningFamily = false;
      notifyListeners();
    }
  }
}
