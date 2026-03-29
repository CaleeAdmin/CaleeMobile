import 'dart:convert';

import 'package:caleesync/common/app_constant.dart';
import 'package:caleesync/common/utils/mmkv_utils.dart';
import 'package:caleesync/entity/calendar_share_alias.dart';
import 'package:http/http.dart' as http;

class CalendarShareAliasService {
  final http.Client _client;

  CalendarShareAliasService({http.Client? client}) : _client = client ?? http.Client();

  String _normalizedServerBase() {
    final raw = MMKVUtils.instance.getString(AppConstant.serverKey) ?? AppConstant.caleeServer;
    var normalized = raw.trim();
    if (!normalized.startsWith('http://') && !normalized.startsWith('https://')) {
      normalized = 'https://$normalized';
    }
    return normalized.endsWith('/') ? normalized.substring(0, normalized.length - 1) : normalized;
  }

  Map<String, String> _headers() {
    final username = MMKVUtils.instance.getString(AppConstant.loginNameKey) ?? '';
    final appPassword = MMKVUtils.instance.getString(AppConstant.appPasswordKey) ?? '';
    final token = base64Encode(utf8.encode('$username:$appPassword'));

    return {
      'Authorization': 'Basic $token',
      'Accept': 'application/json',
      'Content-Type': 'application/json',
      'OCS-APIRequest': 'true',
    };
  }

  Future<CalendarShareAliasDto> fetchCurrentAlias() async {
    final uri = Uri.parse('${_normalizedServerBase()}/v1/me/calendar-share-alias');
    final response = await _client.get(uri, headers: _headers());
    if (response.statusCode != 200) {
      throw Exception('Failed to load calendar share alias: ${response.statusCode} ${response.body}');
    }
    final body = jsonDecode(response.body);
    if (body is! Map<String, dynamic>) {
      throw Exception('Unexpected alias response format');
    }
    return CalendarShareAliasDto.fromJson(body);
  }

  Future<RotateCalendarShareAliasDto> rotateAlias() async {
    final uri = Uri.parse('${_normalizedServerBase()}/v1/me/calendar-share-alias/rotate');
    final response = await _client.post(uri, headers: _headers());
    if (response.statusCode != 200) {
      throw Exception('Failed to rotate calendar share alias: ${response.statusCode} ${response.body}');
    }
    final body = jsonDecode(response.body);
    if (body is! Map<String, dynamic>) {
      throw Exception('Unexpected rotate alias response format');
    }
    return RotateCalendarShareAliasDto.fromJson(body);
  }
}
