import 'package:flutter_test/flutter_test.dart';
import 'package:calee_mobile/features/display_setup/display_setup_link_controller.dart';

const _validToken = 'AbCdEfGhIjKlMnOpQrStUvWxYz0123456789_-AB';
const _shortToken = 'abc123';

void main() {
  group('parseDisplaySetupUri — HTTPS', () {
    test('accepts valid HTTPS link', () {
      final uri = Uri.parse(
        'https://hub.calee.com.au/native-login/$_validToken',
      );
      expect(DisplaySetupLinkController.parseDisplaySetupUri(uri), isNotNull);
    });

    test('extracts token from HTTPS link', () {
      final uri = Uri.parse(
        'https://hub.calee.com.au/native-login/$_validToken',
      );
      final intent = DisplaySetupLinkController.parseDisplaySetupUri(uri);
      expect(intent!.token, _validToken);
    });

    test('rejects short HTTPS token', () {
      final uri = Uri.parse(
        'https://hub.calee.com.au/native-login/$_shortToken',
      );
      expect(DisplaySetupLinkController.parseDisplaySetupUri(uri), isNull);
    });

    test('rejects wrong HTTPS host', () {
      final uri = Uri.parse(
        'https://other.calee.com.au/native-login/$_validToken',
      );
      expect(DisplaySetupLinkController.parseDisplaySetupUri(uri), isNull);
    });

    test('rejects wrong HTTPS path prefix', () {
      final uri = Uri.parse('https://hub.calee.com.au/login/$_validToken');
      expect(DisplaySetupLinkController.parseDisplaySetupUri(uri), isNull);
    });

    test('rejects /v1/native-login path', () {
      final uri = Uri.parse(
        'https://hub.calee.com.au/v1/native-login/$_validToken',
      );
      expect(DisplaySetupLinkController.parseDisplaySetupUri(uri), isNull);
    });

    test('rejects HTTPS link with extra path segment', () {
      final uri = Uri.parse(
        'https://hub.calee.com.au/native-login/$_validToken/extra',
      );
      expect(DisplaySetupLinkController.parseDisplaySetupUri(uri), isNull);
    });

    test('rejects HTTPS link with empty token', () {
      final uri = Uri.parse('https://hub.calee.com.au/native-login/');
      expect(DisplaySetupLinkController.parseDisplaySetupUri(uri), isNull);
    });

    test('sourceUri is preserved for HTTPS link', () {
      final uri = Uri.parse(
        'https://hub.calee.com.au/native-login/$_validToken',
      );
      final intent = DisplaySetupLinkController.parseDisplaySetupUri(uri);
      expect(intent!.sourceUri, uri);
    });
  });

  group('parseDisplaySetupUri — custom scheme', () {
    test('accepts valid calee:// link', () {
      final uri = Uri.parse('calee://native-login/$_validToken');
      expect(DisplaySetupLinkController.parseDisplaySetupUri(uri), isNotNull);
    });

    test('extracts token from custom scheme', () {
      final uri = Uri.parse('calee://native-login/$_validToken');
      final intent = DisplaySetupLinkController.parseDisplaySetupUri(uri);
      expect(intent!.token, _validToken);
    });

    test('rejects short calee token', () {
      final uri = Uri.parse('calee://native-login/$_shortToken');
      expect(DisplaySetupLinkController.parseDisplaySetupUri(uri), isNull);
    });

    test('rejects calee://wrong-host', () {
      final uri = Uri.parse('calee://wrong-host/$_validToken');
      expect(DisplaySetupLinkController.parseDisplaySetupUri(uri), isNull);
    });

    test('rejects calee://native-login with extra path segment', () {
      final uri = Uri.parse('calee://native-login/$_validToken/extra');
      expect(DisplaySetupLinkController.parseDisplaySetupUri(uri), isNull);
    });

    test('rejects calee://native-login with empty token', () {
      final uri = Uri.parse('calee://native-login/');
      expect(DisplaySetupLinkController.parseDisplaySetupUri(uri), isNull);
    });

    test('sourceUri is preserved for calee:// link', () {
      final uri = Uri.parse('calee://native-login/$_validToken');
      final intent = DisplaySetupLinkController.parseDisplaySetupUri(uri);
      expect(intent!.sourceUri, uri);
    });
  });

  group('parseDisplaySetupRouteName — /<token>', () {
    test('accepts valid token-only route', () {
      expect(
        DisplaySetupLinkController.parseDisplaySetupRouteName('/$_validToken'),
        isNotNull,
      );
    });

    test('extracts token from /<token>', () {
      final intent = DisplaySetupLinkController.parseDisplaySetupRouteName(
        '/$_validToken',
      );
      expect(intent!.token, _validToken);
    });

    test('sourceUri is calee://native-login/<token> for /<token>', () {
      final intent = DisplaySetupLinkController.parseDisplaySetupRouteName(
        '/$_validToken',
      );
      expect(intent!.sourceUri, Uri.parse('calee://native-login/$_validToken'));
    });

    test('rejects root route /', () {
      expect(
        DisplaySetupLinkController.parseDisplaySetupRouteName('/'),
        isNull,
      );
    });

    test('rejects /login (too short)', () {
      expect(
        DisplaySetupLinkController.parseDisplaySetupRouteName('/login'),
        isNull,
      );
    });

    test('rejects short token', () {
      expect(
        DisplaySetupLinkController.parseDisplaySetupRouteName('/$_shortToken'),
        isNull,
      );
    });
  });

  group('parseDisplaySetupRouteName — /native-login/<token>', () {
    test('accepts valid /native-login/<token> route', () {
      expect(
        DisplaySetupLinkController.parseDisplaySetupRouteName(
          '/native-login/$_validToken',
        ),
        isNotNull,
      );
    });

    test('extracts token from /native-login/<token>', () {
      final intent = DisplaySetupLinkController.parseDisplaySetupRouteName(
        '/native-login/$_validToken',
      );
      expect(intent!.token, _validToken);
    });

    test('sourceUri is HTTPS for /native-login/<token>', () {
      final intent = DisplaySetupLinkController.parseDisplaySetupRouteName(
        '/native-login/$_validToken',
      );
      expect(
        intent!.sourceUri,
        Uri.parse('https://hub.calee.com.au/native-login/$_validToken'),
      );
    });

    test('rejects /native-login/ with empty token', () {
      expect(
        DisplaySetupLinkController.parseDisplaySetupRouteName('/native-login/'),
        isNull,
      );
    });

    test('rejects /native-login/ with short token', () {
      expect(
        DisplaySetupLinkController.parseDisplaySetupRouteName(
          '/native-login/$_shortToken',
        ),
        isNull,
      );
    });

    test('rejects /native-login/<token>/extra', () {
      expect(
        DisplaySetupLinkController.parseDisplaySetupRouteName(
          '/native-login/$_validToken/extra',
        ),
        isNull,
      );
    });

    test('rejects /v1/native-login/<token>', () {
      expect(
        DisplaySetupLinkController.parseDisplaySetupRouteName(
          '/v1/native-login/$_validToken',
        ),
        isNull,
      );
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

    test('valid HTTPS URI sets pendingIntent', () {
      var notified = false;
      controller.addListener(() => notified = true);

      controller.injectUri(
        Uri.parse('https://hub.calee.com.au/native-login/$_validToken'),
      );

      expect(notified, isTrue);
      expect(controller.pendingIntent, isNotNull);
      expect(controller.pendingIntent!.token, _validToken);
    });

    test('valid calee:// URI sets pendingIntent', () {
      var notified = false;
      controller.addListener(() => notified = true);

      controller.injectUri(Uri.parse('calee://native-login/$_validToken'));

      expect(notified, isTrue);
      expect(controller.pendingIntent, isNotNull);
      expect(controller.pendingIntent!.token, _validToken);
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
        Uri.parse('https://hub.calee.com.au/native-login/$_validToken'),
      );

      var notified = false;
      controller.addListener(() => notified = true);
      controller.clearPending();

      expect(notified, isTrue);
      expect(controller.pendingIntent, isNull);
      expect(controller.pendingError, isNull);
    });

    test('second valid URI replaces pending intent', () {
      final token2 = 'ZzZzZzZzZzZzZzZzZzZzZzZzZzZzZzZz';
      controller.injectUri(
        Uri.parse('https://hub.calee.com.au/native-login/$_validToken'),
      );
      controller.injectUri(
        Uri.parse('https://hub.calee.com.au/native-login/$token2'),
      );

      expect(controller.pendingIntent!.token, token2);
    });
  });
}

// ─── Test helper ──────────────────────────────────────────────────────────────

class _ManualController extends DisplaySetupLinkController {
  void injectUri(Uri uri) {
    final intent = DisplaySetupLinkController.parseDisplaySetupUri(uri);
    if (intent == null) return;
    pendingIntent = intent;
    pendingError = null;
    notifyListeners();
  }
}
