import 'package:flutter/material.dart';

import '../../../data/models/client_calendar.dart';
import '../calendar_utils.dart';

// Shared constants used across calendar widgets.

const kCalendarMonthAbbr = [
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];

bool isSameCalendarDay(DateTime a, DateTime b) =>
    a.year == b.year && a.month == b.month && a.day == b.day;

Color? parseCalendarHexColor(String hex) {
  final clean = hex.startsWith('#') ? hex.substring(1) : hex;
  if (clean.length == 6) {
    final value = int.tryParse(clean, radix: 16);
    if (value != null) return Color(0xFF000000 | value);
  }
  if (clean.length == 8) {
    final value = int.tryParse(clean, radix: 16);
    if (value != null) return Color(value);
  }
  return null;
}

String? calendarSubscriptionHost(String? url) {
  if (url == null || url.isEmpty) return null;
  final host = Uri.tryParse(url)?.host;
  return (host == null || host.isEmpty) ? null : host;
}

String calendarEventTimeLabel(ClientEvent event, {bool use24h = true}) =>
    eventTimeLabel(event, use24h: use24h);
