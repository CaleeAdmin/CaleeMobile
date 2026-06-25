import 'package:flutter/foundation.dart';

import '../../data/models/calendar_service_error.dart';
import '../../data/models/client_calendar.dart';
import '../../data/models/client_task.dart';
import 'tasks_repository.dart';

String _formatTaskDate(DateTime value) {
  final year = value.year.toString().padLeft(4, '0');
  final month = value.month.toString().padLeft(2, '0');
  final day = value.day.toString().padLeft(2, '0');
  return '$year-$month-$day';
}

class TasksController extends ChangeNotifier {
  TasksController({required this.repository});

  final TasksRepository repository;

  bool isLoading = false;
  Object? error;
  TasksOverview? overview;
  List<CalendarServiceError> calendarServiceErrors = [];
  bool isCreatingTask = false;
  final Set<String> updatingTaskIds = {};
  final Set<String> deletingTaskIds = {};
  final Set<String> editingTaskIds = {};
  ClientCalendar? selectedCalendar;
  bool completedExpanded = false;
  String searchQuery = '';

  Future<void> load() async {
    isLoading = true;
    error = null;
    notifyListeners();

    try {
      final today = DateTime.now();
      final from = _formatTaskDate(DateTime(today.year - 2, 1, 1));
      final to = _formatTaskDate(DateTime(today.year + 2, 12, 31));
      overview = await repository.loadOverview(from: from, to: to);
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

  Future<void> refresh() => load();

  void setSearchQuery(String query) {
    searchQuery = query;
    notifyListeners();
  }

  void setSelectedCalendar(ClientCalendar? calendar) {
    selectedCalendar = calendar;
    completedExpanded = false;
    notifyListeners();
  }

  void setCompletedExpanded(bool value) {
    completedExpanded = value;
    notifyListeners();
  }

  Future<void> createTask({
    required ClientCalendar taskCalendar,
    required String title,
    String? dueAt,
    String? description,
  }) async {
    isCreatingTask = true;
    notifyListeners();

    try {
      await repository.createTask(
        taskCalendar: taskCalendar,
        title: title,
        dueAt: dueAt,
        description: description,
      );
      await load();
    } finally {
      isCreatingTask = false;
      notifyListeners();
    }
  }

  Future<void> updateTask({
    required ClientTask task,
    required String title,
    String? dueAt,
    String? description,
  }) async {
    editingTaskIds.add(task.id);
    notifyListeners();

    try {
      await repository.updateTask(
        task: task,
        title: title,
        dueAt: dueAt,
        description: description,
      );
      await load();
    } finally {
      editingTaskIds.remove(task.id);
      notifyListeners();
    }
  }

  Future<void> toggleTaskStatus(ClientTask task) async {
    if (updatingTaskIds.contains(task.id)) return;

    updatingTaskIds.add(task.id);
    notifyListeners();

    try {
      await repository.setTaskCompleted(
        task: task,
        completed: !task.isCompleted,
      );
      await load();
    } finally {
      updatingTaskIds.remove(task.id);
      notifyListeners();
    }
  }

  Future<void> deleteTask(ClientTask task) async {
    if (deletingTaskIds.contains(task.id)) return;

    deletingTaskIds.add(task.id);
    notifyListeners();

    try {
      await repository.deleteTask(task);
      await load();
    } finally {
      deletingTaskIds.remove(task.id);
      notifyListeners();
    }
  }
}
