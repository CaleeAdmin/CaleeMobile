import 'package:flutter/cupertino.dart';

class IcsPropertyValue {
  final String name;
  final String rawValue;
  final Map<String, String> params;

  const IcsPropertyValue({
    required this.name,
    required this.rawValue,
    this.params = const {},
  });

  bool get isEmpty => rawValue.trim().isEmpty;
}

class IcsParser {
  static Map<String, dynamic> parse(String icsString, String fallbackUid) {
    final String content = _unfoldLines(icsString);
    final String? veventBlock = _extractVeventBlock(content);
    if (veventBlock == null || veventBlock.isEmpty) {
      debugPrint('[ICS] No VEVENT block found for fallbackUid=$fallbackUid');
      return {};
    }

    final IcsPropertyValue? uidProperty = _extractFieldFromBlock(veventBlock, 'UID');
    final IcsPropertyValue? summaryProperty = _extractFieldFromBlock(veventBlock, 'SUMMARY');
    final IcsPropertyValue? descriptionProperty = _extractFieldFromBlock(veventBlock, 'DESCRIPTION');
    final IcsPropertyValue? startProperty = _extractFieldFromBlock(veventBlock, 'DTSTART');
    final IcsPropertyValue? endProperty = _extractFieldFromBlock(veventBlock, 'DTEND');
    final IcsPropertyValue? recurrenceIdProperty = _extractFieldFromBlock(veventBlock, 'RECURRENCE-ID');
    final IcsPropertyValue? rruleProperty = _extractFieldFromBlock(veventBlock, 'RRULE');
    final IcsPropertyValue? createdProperty = _extractFieldFromBlock(veventBlock, 'CREATED');
    final IcsPropertyValue? lastModifiedProperty = _extractFieldFromBlock(veventBlock, 'LAST-MODIFIED');
    final IcsPropertyValue? locationProperty = _extractFieldFromBlock(veventBlock, 'LOCATION');
    final IcsPropertyValue? urlProperty = _extractFieldFromBlock(veventBlock, 'URL');
    final IcsPropertyValue? dtstampProperty = _extractFieldFromBlock(veventBlock, 'DTSTAMP');

    final String internalUid = uidProperty?.rawValue.trim() ?? '';
    final String finalUid = internalUid.isNotEmpty ? internalUid : fallbackUid;

    final int? startMillis = _parseIcsDate(startProperty);
    final int? endMillis = _parseIcsDate(endProperty);
    if (startMillis == null) {
      debugPrint('[ICS] Parse failed: VEVENT DTSTART missing/malformed for uid=$finalUid value=${startProperty?.rawValue}');
      return {};
    }

    final String? recurrenceId = recurrenceIdProperty?.rawValue.trim().isNotEmpty == true
        ? recurrenceIdProperty!.rawValue.trim()
        : null;
    final int resolvedEndMillis = endMillis ?? (startMillis + 3600000);

    return {
      'uid': finalUid,
      'summary': _decodeIcsText(
        summaryProperty?.rawValue.trim().isNotEmpty == true
            ? summaryProperty!.rawValue
            : 'Untitled event',
      ),
      'description': _decodeIcsText(descriptionProperty?.rawValue ?? ''),
      'dtstart': startMillis,
      'dtend': resolvedEndMillis,
      'dtstamp': dtstampProperty?.rawValue ?? '',
      'created': createdProperty?.rawValue,
      'last_modified': lastModifiedProperty?.rawValue,
      'location': _decodeIcsText(locationProperty?.rawValue ?? ''),
      'url': urlProperty?.rawValue,
      'rrule': rruleProperty?.rawValue,
      'recurrence_id': recurrenceId,
      'instance_key': _buildInstanceKey(finalUid, recurrenceId),
      'dtstart_meta': _buildDateMeta(startProperty, 'VEVENT'),
      'dtend_meta': _buildDateMeta(endProperty, 'VEVENT'),
      'recurrence_id_meta': _buildDateMeta(recurrenceIdProperty, 'VEVENT'),
      'vevent_block': veventBlock,
      'parse_source': 'VEVENT',
    };
  }

  static String _unfoldLines(String icsString) =>
      icsString.replaceAll(RegExp(r'\r?\n[ \t]'), '');

  static String? _extractVeventBlock(String ics) {
    final RegExpMatch? match = RegExp(
      r'BEGIN:VEVENT[\s\S]*?END:VEVENT',
      caseSensitive: false,
    ).firstMatch(ics);
    return match?.group(0);
  }

  static IcsPropertyValue? _extractFieldFromBlock(String block, String name) {
    final RegExp reg = RegExp(
      '^' + RegExp.escape(name) + r'((?:;[^:]*)?):(.*)$',
      multiLine: true,
      caseSensitive: false,
    );
    final RegExpMatch? match = reg.firstMatch(block);
    if (match == null) return null;

    final String rawParams = match.group(1) ?? '';
    final String rawValue = (match.group(2) ?? '').trim();
    final Map<String, String> params = <String, String>{};
    if (rawParams.isNotEmpty) {
      for (final String piece in rawParams.split(';')) {
        final String normalizedPiece = piece.trim();
        if (normalizedPiece.isEmpty) continue;
        final int idx = normalizedPiece.indexOf('=');
        if (idx <= 0) {
          params[normalizedPiece.toUpperCase()] = '';
          continue;
        }
        params[normalizedPiece.substring(0, idx).trim().toUpperCase()] =
            normalizedPiece.substring(idx + 1).trim();
      }
    }

    return IcsPropertyValue(
      name: name.toUpperCase(),
      rawValue: rawValue,
      params: params,
    );
  }

  static Map<String, dynamic>? _buildDateMeta(IcsPropertyValue? property, String source) {
    if (property == null || property.isEmpty) return null;
    return {
      'rawValue': property.rawValue,
      'params': property.params,
      'source': source,
      'isUtc': property.rawValue.endsWith('Z'),
      'isDateOnly': (property.params['VALUE'] ?? '').toUpperCase() == 'DATE',
      'tzid': property.params['TZID'],
    };
  }

  static String _buildInstanceKey(String uid, String? recurrenceId) {
    final String normalizedRecurrence = recurrenceId?.trim() ?? '';
    return normalizedRecurrence.isEmpty ? uid : '$uid::$normalizedRecurrence';
  }

  static String _decodeIcsText(String input) {
    return input
        .replaceAll(r'\,', ',')
        .replaceAll(r'\;', ';')
        .replaceAll(r'\n', '\n')
        .replaceAll('\\\\', '\\');
  }

  static int? _parseIcsDate(IcsPropertyValue? property) {
    try {
      if (property == null || property.rawValue.isEmpty) return null;
      final String dateStr = property.rawValue.trim();
      final bool isDateOnly = (property.params['VALUE'] ?? '').toUpperCase() == 'DATE';
      final String compact = dateStr.replaceAll(RegExp(r'[^0-9T]'), '');
      if (compact.length < 8) return null;

      final int year = int.parse(compact.substring(0, 4));
      final int month = int.parse(compact.substring(4, 6));
      final int day = int.parse(compact.substring(6, 8));

      if (isDateOnly) {
        return DateTime(year, month, day).millisecondsSinceEpoch;
      }

      if (dateStr.endsWith('Z')) {
        final ({int hour, int minute, int second}) time = _parseFloatingDateTime(compact);
        return DateTime.utc(
          year,
          month,
          day,
          time.hour,
          time.minute,
          time.second,
        ).millisecondsSinceEpoch;
      }

      final ({int hour, int minute, int second}) time = _parseFloatingDateTime(compact);
      final String? tzid = property.params['TZID']?.trim();
      if (tzid != null && tzid.isNotEmpty) {
        final int? fixedOffsetMillis = _resolveFixedOffsetTzMillis(
          tzid,
          year,
          month,
          day,
          time.hour,
          time.minute,
          time.second,
        );
        if (fixedOffsetMillis != null) {
          return fixedOffsetMillis;
        }
      }

      return DateTime(year, month, day, time.hour, time.minute, time.second).millisecondsSinceEpoch;
    } catch (_) {
      return null;
    }
  }

  static ({int hour, int minute, int second}) _parseFloatingDateTime(String compact) {
    if (!compact.contains('T') || compact.length < 15) {
      return (hour: 0, minute: 0, second: 0);
    }
    return (
      hour: int.parse(compact.substring(9, 11)),
      minute: int.parse(compact.substring(11, 13)),
      second: int.parse(compact.substring(13, 15)),
    );
  }

  static int? _resolveFixedOffsetTzMillis(
    String tzid,
    int year,
    int month,
    int day,
    int hour,
    int minute,
    int second,
  ) {
    if (tzid == 'UTC' || tzid == 'Etc/UTC') {
      return DateTime.utc(year, month, day, hour, minute, second).millisecondsSinceEpoch;
    }
    final int? offsetMinutes = _fixedOffsetMinutesForTzid(tzid);
    if (offsetMinutes == null) {
      return null;
    }
    return DateTime.utc(year, month, day, hour, minute - offsetMinutes, second)
        .millisecondsSinceEpoch;
  }

  static int? _fixedOffsetMinutesForTzid(String tzid) {
    switch (tzid) {
      case 'Australia/Perth':
        return 8 * 60;
      case 'Asia/Tokyo':
        return 9 * 60;
      default:
        return null;
    }
  }
}
