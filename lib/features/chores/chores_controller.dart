import 'package:flutter/foundation.dart';

import '../../data/api/calee_hub_client.dart';
import '../../data/models/calendar_service_error.dart';
import '../../data/models/client_calendar.dart';
import '../../data/models/client_chore.dart';
import '../../data/models/client_chore_metadata.dart';
import '../../data/models/client_person.dart';
import 'chore_grouping.dart';
import 'chore_sync_state.dart';
import 'chores_repository.dart';

String _formatChoreDate(DateTime value) {
  final year = value.year.toString().padLeft(4, '0');
  final month = value.month.toString().padLeft(2, '0');
  final day = value.day.toString().padLeft(2, '0');
  return '$year-$month-$day';
}

/// True when [occurrenceDate] (`YYYY-MM-DD`) is strictly after local today.
bool _isFutureOccurrence(String? occurrenceDate) {
  if (occurrenceDate == null || occurrenceDate.trim().isEmpty) return false;
  final parsed = DateTime.tryParse(occurrenceDate.trim());
  if (parsed == null) return false;

  final today = DateTime.now();
  final todayDate = DateTime(today.year, today.month, today.day);
  final occurrence = DateTime(parsed.year, parsed.month, parsed.day);
  return occurrence.isAfter(todayDate);
}

class ChoresController extends ChangeNotifier {
  ChoresController({required this.repository, ChoreSyncOverlay? syncOverlay})
    : syncOverlay = syncOverlay ?? ChoreSyncOverlay();

  final ChoresRepository repository;

  /// Accepted-but-unconfirmed completions and undos. See [ChoreSyncOverlay] —
  /// entries live only until the backend reports the occurrence, and never
  /// beyond the reconciliation window.
  final ChoreSyncOverlay syncOverlay;

  bool isLoading = false;
  Object? error;
  ChoresOverview? overview;
  List<CalendarServiceError> calendarServiceErrors = [];
  final Set<String> updatingChoreIds = {};
  String selectedAssigneeFilter = 'all';

  /// Set when an accepted completion or undo outlived its reconciliation
  /// window. Surfaced to the user as a controlled sync error with a refresh
  /// action, rather than leaving a row on screen that the backend disowns.
  String? syncError;

  @override
  void dispose() {
    // The controller's context is being replaced: nothing accepted under it
    // may survive into whatever replaces it.
    syncOverlay.clear();
    super.dispose();
  }

  /// Drops all locally held sync state. Call on logout, or whenever the
  /// account/household context this controller was built for goes away.
  void clearSyncState() {
    syncOverlay.clear();
    syncError = null;
  }

  Future<void> load() async {
    isLoading = true;
    error = null;
    notifyListeners();

    try {
      final today = DateTime.now();
      final todayDate = DateTime(today.year, today.month, today.day);
      // The backend expands recurring chores into a per-date occurrence row
      // within the requested range, so a full-year window is no longer cheap.
      // 30 days back / 31 days forward matches Calee Android/tablet's window
      // and comfortably covers Today/Tomorrow/Later this week/Later.
      final from = _formatChoreDate(
        todayDate.subtract(const Duration(days: 30)),
      );
      final to = _formatChoreDate(todayDate.add(const Duration(days: 31)));
      final loaded = await repository.loadOverview(from: from, to: to);
      _logChoreDebugInfo(loaded);

      // Drop anything whose account, household, service or calendar has gone
      // away before reconciling what is left.
      syncOverlay.retainScope(
        accountId: repository.accountId,
        householdId: repository.householdId,
        serviceIds: repository.choreServiceIds,
        calendarIds: _knownCalendarIds(loaded),
      );

      final reconciled = syncOverlay.reconcile(
        chores: dedupeChoreOccurrences(loaded.choreList.chores),
        accountId: repository.accountId,
        householdId: repository.householdId,
        fromDate: from,
        toDate: to,
        now: DateTime.now(),
      );

      syncError = reconciled.hasSyncFailure
          ? 'A chore update could not be confirmed. Refresh to see the latest state.'
          : null;

      overview = ChoresOverview(
        calendarList: loaded.calendarList,
        choreList: ClientChoreList(
          from: loaded.choreList.from,
          to: loaded.choreList.to,
          chores: dedupeChoreOccurrences(reconciled.chores),
        ),
        people: loaded.people,
        from: loaded.from,
        to: loaded.to,
        calendarServiceErrors: loaded.calendarServiceErrors,
      );
      calendarServiceErrors = overview?.calendarServiceErrors ?? [];
      error = null;
    } catch (e) {
      error = e;
      calendarServiceErrors = [];
    } finally {
      isLoading = false;
      notifyListeners();
    }
  }

  /// Calendar ids a pending occurrence may legitimately reference, in both the
  /// raw and `serviceId:`-prefixed forms the two endpoints use.
  ///
  /// Returns an empty set when the calendar list itself failed to load: an
  /// empty set disables the calendar check rather than treating a transient
  /// calendars outage as "every calendar was deleted".
  Set<String> _knownCalendarIds(ChoresOverview loaded) {
    final ids = <String>{};

    for (final calendar in loaded.calendarList.calendars) {
      final id = calendar.id.trim();
      if (id.isEmpty) continue;
      ids.add(id);

      final prefix = '${calendar.serviceId}:';
      if (id.startsWith(prefix)) ids.add(id.substring(prefix.length));
    }

    return ids;
  }

  /// Logs chore counts right after the API response is parsed, before any
  /// client-side dedup/grouping runs, so a "Today" row-count mismatch between
  /// the backend and the rendered UI can be traced to a specific stage.
  void _logChoreDebugInfo(ChoresOverview loaded) {
    if (!kDebugMode) return;

    final chores = loaded.choreList.chores;
    final idCounts = <String, int>{};
    for (final chore in chores) {
      idCounts[chore.id] = (idCounts[chore.id] ?? 0) + 1;
    }
    final duplicateIds = [
      for (final entry in idCounts.entries)
        if (entry.value > 1) '${entry.key} x${entry.value}',
    ];

    final todayBeforeGrouping = chores
        .where((c) => c.normalizedSection == 'todoToday')
        .toList();
    final todayAfterGrouping =
        groupChoresBySection(chores, DateTime.now())['todoToday'] ??
        const <ClientChore>[];

    debugPrint(
      'ChoresController.load: totalChores=${chores.length} '
      'uniqueIds=${idCounts.length} duplicateIds=$duplicateIds '
      'todayBeforeGrouping=${todayBeforeGrouping.length} '
      'todayAfterGrouping=${todayAfterGrouping.length}',
    );
    for (final chore in todayBeforeGrouping) {
      debugPrint(
        'ChoresController.load: today row title="${chore.title}" '
        'baseChoreId=${chore.baseChoreId} choreUid=${chore.choreUid} '
        'occurrenceDate=${chore.effectiveOccurrenceDate} id=${chore.id}',
      );
    }
  }

  Future<void> refresh() => load();

  Future<void> createChore({
    required ClientCalendar calendar,
    required String title,
    String? scheduledAt,
    String? description,
    String? recurrence,
    required List<String> assigneePersonIds,
    required int points,
  }) async {
    await repository.createChore(
      calendar: calendar,
      title: title,
      scheduledAt: scheduledAt,
      description: description,
      recurrence: recurrence,
      assigneePersonIds: assigneePersonIds,
      points: points,
    );
    await load();
  }

  Future<void> updateChore({
    required ClientChore chore,
    required String title,
    String? scheduledAt,
    String? description,
    String? recurrence,
    required String? assigneePersonId,
    required int points,
    required String approvalState,
  }) async {
    await repository.updateChore(
      chore: chore,
      title: title,
      scheduledAt: scheduledAt,
      description: description,
      recurrence: recurrence,
      assigneePersonId: assigneePersonId,
      points: points,
      approvalState: approvalState,
    );
    await load();
  }

  Future<void> toggleChoreCompletion(ClientChore chore) async {
    final choreId = chore.completionActionId;
    // Guarding on the action id also blocks a second toggle of the *same*
    // occurrence while one is in flight, so a double tap cannot produce a
    // complete/undo race.
    if (choreId.trim().isEmpty || updatingChoreIds.contains(choreId)) return;

    updatingChoreIds.add(choreId);
    notifyListeners();

    try {
      final key = ChoreOccurrenceKey.forChore(
        chore,
        accountId: repository.accountId,
        householdId: repository.householdId,
      );

      if (chore.isCompleted) {
        // Pending state is only ever cleared after the undo succeeds; a failed
        // undo must leave the occurrence looking completed, which it does
        // because this rethrows before touching the overlay.
        final result = await repository.undoCompletion(chore);
        if (key != null) {
          final active = result.chore;
          if (active != null) {
            syncOverlay.markUndoPending(
              key: key,
              chore: active,
              now: DateTime.now(),
            );
          } else {
            syncOverlay.remove(key);
          }
        }
      } else {
        if (_isFutureOccurrence(chore.effectiveOccurrenceDate)) {
          throw const CaleeHubException(
            statusCode: 0,
            message: 'Future chores cannot be completed yet.',
            code: 'FUTURE_COMPLETION_NOT_ALLOWED',
          );
        }
        // Pending state is added only once the request has succeeded, so a
        // failed completion leaves the occurrence in its original active state.
        final result = await repository.completeChore(chore);
        if (key != null) {
          final completed = result.chore;
          if (completed != null) {
            syncOverlay.markCompletionPending(
              key: key,
              chore: completed,
              now: DateTime.now(),
            );
          }
        }
      }
      await load();
    } finally {
      updatingChoreIds.remove(choreId);
      notifyListeners();
    }
  }

  Future<void> skipRecurringChore(ClientChore chore) async {
    final choreId = chore.completionActionId;
    if (choreId.trim().isEmpty || updatingChoreIds.contains(choreId)) return;

    updatingChoreIds.add(choreId);
    notifyListeners();

    try {
      final occurrenceDate = chore.effectiveOccurrenceDate;
      final date = occurrenceDate != null && occurrenceDate.trim().isNotEmpty
          ? occurrenceDate.trim()
          : DateTime.now().toIso8601String().split('T').first;
      await repository.skipRecurringChore(chore, date: date);
      await load();
    } finally {
      updatingChoreIds.remove(choreId);
      notifyListeners();
    }
  }

  Future<void> stopRepeatingChore(ClientChore chore) async {
    final choreId = chore.completionActionId;
    if (choreId.trim().isEmpty || updatingChoreIds.contains(choreId)) return;

    updatingChoreIds.add(choreId);
    notifyListeners();

    try {
      await repository.stopRepeatingChore(chore);
      await load();
    } finally {
      updatingChoreIds.remove(choreId);
      notifyListeners();
    }
  }

  Future<void> permanentlyDeleteChore(ClientChore chore) async {
    final choreId = chore.completionActionId;
    if (choreId.trim().isEmpty || updatingChoreIds.contains(choreId)) return;

    updatingChoreIds.add(choreId);
    notifyListeners();

    try {
      await repository.permanentlyDeleteChore(chore);
      await load();
    } finally {
      updatingChoreIds.remove(choreId);
      notifyListeners();
    }
  }

  Future<ClientChoreMetadata?> fetchMetadata(ClientChore chore) =>
      repository.fetchMetadata(chore);

  Future<List<ClientPerson>> fetchPeople() => repository.fetchPeople();

  void setAssigneeFilter(String value) {
    selectedAssigneeFilter = value;
    notifyListeners();
  }
}
