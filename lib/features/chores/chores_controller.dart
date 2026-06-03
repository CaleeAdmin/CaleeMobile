import 'package:flutter/foundation.dart';

import '../../data/models/client_calendar.dart';
import '../../data/models/client_chore.dart';
import '../../data/models/client_chore_metadata.dart';
import '../../data/models/client_person.dart';
import 'chores_repository.dart';

String _formatChoreDate(DateTime value) {
  final year = value.year.toString().padLeft(4, '0');
  final month = value.month.toString().padLeft(2, '0');
  final day = value.day.toString().padLeft(2, '0');
  return '$year-$month-$day';
}

class ChoresController extends ChangeNotifier {
  ChoresController({required this.repository});

  final ChoresRepository repository;

  bool isLoading = false;
  Object? error;
  ChoresOverview? overview;
  final Set<String> updatingChoreIds = {};
  String selectedAssigneeFilter = 'all';

  Future<void> load() async {
    isLoading = true;
    error = null;
    notifyListeners();

    try {
      final today = DateTime.now();
      final from = _formatChoreDate(DateTime(today.year, 1, 1));
      final to = _formatChoreDate(DateTime(today.year, 12, 31));
      overview = await repository.loadOverview(from: from, to: to);
      error = null;
    } catch (e) {
      error = e;
    } finally {
      isLoading = false;
      notifyListeners();
    }
  }

  Future<void> refresh() => load();

  Future<void> createChore({
    required ClientCalendar calendar,
    required String title,
    String? scheduledAt,
    String? description,
    String? recurrence,
    required String? assigneePersonId,
    required int points,
  }) async {
    await repository.createChore(
      calendar: calendar,
      title: title,
      scheduledAt: scheduledAt,
      description: description,
      recurrence: recurrence,
      assigneePersonId: assigneePersonId,
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
      if (chore.completedToday || chore.section == 'doneToday') {
        await repository.undoCompletion(chore);
      } else {
        await repository.completeChore(chore);
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
      final scheduledDate = chore.scheduledDate;
      final date = scheduledDate != null && scheduledDate.trim().isNotEmpty
          ? scheduledDate.trim()
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
