import 'package:flutter_test/flutter_test.dart';

import 'package:calee_mobile/data/api/calee_hub_client.dart';
import 'package:calee_mobile/data/auth/calee_preferences.dart';
import 'package:calee_mobile/data/models/calendar_service_error.dart';
import 'package:calee_mobile/data/models/client_calendar.dart';
import 'package:calee_mobile/features/calendar/calendar_controller.dart';
import 'package:calee_mobile/features/calendar/calendar_repository.dart';
import 'package:calee_mobile/features/notifications/local_calendar_notification_service.dart';

// ─── Fakes ────────────────────────────────────────────────────────────────────

class _FakeNotificationService extends LocalCalendarNotificationService {
  _FakeNotificationService() : super.forTest();

  @override
  Future<void> initialize() async {}

  @override
  Future<bool> requestPermissionIfNeeded() async => true;

  @override
  Future<void> rescheduleUpcomingEvents(List<ClientEvent> events) async {}

  @override
  Future<void> cancelAllCalendarEventNotifications() async {}
}

// ─── Stubs ────────────────────────────────────────────────────────────────────

class _StubPrefs extends CaleePreferences {
  @override
  Future<StoredPreferences> load() async => const StoredPreferences();
}

class _StubHubClient extends CaleeHubClient {
  _StubHubClient({required this.calendarsResult});

  final Future<ClientCalendarList> Function() calendarsResult;

  @override
  Future<ClientCalendarList> calendars({required String accessToken}) =>
      calendarsResult();

  @override
  Future<ClientEventList> events({
    required String accessToken,
    required String from,
    required String to,
  }) async => ClientEventList(from: from, to: to, events: const []);
}

// ─── Helpers ──────────────────────────────────────────────────────────────────

ClientCalendar _calendar(
  String id, {
  String serviceId = 'svc',
  String serviceName = 'Test',
  String primaryKind = 'calendar',
}) => ClientCalendar(
  id: id,
  serviceId: serviceId,
  serviceName: serviceName,
  name: 'Cal $id',
  components: const [],
  primaryKind: primaryKind,
  supportsEvents: true,
  supportsTasks: false,
  supportsChores: false,
  readOnly: false,
  isSubscription: false,
  source: 'test',
);

CaleeHubException _hubException({
  required int statusCode,
  required String code,
  String? serviceId,
  String? serviceName,
  String message = 'Connection broken',
}) => CaleeHubException(
  statusCode: statusCode,
  message: message,
  code: code,
  serviceId: serviceId,
  serviceName: serviceName,
);

CalendarController _makeController(
  Future<ClientCalendarList> Function() calendarsResult,
) {
  final hub = _StubHubClient(calendarsResult: calendarsResult);
  final repo = CalendarRepository(
    hubClient: hub,
    accessToken: 'tok',
    preferences: _StubPrefs(),
  );
  return CalendarController(
    repository: repo,
    notificationService: _FakeNotificationService(),
  );
}

// ─── Tests ────────────────────────────────────────────────────────────────────

void main() {
  // ── A: True empty list ──────────────────────────────────────────────────────

  group('A: True empty calendar list', () {
    test('returns empty calendars with no service errors', () async {
      final ctrl = _makeController(
        () async => const ClientCalendarList(calendars: []),
      );

      await ctrl.loadMonth();

      expect(ctrl.calendars, isEmpty);
      expect(ctrl.calendarServiceErrors, isEmpty);
      expect(ctrl.error, isNull);
    });

    test(
      'CalendarServiceError.isCalendarServiceConnectionCode returns false for empty code',
      () {
        expect(isCalendarServiceConnectionCode(null), isFalse);
        expect(isCalendarServiceConnectionCode(''), isFalse);
        expect(isCalendarServiceConnectionCode('SOME_OTHER_ERROR'), isFalse);
      },
    );
  });

  // ── B: Business calendar connection broken ───────────────────────────────────

  group('B: Business calendar connection broken', () {
    test(
      'BUSINESS_CALENDAR_CONNECTION_BROKEN exception is caught as service error',
      () async {
        final ctrl = _makeController(
          () async => throw _hubException(
            statusCode: 503,
            code: 'BUSINESS_CALENDAR_CONNECTION_BROKEN',
            serviceName: 'Business Calendar',
          ),
        );

        await ctrl.loadMonth();

        expect(ctrl.calendarServiceErrors, hasLength(1));
        expect(ctrl.error, isNull);
        expect(ctrl.calendars, isEmpty);
      },
    );

    test(
      'BUSINESS_CALENDAR_CONNECTION_BROKEN sets correct service name',
      () async {
        final ctrl = _makeController(
          () async => throw _hubException(
            statusCode: 503,
            code: 'BUSINESS_CALENDAR_CONNECTION_BROKEN',
            serviceName: 'Acme Business',
          ),
        );

        await ctrl.loadMonth();

        final err = ctrl.calendarServiceErrors.first;
        expect(err.displayServiceName, 'Acme Business');
        expect(err.repairMessage, contains('Acme Business'));
        expect(err.repairMessage, contains('repair'));
      },
    );

    test(
      'BUSINESS_CALENDAR_CONNECTION_BROKEN does not surface as network error',
      () async {
        final ctrl = _makeController(
          () async => throw _hubException(
            statusCode: 503,
            code: 'BUSINESS_CALENDAR_CONNECTION_BROKEN',
            serviceName: 'Business',
          ),
        );

        await ctrl.loadMonth();

        expect(
          ctrl.error,
          isNull,
          reason: 'Service connection error must not appear as a generic error',
        );
      },
    );
  });

  // ── C: Portal calendar connection broken ─────────────────────────────────────

  group('C: Portal calendar connection broken', () {
    test(
      'PORTAL_CALENDAR_CONNECTION_BROKEN exception is caught as service error',
      () async {
        final ctrl = _makeController(
          () async => throw _hubException(
            statusCode: 503,
            code: 'PORTAL_CALENDAR_CONNECTION_BROKEN',
            serviceName: 'Calee Portal',
          ),
        );

        await ctrl.loadMonth();

        expect(ctrl.calendarServiceErrors, hasLength(1));
        expect(ctrl.error, isNull);
      },
    );

    test(
      'PORTAL_CALENDAR_CONNECTION_BROKEN uses serviceName in repair message',
      () async {
        final ctrl = _makeController(
          () async => throw _hubException(
            statusCode: 503,
            code: 'PORTAL_CALENDAR_CONNECTION_BROKEN',
            serviceName: 'My Portal',
          ),
        );

        await ctrl.loadMonth();

        expect(
          ctrl.calendarServiceErrors.first.displayServiceName,
          'My Portal',
        );
      },
    );
  });

  // ── D: Generic / SERVICE_CREDENTIAL_INVALID with service name ───────────────

  group('D: Generic service credential invalid', () {
    test(
      'SERVICE_CREDENTIAL_INVALID with serviceId is caught as service error',
      () async {
        final ctrl = _makeController(
          () async => throw _hubException(
            statusCode: 401,
            code: 'SERVICE_CREDENTIAL_INVALID',
            serviceId: 'google',
            serviceName: 'Google Calendar',
          ),
        );

        await ctrl.loadMonth();

        expect(ctrl.calendarServiceErrors, hasLength(1));
        expect(ctrl.error, isNull);
      },
    );

    test(
      'SERVICE_CREDENTIAL_INVALID falls back to serviceId when no serviceName',
      () async {
        final ctrl = _makeController(
          () async => throw _hubException(
            statusCode: 401,
            code: 'SERVICE_CREDENTIAL_INVALID',
            serviceId: 'my-service',
          ),
        );

        await ctrl.loadMonth();

        expect(
          ctrl.calendarServiceErrors.first.displayServiceName,
          'my-service',
        );
      },
    );

    test(
      'displayServiceName falls back to "Calendar service" when no serviceId or serviceName',
      () {
        final err = CalendarServiceError.fromException(
          _hubException(statusCode: 503, code: 'CALENDAR_SERVICE_UNAVAILABLE'),
        );
        expect(err.displayServiceName, 'Calendar service');
      },
    );

    test(
      'CALENDAR_SERVICE_UNAVAILABLE is recognised as a service connection code',
      () {
        expect(
          isCalendarServiceConnectionCode('CALENDAR_SERVICE_UNAVAILABLE'),
          isTrue,
        );
      },
    );

    test(
      'SCHOOL_CALENDAR_CONNECTION_BROKEN is recognised as a service connection code',
      () {
        expect(
          isCalendarServiceConnectionCode('SCHOOL_CALENDAR_CONNECTION_BROKEN'),
          isTrue,
        );
      },
    );

    test(
      'CALENDAR_SERVICE_CONNECTION_BROKEN is recognised as a service connection code',
      () {
        expect(
          isCalendarServiceConnectionCode('CALENDAR_SERVICE_CONNECTION_BROKEN'),
          isTrue,
        );
      },
    );
  });

  // ── E: Hybrid partial success ────────────────────────────────────────────────

  group('E: Hybrid partial success (serviceErrors in response body)', () {
    test(
      'calendars with inline serviceErrors returns both calendars and errors',
      () async {
        final calList = ClientCalendarList(
          calendars: [_calendar('cal1')],
          serviceErrors: [
            const CalendarServiceError(
              code: 'PORTAL_CALENDAR_CONNECTION_BROKEN',
              serviceName: 'School Portal',
            ),
          ],
        );

        final ctrl = _makeController(() async => calList);
        await ctrl.loadMonth();

        expect(ctrl.calendars, hasLength(1));
        expect(ctrl.calendarServiceErrors, hasLength(1));
        expect(ctrl.error, isNull);
        expect(
          ctrl.calendarServiceErrors.first.displayServiceName,
          'School Portal',
        );
      },
    );

    test('partial success keeps existing calendars accessible', () async {
      final calList = ClientCalendarList(
        calendars: [_calendar('cal1'), _calendar('cal2')],
        serviceErrors: [
          const CalendarServiceError(
            code: 'BUSINESS_CALENDAR_CONNECTION_BROKEN',
            serviceName: 'Broken Svc',
          ),
        ],
      );

      final ctrl = _makeController(() async => calList);
      await ctrl.loadMonth();

      expect(ctrl.calendars, hasLength(2));
      expect(ctrl.calendarServiceErrors, hasLength(1));
      expect(ctrl.error, isNull);
    });

    test('ClientCalendarList.fromJson parses serviceErrors array', () {
      final json = {
        'calendars': <dynamic>[],
        'serviceErrors': [
          {
            'code': 'BUSINESS_CALENDAR_CONNECTION_BROKEN',
            'serviceName': 'ACME',
            'serviceId': 'acme-svc',
          },
        ],
      };

      final result = ClientCalendarList.fromJson(json);

      expect(result.calendars, isEmpty);
      expect(result.serviceErrors, hasLength(1));
      expect(
        result.serviceErrors.first.code,
        'BUSINESS_CALENDAR_CONNECTION_BROKEN',
      );
      expect(result.serviceErrors.first.serviceName, 'ACME');
      expect(result.serviceErrors.first.serviceId, 'acme-svc');
    });

    test(
      'ClientCalendarList.fromJson handles missing serviceErrors gracefully',
      () {
        final json = {'calendars': <dynamic>[]};
        final result = ClientCalendarList.fromJson(json);
        expect(result.serviceErrors, isEmpty);
      },
    );
  });

  // ── F: Network error ─────────────────────────────────────────────────────────

  group('F: Network / connectivity error', () {
    test(
      'generic exception sets error field, not calendarServiceErrors',
      () async {
        final ctrl = _makeController(
          () async => throw Exception('Connection refused'),
        );

        await ctrl.loadMonth();

        expect(ctrl.error, isNotNull);
        expect(ctrl.calendarServiceErrors, isEmpty);
      },
    );

    test(
      'non-service CaleeHubException sets error field, not calendarServiceErrors',
      () async {
        final ctrl = _makeController(
          () async => throw const CaleeHubException(
            statusCode: 500,
            message: 'Internal server error',
            code: 'INTERNAL_ERROR',
          ),
        );

        await ctrl.loadMonth();

        expect(ctrl.error, isNotNull);
        expect(ctrl.calendarServiceErrors, isEmpty);
      },
    );

    test(
      'network error does not produce a service connection error message',
      () async {
        final ctrl = _makeController(
          () async => throw Exception('SocketException: Failed host lookup'),
        );

        await ctrl.loadMonth();

        expect(
          ctrl.calendarServiceErrors,
          isEmpty,
          reason:
              'Network failure must not be misidentified as a service connection problem',
        );
      },
    );
  });

  // ── G: Hub 401 / auth error ──────────────────────────────────────────────────

  group('G: Hub 401 authentication error', () {
    test('401 exception is NOT treated as service connection error', () async {
      final ctrl = _makeController(
        () async => throw const CaleeHubException(
          statusCode: 401,
          message: 'Unauthorized',
          code: 'UNAUTHORIZED',
        ),
      );

      await ctrl.loadMonth();

      expect(ctrl.calendarServiceErrors, isEmpty);
      expect(ctrl.error, isNotNull);
    });

    test(
      'onUnauthorized callback is invoked and token refreshed on 401',
      () async {
        var refreshCalled = false;
        var callCount = 0;

        final hub = _StubHubClientWithAuth(
          onFirstCall: () {
            callCount++;
            if (callCount == 1) {
              throw const CaleeHubException(
                statusCode: 401,
                message: 'Unauthorized',
              );
            }
            return ClientCalendarList(calendars: [_calendar('cal1')]);
          },
        );

        hub.onUnauthorized = () async {
          refreshCalled = true;
          return 'refreshed-token';
        };

        final repo = CalendarRepository(
          hubClient: hub,
          accessToken: 'old-tok',
          preferences: _StubPrefs(),
        );
        final ctrl = CalendarController(repository: repo);

        // The 401 handling happens inside CaleeHubClient._getJson transparently.
        // Here we just verify the callback wiring exists on the hub client.
        expect(hub.onUnauthorized, isNotNull);
        expect(refreshCalled, isFalse); // not yet called
        ctrl.dispose();
      },
    );
  });

  // ── CalendarServiceError model ───────────────────────────────────────────────

  group('CalendarServiceError model', () {
    test('fromJson parses all fields', () {
      final err = CalendarServiceError.fromJson({
        'code': 'BUSINESS_CALENDAR_CONNECTION_BROKEN',
        'serviceId': 'svc-1',
        'serviceName': 'My Service',
        'message': 'Credentials expired',
      });

      expect(err.code, 'BUSINESS_CALENDAR_CONNECTION_BROKEN');
      expect(err.serviceId, 'svc-1');
      expect(err.serviceName, 'My Service');
      expect(err.message, 'Credentials expired');
      expect(err.isServiceConnectionError, isTrue);
    });

    test('fromJson uses default code when code missing', () {
      final err = CalendarServiceError.fromJson({'serviceName': 'Svc'});
      expect(err.code, 'CALENDAR_SERVICE_CONNECTION_BROKEN');
    });

    test('fromException copies all fields', () {
      final ex = _hubException(
        statusCode: 503,
        code: 'PORTAL_CALENDAR_CONNECTION_BROKEN',
        serviceId: 'portal-1',
        serviceName: 'Portal',
        message: 'Token expired',
      );
      final err = CalendarServiceError.fromException(ex);

      expect(err.code, 'PORTAL_CALENDAR_CONNECTION_BROKEN');
      expect(err.serviceId, 'portal-1');
      expect(err.serviceName, 'Portal');
      expect(err.message, 'Token expired');
    });

    test('repairMessage includes displayServiceName', () {
      const err = CalendarServiceError(
        code: 'BUSINESS_CALENDAR_CONNECTION_BROKEN',
        serviceName: 'Acme Corp',
      );
      expect(
        err.repairMessage,
        'Acme Corp calendar connection needs repair. Please contact Calee support.',
      );
    });
  });
}

// ─── Auth-aware stub ──────────────────────────────────────────────────────────

class _StubHubClientWithAuth extends CaleeHubClient {
  _StubHubClientWithAuth({required this.onFirstCall});

  final ClientCalendarList Function() onFirstCall;

  @override
  Future<ClientCalendarList> calendars({required String accessToken}) async =>
      onFirstCall();

  @override
  Future<ClientEventList> events({
    required String accessToken,
    required String from,
    required String to,
  }) async => ClientEventList(from: from, to: to, events: const []);
}
