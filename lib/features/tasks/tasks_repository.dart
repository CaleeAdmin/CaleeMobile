import '../../data/api/calee_hub_client.dart';
import '../../data/auth/calee_preferences.dart';
import '../../data/models/calendar_service_error.dart';
import '../../data/models/client_bootstrap.dart';
import '../../data/models/client_calendar.dart';
import '../../data/models/client_task.dart';

// ─────────────────────────────────────────────
// Public data model
// ─────────────────────────────────────────────

class TasksOverview {
  const TasksOverview({
    required this.calendarList,
    required this.taskList,
    required this.preferences,
    required this.from,
    required this.to,
    this.calendarServiceErrors = const [],
  });

  final ClientCalendarList calendarList;
  final ClientTaskList taskList;
  final StoredPreferences preferences;
  final String from;
  final String to;
  final List<CalendarServiceError> calendarServiceErrors;
}

// ─────────────────────────────────────────────
// Repository
// ─────────────────────────────────────────────

class TasksRepository {
  TasksRepository({
    required this.hubClient,
    required this.accessToken,
    required this.services,
    CaleePreferences? preferences,
  }) : _preferences = preferences ?? CaleePreferences();

  final CaleeHubClient hubClient;
  final String accessToken;
  final List<ClientService> services;
  final CaleePreferences _preferences;

  List<ClientService> get taskServices =>
      services.where((s) => s.supportsTasks).toList();

  Future<TasksOverview> loadOverview({
    required String from,
    required String to,
  }) async {
    final prefs = await _preferences.load();

    ClientCalendarList calList = const ClientCalendarList(calendars: []);
    final calendarServiceErrors = <CalendarServiceError>[];

    try {
      calList = await hubClient.calendars(accessToken: accessToken);
      calendarServiceErrors.addAll(calList.serviceErrors);
    } on CaleeHubException catch (e) {
      if (isCalendarServiceConnectionCode(e.code)) {
        calendarServiceErrors.add(CalendarServiceError.fromException(e));
      } else {
        rethrow;
      }
    }

    final taskList = await hubClient.tasks(
      accessToken: accessToken,
      from: from,
      to: to,
    );

    return TasksOverview(
      preferences: prefs,
      calendarList: calList,
      taskList: taskList,
      from: from,
      to: to,
      calendarServiceErrors: calendarServiceErrors,
    );
  }

  Future<void> createTask({
    required ClientCalendar taskCalendar,
    required String title,
    String? dueAt,
    String? description,
  }) async {
    await hubClient.createTask(
      accessToken: accessToken,
      serviceId: taskCalendar.serviceId,
      calendarId: _rawCalendarId(taskCalendar),
      title: title,
      dueAt: dueAt,
      description: description,
    );
  }

  Future<void> updateTask({
    required ClientTask task,
    required String title,
    String? dueAt,
    String? description,
  }) async {
    await hubClient.updateTask(
      accessToken: accessToken,
      taskId: task.id,
      title: title,
      dueAt: dueAt,
      description: description,
    );
  }

  Future<void> setTaskCompleted({
    required ClientTask task,
    required bool completed,
  }) async {
    await hubClient.updateTaskStatus(
      accessToken: accessToken,
      taskId: task.id,
      completed: completed,
    );
  }

  Future<void> deleteTask(ClientTask task) async {
    await hubClient.deleteTask(accessToken: accessToken, taskId: task.id);
  }

  String _rawCalendarId(ClientCalendar calendar) {
    final prefix = '${calendar.serviceId}:';
    if (calendar.id.startsWith(prefix)) {
      return calendar.id.substring(prefix.length);
    }
    return calendar.id;
  }
}
