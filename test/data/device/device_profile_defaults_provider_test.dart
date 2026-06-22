import 'dart:ui';

import 'package:calee_mobile/data/device/device_profile_defaults_provider.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('DeviceProfileDefaultsProvider.buildFromLocales()', () {
    test(
      'builds locale string as en-AU when language is en and country is AU',
      () {
        final result = DeviceProfileDefaultsProvider.buildFromLocales(const [
          Locale('en', 'AU'),
        ]);
        expect(result.locale, equals('en-AU'));
      },
    );

    test('countryCode is uppercase from platform locale', () {
      final result = DeviceProfileDefaultsProvider.buildFromLocales(const [
        Locale('en', 'AU'),
      ]);
      expect(result.countryCode, equals('AU'));
    });

    test(
      'countryCode is normalised to uppercase even if locale uses lowercase',
      () {
        // Dart's Locale constructor uppercases the country code internally, but
        // we guard against any future path that might deliver lower-case.
        // buildFromLocales calls .toUpperCase() unconditionally.
        final result = DeviceProfileDefaultsProvider.buildFromLocales(const [
          Locale('en', 'au'),
        ]);
        expect(result.countryCode, equals('AU'));
        expect(result.locale, equals('en-AU'));
      },
    );

    test('locale is language-only when countryCode is absent', () {
      final result = DeviceProfileDefaultsProvider.buildFromLocales(const [
        Locale('en'),
      ]);
      expect(result.locale, equals('en'));
      expect(result.countryCode, isNull);
    });

    test('locale and countryCode are null when locale list is empty', () {
      final result = DeviceProfileDefaultsProvider.buildFromLocales([]);
      expect(result.locale, isNull);
      expect(result.countryCode, isNull);
    });

    test('preserves timeZone when provided', () {
      final result = DeviceProfileDefaultsProvider.buildFromLocales(const [
        Locale('en', 'AU'),
      ], timeZone: 'Australia/Perth');
      expect(result.timeZone, equals('Australia/Perth'));
    });

    test('null values are omitted from patch body', () {
      final result = DeviceProfileDefaultsProvider.buildFromLocales(const [
        Locale('en', 'AU'),
      ]);
      final body = result.toProfilePatchBody();
      expect(body.containsKey('timeZone'), isFalse);
      expect(body.containsKey('locale'), isTrue);
      expect(body.containsKey('countryCode'), isTrue);
    });

    test('empty locale list produces empty defaults with no values', () {
      final result = DeviceProfileDefaultsProvider.buildFromLocales([]);
      expect(result.hasAnyValue, isFalse);
    });

    test('postalCode is null when timezone is absent', () {
      final result = DeviceProfileDefaultsProvider.buildFromLocales(const [
        Locale('en', 'AU'),
      ]);
      expect(result.postalCode, isNull);
    });

    test('uses first locale when multiple are provided', () {
      final result = DeviceProfileDefaultsProvider.buildFromLocales(const [
        Locale('en', 'AU'),
        Locale('fr', 'FR'),
      ]);
      expect(result.locale, equals('en-AU'));
      expect(result.countryCode, equals('AU'));
    });
  });

  group('timezone-to-postcode mapping (AU only)', () {
    test('Australia/Perth maps to 6000', () {
      final result = DeviceProfileDefaultsProvider.buildFromLocales(const [
        Locale('en', 'AU'),
      ], timeZone: 'Australia/Perth');
      expect(result.postalCode, equals('6000'));
    });

    test('Australia/Sydney maps to 2000', () {
      final result = DeviceProfileDefaultsProvider.buildFromLocales(const [
        Locale('en', 'AU'),
      ], timeZone: 'Australia/Sydney');
      expect(result.postalCode, equals('2000'));
    });

    test('Australia/Melbourne maps to 3000', () {
      final result = DeviceProfileDefaultsProvider.buildFromLocales(const [
        Locale('en', 'AU'),
      ], timeZone: 'Australia/Melbourne');
      expect(result.postalCode, equals('3000'));
    });

    test('Australia/Brisbane maps to 4000', () {
      final result = DeviceProfileDefaultsProvider.buildFromLocales(const [
        Locale('en', 'AU'),
      ], timeZone: 'Australia/Brisbane');
      expect(result.postalCode, equals('4000'));
    });

    test('Australia/Adelaide maps to 5000', () {
      final result = DeviceProfileDefaultsProvider.buildFromLocales(const [
        Locale('en', 'AU'),
      ], timeZone: 'Australia/Adelaide');
      expect(result.postalCode, equals('5000'));
    });

    test('Australia/Darwin maps to 0800 (preserves leading zero)', () {
      final result = DeviceProfileDefaultsProvider.buildFromLocales(const [
        Locale('en', 'AU'),
      ], timeZone: 'Australia/Darwin');
      expect(result.postalCode, equals('0800'));
    });

    test('Australia/Hobart maps to 7000', () {
      final result = DeviceProfileDefaultsProvider.buildFromLocales(const [
        Locale('en', 'AU'),
      ], timeZone: 'Australia/Hobart');
      expect(result.postalCode, equals('7000'));
    });

    test('unknown Australian timezone yields null postalCode', () {
      final result = DeviceProfileDefaultsProvider.buildFromLocales(const [
        Locale('en', 'AU'),
      ], timeZone: 'Australia/Lord_Howe');
      expect(result.postalCode, isNull);
    });

    test('non-AU country yields null postalCode even for an AU timezone', () {
      final result = DeviceProfileDefaultsProvider.buildFromLocales(const [
        Locale('en', 'US'),
      ], timeZone: 'Australia/Perth');
      expect(result.postalCode, isNull);
    });

    test('no country code yields null postalCode', () {
      final result = DeviceProfileDefaultsProvider.buildFromLocales(const [
        Locale('en'),
      ], timeZone: 'Australia/Perth');
      expect(result.postalCode, isNull);
    });
  });
}
