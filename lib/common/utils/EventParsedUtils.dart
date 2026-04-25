import 'dart:convert';

import 'package:flutter/cupertino.dart';
import 'package:http/http.dart' as http;

import '../app_constant.dart';
import 'IcsParser.dart';
import 'mmkv_utils.dart';

class ParsedEvent {
  final String uid;
  final String identityKey;
  final String summary;
  final int dtstart;
  final int dtend;
  final String? description;
  final String? href;
  final String? recurrenceId;
  final String? location;
  final String? url;
  final String parseSource;
  final Map<String, dynamic>? dtstartMeta;
  final Map<String, dynamic>? dtendMeta;

  ParsedEvent({
    required this.uid,
    required this.identityKey,
    required this.summary,
    required this.dtstart,
    required this.dtend,
    required this.parseSource,
    this.description,
    this.href,
    this.recurrenceId,
    this.location,
    this.url,
    this.dtstartMeta,
    this.dtendMeta,
  });
}

class Eventparsedutils {
  static int? _toInt(dynamic value) {
    if (value is int) return value;
    if (value == null) return null;
    return int.tryParse(value.toString());
  }

  static Future<ParsedEvent?> resolveEventData({
    required Map<String, dynamic> remote,
    required bool isSubscription,
  }) async {
    final String baseUrl = _activeServerBase();
    final String loginName = MMKVUtils.instance.getString(AppConstant.loginNameKey) ?? '';
    final String password = MMKVUtils.instance.getString(AppConstant.appPasswordKey) ?? '';
    final String authHeader = 'Basic ${base64Encode(utf8.encode('$loginName:$password'))}';
    final http.Client client = http.Client();

    try {
      if (isSubscription) {
        final String uid = ((remote['uid'] ?? remote['remote_uid']) ?? '').toString().trim();
        final int? dtstart = _toInt(remote['dtstart'] ?? remote['start']);
        final int? dtend = _toInt(remote['dtend'] ?? remote['end']);
        if (uid.isEmpty || dtstart == null || dtend == null) {
          return null;
        }
        final Map<String, dynamic>? dtstartMeta = remote['dtstart_meta'] as Map<String, dynamic>?;
        final Map<String, dynamic>? dtendMeta = remote['dtend_meta'] as Map<String, dynamic>?;

        return ParsedEvent(
          uid: uid,
          identityKey: (remote['instance_key'] ?? remote['remote_uid'] ?? uid).toString(),
          summary: remote['summary'] ?? 'Untitled',
          dtstart: dtstart,
          dtend: _normalizeAllDayExclusiveEnd(
            dtstart: dtstart,
            dtend: dtend,
            dtstartMeta: dtstartMeta,
            dtendMeta: dtendMeta,
          ),
          description: remote['description'],
          href: remote['href'],
          recurrenceId: remote['recurrence_id']?.toString(),
          location: remote['location']?.toString(),
          url: remote['url']?.toString(),
          parseSource: (remote['parse_source'] ?? 'VEVENT').toString(),
          dtstartMeta: dtstartMeta,
          dtendMeta: dtendMeta,
        );
      }

      final String href = remote['href'] ?? '';
      if (href.isEmpty) return null;

      final String url = "${baseUrl.replaceAll(RegExp(r'/$'), '')}${href.startsWith('/') ? '' : '/'}$href";
      final response = await client.get(
        Uri.parse(url),
        headers: {
          'Authorization': authHeader,
          'User-Agent': 'CaleeSync/1.0',
          'Accept': 'text/calendar',
        },
      ).timeout(const Duration(seconds: 15));

      if (response.statusCode != 200) {
        debugPrint('[WARN] Failed to fetch event details [$href]: ${response.statusCode}');
        return null;
      }

      final Map<String, dynamic> parsedMap = IcsParser.parse(response.body, remote['uid'] ?? href);
      if (parsedMap.isEmpty) {
        return null;
      }
      final Map<String, dynamic>? dtstartMeta = parsedMap['dtstart_meta'] as Map<String, dynamic>?;
      final Map<String, dynamic>? dtendMeta = parsedMap['dtend_meta'] as Map<String, dynamic>?;
      final int parsedStart = parsedMap['dtstart'];
      final int parsedEnd = parsedMap['dtend'];

      return ParsedEvent(
        uid: parsedMap['uid'] ?? remote['uid'] ?? href,
        identityKey: (parsedMap['instance_key'] ?? parsedMap['uid'] ?? remote['uid'] ?? href).toString(),
        summary: parsedMap['summary'] ?? 'Untitled event',
        dtstart: parsedStart,
        dtend: _normalizeAllDayExclusiveEnd(
          dtstart: parsedStart,
          dtend: parsedEnd,
          dtstartMeta: dtstartMeta,
          dtendMeta: dtendMeta,
        ),
        description: parsedMap['description'],
        href: href,
        recurrenceId: parsedMap['recurrence_id']?.toString(),
        location: parsedMap['location']?.toString(),
        url: parsedMap['url']?.toString(),
        parseSource: (parsedMap['parse_source'] ?? 'VEVENT').toString(),
        dtstartMeta: dtstartMeta,
        dtendMeta: dtendMeta,
      );
    } catch (e) {
      debugPrint('[ERROR] resolveEventData exception: $e');
      return null;
    } finally {
      client.close();
    }
  }

  static String _activeServerBase() {
    final String saved = MMKVUtils.instance.getString(AppConstant.serverKey) ?? AppConstant.caleeServer;
    String normalized = saved.trim();
    if (!normalized.startsWith('http://') && !normalized.startsWith('https://')) {
      normalized = 'https://$normalized';
    }
    return normalized.endsWith('/') ? normalized.substring(0, normalized.length - 1) : normalized;
  }

  static int _normalizeAllDayExclusiveEnd({
    required int dtstart,
    required int dtend,
    required Map<String, dynamic>? dtstartMeta,
    required Map<String, dynamic>? dtendMeta,
  }) {
    final bool isDateOnlyStart = dtstartMeta?['isDateOnly'] == true;
    if (!isDateOnlyStart || dtend <= dtstart) {
      return dtend;
    }

    final DateTime end = DateTime.fromMillisecondsSinceEpoch(dtend);
    final bool endAtMidnight =
        end.hour == 0 && end.minute == 0 && end.second == 0 && end.millisecond == 0 && end.microsecond == 0;
    if (!endAtMidnight) {
      return dtend;
    }

    if (dtendMeta?['isDateOnly'] == false) {
      return dtend;
    }

    return dtend - 1;
  }
}
