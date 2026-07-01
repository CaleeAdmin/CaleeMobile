import '../../data/models/calendar_service_error.dart';
import '../../data/models/client_calendar.dart';
import '../../data/models/client_chore.dart';
import '../../data/models/client_meal.dart';
import '../../data/models/client_task.dart';

class TodayOverview {
  const TodayOverview({
    required this.eventsToday,
    required this.tasksDueToday,
    required this.overdueTasks,
    required this.choresDueToday,
    required this.overdueChores,
    this.mealsToday = const [],
    this.calendarError,
    this.tasksError,
    this.choresError,
    this.mealsError,
    this.calendarServiceErrors = const [],
  });

  final List<ClientEvent> eventsToday;
  final List<ClientTask> tasksDueToday;
  final List<ClientTask> overdueTasks;
  final List<ClientChore> choresDueToday;
  final List<ClientChore> overdueChores;
  final List<ClientMeal> mealsToday;
  final Object? calendarError;
  final Object? tasksError;
  final Object? choresError;
  final Object? mealsError;
  final List<CalendarServiceError> calendarServiceErrors;

  bool get hasCalendarError => calendarError != null;
  bool get hasTasksError => tasksError != null;
  bool get hasChoresError => choresError != null;
  bool get hasMealsError => mealsError != null;
  bool get hasCalendarServiceError => calendarServiceErrors.isNotEmpty;
}
