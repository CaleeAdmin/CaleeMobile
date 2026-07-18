import '../../data/api/calee_hub_client.dart';
import '../../data/auth/calee_preferences.dart';
import '../../data/models/client_bootstrap.dart';
import '../../data/models/client_calendar.dart';

// ─── Public model ─────────────────────────────────────────────────────────────

class SettingsOverview {
  const SettingsOverview({required this.preferences, required this.calendars});

  final StoredPreferences preferences;
  final List<ClientCalendar> calendars;
}

// ─── Repository ───────────────────────────────────────────────────────────────

class SettingsRepository {
  SettingsRepository({
    required this.hubClient,
    required this.accessToken,
    CaleePreferences? preferences,
  }) : _caleePrefs = preferences ?? CaleePreferences();

  final CaleeHubClient hubClient;
  final String accessToken;
  final CaleePreferences _caleePrefs;

  Future<SettingsOverview> loadOverview() async {
    final localPrefs = await _caleePrefs.load();

    StoredPreferences? hubPrefs;
    ClientCalendarList? calendarList;

    await Future.wait([
      () async {
        try {
          hubPrefs = (await hubClient.preferences(
            accessToken: accessToken,
          )).toStoredPreferences();
        } catch (_) {
          hubPrefs = null;
        }
      }(),
      () async {
        calendarList = await hubClient.calendars(accessToken: accessToken);
      }(),
    ]);

    final hubPrefsAvailable = hubPrefs != null;
    var prefs = hubPrefs ?? localPrefs;
    if (hubPrefsAvailable) {
      await _caleePrefs.saveAll(prefs);
    }

    final allCalendars = calendarList!.calendars;

    final writableCalendars = allCalendars
        .where((c) => c.isCalendarKind && !c.readOnly)
        .toList();
    final calId = prefs.defaultCalendarId;
    if (calId != null && !writableCalendars.any((c) => c.id == calId)) {
      prefs = prefs.copyWith(clearDefaultCalendarId: true);
      await _clearStaleDefault(
        hubPrefsAvailable: hubPrefsAvailable,
        clearDefaultCalendarId: true,
      );
    }

    final taskCalendars = allCalendars.where((c) => c.isTaskKind).toList();
    final taskListId = prefs.defaultTaskListId;
    if (taskListId != null && !taskCalendars.any((c) => c.id == taskListId)) {
      prefs = prefs.copyWith(clearDefaultTaskListId: true);
      await _clearStaleDefault(
        hubPrefsAvailable: hubPrefsAvailable,
        clearDefaultTaskListId: true,
      );
    }

    return SettingsOverview(preferences: prefs, calendars: allCalendars);
  }

  /// A stored default calendar/task list id no longer exists, is read-only,
  /// or was deleted. Clearing it must never surface as a page-level error:
  /// the local cache is always cleared, and the Hub is patched best-effort
  /// only when it is the confirmed source of truth for this load.
  Future<void> _clearStaleDefault({
    required bool hubPrefsAvailable,
    bool clearDefaultCalendarId = false,
    bool clearDefaultTaskListId = false,
  }) async {
    if (clearDefaultCalendarId) {
      await _caleePrefs.saveDefaultCalendarId(null);
    }
    if (clearDefaultTaskListId) {
      await _caleePrefs.saveDefaultTaskListId(null);
    }

    if (!hubPrefsAvailable) return;
    try {
      await hubClient.updatePreferences(
        accessToken: accessToken,
        clearDefaultCalendarId: clearDefaultCalendarId,
        clearDefaultTaskListId: clearDefaultTaskListId,
      );
    } catch (_) {
      // Best-effort; a stale default is still safely treated as Automatic
      // locally even if the Hub couldn't be patched right now.
    }
  }

  Future<StoredPreferences> setFirstDayOfWeek({
    required StoredPreferences current,
    required FirstDayOfWeek value,
  }) async {
    final updated = await hubClient.updatePreferences(
      accessToken: accessToken,
      firstDayOfWeek: value,
    );
    final prefs = updated.toStoredPreferences();
    await _caleePrefs.saveAll(prefs);
    return prefs;
  }

  Future<StoredPreferences> setTimeFormat({
    required StoredPreferences current,
    required TimeFormatPref value,
  }) async {
    final updated = await hubClient.updatePreferences(
      accessToken: accessToken,
      timeFormat: value,
    );
    final prefs = updated.toStoredPreferences();
    await _caleePrefs.saveAll(prefs);
    return prefs;
  }

  Future<StoredPreferences> setDefaultCalendar({
    required StoredPreferences current,
    ClientCalendar? calendar,
  }) async {
    final updated = await hubClient.updatePreferences(
      accessToken: accessToken,
      defaultCalendarId: calendar?.id,
      clearDefaultCalendarId: calendar == null,
    );
    final prefs = updated.toStoredPreferences();
    await _caleePrefs.saveAll(prefs);
    return prefs;
  }

  Future<StoredPreferences> setDefaultTaskList({
    required StoredPreferences current,
    ClientCalendar? calendar,
  }) async {
    final updated = await hubClient.updatePreferences(
      accessToken: accessToken,
      defaultTaskListId: calendar?.id,
      clearDefaultTaskListId: calendar == null,
    );
    final prefs = updated.toStoredPreferences();
    await _caleePrefs.saveAll(prefs);
    return prefs;
  }

  Future<bool> loadCalendarRemindersEnabled({required String ownerKey}) =>
      _caleePrefs.loadCalendarRemindersEnabled(ownerKey: ownerKey);

  Future<void> saveCalendarRemindersEnabled({
    required String ownerKey,
    required bool enabled,
  }) => _caleePrefs.saveCalendarRemindersEnabled(
    ownerKey: ownerKey,
    enabled: enabled,
  );

  Future<ClientBootstrap> ensureDefaultFamilyAndRefreshBootstrap() async {
    await hubClient.ensureDefaultFamily(accessToken: accessToken);
    return hubClient.bootstrap(accessToken: accessToken);
  }
}
