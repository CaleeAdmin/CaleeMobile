import '../../data/api/calee_hub_client.dart';
import '../../data/models/client_bootstrap.dart';
import '../../data/models/client_calendar.dart';
import '../../data/models/client_chore.dart';
import '../../data/models/client_task.dart';
import 'today_models.dart';

String _formatDate(DateTime value) {
  final local = value.toLocal();
  final y = local.year.toString().padLeft(4, '0');
  final m = local.month.toString().padLeft(2, '0');
  final d = local.day.toString().padLeft(2, '0');
  return '$y-$m-$d';
}

class TodayRepository {
  TodayRepository({
    required this.hubClient,
    required this.accessToken,
    required this.services,
    required this.households,
  });

  final CaleeHubClient hubClient;
  final String accessToken;
  final List<ClientService> services;
  final List<ClientContext> households;

  bool get _hasChoreService => services.any((s) => s.supportsChores);

  Future<TodayOverview> loadToday() async {
    final now = DateTime.now();
    final todayStr = _formatDate(now);

    List<ClientEvent> eventsToday = [];
    Object? calendarError;

    List<ClientTask> tasksDueToday = [];
    List<ClientTask> overdueTasks = [];
    Object? tasksError;

    List<ClientChore> choresDueToday = [];
    List<ClientChore> overdueChores = [];
    Object? choresError;

    // Calendar
    try {
      final eventList = await hubClient.events(
        accessToken: accessToken,
        from: todayStr,
        to: todayStr,
      );
      eventsToday = _filterEventsToday(eventList.events, now);
    } catch (e) {
      calendarError = e;
    }

    // Tasks — load a wide range and filter locally
    try {
      final yesterday = now.subtract(const Duration(days: 1));
      final future = now.add(const Duration(days: 30));
      final taskList = await hubClient.tasks(
        accessToken: accessToken,
        from: _formatDate(yesterday),
        to: _formatDate(future),
      );
      final split = _splitTasks(taskList.tasks, now);
      tasksDueToday = split.$1;
      overdueTasks = split.$2;
    } catch (e) {
      tasksError = e;
    }

    // Chores — only if any service supports it
    if (_hasChoreService) {
      try {
        final yesterday = now.subtract(const Duration(days: 1));
        final choreList = await hubClient.chores(
          accessToken: accessToken,
          from: _formatDate(yesterday),
          to: todayStr,
        );
        final split = _splitChores(choreList.chores);
        choresDueToday = split.$1;
        overdueChores = split.$2;
      } catch (e) {
        choresError = e;
      }
    }

    return TodayOverview(
      eventsToday: eventsToday,
      tasksDueToday: tasksDueToday,
      overdueTasks: overdueTasks,
      choresDueToday: choresDueToday,
      overdueChores: overdueChores,
      calendarError: calendarError,
      tasksError: tasksError,
      choresError: choresError,
    );
  }

  List<ClientEvent> _filterEventsToday(List<ClientEvent> events, DateTime now) {
    final todayStart = DateTime(now.year, now.month, now.day);
    final todayEnd = todayStart.add(const Duration(days: 1));

    final filtered = events.where((e) {
      final start = DateTime.tryParse(e.startsAt)?.toLocal();
      if (start == null) return false;
      if (e.allDay) {
        // all-day: startsAt is a date string like '2024-01-15'
        return start.year == now.year &&
            start.month == now.month &&
            start.day == now.day;
      }
      return start.isAfter(todayStart.subtract(const Duration(seconds: 1))) &&
          start.isBefore(todayEnd);
    }).toList();

    // All-day first, then timed by start time
    filtered.sort((a, b) {
      if (a.allDay && !b.allDay) return -1;
      if (!a.allDay && b.allDay) return 1;
      final aStart = DateTime.tryParse(a.startsAt)?.toLocal();
      final bStart = DateTime.tryParse(b.startsAt)?.toLocal();
      if (aStart == null || bStart == null) return 0;
      return aStart.compareTo(bStart);
    });

    return filtered;
  }

  (List<ClientTask>, List<ClientTask>) _splitTasks(
    List<ClientTask> tasks,
    DateTime now,
  ) {
    final todayStr = _formatDate(now);
    final dueToday = <ClientTask>[];
    final overdue = <ClientTask>[];

    for (final task in tasks) {
      if (task.isCompleted) continue;
      final due = task.dueAt;
      if (due == null || due.isEmpty) continue;
      final dueDate = _dateOnlyPrefix(due);
      if (dueDate == todayStr) {
        dueToday.add(task);
      } else if (dueDate.compareTo(todayStr) < 0) {
        overdue.add(task);
      }
    }

    dueToday.sort((a, b) => a.title.compareTo(b.title));
    overdue.sort((a, b) {
      final cmp = (a.dueAt ?? '').compareTo(b.dueAt ?? '');
      if (cmp != 0) return cmp;
      return a.title.compareTo(b.title);
    });

    return (dueToday, overdue);
  }

  (List<ClientChore>, List<ClientChore>) _splitChores(List<ClientChore> chores) {
    final dueToday = <ClientChore>[];
    final overdue = <ClientChore>[];

    for (final chore in chores) {
      if (chore.isCompletionLog) continue;
      final section = chore.normalizedSection;
      if (section == 'todoToday') {
        dueToday.add(chore);
      } else if (section == 'overdue') {
        overdue.add(chore);
      }
    }

    dueToday.sort((a, b) => a.title.compareTo(b.title));
    overdue.sort((a, b) => a.title.compareTo(b.title));

    return (dueToday, overdue);
  }

  String _dateOnlyPrefix(String dateTimeStr) {
    if (dateTimeStr.length >= 10) return dateTimeStr.substring(0, 10);
    return dateTimeStr;
  }
}
