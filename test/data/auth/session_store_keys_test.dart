import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  group('SessionStore token keys', () {
    test('stores only Hub access and refresh token keys', () {
      final source = File('lib/data/auth/session_store.dart').readAsStringSync();

      expect(source, contains("'calee_hub_access_token'"));
      expect(source, contains("'calee_hub_refresh_token'"));
      expect(source, isNot(contains('caldav')));
      expect(source, isNot(contains('appPassword')));
      expect(source, isNot(contains("'password'")));
    });
  });
}
