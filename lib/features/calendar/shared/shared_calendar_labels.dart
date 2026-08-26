/// Plain date/time wording shared by the calendar's detail surfaces.
///
/// Deliberately tiny and dependency-free: it exists so the signed-out and
/// signed-in details sheets cannot drift into two spellings of the same day
/// (CaleeAdmin/CaleeMobile#566). Formatting only — it makes no decision about
/// which values to show.
library;

const List<String> _kMonthNames = [
  'January',
  'February',
  'March',
  'April',
  'May',
  'June',
  'July',
  'August',
  'September',
  'October',
  'November',
  'December',
];

const List<String> _kFullDayNames = [
  'Sunday',
  'Monday',
  'Tuesday',
  'Wednesday',
  'Thursday',
  'Friday',
  'Saturday',
];

/// e.g. `Friday 21 August 2026`.
String calendarLongDateLabel(DateTime day) =>
    '${_kFullDayNames[day.weekday % 7]} ${day.day} '
    '${_kMonthNames[day.month - 1]} ${day.year}';

/// e.g. `13:00`, or `1:30 PM` / `1 PM` on a 12-hour clock.
String calendarClockLabel(DateTime value, {required bool use24h}) {
  if (use24h) return '${_two(value.hour)}:${_two(value.minute)}';
  final h12 = value.hour % 12 == 0 ? 12 : value.hour % 12;
  final period = value.hour < 12 ? 'AM' : 'PM';
  if (value.minute == 0) return '$h12 $period';
  return '$h12:${_two(value.minute)} $period';
}

String _two(int value) => value.toString().padLeft(2, '0');
