import 'package:calee_mobile/data/api/calee_hub_client.dart';
import 'package:calee_mobile/data/models/client_bootstrap.dart';
import 'package:calee_mobile/data/models/client_calendar.dart';
import 'package:calee_mobile/data/models/client_chore.dart';
import 'package:calee_mobile/data/models/client_person.dart';
import 'package:calee_mobile/features/chores/chores_controller.dart';
import 'package:calee_mobile/features/chores/chores_repository.dart';
import 'package:flutter_test/flutter_test.dart';

// ── Minimal stubs ─────────────────────────────────────────────────────────────

ClientChoreList _emptyChoreList() => ClientChoreList(
      from: '2026-01-01',
      to: '2026-12-31',
      chores: [],
    );

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
  }) =>
      Future.error(Exception('network error'));
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
  }) =>
      Future.value(_emptyChoreList());

  @override
  Future<ClientPersonList> people({
    required String accessToken,
    required String householdId,
    bool includeArchived = false,
  }) =>
      Future.value(_emptyPeopleList());
}

// ── Helpers ───────────────────────────────────────────────────────────────────

ChoresRepository _repositoryWith(CaleeHubClient client) => ChoresRepository(
      hubClient: client,
      accessToken: 'token',
      services: [],
      households: [],
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
      final controller =
          ChoresController(repository: _repositoryWith(_SuccessHubClient()));

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
      final controller =
          ChoresController(repository: _repositoryWith(_AlwaysFailHubClient()));

      await controller.load();

      expect(controller.isLoading, isFalse);
      expect(controller.error, isNotNull);
      expect(controller.overview, isNull);

      controller.dispose();
    });
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
