class SyncGateReason {
  SyncGateReason._();

  static const String ok = 'ok';
  static const String bindingInvalid = 'binding_invalid';
  static const String localCalendarMissing = 'local_calendar_missing';
  static const String remoteCollectionMissing = 'remote_collection_missing';
  static const String authInvalid = 'auth_invalid';
  static const String environmentBlocked = 'environment_blocked';
  static const String subscriptionReadonlyViolation = 'subscription_readonly_violation';
  static const String repairRequired = 'repair_required';
  static const String relinkRequired = 'relink_required';
  static const String relinkVerifying = 'relink_verifying';
  static const String relinkMismatch = 'relink_mismatch';

  static const Set<String> deterministicReasons = {
    ok,
    bindingInvalid,
    localCalendarMissing,
    remoteCollectionMissing,
    authInvalid,
    environmentBlocked,
    subscriptionReadonlyViolation,
    repairRequired,
    relinkRequired,
    relinkVerifying,
    relinkMismatch,
  };

  static String? toUiMessage(String? reason) {
    switch (reason) {
      case localCalendarMissing:
        return 'Device calendar missing. Reconnect to resume.';
      case remoteCollectionMissing:
        return 'Remote collection missing. Reconnect to resume.';
      case bindingInvalid:
        return 'Calendar binding invalid. Reconnect to resume.';
      case authInvalid:
        return 'Authentication invalid. Sign in again to resume.';
      case environmentBlocked:
        return 'Sync blocked by device environment. Check settings and retry.';
      case subscriptionReadonlyViolation:
        return 'Subscription is read-only. Update sync mode to resume.';
      case repairRequired:
        return 'Reconnect required to repair calendar binding.';
      case relinkRequired:
        return 'Relink required before sync can continue.';
      case relinkVerifying:
        return 'Relink verification in progress.';
      case relinkMismatch:
        return 'Relink verification failed. Pick another calendar.';
      default:
        if (reason == null || reason.isEmpty) return null;
        return 'Sync paused (${reason.replaceAll('_', ' ')}).';
    }
  }
}
