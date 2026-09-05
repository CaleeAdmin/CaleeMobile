// Widget tests for GenericCalendarLinkPage bootstrap refresh, error messages,
// and the "Check calendar" preview-before-save validation flow.

import 'dart:async';

import 'package:calee_mobile/data/api/calee_hub_client.dart';
import 'package:calee_mobile/data/models/calendar_subscription_validation.dart';
import 'package:calee_mobile/data/models/client_bootstrap.dart';
import 'package:calee_mobile/data/models/client_calendar.dart';
import 'package:calee_mobile/features/calendar/newly_added_calendar_visibility.dart';
import 'package:calee_mobile/features/calendar_onboarding/provider_guides/generic_calendar_link_page.dart';
import 'package:calee_mobile/ui/calee_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

// CaleePreferences (used by GenericCalendarLinkPage._submit on success)
// reads/writes SharedPreferences and migrates from FlutterSecureStorage on
// first load, so both platform channels need mocking or a successful save
// hangs waiting on a real channel response.
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

class _BootstrapStubClient extends CaleeHubClient {
  _BootstrapStubClient({
    required this._bootstrapFuture,
    this.validateResult,
    this.validateError,
    this.subscribeError,
  }) : super(baseUri: Uri.parse('http://localhost'));

  final Future<ClientBootstrap> _bootstrapFuture;
  CalendarSubscriptionValidationResult? validateResult;
  Object Function()? validateError;
  Object Function()? subscribeError;

  int validateCallCount = 0;
  String? lastValidatedUrl;
  String? lastValidatedName;
  String? lastValidatedServiceId;

  int subscribeCallCount = 0;
  String? lastSubscribedUrl;

  @override
  Future<ClientBootstrap> bootstrap({required String accessToken}) =>
      _bootstrapFuture;

  @override
  Future<ClientCalendarList> calendars({required String accessToken}) async =>
      const ClientCalendarList(calendars: []);

  @override
  Future<CalendarSubscriptionValidationResult> validateCalendarSubscription({
    required String accessToken,
    required String serviceId,
    required String name,
    required String url,
  }) async {
    validateCallCount++;
    lastValidatedUrl = url;
    lastValidatedName = name;
    lastValidatedServiceId = serviceId;
    final error = validateError;
    if (error != null) throw error();
    return validateResult!;
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
}

const _kConnectedService = ClientService(
  id: 'svc1',
  displayName: 'Calee',
  serviceType: 'nextcloud_calendar',
  baseUrl: 'http://localhost',
  launchUrl: '',
  accessStatus: 'active',
  calendarCredentialStatus: 'connected',
  source: 'calee',
  capabilities: {},
);

const _kMissingCredentialService = ClientService(
  id: 'svc1',
  displayName: 'Calee',
  serviceType: 'nextcloud_calendar',
  baseUrl: 'http://localhost',
  launchUrl: '',
  accessStatus: 'active',
  calendarCredentialStatus: 'missing',
  source: 'calee',
  capabilities: {},
);

const _kConnectedPortalService = ClientService(
  id: 'portal',
  displayName: 'Calee Portal',
  serviceType: 'nextcloud_portal',
  baseUrl: 'http://localhost',
  launchUrl: '',
  accessStatus: 'active',
  calendarCredentialStatus: 'connected',
  source: 'calee',
  capabilities: {},
);

const _kMissingCredentialPortalService = ClientService(
  id: 'portal',
  displayName: 'Calee Portal',
  serviceType: 'nextcloud_portal',
  baseUrl: 'http://localhost',
  launchUrl: '',
  accessStatus: 'active',
  calendarCredentialStatus: 'missing',
  source: 'calee',
  capabilities: {},
);

const _kEmptyBootstrap = ClientBootstrap(
  account: ClientAccount(
    id: '',
    displayName: null,
    primaryEmail: null,
    timeZone: null,
    status: null,
  ),
  services: [],
  contexts: ClientContexts(households: [], organisations: []),
  availableContexts: [],
  capabilities: {},
);

const _kConnectedBootstrap = ClientBootstrap(
  account: ClientAccount(
    id: '',
    displayName: null,
    primaryEmail: null,
    timeZone: null,
    status: null,
  ),
  services: [_kConnectedService],
  contexts: ClientContexts(households: [], organisations: []),
  availableContexts: [],
  capabilities: {},
);

const _kMissingCredentialBootstrap = ClientBootstrap(
  account: ClientAccount(
    id: '',
    displayName: null,
    primaryEmail: null,
    timeZone: null,
    status: null,
  ),
  services: [_kMissingCredentialService],
  contexts: ClientContexts(households: [], organisations: []),
  availableContexts: [],
  capabilities: {},
);

const _kConnectedPortalBootstrap = ClientBootstrap(
  account: ClientAccount(
    id: '',
    displayName: null,
    primaryEmail: null,
    timeZone: null,
    status: null,
  ),
  services: [_kConnectedPortalService],
  contexts: ClientContexts(households: [], organisations: []),
  availableContexts: [],
  capabilities: {},
);

const _kMissingCredentialPortalBootstrap = ClientBootstrap(
  account: ClientAccount(
    id: '',
    displayName: null,
    primaryEmail: null,
    timeZone: null,
    status: null,
  ),
  services: [_kMissingCredentialPortalService],
  contexts: ClientContexts(households: [], organisations: []),
  availableContexts: [],
  capabilities: {},
);

const _kNotReadyBootstrap = ClientBootstrap(
  account: ClientAccount(
    id: '',
    displayName: null,
    primaryEmail: null,
    timeZone: null,
    status: null,
  ),
  services: [],
  contexts: ClientContexts(households: [], organisations: []),
  availableContexts: [],
  capabilities: {},
  readiness: {
    'calendarServiceReady': false,
    'problem': 'no_connected_calendar_service',
  },
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

Widget _wrap(
  CaleeHubClient client, {
  List<ClientService> services = const [],
}) => MaterialApp(
  theme: CaleeTheme.buildThemeData(),
  home: GenericCalendarLinkPage(
    hubClient: client,
    accessToken: 'token',
    services: services,
    accountId: 'acct1',
    onDone: () {},
    onViewCalendar: () {},
  ),
);

_BootstrapStubClient _connectedClient({
  CalendarSubscriptionValidationResult? validateResult,
  Object Function()? validateError,
  Object Function()? subscribeError,
}) => _BootstrapStubClient(
  bootstrapFuture: Future.value(_kConnectedBootstrap),
  validateResult: validateResult,
  validateError: validateError,
  subscribeError: subscribeError,
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

void main() {
  setUp(_setUpSharedPrefs);
  tearDown(_tearDownSharedPrefs);

  testWidgets('shows loading indicator while bootstrap is in flight', (
    tester,
  ) async {
    final completer = Completer<ClientBootstrap>();
    final client = _BootstrapStubClient(bootstrapFuture: completer.future);

    await tester.pumpWidget(_wrap(client));
    await tester.pump();

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.text('Calendar name'), findsNothing);

    completer.complete(_kEmptyBootstrap);
    await tester.pumpAndSettle();

    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.text('Calendar name'), findsOneWidget);
  });

  testWidgets('form renders after bootstrap resolves', (tester) async {
    final client = _BootstrapStubClient(
      bootstrapFuture: Future.value(_kEmptyBootstrap),
    );

    await tester.pumpWidget(_wrap(client));
    await tester.pumpAndSettle();

    expect(find.text('Calendar name'), findsOneWidget);
    expect(find.text('Calendar link'), findsOneWidget);
    expect(find.text('Check calendar'), findsOneWidget);
  });

  testWidgets('falls back to widget.services when bootstrap throws', (
    tester,
  ) async {
    final completer = Completer<ClientBootstrap>();
    final client = _BootstrapStubClient(bootstrapFuture: completer.future);

    await tester.pumpWidget(_wrap(client, services: [_kConnectedService]));
    await tester.pump();

    // Complete with error after the widget has attached a listener so the
    // error is handled (not reported as unawaited) by the test zone.
    completer.completeError(Exception('network error'));
    await tester.pumpAndSettle();

    // Form renders — fallback service is connected, so it is selected
    expect(find.text('Calendar name'), findsOneWidget);
    expect(find.text('Check calendar'), findsOneWidget);
  });

  testWidgets(
    'checking shows no_connected_calendar_service message when readiness problem set',
    (tester) async {
      final client = _BootstrapStubClient(
        bootstrapFuture: Future.value(_kNotReadyBootstrap),
      );

      await tester.pumpWidget(_wrap(client));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextFormField).first, 'My Calendar');
      await tester.enterText(
        find.byType(TextFormField).last,
        'https://example.com/calendar.ics',
      );
      await tester.tap(find.text('Check calendar'));
      await tester.pump();

      expect(
        find.text(
          'Your account setup is not complete. Please sign out and sign in again.',
        ),
        findsOneWidget,
      );
      expect(client.validateCallCount, 0);
    },
  );

  testWidgets('checking shows missing credential message', (tester) async {
    final client = _BootstrapStubClient(
      bootstrapFuture: Future.value(_kMissingCredentialBootstrap),
    );

    await tester.pumpWidget(_wrap(client));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextFormField).first, 'My Calendar');
    await tester.enterText(
      find.byType(TextFormField).last,
      'https://example.com/calendar.ics',
    );
    await tester.tap(find.text('Check calendar'));
    await tester.pump();

    expect(
      find.textContaining('Your calendar service credential is missing'),
      findsOneWidget,
    );
    expect(client.validateCallCount, 0);
  });

  testWidgets('connected bootstrap service is selected for submission', (
    tester,
  ) async {
    final client = _BootstrapStubClient(
      bootstrapFuture: Future.value(_kConnectedBootstrap),
    );

    await tester.pumpWidget(_wrap(client));
    await tester.pumpAndSettle();

    // One connected service: no dropdown rendered (only shown when ≥2)
    expect(find.byType(DropdownButtonFormField<ClientService>), findsNothing);
    expect(find.text('Calendar name'), findsOneWidget);
  });

  testWidgets('accepts nextcloud_portal service with connected credential', (
    tester,
  ) async {
    final client = _BootstrapStubClient(
      bootstrapFuture: Future.value(_kConnectedPortalBootstrap),
    );

    await tester.pumpWidget(_wrap(client));
    await tester.pumpAndSettle();

    // Form is shown — the nextcloud_portal service is usable.
    expect(find.text('Calendar name'), findsOneWidget);
    expect(find.text('Check calendar'), findsOneWidget);
    // Single service: no dropdown.
    expect(find.byType(DropdownButtonFormField<ClientService>), findsNothing);
  });

  testWidgets('shows missing credential message for nextcloud_portal service', (
    tester,
  ) async {
    final client = _BootstrapStubClient(
      bootstrapFuture: Future.value(_kMissingCredentialPortalBootstrap),
    );

    await tester.pumpWidget(_wrap(client));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextFormField).first, 'My Calendar');
    await tester.enterText(
      find.byType(TextFormField).last,
      'https://example.com/calendar.ics',
    );
    await tester.tap(find.text('Check calendar'));
    await tester.pump();

    expect(
      find.textContaining('Your calendar service credential is missing'),
      findsOneWidget,
    );
  });

  // ── "Check calendar" validation flow ────────────────────────────────────

  testWidgets('1. empty URL blocks locally without calling check', (
    tester,
  ) async {
    final client = _connectedClient();
    await tester.pumpWidget(_wrap(client));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.widgetWithText(TextFormField, 'Calendar name'),
      'Family',
    );
    await tester.tap(find.text('Check calendar'));
    await tester.pumpAndSettle();

    expect(find.text('Enter a calendar link'), findsOneWidget);
    expect(client.validateCallCount, 0);
  });

  testWidgets('2. a relative path blocks locally without calling check', (
    tester,
  ) async {
    final client = _connectedClient();
    await tester.pumpWidget(_wrap(client));
    await tester.pumpAndSettle();

    await _fillNameAndUrl(tester, url: '/public-calendars/abc?export');
    await tester.tap(find.text('Check calendar'));
    await tester.pumpAndSettle();

    expect(
      find.text(
        'This does not look like a calendar link. Paste a calendar link that starts with https:// or webcal://.',
      ),
      findsOneWidget,
    );
    expect(client.validateCallCount, 0);
  });

  testWidgets('3. a plain http:// link blocks locally without calling check', (
    tester,
  ) async {
    final client = _connectedClient();
    await tester.pumpWidget(_wrap(client));
    await tester.pumpAndSettle();

    await _fillNameAndUrl(tester, url: 'http://example.com/calendar.ics');
    await tester.tap(find.text('Check calendar'));
    await tester.pumpAndSettle();

    expect(
      find.text(
        'This does not look like a calendar link. Paste a calendar link that starts with https:// or webcal://.',
      ),
      findsOneWidget,
    );
    expect(client.validateCallCount, 0);
  });

  testWidgets('4. a https:// link calls validateCalendarSubscription', (
    tester,
  ) async {
    final client = _connectedClient(validateResult: _validResult);
    await tester.pumpWidget(_wrap(client));
    await tester.pumpAndSettle();

    await _fillNameAndUrl(tester, url: 'https://example.com/calendar.ics');
    await tester.tap(find.text('Check calendar'));
    await tester.pumpAndSettle();

    expect(client.validateCallCount, 1);
    expect(client.lastValidatedUrl, 'https://example.com/calendar.ics');
  });

  testWidgets('5. a webcal:// link calls validateCalendarSubscription', (
    tester,
  ) async {
    final client = _connectedClient(validateResult: _validResult);
    await tester.pumpWidget(_wrap(client));
    await tester.pumpAndSettle();

    await _fillNameAndUrl(tester, url: 'webcal://example.com/calendar.ics');
    await tester.tap(find.text('Check calendar'));
    await tester.pumpAndSettle();

    expect(client.validateCallCount, 1);
    expect(client.lastValidatedUrl, 'webcal://example.com/calendar.ics');
  });

  testWidgets('6. HTML-response validation shows inline error and does not save', (
    tester,
  ) async {
    final client = _connectedClient(
      validateResult: const CalendarSubscriptionValidationResult(
        valid: false,
        errorCode: 'html_response',
        message:
            'This link opens a webpage, not a calendar. Please copy the calendar subscription link.',
      ),
    );
    await tester.pumpWidget(_wrap(client));
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

  testWidgets('7. 404 validation shows inline error and does not save', (
    tester,
  ) async {
    final client = _connectedClient(
      validateResult: const CalendarSubscriptionValidationResult(
        valid: false,
        errorCode: 'http_error:404',
        message:
            'This calendar link no longer exists. Please copy a new calendar link.',
      ),
    );
    await tester.pumpWidget(_wrap(client));
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
    expect(find.text('Add to Calee'), findsNothing);
    expect(client.subscribeCallCount, 0);
  });

  testWidgets('8. oversized validation shows inline error and does not save', (
    tester,
  ) async {
    final client = _connectedClient(
      validateResult: const CalendarSubscriptionValidationResult(
        valid: false,
        errorCode: 'response_too_large',
        message:
            'This calendar is too large to import automatically right now. Please contact Calee Support and we can help connect it.',
      ),
    );
    await tester.pumpWidget(_wrap(client));
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
    expect(find.text('Add to Calee'), findsNothing);
    expect(client.subscribeCallCount, 0);
  });

  testWidgets('9. valid validation shows the preview card', (tester) async {
    final client = _connectedClient(validateResult: _validResult);
    await tester.pumpWidget(_wrap(client));
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
    '10. after a valid preview, Add to Calee saves using normalizedUrl',
    (tester) async {
      final client = _connectedClient(validateResult: _validResult);
      await tester.pumpWidget(_wrap(client));
      await tester.pumpAndSettle();
      await _fillNameAndUrl(tester);

      await tester.tap(find.text('Check calendar'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Add to Calee'));
      await tester.pumpAndSettle();

      expect(client.subscribeCallCount, 1);
      expect(client.lastSubscribedUrl, 'https://example.com/normalized.ics');
      expect(find.text('Calendar added to Calee'), findsOneWidget);
    },
  );

  testWidgets(
    '10b. a successful add records the new calendar so Calendar shows it',
    (tester) async {
      // Drain anything an earlier test left behind, so this asserts only what
      // this add records.
      NewlyAddedCalendarVisibility.instance.take();
      final client = _connectedClient(validateResult: _validResult);
      await tester.pumpWidget(_wrap(client));
      await tester.pumpAndSettle();
      await _fillNameAndUrl(tester);

      await tester.tap(find.text('Check calendar'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Add to Calee'));
      await tester.pumpAndSettle();

      // The id the subscribe response returned — the calendar the user just
      // added must not stay unchecked in the calendar selector.
      expect(NewlyAddedCalendarVisibility.instance.take(), {'cal1'});
    },
  );

  testWidgets(
    '11. editing the URL after validation clears the preview and returns to Check calendar',
    (tester) async {
      final client = _connectedClient(validateResult: _validResult);
      await tester.pumpWidget(_wrap(client));
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

  testWidgets(
    '12. a generic "Hub request failed" error during check is converted to a friendly inline message',
    (tester) async {
      final client = _connectedClient(
        validateError: () => const CaleeHubException(
          statusCode: 500,
          message: 'Hub request failed',
        ),
      );
      await tester.pumpWidget(_wrap(client));
      await tester.pumpAndSettle();
      await _fillNameAndUrl(tester);

      await tester.tap(find.text('Check calendar'));
      await tester.pumpAndSettle();

      expect(find.text('Hub request failed'), findsNothing);
      expect(
        find.text(
          'Calee could not check this calendar link. Please try again.',
        ),
        findsOneWidget,
      );
      expect(find.text('Add to Calee'), findsNothing);
      expect(client.subscribeCallCount, 0);
    },
  );
}
