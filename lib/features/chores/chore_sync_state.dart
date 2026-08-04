import 'package:flutter/foundation.dart';

import '../../data/models/client_chore.dart';

/// Where one chore occurrence sits in the completion lifecycle.
///
/// Only [completionPending] and [undoPending] are ever held locally: they
/// describe a mutation the backend has already accepted but has not yet
/// reflected in a list response. Everything else is whatever the backend last
/// reported, so a stale local opinion can never outlive the server's.
enum ChoreSyncStatus {
  /// The occurrence is outstanding — the backend reports it in a todo section.
  active,

  /// A completion request succeeded; the backend has not yet listed the
  /// resulting completed occurrence.
  completionPending,

  /// The backend listed the occurrence as completed. Nothing is held locally.
  completedConfirmed,

  /// An undo request succeeded; the backend has not yet dropped the completed
  /// occurrence from its list response.
  undoPending,

  /// A pending mutation outlived its reconciliation window without the backend
  /// ever confirming it. The overlay is dropped and the user is told.
  reconciliationFailed,
}

/// Identity of a single chore occurrence, scoped tightly enough that no two
/// occurrences can share a key.
///
/// Two different services can legitimately hold chores with the same UID, and
/// one service can hold the same chore in two calendars, so a key built from
/// the chore id alone collides. Account and household are included as well:
/// switching either must not let a pending completion from the previous
/// context reappear against the new one.
@immutable
class ChoreOccurrenceKey {
  const ChoreOccurrenceKey({
    required this.accountId,
    required this.householdId,
    required this.serviceId,
    required this.calendarId,
    required this.completionActionId,
    required this.occurrenceDate,
  });

  /// Builds the key for [chore] within the given account/household scope.
  ///
  /// Returns null when the chore has no stable completion action id, which is
  /// the same condition under which it cannot be completed or undone at all.
  static ChoreOccurrenceKey? forChore(
    ClientChore chore, {
    required String accountId,
    required String householdId,
  }) {
    final actionId = chore.completionActionId.trim();
    if (actionId.isEmpty) return null;

    return ChoreOccurrenceKey(
      accountId: accountId.trim(),
      householdId: householdId.trim(),
      serviceId: chore.serviceId.trim(),
      calendarId: chore.calendarId.trim(),
      completionActionId: actionId,
      occurrenceDate: chore.effectiveOccurrenceDate?.trim() ?? '',
    );
  }

  final String accountId;
  final String householdId;
  final String serviceId;
  final String calendarId;
  final String completionActionId;
  final String occurrenceDate;

  String get value =>
      '$accountId|$householdId|$serviceId|$calendarId|$completionActionId|$occurrenceDate';

  @override
  bool operator ==(Object other) =>
      other is ChoreOccurrenceKey && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => 'ChoreOccurrenceKey($value)';
}

/// A mutation the backend accepted, held only until a list response confirms it.
@immutable
class PendingChoreMutation {
  const PendingChoreMutation({
    required this.key,
    required this.status,
    required this.chore,
    required this.acceptedAt,
  });

  final ChoreOccurrenceKey key;
  final ChoreSyncStatus status;

  /// The authoritative row the backend returned for this mutation. Rendered
  /// as-is while the mutation is pending, so the overlay never invents state.
  final ClientChore chore;

  final DateTime acceptedAt;

  bool hasExpired(DateTime now, Duration window) =>
      now.difference(acceptedAt) > window;
}

/// Outcome of reconciling the local overlay against a list response.
@immutable
class ChoreSyncReconciliation {
  const ChoreSyncReconciliation({
    required this.chores,
    required this.expiredKeys,
  });

  /// The chore rows to render: the backend's rows, plus any still-pending
  /// completion the backend has temporarily omitted, minus any completed row
  /// whose undo the backend has not caught up with yet.
  final List<ClientChore> chores;

  /// Mutations dropped this pass because they outlived the reconciliation
  /// window. Non-empty means the user should be told the sync did not settle.
  final List<ChoreOccurrenceKey> expiredKeys;

  bool get hasSyncFailure => expiredKeys.isNotEmpty;
}

/// Holds accepted-but-unconfirmed chore mutations and reconciles them against
/// each list response.
///
/// The overlay is deliberately hard to keep: every entry is removed as soon as
/// the backend says anything at all about that occurrence — completed or not —
/// and any entry the backend stays silent about is dropped once it outlives
/// [reconciliationWindow]. An entry can therefore never resurrect a row the
/// backend has moved on from, which is what makes this safe to render.
class ChoreSyncOverlay {
  ChoreSyncOverlay({this.reconciliationWindow = const Duration(seconds: 90)});

  /// How long an accepted mutation may be rendered without backend
  /// confirmation. Long enough to cover eventual-consistency lag on a CalDAV
  /// round trip, short enough that a genuinely lost mutation surfaces as an
  /// error instead of a permanently wrong row.
  final Duration reconciliationWindow;

  final Map<ChoreOccurrenceKey, PendingChoreMutation> _pending = {};

  @visibleForTesting
  Map<ChoreOccurrenceKey, PendingChoreMutation> get pending =>
      Map.unmodifiable(_pending);

  int get pendingCount => _pending.length;

  ChoreSyncStatus statusFor(ChoreOccurrenceKey key) =>
      _pending[key]?.status ?? ChoreSyncStatus.active;

  /// Records a completion the backend has already accepted. [chore] must be
  /// the backend's own representation of the completed occurrence.
  void markCompletionPending({
    required ChoreOccurrenceKey key,
    required ClientChore chore,
    required DateTime now,
  }) {
    _pending[key] = PendingChoreMutation(
      key: key,
      status: ChoreSyncStatus.completionPending,
      chore: chore,
      acceptedAt: now,
    );
  }

  /// Records an undo the backend has already accepted, so a list response that
  /// still carries the completed row does not flash it back into Done today.
  void markUndoPending({
    required ChoreOccurrenceKey key,
    required ClientChore chore,
    required DateTime now,
  }) {
    _pending[key] = PendingChoreMutation(
      key: key,
      status: ChoreSyncStatus.undoPending,
      chore: chore,
      acceptedAt: now,
    );
  }

  void remove(ChoreOccurrenceKey key) => _pending.remove(key);

  /// Drops every pending mutation. Called on logout and whenever the
  /// controller/repository context is replaced.
  void clear() => _pending.clear();

  /// Drops mutations that no longer belong to the current context: a different
  /// account or household, or a service/calendar that has since been removed.
  ///
  /// An empty [serviceIds] or [calendarIds] disables that particular check: it
  /// means the caller could not enumerate them this pass (a failed calendars
  /// request), which is not the same as everything having been deleted.
  void retainScope({
    required String accountId,
    required String householdId,
    required Set<String> serviceIds,
    required Set<String> calendarIds,
  }) {
    _pending.removeWhere((key, _) {
      if (key.accountId != accountId.trim()) return true;
      if (key.householdId != householdId.trim()) return true;
      if (serviceIds.isNotEmpty &&
          key.serviceId.isNotEmpty &&
          !serviceIds.contains(key.serviceId)) {
        return true;
      }
      if (calendarIds.isNotEmpty &&
          key.calendarId.isNotEmpty &&
          !calendarIds.contains(key.calendarId)) {
        return true;
      }
      return false;
    });
  }

  /// Merges the overlay into a freshly loaded list.
  ///
  /// Rules, in order:
  ///  1. The backend mentioned the occurrence at all — completed or not — so
  ///     the overlay entry is dropped and the backend row is used verbatim.
  ///  2. The backend omitted it and the entry is still inside the
  ///     reconciliation window, so a completion is rendered from the row the
  ///     backend returned when it accepted the mutation. (A pending undo has
  ///     nothing to render — the occurrence being absent is the state it was
  ///     waiting for.)
  ///  3. The entry outlived the window, so it is dropped and reported as a
  ///     sync failure rather than shown indefinitely.
  ///
  /// Occurrences outside [fromDate]..[toDate] are dropped too: the list did
  /// not cover them, so its silence says nothing about them and holding the
  /// entry would keep it alive forever.
  ChoreSyncReconciliation reconcile({
    required List<ClientChore> chores,
    required String accountId,
    required String householdId,
    required String fromDate,
    required String toDate,
    required DateTime now,
  }) {
    final byKey = <ChoreOccurrenceKey, ClientChore>{};
    for (final chore in chores) {
      final key = ChoreOccurrenceKey.forChore(
        chore,
        accountId: accountId,
        householdId: householdId,
      );
      if (key != null) byKey[key] = chore;
    }

    final expired = <ChoreOccurrenceKey>[];
    final suppressed = <ChoreOccurrenceKey>{};
    final extras = <ClientChore>[];

    for (final entry in _pending.entries.toList()) {
      final key = entry.key;
      final mutation = entry.value;

      // Rule 1 — the backend has an opinion about this occurrence. It wins,
      // whichever way it went.
      final backendRow = byKey[key];
      if (backendRow != null) {
        final settled = mutation.status == ChoreSyncStatus.completionPending
            ? backendRow.isCompleted
            : !backendRow.isCompleted;
        if (settled) {
          _pending.remove(key);
          continue;
        }

        // The backend still reports the pre-mutation state. Inside the window
        // that is lag, not disagreement: suppress the stale row and render the
        // one the backend itself returned when it accepted the mutation.
        if (!mutation.hasExpired(now, reconciliationWindow)) {
          suppressed.add(key);
          extras.add(mutation.chore);
          continue;
        }

        // Rule 3 — waited too long. Drop the overlay, let the backend row
        // stand, and report the failure.
        _pending.remove(key);
        expired.add(key);
        continue;
      }

      // The occurrence falls outside the window this response covered, so the
      // response says nothing about it either way. Holding the entry would
      // keep it alive forever, so drop it without calling it a failure.
      if (!_isWithinRange(key.occurrenceDate, fromDate, toDate)) {
        _pending.remove(key);
        continue;
      }

      // Rule 3 — waited too long.
      if (mutation.hasExpired(now, reconciliationWindow)) {
        _pending.remove(key);
        expired.add(key);
        continue;
      }

      // Rule 2 — the backend omitted the occurrence entirely but the mutation
      // is still inside its window, so render the accepted result rather than
      // letting the occurrence disappear.
      extras.add(mutation.chore);
    }

    final merged = <ClientChore>[];
    for (final chore in chores) {
      final key = ChoreOccurrenceKey.forChore(
        chore,
        accountId: accountId,
        householdId: householdId,
      );
      if (key != null && suppressed.contains(key)) continue;
      merged.add(chore);
    }
    merged.addAll(extras);

    return ChoreSyncReconciliation(chores: merged, expiredKeys: expired);
  }

  static bool _isWithinRange(String date, String fromDate, String toDate) {
    if (date.isEmpty) return true;
    if (fromDate.isNotEmpty && date.compareTo(fromDate) < 0) return false;
    if (toDate.isNotEmpty && date.compareTo(toDate) > 0) return false;
    return true;
  }
}
