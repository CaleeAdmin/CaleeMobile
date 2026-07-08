import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../data/auth/calee_preferences.dart';
import '../../data/models/calendar_service_error.dart';
import '../../data/models/client_calendar.dart';
import '../notifications/local_calendar_notification_service.dart';
import 'calendar_repository.dart';

class CalendarController extends ChangeNotifier {
  CalendarController({
    required this.repository,
    LocalCalendarNotificationService? notificationService,
  }) : _notificationService =
           notificationService ?? LocalCalendarNotificationService.instance {
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
  final LocalCalendarNotificationService _notificationService;

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

  Future<void> loadMonth() async {
    isLoading = true;
    error = null;
    notifyListeners();

    try {
      final overview = await repository.loadMonth(
        selectedMonth: selectedMonth,
      );
      preferences = overview.preferences;
      gridStart = overview.gridStart;
      calendars = overview.calendars;
      events = overview.events;
      calendarServiceErrors = overview.serviceErrors;
      unawaited(_notificationService.rescheduleUpcomingEvents(events));
      hiddenCalendarIds.removeWhere(
        (id) => !calendars.any((cal) => cal.id == id),
      );
      error = null;
    } catch (e) {
      error = e;
      calendarServiceErrors = [];
    } finally {
      isLoading = false;
      notifyListeners();
    }
  }

  Future<void> refresh() => loadMonth();

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
  }

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
    );
    await loadMonth();
  }

  Future<void> deleteEvent({
    required ClientEvent event,
    String? deleteScope,
  }) async {
    await repository.deleteEvent(event: event, deleteScope: deleteScope);
    await loadMonth();
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
