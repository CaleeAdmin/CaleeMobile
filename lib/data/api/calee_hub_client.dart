import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import '../models/client_bootstrap.dart';
import '../models/client_caldav_account.dart';
import '../models/client_calendar.dart';
import '../models/client_chore.dart';
import '../models/client_chore_metadata.dart';
import '../models/client_deleted_items.dart';
import '../models/client_event_draft.dart';
import '../models/client_meal.dart';
import '../models/client_person.dart';
import '../models/client_profile.dart';
import '../models/client_shopping_list.dart';
import '../models/client_task.dart';
import '../models/external_calendar_connection.dart';

class CaleeHubClient {
  CaleeHubClient({Uri? baseUri, HttpClient? httpClient})
    : baseUri = baseUri ?? Uri.parse('https://hub.calee.com.au'),
      _isInjectedClient = httpClient != null {
    _httpClient = httpClient ?? _newHttpClient();
  }

  final Uri baseUri;
  final bool _isInjectedClient;
  late HttpClient _httpClient;

  static const _kTimeout = Duration(seconds: 25);
  static const _kImageAiTimeout = Duration(seconds: 90);

  // Set by CaleeApp after construction to enable transparent 401 refresh+retry.
  // The callback should refresh the access token and return the new one,
  // or return null (or throw) if refresh fails, which causes the original
  // CaleeHubException(401) to be rethrown to the caller.
  Future<String?> Function()? onUnauthorized;

  // The most recently refreshed access token. Used transparently so feature
  // pages don't need to update their stored token before the next request.
  String? _refreshedToken;

  // Call this when signing out or signing in to discard any cached token.
  void clearAuthCache() => _refreshedToken = null;

  HttpClient _newHttpClient() {
    return HttpClient()
      ..connectionTimeout = const Duration(seconds: 25)
      ..idleTimeout = const Duration(seconds: 30);
  }

  /// Closes the current HTTP transport and opens a fresh one.
  /// Safe to call after returning from background; no-op for injected clients.
  void resetTransport() {
    if (_isInjectedClient) return;
    try {
      _httpClient.close(force: true);
    } catch (_) {
      // Ignore close failures.
    }
    _httpClient = _newHttpClient();
  }

  Future<ClientLoginResult> login({
    required String email,
    required String password,
  }) async {
    final json = await _postJson(
      '/client/v1/auth/login',
      body: {'email': email, 'password': password},
    );

    return ClientLoginResult.fromJson(_data(json));
  }

  Future<ClientBootstrap> bootstrap({required String accessToken}) async {
    final json = await _getJson(
      '/client/v1/bootstrap',
      accessToken: accessToken,
    );

    return ClientBootstrap.fromJson(_data(json));
  }

  Future<ClientContext> ensureDefaultFamily({
    required String accessToken,
  }) async {
    // Try idempotent endpoint first; fall back to create if backend returns 404/405.
    try {
      final json = await _postJson(
        '/client/v1/households/default',
        accessToken: accessToken,
        body: {},
      );
      return _parseHouseholdContext(_data(json));
    } on CaleeHubException catch (e) {
      if (e.statusCode != 404 && e.statusCode != 405) rethrow;
    }

    final json = await _postJson(
      '/client/v1/households',
      accessToken: accessToken,
      body: {'name': 'My Family'},
    );
    return _parseHouseholdContext(_data(json));
  }

  ClientContext _parseHouseholdContext(Map<String, dynamic> data) {
    final raw = data['household'] ?? data['context'] ?? data;
    if (raw is! Map<String, dynamic>) {
      throw const CaleeHubException(
        statusCode: 0,
        message: 'Could not set up your family. Please try again.',
      );
    }
    try {
      return ClientContext.fromJson(raw);
    } catch (_) {
      throw const CaleeHubException(
        statusCode: 0,
        message: 'Could not set up your family. Please try again.',
      );
    }
  }

  /// Returns CalDAV/Nextcloud service credentials for external calendar setup.
  /// These credentials are not the CaleeMobile app session auth.
  /// CaleeMobile API calls must continue to use Hub access/refresh tokens.
  Future<ClientCalDavAccount> caldavAccount({
    required String accessToken,
    required String serviceId,
  }) async {
    final encodedServiceId = Uri.encodeComponent(serviceId);
    final json = await _getJson(
      '/client/v1/services/$encodedServiceId/caldav-account',
      accessToken: accessToken,
    );
    return ClientCalDavAccount.fromJson(_data(json));
  }

  Future<ClientCalendarList> calendars({required String accessToken}) async {
    final json = await _getJson(
      '/client/v1/calendars',
      accessToken: accessToken,
    );

    return ClientCalendarList.fromJson(_data(json));
  }

  Future<ClientPersonList> people({
    required String accessToken,
    required String householdId,
    bool includeArchived = false,
  }) async {
    final encodedHouseholdId = Uri.encodeComponent(householdId);
    var path = '/client/v1/households/$encodedHouseholdId/people';

    if (includeArchived) {
      path += '?includeArchived=true';
    }

    final json = await _getJson(path, accessToken: accessToken);

    return ClientPersonList.fromJson(_data(json));
  }

  Future<ClientPerson> createPerson({
    required String accessToken,
    required String householdId,
    required String displayName,
    String? avatarColor,
    String role = 'member',
    int sortOrder = 0,
  }) async {
    final encodedHouseholdId = Uri.encodeComponent(householdId);

    final json = await _postJson(
      '/client/v1/households/$encodedHouseholdId/people',
      accessToken: accessToken,
      body: <String, Object?>{
        'displayName': displayName,
        if (avatarColor != null && avatarColor.trim().isNotEmpty)
          'avatarColor': avatarColor.trim(),
        'role': role,
        'sortOrder': sortOrder,
      },
    );

    return ClientPerson.fromJson(_data(json)['person'] as Map<String, dynamic>);
  }

  Future<ClientPerson> updatePerson({
    required String accessToken,
    required String householdId,
    required String personId,
    String? displayName,
    String? avatarColor,
    String? role,
    int? sortOrder,
  }) async {
    final body = <String, dynamic>{};

    if (displayName != null) {
      body['displayName'] = displayName;
    }

    if (avatarColor != null) {
      body['avatarColor'] = avatarColor;
    }

    if (role != null) {
      body['role'] = role;
    }

    if (sortOrder != null) {
      body['sortOrder'] = sortOrder;
    }

    if (body.isEmpty) {
      throw const CaleeHubException(
        statusCode: 0,
        message: 'No person updates provided',
      );
    }

    final encodedHouseholdId = Uri.encodeComponent(householdId);
    final encodedPersonId = Uri.encodeComponent(personId);

    final json = await _patchJson(
      '/client/v1/households/$encodedHouseholdId/people/$encodedPersonId',
      accessToken: accessToken,
      body: body,
    );

    return ClientPerson.fromJson(_data(json)['person'] as Map<String, dynamic>);
  }

  Future<ClientPerson> archivePerson({
    required String accessToken,
    required String householdId,
    required String personId,
  }) async {
    final encodedHouseholdId = Uri.encodeComponent(householdId);
    final encodedPersonId = Uri.encodeComponent(personId);

    final json = await _deleteJson(
      '/client/v1/households/$encodedHouseholdId/people/$encodedPersonId',
      accessToken: accessToken,
    );

    return ClientPerson.fromJson(_data(json)['person'] as Map<String, dynamic>);
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

  Future<ClientCalendar> subscribeCalendarFromLink({
    required String accessToken,
    required String serviceId,
    required String name,
    required String url,
    String? color,
  }) async {
    final json = await _postJson(
      '/client/v1/calendar-subscriptions',
      accessToken: accessToken,
      body: <String, Object?>{
        'serviceId': serviceId,
        'name': name,
        'url': url,
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
      body: <String, dynamic>{'confirmDeleteItems': confirmDeleteItems},
    );
  }

  Future<ClientChoreList> chores({
    required String accessToken,
    required String from,
    required String to,
  }) async {
    final uri = Uri(
      path: '/client/v1/chores',
      queryParameters: {'from': from, 'to': to},
    );

    final json = await _getJson(uri.toString(), accessToken: accessToken);

    return ClientChoreList.fromJson(_data(json));
  }

  Future<ClientChoreMetadata> choreMetadata({
    required String accessToken,
    required String householdId,
    required String choreUid,
  }) async {
    final encodedHouseholdId = Uri.encodeComponent(householdId);
    final encodedChoreUid = Uri.encodeComponent(choreUid);

    final json = await _getJson(
      '/client/v1/households/$encodedHouseholdId/chores/$encodedChoreUid/metadata',
      accessToken: accessToken,
    );

    return ClientChoreMetadata.fromJson(
      _data(json)['metadata'] as Map<String, dynamic>,
    );
  }

  Future<ClientChoreMetadata> updateChoreMetadata({
    required String accessToken,
    required String householdId,
    required String choreUid,
    String? assigneePersonId,
    int? points,
    String? approvalState,
  }) async {
    final body = <String, dynamic>{};

    if (assigneePersonId != null) {
      body['assigneePersonId'] = assigneePersonId.isEmpty
          ? null
          : int.tryParse(assigneePersonId) ?? assigneePersonId;
    }

    if (points != null) {
      body['points'] = points;
    }

    if (approvalState != null) {
      body['approvalState'] = approvalState;
    }

    if (body.isEmpty) {
      throw const CaleeHubException(
        statusCode: 0,
        message: 'No chore metadata updates provided',
      );
    }

    final encodedHouseholdId = Uri.encodeComponent(householdId);
    final encodedChoreUid = Uri.encodeComponent(choreUid);

    final json = await _patchJson(
      '/client/v1/households/$encodedHouseholdId/chores/$encodedChoreUid/metadata',
      accessToken: accessToken,
      body: body,
    );

    return ClientChoreMetadata.fromJson(
      _data(json)['metadata'] as Map<String, dynamic>,
    );
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
    String? householdId,
    String? assigneePersonId,
    int? metadataPoints,
    String? approvalState,
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
      if (householdId != null && householdId.trim().isNotEmpty)
        'householdId': householdId.trim(),
      if (assigneePersonId != null) 'assigneePersonId': assigneePersonId,
      if (metadataPoints != null) 'metadataPoints': metadataPoints,
      if (approvalState != null) 'approvalState': approvalState,
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
    String? householdId,
    String? choreUid,
    String? assigneePersonId,
    int? metadataPoints,
    String? approvalState,
  }) async {
    final encodedChoreId = Uri.encodeComponent(choreId);
    final body = <String, Object?>{
      'title': title,
      'points': points,
      'scheduledAt': scheduledAt,
      'description': description ?? '',
      'recurrence': recurrence,
      if (householdId != null && householdId.trim().isNotEmpty)
        'householdId': householdId.trim(),
      if (choreUid != null && choreUid.trim().isNotEmpty)
        'choreUid': choreUid.trim(),
      if (assigneePersonId != null) 'assigneePersonId': assigneePersonId,
      if (metadataPoints != null) 'metadataPoints': metadataPoints,
      if (approvalState != null) 'approvalState': approvalState,
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
    String? action,
    String? date,
  }) async {
    final encodedChoreId = Uri.encodeComponent(choreId);
    var path = '/client/v1/chores/$encodedChoreId';

    final queryParameters = <String, String>{};
    if (action != null && action.trim().isNotEmpty) {
      queryParameters['action'] = action.trim();
    }
    if (date != null && date.trim().isNotEmpty) {
      queryParameters['date'] = date.trim();
    }

    if (queryParameters.isNotEmpty) {
      path += '?${Uri(queryParameters: queryParameters).query}';
    }

    await _deleteJson(path, accessToken: accessToken);
  }

  Future<void> undoChoreCompletion({
    required String accessToken,
    required String choreId,
    String? date,
  }) async {
    final encodedChoreId = Uri.encodeComponent(choreId);

    // Prefer the date-specific endpoint so undo targets the right occurrence
    // once a chore has more than one active row; fall back to the /today
    // alias (which only ever undoes today's completion) when no date is
    // available.
    if (date != null && date.trim().isNotEmpty) {
      final query = Uri(queryParameters: {'date': date.trim()}).query;
      await _deleteJson(
        '/client/v1/chores/$encodedChoreId/completion?$query',
        accessToken: accessToken,
      );
      return;
    }

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
      body: {'taskId': taskId, 'completed': completed},
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
      queryParameters: {'from': from, 'to': to},
    );

    final json = await _getJson(uri.toString(), accessToken: accessToken);

    return ClientTaskList.fromJson(_data(json));
  }

  // ── Meals ─────────────────────────────────────────────────────────────────

  Future<ClientMealList> meals({
    required String accessToken,
    required String from,
    required String to,
  }) async {
    final uri = Uri(
      path: '/client/v1/meals',
      queryParameters: {'from': from, 'to': to},
    );
    final json = await _getJson(uri.toString(), accessToken: accessToken);
    return ClientMealList.fromJson(_data(json));
  }

  Future<ClientMeal> createMeal({
    required String accessToken,
    required String mealDate,
    required String mealType,
    required String title,
    String? notes,
  }) async {
    final body = <String, Object?>{
      'mealDate': mealDate,
      'mealType': mealType,
      'title': title,
      if (notes != null && notes.trim().isNotEmpty) 'notes': notes.trim(),
    };
    final json = await _postJson(
      '/client/v1/meals',
      accessToken: accessToken,
      body: body,
    );
    return ClientMeal.fromJson(_data(json)['meal'] as Map<String, dynamic>);
  }

  Future<ClientMeal> updateMeal({
    required String accessToken,
    required int mealId,
    String? mealDate,
    String? mealType,
    String? title,
    String? notes,
    String? status,
  }) async {
    final body = <String, dynamic>{
      if (mealDate != null) 'mealDate': mealDate,
      if (mealType != null) 'mealType': mealType,
      if (title != null) 'title': title,
      if (notes != null) 'notes': notes,
      if (status != null) 'status': status,
    };
    if (body.isEmpty) {
      throw const CaleeHubException(
        statusCode: 0,
        message: 'No meal updates provided',
      );
    }
    final json = await _patchJson(
      '/client/v1/meals/$mealId',
      accessToken: accessToken,
      body: body,
    );
    return ClientMeal.fromJson(_data(json)['meal'] as Map<String, dynamic>);
  }

  Future<void> deleteMeal({
    required String accessToken,
    required int mealId,
  }) async {
    await _deleteJson('/client/v1/meals/$mealId', accessToken: accessToken);
  }

  Future<ClientMealTemplateList> mealTemplates({
    required String accessToken,
    String? mealType,
  }) async {
    final queryParameters = <String, String>{
      if (mealType != null && mealType.trim().isNotEmpty) 'mealType': mealType,
    };
    final uri = queryParameters.isEmpty
        ? Uri(path: '/client/v1/meal-templates')
        : Uri(
            path: '/client/v1/meal-templates',
            queryParameters: queryParameters,
          );
    final json = await _getJson(uri.toString(), accessToken: accessToken);
    return ClientMealTemplateList.fromJson(_data(json));
  }

  Future<ClientMealCopyWeekResult> copyMealWeek({
    required String accessToken,
    required String sourceFrom,
    required String sourceTo,
    required String targetFrom,
    String mode = 'skip_existing',
  }) async {
    final body = <String, dynamic>{
      'sourceFrom': sourceFrom,
      'sourceTo': sourceTo,
      'targetFrom': targetFrom,
      'mode': mode,
    };
    final json = await _postJson(
      '/client/v1/meals/copy-week',
      accessToken: accessToken,
      body: body,
    );
    return ClientMealCopyWeekResult.fromJson(_data(json));
  }

  // ── Shopping ─────────────────────────────────────────────────────────────

  Future<List<ClientStarterMealTemplate>> mealStarterTemplates({
    required String accessToken,
    String? mealType,
    String? pack,
  }) async {
    final queryParameters = <String, String>{
      if (mealType != null && mealType.trim().isNotEmpty) 'mealType': mealType,
      if (pack != null && pack.trim().isNotEmpty) 'pack': pack,
    };
    final uri = queryParameters.isEmpty
        ? Uri(path: '/client/v1/meal-starter-templates')
        : Uri(
            path: '/client/v1/meal-starter-templates',
            queryParameters: queryParameters,
          );
    final json = await _getJson(uri.toString(), accessToken: accessToken);
    final data = _data(json);
    final list = data['templates'] as List<dynamic>? ?? const [];
    return list
        .whereType<Map<String, dynamic>>()
        .map(ClientStarterMealTemplate.fromJson)
        .toList();
  }

  Future<ClientShoppingList> currentShoppingList({
    required String accessToken,
    required String from,
    required String to,
  }) async {
    final uri = Uri(
      path: '/client/v1/shopping-lists/current',
      queryParameters: {'from': from, 'to': to},
    );
    final json = await _getJson(uri.toString(), accessToken: accessToken);
    return ClientShoppingList.fromJson(
      _data(json)['shoppingList'] as Map<String, dynamic>,
    );
  }

  Future<ClientShoppingList> generateShoppingList({
    required String accessToken,
    required String from,
    required String to,
    String mode = 'merge',
  }) async {
    final json = await _postJson(
      '/client/v1/shopping-lists/generate',
      accessToken: accessToken,
      body: {'from': from, 'to': to, 'mode': mode},
    );
    return ClientShoppingList.fromJson(
      _data(json)['shoppingList'] as Map<String, dynamic>,
    );
  }

  Future<ClientShoppingListItem> addShoppingListItem({
    required String accessToken,
    required int listId,
    required String name,
    String? category,
  }) async {
    final body = <String, Object?>{
      'name': name,
      if (category != null && category.trim().isNotEmpty)
        'category': category.trim(),
    };
    final json = await _postJson(
      '/client/v1/shopping-lists/$listId/items',
      accessToken: accessToken,
      body: body,
    );
    return ClientShoppingListItem.fromJson(
      _data(json)['item'] as Map<String, dynamic>,
    );
  }

  Future<ClientShoppingListItem> updateShoppingListItem({
    required String accessToken,
    required int listId,
    required int itemId,
    required bool checked,
  }) async {
    final json = await _patchJson(
      '/client/v1/shopping-lists/$listId/items/$itemId',
      accessToken: accessToken,
      body: {'checked': checked},
    );
    return ClientShoppingListItem.fromJson(
      _data(json)['item'] as Map<String, dynamic>,
    );
  }

  // Note: DELETE returns {"id": <int>, "deleted": true} — the caller already
  // knows which item it deleted, so (like deleteMeal/deleteTask/deleteChore)
  // this doesn't need to parse and return that body.
  Future<void> deleteShoppingListItem({
    required String accessToken,
    required int listId,
    required int itemId,
  }) async {
    await _deleteJson(
      '/client/v1/shopping-lists/$listId/items/$itemId',
      accessToken: accessToken,
    );
  }

  // ── Events ────────────────────────────────────────────────────────────────

  Future<ClientEvent> updateEvent({
    required String accessToken,
    required String eventId,
    required String title,
    String? startsAt,
    String? endsAt,
    bool? allDay,
    String? location,
    String? description,
    String? recurrence,
    bool includeRecurrence = false,
    String? scope,
  }) async {
    final encodedEventId = Uri.encodeComponent(eventId);
    final body = <String, Object?>{
      'title': title,
      'location': location ?? '',
      'description': description ?? '',
    };

    final hasDateUpdate = startsAt != null || endsAt != null || allDay != null;
    if (hasDateUpdate) {
      if (startsAt == null || endsAt == null || allDay == null) {
        throw ArgumentError(
          'startsAt, endsAt, and allDay must be supplied together.',
        );
      }

      body['startsAt'] = startsAt;
      body['endsAt'] = endsAt;
      body['allDay'] = allDay;
    }

    if (includeRecurrence) {
      body['recurrence'] = recurrence == null || recurrence.trim().isEmpty
          ? null
          : recurrence.trim();
    } else if (recurrence != null && recurrence.trim().isNotEmpty) {
      body['recurrence'] = recurrence.trim();
    }

    final trimmedScope = scope?.trim();
    final path = trimmedScope == null || trimmedScope.isEmpty
        ? '/client/v1/events/$encodedEventId'
        : '/client/v1/events/$encodedEventId?scope=${Uri.encodeQueryComponent(trimmedScope)}';

    final json = await _patchJson(path, accessToken: accessToken, body: body);

    return ClientEvent.fromJson(_data(json)['event'] as Map<String, dynamic>);
  }

  Future<void> deleteEvent({
    required String accessToken,
    required String eventId,
    String? scope,
  }) async {
    final encodedEventId = Uri.encodeComponent(eventId);
    final trimmedScope = scope?.trim();
    final path = trimmedScope == null || trimmedScope.isEmpty
        ? '/client/v1/events/$encodedEventId'
        : '/client/v1/events/$encodedEventId?scope=${Uri.encodeQueryComponent(trimmedScope)}';

    await _deleteJson(path, accessToken: accessToken);
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

  Future<EventDraftsFromImageResponse> eventDraftsFromImage({
    required String accessToken,
    required File imageFile,
    String? timezone,
    String? referenceDate,
    String? sourceHint,
  }) async {
    final mimeType = _inferImageMimeType(imageFile.path);
    final fileSize = await imageFile.length();
    if (fileSize > 8 * 1024 * 1024) {
      throw const CaleeHubException(
        statusCode: 0,
        code: 'FILE_TOO_LARGE',
        message: 'This image is too large. Please choose an image under 8 MB.',
      );
    }

    const path = '/v1/ai/calendar/event-drafts/from-image';
    final Map<String, dynamic> raw;
    try {
      raw = await _withRetry(
        (token) => _doMultipartPost(
          path,
          accessToken: token,
          imageFile: imageFile,
          mimeType: mimeType,
          timezone: timezone,
          referenceDate: referenceDate,
          sourceHint: sourceHint,
        ),
        accessToken,
      );
    } on CaleeHubException catch (e) {
      if (e.statusCode == 401 && kDebugMode) {
        debugPrint(
          'EventDraftsFromImage: /v1 endpoint exists, but bearer token was rejected. '
          'Check whether this route expects device token or client token.',
        );
      }
      rethrow;
    }

    final payload =
        raw.containsKey('data') && raw['data'] is Map<String, dynamic>
        ? raw['data'] as Map<String, dynamic>
        : raw;
    return EventDraftsFromImageResponse.fromJson(payload);
  }

  static String _inferImageMimeType(String filePath) {
    final ext = filePath.split('.').last.toLowerCase();
    return switch (ext) {
      'jpg' || 'jpeg' => 'image/jpeg',
      'png' => 'image/png',
      'webp' => 'image/webp',
      _ => throw const CaleeHubException(
        statusCode: 0,
        code: 'UNSUPPORTED_FORMAT',
        message: 'Please choose a JPEG, PNG, or WebP image.',
      ),
    };
  }

  Future<Map<String, dynamic>> _doMultipartPost(
    String path, {
    required String accessToken,
    required File imageFile,
    required String mimeType,
    String? timezone,
    String? referenceDate,
    String? sourceHint,
  }) {
    return _executeImageAiRequest(() async {
      final boundary = 'CaleeBoundary${DateTime.now().millisecondsSinceEpoch}';
      final request = await _httpClient.postUrl(baseUri.resolve(path));
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      request.headers.set(
        HttpHeaders.authorizationHeader,
        'Bearer $accessToken',
      );
      request.headers.contentType = ContentType(
        'multipart',
        'form-data',
        parameters: {'boundary': boundary},
      );

      final body = BytesBuilder();

      void addTextField(String name, String value) {
        body.add(utf8.encode('--$boundary\r\n'));
        body.add(
          utf8.encode('Content-Disposition: form-data; name="$name"\r\n\r\n'),
        );
        body.add(utf8.encode('$value\r\n'));
      }

      final filename = imageFile.path.split('/').last;
      body.add(utf8.encode('--$boundary\r\n'));
      body.add(
        utf8.encode(
          'Content-Disposition: form-data; name="image"; filename="$filename"\r\n',
        ),
      );
      body.add(utf8.encode('Content-Type: $mimeType\r\n\r\n'));
      body.add(await imageFile.readAsBytes());
      body.add(utf8.encode('\r\n'));

      if (timezone != null && timezone.isNotEmpty) {
        addTextField('timezone', timezone);
      }
      if (referenceDate != null && referenceDate.isNotEmpty) {
        addTextField('reference_date', referenceDate);
      }
      if (sourceHint != null && sourceHint.isNotEmpty) {
        addTextField('source_hint', sourceHint);
      }

      body.add(utf8.encode('--$boundary--\r\n'));

      final bodyBytes = body.toBytes();
      if (kDebugMode) {
        debugPrint(
          'EventDraftsFromImage: POST $path bytes=${bodyBytes.length}',
        );
      }
      request.contentLength = bodyBytes.length;
      request.add(bodyBytes);

      final response = await request.close();
      if (kDebugMode) {
        debugPrint(
          'EventDraftsFromImage: response status=${response.statusCode}',
        );
      }
      return _readJsonResponse(response, endpoint: path);
    });
  }

  Future<Map<String, dynamic>> _executeImageAiRequest(
    Future<Map<String, dynamic>> Function() fn,
  ) async {
    try {
      return await fn().timeout(_kImageAiTimeout);
    } on CaleeHubException {
      rethrow;
    } on TimeoutException {
      throw const CaleeHubException(
        statusCode: 0,
        code: 'AI_IMAGE_TIMEOUT',
        message: 'Image scanning is taking too long. Please try again.',
      );
    } on SocketException {
      throw const CaleeHubException(
        statusCode: 0,
        code: 'NETWORK_ERROR',
        message: 'Check your connection and try again.',
      );
    } on HandshakeException {
      throw const CaleeHubException(
        statusCode: 0,
        code: 'NETWORK_ERROR',
        message: 'Check your connection and try again.',
      );
    }
  }

  Future<ClientEventList> events({
    required String accessToken,
    required String from,
    required String to,
  }) async {
    final uri = Uri(
      path: '/client/v1/events',
      queryParameters: {'from': from, 'to': to},
    );

    final json = await _getJson(uri.toString(), accessToken: accessToken);

    return ClientEventList.fromJson(_data(json));
  }

  Future<DeletedItemsResponse> listDeletedItems({
    required String accessToken,
    String? serviceId,
    String? type,
    int? limit,
    String? cursor,
  }) async {
    final queryParameters = <String, String>{};
    if (serviceId != null) queryParameters['serviceId'] = serviceId;
    if (type != null) queryParameters['type'] = type;
    if (limit != null) queryParameters['limit'] = limit.toString();
    if (cursor != null) queryParameters['cursor'] = cursor;

    final uri = queryParameters.isEmpty
        ? Uri(path: '/client/v1/deleted-items')
        : Uri(
            path: '/client/v1/deleted-items',
            queryParameters: queryParameters,
          );

    final json = await _getJson(uri.toString(), accessToken: accessToken);
    return DeletedItemsResponse.fromJson(_data(json));
  }

  Future<DeletedItemsResponse> listDeletedItemsForService(
    String serviceId, {
    required String accessToken,
    String? type,
    int? limit,
    String? cursor,
  }) async {
    final encodedServiceId = Uri.encodeComponent(serviceId);
    final queryParameters = <String, String>{};
    if (type != null) queryParameters['type'] = type;
    if (limit != null) queryParameters['limit'] = limit.toString();
    if (cursor != null) queryParameters['cursor'] = cursor;

    final path = '/client/v1/services/$encodedServiceId/deleted-items';
    final uri = queryParameters.isEmpty
        ? Uri(path: path)
        : Uri(path: path, queryParameters: queryParameters);

    final json = await _getJson(uri.toString(), accessToken: accessToken);
    return DeletedItemsResponse.fromJson(_data(json));
  }

  Future<void> restoreDeletedItem({
    required String accessToken,
    required String serviceId,
    required String deletedItemId,
  }) async {
    final encodedServiceId = Uri.encodeComponent(serviceId);
    final encodedItemId = Uri.encodeComponent(deletedItemId);

    await _postJson(
      '/client/v1/services/$encodedServiceId/deleted-items/$encodedItemId/restore',
      accessToken: accessToken,
      body: {},
    );
  }

  Future<void> deleteDeletedItemPermanently({
    required String accessToken,
    required String serviceId,
    required String deletedItemId,
  }) async {
    final encodedServiceId = Uri.encodeComponent(serviceId);
    final encodedItemId = Uri.encodeComponent(deletedItemId);

    await _postJson(
      '/client/v1/services/$encodedServiceId/deleted-items/$encodedItemId/delete-permanently',
      accessToken: accessToken,
      body: {},
    );
  }

  Future<ClientLoginResult> register({
    required String firstName,
    required String lastName,
    required String email,
    required String confirmEmail,
    required String redeemCode,
    required String password,
    required String confirmPassword,
  }) async {
    final json = await _postJson(
      '/client/v1/auth/register',
      body: {
        'firstName': firstName,
        'lastName': lastName,
        'email': email,
        'confirmEmail': confirmEmail,
        'redeemCode': redeemCode,
        'password': password,
        'confirmPassword': confirmPassword,
      },
    );
    return ClientLoginResult.fromJson(_data(json));
  }

  Future<void> requestPasswordReset({required String email}) async {
    await _postJson(
      '/client/v1/auth/password-resets/request',
      body: {'email': email.trim()},
    );
  }

  Future<void> approveDisplayLogin({
    required String accessToken,
    required String token,
  }) async {
    final encodedToken = Uri.encodeComponent(token);
    await _postJson(
      '/client/v1/displays/native-login/$encodedToken/approve',
      accessToken: accessToken,
      body: {},
    );
  }

  Future<ClientRefreshResult> refresh({required String refreshToken}) async {
    final json = await _postJson(
      '/client/v1/auth/refresh',
      body: {'refreshToken': refreshToken},
    );

    return ClientRefreshResult.fromJson(_data(json));
  }

  Future<ClientProfile> profile({required String accessToken}) async {
    final json = await _getJson('/client/v1/profile', accessToken: accessToken);
    final data = _data(json);
    final profileJson = data['profile'];
    if (profileJson is! Map<String, dynamic>) {
      throw const CaleeHubException(
        statusCode: 0,
        message: 'Could not load your profile. Please try again.',
      );
    }
    return ClientProfile.fromJson(profileJson);
  }

  Future<ClientProfile> updateProfile({
    required String accessToken,
    String? firstName,
    String? lastName,
    String? displayName,
    String? timeZone,
    String? postalCode,
    String? countryCode,
    String? locale,
  }) async {
    final body = <String, dynamic>{
      if (firstName != null) 'firstName': firstName,
      if (lastName != null) 'lastName': lastName,
      if (displayName != null) 'displayName': displayName,
      if (timeZone != null) 'timeZone': timeZone,
      if (postalCode != null) 'postalCode': postalCode,
      if (countryCode != null) 'countryCode': countryCode,
      if (locale != null) 'locale': locale,
    };

    if (body.isEmpty) {
      throw const CaleeHubException(
        statusCode: 0,
        message: 'No profile updates provided',
      );
    }

    final json = await _patchJson(
      '/client/v1/profile',
      accessToken: accessToken,
      body: body,
    );
    final data = _data(json);
    final rawProfile = data['profile'];
    if (rawProfile is! Map<String, dynamic>) {
      throw const CaleeHubException(
        statusCode: 0,
        message: 'Could not load your profile. Please try again.',
      );
    }
    final profileJson = Map<String, dynamic>.from(rawProfile);
    final warnings = data['warnings'];
    if (warnings is List) {
      profileJson['warnings'] = warnings.whereType<String>().toList();
    }
    return ClientProfile.fromJson(profileJson);
  }

  // ── External calendar connections ─────────────────────────────────────────────────────

  Future<List<ExternalCalendarProvider>> externalCalendarProviders({
    required String accessToken,
  }) async {
    final json = await _getJson(
      '/client/v1/external-calendar-providers',
      accessToken: accessToken,
    );
    final data = _data(json);
    final list = data['providers'] as List<dynamic>? ?? const [];
    return list
        .whereType<Map<String, dynamic>>()
        .map(ExternalCalendarProvider.fromJson)
        .toList();
  }

  Future<String> startExternalCalendarOAuth({
    required String accessToken,
    required String providerKey,
    String accessMode = 'read_only',
  }) async {
    final json = await _postJson(
      '/client/v1/external-calendar-connections/oauth/start',
      accessToken: accessToken,
      body: {'providerKey': providerKey, 'accessMode': accessMode},
    );
    final data = _data(json);
    final url = data['authorizationUrl'] as String?;
    if (url == null || url.trim().isEmpty) {
      throw const CaleeHubException(
        statusCode: 0,
        message: 'Could not start Google sign-in. Please try again.',
      );
    }
    return url;
  }

  Future<List<ExternalCalendarConnection>> externalCalendarConnections({
    required String accessToken,
  }) async {
    final json = await _getJson(
      '/client/v1/external-calendar-connections',
      accessToken: accessToken,
    );
    final data = _data(json);
    final list = data['connections'] as List<dynamic>? ?? const [];
    return list
        .whereType<Map<String, dynamic>>()
        .map(ExternalCalendarConnection.fromJson)
        .toList();
  }

  Future<List<ExternalCalendar>> externalCalendarsForConnection({
    required String accessToken,
    required String connectionId,
  }) async {
    final encodedId = Uri.encodeComponent(connectionId);
    final json = await _getJson(
      '/client/v1/external-calendar-connections/$encodedId/calendars',
      accessToken: accessToken,
    );
    final data = _data(json);
    final list = data['calendars'] as List<dynamic>? ?? const [];
    return list
        .whereType<Map<String, dynamic>>()
        .map(ExternalCalendar.fromJson)
        .toList();
  }

  Future<ExternalCalendar> updateExternalCalendar({
    required String accessToken,
    required String externalCalendarId,
    bool? syncEnabled,
    String? displayName,
    String? color,
    ExternalCalendarPrivacySettings? privacySettings,
  }) async {
    final body = <String, dynamic>{};
    if (syncEnabled != null) body['syncEnabled'] = syncEnabled;
    if (displayName != null) body['displayName'] = displayName;
    if (color != null) body['color'] = color;
    if (privacySettings != null) {
      body['privacySettings'] = privacySettings.toJson();
    }

    if (body.isEmpty) {
      throw const CaleeHubException(
        statusCode: 0,
        message: 'No external calendar updates provided',
      );
    }

    final encodedId = Uri.encodeComponent(externalCalendarId);
    final json = await _putJson(
      '/client/v1/external-calendars/$encodedId',
      accessToken: accessToken,
      body: body,
    );
    final data = _data(json);
    return ExternalCalendar.fromJson(
      data['calendar'] as Map<String, dynamic>? ?? data,
    );
  }

  Future<ExternalCalendarSyncResult> syncExternalCalendarNow({
    required String accessToken,
    required String externalCalendarId,
  }) async {
    final encodedId = Uri.encodeComponent(externalCalendarId);
    final json = await _postJson(
      '/client/v1/external-calendars/$encodedId/sync-now',
      accessToken: accessToken,
      body: {},
    );
    final data = _data(json);
    final sync = data['sync'];
    if (sync is! Map<String, dynamic>) {
      throw const CaleeHubException(
        statusCode: 0,
        message: 'Could not sync Google Calendar. Please try again.',
      );
    }
    return ExternalCalendarSyncResult.fromJson(sync);
  }

  Future<void> disconnectExternalCalendarConnection({
    required String accessToken,
    required String connectionId,
  }) async {
    final encodedId = Uri.encodeComponent(connectionId);
    await _deleteJson(
      '/client/v1/external-calendar-connections/$encodedId',
      accessToken: accessToken,
    );
  }

  // ── Auth retry helper ──────────────────────────────────────────────────────────────────
  //
  // On 401, calls onUnauthorized() once to get a fresh token and retries.
  // Also uses any previously refreshed token so feature pages don't need to
  // update their stored access token before the next request.

  Future<Map<String, dynamic>> _withRetry(
    Future<Map<String, dynamic>> Function(String token) doRequest,
    String accessToken,
  ) async {
    final effectiveToken = _refreshedToken ?? accessToken;
    try {
      return await doRequest(effectiveToken);
    } on CaleeHubException catch (e) {
      if (e.statusCode != 401 || onUnauthorized == null) rethrow;
      _refreshedToken = null;
      final newToken = await onUnauthorized!();
      if (newToken == null) rethrow;
      _refreshedToken = newToken;
      return doRequest(newToken);
    }
  }

  // ── Low-level HTTP helpers ────────────────────────────────────────────────────────────────────────

  Future<Map<String, dynamic>> _deleteJson(
    String path, {
    required String accessToken,
    Map<String, dynamic>? body,
  }) {
    return _withRetry(
      (token) => _doDeleteJson(path, accessToken: token, body: body),
      accessToken,
    );
  }

  Future<Map<String, dynamic>> _doDeleteJson(
    String path, {
    required String accessToken,
    Map<String, dynamic>? body,
  }) {
    return _executeRequest(() async {
      final request = await _httpClient.deleteUrl(baseUri.resolve(path));
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      request.headers.set(
        HttpHeaders.authorizationHeader,
        'Bearer $accessToken',
      );

      if (body != null) {
        request.headers.contentType = ContentType.json;
        request.write(jsonEncode(body));
      }

      return _readJsonResponse(await request.close(), endpoint: path);
    });
  }

  Future<Map<String, dynamic>> _putJson(
    String path, {
    required String accessToken,
    required Map<String, dynamic> body,
  }) {
    return _withRetry(
      (token) => _doPutJson(path, accessToken: token, body: body),
      accessToken,
    );
  }

  Future<Map<String, dynamic>> _doPutJson(
    String path, {
    required String accessToken,
    required Map<String, dynamic> body,
  }) {
    return _executeRequest(() async {
      final request = await _httpClient.putUrl(baseUri.resolve(path));
      request.headers.contentType = ContentType.json;
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      request.headers.set(
        HttpHeaders.authorizationHeader,
        'Bearer $accessToken',
      );
      request.write(jsonEncode(body));

      return _readJsonResponse(await request.close(), endpoint: path);
    });
  }

  Future<Map<String, dynamic>> _patchJson(
    String path, {
    required String accessToken,
    required Map<String, dynamic> body,
  }) {
    return _withRetry(
      (token) => _doPatchJson(path, accessToken: token, body: body),
      accessToken,
    );
  }

  Future<Map<String, dynamic>> _doPatchJson(
    String path, {
    required String accessToken,
    required Map<String, dynamic> body,
  }) {
    return _executeRequest(() async {
      final request = await _httpClient.openUrl('PATCH', baseUri.resolve(path));
      request.headers.contentType = ContentType.json;
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      request.headers.set(
        HttpHeaders.authorizationHeader,
        'Bearer $accessToken',
      );
      request.write(jsonEncode(body));

      return _readJsonResponse(await request.close(), endpoint: path);
    });
  }

  Future<Map<String, dynamic>> _postJson(
    String path, {
    String? accessToken,
    required Map<String, dynamic> body,
  }) {
    // Unauthenticated calls (login, refresh) skip retry.
    if (accessToken == null) {
      return _executeRequest(() async {
        final request = await _httpClient.postUrl(baseUri.resolve(path));
        request.headers.contentType = ContentType.json;
        request.headers.set(HttpHeaders.acceptHeader, 'application/json');
        request.write(jsonEncode(body));
        return _readJsonResponse(await request.close(), endpoint: path);
      });
    }
    return _withRetry(
      (token) => _doPostJson(path, accessToken: token, body: body),
      accessToken,
    );
  }

  Future<Map<String, dynamic>> _doPostJson(
    String path, {
    required String? accessToken,
    required Map<String, dynamic> body,
  }) {
    return _executeRequest(() async {
      final request = await _httpClient.postUrl(baseUri.resolve(path));
      request.headers.contentType = ContentType.json;
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      if (accessToken != null && accessToken.trim().isNotEmpty) {
        request.headers.set(
          HttpHeaders.authorizationHeader,
          'Bearer $accessToken',
        );
      }
      request.write(jsonEncode(body));

      return _readJsonResponse(await request.close(), endpoint: path);
    });
  }

  // GET with one safe retry on transient transport failures (stale keep-alive).
  // POST/PUT/PATCH/DELETE are not retried here; only idempotent GETs are safe.
  Future<Map<String, dynamic>> _getJson(
    String path, {
    required String accessToken,
  }) async {
    try {
      return await _withRetry(
        (token) => _doGetJson(path, accessToken: token),
        accessToken,
      );
    } catch (error) {
      if (_isTransientTransportError(error)) {
        if (kDebugMode) {
          debugPrint(
            'CaleeHubClient: transient GET transport error for $path; '
            'retrying once: $error',
          );
        }
        resetTransport();
        return await _withRetry(
          (token) => _doGetJson(path, accessToken: token),
          accessToken,
        );
      }
      rethrow;
    }
  }

  bool _isTransientTransportError(Object error) {
    // _executeRequest wraps SocketException/HandshakeException/TimeoutException
    // into CaleeHubException(statusCode: 0), so check that first.
    if (error is CaleeHubException) {
      return error.statusCode == 0 &&
          (error.code == 'NETWORK_ERROR' || error.code == 'TIMEOUT');
    }
    if (error is HttpException) {
      return error.message.contains(
        'Connection closed before full header was received',
      );
    }
    return error is SocketException || error is HandshakeException;
  }

  Future<Map<String, dynamic>> _doGetJson(
    String path, {
    required String accessToken,
  }) {
    return _executeRequest(() async {
      final request = await _httpClient.getUrl(baseUri.resolve(path));
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      request.headers.set(
        HttpHeaders.authorizationHeader,
        'Bearer $accessToken',
      );

      return _readJsonResponse(await request.close(), endpoint: path);
    });
  }

  // Wraps a request with a timeout and converts network errors to friendly messages.
  Future<Map<String, dynamic>> _executeRequest(
    Future<Map<String, dynamic>> Function() fn,
  ) async {
    try {
      return await fn().timeout(_kTimeout);
    } on CaleeHubException {
      rethrow;
    } on TimeoutException {
      throw const CaleeHubException(
        statusCode: 0,
        code: 'TIMEOUT',
        message: 'Check your connection and try again.',
      );
    } on SocketException {
      throw const CaleeHubException(
        statusCode: 0,
        code: 'NETWORK_ERROR',
        message: 'Check your connection and try again.',
      );
    } on HandshakeException {
      throw const CaleeHubException(
        statusCode: 0,
        code: 'NETWORK_ERROR',
        message: 'Check your connection and try again.',
      );
    }
  }

  Future<Map<String, dynamic>> _readJsonResponse(
    HttpClientResponse response, {
    String? endpoint,
  }) async {
    final body = await response.transform(utf8.decoder).join();
    final decoded = body.isEmpty ? null : jsonDecode(body);

    if (response.statusCode < 200 || response.statusCode >= 300) {
      String? code;
      String? message;
      String? metaRequestId;

      if (decoded is Map<String, dynamic>) {
        final errorMap = decoded['error'];
        String? serviceId;
        String? serviceName;
        if (errorMap is Map<String, dynamic>) {
          code = errorMap['code'] as String?;
          message = errorMap['message'] as String?;
          serviceId = errorMap['serviceId'] as String?;
          serviceName = errorMap['serviceName'] as String?;
        } else {
          message = decoded['message'] as String?;
        }
        final meta = decoded['meta'];
        if (meta is Map<String, dynamic>) {
          metaRequestId = meta['requestId'] as String?;
        }

        final requestId =
            response.headers.value('x-calee-request-id') ??
            response.headers.value('x-request-id') ??
            metaRequestId;

        throw CaleeHubException(
          statusCode: response.statusCode,
          message: message is String && message.trim().isNotEmpty
              ? message
              : 'Hub request failed',
          code: code,
          requestId: requestId,
          endpoint: endpoint,
          serviceId: serviceId,
          serviceName: serviceName,
        );
      }

      final requestId =
          response.headers.value('x-calee-request-id') ??
          response.headers.value('x-request-id') ??
          metaRequestId;

      throw CaleeHubException(
        statusCode: response.statusCode,
        message: 'Hub request failed',
        code: code,
        requestId: requestId,
        endpoint: endpoint,
      );
    }

    if (decoded is! Map<String, dynamic>) {
      throw CaleeHubException(
        statusCode: 0,
        message: 'Invalid Hub response',
        endpoint: endpoint,
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
    this.code,
    this.requestId,
    this.endpoint,
    this.serviceId,
    this.serviceName,
  });

  final int statusCode;
  final String message;
  final String? code;
  final String? requestId;
  final String? endpoint;
  final String? serviceId;
  final String? serviceName;

  String get debugSummary {
    final parts = <String>['HTTP $statusCode'];
    if (code != null) parts.add('code: $code');
    parts.add('message: $message');
    if (requestId != null) parts.add('requestId: $requestId');
    if (endpoint != null) parts.add('endpoint: $endpoint');
    return parts.join(' | ');
  }

  @override
  String toString() => message;
}
