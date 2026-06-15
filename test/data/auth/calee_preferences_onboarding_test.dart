// Tests for CaleePreferences calendar onboarding status storage.
// Uses SharedPreferences mock to avoid platform-channel hangs.

import 'package:calee_mobile/data/auth/calee_preferences.dart';
import 'package:calee_mobile/features/calendar_onboarding/calendar_onboarding_status.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({
      'calee_pref_migrated_to_shared_prefs': true,
    });

    // Stub secure storage in case the migration path is hit.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          (call) async => <String, String>{},
        );
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          null,
        );
  });

  group('loadCalendarOnboardingStatus', () {
    test('defaults to not_started when no value stored', () async {
      final prefs = CaleePreferences();
      final status = await prefs.loadCalendarOnboardingStatus('account1');
      expect(status, CalendarOnboardingStatus.notStarted);
    });

    test('returns stored remind_later', () async {
      SharedPreferences.setMockInitialValues({
        'calee_pref_migrated_to_shared_prefs': true,
        'calee_calendar_onboarding_status_account1':
            CalendarOnboardingStatus.remindLater,
      });
      final prefs = CaleePreferences();
      final status = await prefs.loadCalendarOnboardingStatus('account1');
      expect(status, CalendarOnboardingStatus.remindLater);
    });

    test('returns stored dismissed_forever', () async {
      SharedPreferences.setMockInitialValues({
        'calee_pref_migrated_to_shared_prefs': true,
        'calee_calendar_onboarding_status_account1':
            CalendarOnboardingStatus.dismissedForever,
      });
      final prefs = CaleePreferences();
      final status = await prefs.loadCalendarOnboardingStatus('account1');
      expect(status, CalendarOnboardingStatus.dismissedForever);
    });

    test('status is account-scoped (different accounts are independent)', () async {
      SharedPreferences.setMockInitialValues({
        'calee_pref_migrated_to_shared_prefs': true,
        'calee_calendar_onboarding_status_account1':
            CalendarOnboardingStatus.dismissedForever,
      });
      final prefs = CaleePreferences();
      final status = await prefs.loadCalendarOnboardingStatus('account2');
      expect(status, CalendarOnboardingStatus.notStarted);
    });
  });

  group('saveCalendarOnboardingStatus', () {
    test('saves remind_later and can be loaded back', () async {
      final prefs = CaleePreferences();
      await prefs.saveCalendarOnboardingStatus(
        'account1',
        CalendarOnboardingStatus.remindLater,
      );
      final status = await prefs.loadCalendarOnboardingStatus('account1');
      expect(status, CalendarOnboardingStatus.remindLater);
    });

    test('saves dismissed_forever and can be loaded back', () async {
      final prefs = CaleePreferences();
      await prefs.saveCalendarOnboardingStatus(
        'account1',
        CalendarOnboardingStatus.dismissedForever,
      );
      final status = await prefs.loadCalendarOnboardingStatus('account1');
      expect(status, CalendarOnboardingStatus.dismissedForever);
    });

    test('saves are account-scoped', () async {
      final prefs = CaleePreferences();
      await prefs.saveCalendarOnboardingStatus(
        'account1',
        CalendarOnboardingStatus.dismissedForever,
      );
      await prefs.saveCalendarOnboardingStatus(
        'account2',
        CalendarOnboardingStatus.remindLater,
      );
      expect(
        await prefs.loadCalendarOnboardingStatus('account1'),
        CalendarOnboardingStatus.dismissedForever,
      );
      expect(
        await prefs.loadCalendarOnboardingStatus('account2'),
        CalendarOnboardingStatus.remindLater,
      );
    });
  });
}
