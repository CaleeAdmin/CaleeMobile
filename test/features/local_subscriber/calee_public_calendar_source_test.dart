// Strict source eligibility for signed-out sharing
// (CaleeAdmin/CaleeMobile#558).
//
// This suite is the Mobile mirror of CalEmbed's
// calee_calendar_validate_legacy_ics_url() (lib/calendar_sources.php). The two
// must accept exactly the same URLs: anything this one accepts that CalEmbed
// refuses becomes a Share button that always fails, and anything this one
// refuses that CalEmbed accepts is only a lost feature — so the acceptable
// direction of drift is "Mobile is narrower", never the reverse.

import 'package:calee_mobile/features/local_subscriber/calee_public_calendar_source.dart';
import 'package:flutter_test/flutter_test.dart';

/// A syntactically valid token of [length] characters.
String _token(int length) => List.filled(length, 'a').join();

const _kValidToken = 'AbC123_-xyz';

String _url({
  String scheme = 'https',
  String host = 'portal.calee.com.au',
  String path = '/remote.php/dav/public-calendars/',
  String token = _kValidToken,
  String query = '?export',
}) => '$scheme://$host$path$token$query';

void main() {
  group('CaleePublicCalendarSource — registry', () {
    test('mirrors CalEmbed\'s three registered public origins', () {
      expect(kCaleePublicCalendarOrigins, {
        'portal': 'https://portal.calee.com.au',
        'business': 'https://business.calee.com.au',
        'cewa': 'https://cewa.calee.com.au',
      });
    });

    for (final entry in kCaleePublicCalendarOrigins.entries) {
      test('accepts the ${entry.key} public export URL', () {
        final source = CaleePublicCalendarSource.tryParse(
          '${entry.value}/remote.php/dav/public-calendars/$_kValidToken?export',
        );

        expect(source, isNotNull);
        expect(source!.base, entry.key);
        expect(source.token, _kValidToken);
        expect(
          source.canonicalUrl,
          '${entry.value}/remote.php/dav/public-calendars/$_kValidToken?export',
        );
      });
    }
  });

  group('CaleePublicCalendarSource — token boundaries', () {
    test('accepts the shortest legal token (8)', () {
      final source = CaleePublicCalendarSource.tryParse(_url(token: _token(8)));
      expect(source, isNotNull);
      expect(source!.token, _token(8));
    });

    test('accepts the longest legal token (128)', () {
      final source = CaleePublicCalendarSource.tryParse(
        _url(token: _token(128)),
      );
      expect(source, isNotNull);
      expect(source!.token.length, 128);
    });

    test('refuses a token one character too short (7)', () {
      expect(
        CaleePublicCalendarSource.tryParse(_url(token: _token(7))),
        isNull,
      );
    });

    test('refuses a token one character too long (129)', () {
      expect(
        CaleePublicCalendarSource.tryParse(_url(token: _token(129))),
        isNull,
      );
    });

    test('accepts the full legal token charset', () {
      const token =
          'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-';
      final source = CaleePublicCalendarSource.tryParse(_url(token: token));
      expect(source, isNotNull);
      expect(source!.token, token);
    });
  });

  group('CaleePublicCalendarSource — host handling', () {
    test('resolves a registered host spelled in upper case', () {
      // Hosts are case-insensitive and CalEmbed lower-cases before comparing.
      final source = CaleePublicCalendarSource.tryParse(
        _url(host: 'PORTAL.Calee.Com.Au'),
      );
      expect(source, isNotNull);
      expect(source!.base, 'portal');
      // The canonical URL is rebuilt from the registry, so the bytes sent to
      // the mint endpoint do not depend on how the row was spelled.
      expect(
        source.canonicalUrl,
        'https://portal.calee.com.au'
        '/remote.php/dav/public-calendars/$_kValidToken?export',
      );
    });
  });

  group('CaleePublicCalendarSource — refusals', () {
    final rejected = <String, String?>{
      'null': null,
      'empty': '',
      'blank': '   ',
      'plain http': _url(scheme: 'http'),
      'webcal': _url(scheme: 'webcal'),
      'upper-case scheme': _url(scheme: 'HTTPS'),
      'scheme-relative':
          '//portal.calee.com.au'
          '/remote.php/dav/public-calendars/$_kValidToken?export',
      'arbitrary external host': _url(host: 'example.com'),
      'arbitrary external ICS': 'https://example.com/calendar.ics',
      'Google Calendar':
          'https://calendar.google.com/calendar/ical/x%40group.calendar'
          '.google.com/public/basic.ics',
      'Outlook':
          'https://outlook.office365.com/owa/calendar/abc/reachcalendar.ics',
      'host suffix attack': _url(host: 'portal.calee.com.au.attacker.example'),
      'host prefix attack': _url(host: 'attacker-portal.calee.com.au'),
      'registered-host subdomain': _url(host: 'foo.portal.calee.com.au'),
      'trailing dot host': _url(host: 'portal.calee.com.au.'),
      'credentials': _url(host: 'user:pass@portal.calee.com.au'),
      'user-only credentials': _url(host: 'attacker@portal.calee.com.au'),
      'explicit default port': _url(host: 'portal.calee.com.au:443'),
      'explicit alternate port': _url(host: 'portal.calee.com.au:8443'),
      'fragment': '${_url()}#frag',
      'empty fragment': '${_url()}#',
      'private DAV path': _url(
        path: '/remote.php/dav/calendars/alice/personal/',
      ),
      'wrong DAV path': _url(path: '/remote.php/dav/public-calendar/'),
      'unescaped-dot path': _url(path: '/remoteXphp/dav/public-calendars/'),
      'extra path segment': '${_url(query: '')}/extra?export',
      'leading extra segment': _url(
        path: '/x/remote.php/dav/public-calendars/',
      ),
      'double slash path': _url(path: '//remote.php/dav/public-calendars/'),
      'trailing slash': _url(query: '/?export'),
      'missing query': _url(query: ''),
      'bare question mark': _url(query: '?'),
      'export with value': _url(query: '?export=1'),
      'export plus extra param': _url(query: '?export&foo=bar'),
      'extra param before export': _url(query: '?foo=bar&export'),
      'repeated export': _url(query: '?export&export'),
      'upper-case export': _url(query: '?EXPORT'),
      'percent-encoded traversal': _url(
        path: '/remote.php/dav/public-calendars/%2e%2e/',
      ),
      'percent-encoded token': _url(token: 'abcdef%20gh'),
      'dotted token': _url(token: 'abc.defgh'),
      'plus in token': _url(token: 'abcdefg+h'),
      'slash in token': _url(token: 'abcd/efgh'),
      'query-in-token': _url(token: 'abcdefgh?x'),
      'leading whitespace': ' ${_url()}',
      'trailing whitespace': '${_url()} ',
      'embedded newline': '${_url()}\n',
    };

    rejected.forEach((label, url) {
      test('refuses $label', () {
        expect(
          CaleePublicCalendarSource.tryParse(url),
          isNull,
          reason: 'must not be treated as a public Calee calendar: $url',
        );
      });
    });
  });
}
