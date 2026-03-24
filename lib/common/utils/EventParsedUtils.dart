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
  final bool isExchangeRisk;
  final bool hasAttendees;
  final bool hasOrganizer;
  final bool hasAlarm;
  final bool hasXAppleExchangeMarkers;
  final String uidKind;
  final String? rawVevent;

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
    this.isExchangeRisk = false,
    this.hasAttendees = false,
    this.hasOrganizer = false,
    this.hasAlarm = false,
    this.hasXAppleExchangeMarkers = false,
    this.uidKind = 'other',
    this.rawVevent,
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

        return ParsedEvent(
          uid: uid,
          identityKey: (remote['instance_key'] ?? remote['remote_uid'] ?? uid).toString(),
          summary: remote['summary'] ?? 'Untitled',
          dtstart: dtstart,
          dtend: dtend,
          description: remote['description'],
          href: remote['href'],
          recurrenceId: remote['recurrence_id']?.toString(),
          location: remote['location']?.toString(),
          url: remote['url']?.toString(),
          parseSource: (remote['parse_source'] ?? 'VEVENT').toString(),
          dtstartMeta: remote['dtstart_meta'] as Map<String, dynamic>?,
          dtendMeta: remote['dtend_meta'] as Map<String, dynamic>?,
          isExchangeRisk: remote['is_exchange_risk'] == true || remote['is_exchange_risk'] == 1,
          hasAttendees: remote['has_attendees'] == true || remote['has_attendees'] == 1,
          hasOrganizer: remote['has_organizer'] == true || remote['has_organizer'] == 1,
          hasAlarm: remote['has_alarm'] == true || remote['has_alarm'] == 1,
          hasXAppleExchangeMarkers:
              remote['has_x_apple_exchange_markers'] == true || remote['has_x_apple_exchange_markers'] == 1,
          uidKind: (remote['uid_kind'] ?? 'other').toString(),
          rawVevent: remote['raw_vevent']?.toString(),
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

      return ParsedEvent(
        uid: parsedMap['uid'] ?? remote['uid'] ?? href,
        identityKey: (parsedMap['instance_key'] ?? parsedMap['uid'] ?? remote['uid'] ?? href).toString(),
        summary: parsedMap['summary'] ?? 'Untitled event',
        dtstart: parsedMap['dtstart'],
        dtend: parsedMap['dtend'],
        description: parsedMap['description'],
        href: href,
        recurrenceId: parsedMap['recurrence_id']?.toString(),
        location: parsedMap['location']?.toString(),
        url: parsedMap['url']?.toString(),
        parseSource: (parsedMap['parse_source'] ?? 'VEVENT').toString(),
        dtstartMeta: parsedMap['dtstart_meta'] as Map<String, dynamic>?,
        dtendMeta: parsedMap['dtend_meta'] as Map<String, dynamic>?,
        isExchangeRisk: parsedMap['is_exchange_risk'] == true || parsedMap['is_exchange_risk'] == 1,
        hasAttendees: parsedMap['has_attendees'] == true || parsedMap['has_attendees'] == 1,
        hasOrganizer: parsedMap['has_organizer'] == true || parsedMap['has_organizer'] == 1,
        hasAlarm: parsedMap['has_alarm'] == true || parsedMap['has_alarm'] == 1,
        hasXAppleExchangeMarkers:
            parsedMap['has_x_apple_exchange_markers'] == true || parsedMap['has_x_apple_exchange_markers'] == 1,
        uidKind: (parsedMap['uid_kind'] ?? 'other').toString(),
        rawVevent: parsedMap['raw_vevent']?.toString(),
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
}
