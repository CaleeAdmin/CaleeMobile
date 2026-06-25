import 'dart:io';

import '../../data/api/calee_hub_client.dart';
import '../../data/auth/calee_preferences.dart';
import '../../data/models/calendar_service_error.dart';
import '../../data/models/client_calendar.dart';
import '../../data/models/client_event_draft.dart';

// ─── Public model ─────────────────────────────────────────────────────────────

class CalendarOverview {
  const CalendarOverview({
    required this.calendars,
    required this.events,
    required this.preferences,
    required this.gridStart,
    required this.gridEnd,
    this.serviceErrors = const [],
  });

  final List<ClientCalendar> calendars;
  final List<ClientEvent> events;
  final StoredPreferences preferences;
  final DateTime gridStart;
  final DateTime gridEnd;
  final List<CalendarServiceError> serviceErrors;
}

// ─── Repository ───────────────────────────────────────────────────────────────

class CalendarRepository {
  CalendarRepository({
    required this.hubClient,
    required this.accessToken,
    CaleePreferences? preferences,
  }) : _caleePrefs = preferences ?? CaleePreferences();

  final CaleeHubClient hubClient;
  final String accessToken;
  final CaleePreferences _caleePrefs;

  // ── Grid helpers ─────────────────────────────────────────────────────────

  static DateTime computeGridStart(
    DateTime firstOfMonth,
    FirstDayOfWeek firstDay,
  ) {
    // Sunday-first: offset = weekday % 7  (Mon=1→1, …, Sun=7→0)
    // Monday-first: offset = (weekday+6) % 7  (Mon=1→0, …, Sun=7→6)
    final offset = firstDay == FirstDayOfWeek.monday
        ? (firstOfMonth.weekday + 6) % 7
        : firstOfMonth.weekday % 7;
    return firstOfMonth.subtract(Duration(days: offset));
  }

  static String formatDate(DateTime value) {
    final local = value.toLocal();
    final year = local.year.toString().padLeft(4, '0');
    final month = local.month.toString().padLeft(2, '0');
    final day = local.day.toString().padLeft(2, '0');
    return '$year-$month-$day';
  }

  // ── Load ──────────────────────────────────────────────────────────────────

  // TODO(calendar-notifications): Implement reliable calendar event
  // notifications after hub-core has a background calendar cache/sync worker.
  // Mobile-only local scheduling is not reliable enough because reminders can
  // become stale when events are changed elsewhere. Notification scheduling
  // should use server-side cached event occurrences and push delivery.
  Future<CalendarOverview> loadMonth({
    required DateTime selectedMonth,
    required FirstDayOfWeek firstDayOfWeek,
  }) async {
    StoredPreferences freshPrefs;
    try {
      freshPrefs = await _caleePrefs.load();
    } catch (_) {
      freshPrefs = const StoredPreferences();
    }

    final gridStart = computeGridStart(
      selectedMonth,
      freshPrefs.firstDayOfWeek,
    );
    final gridEnd = gridStart.add(const Duration(days: 41)); // 6 weeks − 1 day

    try {
      final results = await Future.wait([
        hubClient.calendars(accessToken: accessToken),
        hubClient.events(
          accessToken: accessToken,
          from: formatDate(gridStart),
          to: formatDate(gridEnd),
        ),
      ]);

      final calList = results[0] as ClientCalendarList;
      final calendars = calList.calendars
          .where((c) => c.isCalendarKind)
          .toList();
      final events = (results[1] as ClientEventList).events;

      return CalendarOverview(
        calendars: calendars,
        events: events,
        preferences: freshPrefs,
        gridStart: gridStart,
        gridEnd: gridEnd,
        serviceErrors: calList.serviceErrors,
      );
    } on CaleeHubException catch (e) {
      if (isCalendarServiceConnectionCode(e.code)) {
        return CalendarOverview(
          calendars: const [],
          events: const [],
          preferences: freshPrefs,
          gridStart: gridStart,
          gridEnd: gridEnd,
          serviceErrors: [CalendarServiceError.fromException(e)],
        );
      }
      rethrow;
    }
  }

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
    await hubClient.createEvent(
      accessToken: accessToken,
      serviceId: calendar.serviceId,
      calendarId: calendar.id,
      title: title,
      startsAt: allDay ? formatDate(startsAt) : startsAt.toIso8601String(),
      endsAt: allDay ? formatDate(endsAt) : endsAt.toIso8601String(),
      allDay: allDay,
      location: location,
      description: description,
      recurrence: recurrence,
    );
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
    final editOccurrence = event.recurring && editScope == 'occurrence';
    final editSeriesMetadataOnly = event.recurring && editScope == 'series';

    await hubClient.updateEvent(
      accessToken: accessToken,
      eventId: editOccurrence ? event.id : event.writableEventId,
      title: title,
      startsAt: editSeriesMetadataOnly || startsAt == null
          ? null
          : allDay == true
          ? formatDate(startsAt)
          : startsAt.toIso8601String(),
      endsAt: editSeriesMetadataOnly || endsAt == null
          ? null
          : allDay == true
          ? formatDate(endsAt)
          : endsAt.toIso8601String(),
      allDay: editSeriesMetadataOnly ? null : allDay,
      location: location,
      description: description,
      recurrence: editOccurrence || editSeriesMetadataOnly ? null : recurrence,
      includeRecurrence: !editOccurrence && !editSeriesMetadataOnly,
      scope: event.recurring ? editScope : null,
    );
  }

  Future<EventDraftsFromImageResponse> eventDraftsFromImage({
    required File imageFile,
    String? timezone,
    String? referenceDate,
    String? sourceHint,
  }) {
    return hubClient.eventDraftsFromImage(
      accessToken: accessToken,
      imageFile: imageFile,
      timezone: timezone,
      referenceDate: referenceDate,
      sourceHint: sourceHint,
    );
  }

  Future<void> deleteEvent({
    required ClientEvent event,
    String? deleteScope,
  }) async {
    final deleteOccurrence = event.recurring && deleteScope == 'occurrence';
    await hubClient.deleteEvent(
      accessToken: accessToken,
      eventId: deleteOccurrence ? event.id : event.writableEventId,
      scope: event.recurring ? deleteScope : null,
    );
  }
}
