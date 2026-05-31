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

  Future<ClientCalendar> createCalendar({
    required String accessToken,
    required String serviceId,
    required String name,
    required String primaryKind,
    String? color,
  }) async {
    final json = await _postJson(
      '/client/v1/calendars',
      accessToken: accessToken,
      body: <String, Object?>{
        'serviceId': serviceId,
        'name': name,
        'primaryKind': primaryKind,
        if (color != null && color.trim().isNotEmpty) 'color': color.trim(),
      },
    );

    return ClientCalendar.fromJson(
      _data(json)['calendar'] as Map<String, dynamic>,
    );
  }

  Future<ClientCalendar> updateCalendar({
    required String accessToken,
    required String calendarId,
    String? name,
    String? color,
  }) async {
    final body = <String, dynamic>{};

    if (name != null) {
      body['name'] = name;
    }

    if (color != null) {
      body['color'] = color;
    }

    if (body.isEmpty) {
      throw const CaleeHubException(
        statusCode: 0,
        message: 'No calendar updates provided',
      );
    }

    final encodedCalendarId = Uri.encodeComponent(calendarId);
    final json = await _patchJson(
      '/client/v1/calendars/$encodedCalendarId',
      accessToken: accessToken,
      body: body,
    );

    return ClientCalendar.fromJson(
      _data(json)['calendar'] as Map<String, dynamic>,
    );
  }

  Future<void> deleteCalendar({
    required String accessToken,
    required String calendarId,
    required bool confirmDeleteItems,
  }) async {
    final encodedCalendarId = Uri.encodeComponent(calendarId);

    await _deleteJson(
      '/client/v1/calendars/$encodedCalendarId',
      accessToken: accessToken,
      body: <String, dynamic>{
        'confirmDeleteItems': confirmDeleteItems,
      },
    );
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

  Future<ClientChore> createChore({
    required String accessToken,
    required String serviceId,
    required String calendarId,
    required String title,
    String? scheduledAt,
    String? description,
    String? recurrence,
    int points = 1,
  }) async {
    final body = <String, Object?>{
      'serviceId': serviceId,
      'calendarId': calendarId,
      'title': title,
      'points': points,
      if (scheduledAt != null && scheduledAt.trim().isNotEmpty)
        'scheduledAt': scheduledAt.trim(),
      if (description != null && description.trim().isNotEmpty)
        'description': description.trim(),
      if (recurrence != null && recurrence.trim().isNotEmpty)
        'recurrence': recurrence.trim(),
    };

    final json = await _postJson(
      '/client/v1/chores',
      accessToken: accessToken,
      body: body,
    );

    return ClientChore.fromJson(_data(json)['chore'] as Map<String, dynamic>);
  }

  Future<ClientChore> updateChore({
    required String accessToken,
    required String choreId,
    required String title,
    String? scheduledAt,
    String? description,
    String? recurrence,
    int points = 1,
  }) async {
    final encodedChoreId = Uri.encodeComponent(choreId);
    final body = <String, Object?>{
      'title': title,
      'points': points,
      'scheduledAt': scheduledAt,
      'description': description ?? '',
      'recurrence': recurrence,
    };

    final json = await _patchJson(
      '/client/v1/chores/$encodedChoreId',
      accessToken: accessToken,
      body: body,
    );

    return ClientChore.fromJson(_data(json)['chore'] as Map<String, dynamic>);
  }

  Future<void> completeChore({
    required String accessToken,
    required String choreId,
    String? date,
  }) async {
    final encodedChoreId = Uri.encodeComponent(choreId);
    final body = <String, dynamic>{};

    if (date != null && date.trim().isNotEmpty) {
      body['date'] = date.trim();
    }

    await _postJson(
      '/client/v1/chores/$encodedChoreId/complete',
      accessToken: accessToken,
      body: body,
    );
  }

  Future<void> deleteChore({
    required String accessToken,
    required String choreId,
  }) async {
    final encodedChoreId = Uri.encodeComponent(choreId);

    await _deleteJson(
      '/client/v1/chores/$encodedChoreId',
      accessToken: accessToken,
    );
  }

  Future<void> undoChoreCompletion({
    required String accessToken,
    required String choreId,
  }) async {
    final encodedChoreId = Uri.encodeComponent(choreId);

    await _deleteJson(
      '/client/v1/chores/$encodedChoreId/completion/today',
      accessToken: accessToken,
    );
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

  Future<ClientEvent> updateEvent({
    required String accessToken,
    required String eventId,
    required String title,
    required String startsAt,
    required String endsAt,
    required bool allDay,
    String? location,
    String? description,
    String? recurrence,
  }) async {
    final encodedEventId = Uri.encodeComponent(eventId);
    final body = <String, Object?>{
      'title': title,
      'startsAt': startsAt,
      'endsAt': endsAt,
      'allDay': allDay,
      'location': location ?? '',
      'description': description ?? '',
    };

    if (recurrence != null && recurrence.trim().isNotEmpty) {
      body['recurrence'] = recurrence.trim();
    }

    final json = await _patchJson(
      '/client/v1/events/$encodedEventId',
      accessToken: accessToken,
      body: body,
    );

    return ClientEvent.fromJson(_data(json)['event'] as Map<String, dynamic>);
  }

  Future<void> deleteEvent({
    required String accessToken,
    required String eventId,
  }) async {
    final encodedEventId = Uri.encodeComponent(eventId);

    await _deleteJson(
      '/client/v1/events/$encodedEventId',
      accessToken: accessToken,
    );
  }

  Future<ClientEvent> createEvent({
    required String accessToken,
    required String serviceId,
    required String calendarId,
    required String title,
    required String startsAt,
    required String endsAt,
    required bool allDay,
    String? location,
    String? description,
    String? recurrence,
  }) async {
    final body = <String, Object?>{
      'serviceId': serviceId,
      'calendarId': calendarId,
      'title': title,
      'startsAt': startsAt,
      'endsAt': endsAt,
      'allDay': allDay,
      if (location != null && location.trim().isNotEmpty)
        'location': location.trim(),
      if (description != null && description.trim().isNotEmpty)
        'description': description.trim(),
      if (recurrence != null && recurrence.trim().isNotEmpty)
        'recurrence': recurrence.trim(),
    };

    final json = await _postJson(
      '/client/v1/events',
      accessToken: accessToken,
      body: body,
    );

    return ClientEvent.fromJson(_data(json)['event'] as Map<String, dynamic>);
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

  Future<void> _deleteJson(
    String path, {
    required String accessToken,
    Map<String, dynamic>? body,
  }) async {
    final request = await _httpClient.deleteUrl(baseUri.resolve(path));
    request.headers.set(HttpHeaders.acceptHeader, 'application/json');
    request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $accessToken');

    if (body != null) {
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode(body));
    }

    await _readJsonResponse(await request.close());
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
