/// Human-visible date and time labels for one event's DETAILS surface.
///
/// Shared by the signed-out `LocalEventDetailsSheet` and the signed-in
/// `EventDetailsSheet` so both describe the same occurrence the same way
/// (CaleeAdmin/CaleeMobile#566).
///
/// The one rule worth stating out loud: an all-day event's transport `endsAt`
/// is EXCLUSIVE, on both the Hub contract and in iCalendar. A Friday-to-Sunday
/// camp arrives carrying the Monday, and showing the user "Monday" would be a
/// plain lie about when the event finishes. Everything here converts to the
/// INCLUSIVE last day the user actually experiences, and nothing here changes
/// the transport values themselves — [CalendarDisplayEvent.end] keeps its
/// exclusive meaning for the grid, the agenda and any future consumer.
///
/// No timezone work happens in this file. Values arrive already resolved by
/// the display adapters (timed values converted to the device zone, all-day
/// values deliberately left as floating calendar dates), and re-deriving a
/// zone here would be a second, disagreeing opinion about the same instant.
library;

import 'shared_calendar_labels.dart';
import 'calendar_display_event.dart';

/// The date, or inclusive date RANGE, one event covers.
///
/// A single day renders as one date. A span renders as `start – end` with the
/// end being the last day the event is actually on.
String eventDetailDateLabel(CalendarDisplayEvent event) {
  final start = _dateOnly(event.start);
  final end = inclusiveEndDate(event);
  if (end == null || !end.isAfter(start)) return calendarLongDateLabel(start);
  return '${calendarLongDateLabel(start)} – ${calendarLongDateLabel(end)}';
}

/// `All day`, one clock time, or a `start–end` range.
String eventDetailTimeLabel(
  CalendarDisplayEvent event, {
  required bool use24h,
}) {
  if (event.allDay) return 'All day';
  final end = event.end;
  if (end == null) return calendarClockLabel(event.start, use24h: use24h);
  return '${calendarClockLabel(event.start, use24h: use24h)}'
      '–${calendarClockLabel(end, use24h: use24h)}';
}

/// The last calendar day [event] is actually on, or null when it has no end.
///
/// All-day: the transport end is exclusive, so the day before it.
/// Timed: the day the end instant falls on — except an end at exactly
/// midnight, which closes the previous day rather than starting a new one.
DateTime? inclusiveEndDate(CalendarDisplayEvent event) {
  final end = event.end;
  if (end == null) return null;
  final endDate = _dateOnly(end);

  if (event.allDay) {
    // Built from components rather than subtracting a Duration: a Duration is
    // an absolute span and would land on 23:00 of the previous day across a
    // DST transition, which is a different calendar date on some devices.
    return DateTime(endDate.year, endDate.month, endDate.day - 1);
  }

  final startDate = _dateOnly(event.start);
  final endsExactlyAtMidnight =
      end.hour == 0 && end.minute == 0 && end.second == 0;
  if (endsExactlyAtMidnight && endDate.isAfter(startDate)) {
    return DateTime(endDate.year, endDate.month, endDate.day - 1);
  }
  return endDate;
}

DateTime _dateOnly(DateTime value) =>
    DateTime(value.year, value.month, value.day);
