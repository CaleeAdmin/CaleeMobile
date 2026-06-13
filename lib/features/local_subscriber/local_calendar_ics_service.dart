import 'dart:io';

import 'local_calendar_event.dart';
import 'local_calendar_subscription.dart';

// Recurring events are not fully supported in local subscriber mode yet.

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
        throw LocalCalendarIcsException(
          'Unable to refresh this calendar. Please try again.',
        );
      }

      final body = await response.transform(const SystemEncoding()).join();
      return _parse(body, subscription);
    } on LocalCalendarIcsException {
      rethrow;
    } catch (_) {
      throw LocalCalendarIcsException(
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
        // Skip recurring events we can't fully expand.
        if (!hasRrule && uid != null && dtStart != null) {
          if (_inWindow(dtStart, dtEnd, windowStart, windowEnd)) {
            events.add(
              LocalCalendarEvent(
                id: uid,
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

      if (line.startsWith('RRULE:') || line.startsWith('RRULE;')) {
        hasRrule = true;
        continue;
      }

      if (line.startsWith('UID:')) {
        uid = line.substring(4).trim();
        continue;
      }

      if (line.startsWith('SUMMARY:')) {
        summary = _unescapeText(line.substring(8));
        continue;
      }

      if (line.startsWith('DTSTART')) {
        final (dt, allDay) = _parseDtLine(line);
        dtStart = dt;
        isAllDay = allDay;
        continue;
      }

      if (line.startsWith('DTEND')) {
        final (dt, _) = _parseDtLine(line);
        dtEnd = dt;
        continue;
      }
    }

    events.sort((a, b) => a.start.compareTo(b.start));
    return events;
  }

  // ── Helpers ───────────────────────────────────────────────────────────────

  List<String> _unfoldLines(String body) {
    // RFC 5545: lines folded with CRLF (or LF) + whitespace
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
    //   DTSTART;TZID=Australia/Sydney:...  → local (treat as floating)
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
