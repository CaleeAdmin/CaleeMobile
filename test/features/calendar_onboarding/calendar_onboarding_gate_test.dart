import 'package:calee_mobile/features/calendar_onboarding/calendar_onboarding_status.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('shouldShowCalendarOnboarding', () {
    test('not_started + no pending deep link → show onboarding', () {
      expect(
        shouldShowCalendarOnboarding(
          status: CalendarOnboardingStatus.notStarted,
          hasPendingCalendarFollowIntent: false,
        ),
        isTrue,
      );
    });

    test('remind_later + no pending deep link → show onboarding', () {
      expect(
        shouldShowCalendarOnboarding(
          status: CalendarOnboardingStatus.remindLater,
          hasPendingCalendarFollowIntent: false,
        ),
        isTrue,
      );
    });

    test('dismissed_forever + no pending deep link → normal app', () {
      expect(
        shouldShowCalendarOnboarding(
          status: CalendarOnboardingStatus.dismissedForever,
          hasPendingCalendarFollowIntent: false,
        ),
        isFalse,
      );
    });

    test('not_started + pending calendar-follow link → skip onboarding', () {
      expect(
        shouldShowCalendarOnboarding(
          status: CalendarOnboardingStatus.notStarted,
          hasPendingCalendarFollowIntent: true,
        ),
        isFalse,
      );
    });

    test('remind_later + pending calendar-follow link → skip onboarding', () {
      expect(
        shouldShowCalendarOnboarding(
          status: CalendarOnboardingStatus.remindLater,
          hasPendingCalendarFollowIntent: true,
        ),
        isFalse,
      );
    });

    test('dismissed_forever + pending deep link → skip onboarding', () {
      expect(
        shouldShowCalendarOnboarding(
          status: CalendarOnboardingStatus.dismissedForever,
          hasPendingCalendarFollowIntent: true,
        ),
        isFalse,
      );
    });
  });
}
