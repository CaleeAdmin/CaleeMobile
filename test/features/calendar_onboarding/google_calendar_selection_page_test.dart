// Widget tests for GoogleCalendarSelectionPage.
//
// Uses a stub CaleeHubClient to avoid real network calls.

import 'package:calee_mobile/data/api/calee_hub_client.dart';
import 'package:calee_mobile/data/models/external_calendar_connection.dart';
import 'package:calee_mobile/features/calendar_onboarding/provider_guides/google_calendar_selection_page.dart';
import 'package:calee_mobile/ui/calee_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ── Stubs ─────────────────────────────────────────────────────────────────────

class _StubHubClient extends CaleeHubClient {
  _StubHubClient({
    List<ExternalCalendar>? calendars,
    this._syncShouldFail = false,
    this._disconnectShouldFail = false,
  }) : _calendars = calendars ?? [],
       super(baseUri: Uri.parse('http://localhost'));

  final List<ExternalCalendar> _calendars;
  final bool _syncShouldFail;
  final bool _disconnectShouldFail;

  @override
  Future<List<ExternalCalendar>> externalCalendarsForConnection({
    required String accessToken,
    required String connectionId,
  }) async {
    return _calendars;
  }

  @override
  Future<ExternalCalendar> updateExternalCalendar({
    required String accessToken,
    required String externalCalendarId,
    bool? syncEnabled,
    String? displayName,
    String? color,
    ExternalCalendarPrivacySettings? privacySettings,
  }) async {
    final cal = _calendars.firstWhere((c) => c.id == externalCalendarId);
    return ExternalCalendar.fromJson({
      'id': cal.id,
      'providerKey': cal.providerKey,
      'externalCalendarId': cal.externalCalendarId,
      'displayName': cal.displayName,
      'providerDisplayName': cal.providerDisplayName,
      'syncEnabled': syncEnabled ?? cal.syncEnabled,
      'visibilityStatus': cal.visibilityStatus,
      'accessMode': cal.accessMode,
      'sourceOfTruthPolicy': cal.sourceOfTruthPolicy,
      'syncStatus': cal.syncStatus,
    });
  }

  @override
  Future<ExternalCalendarSyncResult> syncExternalCalendarNow({
    required String accessToken,
    required String externalCalendarId,
  }) async {
    if (_syncShouldFail) {
      throw const CaleeHubException(
        statusCode: 500,
        message: 'Sync failed',
        code: 'GOOGLE_EVENTS_FAILED',
      );
    }
    return const ExternalCalendarSyncResult(
      status: 'ok',
      mode: 'full',
      eventCount: 10,
      deletedCount: 0,
      nextSyncAvailable: true,
    );
  }

  @override
  Future<void> disconnectExternalCalendarConnection({
    required String accessToken,
    required String connectionId,
  }) async {
    if (_disconnectShouldFail) {
      throw const CaleeHubException(
        statusCode: 500,
        message: 'Disconnect failed',
      );
    }
  }
}

// ── Test helpers ──────────────────────────────────────────────────────────────

ExternalCalendarConnection _activeConnection({
  String? email,
}) => ExternalCalendarConnection.fromJson({
  'id': 'conn1',
  'providerKey': 'google_calendar',
  'displayName': 'Google Calendar',
  'externalAccountEmail': email,
  'connectionStatus': 'active',
  'accessMode': 'read_only',
  'sourceOfTruthPolicy': 'external',
});

ExternalCalendar _fakeCalendar({
  String id = 'cal1',
  String displayName = 'Personal',
  bool syncEnabled = true,
}) => ExternalCalendar.fromJson({
  'id': id,
  'providerKey': 'google_calendar',
  'externalCalendarId': id,
  'displayName': displayName,
  'providerDisplayName': 'Google Calendar',
  'syncEnabled': syncEnabled,
  'visibilityStatus': 'visible',
  'accessMode': 'read_only',
  'sourceOfTruthPolicy': 'external',
  'syncStatus': 'ok',
});

Widget _wrapPage({
  CaleeHubClient? hubClient,
  ExternalCalendarConnection? connection,
  VoidCallback? onDone,
  VoidCallback? onViewCalendar,
}) => MaterialApp(
  theme: CaleeTheme.buildThemeData(),
  home: GoogleCalendarSelectionPage(
    hubClient: hubClient ?? _StubHubClient(),
    accessToken: 'token',
    connection: connection ?? _activeConnection(),
    onDone: onDone ?? () {},
    onViewCalendar: onViewCalendar ?? () {},
  ),
);

void _setUpSharedPrefs() {
  SharedPreferences.setMockInitialValues({
    'calee_pref_migrated_to_shared_prefs': true,
  });
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
        const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
        (call) async => <String, String>{},
      );
}

void _tearDownSharedPrefs() {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
        const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
        null,
      );
}

// ── Tests ─────────────────────────────────────────────────────────────────────

void main() {
  setUp(_setUpSharedPrefs);
  tearDown(_tearDownSharedPrefs);

  testWidgets('shows introductory heading', (tester) async {
    await tester.pumpWidget(_wrapPage());
    await tester.pump(const Duration(milliseconds: 50));

    expect(
      find.textContaining('Choose which Google calendars to show'),
      findsOneWidget,
    );
  });

  testWidgets('shows account email when provided', (tester) async {
    await tester.pumpWidget(
      _wrapPage(connection: _activeConnection(email: 'user@gmail.com')),
    );
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text('user@gmail.com'), findsOneWidget);
  });

  testWidgets('shows fallback label when account email is absent', (
    tester,
  ) async {
    await tester.pumpWidget(
      _wrapPage(connection: _activeConnection(email: null)),
    );
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text('Google Calendar connected'), findsOneWidget);
  });

  testWidgets('shows calendar row with display name', (tester) async {
    final client = _StubHubClient(
      calendars: [_fakeCalendar(displayName: 'Work')],
    );
    await tester.pumpWidget(_wrapPage(hubClient: client));
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text('Work'), findsOneWidget);
  });

  testWidgets('shows Read-only from Google label on calendar row', (
    tester,
  ) async {
    final client = _StubHubClient(
      calendars: [_fakeCalendar(displayName: 'Personal')],
    );
    await tester.pumpWidget(_wrapPage(hubClient: client));
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text('Read-only from Google'), findsOneWidget);
  });

  testWidgets('shows Sync selected calendars now button', (tester) async {
    await tester.pumpWidget(_wrapPage());
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text('Sync selected calendars now'), findsOneWidget);
  });

  testWidgets('shows Disconnect Google Calendar button', (tester) async {
    await tester.pumpWidget(_wrapPage());
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text('Disconnect Google Calendar'), findsOneWidget);
  });

  testWidgets('shows View calendar button', (tester) async {
    await tester.pumpWidget(_wrapPage());
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text('View calendar'), findsOneWidget);
  });

  testWidgets('shows empty-state text when no calendars returned', (
    tester,
  ) async {
    await tester.pumpWidget(_wrapPage(hubClient: _StubHubClient(calendars: [])));
    await tester.pump(const Duration(milliseconds: 50));

    expect(
      find.textContaining('No calendars found for this Google account'),
      findsOneWidget,
    );
  });

  testWidgets('sync shows Synced label on success', (tester) async {
    final client = _StubHubClient(
      calendars: [_fakeCalendar(syncEnabled: true)],
    );
    await tester.pumpWidget(_wrapPage(hubClient: client));
    await tester.pump(const Duration(milliseconds: 50));

    await tester.tap(find.text('Sync selected calendars now'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('Synced'), findsOneWidget);
  });

  testWidgets('sync failure shows snackbar with friendly error', (
    tester,
  ) async {
    final client = _StubHubClient(
      calendars: [_fakeCalendar(syncEnabled: true)],
      syncShouldFail: true,
    );
    await tester.pumpWidget(_wrapPage(hubClient: client));
    await tester.pump(const Duration(milliseconds: 50));

    await tester.tap(find.text('Sync selected calendars now'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(
      find.textContaining('We could not sync Google Calendar right now'),
      findsOneWidget,
    );
  });

  testWidgets('sync all with no enabled calendars shows guidance snackbar', (
    tester,
  ) async {
    final client = _StubHubClient(
      calendars: [_fakeCalendar(syncEnabled: false)],
    );
    await tester.pumpWidget(_wrapPage(hubClient: client));
    await tester.pump(const Duration(milliseconds: 50));

    await tester.tap(find.text('Sync selected calendars now'));
    await tester.pump();

    expect(
      find.textContaining('Turn on at least one calendar before syncing'),
      findsOneWidget,
    );
  });
}
