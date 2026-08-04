// Controller-level tests for chore completion/undo.
//
// The overlay's own rules are covered by chore_sync_reconciliation_test.dart.
// This file only exercises the integration boundary the controller owns:
// when a mutation result becomes pending state, what a failed request leaves
// behind, how the warning surfaces, and that grouping still yields one row.

import 'package:calee_mobile/data/api/calee_hub_client.dart';
import 'package:calee_mobile/data/models/client_bootstrap.dart';
import 'package:calee_mobile/data/models/client_calendar.dart';
import 'package:calee_mobile/data/models/client_chore.dart';
import 'package:calee_mobile/data/models/client_person.dart';
import 'package:calee_mobile/features/chores/chore_grouping.dart';
import 'package:calee_mobile/features/chores/chore_sync_state.dart';
import 'package:calee_mobile/features/chores/chores_controller.dart';
import 'package:calee_mobile/features/chores/chores_repository.dart';
import 'package:flutter_test/flutter_test.dart';

String _isoToday() {
  final now = DateTime.now();
  return '${now.year.toString().padLeft(4, '0')}-'
      '${now.month.toString().padLeft(2, '0')}-'
      '${now.day.toString().padLeft(2, '0')}';
}

ClientChore _chore({required bool completed, String serviceId = 'portal'}) {
  final date = _isoToday();
  return ClientChore(
    id: completed ? '$serviceId:log-$date' : '$serviceId:uid-1:$date',
    calendarId: 'cal-1',
    serviceId: serviceId,
    serviceName: 'Portal',
    title: 'Take out bins',
    scheduledAt: date,
    scheduledDate: date,
    description: null,
    source: 'nextcloud_portal',
    kind: completed ? 'completionLog' : 'baseChore',
    choreUid: 'uid-1',
    parentChoreUid: completed ? 'uid-1' : null,
    baseChoreId: '$serviceId:uid-1',
    occurrenceDate: date,
    completionLogId: completed ? '$serviceId:log-$date' : null,
    completedToday: completed,
    section: completed ? 'doneToday' : 'todoToday',
    recurrence: null,
    points: 1,
    metadataPoints: null,
    assigneePersonId: null,
    assigneeName: null,
    assigneeAvatarColor: null,
    approvalState: 'none',
  );
}

/// Serves a scripted sequence of list responses; each `chores()` call consumes
/// the next, and the last entry repeats.
class _ScriptedHubClient extends CaleeHubClient {
  _ScriptedHubClient({
    required this.lists,
    this.completionRow,
    this.undoRow,
    this.completionError,
    this.undoError,
  });

  final List<List<ClientChore>> lists;
  final ClientChore? completionRow;
  final ClientChore? undoRow;
  final Object? completionError;
  final Object? undoError;

  int listCalls = 0;
  int completeCalls = 0;
  int undoCalls = 0;

  @override
  Future<ClientCalendarList> calendars({required String accessToken}) =>
      Future.value(
        ClientCalendarList(
          calendars: [
            ClientCalendar(
              id: 'portal:cal-1',
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
            ),
          ],
        ),
      );

  @override
  Future<ClientPersonList> people({
    required String accessToken,
    required String householdId,
    bool includeArchived = false,
  }) => Future.value(const ClientPersonList(people: []));

  @override
  Future<ClientChoreList> chores({
    required String accessToken,
    required String from,
    required String to,
    String? timezone,
  }) {
    final index = listCalls < lists.length ? listCalls : lists.length - 1;
    listCalls++;
    return Future.value(
      ClientChoreList(from: from, to: to, chores: lists[index]),
    );
  }

  @override
  Future<ChoreCompletionResult> completeChore({
    required String accessToken,
    required String choreId,
    String? date,
    String? timezone,
  }) {
    completeCalls++;
    if (completionError != null) return Future.error(completionError!);
    return Future.value(
      ChoreCompletionResult(
        completed: true,
        alreadyCompleted: false,
        completedDate: date,
        completionLogId: completionRow?.completionLogId,
        chore: completionRow,
      ),
    );
  }

  @override
  Future<ChoreCompletionResult> undoChoreCompletion({
    required String accessToken,
    required String choreId,
    String? date,
    String? timezone,
  }) {
    undoCalls++;
    if (undoError != null) return Future.error(undoError!);
    return Future.value(
      ChoreCompletionResult(
        completed: false,
        alreadyCompleted: false,
        completedDate: date,
        completionLogId: null,
        chore: undoRow,
      ),
    );
  }
}

ChoresController _controller(
  _ScriptedHubClient client, {
  Duration window = const Duration(seconds: 90),
}) => ChoresController(
  repository: ChoresRepository(
    hubClient: client,
    accessToken: 'tok',
    services: [
      ClientService(
        id: 'portal',
        displayName: 'Portal',
        baseUrl: 'https://example.test',
        launchUrl: 'https://example.test',
        serviceType: 'nextcloud_portal',
        accessStatus: 'active',
        calendarCredentialStatus: 'connected',
        source: '',
        capabilities: const {'chores': true},
      ),
    ],
    households: const [
      ClientContext(
        id: 'household-1',
        type: 'household',
        name: 'Household',
        role: 'admin',
        status: 'active',
      ),
    ],
    accountId: 'account-1',
    timezone: 'Australia/Perth',
  ),
  syncOverlay: ChoreSyncOverlay(omissionWindow: window),
);

List<ClientChore> _section(ChoresController controller, String section) =>
    groupChoresBySection(
      controller.overview?.choreList.chores ?? const <ClientChore>[],
      DateTime.now(),
    )[section] ??
    const <ClientChore>[];

void main() {
  test(
    'a confirmed completion renders the backend row under Done today',
    () async {
      final client = _ScriptedHubClient(
        lists: [
          [_chore(completed: false)],
          [_chore(completed: true)],
        ],
        completionRow: _chore(completed: true),
      );
      final controller = _controller(client);

      await controller.load();
      await controller.toggleChoreCompletion(
        controller.overview!.choreList.chores.first,
      );

      expect(_section(controller, 'doneToday'), hasLength(1));
      expect(_section(controller, 'todoToday'), isEmpty);
      expect(controller.syncOverlay.pendingCount, 0);
      expect(controller.syncError, isNull);
    },
  );

  test('a completion the list omits stays visible without a warning', () async {
    final client = _ScriptedHubClient(
      lists: [
        [_chore(completed: false)],
        const <ClientChore>[],
      ],
      completionRow: _chore(completed: true),
    );
    final controller = _controller(client);

    await controller.load();
    await controller.toggleChoreCompletion(
      controller.overview!.choreList.chores.first,
    );

    expect(_section(controller, 'doneToday'), hasLength(1));
    expect(controller.syncOverlay.pendingCount, 1);
    expect(controller.syncError, isNull);
  });

  test(
    'a completion the backend contradicts warns and shows the backend row',
    () async {
      final client = _ScriptedHubClient(
        lists: [
          [_chore(completed: false)],
          [_chore(completed: false)],
        ],
        completionRow: _chore(completed: true),
      );
      final controller = _controller(client);

      await controller.load();
      await controller.toggleChoreCompletion(
        controller.overview!.choreList.chores.first,
      );

      expect(_section(controller, 'todoToday'), hasLength(1));
      expect(_section(controller, 'doneToday'), isEmpty);
      expect(controller.syncOverlay.pendingCount, 0);
      expect(controller.syncError, isNotNull);
    },
  );

  test(
    'a failed completion leaves the occurrence active and unpended',
    () async {
      final client = _ScriptedHubClient(
        lists: [
          [_chore(completed: false)],
        ],
        completionError: const CaleeHubException(
          statusCode: 500,
          message: 'boom',
        ),
      );
      final controller = _controller(client);

      await controller.load();
      await expectLater(
        controller.toggleChoreCompletion(
          controller.overview!.choreList.chores.first,
        ),
        throwsA(isA<CaleeHubException>()),
      );

      expect(_section(controller, 'todoToday'), hasLength(1));
      expect(controller.syncOverlay.pendingCount, 0);
      expect(controller.updatingChoreIds, isEmpty);
    },
  );

  test('a successful undo returns the occurrence to Today', () async {
    final client = _ScriptedHubClient(
      lists: [
        [_chore(completed: true)],
        [_chore(completed: false)],
      ],
      undoRow: _chore(completed: false),
    );
    final controller = _controller(client);

    await controller.load();
    await controller.toggleChoreCompletion(
      controller.overview!.choreList.chores.first,
    );

    expect(client.undoCalls, 1);
    expect(_section(controller, 'todoToday'), hasLength(1));
    expect(_section(controller, 'doneToday'), isEmpty);
    expect(controller.syncOverlay.pendingCount, 0);
  });

  test('a failed undo keeps the occurrence completed', () async {
    final client = _ScriptedHubClient(
      lists: [
        [_chore(completed: true)],
      ],
      undoError: const CaleeHubException(statusCode: 500, message: 'boom'),
    );
    final controller = _controller(client);

    await controller.load();
    await expectLater(
      controller.toggleChoreCompletion(
        controller.overview!.choreList.chores.first,
      ),
      throwsA(isA<CaleeHubException>()),
    );

    expect(_section(controller, 'doneToday'), hasLength(1));
    expect(controller.syncOverlay.pendingCount, 0);
    expect(controller.updatingChoreIds, isEmpty);
  });

  test('repeated refreshes never duplicate the completed row', () async {
    final client = _ScriptedHubClient(
      lists: [
        [_chore(completed: false)],
        [_chore(completed: true)],
      ],
      completionRow: _chore(completed: true),
    );
    final controller = _controller(client);

    await controller.load();
    await controller.toggleChoreCompletion(
      controller.overview!.choreList.chores.first,
    );

    for (var i = 0; i < 3; i++) {
      await controller.refresh();
      expect(_section(controller, 'doneToday'), hasLength(1));
      final ids = controller.overview!.choreList.chores.map((c) => c.id);
      expect(ids.toSet(), hasLength(ids.length));
    }
  });

  test('a second toggle is ignored while one is in flight', () async {
    final client = _ScriptedHubClient(
      lists: [
        [_chore(completed: false)],
        [_chore(completed: true)],
      ],
      completionRow: _chore(completed: true),
    );
    final controller = _controller(client);

    await controller.load();
    final chore = controller.overview!.choreList.chores.first;
    await Future.wait([
      controller.toggleChoreCompletion(chore),
      controller.toggleChoreCompletion(chore),
    ]);

    expect(client.completeCalls, 1);
  });

  test('disposing the controller clears held state', () async {
    final client = _ScriptedHubClient(
      lists: [
        [_chore(completed: false)],
        const <ClientChore>[],
      ],
      completionRow: _chore(completed: true),
    );
    final controller = _controller(client);

    await controller.load();
    await controller.toggleChoreCompletion(
      controller.overview!.choreList.chores.first,
    );
    expect(controller.syncOverlay.pendingCount, 1);

    controller.dispose();
    expect(controller.syncOverlay.pendingCount, 0);
  });
}
