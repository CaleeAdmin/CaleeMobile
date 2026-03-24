import 'package:flutter/cupertino.dart';

import 'IcsTimezoneResolver.dart';

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
    IcsTimezoneResolver.ensureInitialized();

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

    final _ParsedDateResult? parsedStart = _parseIcsDate(startProperty);
    final _ParsedDateResult? parsedEnd = _parseIcsDate(endProperty);
    if (parsedStart?.millis == null) {
      debugPrint('[ICS] Parse failed: VEVENT DTSTART missing/malformed for uid=$finalUid value=${startProperty?.rawValue}');
      return {};
    }

    final int startMillis = parsedStart!.millis!;
    final int? parsedEndMillis = parsedEnd?.millis;
    final int? normalizedDateOnlyEnd = _normalizeDateOnlyEndMillis(
      parsedStart: parsedStart,
      parsedEnd: parsedEnd,
    );

    final String? recurrenceId = recurrenceIdProperty?.rawValue.trim().isNotEmpty == true
        ? recurrenceIdProperty!.rawValue.trim()
        : null;
    final int resolvedEndMillis = normalizedDateOnlyEnd ?? parsedEndMillis ?? (startMillis + 3600000);

    debugPrint(
      '[ICS] Parsed VEVENT uid=$finalUid recurrenceId=${recurrenceId ?? ''} '
      'start=$startMillis end=$resolvedEndMillis source=VEVENT',
    );

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
      'dtstart_meta': parsedStart.meta,
      'dtend_meta': parsedEnd?.meta,
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
    final bool isUtc = property.rawValue.trim().endsWith('Z');
    final bool isDateOnly = (property.params['VALUE'] ?? '').toUpperCase() == 'DATE';
    final String? tzid = property.params['TZID'];
    return {
      'raw': property.rawValue,
      'rawValue': property.rawValue,
      'params': property.params,
      'source': source,
      'isUtc': isUtc,
      'isDateOnly': isDateOnly,
      'tzid': tzid,
      'isDateEndExclusive': false,
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

  static _ParsedDateResult? _parseIcsDate(IcsPropertyValue? property) {
    try {
      if (property == null || property.rawValue.isEmpty) return null;

      final bool isDateOnly = (property.params['VALUE'] ?? '').toUpperCase() == 'DATE';
      final String rawValue = property.rawValue.trim();
      final String? tzid = property.params['TZID']?.trim().isNotEmpty == true
          ? property.params['TZID']!.trim()
          : null;

      if (isDateOnly) {
        return _parseFloatingOrDateOnly(property, isDateOnly: true);
      }

      if (rawValue.endsWith('Z')) {
        final DateTime parsedUtc = IcsTimezoneResolver.parseUtcDateTime(rawValue);
        return _ParsedDateResult(
          millis: parsedUtc.millisecondsSinceEpoch,
          meta: {
            'raw': property.rawValue,
            'rawValue': property.rawValue,
            'isUtc': true,
            'isDateOnly': false,
            'tzid': null,
            'params': property.params,
            'source': 'VEVENT',
            'isDateEndExclusive': false,
          },
        );
      }

      if (tzid != null) {
        return _parseIcsDateWithTimezone(property, rawValue: rawValue, tzid: tzid);
      }

      return _parseFloatingOrDateOnly(property, isDateOnly: false);
    } catch (_) {
      return null;
    }
  }

  static _ParsedDateResult _parseIcsDateWithTimezone(
    IcsPropertyValue property, {
    required String rawValue,
    required String tzid,
  }) {
    final DateTime parsed = IcsTimezoneResolver.parseIcsDateInTimezone(rawValue, tzid);
    return _ParsedDateResult(
      millis: parsed.millisecondsSinceEpoch,
      meta: {
        'raw': property.rawValue,
        'rawValue': property.rawValue,
        'isUtc': false,
        'isDateOnly': false,
        'tzid': tzid,
        'params': property.params,
        'source': 'VEVENT',
        'isDateEndExclusive': false,
      },
    );
  }

  static _ParsedDateResult _parseFloatingOrDateOnly(
    IcsPropertyValue property, {
    required bool isDateOnly,
  }) {
    final String rawValue = property.rawValue.trim();

    if (isDateOnly) {
      final String compact = rawValue.replaceAll(RegExp(r'[^0-9]'), '');
      final int year = int.parse(compact.substring(0, 4));
      final int month = int.parse(compact.substring(4, 6));
      final int day = int.parse(compact.substring(6, 8));
      final DateTime parsedDate = DateTime.utc(year, month, day);
      return _ParsedDateResult(
        millis: parsedDate.millisecondsSinceEpoch,
        meta: {
          'raw': property.rawValue,
          'rawValue': property.rawValue,
          'isUtc': false,
          'isDateOnly': true,
          'tzid': null,
          'params': property.params,
          'source': 'VEVENT',
          'isDateEndExclusive': property.name == 'DTEND',
        },
      );
    }

    final DateTime parsedFloating = IcsTimezoneResolver.parseFloatingDateTime(rawValue);
    return _ParsedDateResult(
      millis: parsedFloating.millisecondsSinceEpoch,
      meta: {
        'raw': property.rawValue,
        'rawValue': property.rawValue,
        'isUtc': false,
        'isDateOnly': false,
        'tzid': null,
        'params': property.params,
        'source': 'VEVENT',
        'isDateEndExclusive': false,
      },
    );
  }

  static int? _normalizeDateOnlyEndMillis({
    required _ParsedDateResult parsedStart,
    required _ParsedDateResult? parsedEnd,
  }) {
    if (parsedEnd == null) return null;
    final bool endIsDateOnly = parsedEnd.meta['isDateOnly'] == true;
    if (!endIsDateOnly) return parsedEnd.millis;

    final bool startIsDateOnly = parsedStart.meta['isDateOnly'] == true;
    if (startIsDateOnly) {
      return parsedEnd.millis;
    }

    return parsedEnd.millis;
  }
}

class _ParsedDateResult {
  final int? millis;
  final Map<String, dynamic> meta;

  const _ParsedDateResult({
    required this.millis,
    required this.meta,
  });
}
