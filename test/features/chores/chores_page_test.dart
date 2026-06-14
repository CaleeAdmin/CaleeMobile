// Widget tests for ChoresPage top bar.
//
// Verifies the chores screen shows Search, Filter, and Add actions and that the
// top label reflects the active filter ("All chores") without showing counts.

import 'package:calee_mobile/data/api/calee_hub_client.dart';
import 'package:calee_mobile/data/models/client_bootstrap.dart';
import 'package:calee_mobile/data/models/client_calendar.dart';
import 'package:calee_mobile/data/models/client_chore.dart';
import 'package:calee_mobile/data/models/client_person.dart';
import 'package:calee_mobile/features/chores/chores_page.dart';
import 'package:calee_mobile/ui/calee_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

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

Widget _wrap() => MaterialApp(
  theme: CaleeTheme.buildThemeData(),
  home: ChoresPage(
    hubClient: _StubHubClient(),
    accessToken: 'tok',
    services: const [_service],
    households: const [
      ClientContext(
        id: 'h1',
        type: 'household',
        name: 'My Family',
        role: 'admin',
        status: 'active',
      ),
    ],
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
}
