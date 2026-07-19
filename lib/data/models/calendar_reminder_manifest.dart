/// A single calendar-reminder notification this app has scheduled on the
/// device, together with a privacy-safe fingerprint of the schedule that
/// produced it and a privacy-safe key identifying the account that owns it.
///
/// The [fingerprint] is a deterministic, non-reversible digest of every input
/// that affects the scheduled notification (trigger instant, rendered body
/// inputs, payload identity fields, event start). It lets reconciliation detect
/// that a notification whose numeric [notificationId] is unchanged nevertheless
/// needs to be re-scheduled because its *content* changed — e.g. a title-only
/// edit. A `null` fingerprint means the ID is owned but its schedule digest is
/// unknown (a legacy manifest entry), so it must be re-scheduled once while it
/// is still desired.
///
/// The [ownerKey] is a deterministic, non-reversible digest of the account that
/// scheduled the notification (never the raw account ID). A `null` owner means
/// the entry predates account-aware ownership (a legacy v1/v2 entry) and so must
/// not be assumed to belong to the current account.
class CalendarReminderManifestEntry {
  const CalendarReminderManifestEntry({
    required this.notificationId,
    required this.fingerprint,
    this.ownerKey,
  });

  /// The device notification ID this app owns.
  final int notificationId;

  /// Deterministic, privacy-safe digest of the schedule that produced the
  /// notification, or `null` when unknown (legacy/recovered entry).
  final String? fingerprint;

  /// Deterministic, privacy-safe digest of the owning account, or `null` when
  /// unknown (legacy entry, or an untrusted future-schema value).
  final String? ownerKey;

  /// Largest notification ID we accept — the non-negative signed 31-bit range,
  /// matching the IDs produced by `notificationIdForEvent`.
  static const int maxNotificationId = 0x7FFFFFFF;

  /// Upper bound on a persisted digest string, so a malformed manifest cannot
  /// force us to hold an unbounded value in memory.
  static const int _maxDigestLength = 128;

  /// Returns a copy with the given fields replaced. Pass [clearFingerprint] or
  /// [clearOwnerKey] to explicitly reset a nullable field to `null`, since a
  /// plain `fingerprint: null` argument is indistinguishable from "leave
  /// unchanged" with named parameters.
  CalendarReminderManifestEntry copyWith({
    int? notificationId,
    String? fingerprint,
    bool clearFingerprint = false,
    String? ownerKey,
    bool clearOwnerKey = false,
  }) => CalendarReminderManifestEntry(
    notificationId: notificationId ?? this.notificationId,
    fingerprint: clearFingerprint ? null : (fingerprint ?? this.fingerprint),
    ownerKey: clearOwnerKey ? null : (ownerKey ?? this.ownerKey),
  );

  Map<String, dynamic> toJson() => {
    'id': notificationId,
    if (fingerprint != null) 'fp': fingerprint,
    if (ownerKey != null) 'owner': ownerKey,
  };

  /// Parses a single entry map, returning `null` if it has no usable, in-range
  /// integer ID (so a malformed entry never invents a bogus ownership record).
  ///
  /// [trustFingerprint]/[trustOwner] gate whether the persisted digest values
  /// are retained: an unknown future schema recovers IDs but must not trust its
  /// fingerprints or (unless explicitly known compatible) its owner keys.
  static CalendarReminderManifestEntry? tryFromJson(
    Map<dynamic, dynamic> json, {
    bool trustFingerprint = true,
    bool trustOwner = true,
  }) {
    final id = _asValidId(json['id']);
    if (id == null) return null;
    return CalendarReminderManifestEntry(
      notificationId: id,
      fingerprint: trustFingerprint ? _asBoundedString(json['fp']) : null,
      ownerKey: trustOwner ? _asBoundedString(json['owner']) : null,
    );
  }

  /// Validates a raw JSON value as a non-negative 31-bit notification ID.
  /// Rejects non-numbers, non-integers, negatives, and out-of-range values so a
  /// malformed field can never become a bogus (or platform-invalid) ID.
  static int? _asValidId(Object? raw) {
    final int value;
    if (raw is int) {
      value = raw;
    } else if (raw is double && raw.isFinite && raw == raw.truncateToDouble()) {
      value = raw.toInt();
    } else {
      return null;
    }
    if (value < 0 || value > maxNotificationId) return null;
    return value;
  }

  /// Returns [raw] as a bounded non-empty string, or `null` for anything else.
  static String? _asBoundedString(Object? raw) {
    if (raw is! String) return null;
    if (raw.isEmpty || raw.length > _maxDigestLength) return null;
    return raw;
  }

  @override
  bool operator ==(Object other) =>
      other is CalendarReminderManifestEntry &&
      other.notificationId == notificationId &&
      other.fingerprint == fingerprint &&
      other.ownerKey == ownerKey;

  @override
  int get hashCode => Object.hash(notificationId, fingerprint, ownerKey);

  @override
  String toString() =>
      'CalendarReminderManifestEntry(id: $notificationId, '
      'fp: ${fingerprint == null ? 'null' : 'set'}, '
      'owner: ${ownerKey == null ? 'null' : 'set'})';
}

/// How a persisted calendar reminder manifest was loaded/parsed.
enum CalendarReminderManifestLoadStatus {
  /// A valid current-schema manifest was parsed cleanly.
  loaded,

  /// Legacy or partially-malformed but recoverable data: valid ownership IDs
  /// were preserved, and any untrusted fingerprints/owner keys were dropped.
  recovered,

  /// No stored value was present: an empty, valid manifest.
  absent,

  /// The stored value was unparseable, or an unrecoverable top-level shape.
  /// Ownership is unknown, so the stored value must NOT be overwritten and no
  /// notifications may be scheduled or cancelled off it.
  corrupt,
}

/// Structured, log-safe result of loading the calendar reminder manifest.
///
/// Carries the parsed [manifest] plus the [status] describing how it was
/// obtained, so reconciliation can behave conservatively on [corrupt] data
/// instead of silently treating it as an empty manifest.
class CalendarReminderManifestLoadResult {
  const CalendarReminderManifestLoadResult({
    required this.manifest,
    required this.status,
  });

  final CalendarReminderManifest manifest;
  final CalendarReminderManifestLoadStatus status;

  bool get isCorrupt => status == CalendarReminderManifestLoadStatus.corrupt;

  @override
  String toString() =>
      'CalendarReminderManifestLoadResult(status: ${status.name}, '
      'ids: ${manifest.scheduledIds.length})';
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
///   fingerprints or owners. Read for backward compatibility and migrated on
///   the next successful reconciliation.
/// * **v2 (legacy):** `{ "version": 2, "entries": [{ "id": int, "fp": str? }] }`
///   — versioned entries carrying a schedule fingerprint but no owner.
/// * **v3 (legacy):**
///   `{ "version": 3, "entries": [{ "id": int, "fp": str?, "owner": str? }] }`
///   — entries carried a privacy-safe owner key, but derived with a
///   non-cryptographic FNV hash. On load the legacy owners are dropped (never
///   interpreted as v4 keys) and the entries are re-owned by the current account.
/// * **v4 (current):**
///   `{ "version": 4, "entries": [{ "id": int, "fp": str?, "owner": "v4:<hex>"? }] }`
///   — owner keys are cryptographic (`v4:` + SHA-256; see `reminderOwnerKey`).
///   The `v4:` tag is explicit algorithm/version metadata, so the scheme is never
///   inferred from string length; a present-but-not-v4 owner is dropped as a
///   recovery rather than trusted.
///
/// Reads are deliberately conservative: legacy manifests are migrated (never
/// treated as empty), an unknown/newer manifest recovers any parseable IDs
/// (dropping untrusted fingerprints and owner keys) rather than orphaning
/// notifications a future build owned, and genuinely unparseable data is
/// reported as [CalendarReminderManifestLoadStatus.corrupt] rather than
/// collapsing to [empty] — so ownership is never silently discarded.
class CalendarReminderManifest {
  const CalendarReminderManifest({
    required this.version,
    required this.entries,
    this.lastReconciledAt,
  });

  /// Current manifest schema version: entries carry fingerprints and v4
  /// (cryptographic, `v4:`-tagged SHA-256) owner keys.
  static const int currentVersion = 4;

  /// The v3 schema version: entries carried legacy FNV owner keys, which are NOT
  /// v4 cryptographic owner keys. Still read for migration, but its owner keys
  /// are dropped on load (never interpreted as v4) so the entries are re-owned by
  /// the current account through a normal reconciliation.
  static const int legacyOwnerVersion = 3;

  /// The v2 schema version (fingerprinted entries, no owner), still read for
  /// migration.
  static const int legacyFingerprintVersion = 2;

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

  /// Builds a manifest from bare IDs (fingerprints and owners unknown). Handy
  /// for seeding and for representing a freshly migrated legacy manifest.
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

  /// Parses a decoded JSON value into a structured [load result].
  ///
  /// [decoded] is the value returned by `jsonDecode` (or `null` when nothing was
  /// stored). Never throws: malformed fields are rejected individually and a
  /// genuinely unrecoverable value is reported as
  /// [CalendarReminderManifestLoadStatus.corrupt].
  static CalendarReminderManifestLoadResult parse(Object? decoded) {
    if (decoded == null) {
      return const CalendarReminderManifestLoadResult(
        manifest: empty,
        status: CalendarReminderManifestLoadStatus.absent,
      );
    }
    if (decoded is! Map) {
      // A non-object top-level value cannot carry ownership.
      return const CalendarReminderManifestLoadResult(
        manifest: empty,
        status: CalendarReminderManifestLoadStatus.corrupt,
      );
    }

    final version = _asInt(decoded['version']);
    final lastReconciledAt = _parseDate(decoded['lastReconciledAt']);
    final entriesRaw = decoded['entries'];
    final idsRaw = decoded['ids'];
    final hasShape = entriesRaw is List || idsRaw is List;

    // Current schema: entries carry trusted fingerprints and owner keys, and are
    // held to a stricter standard than a legacy migration (Priority 4). A
    // corrupt or ownership-ambiguous current-schema value must NEVER collapse to
    // a trusted empty manifest that would then be overwritten as if no reminders
    // were owned.
    if (version == currentVersion) {
      if (entriesRaw is! List) {
        // Our own writer always emits an `entries` list (even when empty), so a
        // current-version value without one is malformed, not a valid empty
        // manifest — do not overwrite it.
        return const CalendarReminderManifestLoadResult(
          manifest: empty,
          status: CalendarReminderManifestLoadStatus.corrupt,
        );
      }
      final (parsed, parseDegraded) = _parseEntriesConservative(
        entriesRaw,
        trustFingerprint: true,
        trustOwner: true,
      );
      // A non-empty entries list that yields zero usable entries means real
      // ownership data was present but unreadable — corrupt, never a valid empty
      // manifest (Priority 4: non-empty list, zero valid entries -> corrupt).
      if (entriesRaw.isNotEmpty && parsed.isEmpty) {
        return const CalendarReminderManifestLoadResult(
          manifest: empty,
          status: CalendarReminderManifestLoadStatus.corrupt,
        );
      }
      final (deduped, hadConflict, hadDuplicate) = _dedupeConflictAware(parsed);
      // Duplicate IDs with conflicting fingerprints/owners are ambiguous
      // ownership — corrupt, never silently first-entry-wins (Priority 4).
      if (hadConflict) {
        return const CalendarReminderManifestLoadResult(
          manifest: empty,
          status: CalendarReminderManifestLoadStatus.corrupt,
        );
      }
      // Any dropped entry/field, or a collapsed (non-conflicting) duplicate, is
      // a partial recovery — report `recovered`, never a silent `loaded` that
      // would hide that ownership data was lost/repaired (Priority 4: a mixture
      // of valid and malformed entries is not reported as fully loaded).
      final degraded = parseDegraded || hadDuplicate;
      return CalendarReminderManifestLoadResult(
        manifest: CalendarReminderManifest(
          version: currentVersion,
          entries: deduped,
          lastReconciledAt: lastReconciledAt,
        ),
        status: degraded
            ? CalendarReminderManifestLoadStatus.recovered
            : CalendarReminderManifestLoadStatus.loaded,
      );
    }

    // Legacy v3: entries carried FNV owner keys, which are NOT v4 cryptographic
    // owner keys. Trust the (unchanged-format) fingerprints, but DROP the legacy
    // owners so they can never be interpreted as current-scheme owners — the
    // entries are re-owned by the current account on the next reconciliation (a
    // controlled migration, never a silent reinterpretation).
    if (version == legacyOwnerVersion) {
      final entries = _dedupe(
        _parseEntries(entriesRaw, trustFingerprint: true, trustOwner: false),
      );
      return _recoveredOr(entries, lastReconciledAt, hadShape: hasShape);
    }

    // Legacy v2: fingerprints are trusted; owners are absent (null).
    if (version == legacyFingerprintVersion) {
      final entries = _dedupe(
        _parseEntries(entriesRaw, trustFingerprint: true, trustOwner: false),
      );
      return _recoveredOr(entries, lastReconciledAt, hadShape: hasShape);
    }

    // Legacy v1 ID-only schema.
    if (version == legacyIdOnlyVersion) {
      final entries = _dedupe(_parseLegacyIds(idsRaw));
      return _recoveredOr(entries, lastReconciledAt, hadShape: hasShape);
    }

    // Unknown/newer version, or a version we could not parse to an integer.
    // Recover any IDs we can, but never trust future-schema fingerprints, and
    // treat owner keys conservatively (drop them) so an entry from an unknown
    // future account is not assumed to belong to the current one.
    final recovered = _dedupe(<CalendarReminderManifestEntry>[
      if (entriesRaw is List)
        ..._parseEntries(
          entriesRaw,
          trustFingerprint: false,
          trustOwner: false,
        ),
      ..._parseLegacyIds(idsRaw),
    ]);
    return _recoveredOr(recovered, lastReconciledAt, hadShape: hasShape);
  }

  /// Backwards-compatible convenience: parses a JSON map and returns just the
  /// manifest (discarding the load status). Prefer [parse] where the status
  /// matters (e.g. conservative handling of corrupt data).
  factory CalendarReminderManifest.fromJson(Map<String, dynamic> json) =>
      parse(json).manifest;

  /// Wraps recovered [entries] as [recovered], unless the value had no
  /// list-shaped ownership fields at all — in which case it is unrecoverable
  /// ([corrupt]) rather than a normal empty manifest, so we never overwrite a
  /// value whose real ownership we could not read.
  static CalendarReminderManifestLoadResult _recoveredOr(
    List<CalendarReminderManifestEntry> entries,
    DateTime? lastReconciledAt, {
    required bool hadShape,
  }) {
    if (!hadShape) {
      return const CalendarReminderManifestLoadResult(
        manifest: empty,
        status: CalendarReminderManifestLoadStatus.corrupt,
      );
    }
    return CalendarReminderManifestLoadResult(
      manifest: CalendarReminderManifest(
        version: currentVersion,
        entries: entries,
        lastReconciledAt: lastReconciledAt,
      ),
      status: CalendarReminderManifestLoadStatus.recovered,
    );
  }

  static List<CalendarReminderManifestEntry> _parseEntries(
    Object? raw, {
    required bool trustFingerprint,
    required bool trustOwner,
  }) {
    if (raw is! List) return const <CalendarReminderManifestEntry>[];
    final result = <CalendarReminderManifestEntry>[];
    for (final item in raw) {
      if (item is Map) {
        final entry = CalendarReminderManifestEntry.tryFromJson(
          item,
          trustFingerprint: trustFingerprint,
          trustOwner: trustOwner,
        );
        if (entry != null) result.add(entry);
      }
    }
    return result;
  }

  /// Parses current-schema entries, tracking whether anything had to be dropped
  /// — a non-map item, an item with no usable ID, or a present-but-invalid
  /// fingerprint/owner field. Returns the recovered entries and that flag so the
  /// caller can distinguish a clean [loaded] from a partial [recovered]
  /// (Priority 4: a mix of valid and malformed entries is never reported as
  /// fully loaded).
  static (List<CalendarReminderManifestEntry>, bool) _parseEntriesConservative(
    List<dynamic> raw, {
    required bool trustFingerprint,
    required bool trustOwner,
  }) {
    final result = <CalendarReminderManifestEntry>[];
    var degraded = false;
    for (final item in raw) {
      if (item is! Map) {
        degraded = true;
        continue;
      }
      final entry = CalendarReminderManifestEntry.tryFromJson(
        item,
        trustFingerprint: trustFingerprint,
        trustOwner: trustOwner,
      );
      if (entry == null) {
        degraded = true;
        continue;
      }
      var kept = entry;
      // Owner-key encoding/algorithm validation (Priority 4 case 6): a
      // current-schema owner must be a well-formed v4 token. A present-but-invalid
      // owner (wrong algorithm/version, corrupt encoding) is dropped as a
      // recovery — never trusted as a current-scheme owner, and never silently
      // kept as a bogus value.
      if (kept.ownerKey != null && !_isValidCurrentOwnerKey(kept.ownerKey!)) {
        kept = kept.copyWith(clearOwnerKey: true);
        degraded = true;
      }
      // A present-but-unusable fingerprint/owner (e.g. oversized/malformed) was
      // dropped to null by tryFromJson. That is a recovery, not a clean load —
      // and, crucially, an oversized/malformed digest must not SILENTLY become a
      // trusted null value (Priority 4): the `recovered` status is the signal.
      if (_fieldDropped(item['fp'], entry.fingerprint) ||
          _fieldDropped(item['owner'], entry.ownerKey)) {
        degraded = true;
      }
      result.add(kept);
    }
    return (result, degraded);
  }

  /// True when a raw field was present (non-null) but did not survive parsing
  /// (became null) — i.e. it was malformed/oversized and dropped.
  static bool _fieldDropped(Object? raw, String? parsed) =>
      raw != null && parsed == null;

  /// Matches a well-formed current-scheme (v4) owner key: the `v4:` algorithm/
  /// version tag, then a 64-char lowercase-hex SHA-256 digest. Kept in sync with
  /// `reminderOwnerKey` in calendar_notification_candidates.dart (validated by
  /// algorithm/version, not by length alone). Defined here to keep the data-model
  /// layer free of a dependency on the features layer.
  static final RegExp _currentOwnerKeyPattern = RegExp(r'^v4:[0-9a-f]{64}$');

  /// Whether [value] is a well-formed current-scheme (v4) owner key.
  static bool _isValidCurrentOwnerKey(String value) =>
      _currentOwnerKeyPattern.hasMatch(value);

  /// Deduplicates by notification ID for the current schema, distinguishing a
  /// genuine ownership conflict from a harmless exact duplicate. Returns
  /// (entries, hadConflict, hadDuplicate): a conflict is a repeated ID whose
  /// fingerprint OR owner differs (ambiguous ownership -> the caller treats the
  /// whole manifest as corrupt, never first-entry-wins); an exact duplicate
  /// (identical fingerprint AND owner) is collapsed and flagged so the load is
  /// reported as [recovered].
  static (List<CalendarReminderManifestEntry>, bool, bool) _dedupeConflictAware(
    List<CalendarReminderManifestEntry> entries,
  ) {
    final byId = <int, CalendarReminderManifestEntry>{};
    final result = <CalendarReminderManifestEntry>[];
    var hadConflict = false;
    var hadDuplicate = false;
    for (final entry in entries) {
      final existing = byId[entry.notificationId];
      if (existing == null) {
        byId[entry.notificationId] = entry;
        result.add(entry);
        continue;
      }
      hadDuplicate = true;
      if (existing.fingerprint != entry.fingerprint ||
          existing.ownerKey != entry.ownerKey) {
        hadConflict = true;
      }
    }
    return (result, hadConflict, hadDuplicate);
  }

  static List<CalendarReminderManifestEntry> _parseLegacyIds(Object? raw) {
    if (raw is! List) return const <CalendarReminderManifestEntry>[];
    final result = <CalendarReminderManifestEntry>[];
    for (final id in raw) {
      final valid = CalendarReminderManifestEntry._asValidId(id);
      if (valid != null) {
        result.add(
          CalendarReminderManifestEntry(
            notificationId: valid,
            fingerprint: null,
          ),
        );
      }
    }
    return result;
  }

  /// Deduplicates entries by notification ID, keeping the first occurrence.
  static List<CalendarReminderManifestEntry> _dedupe(
    List<CalendarReminderManifestEntry> entries,
  ) {
    final seen = <int>{};
    final result = <CalendarReminderManifestEntry>[];
    for (final entry in entries) {
      if (seen.add(entry.notificationId)) result.add(entry);
    }
    return result;
  }

  static int? _asInt(Object? raw) {
    if (raw is int) return raw;
    if (raw is double && raw.isFinite && raw == raw.truncateToDouble()) {
      return raw.toInt();
    }
    if (raw is String) return int.tryParse(raw);
    return null;
  }

  static DateTime? _parseDate(Object? raw) =>
      raw is String ? DateTime.tryParse(raw) : null;
}
