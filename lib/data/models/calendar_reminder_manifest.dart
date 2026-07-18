/// A single calendar-reminder notification this app has scheduled on the
/// device, together with a privacy-safe fingerprint of the schedule that
/// produced it.
///
/// The [fingerprint] is a deterministic, non-reversible digest of every input
/// that affects the scheduled notification (trigger instant, rendered body
/// inputs, payload identity fields, event start). It lets reconciliation detect
/// that a notification whose numeric [notificationId] is unchanged nevertheless
/// needs to be re-scheduled because its *content* changed — e.g. a title-only
/// edit. A `null` fingerprint means the ID is owned but its schedule digest is
/// unknown (a legacy manifest entry), so it must be re-scheduled once while it
/// is still desired.
class CalendarReminderManifestEntry {
  const CalendarReminderManifestEntry({
    required this.notificationId,
    required this.fingerprint,
  });

  /// The device notification ID this app owns.
  final int notificationId;

  /// Deterministic, privacy-safe digest of the schedule that produced the
  /// notification, or `null` when unknown (legacy/recovered entry).
  final String? fingerprint;

  CalendarReminderManifestEntry copyWith({String? fingerprint}) =>
      CalendarReminderManifestEntry(
        notificationId: notificationId,
        fingerprint: fingerprint ?? this.fingerprint,
      );

  Map<String, dynamic> toJson() => {
    'id': notificationId,
    if (fingerprint != null) 'fp': fingerprint,
  };

  /// Parses a single entry map, returning `null` if it has no usable integer
  /// ID (so a malformed entry never invents a bogus ownership record).
  static CalendarReminderManifestEntry? tryFromJson(
    Map<dynamic, dynamic> json,
  ) {
    final rawId = json['id'];
    final id = rawId is int ? rawId : (rawId is num ? rawId.toInt() : null);
    if (id == null) return null;
    final rawFp = json['fp'];
    return CalendarReminderManifestEntry(
      notificationId: id,
      fingerprint: rawFp is String ? rawFp : null,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is CalendarReminderManifestEntry &&
      other.notificationId == notificationId &&
      other.fingerprint == fingerprint;

  @override
  int get hashCode => Object.hash(notificationId, fingerprint);

  @override
  String toString() =>
      'CalendarReminderManifestEntry(id: $notificationId, '
      'fp: ${fingerprint == null ? 'null' : 'set'})';
}

/// A record of the calendar reminder notifications this app has scheduled on
/// the device.
///
/// The manifest lets calendar reminder reconciliation cancel only the
/// notification IDs it owns, instead of a global `cancelAll()` that would also
/// clear notifications belonging to other Calee features. It is persisted under
/// a namespaced [CaleePreferences] key.
///
/// ## Versions
/// * **v1 (legacy):** `{ "version": 1, "ids": [int, ...] }` — ID-only, no
///   fingerprints. Read for backward compatibility and migrated to v2 on the
///   next successful reconciliation.
/// * **v2 (current):** `{ "version": 2, "entries": [{ "id": int, "fp": str? }] }`
///   — versioned entries carrying a schedule fingerprint.
///
/// Reads are deliberately conservative: a legacy manifest is migrated (never
/// treated as empty), and an unknown/newer manifest recovers any parseable IDs
/// rather than orphaning notifications a future build owned. Only genuinely
/// unparseable data collapses to [empty].
class CalendarReminderManifest {
  const CalendarReminderManifest({
    required this.version,
    required this.entries,
    this.lastReconciledAt,
  });

  /// Current manifest schema version (versioned entries with fingerprints).
  static const int currentVersion = 2;

  /// The legacy ID-only schema version, still read for migration.
  static const int legacyIdOnlyVersion = 1;

  static const CalendarReminderManifest empty = CalendarReminderManifest(
    version: currentVersion,
    entries: <CalendarReminderManifestEntry>[],
  );

  final int version;

  /// Notification entries believed to be currently scheduled on the device for
  /// calendar reminders.
  final List<CalendarReminderManifestEntry> entries;

  /// When reconciliation last completed successfully. Purely observational.
  final DateTime? lastReconciledAt;

  /// All notification IDs this manifest owns, in entry order.
  List<int> get scheduledIds =>
      entries.map((e) => e.notificationId).toList(growable: false);

  bool get isEmpty => entries.isEmpty;

  /// Looks up an entry by notification ID, or `null` if not owned.
  CalendarReminderManifestEntry? entryFor(int notificationId) {
    for (final entry in entries) {
      if (entry.notificationId == notificationId) return entry;
    }
    return null;
  }

  /// Builds a v2 manifest from bare IDs (fingerprints unknown). Handy for
  /// seeding and for representing a freshly migrated legacy manifest.
  factory CalendarReminderManifest.fromIds(
    List<int> ids, {
    DateTime? lastReconciledAt,
  }) => CalendarReminderManifest(
    version: currentVersion,
    entries: [
      for (final id in ids)
        CalendarReminderManifestEntry(notificationId: id, fingerprint: null),
    ],
    lastReconciledAt: lastReconciledAt,
  );

  Map<String, dynamic> toJson() => {
    'version': currentVersion,
    'entries': [for (final e in entries) e.toJson()],
    if (lastReconciledAt != null)
      'lastReconciledAt': lastReconciledAt!.toIso8601String(),
  };

  factory CalendarReminderManifest.fromJson(Map<String, dynamic> json) {
    final version = json['version'] as int? ?? 0;
    final lastReconciledAt = _parseDate(json['lastReconciledAt']);

    // Current schema: versioned entries with fingerprints.
    if (version == currentVersion) {
      return CalendarReminderManifest(
        version: currentVersion,
        entries: _parseEntries(json['entries']),
        lastReconciledAt: lastReconciledAt,
      );
    }

    // Legacy v1 ID-only schema. Preserve ownership of every ID; fingerprints
    // are unknown, so each still-desired entry is re-scheduled once (to gain a
    // fingerprint) on the next reconciliation. Never treated as empty.
    if (version == legacyIdOnlyVersion) {
      return CalendarReminderManifest(
        version: currentVersion,
        entries: _parseLegacyIds(json['ids']),
        lastReconciledAt: lastReconciledAt,
      );
    }

    // Unknown/newer version. Fail conservatively: recover any IDs we can still
    // parse (from either schema) so we never orphan notifications a newer build
    // scheduled, but drop fingerprints we cannot trust.
    final recovered = <CalendarReminderManifestEntry>[
      ..._parseEntries(json['entries']).map((e) => e.copyWith()),
      ..._parseLegacyIds(json['ids']),
    ];
    final seen = <int>{};
    final deduped = <CalendarReminderManifestEntry>[];
    for (final entry in recovered) {
      if (seen.add(entry.notificationId)) deduped.add(entry);
    }
    return CalendarReminderManifest(
      version: currentVersion,
      entries: deduped,
      lastReconciledAt: lastReconciledAt,
    );
  }

  static List<CalendarReminderManifestEntry> _parseEntries(Object? raw) {
    if (raw is! List) return const <CalendarReminderManifestEntry>[];
    final result = <CalendarReminderManifestEntry>[];
    for (final item in raw) {
      if (item is Map) {
        final entry = CalendarReminderManifestEntry.tryFromJson(item);
        if (entry != null) result.add(entry);
      }
    }
    return result;
  }

  static List<CalendarReminderManifestEntry> _parseLegacyIds(Object? raw) {
    if (raw is! List) return const <CalendarReminderManifestEntry>[];
    return [
      for (final id in raw.whereType<int>())
        CalendarReminderManifestEntry(notificationId: id, fingerprint: null),
    ];
  }

  static DateTime? _parseDate(Object? raw) =>
      raw is String ? DateTime.tryParse(raw) : null;
}
