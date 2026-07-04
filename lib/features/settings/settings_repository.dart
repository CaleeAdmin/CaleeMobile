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
    final results = await Future.wait([
      _caleePrefs.load(),
      hubClient.calendars(accessToken: accessToken),
    ]);

    var prefs = results[0] as StoredPreferences;
    final allCalendars = (results[1] as ClientCalendarList).calendars;

    final writableCalendars = allCalendars
        .where((c) => c.isCalendarKind && !c.readOnly)
        .toList();
    final calId = prefs.defaultCalendarId;
    if (calId != null && !writableCalendars.any((c) => c.id == calId)) {
      await _caleePrefs.saveDefaultCalendarId(null);
      prefs = StoredPreferences(
        firstDayOfWeek: prefs.firstDayOfWeek,
        timeFormat: prefs.timeFormat,
        defaultCalendarId: null,
        defaultTaskListId: prefs.defaultTaskListId,
      );
    }

    final taskCalendars = allCalendars.where((c) => c.isTaskKind).toList();
    final taskListId = prefs.defaultTaskListId;
    if (taskListId != null && !taskCalendars.any((c) => c.id == taskListId)) {
      await _caleePrefs.saveDefaultTaskListId(null);
      prefs = StoredPreferences(
        firstDayOfWeek: prefs.firstDayOfWeek,
        timeFormat: prefs.timeFormat,
        defaultCalendarId: prefs.defaultCalendarId,
        defaultTaskListId: null,
      );
    }

    return SettingsOverview(preferences: prefs, calendars: allCalendars);
  }

  Future<StoredPreferences> setFirstDayOfWeek({
    required StoredPreferences current,
    required FirstDayOfWeek value,
  }) async {
    await _caleePrefs.saveFirstDayOfWeek(value);
    return StoredPreferences(
      firstDayOfWeek: value,
      timeFormat: current.timeFormat,
      defaultCalendarId: current.defaultCalendarId,
      defaultTaskListId: current.defaultTaskListId,
    );
  }

  Future<StoredPreferences> setTimeFormat({
    required StoredPreferences current,
    required TimeFormatPref value,
  }) async {
    await _caleePrefs.saveTimeFormat(value);
    return StoredPreferences(
      firstDayOfWeek: current.firstDayOfWeek,
      timeFormat: value,
      defaultCalendarId: current.defaultCalendarId,
      defaultTaskListId: current.defaultTaskListId,
    );
  }

  Future<StoredPreferences> setDefaultCalendar({
    required StoredPreferences current,
    ClientCalendar? calendar,
  }) async {
    await _caleePrefs.saveDefaultCalendarId(calendar?.id);
    return StoredPreferences(
      firstDayOfWeek: current.firstDayOfWeek,
      timeFormat: current.timeFormat,
      defaultCalendarId: calendar?.id,
      defaultTaskListId: current.defaultTaskListId,
    );
  }

  Future<StoredPreferences> setDefaultTaskList({
    required StoredPreferences current,
    ClientCalendar? calendar,
  }) async {
    await _caleePrefs.saveDefaultTaskListId(calendar?.id);
    return StoredPreferences(
      firstDayOfWeek: current.firstDayOfWeek,
      timeFormat: current.timeFormat,
      defaultCalendarId: current.defaultCalendarId,
      defaultTaskListId: calendar?.id,
    );
  }

  Future<bool> loadCalendarRemindersEnabled() =>
      _caleePrefs.loadCalendarRemindersEnabled();

  Future<void> saveCalendarRemindersEnabled(bool enabled) =>
      _caleePrefs.saveCalendarRemindersEnabled(enabled);

  Future<ClientBootstrap> ensureDefaultFamilyAndRefreshBootstrap() async {
    await hubClient.ensureDefaultFamily(accessToken: accessToken);
    return hubClient.bootstrap(accessToken: accessToken);
  }
}
