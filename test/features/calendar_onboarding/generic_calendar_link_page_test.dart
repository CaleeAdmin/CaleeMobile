// Widget tests for GenericCalendarLinkPage bootstrap refresh and error messages.

import 'dart:async';

import 'package:calee_mobile/data/api/calee_hub_client.dart';
import 'package:calee_mobile/data/models/client_bootstrap.dart';
import 'package:calee_mobile/data/models/client_calendar.dart';
import 'package:calee_mobile/features/calendar_onboarding/provider_guides/generic_calendar_link_page.dart';
import 'package:calee_mobile/ui/calee_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _BootstrapStubClient extends CaleeHubClient {
  _BootstrapStubClient({required Future<ClientBootstrap> bootstrapFuture})
      : _bootstrapFuture = bootstrapFuture,
        super(baseUri: Uri.parse('http://localhost'));

  final Future<ClientBootstrap> _bootstrapFuture;

  @override
  Future<ClientBootstrap> bootstrap({required String accessToken}) =>
      _bootstrapFuture;

  @override
  Future<ClientCalendarList> calendars({required String accessToken}) async =>
      const ClientCalendarList(calendars: []);

  @override
  Future<ClientCalendar> subscribeCalendarFromLink({
    required String accessToken,
    required String serviceId,
    required String name,
    required String url,
    String? color,
  }) async {
    throw const CaleeHubException(
      statusCode: 500,
      message: 'not implemented in stub',
    );
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

void main() {
  testWidgets('shows loading indicator while bootstrap is in flight', (
    tester,
  ) async {
    final completer = Completer<ClientBootstrap>();
    final client =
        _BootstrapStubClient(bootstrapFuture: completer.future);

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
    expect(find.text('Add to Calee'), findsOneWidget);
  });

  testWidgets('falls back to widget.services when bootstrap throws', (
    tester,
  ) async {
    final client = _BootstrapStubClient(
      bootstrapFuture: Future.error(Exception('network error')),
    );

    await tester.pumpWidget(
      _wrap(client, services: [_kConnectedService]),
    );
    await tester.pumpAndSettle();

    // Form renders — fallback service is connected, so it is selected
    expect(find.text('Calendar name'), findsOneWidget);
    expect(find.text('Add to Calee'), findsOneWidget);
  });

  testWidgets(
    'submit shows no_connected_calendar_service message when readiness problem set',
    (tester) async {
      final client = _BootstrapStubClient(
        bootstrapFuture: Future.value(_kNotReadyBootstrap),
      );

      await tester.pumpWidget(_wrap(client));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byType(TextFormField).first,
        'My Calendar',
      );
      await tester.enterText(
        find.byType(TextFormField).last,
        'https://example.com/calendar.ics',
      );
      await tester.tap(find.text('Add to Calee'));
      await tester.pump();

      expect(
        find.textContaining('Your account setup is not complete'),
        findsOneWidget,
      );
    },
  );

  testWidgets('submit shows missing credential message', (tester) async {
    final client = _BootstrapStubClient(
      bootstrapFuture: Future.value(_kMissingCredentialBootstrap),
    );

    await tester.pumpWidget(_wrap(client));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byType(TextFormField).first,
      'My Calendar',
    );
    await tester.enterText(
      find.byType(TextFormField).last,
      'https://example.com/calendar.ics',
    );
    await tester.tap(find.text('Add to Calee'));
    await tester.pump();

    expect(
      find.textContaining(
        'Your calendar service credential is missing',
      ),
      findsOneWidget,
    );
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

  testWidgets(
    'accepts nextcloud_portal service with connected credential',
    (tester) async {
      final client = _BootstrapStubClient(
        bootstrapFuture: Future.value(_kConnectedPortalBootstrap),
      );

      await tester.pumpWidget(_wrap(client));
      await tester.pumpAndSettle();

      // Form is shown — the nextcloud_portal service is usable.
      expect(find.text('Calendar name'), findsOneWidget);
      expect(find.text('Add to Calee'), findsOneWidget);
      // Single service: no dropdown.
      expect(find.byType(DropdownButtonFormField<ClientService>), findsNothing);
    },
  );

  testWidgets(
    'shows missing credential message for nextcloud_portal service',
    (tester) async {
      final client = _BootstrapStubClient(
        bootstrapFuture: Future.value(_kMissingCredentialPortalBootstrap),
      );

      await tester.pumpWidget(_wrap(client));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byType(TextFormField).first,
        'My Calendar',
      );
      await tester.enterText(
        find.byType(TextFormField).last,
        'https://example.com/calendar.ics',
      );
      await tester.tap(find.text('Add to Calee'));
      await tester.pump();

      expect(
        find.textContaining('Your calendar service credential is missing'),
        findsOneWidget,
      );
    },
  );
}
