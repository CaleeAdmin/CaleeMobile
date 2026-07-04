import 'package:calee_mobile/data/api/calee_hub_client.dart';
import 'package:calee_mobile/data/models/client_bootstrap.dart';
import 'package:calee_mobile/data/models/client_calendar.dart';
import 'package:calee_mobile/data/models/client_chore.dart';
import 'package:calee_mobile/data/models/client_task.dart';
import 'package:calee_mobile/features/today/today_repository.dart';
import 'package:flutter_test/flutter_test.dart';

// ── Capturing stub ────────────────────────────────────────────────────────────

class _CapturingClient extends CaleeHubClient {
  String? taskFrom;
  String? taskTo;
  String? choreFrom;
  String? choreTo;

  List<ClientTask> tasksToReturn = [];
  List<ClientChore> choresToReturn = [];

  @override
  Future<ClientEventList> events({
    required String accessToken,
    required String from,
    required String to,
  }) => Future.value(ClientEventList(from: from, to: to, events: const []));

  @override
  Future<ClientTaskList> tasks({
    required String accessToken,
    required String from,
    required String to,
  }) {
    taskFrom = from;
    taskTo = to;
    return Future.value(
      ClientTaskList(from: from, to: to, tasks: tasksToReturn),
    );
  }

  @override
  Future<ClientChoreList> chores({
    required String accessToken,
    required String from,
    required String to,
  }) {
    choreFrom = from;
    choreTo = to;
    return Future.value(
      ClientChoreList(from: from, to: to, chores: choresToReturn),
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

ClientTask _task({required String id, required String dueAt}) => ClientTask(
  id: id,
  calendarId: 'cal',
  serviceId: 'svc',
  serviceName: 'Svc',
  title: 'Task $id',
  status: 'needsaction',
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
      baseChoreId: null,
      occurrenceDate: null,
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

// ── Tests ─────────────────────────────────────────────────────────────────────

void main() {
  group('TodayRepository — task date range', () {
    test('requests tasks from year-2 Jan 1 to year+2 Dec 31', () async {
      final client = _CapturingClient();
      final repo = _repo(client);
      await repo.loadToday();

      final year = DateTime.now().year;
      expect(client.taskFrom, '${year - 2}-01-01');
      expect(client.taskTo, '${year + 2}-12-31');
    });

    test('overdue task older than yesterday appears in overdueTasks', () async {
      final year = DateTime.now().year;
      final oldDue = '${year - 1}-06-15';
      final client = _CapturingClient()
        ..tasksToReturn = [_task(id: 'old', dueAt: oldDue)];
      final repo = _repo(client);
      final overview = await repo.loadToday();

      expect(overview.overdueTasks.length, 1);
      expect(overview.overdueTasks.first.id, 'old');
      expect(overview.tasksDueToday, isEmpty);
    });
  });

  group('TodayRepository — chore date range', () {
    test('requests chores from current year Jan 1 to Dec 31', () async {
      final client = _CapturingClient();
      final repo = _repo(
        client,
        services: [_choreService()],
        isFamilyUxContext: true,
      );
      await repo.loadToday();

      final year = DateTime.now().year;
      expect(client.choreFrom, '$year-01-01');
      expect(client.choreTo, '$year-12-31');
    });

    test('overdue chore (section=overdue) appears in overdueChores', () async {
      final client = _CapturingClient()
        ..choresToReturn = [_chore(id: 'c1', section: 'overdue')];
      final repo = _repo(
        client,
        services: [_choreService()],
        isFamilyUxContext: true,
      );
      final overview = await repo.loadToday();

      expect(overview.overdueChores.length, 1);
      expect(overview.overdueChores.first.id, 'c1');
      expect(overview.choresDueToday, isEmpty);
    });

    test('chore API is not called when no chore service', () async {
      final client = _CapturingClient();
      final repo = _repo(client, services: [_calendarService()]);
      await repo.loadToday();

      expect(client.choreFrom, isNull);
      expect(client.choreTo, isNull);
    });
  });

  group('TodayRepository — partial failure isolation', () {
    test('task failure does not prevent chore loading', () async {
      final client = _CapturingClient()
        ..choresToReturn = [_chore(id: 'c1', section: 'todoToday')];

      // Override tasks to fail
      final failingClient = _FailTasksClient(client);
      final repo = _repo(
        failingClient,
        services: [_choreService()],
        isFamilyUxContext: true,
      );
      final overview = await repo.loadToday();

      expect(overview.tasksError, isNotNull);
      expect(overview.choresDueToday.length, 1);
      expect(overview.choresError, isNull);
    });
  });
}

// Wraps _CapturingClient to make tasks() throw
class _FailTasksClient extends CaleeHubClient {
  _FailTasksClient(this._inner);
  final _CapturingClient _inner;

  @override
  Future<ClientEventList> events({
    required String accessToken,
    required String from,
    required String to,
  }) => _inner.events(accessToken: accessToken, from: from, to: to);

  @override
  Future<ClientTaskList> tasks({
    required String accessToken,
    required String from,
    required String to,
  }) => Future.error(Exception('tasks failed'));

  @override
  Future<ClientChoreList> chores({
    required String accessToken,
    required String from,
    required String to,
  }) => _inner.chores(accessToken: accessToken, from: from, to: to);
}
