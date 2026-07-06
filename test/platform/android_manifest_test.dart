// Guards the Android app-link / deep-link intent filters in
// AndroidManifest.xml against accidental regressions, since there's no
// automated Android instrumentation test coverage for manifest contents.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  late String manifest;

  setUpAll(() {
    manifest = File(
      'android/app/src/main/AndroidManifest.xml',
    ).readAsStringSync();
  });

  test('has the HTTPS app-link intent filter for /mobile/shopping', () {
    expect(
      RegExp(
        r'<intent-filter android:autoVerify="true">\s*'
        r'<action android:name="android\.intent\.action\.VIEW" />\s*'
        r'<category android:name="android\.intent\.category\.DEFAULT" />\s*'
        r'<category android:name="android\.intent\.category\.BROWSABLE" />\s*'
        r'<data\s*'
        r'android:scheme="https"\s*'
        r'android:host="hub\.calee\.com\.au"\s*'
        r'android:pathPrefix="/mobile/shopping" />\s*'
        r'</intent-filter>',
      ).hasMatch(manifest),
      isTrue,
      reason: 'Missing autoVerify HTTPS intent-filter for /mobile/shopping',
    );
  });

  test('still has the calee://shopping custom-scheme intent filter', () {
    expect(
      RegExp(
        r'<data\s*android:scheme="calee"\s*android:host="shopping" />',
      ).hasMatch(manifest),
      isTrue,
    );
  });

  test('still has the calembed.calee.com.au/follow intent filter', () {
    expect(
      RegExp(
        r'android:host="calembed\.calee\.com\.au"\s*'
        r'android:pathPrefix="/follow"',
      ).hasMatch(manifest),
      isTrue,
    );
  });

  test('still has the hub.calee.com.au/native-login intent filter', () {
    expect(
      RegExp(
        r'android:host="hub\.calee\.com\.au"\s*'
        r'android:pathPrefix="/native-login"',
      ).hasMatch(manifest),
      isTrue,
    );
  });

  test('still has the calee://native-login intent filter', () {
    expect(
      RegExp(
        r'android:scheme="calee"\s*android:host="native-login"',
      ).hasMatch(manifest),
      isTrue,
    );
  });

  test('still has the calee://external-calendar-connected intent filter', () {
    expect(
      RegExp(
        r'android:scheme="calee"\s*'
        r'android:host="external-calendar-connected"',
      ).hasMatch(manifest),
      isTrue,
    );
  });
}
