// Widget tests for appearance (name/colour) editing in CalendarCollectionsPage.
//
// Covers the same scenarios as
// test/features/calendar/calendar_detail_sheet_appearance_test.dart, using
// identical fixture calendars per ClientCalendar.appearanceMode, so the two
// surfaces can be shown to reach the same edit-availability decision from
// `calendar.capabilities.canEditAppearance`.

import 'package:calee_mobile/data/api/calee_hub_client.dart';
import 'package:calee_mobile/data/models/client_bootstrap.dart';
import 'package:calee_mobile/data/models/client_calendar.dart';
import 'package:calee_mobile/data/models/external_calendar_connection.dart';
import 'package:calee_mobile/features/settings/calendar_collections_page.dart';
import 'package:calee_mobile/ui/calee_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _StubHubClient extends CaleeHubClient {
  _StubHubClient({this.calendarsToReturn = const [], this.appearanceError})
    : super(baseUri: Uri.parse('http://localhost'));

  final List<ClientCalendar> calendarsToReturn;
  final Object? appearanceError;

  int updateCalendarAppearanceCallCount = 0;
  int updateCalendarCallCount = 0;
  int createCalendarCallCount = 0;
  ({String calendarId, String name, String? color})? lastAppearanceCall;

  @override
  Future<ClientCalendarList> calendars({required String accessToken}) async {
    return ClientCalendarList(calendars: calendarsToReturn);
  }

  @override
  Future<List<ExternalCalendarConnection>> externalCalendarConnections({
    required String accessToken,
  }) async {
    return const [];
  }

  @override
  Future<ClientCalendar> updateCalendarAppearance({
    required String accessToken,
    required String calendarId,
    required String name,
    String? color,
  }) async {
    updateCalendarAppearanceCallCount++;
    lastAppearanceCall = (calendarId: calendarId, name: name, color: color);
    if (appearanceError != null) throw appearanceError!;
    return calendarsToReturn.firstWhere((c) => c.id == calendarId);
  }

  @override
  Future<ClientCalendar> updateCalendar({
    required String accessToken,
    required String calendarId,
    String? name,
    String? color,
  }) async {
    updateCalendarCallCount++;
    throw StateError(
      'updateCalendar() must not be called by appearance editing',
    );
  }

  @override
  Future<ClientCalendar> createCalendar({
    required String accessToken,
    required String serviceId,
    required String name,
    required String primaryKind,
    String? color,
  }) async {
    createCalendarCallCount++;
    return _calendar(
      id: 'new-cal',
      name: name,
      appearanceMode: 'source_metadata',
      capabilities: _sourceMetadataCapabilities,
    );
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

// ── Fixture calendars — one per appearanceMode, kept identical to
// test/features/calendar/calendar_detail_sheet_appearance_test.dart so both
// surfaces can be shown to reach the same edit-availability decision.

const _sourceMetadataCapabilities = CalendarCapabilities(
  canEditAppearance: true,
  canEditEvents: true,
  canEditSourceMetadata: true,
  canRemoveFromCalee: false,
  canDeleteSource: true,
);

const _subscriptionMappingCapabilities = CalendarCapabilities(
  canEditAppearance: true,
  canEditEvents: false,
  canEditSourceMetadata: false,
  canRemoveFromCalee: true,
  canDeleteSource: false,
);

const _externalCalendarCapabilities = CalendarCapabilities(
  canEditAppearance: true,
  canEditEvents: true,
  canEditSourceMetadata: false,
  canRemoveFromCalee: true,
  canDeleteSource: false,
);

const _unsupportedCapabilities = CalendarCapabilities(
  canEditAppearance: false,
  canEditEvents: false,
  canEditSourceMetadata: false,
  canRemoveFromCalee: true,
  canDeleteSource: false,
);

ClientCalendar _calendar({
  required String appearanceMode,
  required CalendarCapabilities capabilities,
  String id = 'cal1',
  String name = 'Family',
  String? color = '#FF9500',
  String? sourceName,
  String? sourceColor,
  bool readOnly = false,
  bool isSubscription = false,
}) => ClientCalendar(
  id: id,
  serviceId: 'svc1',
  serviceName: 'Calee Portal',
  name: name,
  color: color,
  components: const ['VEVENT'],
  primaryKind: 'calendar',
  supportsEvents: true,
  supportsTasks: false,
  supportsChores: false,
  readOnly: readOnly,
  isSubscription: isSubscription,
  source: 'calee',
  sourceName: sourceName,
  sourceColor: sourceColor,
  appearanceMode: appearanceMode,
  capabilities: capabilities,
);

Widget _wrap(CaleeHubClient client) => MaterialApp(
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
  group('row tap opens (or does not open) the edit sheet per appearanceMode', () {
    testWidgets('source_metadata: tapping the row opens the edit sheet', (
      tester,
    ) async {
      final calendar = _calendar(
        appearanceMode: 'source_metadata',
        capabilities: _sourceMetadataCapabilities,
      );
      await tester.pumpWidget(
        _wrap(_StubHubClient(calendarsToReturn: [calendar])),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Family'));
      await tester.pumpAndSettle();

      expect(
        find.text('This updates the calendar name and colour.'),
        findsOneWidget,
      );
      expect(find.text('Name in Calee'), findsOneWidget);
      expect(find.text('Colour in Calee'), findsOneWidget);
    });

    testWidgets('subscription_mapping: tapping the row opens the edit sheet', (
      tester,
    ) async {
      final calendar = _calendar(
        appearanceMode: 'subscription_mapping',
        capabilities: _subscriptionMappingCapabilities,
        isSubscription: true,
        readOnly: true,
      );
      await tester.pumpWidget(
        _wrap(_StubHubClient(calendarsToReturn: [calendar])),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Family'));
      await tester.pumpAndSettle();

      expect(
        find.text(
          'These changes only affect how this calendar appears in Calee.',
        ),
        findsOneWidget,
      );
    });

    testWidgets('external_calendar: tapping the row opens the edit sheet', (
      tester,
    ) async {
      final calendar = _calendar(
        appearanceMode: 'external_calendar',
        capabilities: _externalCalendarCapabilities,
        readOnly: true,
      );
      await tester.pumpWidget(
        _wrap(_StubHubClient(calendarsToReturn: [calendar])),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Family'));
      await tester.pumpAndSettle();

      expect(
        find.text(
          'These changes only affect how this calendar appears in Calee.',
        ),
        findsOneWidget,
      );
    });

    testWidgets(
      'unsupported: the row is not tappable and shows the owner-managed message',
      (tester) async {
        final calendar = _calendar(
          appearanceMode: 'unsupported',
          capabilities: _unsupportedCapabilities,
          readOnly: true,
        );
        await tester.pumpWidget(
          _wrap(_StubHubClient(calendarsToReturn: [calendar])),
        );
        await tester.pumpAndSettle();

        expect(
          find.textContaining('This shared calendar is managed by its owner.'),
          findsOneWidget,
        );
        // No overflow menu either — canRename and canDelete are both false
        // for a readOnly, non-subscription "unsupported" calendar.
        expect(find.byIcon(Icons.more_horiz_rounded), findsNothing);

        await tester.tap(find.text('Family'));
        await tester.pumpAndSettle();

        expect(find.text('Name in Calee'), findsNothing);
      },
    );
  });

  testWidgets(
    'the overflow menu offers "Edit Name & Colour" for an editable calendar',
    (tester) async {
      final calendar = _calendar(
        appearanceMode: 'source_metadata',
        capabilities: _sourceMetadataCapabilities,
      );
      await tester.pumpWidget(
        _wrap(_StubHubClient(calendarsToReturn: [calendar])),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(Icons.more_horiz_rounded));
      await tester.pumpAndSettle();

      expect(find.text('Edit Name & Colour'), findsOneWidget);
    },
  );

  testWidgets('sourceName is preserved and shown when it differs from name', (
    tester,
  ) async {
    final calendar = _calendar(
      appearanceMode: 'subscription_mapping',
      capabilities: _subscriptionMappingCapabilities,
      isSubscription: true,
      readOnly: true,
      name: 'My renamed calendar',
      sourceName: 'Original provider calendar name',
    );
    await tester.pumpWidget(
      _wrap(_StubHubClient(calendarsToReturn: [calendar])),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('My renamed calendar'));
    await tester.pumpAndSettle();

    expect(
      find.text('Originally "Original provider calendar name" at the source.'),
      findsOneWidget,
    );
  });

  testWidgets('the effective name renders in the list, not sourceName', (
    tester,
  ) async {
    final calendar = _calendar(
      appearanceMode: 'subscription_mapping',
      capabilities: _subscriptionMappingCapabilities,
      isSubscription: true,
      readOnly: true,
      name: 'My renamed calendar',
      sourceName: 'Original provider calendar name',
    );
    await tester.pumpWidget(
      _wrap(_StubHubClient(calendarsToReturn: [calendar])),
    );
    await tester.pumpAndSettle();

    expect(find.text('My renamed calendar'), findsOneWidget);
    expect(find.text('Original provider calendar name'), findsNothing);
  });

  group('submitting the edit form', () {
    testWidgets('calls updateCalendarAppearance and not updateCalendar', (
      tester,
    ) async {
      final calendar = _calendar(
        appearanceMode: 'source_metadata',
        capabilities: _sourceMetadataCapabilities,
      );
      final stub = _StubHubClient(calendarsToReturn: [calendar]);

      await tester.pumpWidget(_wrap(stub));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Family'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      expect(stub.updateCalendarAppearanceCallCount, 1);
      expect(stub.updateCalendarCallCount, 0);
      expect(stub.lastAppearanceCall?.calendarId, calendar.id);
      expect(stub.lastAppearanceCall?.name, calendar.name);
    });

    testWidgets(
      'a CaleeHubException from updateCalendarAppearance shows a friendly message',
      (tester) async {
        final calendar = _calendar(
          appearanceMode: 'source_metadata',
          capabilities: _sourceMetadataCapabilities,
        );
        final stub = _StubHubClient(
          calendarsToReturn: [calendar],
          appearanceError: const CaleeHubException(
            statusCode: 502,
            code: 'UPSTREAM_ERROR',
            message: 'Something went wrong updating this calendar.',
          ),
        );

        await tester.pumpWidget(_wrap(stub));
        await tester.pumpAndSettle();

        await tester.tap(find.text('Family'));
        await tester.pumpAndSettle();

        await tester.tap(find.text('Save'));
        await tester.pumpAndSettle();

        expect(
          find.text('Something went wrong updating this calendar.'),
          findsOneWidget,
        );
        expect(find.textContaining('CaleeHubException'), findsNothing);
        expect(find.textContaining('StateError'), findsNothing);
      },
    );

    testWidgets(
      'creating a new calendar still uses createCalendar, not the appearance endpoint',
      (tester) async {
        // Regression guard: confirms the appearance-editing change didn't
        // leak into the create flow, which is explicitly out of scope for
        // this feature and must keep working unchanged.
        final stub = _StubHubClient(calendarsToReturn: const []);

        await tester.pumpWidget(
          MaterialApp(
            theme: CaleeTheme.buildThemeData(),
            home: CalendarCollectionsPage(
              hubClient: stub,
              accessToken: 'tok',
              services: [_calendarService()],
              accountId: 'acct1',
              isFamilyUxContext: true,
              autoOpenCreate: true,
            ),
          ),
        );
        await tester.pumpAndSettle();

        // Create sheet uses the plain, unconditional labels (never touched
        // by this feature).
        expect(find.text('Name'), findsOneWidget);
        expect(find.text('Name in Calee'), findsNothing);

        await tester.enterText(
          find.byType(TextFormField).first,
          'New Calendar',
        );
        await tester.tap(find.text('Save'));
        await tester.pumpAndSettle();

        expect(stub.createCalendarCallCount, 1);
        expect(stub.updateCalendarAppearanceCallCount, 0);
        expect(stub.updateCalendarCallCount, 0);
      },
    );
  });

  group('old-server fallback (no capabilities/appearanceMode/source* keys)', () {
    testWidgets(
      'a writable, non-subscription, non-readonly calendar opens the edit sheet',
      (tester) async {
        final calendar = ClientCalendar.fromJson({
          'id': 'cal1',
          'serviceId': 'svc1',
          'serviceName': 'Calee Portal',
          'name': 'Family',
          'color': '#FF9500',
          'components': ['VEVENT'],
          'primaryKind': 'calendar',
          'supportsEvents': true,
          'supportsTasks': false,
          'supportsChores': false,
          'readOnly': false,
          'isSubscription': false,
          'source': 'calee',
        });
        expect(calendar.capabilities.canEditAppearance, isTrue);

        await tester.pumpWidget(
          _wrap(_StubHubClient(calendarsToReturn: [calendar])),
        );
        await tester.pumpAndSettle();

        expect(find.text('Family'), findsOneWidget);

        await tester.tap(find.text('Family'));
        await tester.pumpAndSettle();

        expect(find.text('Name in Calee'), findsOneWidget);
      },
    );

    testWidgets('a subscription calendar is not tappable', (tester) async {
      final calendar = ClientCalendar.fromJson({
        'id': 'cal1',
        'serviceId': 'svc1',
        'serviceName': 'Calee Portal',
        'name': 'Shared calendar',
        'components': <String>[],
        'primaryKind': 'calendar',
        'supportsEvents': true,
        'supportsTasks': false,
        'supportsChores': false,
        'readOnly': true,
        'isSubscription': true,
        'source': 'calee',
      });
      expect(calendar.capabilities.canEditAppearance, isFalse);

      await tester.pumpWidget(
        _wrap(_StubHubClient(calendarsToReturn: [calendar])),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Shared calendar'));
      await tester.pumpAndSettle();

      expect(find.text('Name in Calee'), findsNothing);
    });
  });
}
