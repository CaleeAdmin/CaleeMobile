// Widget tests for the "Connected calendars" management entry point on
// CalendarCollectionsPage: discovering an active Google Calendar connection
// and disconnecting it via the existing GoogleCalendarSelectionPage.

import 'package:calee_mobile/data/api/calee_hub_client.dart';
import 'package:calee_mobile/data/models/client_calendar.dart';
import 'package:calee_mobile/data/models/external_calendar_connection.dart';
import 'package:calee_mobile/features/calendar_onboarding/provider_guides/google_calendar_selection_page.dart';
import 'package:calee_mobile/features/settings/calendar_collections_page.dart';
import 'package:calee_mobile/ui/calee_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

// ── Stub ─────────────────────────────────────────────────────────────────────

class _StubHubClient extends CaleeHubClient {
  _StubHubClient({
    List<ExternalCalendarConnection>? connections,
    this._externalCalendarsError,
  }) : _connections = connections ?? [],
       super(baseUri: Uri.parse('http://localhost'));

  List<ExternalCalendarConnection> _connections;
  final Object Function()? _externalCalendarsError;
  int disconnectCallCount = 0;
  String? lastDisconnectedConnectionId;

  @override
  Future<ClientCalendarList> calendars({required String accessToken}) async {
    return const ClientCalendarList(calendars: []);
  }

  @override
  Future<List<ExternalCalendarConnection>> externalCalendarConnections({
    required String accessToken,
  }) async {
    return _connections;
  }

  @override
  Future<List<ExternalCalendar>> externalCalendarsForConnection({
    required String accessToken,
    required String connectionId,
  }) async {
    final error = _externalCalendarsError;
    if (error != null) throw error();
    return const [];
  }

  @override
  Future<void> disconnectExternalCalendarConnection({
    required String accessToken,
    required String connectionId,
  }) async {
    disconnectCallCount++;
    lastDisconnectedConnectionId = connectionId;
    _connections = _connections.where((c) => c.id != connectionId).toList();
  }
}

// ── Helpers ──────────────────────────────────────────────────────────────────

ExternalCalendarConnection _googleConnection({
  String id = 'conn1',
  String? email,
  bool active = true,
}) => ExternalCalendarConnection.fromJson({
  'id': id,
  'providerKey': 'google_calendar',
  'displayName': 'Google Calendar',
  'externalAccountEmail': email,
  'connectionStatus': active ? 'active' : 'needs_attention',
  'accessMode': 'read_only',
  'sourceOfTruthPolicy': 'external',
});

Widget _wrap(_StubHubClient hubClient) => MaterialApp(
  theme: CaleeTheme.buildThemeData(),
  home: CalendarCollectionsPage(
    hubClient: hubClient,
    accessToken: 'tok',
    services: const [],
    accountId: 'acct1',
    isFamilyUxContext: true,
  ),
);

// ── Tests ──────────────────────────────────────────────────────────────────────

void main() {
  testWidgets('shows Connected calendars section when a Google '
      'connection exists', (tester) async {
    final client = _StubHubClient(connections: [_googleConnection()]);
    await tester.pumpWidget(_wrap(client));
    await tester.pumpAndSettle();

    expect(find.text('CONNECTED CALENDARS'), findsOneWidget);
    expect(find.text('Google Calendar'), findsOneWidget);
  });

  testWidgets('shows the connected Google account email when available', (
    tester,
  ) async {
    final client = _StubHubClient(
      connections: [_googleConnection(email: 'user@gmail.com')],
    );
    await tester.pumpWidget(_wrap(client));
    await tester.pumpAndSettle();

    expect(find.text('user@gmail.com'), findsOneWidget);
  });

  testWidgets('shows a fallback subtitle when no email is available', (
    tester,
  ) async {
    final client = _StubHubClient(connections: [_googleConnection()]);
    await tester.pumpWidget(_wrap(client));
    await tester.pumpAndSettle();

    expect(find.text('Connected'), findsOneWidget);
  });

  testWidgets('tapping the Google row opens GoogleCalendarSelectionPage', (
    tester,
  ) async {
    final client = _StubHubClient(connections: [_googleConnection()]);
    await tester.pumpWidget(_wrap(client));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Google Calendar'));
    await tester.pumpAndSettle();

    expect(find.byType(GoogleCalendarSelectionPage), findsOneWidget);
  });

  testWidgets('disconnect calls disconnectExternalCalendarConnection and '
      'refreshes the list', (tester) async {
    final client = _StubHubClient(
      connections: [_googleConnection(id: 'conn42')],
    );
    await tester.pumpWidget(_wrap(client));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Google Calendar'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Disconnect Google Calendar'));
    await tester.pumpAndSettle();

    // Confirm the destructive dialog.
    await tester.tap(find.text('Disconnect'));
    await tester.pumpAndSettle();

    expect(client.disconnectCallCount, 1);
    expect(client.lastDisconnectedConnectionId, 'conn42');

    // Disconnect pops back to the CalendarCollectionsPage root and the
    // Google connection should no longer be listed.
    expect(find.byType(CalendarCollectionsPage), findsOneWidget);
    expect(find.text('No connected calendar accounts'), findsOneWidget);
    expect(find.text('Google Calendar'), findsNothing);
  });

  testWidgets('shows empty state when there are no external '
      'calendar connections', (tester) async {
    final client = _StubHubClient(connections: const []);
    await tester.pumpWidget(_wrap(client));
    await tester.pumpAndSettle();

    expect(find.text('CONNECTED CALENDARS'), findsOneWidget);
    expect(find.text('No connected calendar accounts'), findsOneWidget);
  });

  testWidgets(
    'a needs-attention Google connection can still be disconnected when '
    'loading its calendars fails',
    (tester) async {
      final client = _StubHubClient(
        connections: [_googleConnection(id: 'conn99', active: false)],
        externalCalendarsError: () => const CaleeHubException(
          statusCode: 409,
          message: 'Google connection is no longer active. Please reconnect.',
          code: 'CONNECTION_NOT_ACTIVE',
        ),
      );
      await tester.pumpWidget(_wrap(client));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Google Calendar'));
      await tester.pumpAndSettle();

      expect(
        find.text('Google connection is no longer active. Please reconnect.'),
        findsOneWidget,
      );
      expect(find.text('Disconnect Google Calendar'), findsOneWidget);

      await tester.tap(find.text('Disconnect Google Calendar'));
      await tester.pumpAndSettle();

      // Confirm the destructive dialog.
      await tester.tap(find.text('Disconnect'));
      await tester.pumpAndSettle();

      expect(client.disconnectCallCount, 1);
      expect(client.lastDisconnectedConnectionId, 'conn99');

      // Disconnect pops back to the CalendarCollectionsPage root and the
      // connected calendars section refreshes to reflect the removal.
      expect(find.byType(CalendarCollectionsPage), findsOneWidget);
      expect(find.text('No connected calendar accounts'), findsOneWidget);
      expect(find.text('Google Calendar'), findsNothing);
    },
  );
}
