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

/// Returns events eligible for a local reminder notification.
///
/// Pure function — no platform or I/O dependencies.
List<CalendarNotificationCandidate> buildNotificationCandidates(
  List<ClientEvent> events, {
  required DateTime now,
  Duration reminderOffset = const Duration(minutes: 10),
  Duration horizon = const Duration(days: 7),
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

  return result;
}

/// Derives a stable 31-bit notification ID from an event's identity fields.
int notificationIdForEvent(ClientEvent event) {
  final key = '${event.id}|${event.occurrenceId ?? ''}|${event.startsAt}';
  var hash = 0x811c9dc5;
  for (final codeUnit in key.codeUnits) {
    hash ^= codeUnit;
    hash = (hash * 0x01000193) & 0xFFFFFFFF;
  }
  return hash & 0x7FFFFFFF;
}
