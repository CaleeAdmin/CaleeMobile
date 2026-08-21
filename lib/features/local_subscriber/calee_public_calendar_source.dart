/// Strict, Mobile-side recognition of an ALREADY-PUBLIC Calee calendar.
///
/// V1 signed-out sharing (CaleeAdmin/CaleeMobile#558) is offered for one kind
/// of source only: a calendar the owner has already published from a
/// registered Calee Nextcloud instance. Everything else a phone can follow —
/// a private family feed, Google, Outlook, an arbitrary HTTPS `.ics` — is
/// refused here, before any identity is assembled and before any request
/// leaves the device.
///
/// This layer is a UX AND PRIVACY guard, not the security boundary. CalEmbed's
/// `calee_calendar_validate_legacy_ics_url()` re-validates the same URL when
/// `/event-link` receives it and is the sole authority on what may be minted;
/// this file exists so a Share action is never offered for a source the server
/// would refuse, and so a private feed's URL never leaves the phone at all.
/// The two implementations are deliberately identical in what they accept, and
/// this one is allowed to be narrower, never wider.
///
/// The grammar is matched against the RAW stored string rather than a parsed
/// [Uri]. Dart's URI parser normalises away exactly the things that have to be
/// refused — it drops an explicit `:443` because it is the scheme's default
/// port, and it percent-decodes unreserved characters, so `%2e%2e` could
/// become `..` on the way in. A single anchored pattern over the original
/// bytes cannot be talked around that way: a character that is not in the
/// grammar is simply not accepted anywhere.
///
/// The subscription's `source` field is NOT consulted. It is descriptive,
/// legacy, and writable by whatever flow created the subscription, so it
/// cannot decide whether a calendar is public. The stored URL is the only
/// input.
library;

import 'package:flutter/foundation.dart';

/// Canonical public-calendar registry, mirrored from CalEmbed's
/// `calee_calendar_sources()` (`lib/calendar_sources.php`).
///
/// Base key => origin (scheme + host, no trailing slash). Adding a host here
/// without adding it to CalEmbed's registry would offer a Share action the
/// server then refuses; the two lists must move together.
const Map<String, String> kCaleePublicCalendarOrigins = <String, String>{
  'portal': 'https://portal.calee.com.au',
  'business': 'https://business.calee.com.au',
  'cewa': 'https://cewa.calee.com.au',
};

/// The exact public export route. Anchored, and deliberately built from
/// character classes that exclude `@`, `:`, `#`, `%` and `/` wherever they
/// would allow a different URL to be read as this one:
///
///  * `https` only — lower case, as PHP's `parse_url()` reports it verbatim
///    and CalEmbed compares it verbatim;
///  * host has no userinfo (`@`) and no explicit port (`:`) because neither
///    character can appear in the host class;
///  * path is exactly `/remote.php/dav/public-calendars/<token>`, with the
///    literal `.` in `remote.php` escaped so `remoteXphp` cannot pass, and no
///    `/` in the token class so an extra segment cannot pass;
///  * query is exactly `export` — `?export=1` and `?export&foo=bar` both fail
///    on the terminating anchor;
///  * no fragment, because `#` appears nowhere in the pattern.
final RegExp _kPublicIcsUrlPattern = RegExp(
  r'^https://([A-Za-z0-9.-]+)'
  r'/remote\.php/dav/public-calendars/'
  r'([A-Za-z0-9_-]{8,128})'
  r'\?export$',
);

/// One registered, already-public Calee calendar, resolved from a stored
/// subscription URL.
///
/// Instances only ever exist for a URL that passed the full grammar, so
/// holding one IS the eligibility proof — there is no "unvalidated" state of
/// this class to accidentally trust.
@immutable
class CaleePublicCalendarSource {
  const CaleePublicCalendarSource._({
    required this.base,
    required this.token,
    required this.canonicalUrl,
  });

  /// Registry key (`portal`, `business`, `cewa`).
  final String base;

  /// The public calendar token, exactly as it appeared in the URL.
  ///
  /// Public in the sense that the owner published it, but still a bearer
  /// value: it must never be logged, rendered, or shown in event details.
  final String token;

  /// The canonical public ICS export URL for [base] + [token], rebuilt from
  /// the registry rather than echoed back from the caller.
  ///
  /// Rebuilding is what makes this value safe to send: the host is the
  /// registry's own lower-case spelling, and the query is the one literal
  /// form, so a stored URL that differed only in host case produces the same
  /// canonical bytes — and therefore the same Event Link — as every other
  /// client.
  final String canonicalUrl;

  /// The public Calee source this stored subscription URL names, or null when
  /// it is not EXACTLY one.
  ///
  /// Fails closed on every difference, including ones that look cosmetic: a
  /// `webcal://` scheme, surrounding whitespace, or a trailing slash all
  /// return null. Newly followed calendars are normalised to the HTTPS form
  /// when they are stored, and an older or hand-edited row that is not in that
  /// exact shape simply gets no Share action — its display behaviour is
  /// untouched.
  static CaleePublicCalendarSource? tryParse(String? url) {
    if (url == null || url.isEmpty) return null;

    final match = _kPublicIcsUrlPattern.firstMatch(url);
    if (match == null) return null;

    // Hosts are case-insensitive, and CalEmbed lower-cases before its exact
    // comparison. Match that, then resolve by EXACT equality so neither a
    // subdomain of a registered host (`foo.portal.calee.com.au`) nor a host
    // that merely starts with one (`portal.calee.com.au.attacker.example`)
    // can resolve.
    final host = match[1]!.toLowerCase();
    final token = match[2]!;

    for (final entry in kCaleePublicCalendarOrigins.entries) {
      if (host == _originHost(entry.value)) {
        return CaleePublicCalendarSource._(
          base: entry.key,
          token: token,
          canonicalUrl:
              '${entry.value}/remote.php/dav/public-calendars/$token?export',
        );
      }
    }

    return null;
  }

  static String _originHost(String origin) =>
      origin.substring('https://'.length);
}
