import 'package:flutter/foundation.dart';

import '../../data/models/client_chore.dart';

/// Identity of one chore occurrence, scoped tightly enough that no two
/// occurrences can share a key.
///
/// Two services can hold chores with the same UID, one service can hold the
/// same chore in two calendars, and one recurring chore has many dates — so a
/// key built from the chore id alone collides. Account and household are
/// included so switching either cannot let a pending mutation from the previous
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

  /// Returns null when the chore has no stable completion action id — the same
  /// condition under which it cannot be completed or undone at all.
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

/// Outcome of merging the overlay into a list response.
@immutable
class ChoreSyncReconciliation {
  const ChoreSyncReconciliation({required this.chores, this.warning});

  /// Rows to render: the backend's rows, plus any accepted mutation the
  /// backend has temporarily omitted.
  final List<ClientChore> chores;

  /// Set when an accepted mutation did not hold — the backend contradicted it,
  /// or never reported it within the window. Shown to the user as a controlled
  /// sync warning rather than leaving a wrong row on screen.
  final String? warning;
}

/// Holds chore mutations the backend has already accepted, only until a list
/// response says something about the occurrence.
///
/// The backend is authoritative. This overlay exists for exactly one job:
/// bridging a list response that has not yet caught up with a mutation it
/// already accepted. It never invents a row — it replays the row the mutation
/// endpoint itself returned — and it never argues with the backend.
class ChoreSyncOverlay {
  ChoreSyncOverlay({this.omissionWindow = const Duration(seconds: 90)});

  /// How long an accepted mutation may be rendered while the list omits it.
  /// Long enough for CalDAV eventual consistency, short enough that a lost
  /// mutation surfaces as a warning instead of a permanently wrong row.
  final Duration omissionWindow;

  final Map<ChoreOccurrenceKey, _Pending> _pending = {};

  int get pendingCount => _pending.length;

  /// Records a completion the backend accepted. [chore] must be the backend's
  /// own representation of the completed occurrence.
  void markCompletionPending({
    required ChoreOccurrenceKey key,
    required ClientChore chore,
    required DateTime now,
  }) => _pending[key] = _Pending(completing: true, chore: chore, at: now);

  /// Records an undo the backend accepted. [chore] must be the backend's own
  /// representation of the reactivated occurrence.
  void markUndoPending({
    required ChoreOccurrenceKey key,
    required ClientChore chore,
    required DateTime now,
  }) => _pending[key] = _Pending(completing: false, chore: chore, at: now);

  void remove(ChoreOccurrenceKey key) => _pending.remove(key);

  /// Drops everything. Called on logout and when the controller is disposed.
  void clear() => _pending.clear();

  /// Drops entries that no longer belong to the current context.
  ///
  /// The `*Authoritative` flags separate the data from its trustworthiness. An
  /// empty *authoritative* set means "there are none left", so every entry
  /// scoped to one is dropped — that is how removing the last chore service or
  /// calendar clears pending state. An empty *non*-authoritative set means the
  /// caller could not enumerate them this pass (a failed request), which is not
  /// evidence of deletion and must not be treated as such.
  ///
  /// Account and household are always authoritative: the controller knows both
  /// without a network call.
  void retainScope({
    required String accountId,
    required String householdId,
    required Set<String> serviceIds,
    required bool servicesAuthoritative,
    required Set<String> calendarIds,
    required bool calendarsAuthoritative,
  }) {
    _pending.removeWhere((key, _) {
      if (key.accountId != accountId.trim()) return true;
      if (key.householdId != householdId.trim()) return true;
      if (servicesAuthoritative &&
          key.serviceId.isNotEmpty &&
          !serviceIds.contains(key.serviceId)) {
        return true;
      }
      if (calendarsAuthoritative &&
          key.calendarId.isNotEmpty &&
          !calendarIds.contains(key.calendarId)) {
        return true;
      }
      return false;
    });
  }

  /// Merges the overlay into a freshly loaded list.
  ///
  /// If the backend reported the occurrence at all, the overlay entry is
  /// dropped and the backend row is used verbatim — including when the backend
  /// reports the opposite of what the mutation asked for. A completion that did
  /// not stick is the user's real state and must be shown immediately, not
  /// papered over until a timer expires.
  ///
  /// The bounded window applies only to the one case the overlay exists for:
  /// the backend omitting the occurrence entirely.
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

    final extras = <ClientChore>[];
    var contradicted = false;
    var expired = false;

    for (final entry in _pending.entries.toList()) {
      final key = entry.key;
      final mutation = entry.value;
      final backendRow = byKey[key];

      // The backend has an opinion. It always wins, immediately.
      if (backendRow != null) {
        _pending.remove(key);
        if (backendRow.isCompleted != mutation.completing) contradicted = true;
        continue;
      }

      // Outside the loaded range, so this response says nothing either way.
      // Holding the entry would keep it alive forever.
      if (!_isWithinRange(key.occurrenceDate, fromDate, toDate)) {
        _pending.remove(key);
        continue;
      }

      if (now.difference(mutation.at) > omissionWindow) {
        _pending.remove(key);
        expired = true;
        continue;
      }

      // Omitted but still inside the window: replay the accepted row.
      extras.add(mutation.chore);
    }

    return ChoreSyncReconciliation(
      chores: [...chores, ...extras],
      warning: contradicted
          ? 'A chore change did not stick. Showing the latest state from the server.'
          : expired
          ? 'A chore update could not be confirmed. Refresh to see the latest state.'
          : null,
    );
  }

  static bool _isWithinRange(String date, String fromDate, String toDate) {
    if (date.isEmpty) return true;
    if (fromDate.isNotEmpty && date.compareTo(fromDate) < 0) return false;
    if (toDate.isNotEmpty && date.compareTo(toDate) > 0) return false;
    return true;
  }
}

/// A mutation the backend accepted but has not yet reflected in a list.
@immutable
class _Pending {
  const _Pending({
    required this.completing,
    required this.chore,
    required this.at,
  });

  /// True for a completion, false for an undo. The backend row's own
  /// [ClientChore.isCompleted] is compared against this to detect a
  /// contradiction.
  final bool completing;

  /// The authoritative row the mutation endpoint returned.
  final ClientChore chore;

  final DateTime at;
}
