import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:calee_mobile/features/calendar_follow/calendar_follow_intent.dart';
import 'package:calee_mobile/features/calendar_follow/calendar_follow_intent_resolver.dart';
import 'package:calee_mobile/features/calendar_follow/calendar_follow_link_controller.dart';

const _token = 'signedPayload.signedSignature';
const _otherToken = 'anotherPayload.anotherSignature';

Uri _httpsFollow(String token) =>
    Uri.parse('https://calembed.calee.com.au/follow?t=$token');

Uri _caleeFollow(String token) => Uri.parse('calee://follow?t=$token');

void main() {
  group('parseFollowUri — HTTPS App Link', () {
    test('accepts https follow link with a token', () {
      expect(
        CalendarFollowLinkController.parseFollowUri(_httpsFollow(_token)),
        isNotNull,
      );
    });

    test('extracts the token from an https follow link', () {
      final intent = CalendarFollowLinkController.parseFollowUri(
        _httpsFollow(_token),
      );
      expect(intent!.token, _token);
    });

    test('preserves the source URI for an https follow link', () {
      final uri = _httpsFollow(_token);
      final intent = CalendarFollowLinkController.parseFollowUri(uri);
      expect(intent!.sourceUri, uri);
    });

    test('rejects an https follow link with no t parameter', () {
      final uri = Uri.parse('https://calembed.calee.com.au/follow');
      expect(CalendarFollowLinkController.parseFollowUri(uri), isNull);
    });

    test('rejects an https follow link with an empty t parameter', () {
      final uri = Uri.parse('https://calembed.calee.com.au/follow?t=');
      expect(CalendarFollowLinkController.parseFollowUri(uri), isNull);
    });

    test('rejects a raw ?url= link with no signed token', () {
      // The signed intent is the only trusted form — a raw subscription URL
      // must never be accepted as a follow intent.
      final uri = Uri.parse(
        'https://calembed.calee.com.au/follow'
        '?url=https%3A%2F%2Fportal.calee.com.au%2Fx.ics',
      );
      expect(CalendarFollowLinkController.parseFollowUri(uri), isNull);
    });

    test('rejects the wrong https host', () {
      final uri = Uri.parse('https://evil.example.com/follow?t=$_token');
      expect(CalendarFollowLinkController.parseFollowUri(uri), isNull);
    });

    test('rejects the wrong https path', () {
      final uri = Uri.parse(
        'https://calembed.calee.com.au/followers?t=$_token',
      );
      expect(CalendarFollowLinkController.parseFollowUri(uri), isNull);
    });
  });

  group('parseFollowUri — calee:// custom scheme', () {
    test('accepts calee://follow with a token', () {
      expect(
        CalendarFollowLinkController.parseFollowUri(_caleeFollow(_token)),
        isNotNull,
      );
    });

    test('extracts the token from calee://follow', () {
      final intent = CalendarFollowLinkController.parseFollowUri(
        _caleeFollow(_token),
      );
      expect(intent!.token, _token);
    });

    test('preserves the source URI for calee://follow', () {
      final uri = _caleeFollow(_token);
      final intent = CalendarFollowLinkController.parseFollowUri(uri);
      expect(intent!.sourceUri, uri);
    });

    test('rejects calee://follow with no t parameter', () {
      expect(
        CalendarFollowLinkController.parseFollowUri(
          Uri.parse('calee://follow'),
        ),
        isNull,
      );
    });

    test('rejects calee://follow with an empty t parameter', () {
      expect(
        CalendarFollowLinkController.parseFollowUri(
          Uri.parse('calee://follow?t='),
        ),
        isNull,
      );
    });

    test('rejects the wrong custom-scheme host', () {
      final uri = Uri.parse('calee://followers?t=$_token');
      expect(CalendarFollowLinkController.parseFollowUri(uri), isNull);
    });

    test('does not treat calee://follow?url= as a follow intent', () {
      final uri = Uri.parse(
        'calee://follow?url=https%3A%2F%2Fportal.calee.com.au%2Fx.ics',
      );
      expect(CalendarFollowLinkController.parseFollowUri(uri), isNull);
    });
  });

  group('parseFollowUri — unrelated links are ignored', () {
    test('ignores the shopping custom link', () {
      final uri = Uri.parse('calee://shopping?weekStart=2026-01-05');
      expect(CalendarFollowLinkController.parseFollowUri(uri), isNull);
    });

    test('ignores the native-login custom link', () {
      final uri = Uri.parse('calee://native-login/sometabletlogintoken');
      expect(CalendarFollowLinkController.parseFollowUri(uri), isNull);
    });

    test('ignores the external-calendar-connected custom link', () {
      final uri = Uri.parse('calee://external-calendar-connected');
      expect(CalendarFollowLinkController.parseFollowUri(uri), isNull);
    });

    test('ignores an unknown scheme', () {
      final uri = Uri.parse('ftp://calembed.calee.com.au/follow?t=$_token');
      expect(CalendarFollowLinkController.parseFollowUri(uri), isNull);
    });
  });

  group('CalendarFollowLinkController.init lifecycle', () {
    late _FakeLinkSource source;
    late _FakeResolver resolver;
    late CalendarFollowLinkController controller;
    late int notifications;

    setUp(() {
      source = _FakeLinkSource();
      resolver = _FakeResolver();
      notifications = 0;
    });

    tearDown(() {
      controller.dispose();
    });

    test('cold start: an https link from getInitialLink resolves and '
        'notifies once', () async {
      source.initialLink = _httpsFollow(_token);
      controller = CalendarFollowLinkController(
        linkSource: source,
        resolver: resolver,
      );
      controller.addListener(() => notifications++);

      await controller.init();
      await pumpEventQueue();

      expect(resolver.resolvedTokens, [_token]);
      expect(controller.pendingIntent, isNotNull);
      expect(controller.pendingError, isNull);
      expect(notifications, 1);
    });

    test(
      'cold start: a calee://follow link from getInitialLink resolves',
      () async {
        source.initialLink = _caleeFollow(_token);
        controller = CalendarFollowLinkController(
          linkSource: source,
          resolver: resolver,
        );
        controller.addListener(() => notifications++);

        await controller.init();
        await pumpEventQueue();

        expect(resolver.resolvedTokens, [_token]);
        expect(controller.pendingIntent, isNotNull);
        expect(notifications, 1);
      },
    );

    test('warm start: a link arriving later on the stream resolves', () async {
      controller = CalendarFollowLinkController(
        linkSource: source,
        resolver: resolver,
      );
      controller.addListener(() => notifications++);

      await controller.init();
      expect(controller.pendingIntent, isNull);

      source.emit(_caleeFollow(_token));
      await pumpEventQueue();

      expect(resolver.resolvedTokens, [_token]);
      expect(controller.pendingIntent, isNotNull);
      expect(notifications, 1);
    });

    test('a stream link arriving while getInitialLink is still pending is '
        'not lost', () async {
      final completer = Completer<Uri?>();
      source.initialLinkCompleter = completer;
      controller = CalendarFollowLinkController(
        linkSource: source,
        resolver: resolver,
      );
      controller.addListener(() => notifications++);

      final initFuture = controller.init();
      source.emit(_httpsFollow(_token));
      await pumpEventQueue();

      expect(controller.pendingIntent, isNotNull);

      completer.complete(null);
      await initFuture;
      await pumpEventQueue();

      expect(resolver.resolvedTokens, [_token]);
      expect(notifications, 1);
    });

    test(
      'a resolver failure sets pendingError and leaves pendingIntent null',
      () async {
        resolver.error = const CalendarFollowIntentResolverException(
          'This calendar link is invalid or has expired.',
        );
        source.initialLink = _httpsFollow(_token);
        controller = CalendarFollowLinkController(
          linkSource: source,
          resolver: resolver,
        );
        controller.addListener(() => notifications++);

        await controller.init();
        await pumpEventQueue();

        expect(controller.pendingIntent, isNull);
        expect(
          controller.pendingError,
          'This calendar link is invalid or has expired.',
        );
        expect(notifications, 1);
      },
    );

    test('an unrelated custom link on the stream is ignored', () async {
      controller = CalendarFollowLinkController(
        linkSource: source,
        resolver: resolver,
      );
      controller.addListener(() => notifications++);

      await controller.init();
      source.emit(Uri.parse('calee://shopping?weekStart=2026-01-05'));
      await pumpEventQueue();

      expect(resolver.resolvedTokens, isEmpty);
      expect(controller.pendingIntent, isNull);
      expect(notifications, 0);
    });

    test('init is idempotent — a second call does not attach a second '
        'stream subscription', () async {
      controller = CalendarFollowLinkController(
        linkSource: source,
        resolver: resolver,
      );

      await controller.init();
      await controller.init();

      controller.addListener(() => notifications++);
      source.emit(_httpsFollow(_token));
      await pumpEventQueue();

      // A duplicate subscription would resolve the same link twice.
      expect(resolver.resolvedTokens, [_token]);
      expect(notifications, 1);
    });

    test('events after disposal are ignored safely', () async {
      controller = CalendarFollowLinkController(
        linkSource: source,
        resolver: resolver,
      );
      await controller.init();
      controller.dispose();

      source.emit(_httpsFollow(_token));
      await pumpEventQueue();

      expect(resolver.resolvedTokens, isEmpty);
      expect(controller.pendingIntent, isNull);
    });
  });

  group('CalendarFollowLinkController duplicate-delivery dedup', () {
    late _FakeLinkSource source;
    late _FakeResolver resolver;
    late DateTime now;
    late CalendarFollowLinkController controller;
    late int notifications;

    setUp(() {
      source = _FakeLinkSource();
      resolver = _FakeResolver();
      now = DateTime(2026, 1, 1, 12);
      notifications = 0;
    });

    tearDown(() {
      controller.dispose();
    });

    Future<void> build() async {
      controller = CalendarFollowLinkController(
        linkSource: source,
        resolver: resolver,
        clock: () => now,
      );
      controller.addListener(() => notifications++);
      await controller.init();
    }

    test('the same token from getInitialLink and the stream resolves once '
        'and opens one screen', () async {
      final completer = Completer<Uri?>();
      source.initialLinkCompleter = completer;
      controller = CalendarFollowLinkController(
        linkSource: source,
        resolver: resolver,
        clock: () => now,
      );
      controller.addListener(() => notifications++);

      final initFuture = controller.init();
      source.emit(_httpsFollow(_token));
      await pumpEventQueue();
      completer.complete(_httpsFollow(_token));
      await initFuture;
      await pumpEventQueue();

      expect(resolver.resolvedTokens, [_token]);
      expect(notifications, 1);
    });

    test('the https and calee:// forms of one token dedup together', () async {
      await build();

      source.emit(_httpsFollow(_token));
      await pumpEventQueue();
      source.emit(_caleeFollow(_token));
      await pumpEventQueue();

      expect(resolver.resolvedTokens, [_token]);
      expect(notifications, 1);
    });

    test('a different token is never suppressed', () async {
      await build();

      source.emit(_httpsFollow(_token));
      await pumpEventQueue();
      source.emit(_httpsFollow(_otherToken));
      await pumpEventQueue();

      expect(resolver.resolvedTokens, [_token, _otherToken]);
      expect(notifications, 2);
    });

    test(
      'the same token is accepted again after the dedup window elapses',
      () async {
        await build();

        source.emit(_httpsFollow(_token));
        await pumpEventQueue();
        now = now.add(
          CalendarFollowLinkController.dedupWindow +
              const Duration(milliseconds: 1),
        );
        source.emit(_httpsFollow(_token));
        await pumpEventQueue();

        expect(resolver.resolvedTokens, [_token, _token]);
        expect(notifications, 2);
      },
    );

    test('the same token is accepted again after clearPending', () async {
      await build();

      source.emit(_httpsFollow(_token));
      await pumpEventQueue();
      controller.clearPending();
      source.emit(_httpsFollow(_token));
      await pumpEventQueue();

      expect(resolver.resolvedTokens, [_token, _token]);
    });
  });
}

// ─── Test helpers ───────────────────────────────────────────────────────────

/// Fake [CalendarFollowLinkSource] that lets tests control exactly when
/// [getInitialLink] resolves and emit arbitrary URIs on [uriLinkStream],
/// without touching platform channels.
class _FakeLinkSource implements CalendarFollowLinkSource {
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

/// Fake resolver that records the tokens it was asked to resolve and returns a
/// canned intent (or throws a canned error) without any network access.
class _FakeResolver extends CalendarFollowIntentResolver {
  Object? error;
  final List<String> resolvedTokens = [];

  @override
  Future<ResolvedCalendarFollowIntent> resolve(
    CalendarFollowIntent intent,
  ) async {
    resolvedTokens.add(intent.token);
    final err = error;
    if (err != null) throw err;
    return ResolvedCalendarFollowIntent(
      title: 'Calendar',
      url: 'https://portal.calee.com.au/x.ics',
      source: 'calembed',
    );
  }
}
