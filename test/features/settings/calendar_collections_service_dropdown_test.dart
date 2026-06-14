// Widget tests for the "Create list or calendar" service dropdown gating.
//
// The Service dropdown should only appear when there are two or more connected
// calendar services to choose from. With a single service it is hidden because
// there is nothing to choose.

import 'package:calee_mobile/data/api/calee_hub_client.dart';
import 'package:calee_mobile/data/models/client_bootstrap.dart';
import 'package:calee_mobile/data/models/client_calendar.dart';
import 'package:calee_mobile/features/settings/calendar_collections_page.dart';
import 'package:calee_mobile/ui/calee_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _StubHubClient extends CaleeHubClient {
  _StubHubClient() : super(baseUri: Uri.parse('http://localhost'));

  @override
  Future<ClientCalendarList> calendars({required String accessToken}) async {
    return const ClientCalendarList(calendars: []);
  }
}

ClientService _calendarService(String id) => ClientService(
  id: id,
  displayName: 'Service $id',
  baseUrl: 'http://localhost',
  launchUrl: 'http://localhost',
  serviceType: 'nextcloud_calendar',
  accessStatus: 'connected',
  calendarCredentialStatus: 'connected',
  source: 'test',
  capabilities: const {'calendar': true, 'tasks': true, 'chores': false},
);

Widget _wrap(List<ClientService> services) => MaterialApp(
  theme: CaleeTheme.buildThemeData(),
  home: CalendarCollectionsPage(
    hubClient: _StubHubClient(),
    accessToken: 'tok',
    services: services,
    autoOpenCreate: true,
  ),
);

void main() {
  testWidgets('Service dropdown is hidden for a single service', (
    tester,
  ) async {
    await tester.pumpWidget(_wrap([_calendarService('a')]));
    await tester.pumpAndSettle();

    // Create sheet is open (Name field is present) but no Service dropdown.
    expect(find.text('Name'), findsOneWidget);
    expect(find.text('Service'), findsNothing);
  });

  testWidgets('Service dropdown appears for multiple services', (tester) async {
    await tester.pumpWidget(
      _wrap([_calendarService('a'), _calendarService('b')]),
    );
    await tester.pumpAndSettle();

    expect(find.text('Service'), findsOneWidget);
  });
}
