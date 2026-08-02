import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import '../auth/calee_preferences.dart';
import '../models/calendar_subscription_validation.dart';
import '../models/client_bootstrap.dart';
import '../models/client_caldav_account.dart';
import '../models/client_calendar.dart';
import '../models/client_chore.dart';
import '../models/client_chore_metadata.dart';
import '../models/client_deleted_items.dart';
import '../models/client_event_draft.dart';
import '../models/client_meal.dart';
import '../models/client_person.dart';
import '../models/client_preferences.dart';
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
  static const _kAttachmentTransferTimeout = Duration(seconds: 120);

  /// How long a timed-out transfer is given to actually unwind (abort the
  /// request, close the sink, delete a partial file) before `TIMEOUT` is
  /// surfaced regardless. Bounded so a wedged teardown can never turn a
  /// timeout into an indefinite hang.
  static const _kAttachmentTeardownGrace = Duration(seconds: 5);

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

  /// Checks a calendar link before saving it. The backend fetches and
  /// validates the feed itself (redirects, size limits, ICS parsing);
  /// CaleeMobile never fetches or parses the ICS body directly. On success,
  /// save using [CalendarSubscriptionValidationResult.normalizedUrl] rather
  /// than the URL the user originally typed.
  Future<CalendarSubscriptionValidationResult> validateCalendarSubscription({
    required String accessToken,
    required String serviceId,
    required String name,
    required String url,
  }) async {
    final json = await _postJson(
      '/client/v1/calendar-subscriptions/validate',
      accessToken: accessToken,
      body: <String, Object?>{'serviceId': serviceId, 'name': name, 'url': url},
    );

    return CalendarSubscriptionValidationResult.fromJson(_data(json));
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

  /// Edits a calendar's Calee-facing appearance (name/colour) only.
  ///
  /// Unlike [updateCalendar], this never touches the underlying source:
  /// depending on the calendar's appearanceMode the backend either
  /// PROPPATCHes the real CalDAV calendar (source_metadata) or only updates
  /// the local Calee-side mapping/row (subscription_mapping,
  /// external_calendar). Callers should gate on
  /// `calendar.capabilities.canEditAppearance` before offering this.
  ///
  /// The backend applies a partial update: an omitted field is left exactly
  /// as it was, while a sent field becomes a local override. Callers must
  /// therefore pass only the fields the user actually changed — sending an
  /// unchanged name (or colour) would accidentally pin it as a permanent
  /// override, breaking provider renames from then on.
  Future<ClientCalendar> updateCalendarAppearance({
    required String accessToken,
    required String calendarId,
    String? name,
    String? color,
  }) async {
    final body = <String, dynamic>{
      if (name != null) 'name': name,
      if (color != null) 'color': color,
    };

    if (body.isEmpty) {
      throw const CaleeHubException(
        statusCode: 0,
        message: 'No calendar appearance updates provided',
      );
    }

    final encodedCalendarId = Uri.encodeComponent(calendarId);
    final json = await _patchJson(
      '/client/v1/calendars/$encodedCalendarId/appearance',
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
    int? templateId,
    int? starterTemplateId,
  }) async {
    final body = <String, Object?>{
      'mealDate': mealDate,
      'mealType': mealType,
      'title': title,
      if (notes != null && notes.trim().isNotEmpty) 'notes': notes.trim(),
      if (templateId != null) 'templateId': templateId,
      if (starterTemplateId != null) 'starterTemplateId': starterTemplateId,
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

  Future<ClientMealTemplate> createMealTemplate({
    required String accessToken,
    required String name,
    required String defaultMealType,
    String? notes,
    String? icon,
    bool? isFavourite,
  }) async {
    final body = <String, dynamic>{
      'name': name,
      'defaultMealType': defaultMealType,
      if (notes != null) 'notes': notes,
      if (icon != null) 'icon': icon,
      if (isFavourite != null) 'isFavourite': isFavourite,
    };
    final json = await _postJson(
      '/client/v1/meal-templates',
      accessToken: accessToken,
      body: body,
    );
    return ClientMealTemplate.fromJson(
      _data(json)['template'] as Map<String, dynamic>,
    );
  }

  Future<ClientMealTemplate> updateMealTemplate({
    required String accessToken,
    required int templateId,
    String? name,
    String? notes,
    bool? isFavourite,
  }) async {
    final body = <String, dynamic>{
      if (name != null) 'name': name,
      if (notes != null) 'notes': notes,
      if (isFavourite != null) 'isFavourite': isFavourite,
    };
    if (body.isEmpty) {
      throw const CaleeHubException(
        statusCode: 0,
        message: 'No meal template updates provided',
      );
    }
    final json = await _patchJson(
      '/client/v1/meal-templates/$templateId',
      accessToken: accessToken,
      body: body,
    );
    return ClientMealTemplate.fromJson(
      _data(json)['template'] as Map<String, dynamic>,
    );
  }

  Future<void> deleteMealTemplate({
    required String accessToken,
    required int templateId,
  }) async {
    await _deleteJson(
      '/client/v1/meal-templates/$templateId',
      accessToken: accessToken,
    );
  }

  Future<List<ClientTemplateIngredient>> mealTemplateIngredients({
    required String accessToken,
    required int templateId,
  }) async {
    final json = await _getJson(
      '/client/v1/meal-templates/$templateId/ingredients',
      accessToken: accessToken,
    );
    final list = _data(json)['ingredients'] as List<dynamic>? ?? const [];
    return list
        .whereType<Map<String, dynamic>>()
        .map(ClientTemplateIngredient.fromJson)
        .toList();
  }

  Future<ClientTemplateIngredient> addMealTemplateIngredient({
    required String accessToken,
    required int templateId,
    required String name,
    String? quantityText,
    String? unit,
    String? category,
  }) async {
    final body = <String, dynamic>{
      'name': name,
      if (quantityText != null) 'quantityText': quantityText,
      if (unit != null) 'unit': unit,
      if (category != null) 'category': category,
    };
    final json = await _postJson(
      '/client/v1/meal-templates/$templateId/ingredients',
      accessToken: accessToken,
      body: body,
    );
    return ClientTemplateIngredient.fromJson(
      _data(json)['ingredient'] as Map<String, dynamic>,
    );
  }

  Future<ClientTemplateIngredient> updateMealTemplateIngredient({
    required String accessToken,
    required int templateId,
    required int ingredientId,
    String? name,
    String? quantityText,
    String? unit,
    String? category,
  }) async {
    final body = <String, dynamic>{
      if (name != null) 'name': name,
      if (quantityText != null) 'quantityText': quantityText,
      if (unit != null) 'unit': unit,
      if (category != null) 'category': category,
    };
    if (body.isEmpty) {
      throw const CaleeHubException(
        statusCode: 0,
        message: 'No ingredient updates provided',
      );
    }
    final json = await _patchJson(
      '/client/v1/meal-templates/$templateId/ingredients/$ingredientId',
      accessToken: accessToken,
      body: body,
    );
    return ClientTemplateIngredient.fromJson(
      _data(json)['ingredient'] as Map<String, dynamic>,
    );
  }

  Future<void> deleteMealTemplateIngredient({
    required String accessToken,
    required int templateId,
    required int ingredientId,
  }) async {
    await _deleteJson(
      '/client/v1/meal-templates/$templateId/ingredients/$ingredientId',
      accessToken: accessToken,
    );
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

  // ── Calendar event attachments ──────────────────────────────────────────────────────────────────

  Future<List<CalendarAttachment>> listAttachments({
    required String accessToken,
    required String eventId,
  }) async {
    final encodedEventId = Uri.encodeComponent(eventId);
    final json = await _getJson(
      '/client/v1/events/$encodedEventId/attachments',
      accessToken: accessToken,
    );

    final attachments = _data(json)['attachments'];
    if (attachments is! List) return const [];
    return attachments
        .whereType<Map<String, dynamic>>()
        .map(CalendarAttachment.fromJson)
        .toList();
  }

  /// Uploads [file] as an attachment on [eventId].
  ///
  /// [originalFilename] is the name the USER knows the document by -- the
  /// one the platform picker displayed (`FilePicker`'s `name`,
  /// `XFile.name`) -- and is what Hub records. It is deliberately separate
  /// from [file], whose path is frequently a cache/temp location with a
  /// generated basename (`image_picker` copies into the app cache, Android
  /// content URIs resolve to opaque names), so deriving the wire filename
  /// from the path would attach documents under names the user never chose
  /// and would leak local cache path structure. Hub re-sanitizes whatever
  /// it receives and remains authoritative.
  Future<CalendarAttachment> uploadAttachment({
    required String accessToken,
    required String eventId,
    required File file,
    required String originalFilename,
    required String idempotencyKey,
    void Function(int sent, int total)? onProgress,
    AttachmentTransferCancelToken? cancelToken,
  }) async {
    final encodedEventId = Uri.encodeComponent(eventId);
    final path = '/client/v1/events/$encodedEventId/attachments';

    final raw = await _withRetry(
      (token) => _doUploadAttachment(
        path,
        accessToken: token,
        file: file,
        originalFilename: originalFilename,
        idempotencyKey: idempotencyKey,
        onProgress: onProgress,
        cancelToken: cancelToken,
      ),
      accessToken,
    );

    return CalendarAttachment.fromJson(
      _data(raw)['attachment'] as Map<String, dynamic>,
    );
  }

  /// Splits a raw filename into a wire-safe multipart `Content-Disposition`
  /// pair: [ascii] always uses the plain `filename="..."` parameter (CR/LF/
  /// NUL stripped, quotes and backslashes escaped, non-ASCII bytes replaced
  /// with `_` so the quoted-string stays valid on any receiving parser), and
  /// [utf8Star] -- present only when [ascii] had to drop non-ASCII
  /// characters -- carries the original name losslessly via the RFC 5987
  /// `filename*=UTF-8''...` form, mirroring how the Hub backend already
  /// emits `Content-Disposition` for downloads
  /// (`client_api_attachment_content_disposition()`). This only affects the
  /// wire encoding of the upload request; the user-visible filename
  /// elsewhere in the app is never altered.
  static ({String ascii, String? utf8Star}) _sanitizeMultipartFilename(
    String rawFilename,
  ) {
    final noControlChars = rawFilename.replaceAll(RegExp(r'[\r\n\x00]'), '');
    final base = noControlChars.trim().isEmpty ? 'attachment' : noControlChars;

    final asciiBuffer = StringBuffer();
    var isPureAscii = true;
    for (final rune in base.runes) {
      if (rune == 0x5c || rune == 0x22) {
        // Backslash or double-quote: escape so the quoted-string stays valid.
        asciiBuffer.write('\\');
        asciiBuffer.writeCharCode(rune);
      } else if (rune >= 0x20 && rune <= 0x7e) {
        asciiBuffer.writeCharCode(rune);
      } else {
        isPureAscii = false;
        asciiBuffer.write('_');
      }
    }
    var ascii = asciiBuffer.toString();
    if (ascii.trim().isEmpty) ascii = 'attachment';

    final utf8Star = isPureAscii ? null : Uri.encodeComponent(base);
    return (ascii: ascii, utf8Star: utf8Star);
  }

  Future<Map<String, dynamic>> _doUploadAttachment(
    String path, {
    required String accessToken,
    required File file,
    required String originalFilename,
    required String idempotencyKey,
    void Function(int sent, int total)? onProgress,
    AttachmentTransferCancelToken? cancelToken,
  }) {
    return _executeAttachmentTransferRequest((handle) async {
      try {
        final boundary =
            'CaleeBoundary${DateTime.now().millisecondsSinceEpoch}';
        final request = await _httpClient.postUrl(baseUri.resolve(path));
        request.headers.set(HttpHeaders.acceptHeader, 'application/json');
        request.headers.set(
          HttpHeaders.authorizationHeader,
          'Bearer $accessToken',
        );
        // A client-supplied idempotency key, scoped by Hub to
        // account+event+upload-request: a retried upload with the same key
        // returns the original attachment instead of creating a duplicate.
        request.headers.set('Idempotency-Key', idempotencyKey);
        request.headers.contentType = ContentType(
          'multipart',
          'form-data',
          parameters: {'boundary': boundary},
        );

        // Aborting the request genuinely tears down the connection (Hub
        // never sees a complete body, so no partial upload can be misread
        // as success) as long as this fires before the response has
        // arrived -- true for the entire body-writing phase below.
        const cancelException = CaleeHubException(
          statusCode: 0,
          code: 'CANCELLED',
          message: 'Upload cancelled.',
        );
        // A mid-body abort tears down the socket before the declared
        // Content-Length has actually been written, which dart:io flags
        // internally on request.done -- a Future our own code never awaits
        // on this path (we throw directly below instead). Left unlistened,
        // that would surface as a stray unhandled async error alongside
        // the real one. .ignore() marks it observed without affecting the
        // independent await request.close() below.
        request.done.ignore();

        // Both user cancellation AND the transfer timeout tear the request
        // down the same way; only the surfaced code differs.
        cancelToken?.attachAbort(() => request.abort(cancelException));
        handle.armAbort((reason) => request.abort(reason));

        if (cancelToken?.isCancelled ?? false) {
          // Already cancelled before we wrote anything: bail out now so the
          // file is never opened and no bytes reach the wire.
          throw cancelException;
        }

        final sanitizedFilename = _sanitizeMultipartFilename(originalFilename);
        final dispositionBuffer = StringBuffer(
          'Content-Disposition: form-data; name="file"; '
          'filename="${sanitizedFilename.ascii}"',
        );
        if (sanitizedFilename.utf8Star != null) {
          dispositionBuffer.write(
            "; filename*=UTF-8''${sanitizedFilename.utf8Star}",
          );
        }
        dispositionBuffer.write('\r\n');

        final head = BytesBuilder()
          ..add(utf8.encode('--$boundary\r\n'))
          ..add(utf8.encode(dispositionBuffer.toString()))
          ..add(utf8.encode('Content-Type: application/octet-stream\r\n\r\n'));
        final headBytes = head.toBytes();
        final tailBytes = utf8.encode('\r\n--$boundary--\r\n');
        final fileSize = await file.length();
        final totalBytes = headBytes.length + fileSize + tailBytes.length;
        request.contentLength = totalBytes;

        request.add(headBytes);
        var sent = headBytes.length;
        onProgress?.call(sent, totalBytes);

        // Streamed straight from disk (never file.readAsBytes()) so the
        // peak memory used for an upload stays proportional to a chunk, not
        // to the whole attachment.
        await for (final chunk in file.openRead()) {
          if (cancelToken?.isCancelled ?? false) {
            throw cancelException;
          }
          request.add(chunk);
          sent += chunk.length;
          onProgress?.call(sent, totalBytes);
        }

        if (cancelToken?.isCancelled ?? false) {
          throw cancelException;
        }
        request.add(tailBytes);
        sent += tailBytes.length;
        onProgress?.call(sent, totalBytes);

        final response = await request.close();
        cancelToken?.detach();
        return _readJsonResponse(response, endpoint: path);
      } finally {
        handle.markFinished();
      }
    });
  }

  /// Downloads an attachment's bytes to [destinationFile] (caller-chosen --
  /// see the Attachments feature's controller for how a safe application
  /// cache path is built). Streams the response directly to disk, never
  /// buffering the whole file in memory. Deletes [destinationFile] if it
  /// exists partially written after a failure or cancellation.
  Future<void> downloadAttachment({
    required String accessToken,
    required String eventId,
    required String attachmentId,
    required File destinationFile,
    void Function(int received, int? total)? onProgress,
    AttachmentTransferCancelToken? cancelToken,
  }) async {
    final encodedEventId = Uri.encodeComponent(eventId);
    final encodedAttachmentId = Uri.encodeComponent(attachmentId);
    final path =
        '/client/v1/events/$encodedEventId/attachments/$encodedAttachmentId/content';

    try {
      await _withRetryGeneric<void>(
        (token) => _doDownloadAttachment(
          path,
          accessToken: token,
          destinationFile: destinationFile,
          onProgress: onProgress,
          cancelToken: cancelToken,
        ),
        accessToken,
      );
    } catch (_) {
      if (await destinationFile.exists()) {
        await destinationFile.delete();
      }
      rethrow;
    }
  }

  Future<void> _doDownloadAttachment(
    String path, {
    required String accessToken,
    required File destinationFile,
    void Function(int received, int? total)? onProgress,
    AttachmentTransferCancelToken? cancelToken,
  }) {
    return _executeAttachmentTransferRequest((handle) async {
      try {
        const cancelException = CaleeHubException(
          statusCode: 0,
          code: 'CANCELLED',
          message: 'Download cancelled.',
        );

        final request = await _httpClient.getUrl(baseUri.resolve(path));
        request.headers.set(HttpHeaders.acceptHeader, '*/*');
        request.headers.set(
          HttpHeaders.authorizationHeader,
          'Bearer $accessToken',
        );

        // Covers cancellation up until the response arrives; abort()
        // becomes a no-op after that, so the body-streaming phase below
        // re-arms both the cancel token and the timeout handle against the
        // response subscription instead.
        cancelToken?.attachAbort(() => request.abort(cancelException));
        handle.armAbort((reason) => request.abort(reason));

        final response = await request.close();

        if (response.statusCode < 200 || response.statusCode >= 300) {
          cancelToken?.detach();
          // Error responses use the same JSON envelope as every other Hub
          // error -- _readJsonResponse always throws for a non-2xx status.
          await _readJsonResponse(response, endpoint: path);
          return;
        }

        final total = response.contentLength >= 0
            ? response.contentLength
            : null;
        var received = 0;

        final sink = destinationFile.openWrite();
        final bodyCompleter = Completer<void>();
        StreamSubscription<List<int>>? subscription;
        subscription = response.listen(
          (chunk) {
            sink.add(chunk);
            received += chunk.length;
            onProgress?.call(received, total);
          },
          onDone: () {
            if (!bodyCompleter.isCompleted) bodyCompleter.complete();
          },
          onError: (Object error, StackTrace stackTrace) {
            if (!bodyCompleter.isCompleted) {
              bodyCompleter.completeError(error, stackTrace);
            }
          },
          cancelOnError: true,
        );

        // Cancelling a StreamSubscription silently stops further events --
        // it never completes onDone/onError on its own -- so the abort
        // callbacks must also fail the completer to unblock the await
        // below.
        cancelToken?.attachAbort(() {
          subscription?.cancel();
          if (!bodyCompleter.isCompleted) {
            bodyCompleter.completeError(cancelException);
          }
        });
        handle.armAbort((reason) {
          subscription?.cancel();
          if (!bodyCompleter.isCompleted) {
            bodyCompleter.completeError(reason);
          }
        });

        try {
          await bodyCompleter.future;
          await sink.flush();
        } finally {
          cancelToken?.detach();
          await sink.close();
        }

        // Part E: Hub cannot retract a response it has already committed,
        // so a truncated upstream download arrives here as a SHORT BODY
        // under an otherwise-successful 200. Trusting it would hand the
        // user a silently corrupt file to open or share. Compare what
        // actually arrived against the length Hub declared, and treat any
        // disagreement -- short OR long -- as a failed download. The
        // caller (downloadAttachment) deletes the partial file.
        if (total != null && received != total) {
          throw const CaleeHubException(
            statusCode: 0,
            code: 'ATTACHMENT_DOWNLOAD_FAILED',
            message:
                'This attachment did not download completely. '
                'Please try again.',
          );
        }
      } finally {
        handle.markFinished();
      }
    });
  }

  Future<List<CalendarAttachment>> detachAttachment({
    required String accessToken,
    required String eventId,
    required String attachmentId,
  }) async {
    final encodedEventId = Uri.encodeComponent(eventId);
    final encodedAttachmentId = Uri.encodeComponent(attachmentId);
    final json = await _deleteJson(
      '/client/v1/events/$encodedEventId/attachments/$encodedAttachmentId',
      accessToken: accessToken,
    );

    final attachments = _data(json)['attachments'];
    if (attachments is! List) return const [];
    return attachments
        .whereType<Map<String, dynamic>>()
        .map(CalendarAttachment.fromJson)
        .toList();
  }

  // _withRetry above is JSON-response-specific (Future<Map<String, dynamic>>);
  // this is the same 401-refresh-and-retry-once logic generalized over any
  // return type, needed for downloadAttachment()'s void/file-streaming
  // result. Intentionally not used to reimplement _withRetry itself, to
  // avoid touching the well-tested existing JSON path for an unrelated
  // feature.
  Future<T> _withRetryGeneric<T>(
    Future<T> Function(String token) doRequest,
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

  /// Runs an attachment transfer under the shared timeout, with the ability
  /// to ACTIVELY abort the underlying HTTP work when that timeout fires
  /// (Part F). `Future.timeout()` alone only stops the caller waiting -- the
  /// request or response stream keeps running, so bytes could still be
  /// flowing (and a destination file still being written) long after the
  /// caller was told `TIMEOUT`.
  ///
  /// [fn] receives a handle it must arm with its own teardown callback and
  /// mark finished when it unwinds; on timeout this aborts the transfer and
  /// then waits (briefly, bounded) for that unwind to actually complete, so
  /// sinks are closed and partial files removed before `TIMEOUT` surfaces.
  Future<T> _executeAttachmentTransferRequest<T>(
    Future<T> Function(_AttachmentTransferHandle handle) fn,
  ) async {
    final handle = _AttachmentTransferHandle();
    const timeoutException = CaleeHubException(
      statusCode: 0,
      code: 'TIMEOUT',
      message: 'Check your connection and try again.',
    );

    try {
      return await fn(handle).timeout(
        _kAttachmentTransferTimeout,
        onTimeout: () async {
          handle.abort(timeoutException);
          // Bounded: a wedged teardown must not turn a timeout into a hang.
          await handle.finished
              .timeout(_kAttachmentTeardownGrace)
              .catchError((Object _) {});
          throw timeoutException;
        },
      );
    } on CaleeHubException {
      rethrow;
    } on TimeoutException {
      // A timeout raised from inside the transfer body rather than by the
      // wrapper above -- tear down on the same path.
      handle.abort(timeoutException);
      await handle.finished
          .timeout(_kAttachmentTeardownGrace)
          .catchError((Object _) {});
      throw timeoutException;
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
    } on HttpException {
      // dart:io raises this when a body ends before its declared
      // Content-Length ("Connection closed while receiving data") -- i.e.
      // a truncated transfer, which is the failure Part E is about. It must
      // surface as a typed, actionable failure rather than a raw dart:io
      // exception escaping the client layer.
      throw const CaleeHubException(
        statusCode: 0,
        code: 'ATTACHMENT_DOWNLOAD_FAILED',
        message:
            'This attachment did not transfer completely. Please try again.',
      );
    } finally {
      handle.disarm();
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

  Future<ClientPreferences> preferences({required String accessToken}) async {
    final json = await _getJson(
      '/client/v1/preferences',
      accessToken: accessToken,
    );
    final data = _data(json);
    final preferencesJson = data['preferences'];
    if (preferencesJson is! Map<String, dynamic>) {
      throw const CaleeHubException(
        statusCode: 0,
        message: 'Could not load your preferences. Please try again.',
      );
    }
    return ClientPreferences.fromJson(preferencesJson);
  }

  Future<ClientPreferences> updatePreferences({
    required String accessToken,
    FirstDayOfWeek? firstDayOfWeek,
    TimeFormatPref? timeFormat,
    String? defaultCalendarId,
    bool clearDefaultCalendarId = false,
    String? defaultTaskListId,
    bool clearDefaultTaskListId = false,
  }) async {
    final body = <String, dynamic>{
      if (firstDayOfWeek != null) 'firstDayOfWeek': firstDayOfWeek.storageValue,
      if (timeFormat != null) 'timeFormat': timeFormat.storageValue,
      if (clearDefaultCalendarId)
        'defaultCalendarId': null
      else if (defaultCalendarId != null)
        'defaultCalendarId': defaultCalendarId,
      if (clearDefaultTaskListId)
        'defaultTaskListId': null
      else if (defaultTaskListId != null)
        'defaultTaskListId': defaultTaskListId,
    };

    if (body.isEmpty) {
      throw const CaleeHubException(
        statusCode: 0,
        message: 'No preference updates provided',
      );
    }

    final json = await _patchJson(
      '/client/v1/preferences',
      accessToken: accessToken,
      body: body,
    );
    final data = _data(json);
    final preferencesJson = data['preferences'];
    if (preferencesJson is! Map<String, dynamic>) {
      throw const CaleeHubException(
        statusCode: 0,
        message: 'Could not load your preferences. Please try again.',
      );
    }
    return ClientPreferences.fromJson(preferencesJson);
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

/// Internal plumbing letting the transfer timeout reach the in-flight HTTP
/// operation (Part F). The transfer body arms [armAbort] with whatever
/// teardown is correct for its current phase -- `HttpClientRequest.abort()`
/// before a response exists, `StreamSubscription.cancel()` once a download
/// body is streaming -- and calls [markFinished] from a `finally` once it
/// has fully unwound.
class _AttachmentTransferHandle {
  void Function(Object reason)? _onAbort;
  final Completer<void> _finished = Completer<void>();

  void armAbort(void Function(Object reason) onAbort) {
    _onAbort = onAbort;
  }

  void disarm() {
    _onAbort = null;
  }

  void abort(Object reason) {
    _onAbort?.call(reason);
  }

  /// Completes once the transfer body has finished unwinding.
  Future<void> get finished => _finished.future;

  void markFinished() {
    if (!_finished.isCompleted) _finished.complete();
  }
}

/// User-cancellation signal for
/// [CaleeHubClient.uploadAttachment]/[CaleeHubClient.downloadAttachment].
/// Cancelling genuinely tears down the in-flight transfer: whatever abort
/// callback is currently attached (via [attachAbort]) runs synchronously,
/// invoking `HttpClientRequest.abort()` and/or `StreamSubscription.cancel()`
/// depending on which phase the transfer is in. One token is good for one
/// transfer; create a new one for each upload/download.
class AttachmentTransferCancelToken {
  bool _cancelled = false;
  void Function()? _onCancel;

  bool get isCancelled => _cancelled;

  /// Cancels the transfer. If an abort callback is attached, it runs
  /// immediately; otherwise the cancellation is recorded and the next
  /// [attachAbort] call fires straight away, so a cancel requested before
  /// the request/subscription exists yet is never lost.
  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    _onCancel?.call();
  }

  /// Registers the callback that actually aborts the current phase of the
  /// transfer (request abort before a response arrives; stream-subscription
  /// cancel while a download body is being read). Replaces any previously
  /// attached callback -- callers re-attach when the transfer moves into a
  /// new phase. If the token was already cancelled, fires immediately.
  void attachAbort(void Function() onCancel) {
    _onCancel = onCancel;
    if (_cancelled) {
      onCancel();
    }
  }

  /// Detaches the current abort callback without cancelling. Call this once
  /// a phase completes (e.g. the request finished writing and a response
  /// arrived) so a later [cancel] doesn't invoke a stale callback.
  void detach() {
    _onCancel = null;
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
