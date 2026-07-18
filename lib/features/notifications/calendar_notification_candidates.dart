import '../../data/models/client_calendar.dart';

class CalendarNotificationCandidate {
  const CalendarNotificationCandidate({
    required this.event,
    required this.reminderTime,
    required this.startLocal,
    required this.notificationId,
  });

  final ClientEvent event;
  final DateTime reminderTime;
  final DateTime startLocal;
  final int notificationId;
}

/// Default number of days to look ahead when selecting reminder candidates.
///
/// Reminders are scheduled from an independent upcoming-event window rather
/// than the calendar month currently on screen, so this horizon is what bounds
/// how far ahead reminders are pre-scheduled on the device.
const Duration kCalendarReminderHorizon = Duration(days: 30);

/// Returns events eligible for a local reminder notification, sorted by
/// ascending reminder time so the earliest reminders are selected first.
///
/// Pure function — no platform or I/O dependencies.
///
/// Skips:
/// * all-day events (all-day reminder behaviour is out of scope),
/// * events with an unparseable [ClientEvent.startsAt],
/// * events whose reminder time has already passed,
/// * events starting beyond [horizon].
///
/// When [maxCandidates] is provided, the list is sorted first and only then
/// truncated, so the earliest-firing reminders are always the ones kept.
List<CalendarNotificationCandidate> buildNotificationCandidates(
  List<ClientEvent> events, {
  required DateTime now,
  Duration reminderOffset = const Duration(minutes: 10),
  Duration horizon = kCalendarReminderHorizon,
  int? maxCandidates,
}) {
  final cutoff = now.add(horizon);
  final result = <CalendarNotificationCandidate>[];

  for (final event in events) {
    if (event.allDay) continue;

    final startLocal = DateTime.tryParse(event.startsAt)?.toLocal();
    if (startLocal == null) continue;

    final reminderTime = startLocal.subtract(reminderOffset);
    if (!reminderTime.isAfter(now)) continue;
    if (startLocal.isAfter(cutoff)) continue;

    result.add(
      CalendarNotificationCandidate(
        event: event,
        reminderTime: reminderTime,
        startLocal: startLocal,
        notificationId: notificationIdForEvent(event),
      ),
    );
  }

  // Earliest reminders first. When more than the maximum are eligible, the
  // maximum is applied only after sorting so the soonest reminders win.
  result.sort((a, b) => a.reminderTime.compareTo(b.reminderTime));
  if (maxCandidates != null && result.length > maxCandidates) {
    return result.sublist(0, maxCandidates);
  }
  return result;
}

/// Derives a stable 31-bit notification ID from an event's identity fields.
///
/// Recurring occurrences differ by [ClientEvent.occurrenceId] and/or
/// [ClientEvent.startsAt], so each occurrence gets a stable, distinct ID.
int notificationIdForEvent(ClientEvent event) {
  final key = '${event.id}|${event.occurrenceId ?? ''}|${event.startsAt}';
  var hash = 0x811c9dc5;
  for (final codeUnit in key.codeUnits) {
    hash ^= codeUnit;
    hash = (hash * 0x01000193) & 0xFFFFFFFF;
  }
  return hash & 0x7FFFFFFF;
}
