import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../data/api/calee_hub_client.dart';
import '../../data/models/client_service_calendar_address.dart';

class ServiceCalendarAddressApi {
  ServiceCalendarAddressApi({required this.hubClient});

  final CaleeHubClient hubClient;

  Future<ClientServiceCalendarAddress> load({
    required String accessToken,
    required String serviceId,
  }) async {
    final json = await _requestJson(
      path: _path(serviceId),
      accessToken: accessToken,
      method: 'GET',
    );
    return ClientServiceCalendarAddress.fromJson(_data(json));
  }

  Future<ClientServiceCalendarAddress> rotate({
    required String accessToken,
    required String serviceId,
  }) async {
    final json = await _requestJson(
      path: '${_path(serviceId)}/rotate',
      accessToken: accessToken,
      method: 'POST',
    );
    return ClientServiceCalendarAddress.fromJson(_data(json));
  }

  String _path(String serviceId) {
    final encodedServiceId = Uri.encodeComponent(serviceId);
    final suffix = ['calendar', 'sharing', 'address'].join('-');
    return '/client/v1/services/$encodedServiceId/$suffix';
  }

  Future<Map<String, dynamic>> _requestJson({
    required String path,
    required String accessToken,
    required String method,
  }) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 25)
      ..idleTimeout = const Duration(seconds: 30);
    try {
      final request = await client
          .openUrl(method, hubClient.baseUri.resolve(path))
          .timeout(const Duration(seconds: 25));
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      request.headers.set(
        HttpHeaders.authorizationHeader,
        'Bearer $accessToken',
      );
      if (method == 'POST') {
        request.headers.contentType = ContentType.json;
        request.write(jsonEncode(<String, dynamic>{}));
      }

      final response = await request.close().timeout(
        const Duration(seconds: 25),
      );
      final body = await response.transform(utf8.decoder).join();
      final decoded = body.isEmpty ? null : jsonDecode(body);

      if (response.statusCode < 200 || response.statusCode >= 300) {
        final message = decoded is Map<String, dynamic>
            ? decoded['error'] is Map<String, dynamic>
                  ? (decoded['error'] as Map<String, dynamic>)['message']
                  : decoded['message']
            : null;
        throw CaleeHubException(
          statusCode: response.statusCode,
          message: message is String && message.trim().isNotEmpty
              ? message
              : 'Hub request failed',
        );
      }

      if (decoded is! Map<String, dynamic>) {
        throw const CaleeHubException(
          statusCode: 0,
          message: 'Invalid Hub response',
        );
      }

      return decoded;
    } on CaleeHubException {
      rethrow;
    } on TimeoutException {
      throw const CaleeHubException(
        statusCode: 0,
        message: 'Check your connection and try again.',
      );
    } on SocketException {
      throw const CaleeHubException(
        statusCode: 0,
        message: 'Check your connection and try again.',
      );
    } finally {
      client.close(force: true);
    }
  }

  Map<String, dynamic> _data(Map<String, dynamic> json) {
    final data = json['data'];
    if (data is! Map<String, dynamic>) {
      throw const CaleeHubException(
        statusCode: 0,
        message: 'Missing Hub response data',
      );
    }
    return data;
  }
}
