import 'dart:io';

import 'local_calendar_event.dart';
import 'local_calendar_subscription.dart';

// Recurring events (RRULE) are intentionally skipped in local subscriber mode v1.
// Full recurrence expansion is non-trivial and out of scope for this release.
// Events with RRULE are silently ignored — they will not appear in the event list.

class LocalCalendarIcsService {
  const LocalCalendarIcsService();

  static const _timeout = Duration(seconds: 20);
  static const _windowPast = Duration(days: 30);
  static const _windowFuture = Duration(days: 365);

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

      final body = await response.transform(const SystemEncoding()).join();
      return _parse(body, subscription);
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

  List<LocalCalendarEvent> _parse(
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
    bool hasRrule = false;

    for (final line in lines) {
      if (line == 'BEGIN:VEVENT') {
        inVevent = true;
        uid = null;
        summary = null;
        dtStart = null;
        dtEnd = null;
        isAllDay = false;
        hasRrule = false;
        continue;
      }

      if (line == 'END:VEVENT') {
        inVevent = false;
        // Skip recurring events — full RRULE expansion is not supported in v1.
        if (!hasRrule && dtStart != null) {
          final eventId =
              uid ?? _stableEventId(subscription, dtStart, summary);
          if (_inWindow(dtStart, dtEnd, windowStart, windowEnd)) {
            events.add(
              LocalCalendarEvent(
                id: eventId,
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

      // RRULE — mark and skip; recurrence is not supported in v1.
      if (_extractPropertyValue(line, 'RRULE') != null) {
        hasRrule = true;
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

      // DTSTART / DTEND — handled by _parseDtLine which locates the first colon.
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

      // DESCRIPTION and LOCATION are intentionally ignored but must not crash.
    }

    events.sort((a, b) => a.start.compareTo(b.start));
    return events;
  }

  // ── Helpers ───────────────────────────────────────────────────────────────

  /// Extracts the value from an ICS property line, handling parameters.
  ///
  /// Handles both `PROP:value` and `PROP;param=v:value` forms, matching the
  /// property name case-insensitively. Returns null if the line does not match.
  String? _extractPropertyValue(String line, String propertyName) {
    final len = propertyName.length;
    if (line.length <= len) return null;
    if (!line.substring(0, len).toUpperCase().startsWith(
          propertyName.toUpperCase(),
        )) {
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
    if (!line.substring(0, len).toUpperCase().startsWith(
          propertyName.toUpperCase(),
        )) {
      return false;
    }
    final ch = line[len];
    return ch == ':' || ch == ';';
  }

  /// Generates a stable in-memory event ID when UID is absent.
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
    return unfolded
        .split(RegExp(r'\r?\n'))
        .where((l) => l.isNotEmpty)
        .toList();
  }

  (DateTime?, bool) _parseDtLine(String line) {
    // Formats (ICS uses compact 8-digit/15-digit, not ISO 8601 dashes):
    //   DTSTART;VALUE=DATE:20240101        → all-day
    //   DTSTART:20240101T120000Z           → UTC
    //   DTSTART;TZID=Australia/Sydney:...  → local (treated as floating/local)
    //   DTSTART:20240101T120000            → floating

    final colonIdx = line.indexOf(':');
    if (colonIdx == -1) return (null, false);

    final params = line.substring(0, colonIdx).toUpperCase();
    final value = line.substring(colonIdx + 1).trim();

    final isDate = params.contains('VALUE=DATE');

    try {
      if (isDate && value.length == 8) {
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
