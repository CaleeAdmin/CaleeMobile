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
  bool isLoadingPreferences = false;
  bool isOpeningFamily = false;
  Object? error;

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
    preferences = await repository.setFirstDayOfWeek(
      current: preferences,
      value: value,
    );
    notifyListeners();
  }

  Future<void> setTimeFormat(TimeFormatPref value) async {
    preferences = await repository.setTimeFormat(
      current: preferences,
      value: value,
    );
    notifyListeners();
  }

  Future<void> setDefaultCalendar(ClientCalendar? calendar) async {
    preferences = await repository.setDefaultCalendar(
      current: preferences,
      calendar: calendar,
    );
    notifyListeners();
  }

  Future<void> setDefaultTaskList(ClientCalendar? calendar) async {
    preferences = await repository.setDefaultTaskList(
      current: preferences,
      calendar: calendar,
    );
    notifyListeners();
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
