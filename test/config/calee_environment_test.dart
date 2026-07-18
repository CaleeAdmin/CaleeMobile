import 'package:calee_mobile/config/calee_environment.dart';
import 'package:flutter_test/flutter_test.dart';

/// Build-mode shorthands for the two orthogonal permissions
/// [CaleeEnvironment.resolveBackend] takes:
///
///  * a production release grants neither (only https, only production host);
///  * a regression build grants a non-production host but still requires
///    https;
///  * a debug build grants both (non-production host and plain http).
Uri _resolveProduction(String? raw) => CaleeEnvironment.resolveBackend(
  raw,
  allowInsecure: false,
  allowNonProduction: false,
);

Uri _resolveRegression(String? raw) => CaleeEnvironment.resolveBackend(
  raw,
  allowInsecure: false,
  allowNonProduction: true,
);

Uri _resolveDebug(String? raw) => CaleeEnvironment.resolveBackend(
  raw,
  allowInsecure: true,
  allowNonProduction: true,
);

void main() {
  group('resolveBackend — the eight release-safety cases', () {
    test('1. production default: no override resolves to production', () {
      expect(_resolveProduction(''), CaleeEnvironment.productionUri);
      expect(_resolveProduction(null), CaleeEnvironment.productionUri);
      expect(_resolveProduction('   '), CaleeEnvironment.productionUri);
    });

    test('2. an approved regression https backend is honored', () {
      final uri = _resolveRegression('https://hub-dev.calee.com.au');
      expect(uri, Uri.parse('https://hub-dev.calee.com.au'));
      expect(uri.host, 'hub-dev.calee.com.au');
      // Whitespace around a valid override is trimmed.
      expect(
        _resolveRegression('  https://hub-dev.calee.com.au  '),
        Uri.parse('https://hub-dev.calee.com.au'),
      );
    });

    test('3. a local debug http backend is honored', () {
      expect(
        _resolveDebug('http://192.168.1.10:8080'),
        Uri.parse('http://192.168.1.10:8080'),
      );
      expect(
        _resolveDebug('http://localhost:8080'),
        Uri.parse('http://localhost:8080'),
      );
    });

    test('4. an arbitrary https host in production is rejected', () {
      // This is the core of the policy: a production-signed build must never
      // be redirected at some other https host, however well-formed.
      for (final arbitrary in <String>[
        'https://evil.example.com',
        'https://hub.calee.com.au.attacker.test',
        'https://not-calee.com',
        'https://hub-dev.calee.com.au', // even a real regression host
      ]) {
        expect(
          _resolveProduction(arbitrary),
          CaleeEnvironment.productionUri,
          reason: '$arbitrary must fall back to production in a release build',
        );
      }
      // The production host itself is, of course, still accepted in production.
      expect(
        _resolveProduction('https://hub.calee.com.au'),
        CaleeEnvironment.productionUri,
      );
    });

    test('5. a url carrying user information is rejected in every mode', () {
      const withUserInfo = <String>[
        'https://user:pass@hub-dev.calee.com.au',
        'https://admin@hub.calee.com.au',
      ];
      for (final bad in withUserInfo) {
        expect(_resolveProduction(bad), CaleeEnvironment.productionUri);
        expect(
          _resolveRegression(bad),
          CaleeEnvironment.productionUri,
          reason: 'credentials in a backend URL are never acceptable: $bad',
        );
        expect(_resolveDebug(bad), CaleeEnvironment.productionUri);
      }
    });

    test('6. a url carrying a query or fragment (or path) is rejected', () {
      const withExtras = <String>[
        'https://hub-dev.calee.com.au?token=abc',
        'https://hub-dev.calee.com.au#frag',
        'https://hub-dev.calee.com.au/api/v2',
      ];
      for (final bad in withExtras) {
        expect(
          _resolveRegression(bad),
          CaleeEnvironment.productionUri,
          reason: 'a backend base URL must not carry query/fragment/path: $bad',
        );
        expect(_resolveDebug(bad), CaleeEnvironment.productionUri);
      }
    });

    test('7. a malformed override falls back to production', () {
      const invalids = <String>[
        'not a url',
        'ftp://example.com',
        'https://',
        'garbage://host',
        'hub-dev.calee.com.au', // scheme-less
      ];
      for (final bad in invalids) {
        expect(
          _resolveDebug(bad),
          CaleeEnvironment.productionUri,
          reason: 'expected $bad to be rejected and fall back to production',
        );
        expect(_resolveProduction(bad), CaleeEnvironment.productionUri);
      }
    });

    test('8. an empty override resolves to production', () {
      expect(_resolveProduction(''), CaleeEnvironment.productionUri);
      expect(_resolveRegression(''), CaleeEnvironment.productionUri);
      expect(_resolveDebug(''), CaleeEnvironment.productionUri);
    });
  });

  group('resolveBackend — scheme and host interplay', () {
    test('plain http is rejected whenever insecure is not allowed', () {
      // Even a regression build (non-production host allowed) still requires
      // https unless http was explicitly opted into.
      expect(
        _resolveRegression('http://hub-dev.calee.com.au'),
        CaleeEnvironment.productionUri,
      );
      expect(
        _resolveProduction('http://192.168.1.10:8080'),
        CaleeEnvironment.productionUri,
      );
    });

    test('an arbitrary https host is rejected even in regression mode', () {
      // allowNonProduction opens the door only to the approved allow-list,
      // never to any https host on the internet.
      expect(
        _resolveRegression('https://evil.example.com'),
        CaleeEnvironment.productionUri,
      );
      expect(
        _resolveDebug('https://evil.example.com'),
        CaleeEnvironment.productionUri,
      );
    });

    test('every allow-listed non-production host is honored in regression', () {
      for (final host in CaleeEnvironment.allowedNonProductionHosts) {
        final uri = _resolveRegression('https://$host');
        expect(uri.host, host);
      }
    });
  });

  group('isAcceptableBackend', () {
    test('the production host is acceptable in every mode', () {
      final uri = Uri.parse(CaleeEnvironment.productionBaseUrl);
      expect(
        CaleeEnvironment.isAcceptableBackend(
          uri,
          allowInsecure: false,
          allowNonProduction: false,
        ),
        isTrue,
      );
    });

    test('an arbitrary https host is not acceptable in production', () {
      expect(
        CaleeEnvironment.isAcceptableBackend(
          Uri.parse('https://somewhere.example.com'),
          allowInsecure: false,
          allowNonProduction: false,
        ),
        isFalse,
      );
    });

    test(
      'an allow-listed https host is acceptable only for non-production',
      () {
        final uri = Uri.parse('https://hub-dev.calee.com.au');
        expect(
          CaleeEnvironment.isAcceptableBackend(
            uri,
            allowInsecure: false,
            allowNonProduction: false,
          ),
          isFalse,
        );
        expect(
          CaleeEnvironment.isAcceptableBackend(
            uri,
            allowInsecure: false,
            allowNonProduction: true,
          ),
          isTrue,
        );
      },
    );

    test('a hostless URL is never acceptable', () {
      expect(
        CaleeEnvironment.isAcceptableBackend(
          Uri.parse('https://'),
          allowInsecure: true,
          allowNonProduction: true,
        ),
        isFalse,
      );
    });

    test('http is acceptable only when insecure is allowed', () {
      final uri = Uri.parse('http://localhost:8080');
      expect(
        CaleeEnvironment.isAcceptableBackend(
          uri,
          allowInsecure: false,
          allowNonProduction: true,
        ),
        isFalse,
      );
      expect(
        CaleeEnvironment.isAcceptableBackend(
          uri,
          allowInsecure: true,
          allowNonProduction: true,
        ),
        isTrue,
      );
    });

    test('a non-http(s) scheme is never acceptable', () {
      expect(
        CaleeEnvironment.isAcceptableBackend(
          Uri.parse('ftp://example.com'),
          allowInsecure: true,
          allowNonProduction: true,
        ),
        isFalse,
      );
    });

    test('user info, query, fragment and non-root path are rejected', () {
      const unsafe = <String>[
        'https://user:pass@hub.calee.com.au',
        'https://hub.calee.com.au?x=1',
        'https://hub.calee.com.au#y',
        'https://hub.calee.com.au/api',
      ];
      for (final raw in unsafe) {
        expect(
          CaleeEnvironment.isAcceptableBackend(
            Uri.parse(raw),
            allowInsecure: true,
            allowNonProduction: true,
          ),
          isFalse,
          reason: '$raw is structurally unsafe for a backend base URL',
        );
      }
    });

    test('the production host with a trailing slash is acceptable', () {
      expect(
        CaleeEnvironment.isAcceptableBackend(
          Uri.parse('https://hub.calee.com.au/'),
          allowInsecure: false,
          allowNonProduction: false,
        ),
        isTrue,
      );
    });
  });

  group('describeSource', () {
    test('no override is reported as default', () {
      expect(CaleeEnvironment.describeSource(''), 'default');
      expect(CaleeEnvironment.describeSource(null), 'default');
    });

    test('an override equal to production is reported as default', () {
      expect(
        CaleeEnvironment.describeSource(
          'https://hub.calee.com.au',
          allowNonProduction: false,
        ),
        'default',
      );
      expect(
        CaleeEnvironment.describeSource(
          'https://hub.calee.com.au/',
          allowNonProduction: false,
        ),
        'default',
      );
    });

    test('an approved non-production override is reported as override', () {
      expect(
        CaleeEnvironment.describeSource(
          'https://hub-dev.calee.com.au',
          allowInsecure: false,
          allowNonProduction: true,
        ),
        'override',
      );
    });

    test('a rejected override is reported as override_rejected', () {
      expect(
        CaleeEnvironment.describeSource('nonsense', allowNonProduction: true),
        'override_rejected',
      );
      expect(
        CaleeEnvironment.describeSource(
          'http://insecure.example.com',
          allowInsecure: false,
          allowNonProduction: true,
        ),
        'override_rejected',
      );
      // An arbitrary https host in a production build is a rejected override.
      expect(
        CaleeEnvironment.describeSource(
          'https://evil.example.com',
          allowInsecure: false,
          allowNonProduction: false,
        ),
        'override_rejected',
      );
    });
  });

  group('backend port policy — adversarial cases', () {
    // Each case is exercised against the resolved URI *and* describeSource, in
    // the mode where its behaviour is most telling. A hostname match alone must
    // never be enough to accept an arbitrary explicit port.

    test('explicit :443 on the production host is canonicalized', () {
      // Dart normalizes the scheme-default port away, so an explicit :443 is
      // the plain production endpoint. Policy: canonicalize (accept), do not
      // treat it as a distinct off-policy endpoint.
      const raw = 'https://hub.calee.com.au:443';
      expect(_resolveProduction(raw), CaleeEnvironment.productionUri);
      expect(_resolveRegression(raw), CaleeEnvironment.productionUri);
      expect(_resolveDebug(raw), CaleeEnvironment.productionUri);
      // Because it resolves to the canonical production endpoint, its source is
      // reported as the safe default, not a rejected override.
      expect(
        CaleeEnvironment.describeSource(raw, allowNonProduction: false),
        'default',
      );
      expect(
        CaleeEnvironment.isAcceptableBackend(
          Uri.parse(raw),
          allowInsecure: false,
          allowNonProduction: false,
        ),
        isTrue,
      );
    });

    test('a non-standard port on the production host is rejected', () {
      // The hostname matches, but :444 is a different, off-policy endpoint. It
      // must be rejected in every mode and fall back to production.
      const raw = 'https://hub.calee.com.au:444';
      expect(_resolveProduction(raw), CaleeEnvironment.productionUri);
      expect(_resolveRegression(raw), CaleeEnvironment.productionUri);
      expect(_resolveDebug(raw), CaleeEnvironment.productionUri);
      expect(
        CaleeEnvironment.describeSource(raw, allowNonProduction: false),
        'override_rejected',
      );
      expect(
        CaleeEnvironment.describeSource(raw, allowNonProduction: true),
        'override_rejected',
      );
      expect(
        CaleeEnvironment.isAcceptableBackend(
          Uri.parse(raw),
          allowInsecure: true,
          allowNonProduction: true,
        ),
        isFalse,
      );
    });

    test('explicit :443 on an approved non-prod host is canonicalized', () {
      // An approved host on the standard port is the approved endpoint; the
      // explicit :443 canonicalizes to the plain host.
      const raw = 'https://hub-dev.calee.com.au:443';
      expect(
        _resolveRegression(raw),
        Uri.parse('https://hub-dev.calee.com.au'),
      );
      expect(
        CaleeEnvironment.describeSource(
          raw,
          allowInsecure: false,
          allowNonProduction: true,
        ),
        'override',
      );
      // In a production build a non-production host is rejected regardless.
      expect(_resolveProduction(raw), CaleeEnvironment.productionUri);
      expect(
        CaleeEnvironment.describeSource(raw, allowNonProduction: false),
        'override_rejected',
      );
    });

    test('a non-standard port on an approved non-prod host is rejected', () {
      // hub-dev is approved, but only on the standard port. :9443 is not an
      // approved host+port combination.
      const raw = 'https://hub-dev.calee.com.au:9443';
      expect(_resolveRegression(raw), CaleeEnvironment.productionUri);
      expect(_resolveDebug(raw), CaleeEnvironment.productionUri);
      expect(_resolveProduction(raw), CaleeEnvironment.productionUri);
      expect(
        CaleeEnvironment.describeSource(raw, allowNonProduction: true),
        'override_rejected',
      );
      expect(
        CaleeEnvironment.isAcceptableBackend(
          Uri.parse(raw),
          allowInsecure: false,
          allowNonProduction: true,
        ),
        isFalse,
      );
    });

    test('a trailing-dot production host is rejected', () {
      // `hub.calee.com.au.` is a distinct host string from the canonical
      // production host and is never an approved endpoint.
      const raw = 'https://hub.calee.com.au./';
      expect(_resolveProduction(raw), CaleeEnvironment.productionUri);
      expect(_resolveRegression(raw), CaleeEnvironment.productionUri);
      expect(_resolveDebug(raw), CaleeEnvironment.productionUri);
      expect(
        CaleeEnvironment.describeSource(raw, allowNonProduction: true),
        'override_rejected',
      );
      expect(
        CaleeEnvironment.isAcceptableBackend(
          Uri.parse(raw),
          allowInsecure: false,
          allowNonProduction: false,
        ),
        isFalse,
      );
    });

    test('the upper-case production host is canonicalized', () {
      // Host comparison is case-insensitive; an upper-case host resolves to the
      // canonical production endpoint.
      const raw = 'https://HUB.CALEE.COM.AU';
      expect(_resolveProduction(raw), CaleeEnvironment.productionUri);
      expect(
        CaleeEnvironment.describeSource(raw, allowNonProduction: false),
        'default',
      );
      expect(
        CaleeEnvironment.isAcceptableBackend(
          Uri.parse(raw),
          allowInsecure: false,
          allowNonProduction: false,
        ),
        isTrue,
      );
    });

    test('a production host smuggled into user info is rejected', () {
      // The real host here is evil.example; the production host is only the
      // user-info component. Credentials/user-info are always rejected.
      const raw = 'https://hub.calee.com.au@evil.example';
      expect(_resolveProduction(raw), CaleeEnvironment.productionUri);
      expect(_resolveRegression(raw), CaleeEnvironment.productionUri);
      expect(_resolveDebug(raw), CaleeEnvironment.productionUri);
      expect(
        CaleeEnvironment.describeSource(raw, allowNonProduction: true),
        'override_rejected',
      );
      // The diagnostic line for the resolved (safe) backend never leaks the
      // smuggled user-info token.
      final line = CaleeEnvironment.diagnosticLine();
      expect(line.contains('evil.example'), isFalse);
      expect(line.contains('@'), isFalse);
    });

    test('a look-alike suffix host is rejected', () {
      // hub.calee.com.au.attacker.example is a different host, not production.
      const raw = 'https://hub.calee.com.au.attacker.example';
      expect(_resolveProduction(raw), CaleeEnvironment.productionUri);
      expect(_resolveRegression(raw), CaleeEnvironment.productionUri);
      expect(_resolveDebug(raw), CaleeEnvironment.productionUri);
      expect(
        CaleeEnvironment.describeSource(raw, allowNonProduction: true),
        'override_rejected',
      );
    });

    test('a local debug http backend keeps its configurable port', () {
      // The port restriction applies only to https; a permitted plain-http
      // dev hub may use any port.
      expect(
        _resolveDebug('http://192.168.1.10:8080'),
        Uri.parse('http://192.168.1.10:8080'),
      );
      expect(
        _resolveDebug('http://localhost:5001'),
        Uri.parse('http://localhost:5001'),
      );
    });
  });

  group('diagnostics', () {
    test('the default build resolves to production and stays production', () {
      // A plain `flutter test` run supplies no --dart-define, so the compiled
      // default must be the production backend.
      expect(CaleeEnvironment.apiBaseUri, CaleeEnvironment.productionUri);
      expect(CaleeEnvironment.isProductionBackend, isTrue);
      expect(CaleeEnvironment.backendSource, 'default');
    });

    test('the diagnostic line is stable, greppable and leaks no secret', () {
      final line = CaleeEnvironment.diagnosticLine();
      expect(line, startsWith('CALEE_ENV backend='));
      expect(line, contains('production='));
      expect(line, contains('source='));
      expect(line, contains(CaleeEnvironment.resolvedBaseUrl));
      // A base URL is not sensitive; assert no credential-looking token can
      // ride along in this line (URLs carrying user info are rejected before
      // they can ever be resolved).
      expect(line.contains('password'), isFalse);
      expect(line.contains('@'), isFalse);
    });
  });
}
