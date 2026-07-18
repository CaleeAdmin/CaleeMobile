/// A single calendar-reminder notification this app has scheduled on the
/// device, together with a privacy-safe fingerprint of the schedule that
/// produced it and a privacy-safe key identifying the account that owns it.
///
/// The [fingerprint] is a deterministic, one-way SHA-256 digest of every input
/// that affects the scheduled notification (trigger instant, rendered body
/// inputs, payload identity fields, event start). It lets reconciliation detect
/// that a notification whose numeric [notificationId] is unchanged nevertheless
/// needs to be re-scheduled because its *content* changed — e.g. a title-only
/// edit. A `null` fingerprint means the ID is owned but its schedule digest is
/// unknown (a legacy manifest entry, or a value that failed the SHA-256 format
/// check), so it must be re-scheduled once while it is still desired.
///
/// The [ownerKey] is a deterministic, one-way SHA-256 digest of the account that
/// scheduled the notification (never the raw account ID). A `null` owner means
/// the entry predates account-aware ownership (a legacy v1/v2 entry), used a
/// retired digest algorithm (v3 FNV), or carried a value that failed the SHA-256
/// format check — so it must not be assumed to belong to the current account.
class CalendarReminderManifestEntry {
  const CalendarReminderManifestEntry({
    required this.notificationId,
    required this.fingerprint,
    this.ownerKey,
  });

  /// The device notification ID this app owns.
  final int notificationId;

  /// Deterministic, privacy-safe digest of the schedule that produced the
  /// notification, or `null` when unknown (legacy/recovered/untrusted entry).
  final String? fingerprint;

  /// Deterministic, privacy-safe digest of the owning account, or `null` when
  /// unknown (legacy entry, or an untrusted/malformed value).
  final String? ownerKey;

  /// Largest notification ID we accept — the non-negative signed 31-bit range,
  /// matching the IDs produced by `notificationIdForEvent`.
  static const int maxNotificationId = 0x7FFFFFFF;

  /// Exact length of a trusted SHA-256 digest rendered as lowercase hexadecimal.
  static const int _sha256HexLength = 64;

  /// Upper bound on a persisted (legacy/untrusted) digest string, so a malformed
  /// manifest cannot force us to hold an unbounded value in memory.
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
  /// are retained at all: a legacy or unknown schema recovers IDs but must not
  /// trust its (retired-algorithm or foreign) fingerprints/owner keys.
  ///
  /// [requireHexDigest] additionally gates the *format*: for the current v4
  /// schema, a fingerprint/owner is trusted only when it is a lowercase-hex
  /// SHA-256 digest of the required length; anything else is dropped to `null`.
  static CalendarReminderManifestEntry? tryFromJson(
    Map<dynamic, dynamic> json, {
    bool trustFingerprint = true,
    bool trustOwner = true,
    bool requireHexDigest = false,
  }) {
    final id = _asValidId(json['id']);
    if (id == null) return null;
    return CalendarReminderManifestEntry(
      notificationId: id,
      fingerprint: trustFingerprint
          ? _asDigest(json['fp'], requireHex: requireHexDigest)
          : null,
      ownerKey: trustOwner
          ? _asDigest(json['owner'], requireHex: requireHexDigest)
          : null,
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

  /// Returns [raw] as a trusted digest string, or `null`. When [requireHex] is
  /// true (current schema) only a lowercase-hex SHA-256 digest of the exact
  /// required length is accepted; otherwise (legacy/untrusted contexts) any
  /// bounded non-empty string is accepted for retention as an opaque value.
  static String? _asDigest(Object? raw, {required bool requireHex}) {
    if (raw is! String) return null;
    if (requireHex) return _isSha256Hex(raw) ? raw : null;
    if (raw.isEmpty || raw.length > _maxDigestLength) return null;
    return raw;
  }

  /// Whether [value] is a lowercase-hexadecimal SHA-256 digest (64 chars).
  static bool _isSha256Hex(String value) {
    if (value.length != _sha256HexLength) return false;
    for (var i = 0; i < value.length; i++) {
      final c = value.codeUnitAt(i);
      final isDigit = c >= 0x30 && c <= 0x39; // 0-9
      final isLowerHex = c >= 0x61 && c <= 0x66; // a-f
      if (!isDigit && !isLowerHex) return false;
    }
    return true;
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
  /// A valid current-schema manifest was parsed cleanly (including a valid,
  /// empty entries list).
  loaded,

  /// Legacy or partially-malformed but recoverable data: valid ownership IDs
  /// were preserved, and any untrusted/duplicate fingerprints/owner keys were
  /// dropped or collapsed.
  recovered,

  /// No stored value was present: an empty, valid manifest.
  absent,

  /// The stored value was unparseable, an unrecoverable top-level shape, or a
  /// current-schema entries list whose every record was invalid. Ownership is
  /// unknown, so the stored value must NOT be overwritten and no notifications
  /// may be scheduled or cancelled off it.
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
///   fingerprints or owners.
/// * **v2 (legacy):** `{ "version": 2, "entries": [{ "id": int, "fp": str? }] }`
///   — FNV schedule fingerprints, no owner.
/// * **v3 (legacy):**
///   `{ "version": 3, "entries": [{ "id": int, "fp": str?, "owner": str? }] }`
///   — FNV fingerprints and FNV owner keys.
/// * **v4 (current):** same shape as v3, but fingerprints and owner keys are
///   one-way SHA-256 digests (lowercase hex, 64 chars). SHA-256 replaces the
///   retired FNV digests, so v2/v3 digests are treated as untrusted legacy
///   values on read.
///
/// Reads are deliberately conservative: legacy manifests (v1/v2/v3) are migrated
/// by retaining their IDs but dropping their untrusted fingerprints/owner keys
/// (never treated as empty); an unknown/newer manifest recovers any parseable
/// IDs the same way rather than orphaning notifications a future build owned;
/// and genuinely unrecoverable data — bad JSON, an unreadable top-level shape,
/// or a current-schema entries list whose every record is invalid — is reported
/// as [CalendarReminderManifestLoadStatus.corrupt] rather than collapsing to
/// [empty], so ownership is never silently discarded.
class CalendarReminderManifest {
  const CalendarReminderManifest({
    required this.version,
    required this.entries,
    this.lastReconciledAt,
  });

  /// Current manifest schema version: SHA-256 fingerprints and owner keys.
  static const int currentVersion = 4;

  /// The v3 schema version (FNV fingerprints and owner keys), read for migration
  /// but no longer trusted for its digest values.
  static const int legacyFnvOwnerVersion = 3;

  /// The v2 schema version (FNV fingerprints, no owner), read for migration.
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

    // Current schema (v4): strengthened validation. Trust SHA-256 fingerprints
    // and owner keys only when they match the required lowercase-hex format.
    if (version == currentVersion) {
      return _parseCurrent(entriesRaw, lastReconciledAt);
    }

    // Any non-current version — legacy v1/v2/v3 or an unknown/newer schema.
    // Retain any parseable IDs but never trust their fingerprints or owner keys:
    // v2/v3 digests use the retired FNV algorithm, and an unknown future schema
    // is not ours to trust. Legacy IDs are then cleaned and replaced with
    // current-account entries on the next reconciliation.
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

  /// Parses and classifies a current-schema (v4) manifest per the strengthened
  /// validation rules:
  /// * a missing/non-list `entries` field → [corrupt];
  /// * an empty list → [loaded] (valid empty manifest);
  /// * a non-empty list whose every record is invalid → [corrupt];
  /// * a list with some invalid records, or duplicate IDs → [recovered];
  /// * an otherwise-clean list → [loaded].
  static CalendarReminderManifestLoadResult _parseCurrent(
    Object? entriesRaw,
    DateTime? lastReconciledAt,
  ) {
    if (entriesRaw is! List) {
      // Our own writer always emits an `entries` list (even when empty), so a
      // current-version value without one is malformed, not a valid empty
      // manifest — do not overwrite it.
      return const CalendarReminderManifestLoadResult(
        manifest: empty,
        status: CalendarReminderManifestLoadStatus.corrupt,
      );
    }
    if (entriesRaw.isEmpty) {
      return CalendarReminderManifestLoadResult(
        manifest: CalendarReminderManifest(
          version: currentVersion,
          entries: const <CalendarReminderManifestEntry>[],
          lastReconciledAt: lastReconciledAt,
        ),
        status: CalendarReminderManifestLoadStatus.loaded,
      );
    }

    final parsed = _parseEntries(
      entriesRaw,
      trustFingerprint: true,
      trustOwner: true,
      requireHexDigest: true,
    );
    final deduped = _dedupe(parsed);

    if (deduped.isEmpty) {
      // A non-empty list none of whose records were usable is corrupt, not a
      // clean empty manifest — filtered malformed data must never look loaded.
      return const CalendarReminderManifestLoadResult(
        manifest: empty,
        status: CalendarReminderManifestLoadStatus.corrupt,
      );
    }

    // Some raw records had no valid ID (dropped), or duplicate IDs were
    // collapsed → the data was recovered, not cleanly loaded.
    final droppedInvalid = parsed.length < entriesRaw.length;
    final hadDuplicates = deduped.length < parsed.length;
    final status = (droppedInvalid || hadDuplicates)
        ? CalendarReminderManifestLoadStatus.recovered
        : CalendarReminderManifestLoadStatus.loaded;

    return CalendarReminderManifestLoadResult(
      manifest: CalendarReminderManifest(
        version: currentVersion,
        entries: deduped,
        lastReconciledAt: lastReconciledAt,
      ),
      status: status,
    );
  }

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
    bool requireHexDigest = false,
  }) {
    if (raw is! List) return const <CalendarReminderManifestEntry>[];
    final result = <CalendarReminderManifestEntry>[];
    for (final item in raw) {
      if (item is Map) {
        final entry = CalendarReminderManifestEntry.tryFromJson(
          item,
          trustFingerprint: trustFingerprint,
          trustOwner: trustOwner,
          requireHexDigest: requireHexDigest,
        );
        if (entry != null) result.add(entry);
      }
    }
    return result;
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
