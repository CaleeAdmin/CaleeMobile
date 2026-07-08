import 'package:flutter/foundation.dart';

import '../../data/auth/calee_preferences.dart';
import '../../data/models/client_bootstrap.dart';
import '../../data/models/client_calendar.dart';
import 'settings_repository.dart';

class SettingsController extends ChangeNotifier {
  SettingsController({
    required this.repository,
    required ClientBootstrap initialBootstrap,
  }) : bootstrap = initialBootstrap;

  final SettingsRepository repository;

  // ── State ─────────────────────────────────────────────────────────────────

  ClientBootstrap bootstrap;
  StoredPreferences preferences = const StoredPreferences();
  List<ClientCalendar> calendars = [];
  bool calendarRemindersEnabled = false;
  bool isLoadingPreferences = false;
  bool isOpeningFamily = false;
  Object? error;

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
      try {
        calendarRemindersEnabled = await repository
            .loadCalendarRemindersEnabled();
      } catch (_) {
        // Best-effort; keep default of false.
      }
    } catch (e) {
      error = e;
    } finally {
      isLoadingPreferences = false;
      notifyListeners();
    }
  }

  Future<void> refresh() => load();

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

  Future<void> setCalendarRemindersEnabled(bool value) async {
    calendarRemindersEnabled = value;
    notifyListeners();
    await repository.saveCalendarRemindersEnabled(value);
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
