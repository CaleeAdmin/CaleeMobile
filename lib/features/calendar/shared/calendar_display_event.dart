import 'package:flutter/material.dart';

import '../../../ui/calee_design.dart';
import '../../local_subscriber/local_calendar_event.dart';
import '../../local_subscriber/local_calendar_subscription.dart';

class CalendarDisplayEvent {
  const CalendarDisplayEvent({
    required this.id,
    required this.title,
    required this.start,
    this.end,
    required this.allDay,
    required this.calendarId,
    required this.calendarName,
    required this.color,
    this.location,
    this.description,
    this.readOnly = true,
  });

  final String id;
  final String title;
  final DateTime start;
  final DateTime? end;
  final bool allDay;
  final String calendarId;
  final String calendarName;
  final Color color;
  final String? location;
  final String? description;
  final bool readOnly;

  static CalendarDisplayEvent fromLocalCalendarEvent(
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
}
