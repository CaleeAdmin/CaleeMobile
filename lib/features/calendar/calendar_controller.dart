import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../data/auth/calee_preferences.dart';
import '../../data/models/calendar_service_error.dart';
import '../../data/models/client_calendar.dart';
import '../notifications/calendar_reminder_coordinator.dart';
import 'calendar_repository.dart';
import 'newly_added_calendar_visibility.dart';

class CalendarController extends ChangeNotifier {
  CalendarController({
    required this.repository,
    this.onRequestReminderRefresh,
    NewlyAddedCalendarVisibility? newlyAddedCalendarVisibility,
    this.syncConvergenceInterval = const Duration(seconds: 5),
    this.syncConvergenceMaxAttempts = 6,
  }) : newlyAddedCalendarVisibility =
           newlyAddedCalendarVisibility ??
           NewlyAddedCalendarVisibility.instance {
    final now = DateTime.now();
    today = DateTime(now.year, now.month, now.day);
    selectedDay = today;
    selectedMonth = DateTime(now.year, now.month, 1);
    gridStart = CalendarRepository.computeGridStart(
      selectedMonth,
      preferences.firstDayOfWeek,
    );
  }

  final CalendarRepository repository;

  /// Calendars added since the last load, which must be visible as soon as
  /// they appear. See [NewlyAddedCalendarVisibility].
  final NewlyAddedCalendarVisibility newlyAddedCalendarVisibility;

  /// Gap between automatic re-checks while a just-added subscription calendar
  /// is still syncing. See [_scheduleSyncConvergence].
  final Duration syncConvergenceInterval;

  /// How many automatic re-checks a syncing calendar gets before Calee stops
  /// and says so. Bounded on purpose: a feed that never converges must become
  /// a passive, honest "Still syncing. Pull to refresh." rather than an
  /// indefinite spinner and an indefinite poll.
  final int syncConvergenceMaxAttempts;

  /// Invoked to request an independent upcoming-reminder refresh after an
  /// explicit change (event CRUD) or a manual calendar refresh. Deliberately
  /// NOT called from [loadMonth]: month navigation must never reschedule or
  /// cancel device reminders. The callback owns error handling; failures here
  /// are swallowed so a reminder refresh can never make a succeeded event
  /// operation look failed.
  final Future<void> Function(CalendarReminderRefreshReason reason)?
  onRequestReminderRefresh;

  // ── State ─────────────────────────────────────────────────────────────────

  late DateTime today;
  late DateTime selectedMonth;
  late DateTime selectedDay;
  late DateTime gridStart;
  StoredPreferences preferences = const StoredPreferences();
  List<ClientCalendar> calendars = [];
  List<ClientEvent> events = [];
  List<CalendarServiceError> calendarServiceErrors = [];
  bool isLoading = false;
  Object? error;
  final Set<String> hiddenCalendarIds = {};

  // ── Load / refresh ────────────────────────────────────────────────────────

  /// Id of the most recently *started* load. A load whose id no longer matches
  /// has been superseded (by month navigation, a manual refresh, CRUD, or a
  /// newer background refresh) and must drop its result instead of overwriting
  /// newer state.
  int _loadSequence = 0;

  /// True while a load started here is still awaiting the repository. Only
  /// [refreshInBackground] consults it: explicit loads (navigation, manual
  /// refresh, CRUD) must always run, but an automatic refresh has nothing to
  /// add while the same range is already being fetched.
  bool _loadInFlight = false;

  bool _disposed = false;

  // ── Initial-sync convergence ──────────────────────────────────────────────

  Timer? _syncConvergenceTimer;
  int _syncConvergenceAttempts = 0;

  /// True once the automatic re-checks have been used up and a calendar is
  /// still syncing. The UI switches from "Syncing…" to a passive
  /// "Still syncing. Pull to refresh." — Calee stops polling but never
  /// pretends the calendar is empty.
  bool syncConvergenceExhausted = false;

  /// Visible calendars Hub has told us are still completing their first
  /// authoritative sync. Hidden calendars are excluded: a calendar the user
  /// has switched off must not put a banner on the screen.
  List<ClientCalendar> get syncingCalendars => calendars
      .where((cal) => cal.isInitialSyncPending && isCalendarVisible(cal.id))
      .toList(growable: false);

  /// Visible calendars whose first authoritative sync failed.
  List<ClientCalendar> get syncFailedCalendars => calendars
      .where((cal) => cal.hasInitialSyncError && isCalendarVisible(cal.id))
      .toList(growable: false);

  @override
  void dispose() {
    _disposed = true;
    // Nothing may keep polling past dispose: the timer is the only thing here
    // that outlives a build, so cancelling it is what makes "no polling after
    // dispose" true rather than merely likely.
    _cancelSyncConvergence();
    super.dispose();
  }

  /// Stops the automatic re-check loop and forgets its progress. Called on
  /// dispose, when the app is backgrounded ([pauseSyncConvergence]), and
  /// whenever a load shows nothing is syncing any more.
  void _cancelSyncConvergence() {
    _syncConvergenceTimer?.cancel();
    _syncConvergenceTimer = null;
  }

  /// Stops re-checking while the app is not in the foreground. The next
  /// resume drives a [refreshInBackground], which restarts the loop from
  /// scratch if anything is still syncing.
  void pauseSyncConvergence() {
    _cancelSyncConvergence();
  }

  /// Arms one automatic re-check when — and only when — a visible calendar is
  /// still syncing.
  ///
  /// Deliberately reuses [refreshInBackground] (and therefore the existing
  /// repository and load-sequencing) rather than adding a second networking
  /// path: the re-check is an ordinary silent reload, it cannot flash a
  /// spinner over the calendar, and [refreshInBackground] already declines
  /// while another load is in flight, so re-checks cannot stack.
  void _scheduleSyncConvergence() {
    _cancelSyncConvergence();

    if (_disposed) return;

    if (syncingCalendars.isEmpty) {
      // Converged (or the calendar was hidden/removed). Reset so a LATER add
      // gets its own full budget of re-checks.
      _syncConvergenceAttempts = 0;
      syncConvergenceExhausted = false;
      return;
    }

    if (_syncConvergenceAttempts >= syncConvergenceMaxAttempts) {
      syncConvergenceExhausted = true;
      return;
    }

    _syncConvergenceTimer = Timer(syncConvergenceInterval, () {
      _syncConvergenceTimer = null;
      if (_disposed) return;
      _syncConvergenceAttempts++;
      unawaited(refreshInBackground());
    });
  }

  Future<void> loadMonth() => _load(showLoadingIndicator: true);

  /// Silently refetches the month already on screen.
  ///
  /// Unlike [loadMonth] this never raises the blocking loading state and never
  /// discards the last good snapshot, so an automatic refresh cannot flash a
  /// full-screen spinner (or an error screen) over a calendar the user is
  /// reading. It is skipped outright while another load is already fetching,
  /// so repeated lifecycle notifications cannot stack overlapping requests.
  ///
  /// Deliberately does NOT request a reminder refresh: lifecycle-driven
  /// reminder reconciliation is owned by the app-level observer
  /// ([CalendarReminderRefreshReason.appResumed]).
  Future<void> refreshInBackground() async {
    if (_loadInFlight) return;
    await _load(showLoadingIndicator: false);
  }

  Future<void> _load({required bool showLoadingIndicator}) async {
    final requestId = ++_loadSequence;
    _loadInFlight = true;

    if (showLoadingIndicator) {
      isLoading = true;
      error = null;
      notifyListeners();
    }

    CalendarOverview? overview;
    Object? failure;
    try {
      overview = await repository.loadMonth(selectedMonth: selectedMonth);
    } catch (e) {
      failure = e;
    }

    // Disposed, or superseded by a load started after this one: drop the
    // result. The newer load owns _loadInFlight and publishes its own state.
    if (_disposed || requestId != _loadSequence) return;
    _loadInFlight = false;

    if (overview == null) {
      // A failed background refresh leaves the last good snapshot exactly as
      // it was; only an explicit load may replace the screen with an error.
      if (!showLoadingIndicator) return;
      error = failure;
      calendarServiceErrors = [];
      isLoading = false;
      notifyListeners();
      return;
    }

    preferences = overview.preferences;
    gridStart = overview.gridStart;
    calendars = overview.calendars;
    events = overview.events;
    calendarServiceErrors = overview.serviceErrors;
    // NOTE: loading a month intentionally does not touch device reminders.
    // Reminder scheduling is owned by CalendarReminderCoordinator and driven
    // by an independent upcoming-event window, so navigating months never
    // cancels or rebuilds reminders. See onRequestReminderRefresh.
    hiddenCalendarIds.removeWhere(
      (id) => !calendars.any((cal) => cal.id == id),
    );
    // A calendar the user has just added is visible on arrival, whatever a
    // same-id entry left behind in the hidden set says. Only those ids are
    // dropped, so every other hidden choice survives untouched.
    hiddenCalendarIds.removeAll(newlyAddedCalendarVisibility.take());
    error = null;
    isLoading = false;
    // Arm (or stand down) the automatic re-check for a just-added calendar
    // that is still syncing. Runs after hiddenCalendarIds is settled so a
    // calendar the user has switched off is never polled for.
    _scheduleSyncConvergence();
    notifyListeners();
  }

  /// A user-initiated calendar refresh. Unlike month navigation, this also
  /// requests a (throttled) reminder refresh once the data reload succeeds.
  Future<void> refresh() async {
    await loadMonth();
    if (error == null) {
      _requestReminderRefresh(CalendarReminderRefreshReason.manualRefresh);
    }
  }

  /// Fire-and-forget request for an upcoming-reminder refresh. Never throws
  /// into the caller: a reminder refresh failure must not turn a successful
  /// event operation into a failed one.
  void _requestReminderRefresh(CalendarReminderRefreshReason reason) {
    final callback = onRequestReminderRefresh;
    if (callback == null) return;
    unawaited(Future<void>.sync(() => callback(reason)).catchError((_) {}));
  }

  // ── Navigation ────────────────────────────────────────────────────────────

  void goToToday() {
    final now = DateTime.now();
    final newToday = DateTime(now.year, now.month, now.day);
    final newMonth = DateTime(now.year, now.month, 1);
    final sameMonth =
        newMonth.year == selectedMonth.year &&
        newMonth.month == selectedMonth.month;
    today = newToday;
    selectedDay = newToday;
    selectedMonth = newMonth;
    notifyListeners();
    if (!sameMonth) loadMonth();
  }

  void previousMonth() {
    selectedMonth = DateTime(selectedMonth.year, selectedMonth.month - 1, 1);
    if (selectedDay.year != selectedMonth.year ||
        selectedDay.month != selectedMonth.month) {
      selectedDay = selectedMonth;
    }
    notifyListeners();
    loadMonth();
  }

  void nextMonth() {
    selectedMonth = DateTime(selectedMonth.year, selectedMonth.month + 1, 1);
    if (selectedDay.year != selectedMonth.year ||
        selectedDay.month != selectedMonth.month) {
      selectedDay = selectedMonth;
    }
    notifyListeners();
    loadMonth();
  }

  void selectDay(DateTime day) {
    final tapMonth = DateTime(day.year, day.month, 1);
    final sameMonth =
        tapMonth.year == selectedMonth.year &&
        tapMonth.month == selectedMonth.month;
    selectedDay = day;
    if (!sameMonth) selectedMonth = tapMonth;
    notifyListeners();
    if (!sameMonth) loadMonth();
  }

  void selectSearchResult(ClientEvent event) {
    final start = DateTime.tryParse(event.startsAt)?.toLocal();
    if (start == null) return;
    final tapMonth = DateTime(start.year, start.month, 1);
    final sameMonth =
        tapMonth.year == selectedMonth.year &&
        tapMonth.month == selectedMonth.month;
    selectedDay = DateTime(start.year, start.month, start.day);
    if (!sameMonth) selectedMonth = tapMonth;
    notifyListeners();
    if (!sameMonth) loadMonth();
  }

  // ── Calendar visibility ───────────────────────────────────────────────────

  void toggleCalendarVisibility(String calendarId) {
    if (hiddenCalendarIds.contains(calendarId)) {
      hiddenCalendarIds.remove(calendarId);
    } else {
      hiddenCalendarIds.add(calendarId);
    }
    notifyListeners();
  }

  void showAllCalendars() {
    hiddenCalendarIds.clear();
    notifyListeners();
  }

  bool isCalendarVisible(String calendarId) =>
      !hiddenCalendarIds.contains(calendarId);

  // ── CRUD ──────────────────────────────────────────────────────────────────

  Future<void> createEvent({
    required ClientCalendar calendar,
    required String title,
    required DateTime startsAt,
    required DateTime endsAt,
    required bool allDay,
    String? location,
    String? description,
    String? recurrence,
  }) async {
    await repository.createEvent(
      calendar: calendar,
      title: title,
      startsAt: startsAt,
      endsAt: endsAt,
      allDay: allDay,
      location: location,
      description: description,
      recurrence: recurrence,
    );
    await loadMonth();
    _requestReminderRefresh(CalendarReminderRefreshReason.eventCreated);
  }

  /// [destinationCalendar] is where the event should end up. When it names a
  /// calendar other than the one the event is in, Hub moves the event there as
  /// part of this same mutation. Null (and a destination equal to the event's
  /// current calendar) is an ordinary in-place update.
  ///
  /// The unconditional [loadMonth] below is what makes a move converge: the
  /// event's calendar has changed, so its colour, its visibility under the
  /// hidden-calendar filter and which calendar it groups under are all
  /// different now. Reloading from the server is the only way to get all of
  /// that right, and it is why nothing here patches the local copy.
  Future<void> updateEvent({
    required ClientEvent event,
    required String title,
    required DateTime? startsAt,
    required DateTime? endsAt,
    required bool? allDay,
    String? location,
    String? description,
    String? recurrence,
    String? editScope,
    ClientCalendar? destinationCalendar,
  }) async {
    await repository.updateEvent(
      event: event,
      title: title,
      startsAt: startsAt,
      endsAt: endsAt,
      allDay: allDay,
      location: location,
      description: description,
      recurrence: recurrence,
      editScope: editScope,
      destinationCalendar: destinationCalendar,
    );
    await loadMonth();
    _requestReminderRefresh(CalendarReminderRefreshReason.eventUpdated);
  }

  Future<void> deleteEvent({
    required ClientEvent event,
    String? deleteScope,
  }) async {
    await repository.deleteEvent(event: event, deleteScope: deleteScope);
    await loadMonth();
    _requestReminderRefresh(CalendarReminderRefreshReason.eventDeleted);
  }

  // ── Queries ───────────────────────────────────────────────────────────────

  ClientCalendar? calendarForEvent(ClientEvent event) {
    for (final calendar in calendars) {
      if (calendar.id == event.calendarId ||
          calendar.id.endsWith(':${event.calendarId}') ||
          event.calendarId.endsWith(':${calendar.id}')) {
        return calendar;
      }
    }
    return null;
  }

  List<ClientEvent> eventsForDay(DateTime day) {
    final result = <ClientEvent>[];
    for (final event in events) {
      final cal = calendarForEvent(event);
      if (cal != null && !isCalendarVisible(cal.id)) continue;
      final start = DateTime.tryParse(event.startsAt)?.toLocal();
      if (start == null) continue;
      if (event.allDay) {
        final end = DateTime.tryParse(event.endsAt)?.toLocal();
        final startDate = DateTime(start.year, start.month, start.day);
        // all-day endsAt is exclusive
        final endDate = end != null
            ? DateTime(
                end.year,
                end.month,
                end.day,
              ).subtract(const Duration(days: 1))
            : startDate;
        final check = DateTime(day.year, day.month, day.day);
        if (!check.isBefore(startDate) && !check.isAfter(endDate)) {
          result.add(event);
        }
      } else {
        if (start.year == day.year &&
            start.month == day.month &&
            start.day == day.day) {
          result.add(event);
        }
      }
    }
    result.sort((a, b) {
      final at = DateTime.tryParse(a.startsAt);
      final bt = DateTime.tryParse(b.startsAt);
      if (at == null || bt == null) return 0;
      return at.compareTo(bt);
    });
    return result;
  }

  List<ClientEvent> searchEvents(String query) {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return [];
    return events.where((e) {
      final cal = calendarForEvent(e);
      if (cal != null && !isCalendarVisible(cal.id)) return false;
      return e.title.toLowerCase().contains(q) ||
          (e.location ?? '').toLowerCase().contains(q) ||
          (e.description ?? '').toLowerCase().contains(q) ||
          (cal?.name ?? '').toLowerCase().contains(q);
    }).toList()..sort((a, b) {
      final at = DateTime.tryParse(a.startsAt);
      final bt = DateTime.tryParse(b.startsAt);
      if (at == null || bt == null) return 0;
      return at.compareTo(bt);
    });
  }
}
