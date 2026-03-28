import 'package:caleesync/common/utils/CaleeUidSanitizer.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('safe UUID passes through unchanged', () {
    const String uid = 'AE6C35CC-3203-44D8-A56C-973D48D7E289';
    expect(CaleeUidSanitizer.isSafeForRemotePut(uid), isTrue);
    expect(CaleeUidSanitizer.normalizeForRemotePut(uid), uid);
  });

  test('safe local_109 passes through unchanged', () {
    const String uid = 'local_109';
    expect(CaleeUidSanitizer.isSafeForRemotePut(uid), isTrue);
    expect(CaleeUidSanitizer.normalizeForRemotePut(uid), uid);
  });

  test('overlong UID returns generated fallback', () {
    final String normalized = CaleeUidSanitizer.normalizeForRemotePut('A' * 191);
    expect(normalized, isNotEmpty);
    expect(normalized.length, lessThanOrEqualTo(190));
    expect(
      normalized,
      matches(RegExp(r'^[A-F0-9]{8}-[A-F0-9]{4}-[A-F0-9]{4}-[A-F0-9]{4}-[A-F0-9]{12}$')),
    );
  });

  test('UID containing newline returns generated fallback', () {
    final String normalized = CaleeUidSanitizer.normalizeForRemotePut('bad\nuid');
    expect(normalized, isNotEmpty);
    expect(normalized.length, lessThanOrEqualTo(190));
    expect(
      normalized,
      matches(RegExp(r'^[A-F0-9]{8}-[A-F0-9]{4}-[A-F0-9]{4}-[A-F0-9]{4}-[A-F0-9]{12}$')),
    );
  });

  test('UID containing UID: contamination returns generated fallback', () {
    final String normalized = CaleeUidSanitizer.normalizeForRemotePut('UID:abc');
    expect(normalized, isNotEmpty);
    expect(normalized.length, lessThanOrEqualTo(190));
    expect(
      normalized,
      matches(RegExp(r'^[A-F0-9]{8}-[A-F0-9]{4}-[A-F0-9]{4}-[A-F0-9]{4}-[A-F0-9]{12}$')),
    );
  });

  test('UID containing semicolon returns generated fallback', () {
    final String normalized = CaleeUidSanitizer.normalizeForRemotePut('abc;def');
    expect(normalized, isNotEmpty);
    expect(normalized.length, lessThanOrEqualTo(190));
    expect(
      normalized,
      matches(RegExp(r'^[A-F0-9]{8}-[A-F0-9]{4}-[A-F0-9]{4}-[A-F0-9]{4}-[A-F0-9]{12}$')),
    );
  });

  test('UID containing colon returns generated fallback', () {
    final String normalized = CaleeUidSanitizer.normalizeForRemotePut('abc:def');
    expect(normalized, isNotEmpty);
    expect(normalized.length, lessThanOrEqualTo(190));
    expect(
      normalized,
      matches(RegExp(r'^[A-F0-9]{8}-[A-F0-9]{4}-[A-F0-9]{4}-[A-F0-9]{4}-[A-F0-9]{12}$')),
    );
  });

  test('empty UID returns generated fallback', () {
    final String normalized = CaleeUidSanitizer.normalizeForRemotePut('');
    expect(normalized, isNotEmpty);
    expect(normalized.length, lessThanOrEqualTo(190));
    expect(
      normalized,
      matches(RegExp(r'^[A-F0-9]{8}-[A-F0-9]{4}-[A-F0-9]{4}-[A-F0-9]{4}-[A-F0-9]{12}$')),
    );
  });
}
