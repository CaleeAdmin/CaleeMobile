import 'package:calee_mobile/data/models/client_calendar.dart';
import 'package:calee_mobile/data/models/external_calendar_connection.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ExternalCalendarProvider.fromJson', () {
    test('parses all fields', () {
      final p = ExternalCalendarProvider.fromJson({
        'providerKey': 'google_calendar',
        'displayName': 'Google Calendar',
        'authType': 'oauth2',
        'supportsRead': true,
        'supportsWrite': false,
        'supportsCalendarList': true,
        'supportsIncrementalSync': true,
        'supportsPush': false,
      });

      expect(p.providerKey, 'google_calendar');
      expect(p.displayName, 'Google Calendar');
      expect(p.authType, 'oauth2');
      expect(p.supportsRead, isTrue);
      expect(p.supportsWrite, isFalse);
      expect(p.supportsCalendarList, isTrue);
      expect(p.supportsIncrementalSync, isTrue);
      expect(p.supportsPush, isFalse);
    });

    test('defaults booleans to false when missing', () {
      final p = ExternalCalendarProvider.fromJson({});
      expect(p.supportsRead, isFalse);
      expect(p.supportsWrite, isFalse);
      expect(p.supportsCalendarList, isFalse);
    });
  });

  group('ExternalCalendarConnection.fromJson', () {
    test('parses full object', () {
      final c = ExternalCalendarConnection.fromJson({
        'id': 'conn1',
        'providerKey': 'google_calendar',
        'displayName': 'My Google',
        'externalAccountEmail': 'user@gmail.com',
        'connectionStatus': 'active',
        'accessMode': 'read_only',
        'sourceOfTruthPolicy': 'external',
        'lastConnectedAt': '2024-01-01T00:00:00Z',
      });

      expect(c.id, 'conn1');
      expect(c.providerKey, 'google_calendar');
      expect(c.externalAccountEmail, 'user@gmail.com');
      expect(c.connectionStatus, 'active');
      expect(c.isActive, isTrue);
      expect(c.isGoogle, isTrue);
    });

    test('externalAccountEmail is null when absent', () {
      final c = ExternalCalendarConnection.fromJson({
        'id': 'conn2',
        'providerKey': 'google_calendar',
        'connectionStatus': 'active',
        'accessMode': 'read_only',
        'sourceOfTruthPolicy': 'external',
      });

      expect(c.externalAccountEmail, isNull);
      expect(c.isActive, isTrue);
    });

    test('isActive false for revoked status', () {
      final c = ExternalCalendarConnection.fromJson({
        'id': 'conn3',
        'connectionStatus': 'revoked',
        'accessMode': 'read_only',
        'sourceOfTruthPolicy': 'external',
      });

      expect(c.isActive, isFalse);
    });
  });

  group('ExternalCalendarPrivacySettings', () {
    test('defaults match spec', () {
      const d = ExternalCalendarPrivacySettings.defaults;
      expect(d.showTitle, isTrue);
      expect(d.showLocation, isTrue);
      expect(d.showDescription, isFalse);
      expect(d.showAttendees, isFalse);
      expect(d.showOrganizer, isFalse);
      expect(d.privateEventMode, 'busy_only');
    });

    test('fromJson parses and toJson round-trips', () {
      final p = ExternalCalendarPrivacySettings.fromJson({
        'showTitle': false,
        'showLocation': false,
        'showDescription': true,
        'showAttendees': true,
        'showOrganizer': true,
        'privateEventMode': 'show_as_busy',
      });

      expect(p.showTitle, isFalse);
      expect(p.showDescription, isTrue);
      expect(p.privateEventMode, 'show_as_busy');

      final j = p.toJson();
      expect(j['showTitle'], isFalse);
      expect(j['showDescription'], isTrue);
      expect(j['privateEventMode'], 'show_as_busy');
    });
  });

  group('ExternalCalendar.fromJson', () {
    test('parses all fields including privacy settings', () {
      final cal = ExternalCalendar.fromJson({
        'id': 'ext1',
        'providerKey': 'google_calendar',
        'externalCalendarId': 'primary',
        'displayName': 'Personal',
        'providerDisplayName': 'Google Calendar',
        'color': '#4285F4',
        'timeZone': 'Australia/Perth',
        'accessRole': 'owner',
        'syncEnabled': true,
        'visibilityStatus': 'visible',
        'accessMode': 'read_only',
        'sourceOfTruthPolicy': 'external',
        'privacySettings': {
          'showTitle': true,
          'showLocation': true,
          'showDescription': false,
          'showAttendees': false,
          'showOrganizer': false,
          'privateEventMode': 'busy_only',
        },
        'syncStatus': 'ok',
        'lastSyncedAt': '2024-01-01T12:00:00Z',
      });

      expect(cal.id, 'ext1');
      expect(cal.displayName, 'Personal');
      expect(cal.syncEnabled, isTrue);
      expect(cal.privacySettings.showTitle, isTrue);
      expect(cal.privacySettings.showDescription, isFalse);
      expect(cal.privacySettings.privateEventMode, 'busy_only');
    });

    test('uses default privacy settings when privacySettings absent', () {
      final cal = ExternalCalendar.fromJson({
        'id': 'ext2',
        'displayName': 'Work',
        'syncEnabled': false,
      });

      expect(
        cal.privacySettings.showTitle,
        ExternalCalendarPrivacySettings.defaults.showTitle,
      );
      expect(
        cal.privacySettings.showDescription,
        ExternalCalendarPrivacySettings.defaults.showDescription,
      );
    });
  });

  group('ClientCalendar extended fields', () {
    test('parses providerKey and isExternal getter', () {
      final cal = ClientCalendar.fromJson({
        'id': 'external:abc',
        'source': 'external',
        'providerKey': 'google_calendar',
        'accessMode': 'read_only',
        'syncStatus': 'ok',
        'lastSyncedAt': '2024-01-01T00:00:00Z',
      });

      expect(cal.source, 'external');
      expect(cal.providerKey, 'google_calendar');
      expect(cal.isExternal, isTrue);
      expect(cal.isGoogleCalendar, isTrue);
    });

    test('isExternal false for regular calendar', () {
      final cal = ClientCalendar.fromJson({
        'id': 'cal1',
        'source': 'calee',
        'serviceId': 'svc1',
      });

      expect(cal.isExternal, isFalse);
      expect(cal.isGoogleCalendar, isFalse);
    });
  });

  group('ExternalCalendarSyncResult.fromJson', () {
    test('parses all fields from backend sync subobject', () {
      final result = ExternalCalendarSyncResult.fromJson({
        'status': 'ok',
        'mode': 'full',
        'eventCount': 84,
        'deletedCount': 3,
        'nextSyncAvailable': true,
      });

      expect(result.status, 'ok');
      expect(result.mode, 'full');
      expect(result.eventCount, 84);
      expect(result.deletedCount, 3);
      expect(result.nextSyncAvailable, isTrue);
      expect(result.isSuccess, isTrue);
    });

    test('isSuccess true for status "success"', () {
      final result = ExternalCalendarSyncResult.fromJson({'status': 'success'});
      expect(result.isSuccess, isTrue);
    });

    test('isSuccess false for non-ok status', () {
      final result = ExternalCalendarSyncResult.fromJson({'status': 'error'});
      expect(result.isSuccess, isFalse);
    });

    test('defaults when fields are missing', () {
      final result = ExternalCalendarSyncResult.fromJson({});

      expect(result.status, '');
      expect(result.mode, '');
      expect(result.eventCount, 0);
      expect(result.deletedCount, 0);
      expect(result.nextSyncAvailable, isFalse);
      expect(result.isSuccess, isFalse);
    });

    test('parses incremental sync mode', () {
      final result = ExternalCalendarSyncResult.fromJson({
        'status': 'ok',
        'mode': 'incremental',
        'eventCount': 5,
        'deletedCount': 0,
        'nextSyncAvailable': false,
      });

      expect(result.mode, 'incremental');
      expect(result.nextSyncAvailable, isFalse);
    });
  });

  group('ClientEvent extended fields', () {
    test('parses providerKey, readOnly, timeZone', () {
      final event = ClientEvent.fromJson({
        'id': 'external:evt1',
        'source': 'external',
        'providerKey': 'google_calendar',
        'readOnly': true,
        'timeZone': 'Australia/Perth',
        'title': 'Team meeting',
        'startsAt': '2024-01-01T09:00:00Z',
        'endsAt': '2024-01-01T10:00:00Z',
        'allDay': false,
        'recurring': false,
      });

      expect(event.providerKey, 'google_calendar');
      expect(event.readOnly, isTrue);
      expect(event.timeZone, 'Australia/Perth');
      expect(event.isExternal, isTrue);
      expect(event.isReadOnly, isTrue);
      expect(event.isGoogleEvent, isTrue);
    });

    test('isReadOnly true for external source even if readOnly field is false',
        () {
      final event = ClientEvent.fromJson({
        'id': 'external:evt2',
        'source': 'external',
        'readOnly': false,
        'recurring': false,
      });

      expect(event.isExternal, isTrue);
      expect(event.isReadOnly, isTrue);
    });

    test('writableEventId returns id when isReadOnly', () {
      final event = ClientEvent.fromJson({
        'id': 'external:evt3',
        'source': 'external',
        'readOnly': true,
        'recurring': true,
        'seriesId': 'series1',
      });

      expect(event.writableEventId, 'external:evt3');
    });

    test('regular recurring event still returns seriesId', () {
      final event = ClientEvent.fromJson({
        'id': 'evt4',
        'source': 'calee',
        'readOnly': false,
        'recurring': true,
        'seriesId': 'series2',
      });

      expect(event.isReadOnly, isFalse);
      expect(event.writableEventId, 'series2');
    });
  });
}
