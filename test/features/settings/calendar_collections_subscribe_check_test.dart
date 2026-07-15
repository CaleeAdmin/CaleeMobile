// Widget tests for the "Check calendar" preview-before-save flow on
// CalendarCollectionsPage's Add-calendar-link sheet: local URL-shape
// validation, backend validation (valid/invalid), the preview card, and
// state resets when the checked fields are edited afterward.

import 'package:calee_mobile/data/api/calee_hub_client.dart';
import 'package:calee_mobile/data/models/calendar_subscription_validation.dart';
import 'package:calee_mobile/data/models/client_bootstrap.dart';
import 'package:calee_mobile/data/models/client_calendar.dart';
import 'package:calee_mobile/data/models/external_calendar_connection.dart';
import 'package:calee_mobile/features/settings/calendar_collections_page.dart';
import 'package:calee_mobile/ui/calee_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

// ── Stub ─────────────────────────────────────────────────────────────────────

class _StubHubClient extends CaleeHubClient {
  _StubHubClient({
    this.checkResult,
    this.checkError,
    this.subscribeError,
    List<ExternalCalendarConnection>? connections,
  }) : _connections = connections ?? const [],
       super(baseUri: Uri.parse('http://localhost'));

  CalendarSubscriptionValidationResult? checkResult;
  Object Function()? checkError;
  Object Function()? subscribeError;
  final List<ExternalCalendarConnection> _connections;

  int checkCallCount = 0;
  String? lastCheckedUrl;
  String? lastCheckedName;
  String? lastCheckedServiceId;

  int subscribeCallCount = 0;
  String? lastSubscribedUrl;

  int createCallCount = 0;

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
  Future<CalendarSubscriptionValidationResult> validateCalendarSubscription({
    required String accessToken,
    required String serviceId,
    required String name,
    required String url,
  }) async {
    checkCallCount++;
    lastCheckedUrl = url;
    lastCheckedName = name;
    lastCheckedServiceId = serviceId;
    final error = checkError;
    if (error != null) throw error();
    return checkResult!;
  }

  @override
  Future<ClientCalendar> subscribeCalendarFromLink({
    required String accessToken,
    required String serviceId,
    required String name,
    required String url,
    String? color,
  }) async {
    subscribeCallCount++;
    lastSubscribedUrl = url;
    final error = subscribeError;
    if (error != null) throw error();
    return ClientCalendar.fromJson({
      'id': 'cal1',
      'serviceId': serviceId,
      'name': name,
      'isSubscription': true,
      'readOnly': true,
    });
  }

  @override
  Future<ClientCalendar> createCalendar({
    required String accessToken,
    required String serviceId,
    required String name,
    required String primaryKind,
    String? color,
  }) async {
    createCallCount++;
    return ClientCalendar.fromJson({
      'id': 'cal-created',
      'serviceId': serviceId,
      'name': name,
      'primaryKind': primaryKind,
    });
  }
}

// ── Helpers ──────────────────────────────────────────────────────────────────

ClientService _service({String id = 'svc1'}) => ClientService(
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

Widget _wrap(
  _StubHubClient hubClient, {
  bool autoOpenSubscribe = false,
  bool autoOpenSubscribeForm = false,
  bool autoOpenCreate = false,
  String? initialSubscriptionUrl,
  String? initialSubscriptionName,
}) => MaterialApp(
  theme: CaleeTheme.buildThemeData(),
  home: CalendarCollectionsPage(
    hubClient: hubClient,
    accessToken: 'tok',
    services: [_service()],
    accountId: 'acct1',
    isFamilyUxContext: true,
    autoOpenSubscribe: autoOpenSubscribe,
    autoOpenSubscribeForm: autoOpenSubscribeForm,
    autoOpenCreate: autoOpenCreate,
    initialSubscriptionUrl: initialSubscriptionUrl,
    initialSubscriptionName: initialSubscriptionName,
  ),
);

const _validResult = CalendarSubscriptionValidationResult(
  valid: true,
  normalizedUrl: 'https://example.com/normalized.ics',
  message: 'Calendar link looks good.',
  preview: CalendarSubscriptionPreview(
    displayName: 'Family',
    sourceHost: 'example.com',
    provider: 'icloud',
    eventCount: 85,
  ),
);

Future<void> _fillNameAndUrl(
  WidgetTester tester, {
  String name = 'Family',
  String url = 'https://example.com/calendar.ics',
}) async {
  await tester.enterText(
    find.widgetWithText(TextFormField, 'Calendar name'),
    name,
  );
  await tester.enterText(
    find.widgetWithText(TextFormField, 'Calendar link'),
    url,
  );
}

// ── Tests ──────────────────────────────────────────────────────────────────────

void main() {
  testWidgets('1. invalid URL shape still blocks locally without calling check', (
    tester,
  ) async {
    final client = _StubHubClient();
    await tester.pumpWidget(_wrap(client, autoOpenSubscribe: true));
    await tester.pumpAndSettle();

    await _fillNameAndUrl(tester, url: 'not a link');
    await tester.tap(find.text('Check calendar'));
    await tester.pumpAndSettle();

    expect(
      find.text(
        'This does not look like a calendar link. Paste a link that starts with http, https, or webcal.',
      ),
      findsOneWidget,
    );
    expect(client.checkCallCount, 0);
  });

  testWidgets('2. HTML-response validation shows inline error and does not save', (
    tester,
  ) async {
    final client = _StubHubClient(
      checkResult: const CalendarSubscriptionValidationResult(
        valid: false,
        errorCode: 'html_response',
        message:
            'This link opens a webpage, not a calendar. Please copy the calendar subscription link.',
      ),
    );
    await tester.pumpWidget(_wrap(client, autoOpenSubscribe: true));
    await tester.pumpAndSettle();
    await _fillNameAndUrl(tester);

    await tester.tap(find.text('Check calendar'));
    await tester.pumpAndSettle();

    expect(
      find.text(
        'This link opens a webpage, not a calendar. Please copy the calendar subscription link.',
      ),
      findsOneWidget,
    );
    expect(find.text('Add to Calee'), findsNothing);
    expect(client.subscribeCallCount, 0);
  });

  testWidgets('3. 404 validation shows inline error and does not save', (
    tester,
  ) async {
    final client = _StubHubClient(
      checkResult: const CalendarSubscriptionValidationResult(
        valid: false,
        errorCode: 'http_error:404',
        message:
            'This calendar link no longer exists. Please copy a new calendar link.',
      ),
    );
    await tester.pumpWidget(_wrap(client, autoOpenSubscribe: true));
    await tester.pumpAndSettle();
    await _fillNameAndUrl(tester);

    await tester.tap(find.text('Check calendar'));
    await tester.pumpAndSettle();

    expect(
      find.text(
        'This calendar link no longer exists. Please copy a new calendar link.',
      ),
      findsOneWidget,
    );
    expect(client.subscribeCallCount, 0);
  });

  testWidgets(
    '4. oversized validation shows the support message and does not save',
    (tester) async {
      final client = _StubHubClient(
        checkResult: const CalendarSubscriptionValidationResult(
          valid: false,
          errorCode: 'response_too_large',
          message:
              'This calendar is too large to import automatically right now. Please contact Calee Support and we can help connect it.',
        ),
      );
      await tester.pumpWidget(_wrap(client, autoOpenSubscribe: true));
      await tester.pumpAndSettle();
      await _fillNameAndUrl(tester);

      await tester.tap(find.text('Check calendar'));
      await tester.pumpAndSettle();

      expect(
        find.text(
          'This calendar is too large to import automatically right now. Please contact Calee Support and we can help connect it.',
        ),
        findsOneWidget,
      );
      expect(client.subscribeCallCount, 0);
    },
  );

  testWidgets('5. valid validation shows the preview card', (tester) async {
    final client = _StubHubClient(checkResult: _validResult);
    await tester.pumpWidget(_wrap(client, autoOpenSubscribe: true));
    await tester.pumpAndSettle();
    await _fillNameAndUrl(tester);

    await tester.tap(find.text('Check calendar'));
    await tester.pumpAndSettle();

    expect(find.text('Calendar found'), findsOneWidget);
    expect(find.text('Provider: iCloud'), findsOneWidget);
    expect(find.text('Events found: 85'), findsOneWidget);
    expect(find.text('Add to Calee'), findsOneWidget);
  });

  testWidgets(
    '6. after a valid preview, Add to Calee saves using normalizedUrl',
    (tester) async {
      final client = _StubHubClient(checkResult: _validResult);
      await tester.pumpWidget(_wrap(client, autoOpenSubscribe: true));
      await tester.pumpAndSettle();
      await _fillNameAndUrl(tester);

      await tester.tap(find.text('Check calendar'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Add to Calee'));
      await tester.pumpAndSettle();

      expect(client.subscribeCallCount, 1);
      expect(client.lastSubscribedUrl, 'https://example.com/normalized.ics');
    },
  );

  testWidgets(
    '7. editing the URL after validation clears the preview and requires checking again',
    (tester) async {
      final client = _StubHubClient(checkResult: _validResult);
      await tester.pumpWidget(_wrap(client, autoOpenSubscribe: true));
      await tester.pumpAndSettle();
      await _fillNameAndUrl(tester);

      await tester.tap(find.text('Check calendar'));
      await tester.pumpAndSettle();
      expect(find.text('Add to Calee'), findsOneWidget);

      await tester.enterText(
        find.widgetWithText(TextFormField, 'Calendar link'),
        'https://example.com/different.ics',
      );
      await tester.pump();

      expect(find.text('Calendar found'), findsNothing);
      expect(find.text('Check calendar'), findsOneWidget);
      expect(find.text('Add to Calee'), findsNothing);
    },
  );

  testWidgets('8. existing create-calendar flow still works', (tester) async {
    final client = _StubHubClient();
    await tester.pumpWidget(_wrap(client, autoOpenCreate: true));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.widgetWithText(TextFormField, 'Name'),
      'My List',
    );
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(client.createCallCount, 1);
  });

  testWidgets('9. existing Google Calendar connection flow is not affected', (
    tester,
  ) async {
    final client = _StubHubClient(
      connections: [
        ExternalCalendarConnection.fromJson({
          'id': 'conn1',
          'providerKey': 'google_calendar',
          'displayName': 'Google Calendar',
          'connectionStatus': 'active',
          'accessMode': 'read_only',
          'sourceOfTruthPolicy': 'external',
        }),
      ],
    );
    await tester.pumpWidget(_wrap(client));
    await tester.pumpAndSettle();

    expect(find.text('Google Calendar'), findsOneWidget);
    expect(client.checkCallCount, 0);
    expect(client.subscribeCallCount, 0);
  });

  testWidgets(
    '10. prefilled follow-link subscription still validates before save',
    (tester) async {
      final client = _StubHubClient(checkResult: _validResult);
      await tester.pumpWidget(
        _wrap(
          client,
          autoOpenSubscribeForm: true,
          initialSubscriptionUrl: 'https://example.com/follow.ics',
          initialSubscriptionName: 'Shared family calendar',
        ),
      );
      await tester.pumpAndSettle();

      // Prefilled fields render, but the primary action still starts as
      // "Check calendar" — a prefilled follow-link URL is never trusted
      // without a check.
      expect(find.text('Shared family calendar'), findsOneWidget);
      expect(find.text('Check calendar'), findsOneWidget);
      expect(find.text('Add to Calee'), findsNothing);
      expect(client.checkCallCount, 0);

      await tester.tap(find.text('Check calendar'));
      await tester.pumpAndSettle();

      expect(client.checkCallCount, 1);
      expect(client.lastCheckedUrl, 'https://example.com/follow.ics');
      expect(find.text('Add to Calee'), findsOneWidget);

      await tester.tap(find.text('Add to Calee'));
      await tester.pumpAndSettle();

      expect(client.subscribeCallCount, 1);
    },
  );

  testWidgets(
    '11. a network/API failure while checking shows an inline error and does not save',
    (tester) async {
      final client = _StubHubClient(
        checkError: () => const CaleeHubException(
          statusCode: 0,
          message: 'Check your connection and try again.',
        ),
      );
      await tester.pumpWidget(_wrap(client, autoOpenSubscribe: true));
      await tester.pumpAndSettle();
      await _fillNameAndUrl(tester);

      await tester.tap(find.text('Check calendar'));
      await tester.pumpAndSettle();

      expect(find.text('Check your connection and try again.'), findsOneWidget);
      expect(find.text('Add to Calee'), findsNothing);
      expect(client.subscribeCallCount, 0);
    },
  );

  testWidgets(
    '12. a save failure after a valid check keeps the existing SnackBar error handling',
    (tester) async {
      final client = _StubHubClient(
        checkResult: _validResult,
        subscribeError: () => const CaleeHubException(
          statusCode: 409,
          message: 'Calendar subscription already exists',
          code: 'CALENDAR_EXISTS',
        ),
      );
      await tester.pumpWidget(_wrap(client, autoOpenSubscribe: true));
      await tester.pumpAndSettle();
      await _fillNameAndUrl(tester);

      await tester.tap(find.text('Check calendar'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Add to Calee'));
      await tester.pumpAndSettle();

      expect(find.text('Calendar subscription already exists'), findsOneWidget);
      // The preview/checked state is untouched by a save failure — no need
      // to re-check, "Add to Calee" is still the primary action.
      expect(find.text('Add to Calee'), findsOneWidget);
    },
  );
}
