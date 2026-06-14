import 'package:flutter/material.dart';

import '../../../data/models/client_calendar.dart';
import '../../../ui/calee_design.dart';
import '../widgets/calendar_widget_helpers.dart';
import '../../local_subscriber/local_calendar_event.dart';
import '../../local_subscriber/local_calendar_subscription.dart';
import 'calendar_display_event.dart';

CalendarDisplayEvent calendarDisplayEventFromLocalEvent(
  LocalCalendarEvent event, {
  required LocalCalendarSubscription subscription,
  Color color = CaleeColors.dotBlue,
}) {
  return CalendarDisplayEvent(
    id: event.id,
    title: event.title,
    start: event.start,
    end: event.end,
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
