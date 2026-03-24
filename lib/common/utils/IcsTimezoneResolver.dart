import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

class IcsTimezoneResolver {
  static bool _initialized = false;

  static Future<void> ensureInitialized() async {
    if (_initialized) return;
    tzdata.initializeTimeZones();
    _initialized = true;
  }

  static DateTime parseIcsDateInTimezone(String rawValue, String tzid) {
    _initializeIfNeeded();
    final _IcsDateParts parts = _parseDateParts(rawValue);
    final tz.Location location = tz.getLocation(tzid);
    final tz.TZDateTime zoned = tz.TZDateTime(
      location,
      parts.year,
      parts.month,
      parts.day,
      parts.hour,
      parts.minute,
      parts.second,
    );
    return zoned.toUtc();
  }

  static DateTime parseFloatingDateTime(String rawValue) {
    final _IcsDateParts parts = _parseDateParts(rawValue);
    return DateTime(
      parts.year,
      parts.month,
      parts.day,
      parts.hour,
      parts.minute,
      parts.second,
    );
  }

  static DateTime parseUtcDateTime(String rawValue) {
    final _IcsDateParts parts = _parseDateParts(rawValue);
    return DateTime.utc(
      parts.year,
      parts.month,
      parts.day,
      parts.hour,
      parts.minute,
      parts.second,
    );
  }

  static void _initializeIfNeeded() {
    if (_initialized) return;
    tzdata.initializeTimeZones();
    _initialized = true;
  }

  static _IcsDateParts _parseDateParts(String rawValue) {
    final String sanitized = rawValue.trim();
    final String normalized = sanitized.endsWith('Z')
        ? sanitized.substring(0, sanitized.length - 1)
        : sanitized;
    final String compact = normalized.replaceAll(RegExp(r'[^0-9T]'), '');
    if (compact.length < 8) {
      throw FormatException('Invalid ICS date: $rawValue');
    }

    final int year = int.parse(compact.substring(0, 4));
    final int month = int.parse(compact.substring(4, 6));
    final int day = int.parse(compact.substring(6, 8));

    int hour = 0;
    int minute = 0;
    int second = 0;
    final int tIndex = compact.indexOf('T');
    if (tIndex >= 0) {
      final String timePart = compact.substring(tIndex + 1);
      if (timePart.length >= 2) {
        hour = int.parse(timePart.substring(0, 2));
      }
      if (timePart.length >= 4) {
        minute = int.parse(timePart.substring(2, 4));
      }
      if (timePart.length >= 6) {
        second = int.parse(timePart.substring(4, 6));
      }
    }

    return _IcsDateParts(
      year: year,
      month: month,
      day: day,
      hour: hour,
      minute: minute,
      second: second,
    );
  }
}

class _IcsDateParts {
  final int year;
  final int month;
  final int day;
  final int hour;
  final int minute;
  final int second;

  const _IcsDateParts({
    required this.year,
    required this.month,
    required this.day,
    required this.hour,
    required this.minute,
    required this.second,
  });
}
