import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:calee_mobile/features/display_setup/display_setup_intent.dart';
import 'package:calee_mobile/features/display_setup/display_setup_link_controller.dart';

const _validToken = 'AbCdEfGhIjKlMnOpQrStUvWxYz0123456789_-AB';
const _otherToken = 'ZzYyXxWwVvUuTtSsRrQqPpOoNnMmLlKkJj012345';
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

  group('DisplaySetupLinkController token dedup', () {
    // Both _handleUri and handleDisplaySetupIntent funnel through the same
    // internal accept method, so driving handleDisplaySetupIntent with
    // intents parsed from real URIs exercises the shared dedup logic.
    const tokenB = 'ZzYyXxWwVvUuTtSsRrQqPpOoNnMmLlKkJj012345';

    DisplaySetupIntent httpsIntent(String token) =>
        DisplaySetupLinkController.parseDisplaySetupUri(
          Uri.parse('https://hub.calee.com.au/native-login/$token'),
        )!;

    DisplaySetupIntent caleeIntent(String token) =>
        DisplaySetupLinkController.parseDisplaySetupUri(
          Uri.parse('calee://native-login/$token'),
        )!;

    late DateTime now;
    late DisplaySetupLinkController controller;
    late int notifications;

    setUp(() {
      now = DateTime(2026, 1, 1, 12);
      controller = DisplaySetupLinkController(clock: () => now);
      notifications = 0;
      controller.addListener(() => notifications++);
    });

    tearDown(() {
      controller.dispose();
    });

    test('same token delivered twice inside the window notifies once', () {
      controller.handleDisplaySetupIntent(httpsIntent(_validToken));
      now = now.add(const Duration(seconds: 1));
      controller.handleDisplaySetupIntent(httpsIntent(_validToken));

      expect(notifications, 1);
      expect(controller.pendingIntent!.token, _validToken);
    });

    test('HTTPS and calee:// forms of the same token dedup together', () {
      controller.handleDisplaySetupIntent(httpsIntent(_validToken));
      controller.handleDisplaySetupIntent(caleeIntent(_validToken));

      expect(notifications, 1);
      expect(controller.pendingIntent!.token, _validToken);
    });

    test('a different token is not suppressed', () {
      controller.handleDisplaySetupIntent(httpsIntent(_validToken));
      controller.handleDisplaySetupIntent(httpsIntent(tokenB));

      expect(notifications, 2);
      expect(controller.pendingIntent!.token, tokenB);
    });

    test('same token accepted again after the dedup window elapses', () {
      controller.handleDisplaySetupIntent(httpsIntent(_validToken));
      now = now.add(
        DisplaySetupLinkController.dedupWindow +
            const Duration(milliseconds: 1),
      );
      controller.handleDisplaySetupIntent(httpsIntent(_validToken));

      expect(notifications, 2);
      expect(controller.pendingIntent!.token, _validToken);
    });

    test('same token accepted again after clearPending', () {
      controller.handleDisplaySetupIntent(httpsIntent(_validToken));
      controller.clearPending();
      controller.handleDisplaySetupIntent(httpsIntent(_validToken));

      // Delivery, clearPending, and re-delivery each notify.
      expect(notifications, 3);
      expect(controller.pendingIntent!.token, _validToken);
    });
  });

  group('DisplaySetupLinkController.init lifecycle (fake link source)', () {
    late _FakeLinkSource source;
    late DisplaySetupLinkController controller;
    late int notifications;

    setUp(() {
      source = _FakeLinkSource();
      notifications = 0;
    });

    tearDown(() {
      controller.dispose();
    });

    test('initial link delivered via getInitialLink populates pendingIntent '
        'and notifies exactly once', () async {
      source.initialLink = Uri.parse(
        'https://hub.calee.com.au/native-login/$_validToken',
      );
      controller = DisplaySetupLinkController(linkSource: source);
      controller.addListener(() => notifications++);

      await controller.init();

      expect(controller.pendingIntent, isNotNull);
      expect(controller.pendingIntent!.token, _validToken);
      expect(notifications, 1);
    });

    test('a link that only arrives later via uriLinkStream populates '
        'pendingIntent', () async {
      controller = DisplaySetupLinkController(linkSource: source);
      controller.addListener(() => notifications++);

      await controller.init();
      expect(controller.pendingIntent, isNull);

      source.emit(Uri.parse('calee://native-login/$_validToken'));
      await Future<void>.delayed(Duration.zero);

      expect(controller.pendingIntent, isNotNull);
      expect(controller.pendingIntent!.token, _validToken);
      expect(notifications, 1);
    });

    test('a stream link arriving while getInitialLink is still pending is not '
        'lost', () async {
      final initialLinkCompleter = Completer<Uri?>();
      source.initialLinkCompleter = initialLinkCompleter;
      controller = DisplaySetupLinkController(linkSource: source);
      controller.addListener(() => notifications++);

      final initFuture = controller.init();
      // getInitialLink has not resolved yet — the stream listener must
      // already be attached, so this is not dropped.
      source.emit(
        Uri.parse('https://hub.calee.com.au/native-login/$_validToken'),
      );
      await Future<void>.delayed(Duration.zero);

      expect(controller.pendingIntent, isNotNull);
      expect(controller.pendingIntent!.token, _validToken);

      initialLinkCompleter.complete(null);
      await initFuture;

      expect(controller.pendingIntent!.token, _validToken);
      expect(notifications, 1);
    });

    test(
      'the same token from both the stream and getInitialLink notifies once',
      () async {
        final uri = Uri.parse(
          'https://hub.calee.com.au/native-login/$_validToken',
        );
        final initialLinkCompleter = Completer<Uri?>();
        source.initialLinkCompleter = initialLinkCompleter;
        controller = DisplaySetupLinkController(linkSource: source);
        controller.addListener(() => notifications++);

        final initFuture = controller.init();
        source.emit(uri);
        await Future<void>.delayed(Duration.zero);
        initialLinkCompleter.complete(uri);
        await initFuture;

        expect(notifications, 1);
        expect(controller.pendingIntent!.token, _validToken);
      },
    );

    test('HTTPS getInitialLink and calee:// stream link for the same tablet '
        'token dedup together', () async {
      final httpsUri = Uri.parse(
        'https://hub.calee.com.au/native-login/$_validToken',
      );
      final caleeUri = Uri.parse('calee://native-login/$_validToken');
      final initialLinkCompleter = Completer<Uri?>();
      source.initialLinkCompleter = initialLinkCompleter;
      controller = DisplaySetupLinkController(linkSource: source);
      controller.addListener(() => notifications++);

      final initFuture = controller.init();
      source.emit(caleeUri);
      await Future<void>.delayed(Duration.zero);
      initialLinkCompleter.complete(httpsUri);
      await initFuture;

      expect(notifications, 1);
      expect(controller.pendingIntent!.token, _validToken);
    });

    test('a genuinely different token delivered later is accepted', () async {
      source.initialLink = Uri.parse(
        'https://hub.calee.com.au/native-login/$_validToken',
      );
      controller = DisplaySetupLinkController(linkSource: source);
      controller.addListener(() => notifications++);

      await controller.init();
      expect(controller.pendingIntent!.token, _validToken);

      source.emit(Uri.parse('calee://native-login/$_otherToken'));
      await Future<void>.delayed(Duration.zero);

      expect(notifications, 2);
      expect(controller.pendingIntent!.token, _otherToken);
    });

    test('init is idempotent — a second call does not attach a second '
        'stream subscription', () async {
      controller = DisplaySetupLinkController(linkSource: source);

      await controller.init();
      await controller.init();

      controller.addListener(() => notifications++);
      source.emit(Uri.parse('calee://native-login/$_validToken'));
      await Future<void>.delayed(Duration.zero);

      // A duplicate subscription would deliver the same event twice and
      // double-count the notification.
      expect(notifications, 1);
    });
  });

  test('events after disposal are ignored safely', () async {
    final source = _FakeLinkSource();
    final controller = DisplaySetupLinkController(linkSource: source);
    await controller.init();
    controller.dispose();

    source.emit(
      Uri.parse('https://hub.calee.com.au/native-login/$_validToken'),
    );
    await Future<void>.delayed(Duration.zero);

    // No exception from notifying a disposed ChangeNotifier, and no
    // pendingIntent set from the post-disposal event.
    expect(controller.pendingIntent, isNull);
  });
}

// ─── Test helpers ─────────────────────────────────────────────────────────────

class _ManualController extends DisplaySetupLinkController {
  void injectUri(Uri uri) {
    final intent = DisplaySetupLinkController.parseDisplaySetupUri(uri);
    if (intent == null) return;
    pendingIntent = intent;
    pendingError = null;
    notifyListeners();
  }
}

/// Fake [DisplaySetupLinkSource] that lets tests control exactly when
/// [getInitialLink] resolves and emit arbitrary URIs on [uriLinkStream],
/// without touching platform channels.
class _FakeLinkSource implements DisplaySetupLinkSource {
  Uri? initialLink;
  Completer<Uri?>? initialLinkCompleter;

  final _streamController = StreamController<Uri>.broadcast();

  @override
  Future<Uri?> getInitialLink() {
    final completer = initialLinkCompleter;
    if (completer != null) return completer.future;
    return Future.value(initialLink);
  }

  @override
  Stream<Uri> get uriLinkStream => _streamController.stream;

  void emit(Uri uri) => _streamController.add(uri);
}
