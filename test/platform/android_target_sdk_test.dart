// Guards the Android 16 / API 36 target configuration.
//
// Google Play requires new app and update submissions to target API 36 from
// 31 August 2026. Targeting API 36 also *activates* platform behaviour changes
// that the app must already be compatible with, and two of them are expressed
// purely as manifest/resource configuration:
//
//  * Predictive back system animations are on by default for API 36 targets,
//    and `onBackPressed()`/`KEYCODE_BACK` are no longer dispatched. Flutter's
//    `FlutterActivity` only registers an `OnBackInvokedCallback` (which is what
//    makes `PopScope` work) when `android:enableOnBackInvokedCallback="true"`
//    is declared, so dropping that attribute would silently break in-app back
//    handling on Android 16.
//  * Edge-to-edge enforcement can no longer be opted out of:
//    `android:windowOptOutEdgeToEdgeEnforcement` is ignored for API 36 targets.
//    Adding it back would be a no-op that hides a real layout bug.
//
// There is no Android instrumentation coverage for Gradle/manifest contents, so
// these are asserted at the source level alongside
// test/platform/android_manifest_test.dart.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  late String gradle;
  late String manifest;
  late List<String> resourceFiles;

  setUpAll(() {
    gradle = File('android/app/build.gradle.kts').readAsStringSync();
    manifest = File(
      'android/app/src/main/AndroidManifest.xml',
    ).readAsStringSync();
    resourceFiles = Directory('android/app/src/main/res')
        .listSync(recursive: true)
        .whereType<File>()
        .where((file) => file.path.endsWith('.xml'))
        .map((file) => file.readAsStringSync())
        .toList(growable: false);
  });

  test('targetSdk is 36 (Android 16)', () {
    expect(
      RegExp(r'^\s*targetSdk\s*=\s*36\s*$', multiLine: true).hasMatch(gradle),
      isTrue,
      reason:
          'android/app/build.gradle.kts must declare targetSdk = 36 for the '
          'Google Play target-API requirement effective 31 August 2026',
    );
  });

  test('compileSdk is 36 and matches targetSdk', () {
    expect(
      RegExp(r'^\s*compileSdk\s*=\s*36\s*$', multiLine: true).hasMatch(gradle),
      isTrue,
      reason:
          'compileSdk must stay at 36 so the API 36 attributes used by the '
          'manifest (e.g. android:pageSizeCompat) still resolve',
    );
  });

  test('minSdk is still derived from the Flutter SDK', () {
    // Raising the API 36 target must not quietly raise the minimum supported
    // Android version and drop existing Calee users.
    expect(
      RegExp(
        r'^\s*minSdk\s*=\s*flutter\.minSdkVersion\s*$',
        multiLine: true,
      ).hasMatch(gradle),
      isTrue,
    );
  });

  test('MainActivity opts in to the back-invoked callback', () {
    expect(
      manifest.contains('android:enableOnBackInvokedCallback="true"'),
      isTrue,
      reason:
          'Required for PopScope/predictive back to keep working once the app '
          'targets API 36, where onBackPressed() is no longer called',
    );
  });

  test('no activity opts out of edge-to-edge enforcement', () {
    expect(
      manifest.contains('windowOptOutEdgeToEdgeEnforcement'),
      isFalse,
      reason: 'The opt-out is ignored for API 36 targets',
    );
    for (final resource in resourceFiles) {
      expect(
        resource.contains('windowOptOutEdgeToEdgeEnforcement'),
        isFalse,
        reason: 'The opt-out is ignored for API 36 targets',
      );
    }
  });

  test('no activity opts out of large-screen adaptive layouts', () {
    // API 36 ignores android:screenOrientation / android:resizeableActivity /
    // min-maxAspectRatio on displays >= sw600dp. The app declares none of them
    // today; adding one would be silently ineffective on tablets and foldables.
    expect(manifest.contains('android:screenOrientation'), isFalse);
    expect(manifest.contains('android:resizeableActivity'), isFalse);
    expect(
      manifest.contains('PROPERTY_COMPAT_ALLOW_RESTRICTED_RESIZABILITY'),
      isFalse,
      reason:
          'The temporary large-screen restriction opt-out is not needed and '
          'stops working at API 37',
    );
  });
}
