import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'calendar_follow_intent.dart';

class CalendarFollowIntentResolverException implements Exception {
  const CalendarFollowIntentResolverException(this.message);
  final String message;
  @override
  String toString() => message;
}

class CalendarFollowIntentResolver {
  static const _kBaseUri = 'https://calembed.calee.com.au';
  static const _kTimeout = Duration(seconds: 15);

  CalendarFollowIntentResolver({HttpClient? httpClient})
    : _httpClient =
          httpClient ??
          (HttpClient()..connectionTimeout = const Duration(seconds: 15));

  final HttpClient _httpClient;

  Future<ResolvedCalendarFollowIntent> resolve(
    CalendarFollowIntent intent,
  ) async {
    final uri = Uri.parse(
      _kBaseUri,
    ).resolve('/calendar-intent?t=${Uri.encodeQueryComponent(intent.token)}');

    try {
      final request = await _httpClient.getUrl(uri);
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      final response = await request.close().timeout(_kTimeout);
      final body = await response.transform(utf8.decoder).join();

      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw const CalendarFollowIntentResolverException(
          'This calendar link is invalid or has expired.',
        );
      }

      final decoded = jsonDecode(body);
      if (decoded is! Map<String, dynamic>) {
        throw const CalendarFollowIntentResolverException(
          'This calendar link is invalid or has expired.',
        );
      }

      final data = decoded['data'];
      if (data is! Map<String, dynamic>) {
        throw const CalendarFollowIntentResolverException(
          'This calendar link is invalid or has expired.',
        );
      }

      if (data['kind'] != 'calendar_subscription') {
        throw const CalendarFollowIntentResolverException(
          'This calendar link is invalid or has expired.',
        );
      }

      final url = (data['url'] as String? ?? '').trim();
      if (url.isEmpty) {
        throw const CalendarFollowIntentResolverException(
          'This calendar link is invalid or has expired.',
        );
      }

      final title = (data['title'] as String? ?? '').trim();
      final source = (data['source'] as String? ?? '').trim();

      DateTime? expiresAt;
      final expiresAtRaw = data['expiresAt'] as String?;
      if (expiresAtRaw != null) {
        expiresAt = DateTime.tryParse(expiresAtRaw);
      }

      return ResolvedCalendarFollowIntent(
        title: title.isEmpty ? 'Calendar' : title,
        url: url,
        source: source.isEmpty ? 'calembed' : source,
        expiresAt: expiresAt,
      );
    } on CalendarFollowIntentResolverException {
      rethrow;
    } on TimeoutException {
      throw const CalendarFollowIntentResolverException(
        'Unable to open this calendar link. Please try again.',
      );
    } on SocketException {
      throw const CalendarFollowIntentResolverException(
        'Unable to open this calendar link. Please try again.',
      );
    } on HandshakeException {
      throw const CalendarFollowIntentResolverException(
        'Unable to open this calendar link. Please try again.',
      );
    } catch (_) {
      throw const CalendarFollowIntentResolverException(
        'This calendar link is invalid or has expired.',
      );
    }
  }

  void dispose() => _httpClient.close();
}
