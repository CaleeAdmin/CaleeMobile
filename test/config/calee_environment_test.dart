import 'package:calee_mobile/config/calee_environment.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('resolveBackend', () {
    test('empty / null / blank override resolves to production', () {
      expect(
        CaleeEnvironment.resolveBackend('', allowInsecure: false),
        CaleeEnvironment.productionUri,
      );
      expect(
        CaleeEnvironment.resolveBackend(null, allowInsecure: false),
        CaleeEnvironment.productionUri,
      );
      expect(
        CaleeEnvironment.resolveBackend('   ', allowInsecure: false),
        CaleeEnvironment.productionUri,
      );
    });

    test('a valid https override is honored', () {
      final uri = CaleeEnvironment.resolveBackend(
        'https://hub-dev.calee.com.au',
        allowInsecure: false,
      );
      expect(uri, Uri.parse('https://hub-dev.calee.com.au'));
      expect(uri.host, 'hub-dev.calee.com.au');
    });

    test('surrounding whitespace on a valid override is trimmed', () {
      final uri = CaleeEnvironment.resolveBackend(
        '  https://hub-dev.calee.com.au  ',
        allowInsecure: false,
      );
      expect(uri, Uri.parse('https://hub-dev.calee.com.au'));
    });

    test('an invalid override falls back to production (release-safe)', () {
      const invalids = <String>[
        'not a url',
        'ftp://example.com',
        'https://',
        'garbage://host',
        'hub-dev.calee.com.au',
      ];
      for (final bad in invalids) {
        expect(
          CaleeEnvironment.resolveBackend(bad, allowInsecure: false),
          CaleeEnvironment.productionUri,
          reason: 'expected $bad to be rejected and fall back to production',
        );
      }
    });

    test('a plain-http override is rejected in a release build', () {
      expect(
        CaleeEnvironment.resolveBackend(
          'http://192.168.1.10:8080',
          allowInsecure: false,
        ),
        CaleeEnvironment.productionUri,
      );
    });

    test('a plain-http override is accepted in debug/regression builds', () {
      expect(
        CaleeEnvironment.resolveBackend(
          'http://192.168.1.10:8080',
          allowInsecure: true,
        ),
        Uri.parse('http://192.168.1.10:8080'),
      );
    });
  });

  group('isAcceptableBackend', () {
    test('https with a host is always acceptable', () {
      expect(
        CaleeEnvironment.isAcceptableBackend(
          Uri.parse('https://hub-dev.calee.com.au'),
          allowInsecure: false,
        ),
        isTrue,
      );
    });

    test('a hostless URL is never acceptable', () {
      expect(
        CaleeEnvironment.isAcceptableBackend(
          Uri.parse('https://'),
          allowInsecure: true,
        ),
        isFalse,
      );
    });

    test('http is acceptable only when insecure is allowed', () {
      final uri = Uri.parse('http://localhost:8080');
      expect(
        CaleeEnvironment.isAcceptableBackend(uri, allowInsecure: false),
        isFalse,
      );
      expect(
        CaleeEnvironment.isAcceptableBackend(uri, allowInsecure: true),
        isTrue,
      );
    });

    test('a non-http(s) scheme is never acceptable', () {
      expect(
        CaleeEnvironment.isAcceptableBackend(
          Uri.parse('ftp://example.com'),
          allowInsecure: true,
        ),
        isFalse,
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
        CaleeEnvironment.describeSource('https://hub.calee.com.au'),
        'default',
      );
      expect(
        CaleeEnvironment.describeSource('https://hub.calee.com.au/'),
        'default',
      );
    });

    test('a valid non-production override is reported as override', () {
      expect(
        CaleeEnvironment.describeSource(
          'https://hub-dev.calee.com.au',
          allowInsecure: false,
        ),
        'override',
      );
    });

    test('an invalid override is reported as override_rejected', () {
      expect(
        CaleeEnvironment.describeSource('nonsense', allowInsecure: false),
        'override_rejected',
      );
      expect(
        CaleeEnvironment.describeSource(
          'http://insecure.example.com',
          allowInsecure: false,
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
      // ride along in this line.
      expect(line.contains('password'), isFalse);
      expect(line.contains('@'), isFalse);
    });
  });
}
