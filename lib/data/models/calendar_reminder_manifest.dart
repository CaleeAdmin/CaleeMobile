/// A record of the calendar reminder notifications this app has scheduled on
/// the device.
///
/// The manifest lets calendar reminder reconciliation cancel only the
/// notification IDs it owns, instead of a global `cancelAll()` that would also
/// clear notifications belonging to other Calee features. It is persisted under
/// a namespaced [CaleePreferences] key.
class CalendarReminderManifest {
  const CalendarReminderManifest({
    required this.version,
    required this.scheduledIds,
    this.lastReconciledAt,
  });

  /// Current manifest schema version. Bump only if the stored shape changes;
  /// unknown/older versions are treated as empty on read (a safe reset that
  /// never cancels notifications the app no longer recognises as its own).
  static const int currentVersion = 1;

  static const CalendarReminderManifest empty = CalendarReminderManifest(
    version: currentVersion,
    scheduledIds: <int>[],
  );

  final int version;

  /// Notification IDs believed to be currently scheduled on the device for
  /// calendar reminders.
  final List<int> scheduledIds;

  /// When reconciliation last completed successfully. Purely observational.
  final DateTime? lastReconciledAt;

  Map<String, dynamic> toJson() => {
    'version': version,
    'ids': scheduledIds,
    if (lastReconciledAt != null)
      'lastReconciledAt': lastReconciledAt!.toIso8601String(),
  };

  factory CalendarReminderManifest.fromJson(Map<String, dynamic> json) {
    final version = json['version'] as int? ?? 0;
    if (version != currentVersion) return empty;

    final rawIds = json['ids'];
    final ids = rawIds is List
        ? rawIds.whereType<int>().toList()
        : const <int>[];

    final rawReconciled = json['lastReconciledAt'];
    final lastReconciledAt = rawReconciled is String
        ? DateTime.tryParse(rawReconciled)
        : null;

    return CalendarReminderManifest(
      version: currentVersion,
      scheduledIds: ids,
      lastReconciledAt: lastReconciledAt,
    );
  }
}
