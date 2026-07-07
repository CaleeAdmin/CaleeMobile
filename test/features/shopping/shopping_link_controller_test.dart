// Unit tests for ShoppingLinkController URI parsing.

import 'package:calee_mobile/features/shopping/shopping_link_controller.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ShoppingLinkController.parseUri', () {
    group('custom scheme', () {
      test('parses weekStart from calee://shopping', () {
        final uri = Uri.parse('calee://shopping?weekStart=2026-07-06');
        final intent = ShoppingLinkController.parseUri(uri);
        expect(intent, isNotNull);
        expect(intent!.weekStart, DateTime(2026, 7, 6));
        expect(intent.sourceUri, uri);
      });

      test('parses link with no query parameters', () {
        final uri = Uri.parse('calee://shopping');
        final intent = ShoppingLinkController.parseUri(uri);
        expect(intent, isNotNull);
        expect(intent!.weekStart, isNull);
      });
    });

    group('https universal link', () {
      test('parses weekStart from hub.calee.com.au/mobile/shopping', () {
        final uri = Uri.parse(
          'https://hub.calee.com.au/mobile/shopping?weekStart=2026-07-06',
        );
        final intent = ShoppingLinkController.parseUri(uri);
        expect(intent, isNotNull);
        expect(intent!.weekStart, DateTime(2026, 7, 6));
        expect(intent.sourceUri, uri);
      });

      test('parses link with no query parameters', () {
        final uri = Uri.parse('https://hub.calee.com.au/mobile/shopping');
        final intent = ShoppingLinkController.parseUri(uri);
        expect(intent, isNotNull);
        expect(intent!.weekStart, isNull);
      });
    });

    group('missing or invalid weekStart falls back to null (current week)', () {
      test('missing weekStart', () {
        final uri = Uri.parse('calee://shopping');
        final intent = ShoppingLinkController.parseUri(uri);
        expect(intent, isNotNull);
        expect(intent!.weekStart, isNull);
      });

      test('empty weekStart', () {
        final uri = Uri.parse('calee://shopping?weekStart=');
        final intent = ShoppingLinkController.parseUri(uri);
        expect(intent, isNotNull);
        expect(intent!.weekStart, isNull);
      });

      test('malformed weekStart (not YYYY-MM-DD)', () {
        final uri = Uri.parse('calee://shopping?weekStart=06-07-2026');
        final intent = ShoppingLinkController.parseUri(uri);
        expect(intent, isNotNull);
        expect(intent!.weekStart, isNull);
      });

      test('non-numeric weekStart', () {
        final uri = Uri.parse('calee://shopping?weekStart=banana');
        final intent = ShoppingLinkController.parseUri(uri);
        expect(intent, isNotNull);
        expect(intent!.weekStart, isNull);
      });

      test('out-of-range month', () {
        final uri = Uri.parse('calee://shopping?weekStart=2026-13-01');
        final intent = ShoppingLinkController.parseUri(uri);
        expect(intent, isNotNull);
        expect(intent!.weekStart, isNull);
      });

      test('calendar date that does not exist (Feb 30)', () {
        final uri = Uri.parse('calee://shopping?weekStart=2026-02-30');
        final intent = ShoppingLinkController.parseUri(uri);
        expect(intent, isNotNull);
        expect(intent!.weekStart, isNull);
      });

      test('valid leap-day date is accepted', () {
        final uri = Uri.parse('calee://shopping?weekStart=2028-02-29');
        final intent = ShoppingLinkController.parseUri(uri);
        expect(intent, isNotNull);
        expect(intent!.weekStart, DateTime(2028, 2, 29));
      });
    });

    group('rejects non-matching URIs', () {
      test('returns null for wrong calee host', () {
        final uri = Uri.parse('calee://native-login?weekStart=2026-07-06');
        expect(ShoppingLinkController.parseUri(uri), isNull);
      });

      test('returns null for wrong https host', () {
        final uri = Uri.parse(
          'https://example.com/mobile/shopping?weekStart=2026-07-06',
        );
        expect(ShoppingLinkController.parseUri(uri), isNull);
      });

      test('returns null for wrong https path', () {
        final uri = Uri.parse(
          'https://hub.calee.com.au/shopping?weekStart=2026-07-06',
        );
        expect(ShoppingLinkController.parseUri(uri), isNull);
      });

      test('returns null for http (non-https) scheme', () {
        final uri = Uri.parse(
          'http://hub.calee.com.au/mobile/shopping?weekStart=2026-07-06',
        );
        expect(ShoppingLinkController.parseUri(uri), isNull);
      });
    });
  });

  group('ShoppingLinkIntent.canonicalKey', () {
    test('same weekStart dedups across HTTPS and calee:// schemes', () {
      final https = ShoppingLinkController.parseUri(
        Uri.parse(
          'https://hub.calee.com.au/mobile/shopping?weekStart=2026-07-06',
        ),
      )!;
      final custom = ShoppingLinkController.parseUri(
        Uri.parse('calee://shopping?weekStart=2026-07-06'),
      )!;

      expect(https.canonicalKey, custom.canonicalKey);
    });

    test('different weekStart values produce different keys', () {
      final week1 = ShoppingLinkController.parseUri(
        Uri.parse('calee://shopping?weekStart=2026-07-06'),
      )!;
      final week2 = ShoppingLinkController.parseUri(
        Uri.parse('calee://shopping?weekStart=2026-07-13'),
      )!;

      expect(week1.canonicalKey, isNot(week2.canonicalKey));
    });

    test('missing weekStart resolves to the same "current" key regardless '
        'of scheme', () {
      final https = ShoppingLinkController.parseUri(
        Uri.parse('https://hub.calee.com.au/mobile/shopping'),
      )!;
      final custom = ShoppingLinkController.parseUri(
        Uri.parse('calee://shopping'),
      )!;

      expect(https.canonicalKey, custom.canonicalKey);
    });
  });

  group('ShoppingLinkController', () {
    late ShoppingLinkController controller;

    setUp(() => controller = ShoppingLinkController());
    tearDown(() => controller.dispose());

    test('handleUri sets pendingIntent and notifies listeners', () {
      int notifications = 0;
      controller.addListener(() => notifications++);

      controller.handleUri(Uri.parse('calee://shopping?weekStart=2026-07-06'));

      expect(notifications, 1);
      expect(controller.pendingIntent, isNotNull);
      expect(controller.pendingIntent!.weekStart, DateTime(2026, 7, 6));
    });

    test('handleUri ignores non-matching links', () {
      int notifications = 0;
      controller.addListener(() => notifications++);

      controller.handleUri(Uri.parse('calee://native-login/abc'));

      expect(notifications, 0);
      expect(controller.pendingIntent, isNull);
    });

    test('clearPending resets pendingIntent and notifies', () {
      controller.handleUri(Uri.parse('calee://shopping?weekStart=2026-07-06'));
      expect(controller.pendingIntent, isNotNull);

      int notifications = 0;
      controller.addListener(() => notifications++);
      controller.clearPending();

      expect(notifications, 1);
      expect(controller.pendingIntent, isNull);
    });

    test('disposed controller ignores deep links', () {
      controller.dispose();

      expect(
        () => controller.handleUri(
          Uri.parse('calee://shopping?weekStart=2026-07-06'),
        ),
        returnsNormally,
      );
      expect(controller.pendingIntent, isNull);
    });
  });
}
