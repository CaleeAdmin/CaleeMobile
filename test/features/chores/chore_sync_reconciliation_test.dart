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

// ── Helpers ───────────────────────────────────────────────────────────────────

String _isoDate(DateTime value) =>
    '${value.year.toString().padLeft(4, '0')}-'
    '${value.month.toString().padLeft(2, '0')}-'
    '${value.day.toString().padLeft(2, '0')}';

String get _today => _isoDate(DateTime.now());
String get _tomorrow => _isoDate(DateTime.now().add(const Duration(days: 1)));

/// An active occurrence row as the backend emits it.
ClientChore _active({
  String uid = 'uid-1',
  String serviceId = 'portal',
  String calendarId = 'cal-1',
  String title = 'Take out bins',
  String? occurrenceDate,
  String section = 'todoToday',
  String? recurrence,
}) {
  final date = occurrenceDate ?? _today;
  final baseChoreId = '$serviceId:$uid';
  return ClientChore(
    id: recurrence == null ? baseChoreId : '$baseChoreId:$date',
    calendarId: calendarId,
    serviceId: serviceId,
    serviceName: 'Portal',
    title: title,
    scheduledAt: date,
    scheduledDate: date,
    description: null,
    source: 'nextcloud_portal',
    kind: 'baseChore',
    choreUid: uid,
    parentChoreUid: null,
    baseChoreId: baseChoreId,
    occurrenceDate: date,
    completionLogId: null,
    completedToday: false,
    section: section,
    recurrence: recurrence,
    points: 1,
    metadataPoints: null,
    assigneePersonId: null,
    assigneeName: null,
    assigneeAvatarColor: null,
    approvalState: 'none',
  );
}

/// The completed occurrence row the backend returns from the completion
/// endpoint and from the next list response.
ClientChore _completed({
  String uid = 'uid-1',
  String serviceId = 'portal',
  String calendarId = 'cal-1',
  String title = 'Take out bins',
  String? occurrenceDate,
  String section = 'doneToday',
  bool completedToday = true,
  String? recurrence,
}) {
  final date = occurrenceDate ?? _today;
  return ClientChore(
    id: '$serviceId:calee-chore-log-$uid-$date',
    calendarId: calendarId,
    serviceId: serviceId,
    serviceName: 'Portal',
    title: title,
    scheduledAt: date,
    scheduledDate: date,
    description: null,
    source: 'nextcloud_portal',
    kind: 'completionLog',
    choreUid: uid,
    parentChoreUid: uid,
    baseChoreId: '$serviceId:$uid',
    occurrenceDate: date,
    completionLogId: '$serviceId:calee-chore-log-$uid-$date',
    completedToday: completedToday,
    section: section,
    recurrence: recurrence,
    points: 1,
    metadataPoints: null,
    assigneePersonId: null,
    assigneeName: null,
    assigneeAvatarColor: null,
    approvalState: 'none',
  );
}

ClientCalendar _calendar({
  String id = 'portal:cal-1',
  String serviceId = 'portal',
}) => ClientCalendar(
  id: id,
  serviceId: serviceId,
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

ClientService _service({String id = 'portal'}) => ClientService(
  id: id,
  displayName: 'Portal',
  baseUrl: 'https://example.test',
  launchUrl: 'https://example.test',
  serviceType: 'nextcloud_portal',
  accessStatus: 'active',
  calendarCredentialStatus: 'connected',
  source: '',
  capabilities: const {'chores': true},
);

ClientContext _household({String id = 'household-1'}) => ClientContext(
  id: id,
  type: 'household',
  name: 'Household',
  role: 'admin',
  status: 'active',
);

/// A hub client driven by a script: each `chores()` call consumes the next
/// entry, and completion/undo return whatever the test tells them to.
class _ScriptedHubClient extends CaleeHubClient {
  _ScriptedHubClient({
    required this.listResponses,
    this.completionResult,
    this.undoResult,
    this.completionError,
    this.undoError,
    this.calendars_ = const [],
  });

  final List<List<ClientChore>> listResponses;
  final ClientChore? completionResult;
  final ClientChore? undoResult;
  final Object? completionError;
  final Object? undoError;
  final List<ClientCalendar> calendars_;

  int choresCalls = 0;
  int completeCalls = 0;
  int undoCalls = 0;
  final requestedTimezones = <String?>[];

  @override
  Future<ClientCalendarList> calendars({required String accessToken}) =>
      Future.value(ClientCalendarList(calendars: calendars_));

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
    requestedTimezones.add(timezone);
    final index = choresCalls < listResponses.length
        ? choresCalls
        : listResponses.length - 1;
    choresCalls++;
    return Future.value(
      ClientChoreList(
        from: from,
        to: to,
        chores: listResponses.isEmpty ? const [] : listResponses[index],
      ),
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
        completionLogId: completionResult?.completionLogId,
        chore: completionResult,
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
        chore: undoResult,
      ),
    );
  }
}

ChoresController _controllerFor(
  _ScriptedHubClient client, {
  String accountId = 'account-1',
  String householdId = 'household-1',
  List<ClientService>? services,
  Duration window = const Duration(seconds: 90),
}) {
  return ChoresController(
    repository: ChoresRepository(
      hubClient: client,
      accessToken: 'token',
      services: services ?? [_service()],
      households: [_household(id: householdId)],
      accountId: accountId,
      timezone: 'Australia/Perth',
    ),
    syncOverlay: ChoreSyncOverlay(reconciliationWindow: window),
  );
}

List<ClientChore> _section(ChoresController controller, String section) {
  final chores = controller.overview?.choreList.chores ?? const <ClientChore>[];
  return groupChoresBySection(chores, DateTime.now())[section] ??
      const <ClientChore>[];
}

void main() {
  group('ChoreOccurrenceKey', () {
    test(
      'scopes by account, household, service, calendar, action and date',
      () {
        final key = ChoreOccurrenceKey.forChore(
          _active(),
          accountId: 'account-1',
          householdId: 'household-1',
        );

        expect(key, isNotNull);
        expect(key!.accountId, 'account-1');
        expect(key.householdId, 'household-1');
        expect(key.serviceId, 'portal');
        expect(key.calendarId, 'cal-1');
        expect(key.completionActionId, 'portal:uid-1');
        expect(key.occurrenceDate, _today);
      },
    );

    // 16. Similar ids from different services must never share a key.
    test('does not collide across services or calendars', () {
      final portal = ChoreOccurrenceKey.forChore(
        _active(uid: 'shared', serviceId: 'portal', calendarId: 'cal-1'),
        accountId: 'a',
        householdId: 'h',
      );
      final business = ChoreOccurrenceKey.forChore(
        _active(uid: 'shared', serviceId: 'business', calendarId: 'cal-1'),
        accountId: 'a',
        householdId: 'h',
      );
      final otherCalendar = ChoreOccurrenceKey.forChore(
        _active(uid: 'shared', serviceId: 'portal', calendarId: 'cal-2'),
        accountId: 'a',
        householdId: 'h',
      );

      expect(portal, isNot(equals(business)));
      expect(portal, isNot(equals(otherCalendar)));
      expect(business, isNot(equals(otherCalendar)));
    });

    // 15. Recurring occurrences are separated by date.
    test('separates occurrences of the same chore by date', () {
      final todayKey = ChoreOccurrenceKey.forChore(
        _active(recurrence: 'FREQ=DAILY', occurrenceDate: _today),
        accountId: 'a',
        householdId: 'h',
      );
      final tomorrowKey = ChoreOccurrenceKey.forChore(
        _active(recurrence: 'FREQ=DAILY', occurrenceDate: _tomorrow),
        accountId: 'a',
        householdId: 'h',
      );

      expect(todayKey, isNot(equals(tomorrowKey)));
    });

    test('is null when the chore has no completion action id', () {
      final orphan = _completed().copyWith();
      final noIdentity = ClientChore.fromJson({
        'id': '',
        'title': orphan.title,
        'kind': 'completionLog',
      });

      expect(
        ChoreOccurrenceKey.forChore(
          noIdentity,
          accountId: 'a',
          householdId: 'h',
        ),
        isNull,
      );
    });
  });

  group('ChoresController completion reconciliation', () {
    // 1. Completion succeeds and the refresh returns the completed occurrence.
    // 18. The correct item appears under Done today.
    test(
      'uses the backend row when the refresh returns it as completed',
      () async {
        final client = _ScriptedHubClient(
          listResponses: [
            [_active()],
            [_completed()],
          ],
          completionResult: _completed(),
          calendars_: [_calendar()],
        );
        final controller = _controllerFor(client);

        await controller.load();
        expect(_section(controller, 'todoToday'), hasLength(1));

        await controller.toggleChoreCompletion(
          controller.overview!.choreList.chores.first,
        );

        final done = _section(controller, 'doneToday');
        expect(done, hasLength(1));
        expect(done.first.title, 'Take out bins');
        expect(done.first.completionLogId, isNotNull);
        expect(_section(controller, 'todoToday'), isEmpty);
        // Backend confirmed, so nothing is held locally.
        expect(controller.syncOverlay.pendingCount, 0);
        expect(controller.syncError, isNull);
      },
    );

    // 2. Completion succeeds and one refresh temporarily omits it.
    test('holds the accepted completion when a refresh omits it', () async {
      final client = _ScriptedHubClient(
        listResponses: [
          [_active()],
          const <ClientChore>[], // completion accepted, list has not caught up
        ],
        completionResult: _completed(),
        calendars_: [_calendar()],
      );
      final controller = _controllerFor(client);

      await controller.load();
      await controller.toggleChoreCompletion(
        controller.overview!.choreList.chores.first,
      );

      final done = _section(controller, 'doneToday');
      expect(done, hasLength(1), reason: 'accepted completion stays visible');
      expect(done.first.completedToday, isTrue);
      expect(controller.syncOverlay.pendingCount, 1);
      expect(controller.syncError, isNull);
    });

    // 3. A later backend confirmation removes the pending state.
    test(
      'drops pending state once the backend confirms the completion',
      () async {
        final client = _ScriptedHubClient(
          listResponses: [
            [_active()],
            const <ClientChore>[],
            [_completed()],
          ],
          completionResult: _completed(),
          calendars_: [_calendar()],
        );
        final controller = _controllerFor(client);

        await controller.load();
        await controller.toggleChoreCompletion(
          controller.overview!.choreList.chores.first,
        );
        expect(controller.syncOverlay.pendingCount, 1);

        await controller.refresh();

        expect(controller.syncOverlay.pendingCount, 0);
        expect(_section(controller, 'doneToday'), hasLength(1));
        expect(controller.syncError, isNull);
      },
    );

    // 4. The backend explicitly returns the occurrence as uncompleted.
    // 5. A stale pending row is not resurrected.
    test('backend wins when it reports the occurrence as uncompleted', () async {
      final client = _ScriptedHubClient(
        listResponses: [
          [_active()],
          const <ClientChore>[],
          [_active()], // the completion did not stick server-side
          [_active()],
        ],
        completionResult: _completed(),
        calendars_: [_calendar()],
      );
      final controller = _controllerFor(client);

      await controller.load();
      await controller.toggleChoreCompletion(
        controller.overview!.choreList.chores.first,
      );
      expect(controller.syncOverlay.pendingCount, 1);

      // The backend says "still active" — while inside the window the stale
      // active row is suppressed in favour of the accepted completion...
      await controller.refresh();
      expect(_section(controller, 'doneToday'), hasLength(1));

      // ...but a pending entry is never permanent. Once it expires the backend
      // state is used and the completed row does not come back.
      controller.syncOverlay.clear();
      await controller.refresh();

      expect(controller.syncOverlay.pendingCount, 0);
      expect(_section(controller, 'doneToday'), isEmpty);
      expect(_section(controller, 'todoToday'), hasLength(1));
    });

    // 9. Pending state expires rather than displaying indefinitely.
    test(
      'expires pending state and surfaces a controlled sync error',
      () async {
        final client = _ScriptedHubClient(
          listResponses: [
            [_active()],
            const <ClientChore>[],
            const <ClientChore>[],
          ],
          completionResult: _completed(),
          calendars_: [_calendar()],
        );
        final controller = _controllerFor(
          client,
          window: Duration.zero, // anything accepted is already stale
        );

        await controller.load();
        await controller.toggleChoreCompletion(
          controller.overview!.choreList.chores.first,
        );

        expect(controller.syncOverlay.pendingCount, 0);
        expect(_section(controller, 'doneToday'), isEmpty);
        expect(controller.syncError, isNotNull);
        expect(controller.syncError, contains('Refresh'));
      },
    );

    // 6. A failed completion keeps the original active state.
    test('a failed completion request adds no pending state', () async {
      final client = _ScriptedHubClient(
        listResponses: [
          [_active()],
        ],
        completionError: const CaleeHubException(
          statusCode: 500,
          message: 'boom',
        ),
        calendars_: [_calendar()],
      );
      final controller = _controllerFor(client);

      await controller.load();

      await expectLater(
        controller.toggleChoreCompletion(
          controller.overview!.choreList.chores.first,
        ),
        throwsA(isA<CaleeHubException>()),
      );

      expect(controller.syncOverlay.pendingCount, 0);
      expect(_section(controller, 'todoToday'), hasLength(1));
      expect(_section(controller, 'doneToday'), isEmpty);
      expect(controller.updatingChoreIds, isEmpty);
    });

    // 17. Repeated refreshes do not duplicate rows.
    test('repeated refreshes never duplicate the completed row', () async {
      final client = _ScriptedHubClient(
        listResponses: [
          [_active()],
          [_completed()],
        ],
        completionResult: _completed(),
        calendars_: [_calendar()],
      );
      final controller = _controllerFor(client);

      await controller.load();
      await controller.toggleChoreCompletion(
        controller.overview!.choreList.chores.first,
      );

      for (var i = 0; i < 4; i++) {
        await controller.refresh();
        expect(_section(controller, 'doneToday'), hasLength(1));
        expect(_section(controller, 'todoToday'), isEmpty);

        final ids = controller.overview!.choreList.chores
            .map((c) => c.id)
            .toList();
        expect(ids.toSet(), hasLength(ids.length));
      }
    });

    // 15. Completing one recurring occurrence leaves the others alone.
    test('completing one occurrence leaves other dates active', () async {
      final todayRow = _active(
        recurrence: 'FREQ=DAILY',
        occurrenceDate: _today,
      );
      final tomorrowRow = _active(
        recurrence: 'FREQ=DAILY',
        occurrenceDate: _tomorrow,
        section: 'future',
      );

      final client = _ScriptedHubClient(
        listResponses: [
          [todayRow, tomorrowRow],
          [_completed(recurrence: 'FREQ=DAILY'), tomorrowRow],
        ],
        completionResult: _completed(recurrence: 'FREQ=DAILY'),
        calendars_: [_calendar()],
      );
      final controller = _controllerFor(client);

      await controller.load();
      await controller.toggleChoreCompletion(todayRow);

      expect(_section(controller, 'doneToday'), hasLength(1));
      expect(_section(controller, 'todoToday'), isEmpty);
      expect(_section(controller, 'tomorrow'), hasLength(1));
      expect(_section(controller, 'tomorrow').first.occurrenceDate, _tomorrow);
    });

    // 16. Similar ids from different services stay independent end to end.
    test('completing one service does not affect the other', () async {
      final portalRow = _active(uid: 'shared', serviceId: 'portal');
      final businessRow = _active(
        uid: 'shared',
        serviceId: 'business',
        calendarId: 'cal-9',
      );

      final client = _ScriptedHubClient(
        listResponses: [
          [portalRow, businessRow],
          [_completed(uid: 'shared', serviceId: 'portal'), businessRow],
        ],
        completionResult: _completed(uid: 'shared', serviceId: 'portal'),
        calendars_: [
          _calendar(),
          _calendar(id: 'business:cal-9', serviceId: 'business'),
        ],
      );
      final controller = _controllerFor(
        client,
        services: [
          _service(),
          _service(id: 'business'),
        ],
      );

      await controller.load();
      await controller.toggleChoreCompletion(portalRow);

      final done = _section(controller, 'doneToday');
      final todo = _section(controller, 'todoToday');

      expect(done, hasLength(1));
      expect(done.first.serviceId, 'portal');
      expect(todo, hasLength(1));
      expect(todo.first.serviceId, 'business');
    });

    test('sends the device timezone with every list request', () async {
      final client = _ScriptedHubClient(
        listResponses: [
          [_active()],
        ],
        calendars_: [_calendar()],
      );

      await _controllerFor(client).load();

      expect(client.requestedTimezones, ['Australia/Perth']);
    });

    test('a second toggle is ignored while one is in flight', () async {
      final client = _ScriptedHubClient(
        listResponses: [
          [_active()],
          [_completed()],
        ],
        completionResult: _completed(),
        calendars_: [_calendar()],
      );
      final controller = _controllerFor(client);

      await controller.load();
      final chore = controller.overview!.choreList.chores.first;

      await Future.wait([
        controller.toggleChoreCompletion(chore),
        controller.toggleChoreCompletion(chore),
      ]);

      expect(client.completeCalls, 1);
    });
  });

  group('ChoresController undo', () {
    // 8. A successful undo.
    // 19. The correct item returns to Today after undo.
    test('undo returns the occurrence to Today', () async {
      final client = _ScriptedHubClient(
        listResponses: [
          [_completed()],
          [_active()],
        ],
        undoResult: _active(),
        calendars_: [_calendar()],
      );
      final controller = _controllerFor(client);

      await controller.load();
      expect(_section(controller, 'doneToday'), hasLength(1));

      await controller.toggleChoreCompletion(
        controller.overview!.choreList.chores.first,
      );

      expect(client.undoCalls, 1);
      expect(_section(controller, 'todoToday'), hasLength(1));
      expect(_section(controller, 'doneToday'), isEmpty);
      expect(controller.syncOverlay.pendingCount, 0);
    });

    test('a stale completed row does not flash back after undo', () async {
      final client = _ScriptedHubClient(
        listResponses: [
          [_completed()],
          [_completed()], // list has not caught up with the undo yet
          [_active()],
        ],
        undoResult: _active(),
        calendars_: [_calendar()],
      );
      final controller = _controllerFor(client);

      await controller.load();
      await controller.toggleChoreCompletion(
        controller.overview!.choreList.chores.first,
      );

      expect(
        _section(controller, 'doneToday'),
        isEmpty,
        reason: 'the undone occurrence must not linger in Done today',
      );
      expect(_section(controller, 'todoToday'), hasLength(1));

      await controller.refresh();
      expect(controller.syncOverlay.pendingCount, 0);
      expect(_section(controller, 'todoToday'), hasLength(1));
    });

    // 7. A failed undo keeps the completed state.
    test('a failed undo keeps the occurrence completed', () async {
      final client = _ScriptedHubClient(
        listResponses: [
          [_completed()],
        ],
        undoError: const CaleeHubException(statusCode: 500, message: 'boom'),
        calendars_: [_calendar()],
      );
      final controller = _controllerFor(client);

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
  });

  group('ChoreSyncOverlay lifecycle cleanup', () {
    ChoreSyncOverlay overlayWithPending() {
      final overlay = ChoreSyncOverlay();
      overlay.markCompletionPending(
        key: ChoreOccurrenceKey.forChore(
          _active(),
          accountId: 'account-1',
          householdId: 'household-1',
        )!,
        chore: _completed(),
        now: DateTime.now(),
      );
      return overlay;
    }

    // 10. Logout cleanup.
    test('clear() drops everything on logout', () {
      final overlay = overlayWithPending();
      expect(overlay.pendingCount, 1);
      overlay.clear();
      expect(overlay.pendingCount, 0);
    });

    // 11. Account-switch cleanup.
    test('an account switch drops pending state', () {
      final overlay = overlayWithPending();
      overlay.retainScope(
        accountId: 'account-2',
        householdId: 'household-1',
        serviceIds: {'portal'},
        calendarIds: {'cal-1'},
      );
      expect(overlay.pendingCount, 0);
    });

    // 12. Household-switch cleanup.
    test('a household switch drops pending state', () {
      final overlay = overlayWithPending();
      overlay.retainScope(
        accountId: 'account-1',
        householdId: 'household-2',
        serviceIds: {'portal'},
        calendarIds: {'cal-1'},
      );
      expect(overlay.pendingCount, 0);
    });

    // 13. Missing service cleanup.
    test('a removed service drops pending state', () {
      final overlay = overlayWithPending();
      overlay.retainScope(
        accountId: 'account-1',
        householdId: 'household-1',
        serviceIds: {'business'},
        calendarIds: {'cal-1'},
      );
      expect(overlay.pendingCount, 0);
    });

    // 14. Missing calendar cleanup.
    test('a removed calendar drops pending state', () {
      final overlay = overlayWithPending();
      overlay.retainScope(
        accountId: 'account-1',
        householdId: 'household-1',
        serviceIds: {'portal'},
        calendarIds: {'cal-99'},
      );
      expect(overlay.pendingCount, 0);
    });

    test('an unchanged scope keeps pending state', () {
      final overlay = overlayWithPending();
      overlay.retainScope(
        accountId: 'account-1',
        householdId: 'household-1',
        serviceIds: {'portal'},
        calendarIds: {'cal-1'},
      );
      expect(overlay.pendingCount, 1);
    });

    test('an empty calendar set does not punish a failed calendars load', () {
      final overlay = overlayWithPending();
      overlay.retainScope(
        accountId: 'account-1',
        householdId: 'household-1',
        serviceIds: {'portal'},
        calendarIds: const {},
      );
      expect(overlay.pendingCount, 1);
    });

    test('an occurrence outside the loaded range is dropped', () {
      final overlay = overlayWithPending();
      final result = overlay.reconcile(
        chores: const [],
        accountId: 'account-1',
        householdId: 'household-1',
        fromDate: '2000-01-01',
        toDate: '2000-12-31',
        now: DateTime.now(),
      );

      expect(overlay.pendingCount, 0);
      expect(result.chores, isEmpty);
      expect(
        result.expiredKeys,
        isEmpty,
        reason: 'out-of-range is not a sync failure, just out of scope',
      );
    });

    test('disposing the controller clears held state', () async {
      final client = _ScriptedHubClient(
        listResponses: [
          [_active()],
          const <ClientChore>[],
        ],
        completionResult: _completed(),
        calendars_: [_calendar()],
      );
      final controller = _controllerFor(client);

      await controller.load();
      await controller.toggleChoreCompletion(
        controller.overview!.choreList.chores.first,
      );
      expect(controller.syncOverlay.pendingCount, 1);

      controller.dispose();
      expect(controller.syncOverlay.pendingCount, 0);
    });

    test('clearSyncState() drops the overlay and the sync error', () async {
      final client = _ScriptedHubClient(
        listResponses: [
          [_active()],
          const <ClientChore>[],
        ],
        completionResult: _completed(),
        calendars_: [_calendar()],
      );
      final controller = _controllerFor(client, window: Duration.zero);

      await controller.load();
      await controller.toggleChoreCompletion(
        controller.overview!.choreList.chores.first,
      );
      expect(controller.syncError, isNotNull);

      controller.clearSyncState();
      expect(controller.syncError, isNull);
      expect(controller.syncOverlay.pendingCount, 0);
    });
  });
}
