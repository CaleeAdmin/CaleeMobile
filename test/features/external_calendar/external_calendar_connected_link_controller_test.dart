// Unit tests for ExternalCalendarConnectedLinkController URI parsing.

import 'package:calee_mobile/features/external_calendar/external_calendar_connected_link_controller.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ExternalCalendarConnectedLinkController.parseUri', () {
    group('successful google_calendar link', () {
      test('parses providerKey and connectionId', () {
        final uri = Uri.parse(
          'calee://external-calendar-connected'
          '?providerKey=google_calendar&connectionId=conn123',
        );
        final intent =
            ExternalCalendarConnectedLinkController.parseUri(uri);
        expect(intent, isNotNull);
        expect(intent!.providerKey, 'google_calendar');
        expect(intent.connectionId, 'conn123');
        expect(intent.isError, isFalse);
        expect(intent.isGoogle, isTrue);
      });

      test('parses link without connectionId', () {
        final uri = Uri.parse(
          'calee://external-calendar-connected?providerKey=google_calendar',
        );
        final intent =
            ExternalCalendarConnectedLinkController.parseUri(uri);
        expect(intent, isNotNull);
        expect(intent!.providerKey, 'google_calendar');
        expect(intent.connectionId, isNull);
        expect(intent.isError, isFalse);
        expect(intent.isGoogle, isTrue);
      });

      test('parses unknown providerKey as non-google', () {
        final uri = Uri.parse(
          'calee://external-calendar-connected?providerKey=outlook_calendar',
        );
        final intent =
            ExternalCalendarConnectedLinkController.parseUri(uri);
        expect(intent, isNotNull);
        expect(intent!.isGoogle, isFalse);
        expect(intent.isError, isFalse);
      });

      test('parses link with no query parameters', () {
        final uri = Uri.parse('calee://external-calendar-connected');
        final intent =
            ExternalCalendarConnectedLinkController.parseUri(uri);
        expect(intent, isNotNull);
        expect(intent!.providerKey, isNull);
        expect(intent.connectionId, isNull);
        expect(intent.isError, isFalse);
      });
    });

    group('error link', () {
      test('parses status=error and reason', () {
        final uri = Uri.parse(
          'calee://external-calendar-connected'
          '?status=error&reason=access_denied',
        );
        final intent =
            ExternalCalendarConnectedLinkController.parseUri(uri);
        expect(intent, isNotNull);
        expect(intent!.isError, isTrue);
        expect(intent.reason, 'access_denied');
        expect(intent.providerKey, isNull);
      });

      test('parses error link without reason', () {
        final uri = Uri.parse(
          'calee://external-calendar-connected?status=error',
        );
        final intent =
            ExternalCalendarConnectedLinkController.parseUri(uri);
        expect(intent, isNotNull);
        expect(intent!.isError, isTrue);
        expect(intent.reason, isNull);
      });
    });

    group('rejects non-matching URIs', () {
      test('returns null for wrong scheme', () {
        final uri = Uri.parse(
          'https://hub.calee.com.au/external-calendar-connected'
          '?providerKey=google_calendar',
        );
        expect(
          ExternalCalendarConnectedLinkController.parseUri(uri),
          isNull,
        );
      });

      test('returns null for wrong host', () {
        final uri = Uri.parse(
          'calee://native-login?providerKey=google_calendar',
        );
        expect(
          ExternalCalendarConnectedLinkController.parseUri(uri),
          isNull,
        );
      });

      test('returns null for different calee host', () {
        final uri = Uri.parse(
          'calee://external-calendar-return?providerKey=google_calendar',
        );
        expect(
          ExternalCalendarConnectedLinkController.parseUri(uri),
          isNull,
        );
      });

      test('returns null for http scheme', () {
        final uri = Uri.parse(
          'http://external-calendar-connected?providerKey=google_calendar',
        );
        expect(
          ExternalCalendarConnectedLinkController.parseUri(uri),
          isNull,
        );
      });
    });
  });
}
