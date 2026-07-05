// Unit tests for ShoppingListLinkController URI parsing and state.
//
// Covers: the tablet's QR link `https://hub.calee.com.au/app/shopping-list/
// {listId}` is accepted and its listId extracted; other hosts/paths/schemes
// are rejected; controller state (pendingIntent, clearPending) behaves like
// the other link controllers in this app.

import 'package:calee_mobile/features/shopping/shopping_list_link_controller.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ShoppingListLinkController.parseUri', () {
    test('accepts a valid shopping-list link', () {
      final uri = Uri.parse('https://hub.calee.com.au/app/shopping-list/42');
      final intent = ShoppingListLinkController.parseUri(uri);

      expect(intent, isNotNull);
      expect(intent!.listId, 42);
      expect(intent.sourceUri, uri);
    });

    test('rejects http scheme', () {
      final uri = Uri.parse('http://hub.calee.com.au/app/shopping-list/42');
      expect(ShoppingListLinkController.parseUri(uri), isNull);
    });

    test('rejects the unregistered bare calee.com.au host', () {
      final uri = Uri.parse('https://calee.com.au/app/shopping-list/42');
      expect(ShoppingListLinkController.parseUri(uri), isNull);
    });

    test('rejects a different subdomain', () {
      final uri = Uri.parse(
        'https://calembed.calee.com.au/app/shopping-list/42',
      );
      expect(ShoppingListLinkController.parseUri(uri), isNull);
    });

    test('rejects wrong path prefix', () {
      final uri = Uri.parse('https://hub.calee.com.au/shopping-list/42');
      expect(ShoppingListLinkController.parseUri(uri), isNull);
    });

    test('rejects missing list id', () {
      final uri = Uri.parse('https://hub.calee.com.au/app/shopping-list/');
      expect(ShoppingListLinkController.parseUri(uri), isNull);
    });

    test('rejects non-numeric list id', () {
      final uri = Uri.parse('https://hub.calee.com.au/app/shopping-list/abc');
      expect(ShoppingListLinkController.parseUri(uri), isNull);
    });

    test('rejects extra path segments', () {
      final uri = Uri.parse(
        'https://hub.calee.com.au/app/shopping-list/42/extra',
      );
      expect(ShoppingListLinkController.parseUri(uri), isNull);
    });

    test('rejects a custom scheme', () {
      final uri = Uri.parse('calee://app/shopping-list/42');
      expect(ShoppingListLinkController.parseUri(uri), isNull);
    });
  });

  group('ShoppingListLinkController state', () {
    late ShoppingListLinkController controller;

    setUp(() => controller = ShoppingListLinkController());
    tearDown(() => controller.dispose());

    test('pendingIntent is null initially', () {
      expect(controller.pendingIntent, isNull);
    });

    test('valid URI sets pendingIntent and notifies', () {
      var notified = false;
      controller.addListener(() => notified = true);

      controller.handleUri(
        Uri.parse('https://hub.calee.com.au/app/shopping-list/7'),
      );

      expect(notified, isTrue);
      expect(controller.pendingIntent, isNotNull);
      expect(controller.pendingIntent!.listId, 7);
    });

    test('invalid URI leaves pendingIntent null and does not notify', () {
      var notified = false;
      controller.addListener(() => notified = true);

      controller.handleUri(Uri.parse('https://other.example.com/foo'));

      expect(notified, isFalse);
      expect(controller.pendingIntent, isNull);
    });

    test('clearPending clears the intent and notifies', () {
      controller.handleUri(
        Uri.parse('https://hub.calee.com.au/app/shopping-list/7'),
      );

      var notified = false;
      controller.addListener(() => notified = true);
      controller.clearPending();

      expect(notified, isTrue);
      expect(controller.pendingIntent, isNull);
    });

    test('a second valid URI replaces the pending intent', () {
      controller.handleUri(
        Uri.parse('https://hub.calee.com.au/app/shopping-list/7'),
      );
      controller.handleUri(
        Uri.parse('https://hub.calee.com.au/app/shopping-list/8'),
      );

      expect(controller.pendingIntent!.listId, 8);
    });

    test('disposed controller ignores deep links', () {
      controller.dispose();

      expect(
        () => controller.handleUri(
          Uri.parse('https://hub.calee.com.au/app/shopping-list/7'),
        ),
        returnsNormally,
      );
      expect(controller.pendingIntent, isNull);
    });
  });
}
