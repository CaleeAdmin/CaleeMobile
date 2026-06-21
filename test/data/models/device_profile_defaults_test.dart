import 'package:calee_mobile/data/models/device_profile_defaults.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('DeviceProfileDefaults.toProfilePatchBody()', () {
    test('includes only non-null fields', () {
      const d = DeviceProfileDefaults(
        timeZone: 'Australia/Perth',
        locale: 'en-AU',
        countryCode: 'AU',
      );
      final body = d.toProfilePatchBody();
      expect(
        body,
        equals({
          'timeZone': 'Australia/Perth',
          'locale': 'en-AU',
          'countryCode': 'AU',
        }),
      );
    });

    test('excludes null timeZone', () {
      const d = DeviceProfileDefaults(locale: 'en-AU', countryCode: 'AU');
      final body = d.toProfilePatchBody();
      expect(body.containsKey('timeZone'), isFalse);
    });

    test('excludes null locale', () {
      const d = DeviceProfileDefaults(timeZone: 'Australia/Perth');
      final body = d.toProfilePatchBody();
      expect(body.containsKey('locale'), isFalse);
    });

    test('excludes null countryCode', () {
      const d = DeviceProfileDefaults(
        timeZone: 'Australia/Perth',
        locale: 'en',
      );
      final body = d.toProfilePatchBody();
      expect(body.containsKey('countryCode'), isFalse);
    });

    test('never includes postalCode', () {
      const d = DeviceProfileDefaults(
        timeZone: 'Australia/Perth',
        locale: 'en-AU',
        countryCode: 'AU',
      );
      final body = d.toProfilePatchBody();
      expect(body.containsKey('postalCode'), isFalse);
    });

    test('never includes email', () {
      const d = DeviceProfileDefaults(
        timeZone: 'Australia/Perth',
        locale: 'en-AU',
        countryCode: 'AU',
      );
      final body = d.toProfilePatchBody();
      expect(body.containsKey('email'), isFalse);
      expect(body.containsKey('primaryEmail'), isFalse);
    });

    test('returns empty map when all fields are null', () {
      const d = DeviceProfileDefaults();
      expect(d.toProfilePatchBody(), isEmpty);
    });
  });

  group('DeviceProfileDefaults.hasAnyValue', () {
    test('true when timeZone is set', () {
      expect(const DeviceProfileDefaults(timeZone: 'UTC').hasAnyValue, isTrue);
    });

    test('true when locale is set', () {
      expect(const DeviceProfileDefaults(locale: 'en').hasAnyValue, isTrue);
    });

    test('true when countryCode is set', () {
      expect(
        const DeviceProfileDefaults(countryCode: 'AU').hasAnyValue,
        isTrue,
      );
    });

    test('false when all fields are null', () {
      expect(const DeviceProfileDefaults().hasAnyValue, isFalse);
    });
  });
}
