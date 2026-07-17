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
