import 'dart:convert';
import 'dart:convert' show latin1;
import 'package:http/http.dart' as http;

import '../entity/public_subscription.dart';


class PublicSubscriptionsService {
  final String baseUrl;

  PublicSubscriptionsService({required this.baseUrl});

  Future<List<PublicSubscriptionCategory>> fetch({required String username, required String appPassword}) async {
    final apiUrl = '$baseUrl/api/public-subscriptions.php';
    final apiUri = Uri.parse(apiUrl);
    final credentials = base64Encode(latin1.encode('$username:$appPassword'));

    // 1) Perform PROPFIND to obtain session cookie(s)
    final propfindUri = Uri.parse('$baseUrl/remote.php/dav/');
    final propReq = http.Request('PROPFIND', propfindUri);
    propReq.headers.addAll({
      'Authorization': 'Basic $credentials',
      'Depth': '0',
      'OCS-APIRequest': 'true',
      'User-Agent': 'CaleeSync/1.0',
    });
    final propStreamed = await propReq.send().timeout(const Duration(seconds: 15));
    final propResp = await http.Response.fromStream(propStreamed);

    // collect cookies from Set-Cookie header(s)
    String? cookieHeader;
    final sc = propResp.headers['set-cookie'];
    // Debug: print propfind headers
    // ignore: avoid_print
    print('[PublicSubscriptions] PROPFIND headers: ${propResp.headers}');
    if (sc != null && sc.isNotEmpty) {
      // parse name=value pairs and keep only one value per cookie name (last occurrence)
      final cookieRegex = RegExp(r'([^=\s;,\|]+)=([^;,\s]+)');
      final Map<String, String> cookieMap = {};
      final excludeNames = {'path', 'expires', 'httponly', 'secure', 'samesite', 'domain', 'max-age'};
      for (final m in cookieRegex.allMatches(sc)) {
        final name = m.group(1)!.trim();
        final lname = name.toLowerCase();
        final value = m.group(2)!.trim();
        if (excludeNames.contains(lname)) continue;
        // prefer later occurrences (override)
        cookieMap[name] = value;
      }
      if (cookieMap.isNotEmpty) {
        // Prefer the common Nextcloud session cookies order: oc_sessionPassphrase, ocrpwmt1k7ny
        final preferred = <String>['oc_sessionPassphrase', 'ocrpwmt1k7ny'];
        final parts = <String>[];
        for (final key in preferred) {
          if (cookieMap.containsKey(key)) parts.add('$key=${cookieMap[key]}');
        }
        // append any remaining cookies
        for (final entry in cookieMap.entries) {
          if (!preferred.contains(entry.key)) parts.add('${entry.key}=${entry.value}');
        }
        cookieHeader = parts.join('; ');
      } else {
        // fallback: use first token before semicolon from the header
        final parts = sc.split(',').map((s) => s.split(';').first.trim()).where((s) => s.isNotEmpty).toList();
        if (parts.isNotEmpty) cookieHeader = parts.join('; ');
      }
    }
    // Debug: print cookieHeader
    // ignore: avoid_print
    print('[PublicSubscriptions] cookieHeader=$cookieHeader');

    // 2) Call API using Cookie if available, otherwise fallback to Authorization header
    final headers = <String, String>{
      'Accept': 'application/json',
      'OCS-APIRequest': 'true',
      'User-Agent': 'CaleeSync/1.0',
    };
    if (cookieHeader != null) {
      headers['Cookie'] = cookieHeader;
    } else {
      headers['Authorization'] = 'Basic $credentials';
    }

    // Try API call; if 404 or 401 and we used cookie, try fallback strategies
    // Debug: print request headers
    // ignore: avoid_print
    print('[PublicSubscriptions] API request headers: $headers');
    var resp = await http.get(apiUri, headers: headers).timeout(const Duration(seconds: 15));
    if (resp.statusCode == 404) {
      // try without .php
      final altApiUri = Uri.parse('$baseUrl/api/public-subscriptions');
      // ignore: avoid_print
      print('[PublicSubscriptions] 404 on .php, trying $altApiUri');
      resp = await http.get(altApiUri, headers: headers).timeout(const Duration(seconds: 15));
    }

    if (resp.statusCode == 401 && cookieHeader != null) {
      // fallback: try with Authorization header instead of cookie
      headers.remove('Cookie');
      headers['Authorization'] = 'Basic $credentials';
      // ignore: avoid_print
      print('[PublicSubscriptions] 401 with cookie, retrying with Authorization header');
      resp = await http.get(apiUri, headers: headers).timeout(const Duration(seconds: 15));
    }

    if (resp.statusCode != 200) {
      // debug response
      // ignore: avoid_print
      print('[PublicSubscriptions] API response status=${resp.statusCode}, body=${resp.body}');
      throw Exception('Failed to load subscriptions: ${resp.statusCode} ${resp.body}');
    }

    final decoded = jsonDecode(resp.body);
    final List<PublicSubscriptionCategory> result = [];

    if (decoded is Map<String, dynamic>) {
      if (decoded.containsKey('items') && decoded['items'] is List) {
        final items = (decoded['items'] as List).whereType<Map<String, dynamic>>().map((e) => PublicSubscriptionCalendar.fromJson(e)).toList();
        result.add(PublicSubscriptionCategory(title: 'Public Subscriptions', calendars: items));
      } else if (decoded.containsKey('subscriptions') && decoded['subscriptions'] is List) {
        final items = (decoded['subscriptions'] as List).whereType<Map<String, dynamic>>().map((e) => PublicSubscriptionCalendar.fromJson(e)).toList();
        result.add(PublicSubscriptionCategory(title: 'Subscriptions', calendars: items));
      } else {
        final items = decoded['data'] is List ? (decoded['data'] as List).whereType<Map<String, dynamic>>().map((e) => PublicSubscriptionCalendar.fromJson(e)).toList() : <PublicSubscriptionCalendar>[];
        if (items.isNotEmpty) {
          result.add(PublicSubscriptionCategory(title: 'All', calendars: items));
        } else {
          if (decoded.isNotEmpty) {
            result.add(PublicSubscriptionCategory(title: 'All', calendars: [PublicSubscriptionCalendar.fromJson(decoded)]));
          }
        }
      }
    } else if (decoded is List) {
      final items = decoded.whereType<Map<String, dynamic>>().map((e) => PublicSubscriptionCalendar.fromJson(e)).toList();
      result.add(PublicSubscriptionCategory(title: 'All', calendars: items));
    } else {
      throw Exception('Unexpected API response format');
    }

    return result;
  }
}


