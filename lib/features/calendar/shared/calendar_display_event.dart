import 'package:flutter/material.dart';

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
}
