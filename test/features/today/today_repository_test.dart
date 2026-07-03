import 'package:calee_mobile/data/api/calee_hub_client.dart';
import 'package:calee_mobile/data/models/client_bootstrap.dart';
import 'package:calee_mobile/data/models/client_calendar.dart';
import 'package:calee_mobile/data/models/client_chore.dart';
import 'package:calee_mobile/data/models/client_task.dart';
import 'package:calee_mobile/features/today/today_repository.dart';
import 'package:flutter_test/flutter_test.dart';

// ── Stubs ──────────────────────────────────────────────────────────────────────

class _StubHubClient extends CaleeHubClient {
  _StubHubClient({
    ClientEventList? events,
    ClientTaskList? tasks,
    ClientChoreList? chores,
    this.failEvents = false,
    this.failTasks = false,
  }) : stubEvents = events,
       stubTasks = tasks,
       stubChores = chores;

  final ClientEventList? stubEvents;
  final ClientTaskList? stubTasks;
  final ClientChoreList? stubChores;
  final bool failEvents;
  final bool failTasks;

  @override
  Future<ClientEventList> events({
    required String accessToken,
    required String from,
    required String to,
  }) {
    if (failEvents) return Future.error(Exception('events error'));
    return Future.value(
      stubEvents ?? ClientEventList(from: from, to: to, events: const []),
    );
  }

  @override
  Future<ClientTaskList> tasks({
    required String accessToken,
    required String from,
    required String to,
  }) {
    if (failTasks) return Future.error(Exception('tasks error'));
    return Future.value(
      stubTasks ?? ClientTaskList(from: from, to: to, tasks: const []),
    );
  }

  @override
  Future<ClientChoreList> chores({
    required String accessToken,
    required String from,
    required String to,
  }) {
    return Future.value(
      stubChores ?? ClientChoreList(from: from, to: to, chores: const []),
    );
  }
}

ClientService _choreService() => const ClientService(
  id: 'portal',
  displayName: 'Portal',
  baseUrl: '',
  launchUrl: '',
  serviceType: 'nextcloud_portal',
  accessStatus: 'active',
  calendarCredentialStatus: 'connected',
  source: '',
  capabilities: {'chores': true},
);

ClientService _calendarService() => const ClientService(
  id: 'caldav',
  displayName: 'CalDAV',
  baseUrl: '',
  launchUrl: '',
  serviceType: 'caldav',
  accessStatus: 'active',
  calendarCredentialStatus: 'connected',
  source: '',
  capabilities: {'calendar': true, 'tasks': true},
);

TodayRepository _repo(
  CaleeHubClient client, {
  List<ClientService>? services,
  bool isFamilyUxContext = false,
}) => TodayRepository(
  hubClient: client,
  accessToken: 'token',
  services: services ?? [_calendarService()],
  households: const [],
  isFamilyUxContext: isFamilyUxContext,
);

ClientTask _task({
  required String id,
  required String dueAt,
  String status = 'needsaction',
}) => ClientTask(
  id: id,
  calendarId: 'cal',
  serviceId: 'svc',
  serviceName: 'Svc',
  title: 'Task $id',
  status: status,
  dueAt: dueAt,
  completedAt: null,
  description: null,
  source: '',
);

ClientChore _chore({required String id, required String section}) =>
    ClientChore(
      id: id,
      calendarId: 'cal',
      serviceId: 'svc',
      serviceName: 'Svc',
      title: 'Chore $id',
      scheduledAt: null,
      scheduledDate: null,
      description: null,
      source: '',
      kind: 'baseChore',
      choreUid: id,
      parentChoreUid: null,
      completionLogId: null,
      completedToday: false,
      section: section,
      recurrence: null,
      points: 1,
      metadataPoints: null,
      assigneePersonId: null,
      assigneeName: null,
      assigneeAvatarColor: null,
      approvalState: 'none',
    );

// ── Tests ──────────────────────────────────────────────────────────────────────

void main() {
  group('TodayRepository.loadToday()', () {
    test('returns empty overview when all sections empty', () async {
      final repo = _repo(_StubHubClient());
      final overview = await repo.loadToday();

      expect(overview.eventsToday, isEmpty);
      expect(overview.tasksDueToday, isEmpty);
      expect(overview.overdueTasks, isEmpty);
      expect(overview.choresDueToday, isEmpty);
      expect(overview.overdueChores, isEmpty);
      expect(overview.calendarError, isNull);
      expect(overview.tasksError, isNull);
      expect(overview.choresError, isNull);
    });

    test('sets calendarError when events call fails', () async {
      final repo = _repo(_StubHubClient(failEvents: true));
      final overview = await repo.loadToday();

      expect(overview.calendarError, isNotNull);
      expect(overview.tasksError, isNull);
    });

    test('sets tasksError when tasks call fails', () async {
      final repo = _repo(_StubHubClient(failTasks: true));
      final overview = await repo.loadToday();

      expect(overview.tasksError, isNotNull);
      expect(overview.calendarError, isNull);
    });

    test('partial failure does not block other sections', () async {
      final repo = _repo(_StubHubClient(failEvents: true, failTasks: true));
      final overview = await repo.loadToday();

      // Both failed but no exception thrown
      expect(overview.calendarError, isNotNull);
      expect(overview.tasksError, isNotNull);
      expect(overview.choresDueToday, isEmpty);
    });

    test('does not load chores when no chore service', () async {
      final client = _StubHubClient(
        chores: ClientChoreList(
          from: '',
          to: '',
          chores: [_chore(id: '1', section: 'todoToday')],
        ),
      );
      // No chore service
      final repo = _repo(client, services: [_calendarService()]);
      final overview = await repo.loadToday();

      expect(overview.choresDueToday, isEmpty);
      expect(overview.choresError, isNull);
    });

    test('loads chores when chore service present and family context', () async {
      final client = _StubHubClient(
        chores: ClientChoreList(
          from: '',
          to: '',
          chores: [
            _chore(id: '1', section: 'todoToday'),
            _chore(id: '2', section: 'overdue'),
          ],
        ),
      );
      final repo = _repo(
        client,
        services: [_choreService()],
        isFamilyUxContext: true,
      );
      final overview = await repo.loadToday();

      expect(overview.choresDueToday.length, 1);
      expect(overview.overdueChores.length, 1);
    });

    test('does not load chores even with chore service when not family context', () async {
      final client = _StubHubClient(
        chores: ClientChoreList(
          from: '',
          to: '',
          chores: [_chore(id: '1', section: 'todoToday')],
        ),
      );
      // business/workspace: isFamilyUxContext = false
      final repo = _repo(
        client,
        services: [_choreService()],
        isFamilyUxContext: false,
      );
      final overview = await repo.loadToday();

      expect(overview.choresDueToday, isEmpty);
      expect(overview.choresError, isNull);
    });

    test('splits tasks into due-today and overdue correctly', () async {
      final now = DateTime.now();
      final todayStr =
          '${now.year.toString().padLeft(4, '0')}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
      final yesterday = now.subtract(const Duration(days: 1));
      final yesterdayStr =
          '${yesterday.year.toString().padLeft(4, '0')}-${yesterday.month.toString().padLeft(2, '0')}-${yesterday.day.toString().padLeft(2, '0')}';

      final client = _StubHubClient(
        tasks: ClientTaskList(
          from: '',
          to: '',
          tasks: [
            _task(id: '1', dueAt: todayStr),
            _task(id: '2', dueAt: yesterdayStr),
            _task(id: '3', dueAt: todayStr, status: 'completed'),
          ],
        ),
      );
      final repo = _repo(client);
      final overview = await repo.loadToday();

      expect(overview.tasksDueToday.length, 1);
      expect(overview.tasksDueToday.first.id, '1');
      expect(overview.overdueTasks.length, 1);
      expect(overview.overdueTasks.first.id, '2');
    });

    test('completed tasks are excluded from today and overdue', () async {
      final now = DateTime.now();
      final todayStr =
          '${now.year.toString().padLeft(4, '0')}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';

      final client = _StubHubClient(
        tasks: ClientTaskList(
          from: '',
          to: '',
          tasks: [_task(id: '1', dueAt: todayStr, status: 'completed')],
        ),
      );
      final repo = _repo(client);
      final overview = await repo.loadToday();

      expect(overview.tasksDueToday, isEmpty);
      expect(overview.overdueTasks, isEmpty);
    });
  });
}
