import 'package:flutter/material.dart';

import '../../../data/models/client_calendar.dart';
import '../../../ui/calee_design.dart';
import '../widgets/calendar_widget_helpers.dart';
import '../../local_subscriber/local_calendar_event.dart';
import '../../local_subscriber/local_calendar_subscription.dart';
import 'calendar_display_event.dart';

/// Adapts a phone-only ("Added on this phone only") subscription event for the
/// shared calendar view.
///
/// LocalCalendarIcsService resolves every timed value to an absolute instant:
/// `DTSTART;TZID=Australia/Perth:20260809T140000` becomes `2026-08-09T06:00:00Z`.
/// Handing that UTC value straight to the view rendered it as 06:00 instead of
/// the intended 14:00, so timed values are converted to the device timezone
/// here — the same treatment the Hub-backed adapter below already applies.
///
/// All-day values are deliberately left alone: they are floating calendar dates
/// with no instant behind them, and converting one can shift its date.
CalendarDisplayEvent calendarDisplayEventFromLocalEvent(
  LocalCalendarEvent event, {
  required LocalCalendarSubscription subscription,
  Color color = CaleeColors.dotBlue,
}) {
  final start = event.isAllDay ? event.start : event.start.toLocal();

  final end = event.end == null
      ? null
      : event.isAllDay
      ? event.end
      : event.end!.toLocal();

  return CalendarDisplayEvent(
    id: event.id,
    title: event.title,
    start: start,
    end: end,
    allDay: event.isAllDay,
    calendarId: subscription.id,
    calendarName: subscription.title,
    color: color,
    readOnly: true,
  );
}

CalendarDisplayEvent calendarDisplayEventFromClientEvent(
  ClientEvent event, {
  required ClientCalendar? calendar,
  Color fallbackColor = CaleeColors.dotBlue,
}) {
  Color color = fallbackColor;
  if (calendar?.color != null) {
    final parsed = parseCalendarHexColor(calendar!.color!);
    if (parsed != null) color = parsed;
  }

  DateTime start;
  DateTime? end;
  try {
    start = DateTime.parse(event.startsAt).toLocal();
  } catch (_) {
    debugPrint(
      '[CalendarDisplayEvent] could not parse startsAt "${event.startsAt}" '
      'for event ${event.id}; defaulting to now',
    );
    start = DateTime.now();
  }
  try {
    end = DateTime.parse(event.endsAt).toLocal();
  } catch (_) {
    end = null;
  }

  return CalendarDisplayEvent(
    id: event.id,
    title: event.title,
    start: start,
    end: end,
    allDay: event.allDay,
    calendarId: event.calendarId,
    calendarName: calendar?.name ?? '',
    color: color,
    location: event.location,
    description: event.description,
    readOnly: calendar?.readOnly ?? false,
  );
}
