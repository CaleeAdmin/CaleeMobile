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
  static const String safeFirstSync = 'safe_first_sync';
  static const String exchangeReadOnly = 'exchange_read_only';

  static const Set<String> deterministicReasons = {
    ok,
    bindingInvalid,
    localCalendarMissing,
    remoteCollectionMissing,
    authInvalid,
    environmentBlocked,
    subscriptionReadonlyViolation,
    repairRequired,
    safeFirstSync,
    exchangeReadOnly,
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
      case safeFirstSync:
        return 'First sync after reconnect is running in safe mode. Deletes are temporarily blocked.';
      case exchangeReadOnly:
        return 'Exchange-safe mode: this event is mirrored from remote and local edits will not push back.';
      default:
        if (reason == null || reason.isEmpty) return null;
        return 'Sync paused (${reason.replaceAll('_', ' ')}).';
    }
  }
}
