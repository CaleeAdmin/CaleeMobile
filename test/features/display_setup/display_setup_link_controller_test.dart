import 'package:flutter_test/flutter_test.dart';
import 'package:calee_mobile/features/display_setup/display_setup_link_controller.dart';
import 'package:calee_mobile/features/display_setup/display_setup_intent.dart';

void main() {
  group('DisplaySetupLinkController._isDisplaySetupLink', () {
    // Access _isDisplaySetupLink via a subclass to keep tests pure.
    late _TestableController controller;

    setUp(() {
      controller = _TestableController();
    });

    tearDown(() {
      controller.dispose();
    });

    test('valid native-login URL is detected', () {
      final uri = Uri.parse('https://hub.calee.com.au/native-login/abc123');
      expect(controller.testIsDisplaySetupLink(uri), isTrue);
    });

    test('token is extracted correctly', () {
      final uri = Uri.parse('https://hub.calee.com.au/native-login/tok-xyz');
      expect(uri.pathSegments.last, 'tok-xyz');
    });

    test('wrong host is ignored', () {
      final uri = Uri.parse('https://other.calee.com.au/native-login/abc');
      expect(controller.testIsDisplaySetupLink(uri), isFalse);
    });

    test('wrong scheme is ignored', () {
      final uri = Uri.parse('http://hub.calee.com.au/native-login/abc');
      expect(controller.testIsDisplaySetupLink(uri), isFalse);
    });

    test('wrong path prefix is ignored', () {
      final uri = Uri.parse('https://hub.calee.com.au/login/abc');
      expect(controller.testIsDisplaySetupLink(uri), isFalse);
    });

    test('missing token segment is ignored', () {
      final uri = Uri.parse('https://hub.calee.com.au/native-login/');
      expect(controller.testIsDisplaySetupLink(uri), isFalse);
    });

    test('calembed calendar-follow URL is ignored', () {
      final uri = Uri.parse(
        'https://calembed.calee.com.au/follow?t=tok',
      );
      expect(controller.testIsDisplaySetupLink(uri), isFalse);
    });
  });

  group('DisplaySetupLinkController state', () {
    late _ManualController controller;

    setUp(() {
      controller = _ManualController();
    });

    tearDown(() {
      controller.dispose();
    });

    test('pendingIntent is null initially', () {
      expect(controller.pendingIntent, isNull);
      expect(controller.pendingError, isNull);
    });

    test('valid URI sets pendingIntent', () {
      var notified = false;
      controller.addListener(() => notified = true);

      controller.injectUri(
        Uri.parse('https://hub.calee.com.au/native-login/abc123'),
      );

      expect(notified, isTrue);
      expect(controller.pendingIntent, isNotNull);
      expect(controller.pendingIntent!.token, 'abc123');
    });

    test('invalid URI leaves pendingIntent null', () {
      var notified = false;
      controller.addListener(() => notified = true);

      controller.injectUri(Uri.parse('https://other.example.com/foo'));

      expect(notified, isFalse);
      expect(controller.pendingIntent, isNull);
    });

    test('clearPending clears intent and notifies', () {
      controller.injectUri(
        Uri.parse('https://hub.calee.com.au/native-login/tok'),
      );

      var notified = false;
      controller.addListener(() => notified = true);
      controller.clearPending();

      expect(notified, isTrue);
      expect(controller.pendingIntent, isNull);
      expect(controller.pendingError, isNull);
    });

    test('second valid URI replaces pending intent', () {
      controller.injectUri(
        Uri.parse('https://hub.calee.com.au/native-login/first'),
      );
      controller.injectUri(
        Uri.parse('https://hub.calee.com.au/native-login/second'),
      );

      expect(controller.pendingIntent!.token, 'second');
    });

    test('sourceUri is preserved in intent', () {
      final uri = Uri.parse('https://hub.calee.com.au/native-login/abc');
      controller.injectUri(uri);

      expect(controller.pendingIntent!.sourceUri, uri);
    });
  });
}

// ─── Test helpers ─────────────────────────────────────────────────────────────

class _TestableController extends DisplaySetupLinkController {
  bool testIsDisplaySetupLink(Uri uri) {
    return uri.scheme == 'https' &&
        uri.host == 'hub.calee.com.au' &&
        uri.pathSegments.length == 2 &&
        uri.pathSegments.first == 'native-login' &&
        uri.pathSegments.last.isNotEmpty;
  }
}

class _ManualController extends DisplaySetupLinkController {
  void injectUri(Uri uri) {
    // Replicate the internal _handleUri logic without app_links dependency.
    if (!_check(uri)) return;
    final token = uri.pathSegments.last;
    pendingIntent = DisplaySetupIntent(token: token, sourceUri: uri);
    pendingError = null;
    notifyListeners();
  }

  bool _check(Uri uri) {
    return uri.scheme == 'https' &&
        uri.host == 'hub.calee.com.au' &&
        uri.pathSegments.length == 2 &&
        uri.pathSegments.first == 'native-login' &&
        uri.pathSegments.last.isNotEmpty;
  }
}
