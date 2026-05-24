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

  static String mergeIntoExistingVevent({
    required String originalVeventBlock,
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
    String merged = _normalizeVeventBlock(originalVeventBlock);
    final DateTime now = DateTime.now().toUtc();

    merged = _replaceOrInsertTextProperty(
      veventBlock: merged,
      propertyName: 'UID',
      value: uid,
      isOptional: false,
    );
    merged = _replaceOrInsertRawProperty(
      veventBlock: merged,
      propertyName: 'DTSTAMP',
      value: _formatUtc(now),
      isOptional: false,
    );
    merged = _replaceOrInsertRawProperty(
      veventBlock: merged,
      propertyName: 'LAST-MODIFIED',
      value: lastModified,
      isOptional: true,
    );
    if (created != null && created.trim().isNotEmpty) {
      merged = _replaceOrInsertRawProperty(
        veventBlock: merged,
        propertyName: 'CREATED',
        value: created,
        isOptional: false,
      );
    }
    merged = _replaceOrInsertDateProperty(
      veventBlock: merged,
      propertyName: 'DTSTART',
      value: start,
      meta: dtstartMeta,
      isOptional: false,
    );
    merged = _replaceOrInsertDateProperty(
      veventBlock: merged,
      propertyName: 'DTEND',
      value: end,
      meta: dtendMeta,
      isOptional: false,
    );
    merged = _replaceOrInsertDateProperty(
      veventBlock: merged,
      propertyName: 'RECURRENCE-ID',
      value: recurrenceId == null || recurrenceId.trim().isEmpty ? null : DateTime.tryParse(recurrenceId),
      rawValue: recurrenceId,
      isOptional: true,
    );
    merged = _replaceOrInsertRawProperty(
      veventBlock: merged,
      propertyName: 'RRULE',
      value: rrule,
      isOptional: true,
    );
    merged = _replaceOrInsertTextProperty(
      veventBlock: merged,
      propertyName: 'SUMMARY',
      value: summary,
      isOptional: false,
    );
    merged = _replaceOrInsertTextProperty(
      veventBlock: merged,
      propertyName: 'DESCRIPTION',
      value: description,
      isOptional: true,
    );
    merged = _replaceOrInsertTextProperty(
      veventBlock: merged,
      propertyName: 'LOCATION',
      value: location,
      isOptional: true,
    );
    merged = _replaceOrInsertTextProperty(
      veventBlock: merged,
      propertyName: 'URL',
      value: url,
      isOptional: true,
    );

    return 'BEGIN:VCALENDAR\r\n'
        'VERSION:2.0\r\n'
        'PRODID:-//CaleeSync//NONSGML v1.0//EN\r\n'
        '$merged'
        'END:VCALENDAR\r\n';
  }

  static String _formatUtc(DateTime dt) =>
      DateFormat("yyyyMMdd'T'HHmmss'Z'").format(dt.toUtc());

  static String _replaceOrInsertTextProperty({
    required String veventBlock,
    required String propertyName,
    required String? value,
    required bool isOptional,
  }) {
    final String? trimmed = value?.trim();
    if ((trimmed == null || trimmed.isEmpty) && isOptional) {
      return _removeProperty(veventBlock: veventBlock, propertyName: propertyName);
    }
    if (trimmed == null || trimmed.isEmpty) {
      return veventBlock;
    }
    final String replacement = '$propertyName:${_escapeText(trimmed)}';
    final RegExp pattern = RegExp('^${RegExp.escape(propertyName)}(?:;[^:]*)?:.*\$', multiLine: true);
    if (pattern.hasMatch(veventBlock)) {
      return veventBlock.replaceFirst(pattern, replacement);
    }
    return _insertBeforeEndVevent(veventBlock: veventBlock, line: replacement);
  }

  static String _replaceOrInsertDateProperty({
    required String veventBlock,
    required String propertyName,
    DateTime? value,
    Map<String, dynamic>? meta,
    String? rawValue,
    required bool isOptional,
  }) {
    final String? trimmedRaw = rawValue?.trim();
    if (trimmedRaw != null && trimmedRaw.isNotEmpty) {
      return _replaceOrInsertRawProperty(
        veventBlock: veventBlock,
        propertyName: propertyName,
        value: trimmedRaw,
        isOptional: isOptional,
      );
    }
    if (value == null && isOptional) {
      return _removeProperty(veventBlock: veventBlock, propertyName: propertyName);
    }
    if (value == null) {
      return veventBlock;
    }
    final String replacement = _formatDateProperty(propertyName, value, meta);
    final RegExp pattern = RegExp('^${RegExp.escape(propertyName)}(?:;[^:]*)?:.*\$', multiLine: true);
    if (pattern.hasMatch(veventBlock)) {
      return veventBlock.replaceFirst(pattern, replacement);
    }
    return _insertBeforeEndVevent(veventBlock: veventBlock, line: replacement);
  }

  static String _replaceOrInsertRawProperty({
    required String veventBlock,
    required String propertyName,
    required String? value,
    required bool isOptional,
  }) {
    final String? trimmed = value?.trim();
    if ((trimmed == null || trimmed.isEmpty) && isOptional) {
      return _removeProperty(veventBlock: veventBlock, propertyName: propertyName);
    }
    if (trimmed == null || trimmed.isEmpty) {
      return veventBlock;
    }
    final String replacement = '$propertyName:$trimmed';
    final RegExp pattern = RegExp('^${RegExp.escape(propertyName)}(?:;[^:]*)?:.*\$', multiLine: true);
    if (pattern.hasMatch(veventBlock)) {
      return veventBlock.replaceFirst(pattern, replacement);
    }
    return _insertBeforeEndVevent(veventBlock: veventBlock, line: replacement);
  }

  static String _removeProperty({
    required String veventBlock,
    required String propertyName,
  }) {
    final RegExp withNewline = RegExp(
      '^${RegExp.escape(propertyName)}(?:;[^:]*)?:.*(?:\\r?\\n)?',
      multiLine: true,
    );
    if (withNewline.hasMatch(veventBlock)) {
      return veventBlock.replaceFirst(withNewline, '');
    }
    return veventBlock;
  }

  static String _insertBeforeEndVevent({
    required String veventBlock,
    required String line,
  }) {
    final RegExp endPattern = RegExp(r'END:VEVENT\r\n?$');
    if (endPattern.hasMatch(veventBlock)) {
      return veventBlock.replaceFirst(endPattern, '$line\r\nEND:VEVENT\r\n');
    }
    return '$veventBlock$line\r\nEND:VEVENT\r\n';
  }

  static String _normalizeVeventBlock(String input) {
    final String normalizedLineBreaks = input.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    final int beginIdx = normalizedLineBreaks.indexOf('BEGIN:VEVENT');
    if (beginIdx < 0) {
      return 'BEGIN:VEVENT\r\nEND:VEVENT\r\n';
    }
    final int endIdx = normalizedLineBreaks.indexOf('END:VEVENT', beginIdx);
    if (endIdx < 0) {
      final String partial = normalizedLineBreaks.substring(beginIdx).trimRight();
      final String fixed = partial.endsWith('\n') ? partial : '$partial\n';
      return '${fixed.replaceAll('\n', '\r\n')}END:VEVENT\r\n';
    }
    final int endLineIdx = endIdx + 'END:VEVENT'.length;
    String vevent = normalizedLineBreaks.substring(beginIdx, endLineIdx);
    if (!vevent.endsWith('\n')) {
      vevent = '$vevent\n';
    }
    return vevent.replaceAll('\n', '\r\n');
  }

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
