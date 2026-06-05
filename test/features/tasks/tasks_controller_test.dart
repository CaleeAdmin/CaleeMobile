import 'package:calee_mobile/data/api/calee_hub_client.dart';
import 'package:calee_mobile/data/auth/calee_preferences.dart';
import 'package:calee_mobile/data/models/client_bootstrap.dart';
import 'package:calee_mobile/data/models/client_calendar.dart';
import 'package:calee_mobile/data/models/client_task.dart';
import 'package:calee_mobile/features/tasks/tasks_controller.dart';
import 'package:calee_mobile/features/tasks/tasks_repository.dart';
import 'package:flutter_test/flutter_test.dart';

// ── Minimal stubs ─────────────────────────────────────────────────────────────

ClientTaskList _emptyTaskList() =>
    ClientTaskList(from: '2024-01-01', to: '2027-12-31', tasks: []);

ClientCalendarList _emptyCalendarList() => ClientCalendarList(calendars: []);

class _AlwaysFailHubClient extends CaleeHubClient {
  @override
  Future<ClientCalendarList> calendars({required String accessToken}) =>
      Future.error(Exception('network error'));

  @override
  Future<ClientTaskList> tasks({
    required String accessToken,
    required String from,
    required String to,
  }) => Future.error(Exception('network error'));
}

class _SuccessHubClient extends CaleeHubClient {
  @override
  Future<ClientCalendarList> calendars({required String accessToken}) =>
      Future.value(_emptyCalendarList());

  @override
  Future<ClientTaskList> tasks({
    required String accessToken,
    required String from,
    required String to,
  }) => Future.value(_emptyTaskList());
}

class _FakePreferences extends CaleePreferences {
  @override
  Future<StoredPreferences> load() async => const StoredPreferences();
}

// ── Helpers ───────────────────────────────────────────────────────────────────

TasksRepository _repositoryWith(CaleeHubClient client) => TasksRepository(
  hubClient: client,
  accessToken: 'token',
  services: [],
  preferences: _FakePreferences(),
);

ClientService _svc(String id, Map<String, dynamic> caps) => ClientService(
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

// ── Tests ─────────────────────────────────────────────────────────────────────

void main() {
  group('TasksRepository.taskServices', () {
    test('returns only services where supportsTasks is true', () {
      final services = [
        _svc('svc-tasks', {'tasks': true}),
        _svc('svc-chores', {'chores': true}),
        _svc('svc-both', {'tasks': true, 'chores': true}),
      ];

      final repo = TasksRepository(
        hubClient: _SuccessHubClient(),
        accessToken: 'token',
        services: services,
        preferences: _FakePreferences(),
      );

      final ids = repo.taskServices.map((s) => s.id).toList();
      expect(ids, containsAll(['svc-tasks', 'svc-both']));
      expect(ids, isNot(contains('svc-chores')));
    });
  });

  group('TasksController loading state', () {
    test('sets isLoading true then false on success', () async {
      final controller = TasksController(
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
      final controller = TasksController(
        repository: _repositoryWith(_AlwaysFailHubClient()),
      );

      await controller.load();

      expect(controller.isLoading, isFalse);
      expect(controller.error, isNotNull);
      expect(controller.overview, isNull);

      controller.dispose();
    });
  });

  group('TasksController toggleTaskStatus', () {
    test('adds then removes task id from updatingTaskIds', () async {
      final taskId = 'task-123';
      final task = ClientTask(
        id: taskId,
        calendarId: 'cal-1',
        serviceId: 'svc-1',
        serviceName: 'Test',
        title: 'Test task',
        status: 'needsaction',
        dueAt: null,
        completedAt: null,
        description: null,
        source: '',
      );

      bool? sawAdded;
      final client = _ToggleTrackingHubClient(
        onUpdateStatus: () {
          sawAdded = true;
        },
      );

      final repo = TasksRepository(
        hubClient: client,
        accessToken: 'token',
        services: [],
        preferences: _FakePreferences(),
      );
      final controller = TasksController(repository: repo);
      // Pre-load so overview is available after toggle
      await controller.load();

      final future = controller.toggleTaskStatus(task);
      expect(controller.updatingTaskIds.contains(taskId), isTrue);
      await future;
      expect(controller.updatingTaskIds.contains(taskId), isFalse);
      expect(sawAdded, isTrue);

      controller.dispose();
    });
  });

  group('TasksController search query', () {
    test('setSearchQuery updates state and notifies', () {
      final controller = TasksController(
        repository: _repositoryWith(_SuccessHubClient()),
      );

      String? notified;
      controller.addListener(() => notified = controller.searchQuery);

      controller.setSearchQuery('hello');
      expect(controller.searchQuery, 'hello');
      expect(notified, 'hello');

      controller.dispose();
    });
  });
}

// A hub client that records when updateTaskStatus is called.
class _ToggleTrackingHubClient extends CaleeHubClient {
  _ToggleTrackingHubClient({required this.onUpdateStatus});

  final void Function() onUpdateStatus;

  @override
  Future<ClientCalendarList> calendars({required String accessToken}) =>
      Future.value(ClientCalendarList(calendars: []));

  @override
  Future<ClientTaskList> tasks({
    required String accessToken,
    required String from,
    required String to,
  }) => Future.value(ClientTaskList(from: from, to: to, tasks: []));

  @override
  Future<ClientTask> updateTaskStatus({
    required String accessToken,
    required String taskId,
    required bool completed,
  }) async {
    onUpdateStatus();
    return const ClientTask(
      id: 'task-1',
      calendarId: 'calendar-1',
      serviceId: 'service-1',
      serviceName: 'Service',
      title: 'Task',
      status: 'completed',
      dueAt: null,
      completedAt: null,
      description: null,
      source: 'test',
    );
  }
}
