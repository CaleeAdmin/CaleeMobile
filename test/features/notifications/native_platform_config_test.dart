// Static regression checks for the native notification platform configuration.
//
// These read the actual repository files so a future edit that drops a required
// Android receiver/permission, the dedicated notification icon, or the iOS
// notification-centre delegate fails `flutter test` (in addition to the
// standalone Python CI guard). Run from the repository root.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _read(String path) {
  final file = File(path);
  expect(file.existsSync(), isTrue, reason: 'expected file at $path');
  return file.readAsStringSync();
}

/// Extracts the substring of the `<receiver … android:name="[name]" …>` element
/// (opening tag through its matching close, or the self-closing tag).
String _receiverBlock(String manifest, String name) {
  final start = manifest.indexOf('android:name="$name"');
  expect(start, greaterThanOrEqualTo(0), reason: 'receiver $name not found');
  // Walk back to the enclosing `<receiver` and forward to the element end.
  final open = manifest.lastIndexOf('<receiver', start);
  expect(open, greaterThanOrEqualTo(0));
  // End of the opening `<receiver …>` tag.
  final openTagEnd = manifest.indexOf('>', start);
  expect(openTagEnd, greaterThanOrEqualTo(0));
  // Self-closing opening tag (`… />`) → the element is just the opening tag.
  // Otherwise it is a block element closed by `</receiver>`.
  if (manifest[openTagEnd - 1] == '/') {
    return manifest.substring(open, openTagEnd + 1);
  }
  final blockClose = manifest.indexOf('</receiver>', openTagEnd);
  expect(blockClose, greaterThanOrEqualTo(0));
  return manifest.substring(open, blockClose + '</receiver>'.length);
}

void main() {
  group('Android manifest notification config', () {
    late String manifest;

    setUpAll(() {
      manifest = _read('android/app/src/main/AndroidManifest.xml');
    });

    test('declares POST_NOTIFICATIONS and RECEIVE_BOOT_COMPLETED', () {
      expect(
        manifest,
        contains(
          '<uses-permission android:name="android.permission.POST_NOTIFICATIONS" />',
        ),
      );
      expect(
        manifest,
        contains(
          '<uses-permission android:name="android.permission.RECEIVE_BOOT_COMPLETED" />',
        ),
      );
    });

    test('ScheduledNotificationReceiver present and not exported', () {
      final block = _receiverBlock(
        manifest,
        'com.dexterous.flutterlocalnotifications.ScheduledNotificationReceiver',
      );
      expect(block, contains('android:exported="false"'));
    });

    test('boot receiver: not exported, with reboot/package actions', () {
      final block = _receiverBlock(
        manifest,
        'com.dexterous.flutterlocalnotifications.ScheduledNotificationBootReceiver',
      );
      expect(block, contains('android:exported="false"'));
      expect(
        block,
        contains('android:name="android.intent.action.BOOT_COMPLETED"'),
      );
      expect(
        block,
        contains('android:name="android.intent.action.MY_PACKAGE_REPLACED"'),
      );
      expect(
        block,
        contains('android:name="android.intent.action.QUICKBOOT_POWERON"'),
      );
    });
  });

  group('Android notification icon + shrinking config', () {
    test('dedicated status-bar drawable exists', () {
      expect(
        File(
          'android/app/src/main/res/drawable/ic_stat_calee.xml',
        ).existsSync(),
        isTrue,
      );
    });

    test('resource keep file retains the drawable', () {
      final keep = _read('android/app/src/main/res/raw/keep.xml');
      expect(keep, contains('@drawable/ic_stat_calee'));
    });

    test('release ProGuard config exists and is wired into gradle', () {
      final proguard = _read('android/app/proguard-rules.pro');
      expect(proguard, contains('-keepattributes Signature'));
      expect(proguard, contains('com.google.gson'));

      final gradle = _read('android/app/build.gradle.kts');
      expect(gradle, contains('proguard-rules.pro'));
      expect(gradle, contains('isMinifyEnabled = true'));
    });

    test('the Dart service references the dedicated icon', () {
      final dart = _read(
        'lib/features/notifications/local_calendar_notification_service.dart',
      );
      expect(dart, contains('ic_stat_calee'));
    });
  });

  group('iOS AppDelegate notification config', () {
    late String swift;

    setUpAll(() {
      swift = _read('ios/Runner/AppDelegate.swift');
    });

    test('imports UserNotifications', () {
      expect(swift, contains('import UserNotifications'));
    });

    test('assigns the notification-centre delegate at launch', () {
      final launchStart = swift.indexOf('didFinishLaunchingWithOptions');
      expect(launchStart, greaterThanOrEqualTo(0));
      final launchBody = swift.substring(launchStart);
      expect(
        launchBody,
        contains('UNUserNotificationCenter.current().delegate'),
      );
    });

    test('preserves the implicit-engine registration', () {
      expect(swift, contains('didInitializeImplicitFlutterEngine'));
      expect(swift, contains('GeneratedPluginRegistrant.register'));
    });
  });
}
