import 'package:flutter/foundation.dart';

import '../../data/api/calee_hub_client.dart';
import '../../data/models/calendar_service_error.dart';
import '../../data/models/client_calendar.dart';
import '../../data/models/client_chore.dart';
import '../../data/models/client_chore_metadata.dart';
import '../../data/models/client_person.dart';
import 'chore_grouping.dart';
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
  ChoresController({required this.repository});

  final ChoresRepository repository;

  bool isLoading = false;
  Object? error;
  ChoresOverview? overview;
  List<CalendarServiceError> calendarServiceErrors = [];
  final Set<String> updatingChoreIds = {};
  // Some calendar services accept a completion but omit its occurrence from
  // the immediate list response. Keep the accepted occurrence visible so the
  // user can see and undo the action until the service reports it normally.
  final Map<String, ClientChore> _completedOverrides = {};
  String selectedAssigneeFilter = 'all';

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
      var chores = dedupeChoreOccurrences(loaded.choreList.chores);
      for (final entry in _completedOverrides.entries) {
        final present = chores.any(
          (chore) => _occurrenceKey(chore) == entry.key && chore.completedToday,
        );
        if (!present) chores = [...chores, entry.value];
      }
      overview = ChoresOverview(
        calendarList: loaded.calendarList,
        choreList: ClientChoreList(
          from: loaded.choreList.from,
          to: loaded.choreList.to,
          chores: chores,
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

  String _occurrenceKey(ClientChore chore) =>
      '${chore.completionActionId}:${chore.effectiveOccurrenceDate ?? ''}';

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
    if (choreId.trim().isEmpty || updatingChoreIds.contains(choreId)) return;

    updatingChoreIds.add(choreId);
    notifyListeners();

    try {
      if (chore.completedToday || chore.normalizedSection == 'doneToday') {
        await repository.undoCompletion(chore);
        _completedOverrides.remove(_occurrenceKey(chore));
      } else {
        if (_isFutureOccurrence(chore.effectiveOccurrenceDate)) {
          throw const CaleeHubException(
            statusCode: 0,
            message: 'Future chores cannot be completed yet.',
            code: 'FUTURE_COMPLETION_NOT_ALLOWED',
          );
        }
        await repository.completeChore(chore);
        _completedOverrides[_occurrenceKey(chore)] = chore.copyWith(
          completedToday: true,
          section: 'doneToday',
        );
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
