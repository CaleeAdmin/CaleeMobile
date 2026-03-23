import 'package:intl/intl.dart';

class IcsSerializer {
  static String toIcs({
    required String uid,
    required String summary,
    String? description,
    String? location,
    String? url,
    String? recurrenceId,
    String? rrule,
    String? created,
    String? lastModified,
    Map<String, dynamic>? dtstartMeta,
    Map<String, dynamic>? dtendMeta,
    DateTime? start,
    DateTime? end,
  }) {
    final DateTime now = DateTime.now().toUtc();
    final DateTime dtStart = start ?? now;
    final DateTime dtEnd = end ?? dtStart.add(const Duration(hours: 1));

    final StringBuffer sb = StringBuffer();
    sb.write('BEGIN:VCALENDAR\r\n');
    sb.write('VERSION:2.0\r\n');
    sb.write('PRODID:-//CaleeSync//NONSGML v1.0//EN\r\n');
    sb.write('BEGIN:VEVENT\r\n');
    sb.write('UID:${_escapeText(uid)}\r\n');
    sb.write('DTSTAMP:${_formatUtc(now)}\r\n');
    if (created != null && created.trim().isNotEmpty) {
      sb.write('CREATED:${created.trim()}\r\n');
    }
    if (lastModified != null && lastModified.trim().isNotEmpty) {
      sb.write('LAST-MODIFIED:${lastModified.trim()}\r\n');
    }
    sb.write('${_formatDateProperty('DTSTART', dtStart, dtstartMeta)}\r\n');
    sb.write('${_formatDateProperty('DTEND', dtEnd, dtendMeta)}\r\n');
    if (recurrenceId != null && recurrenceId.trim().isNotEmpty) {
      sb.write('RECURRENCE-ID:${recurrenceId.trim()}\r\n');
    }
    if (rrule != null && rrule.trim().isNotEmpty) {
      sb.write('RRULE:${rrule.trim()}\r\n');
    }
    sb.write('SUMMARY:${_escapeText(summary)}\r\n');
    if (description != null && description.isNotEmpty) {
      sb.write('DESCRIPTION:${_escapeText(description)}\r\n');
    }
    if (location != null && location.isNotEmpty) {
      sb.write('LOCATION:${_escapeText(location)}\r\n');
    }
    if (url != null && url.isNotEmpty) {
      sb.write('URL:${url.trim()}\r\n');
    }
    sb.write('SEQUENCE:0\r\n');
    sb.write('TRANSP:OPAQUE\r\n');
    sb.write('END:VEVENT\r\n');
    sb.write('END:VCALENDAR\r\n');
    return sb.toString();
  }

  static String _formatUtc(DateTime dt) =>
      DateFormat("yyyyMMdd'T'HHmmss'Z'").format(dt.toUtc());

  static String _formatDateProperty(
    String name,
    DateTime dt,
    Map<String, dynamic>? meta,
  ) {
    final Map<String, dynamic> params =
        meta == null ? <String, dynamic>{} : Map<String, dynamic>.from(meta['params'] as Map? ?? const {});
    final String? rawTzid = meta == null ? null : meta['tzid']?.toString();
    final bool isUtc = meta != null && meta['isUtc'] == true;
    final bool isDateOnly = meta != null && meta['isDateOnly'] == true;

    if (isDateOnly) {
      params['VALUE'] = 'DATE';
      params.remove('TZID');
      return '$name${_serializeParams(params)}:${DateFormat('yyyyMMdd').format(dt)}';
    }
    if (rawTzid != null && rawTzid.trim().isNotEmpty) {
      params['TZID'] = rawTzid.trim();
      return '$name${_serializeParams(params)}:${DateFormat("yyyyMMdd'T'HHmmss").format(dt)}';
    }
    if (isUtc) {
      params.remove('TZID');
      return '$name${_serializeParams(params)}:${_formatUtc(dt)}';
    }
    params.remove('TZID');
    return '$name${_serializeParams(params)}:${DateFormat("yyyyMMdd'T'HHmmss").format(dt)}';
  }

  static String _serializeParams(Map<String, dynamic> params) {
    if (params.isEmpty) return '';
    return params.entries
        .where((entry) => entry.value != null && entry.value.toString().trim().isNotEmpty)
        .map((entry) => ';${entry.key.toString().toUpperCase()}=${entry.value.toString()}')
        .join();
  }

  static String _escapeText(String value) {
    return value
        .replaceAll('\\', r'\\')
        .replaceAll('\n', r'\n')
        .replaceAll(',', r'\,')
        .replaceAll(';', r'\;');
  }
}
