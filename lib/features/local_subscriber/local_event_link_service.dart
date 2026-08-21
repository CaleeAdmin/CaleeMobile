/// Minting a canonical public Event Link for one occurrence of an
/// already-public Calee calendar.
///
/// CalEmbed is the ONLY minter. This client sends a source identity and
/// receives a signed URL; it holds no secret, computes no HMAC, and knows
/// nothing about the payload encoding. Porting any of that to Dart would
/// create a second implementation that has to agree with PHP forever, and a
/// signing key on a phone is a key that has been published.
///
/// The request is deliberately tiny — a calendar reference, a UID, and (only
/// for a recurring occurrence) a canonical recurrence identity. No title, no
/// date, no location, no attendee, no account, no device or installation
/// identifier. The public page the link resolves to reads its display data
/// from the public ICS feed itself, so sending any of it here would be
/// duplicate data the endpoint does not want and a privacy surface it does not
/// need.
///
/// The endpoint is PURE (calee-hub-calembed#71): it fetches no upstream
/// calendar, verifies no event existence, writes no record, and signs
/// deterministically. So one Share tap costs exactly one request. There is no
/// preflight, no `GET /e/...` to check the link, and no re-fetch of the
/// subscription — the phone already fetched the ICS to draw the event.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'calee_public_calendar_source.dart';

/// The one production mint endpoint.
const String kCalEmbedEventLinkEndpoint =
    'https://calembed.calee.com.au/event-link';

/// The canonical Event Link origin. A returned URL on any other origin is
/// refused rather than shared.
const String kCalEmbedEventLinkOrigin = 'https://calembed.calee.com.au';

/// A mint attempt that produced no shareable link.
///
/// Deliberately opaque. CalEmbed's stable codes (`invalid_request`,
/// `invalid_source`, `invalid_uid`, `invalid_occurrence`, `unavailable`), the
/// HTTP status, the response body and the request URI are all diagnostics for
/// the server's own logs — none of them mean anything to the person holding
/// the phone, and each one is a detail about a calendar's identity that the UI
/// has no reason to display. Every failure therefore collapses to this single
/// type carrying nothing, and the UI says one thing: try again.
class LocalEventLinkException implements Exception {
  const LocalEventLinkException();

  @override
  String toString() => 'LocalEventLinkException';
}

/// Mints the canonical Event Link for one occurrence.
///
/// An interface so the calendar page can be driven by a fake in widget tests
/// without a socket, and so CaleeAdmin/CaleeMobile#559 can later reuse exactly
/// this seam for signed-in sharing.
abstract interface class LocalEventLinkService {
  /// The canonical `https://calembed.calee.com.au/e/...` URL for this source
  /// occurrence.
  ///
  /// [uid] is the VERBATIM source `UID` and is transmitted byte for byte:
  /// never trimmed, never lower-cased, never URL-decoded, and never replaced
  /// by a local id. `0` is a real UID, ` spaced ` is a different event from
  /// `spaced`, and `a  b` is a different event from `a b`.
  ///
  /// [occurrenceId] is the CANONICAL recurrence identity of a recurring
  /// occurrence, and is omitted entirely for a one-off.
  ///
  /// Throws [LocalEventLinkException] for every failure, including a response
  /// whose URL is not a canonical Event Link.
  Future<Uri> mint({
    required CaleePublicCalendarSource source,
    required String uid,
    String? occurrenceId,
  });
}

/// The production client: one unauthenticated `POST` to CalEmbed.
class CalEmbedEventLinkService implements LocalEventLinkService {
  /// [endpoint] and [timeout] exist so the tests can drive this exact
  /// production code against a loopback `HttpServer` instead of a second,
  /// parallel implementation that could drift from it. Neither is configurable
  /// anywhere in the app: every production construction takes the defaults.
  const CalEmbedEventLinkService({
    this.endpoint = kCalEmbedEventLinkEndpoint,
    this.timeout = const Duration(seconds: 15),
  });

  final String endpoint;
  final Duration timeout;

  /// Response bytes accepted before the read is abandoned.
  ///
  /// A successful body is one JSON object holding one URL — a few hundred
  /// bytes. 64 KiB is generous by two orders of magnitude and still bounds a
  /// hostile or malfunctioning responder that would otherwise stream into
  /// memory on a phone.
  static const int _maxResponseBytes = 64 * 1024;

  @override
  Future<Uri> mint({
    required CaleePublicCalendarSource source,
    required String uid,
    String? occurrenceId,
  }) async {
    // ONE request shape. CalEmbed also accepts an explicit `null`
    // occurrenceId, and a base/token pair instead of a URL, but a client that
    // can emit four shapes is a client whose bytes have to be reasoned about
    // four times. A one-off omits the key.
    final body = utf8.encode(
      jsonEncode(<String, String>{
        'calendarUrl': source.canonicalUrl,
        'uid': uid,
        if (occurrenceId != null) 'occurrenceId': occurrenceId,
      }),
    );

    final client = HttpClient();
    try {
      client.connectionTimeout = timeout;

      final request = await client
          .postUrl(Uri.parse(endpoint))
          .timeout(timeout);

      // NO Authorization header, NO bearer token, NO cookie, NO Hub session.
      // The source calendar is already public and this endpoint is
      // unauthenticated by design; attaching an account credential here would
      // turn a signed-out action into an identified one.
      //
      // Redirects are refused rather than followed: a 30x is the one way a
      // response could otherwise re-point this request — with its body — at an
      // origin nobody validated.
      request.followRedirects = false;
      request.headers.set(HttpHeaders.contentTypeHeader, 'application/json');
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      request.headers.set(HttpHeaders.userAgentHeader, 'CaleeMobile/1');
      request.contentLength = body.length;
      request.add(body);

      final response = await request.close().timeout(timeout);
      final payload = await _readBody(response);

      if (response.statusCode != 200) throw const LocalEventLinkException();

      final Object? decoded;
      try {
        decoded = jsonDecode(payload);
      } catch (_) {
        throw const LocalEventLinkException();
      }
      if (decoded is! Map<String, dynamic>) {
        throw const LocalEventLinkException();
      }

      final url = decoded['url'];
      if (url is! String) throw const LocalEventLinkException();

      final link = calEmbedEventLink(url);
      if (link == null) throw const LocalEventLinkException();

      return link;
    } on LocalEventLinkException {
      rethrow;
    } catch (_) {
      // Timeout, socket failure, TLS handshake, malformed response — one
      // outcome, and nothing about it is logged: the URI carries the public
      // calendar token and the body carries the source UID.
      throw const LocalEventLinkException();
    } finally {
      client.close(force: true);
    }
  }

  Future<String> _readBody(HttpClientResponse response) async {
    final bytes = <int>[];
    await for (final chunk in response.timeout(timeout)) {
      bytes.addAll(chunk);
      if (bytes.length > _maxResponseBytes) {
        throw const LocalEventLinkException();
      }
    }
    return utf8.decode(bytes, allowMalformed: true);
  }
}

/// The canonical Event Link shape this build accepts back from the mint
/// endpoint.
///
///  * origin exactly `https://calembed.calee.com.au` — no userinfo (`@`), no
///    explicit port (`:`) and no other host, because none of those characters
///    is in the pattern;
///  * path exactly `/e/<reference>`, with no second segment and no `.`
///    outside the reference's own two separators, so `/e/../x` cannot pass;
///  * reference in the v1 shape `1.<base64url>.<base64url>`, each part
///    non-empty;
///  * no query string and no fragment, on the terminating anchor.
final RegExp _kEventLinkPattern = RegExp(
  r'^https://calembed\.calee\.com\.au'
  r'/e/(1\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+)$',
);

/// [value] as a canonical Event Link [Uri], or null when it is not one.
///
/// This is the gate that keeps a compromised, misconfigured or simply wrong
/// response from turning one Share tap into "CaleeMobile handed my contacts a
/// link to attacker.example". The server's answer is data, not instruction:
/// nothing about a 200 makes the URL inside it trustworthy.
///
/// It does NOT verify the HMAC. CalEmbed owns the secret and the signature;
/// this checks only that the phone is about to share a Calee URL of the shape
/// this version mints, and it fails closed on anything else — including a
/// future `2.` reference, which would ship together with the client that
/// understands it.
///
/// The round-trip equality check at the end is what makes "passed unchanged"
/// literal: a string that [Uri] would re-serialise differently is refused
/// rather than silently reshaped, so the bytes handed to the share sheet are
/// the bytes CalEmbed signed.
Uri? calEmbedEventLink(String value) {
  if (!_kEventLinkPattern.hasMatch(value)) return null;

  final Uri parsed;
  try {
    parsed = Uri.parse(value);
  } catch (_) {
    return null;
  }

  return parsed.toString() == value ? parsed : null;
}
