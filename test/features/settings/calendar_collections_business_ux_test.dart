// Widget tests verifying that CalendarCollectionsPage ("Lists & calendars")
// hides the Chore lists section — and the "Chore list" create option — for
// business/workspace accounts, matching the Chores/Meals/People gating done
// via ClientBootstrap.isFamilyUxContext elsewhere in the app.

import 'package:calee_mobile/data/api/calee_hub_client.dart';
import 'package:calee_mobile/data/models/client_bootstrap.dart';
import 'package:calee_mobile/data/models/client_calendar.dart';
import 'package:calee_mobile/features/settings/calendar_collections_page.dart';
import 'package:calee_mobile/ui/calee_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _StubHubClient extends CaleeHubClient {
  _StubHubClient({this.calendarsToReturn = const []})
    : super(baseUri: Uri.parse('http://localhost'));

  final List<ClientCalendar> calendarsToReturn;

  @override
  Future<ClientCalendarList> calendars({required String accessToken}) async {
    return ClientCalendarList(calendars: calendarsToReturn);
  }
}

ClientService _calendarService() => ClientService(
  id: 'svc1',
  displayName: 'My Nextcloud',
  baseUrl: 'http://localhost',
  launchUrl: 'http://localhost',
  serviceType: 'nextcloud_calendar',
  accessStatus: 'connected',
  calendarCredentialStatus: 'connected',
  source: 'test',
  capabilities: const {'calendar': true, 'tasks': true, 'chores': true},
);

ClientCalendar _calendar({required String id, required String kind}) =>
    ClientCalendar(
      id: id,
      serviceId: 'svc1',
      serviceName: 'My Nextcloud',
      name: 'Leftover chores',
      components: const [],
      primaryKind: kind,
      supportsEvents: kind == 'calendar',
      supportsTasks: kind == 'tasks',
      supportsChores: kind == 'chores',
      readOnly: false,
      isSubscription: false,
      source: 'calee',
    );

Widget _wrap({
  required bool isFamilyUxContext,
  List<ClientCalendar> calendars = const [],
  bool autoOpenCreate = false,
}) => MaterialApp(
  theme: CaleeTheme.buildThemeData(),
  home: CalendarCollectionsPage(
    hubClient: _StubHubClient(calendarsToReturn: calendars),
    accessToken: 'tok',
    services: [_calendarService()],
    accountId: 'acct1',
    isFamilyUxContext: isFamilyUxContext,
    autoOpenCreate: autoOpenCreate,
  ),
);

void main() {
  group('Chore lists section — business/workspace visibility', () {
    testWidgets('shown for family/household accounts', (tester) async {
      await tester.pumpWidget(_wrap(isFamilyUxContext: true));
      await tester.pumpAndSettle();

      // CaleeSection renders titles upper-cased (see calee_widgets.dart).
      expect(find.text('CHORE LISTS'), findsOneWidget);
      expect(find.text('No chore lists yet.'), findsOneWidget);
      // Unrelated sections are unaffected.
      expect(find.text('CALENDARS'), findsOneWidget);
      expect(find.text('TASK LISTS'), findsOneWidget);
    });

    testWidgets('hidden for business/workspace accounts', (tester) async {
      await tester.pumpWidget(_wrap(isFamilyUxContext: false));
      await tester.pumpAndSettle();

      expect(find.text('CHORE LISTS'), findsNothing);
      expect(find.text('No chore lists yet.'), findsNothing);
      // Unrelated sections are unaffected and still load correctly.
      expect(find.text('CALENDARS'), findsOneWidget);
      expect(find.text('TASK LISTS'), findsOneWidget);
    });

    testWidgets(
      'an existing chore calendar is not shown for business/workspace accounts',
      (tester) async {
        await tester.pumpWidget(
          _wrap(
            isFamilyUxContext: false,
            calendars: [_calendar(id: 'cal1', kind: 'chores')],
          ),
        );
        await tester.pumpAndSettle();

        // Confirms the page actually finished loading (not just an empty
        // build), so the findsNothing checks below are meaningful.
        expect(find.text('CALENDARS'), findsOneWidget);
        expect(find.text('CHORE LISTS'), findsNothing);
        expect(find.text('Leftover chores'), findsNothing);
      },
    );
  });

  group('Create sheet Type dropdown — business/workspace visibility', () {
    testWidgets('offers "Chore list" for family/household accounts', (
      tester,
    ) async {
      await tester.pumpWidget(
        _wrap(isFamilyUxContext: true, autoOpenCreate: true),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byType(DropdownButtonFormField<String>));
      await tester.pumpAndSettle();

      expect(find.text('Chore list'), findsOneWidget);
    });

    testWidgets('omits "Chore list" for business/workspace accounts', (
      tester,
    ) async {
      await tester.pumpWidget(
        _wrap(isFamilyUxContext: false, autoOpenCreate: true),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byType(DropdownButtonFormField<String>));
      await tester.pumpAndSettle();

      expect(find.text('Chore list'), findsNothing);
      // Calendar and Task list remain selectable.
      expect(find.text('Task list'), findsOneWidget);
    });
  });
}
