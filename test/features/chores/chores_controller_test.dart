import 'package:calee_mobile/data/api/calee_hub_client.dart';
import 'package:calee_mobile/data/models/client_bootstrap.dart';
import 'package:calee_mobile/data/models/client_calendar.dart';
import 'package:calee_mobile/data/models/client_chore.dart';
import 'package:calee_mobile/data/models/client_chore_metadata.dart';
import 'package:calee_mobile/data/models/client_person.dart';
import 'package:calee_mobile/features/chores/chores_controller.dart';
import 'package:calee_mobile/features/chores/chores_repository.dart';
import 'package:flutter_test/flutter_test.dart';

// ── Minimal stubs ─────────────────────────────────────────────────────────────

String _isoDate(DateTime value) => value.toIso8601String().split('T').first;

ClientChoreList _emptyChoreList() =>
    ClientChoreList(from: '2026-01-01', to: '2026-12-31', chores: []);

ClientCalendarList _emptyCalendarList() => ClientCalendarList(calendars: []);

ClientPersonList _emptyPeopleList() => ClientPersonList(people: []);

// A CaleeHubClient that always throws so we can test error state.
class _AlwaysFailHubClient extends CaleeHubClient {
  @override
  Future<ClientCalendarList> calendars({required String accessToken}) =>
      Future.error(Exception('network error'));

  @override
  Future<ClientChoreList> chores({
    required String accessToken,
    required String from,
    required String to,
  }) => Future.error(Exception('network error'));
}

// Helpers for repository mutation tests.
ClientCalendar _calendar(String id) => ClientCalendar(
  id: id,
  serviceId: 'portal',
  serviceName: 'Portal',
  name: 'Chores',
  components: const ['VTODO'],
  primaryKind: 'chores',
  supportsEvents: false,
  supportsTasks: false,
  supportsChores: true,
  readOnly: false,
  isSubscription: false,
  source: '',
);

ClientContext _household() => const ClientContext(
  id: 'household-1',
  type: 'household',
  name: 'Household',
  role: 'admin',
  status: 'active',
);

ClientChore _chore({
  String id = 'chore-1',
  String? choreUid = 'uid-1',
  String? occurrenceDate,
  String section = 'todoToday',
  bool completedToday = false,
}) => ClientChore(
  id: id,
  calendarId: 'cal-1',
  serviceId: 'portal',
  serviceName: 'Portal',
  title: 'Chore',
  scheduledAt: null,
  scheduledDate: null,
  description: null,
  source: '',
  kind: 'baseChore',
  choreUid: choreUid,
  parentChoreUid: null,
  baseChoreId: null,
  occurrenceDate: occurrenceDate,
  completionLogId: null,
  completedToday: completedToday,
  section: section,
  recurrence: null,
  points: 1,
  metadataPoints: null,
  assigneePersonId: null,
  assigneeName: null,
  assigneeAvatarColor: null,
  approvalState: 'none',
);

class _CreateTrackingHubClient extends CaleeHubClient {
  _CreateTrackingHubClient({this.failAtomicCreate = false});

  final bool failAtomicCreate;
  final createCalls = <Map<String, Object?>>[];
  final metadataCalls = <Map<String, Object?>>[];

  @override
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
    createCalls.add({
      'serviceId': serviceId,
      'calendarId': calendarId,
      'assigneePersonId': assigneePersonId,
      'householdId': householdId,
      'metadataPoints': metadataPoints,
      'approvalState': approvalState,
    });

    if (failAtomicCreate && createCalls.length == 1) {
      throw const CaleeHubException(statusCode: 400, message: 'unsupported');
    }

    return _chore();
  }

  @override
  Future<ClientChoreMetadata> updateChoreMetadata({
    required String accessToken,
    required String householdId,
    required String choreUid,
    String? assigneePersonId,
    int? points,
    String? approvalState,
  }) async {
    metadataCalls.add({
      'householdId': householdId,
      'choreUid': choreUid,
      'assigneePersonId': assigneePersonId,
      'points': points,
      'approvalState': approvalState,
    });
    return ClientChoreMetadata(
      id: null,
      householdId: householdId,
      choreUid: choreUid,
      assigneePersonId: assigneePersonId,
      points: points ?? 1,
      approvalState: approvalState ?? 'none',
      createdAt: null,
      updatedAt: null,
    );
  }
}

class _UpdateTrackingHubClient extends CaleeHubClient {
  _UpdateTrackingHubClient({this.failAtomicUpdate = false});

  final bool failAtomicUpdate;
  final updateCalls = <Map<String, Object?>>[];
  final metadataCalls = <Map<String, Object?>>[];

  @override
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
    updateCalls.add({
      'choreId': choreId,
      'assigneePersonId': assigneePersonId,
      'householdId': householdId,
      'choreUid': choreUid,
      'metadataPoints': metadataPoints,
      'approvalState': approvalState,
    });

    if (failAtomicUpdate && updateCalls.length == 1) {
      throw const CaleeHubException(statusCode: 400, message: 'unsupported');
    }

    return _chore(id: choreId);
  }

  @override
  Future<ClientChoreMetadata> updateChoreMetadata({
    required String accessToken,
    required String householdId,
    required String choreUid,
    String? assigneePersonId,
    int? points,
    String? approvalState,
  }) async {
    metadataCalls.add({
      'householdId': householdId,
      'choreUid': choreUid,
      'assigneePersonId': assigneePersonId,
      'points': points,
      'approvalState': approvalState,
    });
    return ClientChoreMetadata(
      id: null,
      householdId: householdId,
      choreUid: choreUid,
      assigneePersonId: assigneePersonId,
      points: points ?? 1,
      approvalState: approvalState ?? 'none',
      createdAt: null,
      updatedAt: null,
    );
  }
}

class _CompletionTrackingHubClient extends CaleeHubClient {
  final completeCalls = <String>[];
  final undoCalls = <String>[];

  @override
  Future<void> completeChore({
    required String accessToken,
    required String choreId,
    String? date,
  }) async {
    completeCalls.add(date ?? '');
  }

  @override
  Future<void> undoChoreCompletion({
    required String accessToken,
    required String choreId,
    String? date,
  }) async {
    undoCalls.add(date ?? '');
  }

  @override
  Future<ClientCalendarList> calendars({required String accessToken}) =>
      Future.value(_emptyCalendarList());

  @override
  Future<ClientChoreList> chores({
    required String accessToken,
    required String from,
    required String to,
  }) => Future.value(_emptyChoreList());
}

// A CaleeHubClient that always succeeds with empty data.
class _SuccessHubClient extends CaleeHubClient {
  @override
  Future<ClientCalendarList> calendars({required String accessToken}) =>
      Future.value(_emptyCalendarList());

  @override
  Future<ClientChoreList> chores({
    required String accessToken,
    required String from,
    required String to,
  }) => Future.value(_emptyChoreList());

  @override
  Future<ClientPersonList> people({
    required String accessToken,
    required String householdId,
    bool includeArchived = false,
  }) => Future.value(_emptyPeopleList());
}

// ── Helpers ───────────────────────────────────────────────────────────────────

ChoresRepository _repositoryWith(CaleeHubClient client) => ChoresRepository(
  hubClient: client,
  accessToken: 'token',
  services: [],
  households: [],
);

ChoresRepository _repositoryWithHousehold(CaleeHubClient client) =>
    ChoresRepository(
      hubClient: client,
      accessToken: 'token',
      services: const [],
      households: [_household()],
    );

// ── Tests ─────────────────────────────────────────────────────────────────────

void main() {
  group('ChoresRepository.choreServices', () {
    test('returns only services where supportsChores is true', () {
      ClientService svc(String id, Map<String, dynamic> caps) => ClientService(
        id: id,
        displayName: id,
        baseUrl: '',
        launchUrl: '',
        serviceType: '',
        accessStatus: 'active',
        calendarCredentialStatus: 'unsupported',
        source: '',
        capabilities: caps,
      );

      final services = [
        svc('svc-chores', {'chores': true}),
        svc('svc-tasks', {'tasks': true}),
        svc('svc-both', {'chores': true, 'tasks': true}),
      ];

      final repo = ChoresRepository(
        hubClient: _SuccessHubClient(),
        accessToken: 'token',
        services: services,
        households: [],
      );

      final ids = repo.choreServices.map((s) => s.id).toList();
      expect(ids, containsAll(['svc-chores', 'svc-both']));
      expect(ids, isNot(contains('svc-tasks')));
    });
  });

  group('ChoresController loading state', () {
    test('sets isLoading true then false on success', () async {
      final controller = ChoresController(
        repository: _repositoryWith(_SuccessHubClient()),
      );

      final states = <bool>[];
      controller.addListener(() => states.add(controller.isLoading));

      await controller.load();

      expect(states.first, isTrue);
      expect(states.last, isFalse);
      expect(controller.error, isNull);
      expect(controller.overview, isNotNull);

      controller.dispose();
    });

    test('sets error and clears overview on failure', () async {
      final controller = ChoresController(
        repository: _repositoryWith(_AlwaysFailHubClient()),
      );

      await controller.load();

      expect(controller.isLoading, isFalse);
      expect(controller.error, isNotNull);
      expect(controller.overview, isNull);

      controller.dispose();
    });
  });

  group('ChoresRepository createChore', () {
    test('strips service-prefixed calendar id before create POST', () async {
      final client = _CreateTrackingHubClient();
      final repo = _repositoryWithHousehold(client);

      await repo.createChore(
        calendar: _calendar('portal:cal-1'),
        title: 'Chore',
        assigneePersonIds: ['person-1'],
        points: 3,
      );

      expect(client.createCalls.single['serviceId'], 'portal');
      expect(client.createCalls.single['calendarId'], 'cal-1');
    });

    test('keeps raw calendar id raw before create POST', () async {
      final client = _CreateTrackingHubClient();
      final repo = _repositoryWithHousehold(client);

      await repo.createChore(
        calendar: _calendar('cal-1'),
        title: 'Chore',
        assigneePersonIds: ['person-1'],
        points: 3,
      );

      expect(client.createCalls.single['calendarId'], 'cal-1');
    });

    test('unassigned atomic create sends empty assignee string', () async {
      final client = _CreateTrackingHubClient();
      final repo = _repositoryWithHousehold(client);

      await repo.createChore(
        calendar: _calendar('cal-1'),
        title: 'Chore',
        assigneePersonIds: [],
        points: 3,
      );

      expect(client.createCalls.single['assigneePersonId'], '');
    });

    test(
      'unassigned create fallback metadata sends empty assignee string',
      () async {
        final client = _CreateTrackingHubClient(failAtomicCreate: true);
        final repo = _repositoryWithHousehold(client);

        await repo.createChore(
          calendar: _calendar('portal:cal-1'),
          title: 'Chore',
          assigneePersonIds: [],
          points: 3,
        );

        expect(client.createCalls.first['assigneePersonId'], '');
        expect(client.createCalls.last['calendarId'], 'cal-1');
        expect(client.metadataCalls.single['assigneePersonId'], '');
      },
    );

    test('two assignees make two separate backend create calls', () async {
      final client = _CreateTrackingHubClient();
      final repo = _repositoryWithHousehold(client);

      await repo.createChore(
        calendar: _calendar('cal-1'),
        title: 'Chore',
        assigneePersonIds: ['person-1', 'person-2'],
        points: 5,
      );

      expect(client.createCalls, hasLength(2));
      final assignees = client.createCalls
          .map((c) => c['assigneePersonId'])
          .toSet();
      expect(assignees, containsAll(['person-1', 'person-2']));
    });

    test(
      'duplicate assignee IDs are deduped preserving first-seen order',
      () async {
        final client = _CreateTrackingHubClient();
        final repo = _repositoryWithHousehold(client);

        await repo.createChore(
          calendar: _calendar('cal-1'),
          title: 'Chore',
          assigneePersonIds: ['person-2', 'person-1', 'person-2'],
          points: 3,
        );

        expect(client.createCalls, hasLength(2));
        expect(client.createCalls[0]['assigneePersonId'], 'person-2');
        expect(client.createCalls[1]['assigneePersonId'], 'person-1');
      },
    );

    test('whitespace-only and empty IDs are skipped', () async {
      final client = _CreateTrackingHubClient();
      final repo = _repositoryWithHousehold(client);

      await repo.createChore(
        calendar: _calendar('cal-1'),
        title: 'Chore',
        assigneePersonIds: ['  ', '', 'person-1'],
        points: 1,
      );

      expect(client.createCalls, hasLength(1));
      expect(client.createCalls.single['assigneePersonId'], 'person-1');
    });
  });

  group('ChoresRepository updateChore', () {
    test('unassigned atomic update sends empty assignee string', () async {
      final client = _UpdateTrackingHubClient();
      final repo = _repositoryWithHousehold(client);

      await repo.updateChore(
        chore: _chore(),
        title: 'Chore',
        assigneePersonId: null,
        points: 3,
        approvalState: 'none',
      );

      expect(client.updateCalls.single['assigneePersonId'], '');
    });

    test(
      'unassigned update fallback metadata sends empty assignee string',
      () async {
        final client = _UpdateTrackingHubClient(failAtomicUpdate: true);
        final repo = _repositoryWithHousehold(client);

        await repo.updateChore(
          chore: _chore(),
          title: 'Chore',
          assigneePersonId: null,
          points: 3,
          approvalState: 'none',
        );

        expect(client.updateCalls.first['assigneePersonId'], '');
        expect(client.metadataCalls.single['assigneePersonId'], '');
      },
    );
  });

  group('ChoresController.toggleChoreCompletion future-date guard', () {
    test('today chore calls repository.completeChore', () async {
      final client = _CompletionTrackingHubClient();
      final controller = ChoresController(repository: _repositoryWith(client));
      final today = _isoDate(DateTime.now());

      await controller.toggleChoreCompletion(
        _chore(occurrenceDate: today, section: 'todoToday'),
      );

      expect(client.completeCalls, hasLength(1));
      controller.dispose();
    });

    test('done today chore can still be undone', () async {
      final client = _CompletionTrackingHubClient();
      final controller = ChoresController(repository: _repositoryWith(client));
      final today = _isoDate(DateTime.now());

      await controller.toggleChoreCompletion(
        _chore(
          occurrenceDate: today,
          section: 'doneToday',
          completedToday: true,
        ),
      );

      expect(client.undoCalls, hasLength(1));
      expect(client.completeCalls, isEmpty);
      controller.dispose();
    });

    test(
      'tomorrow chore does not call repository.completeChore and surfaces a friendly error',
      () async {
        final client = _CompletionTrackingHubClient();
        final controller = ChoresController(
          repository: _repositoryWith(client),
        );
        final tomorrow = _isoDate(DateTime.now().add(const Duration(days: 1)));

        await expectLater(
          () => controller.toggleChoreCompletion(
            _chore(occurrenceDate: tomorrow, section: 'future'),
          ),
          throwsA(
            isA<CaleeHubException>().having(
              (e) => e.message,
              'message',
              'Future chores cannot be completed yet.',
            ),
          ),
        );

        expect(client.completeCalls, isEmpty);
        controller.dispose();
      },
    );
  });

  group('points validation', () {
    bool isValid(int? v) => v != null && v >= 1 && v <= 100;

    test('accepts values 1 through 100', () {
      expect(isValid(1), isTrue);
      expect(isValid(50), isTrue);
      expect(isValid(100), isTrue);
    });

    test('rejects values outside 1-100', () {
      expect(isValid(0), isFalse);
      expect(isValid(101), isFalse);
      expect(isValid(null), isFalse);
    });
  });
}
