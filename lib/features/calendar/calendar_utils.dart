import '../../data/models/client_calendar.dart';

String eventTimeLabel(ClientEvent event, {bool use24h = true}) {
  final start = DateTime.tryParse(event.startsAt)?.toLocal();
  if (start == null) return event.allDay ? 'All day' : '';
  if (event.allDay) return 'All day';
  if (use24h) {
    final h = start.hour.toString().padLeft(2, '0');
    final m = start.minute.toString().padLeft(2, '0');
    return '$h:$m';
  } else {
    final hour12 = start.hour % 12;
    final displayHour = hour12 == 0 ? 12 : hour12;
    final period = start.hour < 12 ? 'AM' : 'PM';
    if (start.minute == 0) {
      return '$displayHour $period';
    } else {
      final m = start.minute.toString().padLeft(2, '0');
      return '$displayHour:$m $period';
    }
  }
}
