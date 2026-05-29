import 'dart:convert';
import 'dart:io';

import '../models/client_bootstrap.dart';
import '../models/client_calendar.dart';
import '../models/client_chore.dart';
import '../models/client_task.dart';

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

  Future<ClientChoreList> chores({
    required String accessToken,
    required String from,
    required String to,
  }) async {
    final uri = Uri(
      path: '/client/v1/chores',
      queryParameters: {
        'from': from,
        'to': to,
      },
    );

    final json = await _getJson(
      uri.toString(),
      accessToken: accessToken,
    );

    return ClientChoreList.fromJson(_data(json));
  }

  Future<ClientTask> updateTask({
    required String accessToken,
    required String taskId,
    required String title,
    String? dueAt,
    String? description,
  }) async {
    final json = await _patchJson(
      '/client/v1/tasks',
      accessToken: accessToken,
      body: <String, dynamic>{
        'taskId': taskId,
        'title': title,
        'dueAt': dueAt,
        'description': description ?? '',
      },
    );

    return ClientTask.fromJson(_data(json)['task'] as Map<String, dynamic>);
  }

  Future<ClientTask> updateTaskStatus({
    required String accessToken,
    required String taskId,
    required bool completed,
  }) async {
    final json = await _patchJson(
      '/client/v1/tasks',
      accessToken: accessToken,
      body: {
        'taskId': taskId,
        'completed': completed,
      },
    );

    return ClientTask.fromJson(_data(json)['task'] as Map<String, dynamic>);
  }

  Future<void> deleteTask({
    required String accessToken,
    required String taskId,
  }) async {
    final encodedTaskId = Uri.encodeComponent(taskId);

    await _deleteJson(
      '/client/v1/tasks/$encodedTaskId',
      accessToken: accessToken,
    );
  }

  Future<ClientTask> createTask({
    required String accessToken,
    required String serviceId,
    required String calendarId,
    required String title,
    String? dueAt,
    String? description,
  }) async {
    final body = <String, Object?>{
      'serviceId': serviceId,
      'calendarId': calendarId,
      'title': title,
      if (dueAt != null && dueAt.trim().isNotEmpty) 'dueAt': dueAt.trim(),
      if (description != null && description.trim().isNotEmpty)
        'description': description.trim(),
    };

    final json = await _postJson(
      '/client/v1/tasks',
      accessToken: accessToken,
      body: body,
    );

    return ClientTask.fromJson(_data(json)['task'] as Map<String, dynamic>);
  }

  Future<ClientTaskList> tasks({
    required String accessToken,
    required String from,
    required String to,
  }) async {
    final uri = Uri(
      path: '/client/v1/tasks',
      queryParameters: {
        'from': from,
        'to': to,
      },
    );

    final json = await _getJson(
      uri.toString(),
      accessToken: accessToken,
    );

    return ClientTaskList.fromJson(_data(json));
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

  Future<Map<String, dynamic>> _deleteJson(
    String path, {
    required String accessToken,
  }) async {
    final request = await _httpClient.deleteUrl(baseUri.resolve(path));
    request.headers.set(HttpHeaders.acceptHeader, 'application/json');
    request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $accessToken');

    return _readJsonResponse(await request.close());
  }

  Future<Map<String, dynamic>> _patchJson(
    String path, {
    required String accessToken,
    required Map<String, dynamic> body,
  }) async {
    final request = await _httpClient.openUrl('PATCH', baseUri.resolve(path));
    request.headers.contentType = ContentType.json;
    request.headers.set(HttpHeaders.acceptHeader, 'application/json');
    request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $accessToken');
    request.write(jsonEncode(body));

    return _readJsonResponse(await request.close());
  }

  Future<Map<String, dynamic>> _postJson(
    String path, {
    String? accessToken,
    required Map<String, dynamic> body,
  }) async {
    final request = await _httpClient.postUrl(baseUri.resolve(path));
    request.headers.contentType = ContentType.json;
    request.headers.set(HttpHeaders.acceptHeader, 'application/json');
    if (accessToken != null && accessToken.trim().isNotEmpty) {
      request.headers
          .set(HttpHeaders.authorizationHeader, 'Bearer $accessToken');
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
