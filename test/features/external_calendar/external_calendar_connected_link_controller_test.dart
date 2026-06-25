// Unit tests for ExternalCalendarConnectedLinkController URI parsing and deduplication.

import 'package:calee_mobile/features/external_calendar/external_calendar_connected_intent.dart';
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
        final intent = ExternalCalendarConnectedLinkController.parseUri(uri);
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
        final intent = ExternalCalendarConnectedLinkController.parseUri(uri);
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
        final intent = ExternalCalendarConnectedLinkController.parseUri(uri);
        expect(intent, isNotNull);
        expect(intent!.isGoogle, isFalse);
        expect(intent.isError, isFalse);
      });

      test('parses link with no query parameters', () {
        final uri = Uri.parse('calee://external-calendar-connected');
        final intent = ExternalCalendarConnectedLinkController.parseUri(uri);
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
        final intent = ExternalCalendarConnectedLinkController.parseUri(uri);
        expect(intent, isNotNull);
        expect(intent!.isError, isTrue);
        expect(intent.reason, 'access_denied');
        expect(intent.providerKey, isNull);
      });

      test('parses error link without reason', () {
        final uri = Uri.parse(
          'calee://external-calendar-connected?status=error',
        );
        final intent = ExternalCalendarConnectedLinkController.parseUri(uri);
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

  group('ExternalCalendarConnectedLinkController deduplication', () {
    late ExternalCalendarConnectedLinkController controller;
    late DateTime fakeNow;

    setUp(() {
      controller = ExternalCalendarConnectedLinkController();
      fakeNow = DateTime(2026, 1, 1, 12);
      controller.clockForTesting = () => fakeNow;
    });

    tearDown(() => controller.dispose());

    final googleUri = Uri.parse(
      'calee://external-calendar-connected'
      '?providerKey=google_calendar&connectionId=conn1',
    );

    test('first deep link is processed and sets pendingIntent', () {
      int notifications = 0;
      controller.addListener(() => notifications++);

      controller.handleUri(googleUri);

      expect(notifications, 1);
      expect(controller.pendingIntent, isNotNull);
      expect(controller.pendingIntent!.connectionId, 'conn1');
    });

    test('identical link within 3 seconds is deduplicated', () {
      int notifications = 0;
      controller.addListener(() => notifications++);

      controller.handleUri(googleUri); // first
      fakeNow = fakeNow.add(const Duration(seconds: 1));
      controller.handleUri(googleUri); // duplicate within window

      expect(notifications, 1, reason: 'second identical link must be ignored');
    });

    test('identical link after 3+ seconds is processed again', () {
      int notifications = 0;
      controller.addListener(() => notifications++);

      controller.handleUri(googleUri);
      fakeNow = fakeNow.add(const Duration(seconds: 4));
      controller.handleUri(googleUri); // outside the 3-second window

      expect(notifications, 2);
    });

    test('link with different connectionId is not a duplicate', () {
      int notifications = 0;
      controller.addListener(() => notifications++);

      final uri1 = Uri.parse(
        'calee://external-calendar-connected'
        '?providerKey=google_calendar&connectionId=conn1',
      );
      final uri2 = Uri.parse(
        'calee://external-calendar-connected'
        '?providerKey=google_calendar&connectionId=conn2',
      );

      controller.handleUri(uri1);
      fakeNow = fakeNow.add(const Duration(milliseconds: 100));
      controller.handleUri(uri2);

      expect(notifications, 2);
      expect(controller.pendingIntent!.connectionId, 'conn2');
    });

    test('error link with different reason is not a duplicate', () {
      int notifications = 0;
      controller.addListener(() => notifications++);

      final errorUri1 = Uri.parse(
        'calee://external-calendar-connected?status=error&reason=denied',
      );
      final errorUri2 = Uri.parse(
        'calee://external-calendar-connected?status=error&reason=cancelled',
      );

      controller.handleUri(errorUri1);
      fakeNow = fakeNow.add(const Duration(milliseconds: 100));
      controller.handleUri(errorUri2);

      expect(notifications, 2);
    });

    test('dedup window resets after clearPending', () {
      // clearPending does NOT reset the dedup window — a re-notification
      // within 3 s of the original deep link is still deduplicated.
      int notifications = 0;
      controller.addListener(() => notifications++);

      controller.handleUri(googleUri);
      controller.clearPending();
      fakeNow = fakeNow.add(const Duration(seconds: 1));
      controller.handleUri(googleUri); // still within 3-second window

      // clearPending notifies (−1 call counted) but the duplicate is blocked.
      expect(
        notifications,
        2,
        reason: 'handleUri notification + clearPending notification; '
            'second handleUri must be deduplicated',
      );
    });

    test('disposed controller ignores deep links', () {
      controller.dispose();

      // Should not throw even after dispose.
      expect(() => controller.handleUri(googleUri), returnsNormally);
      expect(controller.pendingIntent, isNull);
    });
  });
}
