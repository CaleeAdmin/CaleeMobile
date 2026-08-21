// The real production mint client, driven against a loopback HTTP server
// (CaleeAdmin/CaleeMobile#558).
//
// Deliberately NOT a second, parallel implementation of the client: these
// tests exercise CalEmbedEventLinkService itself — its request construction,
// its headers, its timeouts, its body cap and its response validation — over a
// real socket. A hand-rolled fake service would prove only that the fake
// agrees with itself.
//
// The one thing overridden is the endpoint (and, where a test needs to fail
// fast, the timeout). Both default to production values, and the first test
// below pins those defaults.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:calee_mobile/features/local_subscriber/calee_public_calendar_source.dart';
import 'package:calee_mobile/features/local_subscriber/local_event_link_service.dart';
import 'package:flutter_test/flutter_test.dart';

// ── Fixtures ──────────────────────────────────────────────────────────────────

const _kToken = 'AbC123_-xyz';
const _kCanonicalCalendarUrl =
    'https://portal.calee.com.au/remote.php/dav/public-calendars/$_kToken'
    '?export';
const _kEventLink =
    'https://calembed.calee.com.au/e/1.eyJiIjoicG9ydGFsIn0.c2lnbmF0dXJl';

CaleePublicCalendarSource get _source =>
    CaleePublicCalendarSource.tryParse(_kCanonicalCalendarUrl)!;

// ── Loopback mint endpoint ────────────────────────────────────────────────────

class _RecordedRequest {
  _RecordedRequest({
    required this.method,
    required this.uri,
    required this.headers,
    required this.bodyBytes,
  });

  final String method;
  final Uri uri;
  final Map<String, List<String>> headers;
  final List<int> bodyBytes;

  /// The body decoded as UTF-8. Compared byte-exactly against what was sent:
  /// a UID must survive this round trip unchanged.
  String get bodyText => utf8.decode(bodyBytes);

  Map<String, dynamic> get json => jsonDecode(bodyText) as Map<String, dynamic>;

  String? header(String name) => headers[name.toLowerCase()]?.join(', ');
}

class _FakeMintEndpoint {
  _FakeMintEndpoint._(this._server);

  final HttpServer _server;
  final List<_RecordedRequest> requests = <_RecordedRequest>[];

  static Future<_FakeMintEndpoint> start(
    FutureOr<void> Function(HttpRequest request) respond,
  ) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final endpoint = _FakeMintEndpoint._(server);

    server.listen((request) async {
      final bytes = <int>[];
      await for (final chunk in request) {
        bytes.addAll(chunk);
      }
      final headers = <String, List<String>>{};
      request.headers.forEach(
        (name, values) => headers[name.toLowerCase()] = List.of(values),
      );
      endpoint.requests.add(
        _RecordedRequest(
          method: request.method,
          uri: request.uri,
          headers: headers,
          bodyBytes: bytes,
        ),
      );
      await respond(request);
    });

    return endpoint;
  }

  String get url =>
      'http://${_server.address.address}:${_server.port}/event-link';

  Future<void> close() => _server.close(force: true);
}

/// Responds exactly as CalEmbed does on success.
Future<void> Function(HttpRequest) _respondOk([String url = _kEventLink]) =>
    (request) async {
      request.response
        ..statusCode = 200
        ..headers.contentType = ContentType.json
        ..write(jsonEncode({'url': url}));
      await request.response.close();
    };

/// Responds with a raw body, so a malformed or oversized payload can be
/// produced verbatim.
Future<void> Function(HttpRequest) _respondRaw(int status, String body) =>
    (request) async {
      request.response
        ..statusCode = status
        ..headers.contentType = ContentType.json
        ..write(body);
      await request.response.close();
    };

void main() {
  late _FakeMintEndpoint endpoint;

  tearDown(() async {
    await endpoint.close();
  });

  // ── Production defaults ─────────────────────────────────────────────────

  group('CalEmbedEventLinkService — production defaults', () {
    setUp(() async {
      endpoint = await _FakeMintEndpoint.start(_respondOk());
    });

    test('posts to the production CalEmbed mint endpoint by default', () {
      expect(
        kCalEmbedEventLinkEndpoint,
        'https://calembed.calee.com.au/event-link',
      );
      expect(
        const CalEmbedEventLinkService().endpoint,
        'https://calembed.calee.com.au/event-link',
      );
    });

    test('uses a finite default timeout', () {
      expect(
        const CalEmbedEventLinkService().timeout,
        lessThanOrEqualTo(const Duration(seconds: 30)),
      );
      expect(
        const CalEmbedEventLinkService().timeout,
        greaterThan(Duration.zero),
      );
    });
  });

  // ── Request shape ───────────────────────────────────────────────────────

  group('CalEmbedEventLinkService — request', () {
    setUp(() async {
      endpoint = await _FakeMintEndpoint.start(_respondOk());
    });

    Future<Uri> mint({required String uid, String? occurrenceId}) =>
        CalEmbedEventLinkService(
          endpoint: endpoint.url,
        ).mint(source: _source, uid: uid, occurrenceId: occurrenceId);

    test('a one-off sends exactly calendarUrl and uid', () async {
      await mint(uid: 'one-off-uid');

      expect(endpoint.requests, hasLength(1));
      final body = endpoint.requests.single.json;
      expect(body.keys.toSet(), {'calendarUrl', 'uid'});
      expect(body['calendarUrl'], _kCanonicalCalendarUrl);
      expect(body['uid'], 'one-off-uid');
      // Omitted, never a manufactured null or empty string.
      expect(body.containsKey('occurrenceId'), isFalse);
    });

    test('a recurring occurrence sends exactly the three fields', () async {
      await mint(uid: 'series-uid', occurrenceId: '20260818T073000Z');

      final body = endpoint.requests.single.json;
      expect(body.keys.toSet(), {'calendarUrl', 'uid', 'occurrenceId'});
      expect(body['uid'], 'series-uid');
      expect(body['occurrenceId'], '20260818T073000Z');
    });

    test('an all-day recurrence sends the Ymd identity unchanged', () async {
      await mint(uid: 'all-day-uid', occurrenceId: '20260818');

      expect(endpoint.requests.single.json['occurrenceId'], '20260818');
    });

    test('the UID "0" survives exactly', () async {
      await mint(uid: '0');

      expect(endpoint.requests.single.json['uid'], '0');
    });

    test('boundary whitespace in a UID survives exactly', () async {
      await mint(uid: '  padded-uid  ');

      expect(endpoint.requests.single.json['uid'], '  padded-uid  ');
    });

    test('internal double whitespace in a UID survives exactly', () async {
      await mint(uid: 'series  one');

      expect(endpoint.requests.single.json['uid'], 'series  one');
    });

    test('a non-ASCII UID survives byte for byte', () async {
      await mint(uid: 'ünïcode-uid-\u{1F600}');

      expect(endpoint.requests.single.json['uid'], 'ünïcode-uid-\u{1F600}');
    });

    test('sends no event content and no client identity', () async {
      await mint(uid: 'series-uid', occurrenceId: '20260818T073000Z');

      // Asserted as the COMPLETE body rather than as a list of absent words:
      // an exact match proves there is no title, description, location,
      // attendee, start, end, account, device or installation field, including
      // ones nobody thought to name here. The mint API has no parameter for
      // any of them, and this is what keeps it that way.
      expect(
        endpoint.requests.single.bodyText,
        '{"calendarUrl":"$_kCanonicalCalendarUrl",'
        '"uid":"series-uid",'
        '"occurrenceId":"20260818T073000Z"}',
      );
    });

    test('sends nothing beyond the identity for a one-off either', () async {
      await mint(uid: 'one-off-uid');

      expect(
        endpoint.requests.single.bodyText,
        '{"calendarUrl":"$_kCanonicalCalendarUrl","uid":"one-off-uid"}',
      );
    });

    test('is a POST to /event-link as application/json', () async {
      await mint(uid: 'uid');

      final request = endpoint.requests.single;
      expect(request.method, 'POST');
      expect(request.uri.path, '/event-link');
      expect(request.uri.query, isEmpty);
      expect(request.header('content-type'), 'application/json');
      expect(request.header('accept'), 'application/json');
    });

    test('carries no authorization, cookie or Hub session header', () async {
      await mint(uid: 'uid');

      final headers = endpoint.requests.single.headers;
      for (final forbidden in const [
        'authorization',
        'cookie',
        'x-calee-session',
        'x-api-key',
        'proxy-authorization',
      ]) {
        expect(
          headers.containsKey(forbidden),
          isFalse,
          reason: 'signed-out mint must not send "$forbidden"',
        );
      }
    });

    test('returns the response URL byte for byte', () async {
      final url = await mint(uid: 'uid');

      expect(url.toString(), _kEventLink);
    });
  });

  // ── Failures ────────────────────────────────────────────────────────────

  group('CalEmbedEventLinkService — server failures', () {
    Future<void> expectRefusal() async {
      await expectLater(
        CalEmbedEventLinkService(
          endpoint: endpoint.url,
          timeout: const Duration(seconds: 5),
        ).mint(source: _source, uid: 'uid'),
        throwsA(isA<LocalEventLinkException>()),
      );
    }

    test('refuses a 400 invalid_source', () async {
      endpoint = await _FakeMintEndpoint.start(
        _respondRaw(
          400,
          jsonEncode({
            'error': {
              'code': 'invalid_source',
              'message': 'Unknown calendar source.',
            },
          }),
        ),
      );
      await expectRefusal();
    });

    test('refuses a 503 unavailable', () async {
      endpoint = await _FakeMintEndpoint.start(
        _respondRaw(
          503,
          jsonEncode({
            'error': {'code': 'unavailable', 'message': 'Not available.'},
          }),
        ),
      );
      await expectRefusal();
    });

    test('refuses a 200 carrying malformed JSON', () async {
      endpoint = await _FakeMintEndpoint.start(_respondRaw(200, '{not json'));
      await expectRefusal();
    });

    test('refuses a 200 whose body is a JSON array', () async {
      endpoint = await _FakeMintEndpoint.start(_respondRaw(200, '["url"]'));
      await expectRefusal();
    });

    test('refuses a success payload with no url', () async {
      endpoint = await _FakeMintEndpoint.start(
        _respondRaw(200, jsonEncode({'ok': true})),
      );
      await expectRefusal();
    });

    test('refuses a url that is not a string', () async {
      endpoint = await _FakeMintEndpoint.start(
        _respondRaw(200, jsonEncode({'url': 42})),
      );
      await expectRefusal();
    });

    test('refuses an Event Link on another origin', () async {
      endpoint = await _FakeMintEndpoint.start(
        _respondOk('https://attacker.example/e/1.payload.signature'),
      );
      await expectRefusal();
    });

    test('refuses a query-bearing Event Link', () async {
      endpoint = await _FakeMintEndpoint.start(
        _respondOk('$_kEventLink?utm_source=mobile'),
      );
      await expectRefusal();
    });

    test('refuses a fragment-bearing Event Link', () async {
      endpoint = await _FakeMintEndpoint.start(_respondOk('$_kEventLink#top'));
      await expectRefusal();
    });

    test('refuses a wrong /e/ shape', () async {
      endpoint = await _FakeMintEndpoint.start(
        _respondOk('https://calembed.calee.com.au/e/'),
      );
      await expectRefusal();
    });

    test('refuses a response body beyond the size cap', () async {
      endpoint = await _FakeMintEndpoint.start(
        _respondRaw(200, 'x' * (256 * 1024)),
      );
      await expectRefusal();
    });

    test('does not follow a redirect to another origin', () async {
      final elsewhere = await _FakeMintEndpoint.start(_respondOk());
      addTearDown(elsewhere.close);

      endpoint = await _FakeMintEndpoint.start((request) async {
        request.response
          ..statusCode = 302
          ..headers.set(HttpHeaders.locationHeader, elsewhere.url);
        await request.response.close();
      });

      await expectRefusal();
      expect(elsewhere.requests, isEmpty);
    });

    test('times out rather than hanging', () async {
      final held = Completer<void>();
      endpoint = await _FakeMintEndpoint.start((request) => held.future);
      addTearDown(() => held.complete());

      await expectLater(
        CalEmbedEventLinkService(
          endpoint: endpoint.url,
          timeout: const Duration(milliseconds: 200),
        ).mint(source: _source, uid: 'uid'),
        throwsA(isA<LocalEventLinkException>()),
      );
    });

    test('refuses when the endpoint is unreachable', () async {
      endpoint = await _FakeMintEndpoint.start(_respondOk());
      final deadUrl = endpoint.url;
      await endpoint.close();

      await expectLater(
        CalEmbedEventLinkService(
          endpoint: deadUrl,
          timeout: const Duration(seconds: 5),
        ).mint(source: _source, uid: 'uid'),
        throwsA(isA<LocalEventLinkException>()),
      );
    });
  });

  // ── Returned-URL validation, directly ───────────────────────────────────

  group('calEmbedEventLink', () {
    test('accepts a canonical v1 Event Link unchanged', () {
      final uri = calEmbedEventLink(_kEventLink);
      expect(uri, isNotNull);
      expect(uri.toString(), _kEventLink);
    });

    final rejected = <String, String>{
      'http': 'http://calembed.calee.com.au/e/1.payload.signature',
      'another origin': 'https://attacker.example/e/1.payload.signature',
      'host suffix attack':
          'https://calembed.calee.com.au.attacker.example/e/1.p.s',
      'subdomain': 'https://x.calembed.calee.com.au/e/1.p.s',
      'credentials':
          'https://user:pass@calembed.calee.com.au/e/1.payload.signature',
      'explicit port':
          'https://calembed.calee.com.au:443/e/1.payload.signature',
      'query': 'https://calembed.calee.com.au/e/1.p.s?x=1',
      'fragment': 'https://calembed.calee.com.au/e/1.p.s#x',
      'empty reference': 'https://calembed.calee.com.au/e/',
      'path traversal': 'https://calembed.calee.com.au/e/../admin',
      'extra segment': 'https://calembed.calee.com.au/e/1.p.s/extra',
      'wrong path': 'https://calembed.calee.com.au/event/1.p.s',
      'unversioned reference': 'https://calembed.calee.com.au/e/payload.sig',
      'unknown version': 'https://calembed.calee.com.au/e/2.payload.signature',
      'missing signature': 'https://calembed.calee.com.au/e/1.payload',
      'empty payload part': 'https://calembed.calee.com.au/e/1..signature',
      'non-base64url character':
          'https://calembed.calee.com.au/e/1.pay+load.signature',
      'leading whitespace': ' $_kEventLink',
      'trailing newline': '$_kEventLink\n',
      'not a url': 'nonsense',
      'empty': '',
    };

    rejected.forEach((label, value) {
      test('refuses $label', () {
        expect(calEmbedEventLink(value), isNull, reason: value);
      });
    });
  });
}
