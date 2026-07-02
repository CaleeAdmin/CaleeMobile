// Widget tests for ChoresPage top bar and chore action sheet.

import 'package:calee_mobile/data/api/calee_hub_client.dart';
import 'package:calee_mobile/data/models/client_bootstrap.dart';
import 'package:calee_mobile/data/models/client_calendar.dart';
import 'package:calee_mobile/data/models/client_chore.dart';
import 'package:calee_mobile/data/models/client_person.dart';
import 'package:calee_mobile/features/chores/chores_page.dart';
import 'package:calee_mobile/features/chores/widgets/chore_row.dart';
import 'package:calee_mobile/ui/calee_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

// ── Stubs ─────────────────────────────────────────────────────────────────────

class _StubHubClient extends CaleeHubClient {
  _StubHubClient() : super(baseUri: Uri.parse('http://localhost'));

  @override
  Future<ClientCalendarList> calendars({required String accessToken}) async {
    return const ClientCalendarList(
      calendars: [
        ClientCalendar(
          id: 'svc1:chores1',
          serviceId: 'svc1',
          serviceName: 'Test Service',
          name: 'Chores',
          components: ['VTODO'],
          primaryKind: 'chores',
          supportsEvents: false,
          supportsTasks: false,
          supportsChores: true,
          readOnly: false,
          isSubscription: false,
          source: 'test',
        ),
      ],
    );
  }

  @override
  Future<ClientChoreList> chores({
    required String accessToken,
    required String from,
    required String to,
  }) async {
    return ClientChoreList(from: from, to: to, chores: const []);
  }

  @override
  Future<ClientPersonList> people({
    required String accessToken,
    required String householdId,
    bool includeArchived = false,
  }) async {
    return const ClientPersonList(people: []);
  }
}

const _service = ClientService(
  id: 'svc1',
  displayName: 'Test Service',
  baseUrl: 'http://localhost',
  launchUrl: 'http://localhost',
  serviceType: 'nextcloud',
  accessStatus: 'connected',
  calendarCredentialStatus: 'connected',
  source: 'test',
  capabilities: {'calendar': true, 'tasks': true, 'chores': true},
);

class _StubHubClientWithChore extends CaleeHubClient {
  _StubHubClientWithChore({required this.chore})
    : super(baseUri: Uri.parse('http://localhost'));

  final ClientChore chore;

  @override
  Future<ClientCalendarList> calendars({required String accessToken}) async {
    return const ClientCalendarList(
      calendars: [
        ClientCalendar(
          id: 'svc1:chores1',
          serviceId: 'svc1',
          serviceName: 'Test Service',
          name: 'Chores',
          components: ['VTODO'],
          primaryKind: 'chores',
          supportsEvents: false,
          supportsTasks: false,
          supportsChores: true,
          readOnly: false,
          isSubscription: false,
          source: 'test',
        ),
      ],
    );
  }

  @override
  Future<ClientChoreList> chores({
    required String accessToken,
    required String from,
    required String to,
  }) async {
    return ClientChoreList(from: from, to: to, chores: [chore]);
  }

  @override
  Future<ClientPersonList> people({
    required String accessToken,
    required String householdId,
    bool includeArchived = false,
  }) async {
    return const ClientPersonList(people: []);
  }
}

// ── Helpers ───────────────────────────────────────────────────────────────────

const _households = [
  ClientContext(
    id: 'h1',
    type: 'household',
    name: 'My Family',
    role: 'admin',
    status: 'active',
  ),
];

ClientChore _incompleteChore() => ClientChore(
  id: 'c1',
  calendarId: 'svc1:chores1',
  serviceId: 'svc1',
  serviceName: 'Test Service',
  title: 'Wash dishes',
  scheduledAt: null,
  scheduledDate: null,
  description: null,
  source: '',
  kind: 'baseChore',
  choreUid: 'uid-1',
  parentChoreUid: null,
  completionLogId: null,
  completedToday: false,
  section: 'todoToday',
  recurrence: null,
  points: 1,
  metadataPoints: null,
  assigneePersonId: null,
  assigneeName: null,
  assigneeAvatarColor: null,
  approvalState: 'none',
);

ClientChore _futureChore() {
  final tomorrow = DateTime.now().add(const Duration(days: 1));
  final dateStr =
      '${tomorrow.year}-${tomorrow.month.toString().padLeft(2, '0')}-${tomorrow.day.toString().padLeft(2, '0')}';
  return ClientChore(
    id: 'c-future-1',
    calendarId: 'svc1:chores1',
    serviceId: 'svc1',
    serviceName: 'Test Service',
    title: 'Future chore',
    scheduledAt: null,
    scheduledDate: dateStr,
    description: null,
    source: '',
    kind: 'baseChore',
    choreUid: 'uid-future-1',
    parentChoreUid: null,
    completionLogId: null,
    completedToday: false,
    section: 'future',
    recurrence: null,
    points: 1,
    metadataPoints: null,
    assigneePersonId: null,
    assigneeName: null,
    assigneeAvatarColor: null,
    approvalState: 'none',
  );
}

ClientChore _completedChore() => ClientChore(
  id: 'c1',
  calendarId: 'svc1:chores1',
  serviceId: 'svc1',
  serviceName: 'Test Service',
  title: 'Wash dishes',
  scheduledAt: null,
  scheduledDate: null,
  description: null,
  source: '',
  kind: 'baseChore',
  choreUid: 'uid-1',
  parentChoreUid: null,
  completionLogId: null,
  completedToday: true,
  section: 'todoToday',
  recurrence: null,
  points: 1,
  metadataPoints: null,
  assigneePersonId: null,
  assigneeName: null,
  assigneeAvatarColor: null,
  approvalState: 'none',
);

Widget _wrap() => MaterialApp(
  theme: CaleeTheme.buildThemeData(),
  home: ChoresPage(
    hubClient: _StubHubClient(),
    accessToken: 'tok',
    services: const [_service],
    households: _households,
    accountId: 'acct1',
  ),
);

Widget _wrapWithChore(ClientChore chore) => MaterialApp(
  theme: CaleeTheme.buildThemeData(),
  home: ChoresPage(
    hubClient: _StubHubClientWithChore(chore: chore),
    accessToken: 'tok',
    services: const [_service],
    households: _households,
    accountId: 'acct1',
  ),
);

void main() {
  testWidgets('Chores top bar shows Search, Filter, and Add actions', (
    tester,
  ) async {
    await tester.pumpWidget(_wrap());
    await tester.pumpAndSettle();

    expect(find.byTooltip('Search chores'), findsOneWidget);
    expect(find.byTooltip('Filter chores'), findsOneWidget);
    expect(find.byTooltip('Add chore'), findsOneWidget);
  });

  testWidgets('Chores top label is "All chores" and shows no count', (
    tester,
  ) async {
    await tester.pumpWidget(_wrap());
    await tester.pumpAndSettle();

    expect(find.text('All chores'), findsOneWidget);
    // The label must not append a count such as "All chores (0)".
    expect(find.textContaining('All chores ('), findsNothing);
  });

  group('Future section circle tap', () {
    testWidgets('tapping circle on a tomorrow chore fires completion toggle', (
      tester,
    ) async {
      var tapCount = 0;
      final chore = _futureChore();
      await tester.pumpWidget(
        MaterialApp(
          theme: CaleeTheme.buildThemeData(),
          home: Scaffold(
            body: ChoreRow(
              chore: chore,
              calendarName: 'Chores',
              scheduledLabel: '',
              isUpdating: false,
              onToggleCompletion: () => tapCount++,
              onCircleTap: null,
              onMoreTap: null,
              onRowTap: null,
            ),
          ),
        ),
      );

      await tester.tap(find.byIcon(Icons.radio_button_unchecked));
      await tester.pump();

      expect(tapCount, 1);
    });

    testWidgets(
      'tapping circle on tomorrow chore via ChoresPage fires toggle not action sheet',
      (tester) async {
        await tester.pumpWidget(_wrapWithChore(_futureChore()));
        await tester.pumpAndSettle();

        // The circle for the future chore should trigger completion, not open
        // the action sheet (which would show 'Edit chore').
        await tester.tap(find.byIcon(Icons.radio_button_unchecked));
        await tester.pumpAndSettle();

        expect(find.text('Edit chore'), findsNothing);
      },
    );

    testWidgets('tapping row body of tomorrow chore opens action sheet', (
      tester,
    ) async {
      await tester.pumpWidget(_wrapWithChore(_futureChore()));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Future chore'));
      await tester.pumpAndSettle();

      expect(find.text('Edit chore'), findsOneWidget);
    });

    testWidgets(
      'incomplete future chore action sheet does not show "Mark done"',
      (tester) async {
        await tester.pumpWidget(_wrapWithChore(_futureChore()));
        await tester.pumpAndSettle();

        await tester.tap(find.text('Future chore'));
        await tester.pumpAndSettle();

        expect(find.text('Mark done'), findsNothing);
        expect(find.text('Mark as not done'), findsNothing);
      },
    );
  });

  group('Today section circle tap', () {
    testWidgets(
      'tapping circle fires onToggleCompletion for incomplete chore',
      (tester) async {
        var tapCount = 0;
        await tester.pumpWidget(
          MaterialApp(
            theme: CaleeTheme.buildThemeData(),
            home: Scaffold(
              body: ChoreRow(
                chore: _incompleteChore(),
                calendarName: 'Chores',
                scheduledLabel: '',
                isUpdating: false,
                onToggleCompletion: () => tapCount++,
              ),
            ),
          ),
        );

        await tester.tap(find.byIcon(Icons.radio_button_unchecked));
        await tester.pump();

        expect(tapCount, 1);
      },
    );
  });

  group('Chore action sheet', () {
    testWidgets(
      'completed chore shows "Mark as not done" and not "Mark done"',
      (tester) async {
        await tester.pumpWidget(_wrapWithChore(_completedChore()));
        await tester.pumpAndSettle();

        await tester.tap(find.text('Show completed chores'));
        await tester.pumpAndSettle();

        await tester.tap(find.byIcon(Icons.more_horiz));
        await tester.pumpAndSettle();

        expect(find.text('Mark as not done'), findsOneWidget);
        expect(find.text('Mark done'), findsNothing);
        expect(find.text('Undo done'), findsNothing);
      },
    );

    testWidgets('incomplete chore does not show "Mark done" in action sheet', (
      tester,
    ) async {
      await tester.pumpWidget(_wrapWithChore(_incompleteChore()));
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(Icons.more_horiz));
      await tester.pumpAndSettle();

      expect(find.text('Mark done'), findsNothing);
      expect(find.text('Mark as not done'), findsNothing);
    });

    testWidgets('action sheet does not show delete actions', (tester) async {
      await tester.pumpWidget(_wrapWithChore(_incompleteChore()));
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(Icons.more_horiz));
      await tester.pumpAndSettle();

      expect(find.text('Delete chore'), findsNothing);
      expect(find.text('Delete permanently'), findsNothing);
    });
  });
}
