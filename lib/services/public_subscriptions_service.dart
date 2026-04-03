import 'dart:convert';

import 'package:caleesync/common/app_constant.dart';
import 'package:caleesync/common/utils/mmkv_utils.dart';
import 'package:http/http.dart' as http;

import '../entity/public_subscription.dart';

class PublicSubscriptionsService {
  final http.Client _client;

  PublicSubscriptionsService({http.Client? client}) : _client = client ?? http.Client();

  Uri _fetchUri() => Uri.https(AppConstant.caleeApiServer, '/v1/me/published-calendars');

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

  Future<List<PublicSubscriptionCategory>> fetch() async {
    final response = await _client.get(_fetchUri(), headers: _headers());
    if (response.statusCode != 200) {
      throw Exception('Failed to load calendars: ${response.statusCode} ${response.body}');
    }

    final decoded = jsonDecode(response.body);
    if (decoded is! Map<String, dynamic>) {
      throw Exception('Unexpected calendars response format');
    }

    final items = decoded['items'];
    if (items is! List) {
      throw Exception('Unexpected calendars payload: missing items list');
    }

    final calendars = items
        .whereType<Map<String, dynamic>>()
        .map(PublicSubscriptionCalendar.fromJson)
        .toList();

    return [
      PublicSubscriptionCategory(title: 'Calee Calendars', calendars: calendars),
    ];
  }
}
