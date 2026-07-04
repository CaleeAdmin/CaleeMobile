// Widget tests verifying that calendar service connection errors are surfaced
// in CalendarCollectionsPage instead of showing "No calendars yet." empty state.

import 'package:calee_mobile/data/api/calee_hub_client.dart';
import 'package:calee_mobile/data/models/calendar_service_error.dart';
import 'package:calee_mobile/data/models/client_bootstrap.dart';
import 'package:calee_mobile/data/models/client_calendar.dart';
import 'package:calee_mobile/features/calendar/widgets/calendar_error_state.dart';
import 'package:calee_mobile/features/settings/calendar_collections_page.dart';
import 'package:calee_mobile/ui/calee_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _StubHubClient extends CaleeHubClient {
  _StubHubClient({required this.calendarsResult})
    : super(baseUri: Uri.parse('http://localhost'));

  final Future<ClientCalendarList> Function() calendarsResult;

  @override
  Future<ClientCalendarList> calendars({required String accessToken}) =>
      calendarsResult();
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
  capabilities: const {'calendar': true, 'tasks': true, 'chores': false},
);

ClientCalendar _calendar({String id = 'cal1', String kind = 'calendar'}) =>
    ClientCalendar(
      id: id,
      serviceId: 'svc1',
      serviceName: 'My Nextcloud',
      name: 'Personal',
      components: const [],
      primaryKind: kind,
      supportsEvents: true,
      supportsTasks: false,
      supportsChores: false,
      readOnly: false,
      isSubscription: false,
      source: 'calee',
    );

Widget _wrap(_StubHubClient client) => MaterialApp(
  theme: CaleeTheme.buildThemeData(),
  home: CalendarCollectionsPage(
    hubClient: client,
    accessToken: 'tok',
    services: [_calendarService()],
    accountId: 'acct1',
    isFamilyUxContext: true,
  ),
);

void main() {
  testWidgets(
    'BUSINESS_CALENDAR_CONNECTION_BROKEN exception shows error state, not empty',
    (tester) async {
      final client = _StubHubClient(
        calendarsResult: () => Future.error(
          const CaleeHubException(
            statusCode: 503,
            message: 'Calendar service unavailable',
            code: 'BUSINESS_CALENDAR_CONNECTION_BROKEN',
            serviceId: 'svc1',
            serviceName: 'My Nextcloud',
          ),
        ),
      );
      await tester.pumpWidget(_wrap(client));
      await tester.pumpAndSettle();

      expect(find.byType(CalendarServiceConnectionErrorState), findsOneWidget);
      expect(find.text('No calendars yet.'), findsNothing);
    },
  );

  testWidgets(
    'True empty list shows "No calendars yet." with no error widgets',
    (tester) async {
      final client = _StubHubClient(
        calendarsResult: () async =>
            const ClientCalendarList(calendars: [], serviceErrors: []),
      );
      await tester.pumpWidget(_wrap(client));
      await tester.pumpAndSettle();

      expect(find.text('No calendars yet.'), findsOneWidget);
      expect(find.byType(CalendarServiceConnectionErrorState), findsNothing);
      expect(find.byType(CalendarServiceWarningBanner), findsNothing);
    },
  );

  testWidgets(
    'Response with only serviceErrors and no calendars shows full error state',
    (tester) async {
      final client = _StubHubClient(
        calendarsResult: () async => ClientCalendarList(
          calendars: const [],
          serviceErrors: const [
            CalendarServiceError(
              code: 'CALENDAR_SERVICE_CONNECTION_BROKEN',
              serviceId: 'svc1',
              serviceName: 'My Nextcloud',
            ),
          ],
        ),
      );
      await tester.pumpWidget(_wrap(client));
      await tester.pumpAndSettle();

      expect(find.byType(CalendarServiceConnectionErrorState), findsOneWidget);
      expect(find.text('No calendars yet.'), findsNothing);
    },
  );

  testWidgets('Partial failure shows warning banner and available calendars', (
    tester,
  ) async {
    final client = _StubHubClient(
      calendarsResult: () async => ClientCalendarList(
        calendars: [_calendar()],
        serviceErrors: const [
          CalendarServiceError(
            code: 'CALENDAR_SERVICE_CONNECTION_BROKEN',
            serviceId: 'svc2',
            serviceName: 'Other Service',
          ),
        ],
      ),
    );
    await tester.pumpWidget(_wrap(client));
    await tester.pumpAndSettle();

    expect(find.byType(CalendarServiceWarningBanner), findsOneWidget);
    expect(find.byType(CalendarServiceConnectionErrorState), findsNothing);
    expect(find.text('Personal'), findsOneWidget);
  });

  testWidgets('SERVICE_CREDENTIAL_INVALID exception shows error state', (
    tester,
  ) async {
    final client = _StubHubClient(
      calendarsResult: () => Future.error(
        const CaleeHubException(
          statusCode: 401,
          message: 'Credential invalid',
          code: 'SERVICE_CREDENTIAL_INVALID',
          serviceId: 'svc1',
          serviceName: 'My Nextcloud',
        ),
      ),
    );
    await tester.pumpWidget(_wrap(client));
    await tester.pumpAndSettle();

    expect(find.byType(CalendarServiceConnectionErrorState), findsOneWidget);
    expect(find.text('No calendars yet.'), findsNothing);
  });

  testWidgets(
    'Generic network error shows "Unable to load", not service error state',
    (tester) async {
      final client = _StubHubClient(
        calendarsResult: () => Future.error(Exception('Network error')),
      );
      await tester.pumpWidget(_wrap(client));
      await tester.pumpAndSettle();

      expect(find.text('Unable to load'), findsOneWidget);
      expect(find.byType(CalendarServiceConnectionErrorState), findsNothing);
    },
  );
}
