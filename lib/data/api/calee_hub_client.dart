import 'dart:convert';
import 'dart:io';

import '../models/client_bootstrap.dart';
import '../models/client_calendar.dart';

class CaleeHubClient {
  CaleeHubClient({
    Uri? baseUri,
    HttpClient? httpClient,
  })  : baseUri = baseUri ?? Uri.parse('https://hub.calee.com.au'),
        _httpClient = httpClient ?? HttpClient();

  final Uri baseUri;
  final HttpClient _httpClient;

  Future<ClientLoginResult> login({
    required String email,
    required String password,
  }) async {
    final json = await _postJson(
      '/client/v1/auth/login',
      body: {
        'email': email,
        'password': password,
      },
    );

    return ClientLoginResult.fromJson(_data(json));
  }

  Future<ClientBootstrap> bootstrap({
    required String accessToken,
  }) async {
    final json = await _getJson(
      '/client/v1/bootstrap',
      accessToken: accessToken,
    );

    return ClientBootstrap.fromJson(_data(json));
  }

  Future<ClientCalendarList> calendars({
    required String accessToken,
  }) async {
    final json = await _getJson(
      '/client/v1/calendars',
      accessToken: accessToken,
    );

    return ClientCalendarList.fromJson(_data(json));
  }

  Future<ClientEventList> events({
    required String accessToken,
    required String from,
    required String to,
  }) async {
    final uri = Uri(
      path: '/client/v1/events',
      queryParameters: {
        'from': from,
        'to': to,
      },
    );

    final json = await _getJson(
      uri.toString(),
      accessToken: accessToken,
    );

    return ClientEventList.fromJson(_data(json));
  }

  Future<ClientRefreshResult> refresh({
    required String refreshToken,
  }) async {
    final json = await _postJson(
      '/client/v1/auth/refresh',
      body: {
        'refreshToken': refreshToken,
      },
    );

    return ClientRefreshResult.fromJson(_data(json));
  }

  Future<void> storeServiceCredentials({
    required String accessToken,
    required String serviceId,
    required String loginName,
    required String appPassword,
  }) async {
    await _postJson(
      '/client/v1/services/${Uri.encodeComponent(serviceId)}/credentials',
      accessToken: accessToken,
      body: {
        'loginName': loginName,
        'appPassword': appPassword,
      },
    );
  }

  Future<Map<String, dynamic>> _postJson(
    String path, {
    required Map<String, dynamic> body,
    String? accessToken,
  }) async {
    final request = await _httpClient.postUrl(baseUri.resolve(path));
    request.headers.contentType = ContentType.json;
    request.headers.set(HttpHeaders.acceptHeader, 'application/json');

    if (accessToken != null) {
      request.headers.set(
        HttpHeaders.authorizationHeader,
        'Bearer $accessToken',
      );
    }

    request.write(jsonEncode(body));

    return _readJsonResponse(await request.close());
  }

  Future<Map<String, dynamic>> _getJson(
    String path, {
    required String accessToken,
  }) async {
    final request = await _httpClient.getUrl(baseUri.resolve(path));
    request.headers.set(HttpHeaders.acceptHeader, 'application/json');
    request.headers.set(
      HttpHeaders.authorizationHeader,
      'Bearer $accessToken',
    );

    return _readJsonResponse(await request.close());
  }

  Future<Map<String, dynamic>> _readJsonResponse(
    HttpClientResponse response,
  ) async {
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

class CaleeHubException implements Exception {
  const CaleeHubException({
    required this.statusCode,
    required this.message,
  });

  final int statusCode;
  final String message;

  @override
  String toString() => message;
}
