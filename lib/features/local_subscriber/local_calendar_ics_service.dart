import 'dart:convert';
import 'dart:io';

import 'package:timezone/timezone.dart' as tz;

import 'local_calendar_event.dart';
import 'local_calendar_subscription.dart';

class LocalCalendarIcsService {
  const LocalCalendarIcsService();

  static const _timeout = Duration(seconds: 20);
  static const _windowPast = Duration(days: 30);
  static const _windowFuture = Duration(days: 365);
  static const _maxResponseBytes = 5 * 1024 * 1024; // 5 MB

  Future<List<LocalCalendarEvent>> fetchEvents(
    LocalCalendarSubscription subscription,
  ) async {
    final url = _normalizeUrl(subscription.url);
    final uri = Uri.parse(url);

    final client = HttpClient();
    try {
      client.connectionTimeout = _timeout;
      final request = await client.getUrl(uri).timeout(_timeout);
      request.headers.set(HttpHeaders.userAgentHeader, 'CaleeMobile/1');
      final response = await request.close().timeout(_timeout);

      if (response.statusCode != 200) {
        throw const LocalCalendarIcsException(
          'Unable to refresh this calendar. Please try again.',
        );
      }

      final body = await readBody(response).timeout(_timeout);
      return parseBody(body, subscription);
    } on LocalCalendarIcsException {
      rethrow;
    } catch (_) {
      throw const LocalCalendarIcsException(
        'Unable to refresh this calendar. Please try again.',
      );
    } finally {
      client.close();
    }
  }

  /// Reads a response stream up to [_maxResponseBytes].
  ///
  /// Throws [LocalCalendarIcsException] if the limit is exceeded.
  Future<String> readBody(Stream<List<int>> stream) async {
    final chunks = <List<int>>[];
    var totalBytes = 0;
    await for (final chunk in stream) {
      totalBytes += chunk.length;
      if (totalBytes > _maxResponseBytes) {
        throw const LocalCalendarIcsException(
          'This calendar is too large to open on this phone.',
        );
      }
      chunks.add(chunk);
    }
    return utf8.decode(chunks.expand((c) => c).toList());
  }

  /// Parses an ICS body and returns events within the fetch window.
  List<LocalCalendarEvent> parseBody(
    String icsBody,
    LocalCalendarSubscription subscription,
  ) {
    final now = DateTime.now();
    final windowStart = now.subtract(_windowPast);
    final windowEnd = now.add(_windowFuture);

    final events = <LocalCalendarEvent>[];
    final lines = _unfoldLines(icsBody);

    String? uid;
    String? summary;
    DateTime? dtStart;
    DateTime? dtEnd;
    bool isAllDay = false;
    bool inVevent = false;
    String? rruleValue;
    final exdates = <DateTime>[];

    for (final line in lines) {
      if (line == 'BEGIN:VEVENT') {
        inVevent = true;
        uid = null;
        summary = null;
        dtStart = null;
        dtEnd = null;
        isAllDay = false;
        rruleValue = null;
        exdates.clear();
        continue;
      }

      if (line == 'END:VEVENT') {
        inVevent = false;
        if (dtStart != null) {
          final baseId = uid ?? _stableEventId(subscription, dtStart, summary);
          final duration = dtEnd?.difference(dtStart);

          if (rruleValue != null) {
            final occurrences = _expandRrule(
              rruleValue: rruleValue,
              dtStart: dtStart,
              isAllDay: isAllDay,
              windowStart: windowStart,
              windowEnd: windowEnd,
              exdates: exdates,
            );
            for (final occ in occurrences) {
              events.add(
                LocalCalendarEvent(
                  id: '$baseId:${occ.millisecondsSinceEpoch}',
                  subscriptionId: subscription.id,
                  subscriptionTitle: subscription.title,
                  title: summary ?? 'Untitled',
                  start: occ,
                  end: duration != null ? occ.add(duration) : null,
                  isAllDay: isAllDay,
                  sourceUrl: subscription.url,
                ),
              );
            }
          } else if (_inWindow(dtStart, dtEnd, windowStart, windowEnd)) {
            events.add(
              LocalCalendarEvent(
                id: baseId,
                subscriptionId: subscription.id,
                subscriptionTitle: subscription.title,
                title: summary ?? 'Untitled',
                start: dtStart,
                end: dtEnd,
                isAllDay: isAllDay,
                sourceUrl: subscription.url,
              ),
            );
          }
        }
        continue;
      }

      if (!inVevent) continue;

      final rruleRaw = _extractPropertyValue(line, 'RRULE');
      if (rruleRaw != null) {
        rruleValue = rruleRaw;
        continue;
      }

      if (_propertyMatches(line, 'EXDATE')) {
        exdates.addAll(_parseExdateValues(line));
        continue;
      }

      final uidVal = _extractPropertyValue(line, 'UID');
      if (uidVal != null) {
        uid = uidVal.trim();
        continue;
      }

      final summaryVal = _extractPropertyValue(line, 'SUMMARY');
      if (summaryVal != null) {
        summary = _unescapeText(summaryVal);
        continue;
      }

      if (_propertyMatches(line, 'DTSTART')) {
        final (dt, allDay) = _parseDtLine(line);
        dtStart = dt;
        isAllDay = allDay;
        continue;
      }

      if (_propertyMatches(line, 'DTEND')) {
        final (dt, _) = _parseDtLine(line);
        dtEnd = dt;
        continue;
      }
    }

    events.sort((a, b) => a.start.compareTo(b.start));
    return events;
  }

  // ── RRULE expansion ───────────────────────────────────────────────────────

  List<DateTime> _expandRrule({
    required String rruleValue,
    required DateTime dtStart,
    required bool isAllDay,
    required DateTime windowStart,
    required DateTime windowEnd,
    required List<DateTime> exdates,
  }) {
    final params = _parseRruleParams(rruleValue);
    final freq = (params['FREQ'] ?? '').toUpperCase();
    if (!{'DAILY', 'WEEKLY', 'MONTHLY', 'YEARLY'}.contains(freq)) return [];

    // Fix 1: clamp returns num; force int explicitly.
    final parsedInterval = int.tryParse(params['INTERVAL'] ?? '') ?? 1;
    final interval = parsedInterval.clamp(1, 365).toInt();

    final countLimit = params['COUNT'] != null
        ? int.tryParse(params['COUNT']!)
        : null;

    DateTime? until;
    if (params['UNTIL'] != null) {
      final (dt, _) = _parseDtLine('UNTIL:${params['UNTIL']!}');
      until = dt;
    }

    // BYDAY only supported for WEEKLY; ordinal values (e.g. 2MO, -1FR) are
    // filtered out by _weekdayOffset returning -1.
    final byDay = freq == 'WEEKLY'
        ? (params['BYDAY'] ?? '')
              .split(',')
              .map((s) => s.trim().toUpperCase())
              .where((s) => s.isNotEmpty)
              .toList()
        : <String>[];

    final results = <DateTime>[];
    var current = dtStart;
    var occurrenceCount = 0;

    // Fast-forward past iterations before the window for DAILY/WEEKLY.
    // Only safe when there is no COUNT limit (COUNT requires accurate tracking
    // from the first occurrence, which precludes skipping ahead).
    if (current.isBefore(windowStart) &&
        byDay.isEmpty &&
        countLimit == null &&
        (freq == 'DAILY' || freq == 'WEEKLY')) {
      final daysPer = freq == 'WEEKLY' ? 7 * interval : interval;
      final gap = windowStart.difference(current).inDays;
      final skip = (gap / daysPer).floor() - 1;
      if (skip > 0) {
        current = current.add(Duration(days: skip * daysPer));
      }
    }

    for (var iter = 0; iter < 3000; iter++) {
      if (until != null && current.isAfter(until)) break;
      if (countLimit != null && occurrenceCount >= countLimit) break;
      if (current.isAfter(windowEnd)) break;

      if (byDay.isNotEmpty) {
        // Expand each BYDAY within this interval week.
        final monday = _isoWeekStart(current);
        for (final dayAbbr in byDay) {
          final offset = _weekdayOffset(dayAbbr);
          if (offset < 0) continue; // ordinal or unknown — ignore safely
          if (countLimit != null && occurrenceCount >= countLimit) break;

          final base = monday.add(Duration(days: offset));
          final occ = _makeDateWithOriginalTime(
            base.year,
            base.month,
            base.day,
            dtStart,
            isAllDay,
          );

          if (occ.isBefore(dtStart)) continue;
          if (until != null && occ.isAfter(until)) continue;

          // Fix 2: COUNT counts generated candidates before EXDATE removes
          // visible instances.
          occurrenceCount++;
          if (!_isExcluded(occ, exdates)) {
            if (occ.isAfter(windowStart) && !occ.isAfter(windowEnd)) {
              results.add(occ);
            }
          }
        }
      } else {
        // Fix 2: count before EXDATE filter.
        occurrenceCount++;
        if (!_isExcluded(current, exdates)) {
          if (current.isAfter(windowStart) && !current.isAfter(windowEnd)) {
            results.add(current);
          }
        }
      }

      current = _advanceRrule(current, freq, interval, dtStart, isAllDay);
    }

    return results;
  }

  DateTime _advanceRrule(
    DateTime current,
    String freq,
    int interval,
    DateTime dtStart,
    bool isAllDay,
  ) {
    switch (freq) {
      case 'DAILY':
        // DateTime.add preserves isUtc.
        return current.add(Duration(days: interval));
      case 'WEEKLY':
        return current.add(Duration(days: 7 * interval));
      case 'MONTHLY':
        return _advanceMonthly(current, interval, dtStart, isAllDay);
      case 'YEARLY':
        return _advanceYearly(current, interval, dtStart, isAllDay);
      default:
        return current.add(const Duration(days: 1));
    }
  }

  // Fix 5: helper that constructs a DateTime matching dtStart's time fields
  // and UTC flag, clamped to a specific year/month/day.
  DateTime _makeDateWithOriginalTime(
    int year,
    int month,
    int day,
    DateTime dtStart,
    bool isAllDay,
  ) {
    if (isAllDay) {
      return dtStart.isUtc
          ? DateTime.utc(year, month, day)
          : DateTime(year, month, day);
    }
    return dtStart.isUtc
        ? DateTime.utc(
            year,
            month,
            day,
            dtStart.hour,
            dtStart.minute,
            dtStart.second,
          )
        : DateTime(
            year,
            month,
            day,
            dtStart.hour,
            dtStart.minute,
            dtStart.second,
          );
  }

  DateTime _advanceMonthly(
    DateTime current,
    int interval,
    DateTime dtStart,
    bool isAllDay,
  ) {
    var month = current.month + interval;
    var year = current.year;
    while (month > 12) {
      month -= 12;
      year++;
    }
    final day = dtStart.day.clamp(1, _daysInMonth(year, month));
    return _makeDateWithOriginalTime(year, month, day, dtStart, isAllDay);
  }

  // Fix 3: advance by interval years, preserve original month/day/time,
  // clamp invalid dates (e.g. Feb 29 → Feb 28 in non-leap years).
  DateTime _advanceYearly(
    DateTime current,
    int interval,
    DateTime dtStart,
    bool isAllDay,
  ) {
    final year = current.year + interval;
    final month = dtStart.month;
    final day = dtStart.day.clamp(1, _daysInMonth(year, month));
    return _makeDateWithOriginalTime(year, month, day, dtStart, isAllDay);
  }

  /// Returns the ISO Monday of the week containing [dt] (time stripped).
  /// Fix 5: preserves UTC flag from [dt].
  DateTime _isoWeekStart(DateTime dt) {
    final monday = dt.subtract(Duration(days: dt.weekday - 1));
    return dt.isUtc
        ? DateTime.utc(monday.year, monday.month, monday.day)
        : DateTime(monday.year, monday.month, monday.day);
  }

  /// Maps a plain BYDAY abbreviation (MO, TU, WE, TH, FR, SA, SU) to a
  /// 0-based offset from Monday.
  ///
  /// Fix 4: ordinal BYDAY values (e.g. 2MO, -1FR) contain digits and are
  /// NOT stripped — they are rejected by returning -1 so callers can skip
  /// them safely.
  int _weekdayOffset(String abbr) {
    const offsets = {
      'MO': 0,
      'TU': 1,
      'WE': 2,
      'TH': 3,
      'FR': 4,
      'SA': 5,
      'SU': 6,
    };
    // Reject ordinal values such as 2MO or -1FR (contain a digit).
    if (abbr.contains(RegExp(r'\d'))) return -1;
    return offsets[abbr] ?? -1;
  }

  bool _isExcluded(DateTime dt, List<DateTime> exdates) {
    for (final ex in exdates) {
      if (ex.year == dt.year &&
          ex.month == dt.month &&
          ex.day == dt.day &&
          ex.hour == dt.hour &&
          ex.minute == dt.minute &&
          ex.second == dt.second) {
        return true;
      }
    }
    return false;
  }

  Map<String, String> _parseRruleParams(String rrule) {
    final result = <String, String>{};
    for (final part in rrule.split(';')) {
      final idx = part.indexOf('=');
      if (idx == -1) continue;
      result[part.substring(0, idx).toUpperCase()] = part.substring(idx + 1);
    }
    return result;
  }

  List<DateTime> _parseExdateValues(String line) {
    final colonIdx = line.indexOf(':');
    if (colonIdx == -1) return [];
    final prefix = line.substring(0, colonIdx);
    final values = line.substring(colonIdx + 1).split(',');
    final result = <DateTime>[];
    for (final v in values) {
      final (dt, _) = _parseDtLine('$prefix:${v.trim()}');
      if (dt != null) result.add(dt);
    }
    return result;
  }

  int _daysInMonth(int year, int month) => DateTime(year, month + 1, 0).day;

  // ── Helpers ───────────────────────────────────────────────────────────────

  /// Extracts the value from an ICS property line, handling parameters.
  String? _extractPropertyValue(String line, String propertyName) {
    final len = propertyName.length;
    if (line.length <= len) return null;
    if (!line
        .substring(0, len)
        .toUpperCase()
        .startsWith(propertyName.toUpperCase())) {
      return null;
    }
    final ch = line[len];
    if (ch == ':') return line.substring(len + 1);
    if (ch == ';') {
      final colonIdx = line.indexOf(':', len);
      if (colonIdx == -1) return null;
      return line.substring(colonIdx + 1);
    }
    return null;
  }

  /// Returns true when [line] starts with [propertyName] followed by `:` or `;`.
  bool _propertyMatches(String line, String propertyName) {
    final len = propertyName.length;
    if (line.length <= len) return false;
    if (!line
        .substring(0, len)
        .toUpperCase()
        .startsWith(propertyName.toUpperCase())) {
      return false;
    }
    final ch = line[len];
    return ch == ':' || ch == ';';
  }

  String _stableEventId(
    LocalCalendarSubscription subscription,
    DateTime start,
    String? title,
  ) {
    return '${subscription.id}:${start.millisecondsSinceEpoch}:${title ?? ''}';
  }

  List<String> _unfoldLines(String body) {
    // RFC 5545: lines folded with CRLF (or LF) followed by a whitespace char.
    final unfolded = body
        .replaceAll('\r\n ', '')
        .replaceAll('\r\n\t', '')
        .replaceAll('\n ', '')
        .replaceAll('\n\t', '');
    return unfolded.split(RegExp(r'\r?\n')).where((l) => l.isNotEmpty).toList();
  }

  (DateTime?, bool) _parseDtLine(String line) {
    // Formats handled (ICS compact, not ISO 8601 with dashes):
    //   DTSTART;VALUE=DATE:20240101        → all-day
    //   DTSTART:20240101T120000Z           → UTC timed
    //   DTSTART;TZID=America/New_York:...  → converted to UTC via timezone data
    //   DTSTART:20240101T120000            → floating timed (treated as local)
    //   UNTIL:20240101                     → date-only (no VALUE=DATE needed)

    final colonIdx = line.indexOf(':');
    if (colonIdx == -1) return (null, false);

    // Extract TZID parameter if present.
    // e.g. "DTSTART;TZID=America/New_York:20240101T120000"
    String? tzid;
    final propPart = line.substring(0, colonIdx);
    final semiIdx = propPart.indexOf(';');
    if (semiIdx != -1) {
      for (final param in propPart.substring(semiIdx + 1).split(';')) {
        if (param.startsWith('TZID=')) {
          tzid = param.substring(5);
          break;
        }
      }
    }

    final value = line.substring(colonIdx + 1).trim();

    try {
      // 8-char value is always a date (covers VALUE=DATE and bare UNTIL dates).
      if (value.length == 8) {
        final year = int.parse(value.substring(0, 4));
        final month = int.parse(value.substring(4, 6));
        final day = int.parse(value.substring(6, 8));
        return (DateTime(year, month, day), true);
      }

      // Compact datetime: 20240101T120000Z or 20240101T120000
      if (value.length >= 15 && value[8] == 'T') {
        final year = int.parse(value.substring(0, 4));
        final month = int.parse(value.substring(4, 6));
        final day = int.parse(value.substring(6, 8));
        final hour = int.parse(value.substring(9, 11));
        final min = int.parse(value.substring(11, 13));
        final sec = int.parse(value.substring(13, 15));
        if (value.endsWith('Z')) {
          return (DateTime.utc(year, month, day, hour, min, sec), false);
        }
        if (tzid != null) {
          try {
            final location = tz.getLocation(tzid);
            return (
              tz.TZDateTime(location, year, month, day, hour, min, sec).toUtc(),
              false,
            );
          } catch (_) {
            // Unknown TZID — fall through to floating local time.
          }
        }
        return (DateTime(year, month, day, hour, min, sec), false);
      }
    } catch (_) {
      return (null, false);
    }

    return (null, false);
  }

  bool _inWindow(
    DateTime start,
    DateTime? end,
    DateTime windowStart,
    DateTime windowEnd,
  ) {
    final eventEnd = end ?? start;
    return eventEnd.isAfter(windowStart) && start.isBefore(windowEnd);
  }

  String _unescapeText(String value) {
    return value
        .replaceAll('\\n', '\n')
        .replaceAll('\\N', '\n')
        .replaceAll('\\,', ',')
        .replaceAll('\\;', ';')
        .replaceAll('\\\\', '\\');
  }

  String _normalizeUrl(String url) {
    if (url.startsWith('webcal://')) {
      return 'https://${url.substring('webcal://'.length)}';
    }
    return url;
  }
}

class LocalCalendarIcsException implements Exception {
  const LocalCalendarIcsException(this.message);
  final String message;
  @override
  String toString() => message;
}
