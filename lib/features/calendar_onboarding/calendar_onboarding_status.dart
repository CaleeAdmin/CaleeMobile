abstract final class CalendarOnboardingStatus {
  static const notStarted = 'not_started';
  static const remindLater = 'remind_later';
  static const dismissedForever = 'dismissed_forever';
}

bool shouldShowCalendarOnboarding({
  required String status,
  required bool hasPendingCalendarFollowIntent,
}) {
  if (hasPendingCalendarFollowIntent) return false;
  return status == CalendarOnboardingStatus.notStarted ||
      status == CalendarOnboardingStatus.remindLater;
}
