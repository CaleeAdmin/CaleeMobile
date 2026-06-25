import '../../data/api/calee_hub_client.dart';
import '../../data/models/calendar_service_error.dart';
import '../../data/models/client_bootstrap.dart';
import '../../data/models/client_calendar.dart';
import '../../data/models/client_chore.dart';
import '../../data/models/client_chore_metadata.dart';
import '../../data/models/client_person.dart';

// ─────────────────────────────────────────────
// Public data model
// ─────────────────────────────────────────────

class ChoresOverview {
  const ChoresOverview({
    required this.calendarList,
    required this.choreList,
    required this.people,
    required this.from,
    required this.to,
    this.calendarServiceErrors = const [],
  });

  final ClientCalendarList calendarList;
  final ClientChoreList choreList;
  final List<ClientPerson> people;
  final String from;
  final String to;
  final List<CalendarServiceError> calendarServiceErrors;
}

// ─────────────────────────────────────────────
// Repository
// ─────────────────────────────────────────────

class ChoresRepository {
  ChoresRepository({
    required this.hubClient,
    required this.accessToken,
    required this.services,
    required this.households,
  });

  final CaleeHubClient hubClient;
  final String accessToken;
  final List<ClientService> services;
  final List<ClientContext> households;

  List<ClientService> get choreServices =>
      services.where((s) => s.supportsChores).toList();

  ClientContext? get primaryHousehold {
    for (final household in households) {
      if (household.type == 'household' && household.status == 'active') {
        return household;
      }
    }
    return households.isNotEmpty ? households.first : null;
  }

  Future<ChoresOverview> loadOverview({
    required String from,
    required String to,
  }) async {
    ClientCalendarList calList = const ClientCalendarList(calendars: []);
    final calendarServiceErrors = <CalendarServiceError>[];

    try {
      calList = await hubClient.calendars(accessToken: accessToken);
      calendarServiceErrors.addAll(calList.serviceErrors);
    } on CaleeHubException catch (e) {
      if (isCalendarServiceConnectionCode(e.code)) {
        calendarServiceErrors.add(CalendarServiceError.fromException(e));
      } else {
        rethrow;
      }
    }

    final choreList = await hubClient.chores(
      accessToken: accessToken,
      from: from,
      to: to,
    );

    final household = primaryHousehold;
    var people = <ClientPerson>[];

    if (household != null) {
      try {
        final peopleList = await hubClient.people(
          accessToken: accessToken,
          householdId: household.id,
        );
        people = peopleList.people.where((p) => p.isActive).toList();
      } catch (_) {
        people = <ClientPerson>[];
      }
    }

    return ChoresOverview(
      calendarList: calList,
      choreList: choreList,
      people: people,
      from: from,
      to: to,
      calendarServiceErrors: calendarServiceErrors,
    );
  }

  String _rawCalendarId(ClientCalendar calendar) {
    final prefix = '${calendar.serviceId}:';
    if (calendar.id.startsWith(prefix)) {
      return calendar.id.substring(prefix.length);
    }
    return calendar.id;
  }

  Future<void> createChore({
    required ClientCalendar calendar,
    required String title,
    String? scheduledAt,
    String? description,
    String? recurrence,
    required List<String> assigneePersonIds,
    required int points,
  }) async {
    final seen = <String>{};
    final deduped = assigneePersonIds
        .map((id) => id.trim())
        .where((id) => id.isNotEmpty && seen.add(id))
        .toList();

    if (deduped.isEmpty) {
      await _createSingleChore(
        calendar: calendar,
        title: title,
        scheduledAt: scheduledAt,
        description: description,
        recurrence: recurrence,
        assigneePersonId: null,
        points: points,
      );
    } else {
      for (final personId in deduped) {
        await _createSingleChore(
          calendar: calendar,
          title: title,
          scheduledAt: scheduledAt,
          description: description,
          recurrence: recurrence,
          assigneePersonId: personId,
          points: points,
        );
      }
    }
  }

  Future<void> _createSingleChore({
    required ClientCalendar calendar,
    required String title,
    String? scheduledAt,
    String? description,
    String? recurrence,
    required String? assigneePersonId,
    required int points,
  }) async {
    final household = primaryHousehold;
    final calendarId = _rawCalendarId(calendar);
    ClientChore createdChore;
    bool atomicSucceeded = false;

    try {
      createdChore = await hubClient.createChore(
        accessToken: accessToken,
        serviceId: calendar.serviceId,
        calendarId: calendarId,
        title: title,
        scheduledAt: scheduledAt,
        description: description,
        recurrence: recurrence,
        points: 1,
        householdId: household?.id,
        assigneePersonId: assigneePersonId ?? '',
        metadataPoints: points,
        approvalState: 'none',
      );
      atomicSucceeded = true;
    } on CaleeHubException catch (e) {
      if (e.statusCode != 400) rethrow;
      // Backend does not yet support atomic metadata fields — fall back to two-step.
      createdChore = await hubClient.createChore(
        accessToken: accessToken,
        serviceId: calendar.serviceId,
        calendarId: calendarId,
        title: title,
        scheduledAt: scheduledAt,
        description: description,
        recurrence: recurrence,
        points: 1,
      );
    }

    if (!atomicSucceeded) {
      final choreUid = createdChore.choreUid?.trim();
      if (household != null && choreUid != null && choreUid.isNotEmpty) {
        await hubClient.updateChoreMetadata(
          accessToken: accessToken,
          householdId: household.id,
          choreUid: choreUid,
          assigneePersonId: assigneePersonId ?? '',
          points: points,
          approvalState: 'none',
        );
      }
    }
  }

  Future<void> updateChore({
    required ClientChore chore,
    required String title,
    String? scheduledAt,
    String? description,
    String? recurrence,
    required String? assigneePersonId,
    required int points,
    required String approvalState,
  }) async {
    final choreId = chore.completionActionId;

    if (choreId.trim().isEmpty) {
      throw StateError('Missing chore id');
    }

    final household = primaryHousehold;
    final choreUid = chore.choreUid?.trim();
    bool atomicSucceeded = false;

    try {
      await hubClient.updateChore(
        accessToken: accessToken,
        choreId: choreId,
        title: title,
        scheduledAt: scheduledAt,
        description: description,
        recurrence: recurrence,
        householdId: household?.id,
        choreUid: choreUid,
        assigneePersonId: assigneePersonId ?? '',
        metadataPoints: points,
        approvalState: approvalState,
      );
      atomicSucceeded = true;
    } on CaleeHubException catch (e) {
      if (e.statusCode != 400) rethrow;
      // Backend does not yet support atomic metadata fields — fall back to two-step.
      await hubClient.updateChore(
        accessToken: accessToken,
        choreId: choreId,
        title: title,
        scheduledAt: scheduledAt,
        description: description,
        recurrence: recurrence,
      );
    }

    if (!atomicSucceeded) {
      if (household != null && choreUid != null && choreUid.isNotEmpty) {
        await hubClient.updateChoreMetadata(
          accessToken: accessToken,
          householdId: household.id,
          choreUid: choreUid,
          assigneePersonId: assigneePersonId ?? '',
          points: points,
          approvalState: approvalState,
        );
      }
    }
  }

  Future<void> completeChore(ClientChore chore) async {
    final choreId = chore.completionActionId;
    if (choreId.trim().isEmpty) throw StateError('Missing chore id');
    await hubClient.completeChore(accessToken: accessToken, choreId: choreId);
  }

  Future<void> undoCompletion(ClientChore chore) async {
    final choreId = chore.completionActionId;
    if (choreId.trim().isEmpty) throw StateError('Missing chore id');
    await hubClient.undoChoreCompletion(
      accessToken: accessToken,
      choreId: choreId,
    );
  }

  Future<void> deleteChore(ClientChore chore) async {
    final choreId = chore.completionActionId;
    if (choreId.trim().isEmpty) throw StateError('Missing chore id');
    await hubClient.deleteChore(
      accessToken: accessToken,
      choreId: choreId,
      action: 'deletePermanent',
    );
  }

  Future<void> skipRecurringChore(ClientChore chore, {String? date}) async {
    final choreId = chore.completionActionId;
    if (choreId.trim().isEmpty) throw StateError('Missing chore id');
    await hubClient.deleteChore(
      accessToken: accessToken,
      choreId: choreId,
      action: 'skip',
      date: date,
    );
  }

  Future<void> stopRepeatingChore(ClientChore chore) async {
    final choreId = chore.completionActionId;
    if (choreId.trim().isEmpty) throw StateError('Missing chore id');
    await hubClient.deleteChore(
      accessToken: accessToken,
      choreId: choreId,
      action: 'stopRepeating',
    );
  }

  Future<void> permanentlyDeleteChore(ClientChore chore) async {
    await deleteChore(chore);
  }

  Future<ClientChoreMetadata?> fetchMetadata(ClientChore chore) async {
    final household = primaryHousehold;
    final choreUid = chore.choreUid?.trim();

    if (household == null || choreUid == null || choreUid.isEmpty) {
      return null;
    }

    try {
      return await hubClient.choreMetadata(
        accessToken: accessToken,
        householdId: household.id,
        choreUid: choreUid,
      );
    } catch (_) {
      return null;
    }
  }

  Future<List<ClientPerson>> fetchPeople() async {
    final household = primaryHousehold;
    if (household == null) return [];

    try {
      final peopleList = await hubClient.people(
        accessToken: accessToken,
        householdId: household.id,
      );
      return peopleList.people.where((p) => p.isActive).toList();
    } catch (_) {
      return [];
    }
  }
}
