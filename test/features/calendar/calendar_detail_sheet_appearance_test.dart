// Widget tests for appearance (name/colour) editing in CalendarDetailSheet.
//
// Covers: edit-availability and copy per ClientCalendar.appearanceMode,
// submitting calls updateCalendarAppearance() (never the old updateCalendar()),
// friendly error surfacing, sourceName preservation, and the old-server
// fallback (no capabilities/appearanceMode/sourceName/sourceColor keys sent).
//
// test/features/settings/calendar_collections_appearance_test.dart uses the
// identical fixture-calendars-per-appearanceMode shape so the two surfaces'
// edit-availability decisions can be compared directly.

import 'package:calee_mobile/data/api/calee_hub_client.dart';
import 'package:calee_mobile/data/models/client_calendar.dart';
import 'package:calee_mobile/features/calendar/widgets/calendar_detail_sheet.dart';
import 'package:calee_mobile/ui/calee_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _StubHubClient extends CaleeHubClient {
  _StubHubClient({this.appearanceResult, this.appearanceError})
    : super(baseUri: Uri.parse('http://localhost'));

  final ClientCalendar? appearanceResult;
  final Object? appearanceError;

  int updateCalendarAppearanceCallCount = 0;
  int updateCalendarCallCount = 0;
  ({String calendarId, String name, String? color})? lastAppearanceCall;

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
    return appearanceResult!;
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
}

// ── Fixture calendars — one per appearanceMode, kept identical to
// test/features/settings/calendar_collections_appearance_test.dart so both
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

Widget _wrap(
  ClientCalendar calendar, {
  required CaleeHubClient hubClient,
  bool initiallyVisible = true,
  void Function(String? message)? onMutated,
}) => MaterialApp(
  theme: CaleeTheme.buildThemeData(),
  home: Scaffold(
    body: CalendarDetailSheet(
      calendar: calendar,
      color: CaleeColors.dotBlue,
      hubClient: hubClient,
      accessToken: 'tok',
      initiallyVisible: initiallyVisible,
      onToggleAndClose: () {},
      onMutated: onMutated ?? (_) {},
    ),
  ),
);

void main() {
  group('edit action visibility per appearanceMode', () {
    testWidgets('source_metadata shows the edit action', (tester) async {
      await tester.pumpWidget(
        _wrap(
          _calendar(
            appearanceMode: 'source_metadata',
            capabilities: _sourceMetadataCapabilities,
          ),
          hubClient: _StubHubClient(),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Edit Name & Colour'), findsOneWidget);
    });

    testWidgets('subscription_mapping shows the edit action', (tester) async {
      await tester.pumpWidget(
        _wrap(
          _calendar(
            appearanceMode: 'subscription_mapping',
            capabilities: _subscriptionMappingCapabilities,
            isSubscription: true,
            readOnly: true,
          ),
          hubClient: _StubHubClient(),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Edit Name & Colour'), findsOneWidget);
    });

    testWidgets('external_calendar shows the edit action', (tester) async {
      await tester.pumpWidget(
        _wrap(
          _calendar(
            appearanceMode: 'external_calendar',
            capabilities: _externalCalendarCapabilities,
            readOnly: true,
          ),
          hubClient: _StubHubClient(),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Edit Name & Colour'), findsOneWidget);
    });

    testWidgets(
      'unsupported hides the edit action and shows the owner-managed message',
      (tester) async {
        await tester.pumpWidget(
          _wrap(
            _calendar(
              appearanceMode: 'unsupported',
              capabilities: _unsupportedCapabilities,
              readOnly: true,
            ),
            hubClient: _StubHubClient(),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.text('Edit Name & Colour'), findsNothing);
        expect(
          find.text('This shared calendar is managed by its owner.'),
          findsOneWidget,
        );
      },
    );
  });

  group('mode-specific explanatory copy in the edit view', () {
    testWidgets('subscription_mapping shows the Calee-only-appearance copy', (
      tester,
    ) async {
      await tester.pumpWidget(
        _wrap(
          _calendar(
            appearanceMode: 'subscription_mapping',
            capabilities: _subscriptionMappingCapabilities,
            isSubscription: true,
            readOnly: true,
          ),
          hubClient: _StubHubClient(),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Edit Name & Colour'));
      await tester.pumpAndSettle();

      expect(
        find.text(
          'These changes only affect how this calendar appears in Calee.',
        ),
        findsOneWidget,
      );
    });

    testWidgets('external_calendar shows the Calee-only-appearance copy', (
      tester,
    ) async {
      await tester.pumpWidget(
        _wrap(
          _calendar(
            appearanceMode: 'external_calendar',
            capabilities: _externalCalendarCapabilities,
          ),
          hubClient: _StubHubClient(),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Edit Name & Colour'));
      await tester.pumpAndSettle();

      expect(
        find.text(
          'These changes only affect how this calendar appears in Calee.',
        ),
        findsOneWidget,
      );
    });

    testWidgets('source_metadata shows the updates-name-and-colour copy', (
      tester,
    ) async {
      await tester.pumpWidget(
        _wrap(
          _calendar(
            appearanceMode: 'source_metadata',
            capabilities: _sourceMetadataCapabilities,
          ),
          hubClient: _StubHubClient(),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Edit Name & Colour'));
      await tester.pumpAndSettle();

      expect(
        find.text('This updates the calendar name and colour.'),
        findsOneWidget,
      );
    });
  });

  testWidgets('field labels read "Name in Calee" / "Colour in Calee"', (
    tester,
  ) async {
    await tester.pumpWidget(
      _wrap(
        _calendar(
          appearanceMode: 'source_metadata',
          capabilities: _sourceMetadataCapabilities,
        ),
        hubClient: _StubHubClient(),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Edit Name & Colour'));
    await tester.pumpAndSettle();

    expect(find.text('Name in Calee'), findsOneWidget);
    expect(find.text('Colour in Calee'), findsOneWidget);
  });

  testWidgets('sourceName is preserved and shown when it differs from name', (
    tester,
  ) async {
    await tester.pumpWidget(
      _wrap(
        _calendar(
          appearanceMode: 'subscription_mapping',
          capabilities: _subscriptionMappingCapabilities,
          isSubscription: true,
          readOnly: true,
          name: 'My renamed calendar',
          sourceName: 'Original provider calendar name',
        ),
        hubClient: _StubHubClient(),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Edit Name & Colour'));
    await tester.pumpAndSettle();

    expect(
      find.text('Originally "Original provider calendar name" at the source.'),
      findsOneWidget,
    );
  });

  testWidgets(
    'sourceName round-trips through fromJson and is accessible on the model',
    (tester) async {
      final calendar = ClientCalendar.fromJson({
        'id': 'cal1',
        'serviceId': 'svc1',
        'serviceName': 'Calee Portal',
        'name': 'My renamed calendar',
        'color': '#FF9500',
        'components': ['VEVENT'],
        'primaryKind': 'calendar',
        'supportsEvents': true,
        'supportsTasks': false,
        'supportsChores': false,
        'readOnly': true,
        'isSubscription': true,
        'source': 'calee',
        'sourceName': 'Original provider calendar name',
        'sourceColor': null,
        'appearanceMode': 'subscription_mapping',
        'capabilities': {
          'canEditAppearance': true,
          'canEditEvents': false,
          'canEditSourceMetadata': false,
          'canRemoveFromCalee': true,
          'canDeleteSource': false,
        },
      });

      expect(calendar.sourceName, 'Original provider calendar name');

      await tester.pumpWidget(_wrap(calendar, hubClient: _StubHubClient()));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Edit Name & Colour'));
      await tester.pumpAndSettle();

      expect(
        find.text(
          'Originally "Original provider calendar name" at the source.',
        ),
        findsOneWidget,
      );
    },
  );

  group('submitting the edit form', () {
    testWidgets('calls updateCalendarAppearance and not updateCalendar', (
      tester,
    ) async {
      final calendar = _calendar(
        appearanceMode: 'source_metadata',
        capabilities: _sourceMetadataCapabilities,
      );
      final stub = _StubHubClient(appearanceResult: calendar);
      String? mutatedMessage;

      await tester.pumpWidget(
        _wrap(calendar, hubClient: stub, onMutated: (m) => mutatedMessage = m),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Edit Name & Colour'));
      await tester.pumpAndSettle();

      // Not pumpAndSettle(): on success _submitEdit() deliberately leaves
      // _isSubmitting true (the real caller navigates away via onMutated,
      // which this stub doesn't do), so the Save button's spinner would
      // animate forever and pumpAndSettle() would never return.
      await tester.tap(find.text('Save'));
      await tester.pump();
      await tester.pump();

      expect(stub.updateCalendarAppearanceCallCount, 1);
      expect(stub.updateCalendarCallCount, 0);
      expect(stub.lastAppearanceCall?.calendarId, calendar.id);
      expect(stub.lastAppearanceCall?.name, calendar.name);
      expect(mutatedMessage, isNotNull);
    });

    testWidgets(
      'a CaleeHubException from updateCalendarAppearance shows a friendly message',
      (tester) async {
        final calendar = _calendar(
          appearanceMode: 'source_metadata',
          capabilities: _sourceMetadataCapabilities,
        );
        final stub = _StubHubClient(
          appearanceError: const CaleeHubException(
            statusCode: 409,
            code: 'CALENDAR_APPEARANCE_NOT_SUPPORTED',
            message: 'This shared calendar is managed by its owner.',
          ),
        );

        await tester.pumpWidget(_wrap(calendar, hubClient: stub));
        await tester.pumpAndSettle();

        await tester.tap(find.text('Edit Name & Colour'));
        await tester.pumpAndSettle();

        await tester.tap(find.text('Save'));
        await tester.pumpAndSettle();

        // A friendly, stable message is shown — never a raw exception dump
        // (e.g. the exception's runtimeType or an unhandled-error banner).
        expect(
          find.textContaining('Unable to update calendar.'),
          findsOneWidget,
        );
        expect(find.textContaining('CaleeHubException'), findsNothing);
      },
    );
  });

  group('old-server fallback (no capabilities/appearanceMode/source* keys)', () {
    testWidgets(
      'a writable, non-subscription, non-readonly calendar renders and shows the edit action',
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

        await tester.pumpWidget(_wrap(calendar, hubClient: _StubHubClient()));
        await tester.pumpAndSettle();

        expect(find.text('Family'), findsOneWidget);
        expect(find.text('Edit Name & Colour'), findsOneWidget);
      },
    );

    testWidgets('a subscription calendar does not show the edit action', (
      tester,
    ) async {
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

      await tester.pumpWidget(_wrap(calendar, hubClient: _StubHubClient()));
      await tester.pumpAndSettle();

      expect(find.text('Edit Name & Colour'), findsNothing);
    });
  });

  testWidgets('the effective name renders in the header, not sourceName', (
    tester,
  ) async {
    await tester.pumpWidget(
      _wrap(
        _calendar(
          appearanceMode: 'subscription_mapping',
          capabilities: _subscriptionMappingCapabilities,
          isSubscription: true,
          readOnly: true,
          name: 'My renamed calendar',
          sourceName: 'Original provider calendar name',
        ),
        hubClient: _StubHubClient(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('My renamed calendar'), findsOneWidget);
    expect(find.text('Original provider calendar name'), findsNothing);
  });
}
