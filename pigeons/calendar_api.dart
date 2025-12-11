import 'package:pigeon/pigeon.dart';

/// Calendar data contract exposed via Pigeon.
///
/// Scope (first milestone):
/// - List calendars
/// - List events within a time window
///
/// Note: Permission handling is done via permission_handler in Flutter,
/// not through this Pigeon API.
@ConfigurePigeon(
  PigeonOptions(
    dartOut: 'lib/core/platform/pigeon/calendar_api.g.dart',
    kotlinOut: 'android/app/src/main/kotlin/com/nextcloud/caleesync/CalendarApi.g.kt',
    kotlinOptions: KotlinOptions(
      package: 'com.nextcloud.caleesync',
    ),
    swiftOut: 'ios/Runner/CalendarApi.g.swift',
    dartPackageName: 'calendar_api',
  ),
)

class TimeWindow {
  TimeWindow({
    required this.startMillis,
    required this.endMillis,
    this.calendarIds,
  });

  /// Inclusive UTC start timestamp in milliseconds.
  int startMillis;

  /// Exclusive UTC end timestamp in milliseconds.
  int endMillis;

  /// Optional filter for specific calendar IDs (device identifiers).
  List<int?>? calendarIds;
}

class PigeonCalendar {
  PigeonCalendar({
    required this.id,
    required this.accountName,
    required this.accountType,
    this.ownerAccount,
    this.name,
    this.displayName,
    required this.color,
    required this.visible,
    required this.syncEvents,
    required this.isPrimary,
    required this.isLocal,
    required this.accessLevel,
  });

  /// Device-level calendar identifier (Calendar Provider / EventKit).
  int id;

  String accountName;
  String accountType;
  String? ownerAccount;
  String? name;
  String? displayName;
  int color;
  bool visible;
  bool syncEvents;
  bool isPrimary;
  bool isLocal;
  int accessLevel;
}

class PigeonEvent {
  PigeonEvent({
    required this.id,
    required this.calendarId,
    required this.title,
    required this.startMillis,
    required this.endMillis,
    this.description,
    this.location,
    this.allDay = false,
    this.timeZone,
    this.recurrenceRule,
    this.recurrenceExceptionMillis,
    this.attendees,
    this.organizer,
    this.status,
    this.etag,
    this.updatedAtMillis,
    this.isCanceled = false,
  });

  /// Device-level event identifier (Calendar Provider / EventKit).
  String id;

  String calendarId;
  String title;
  int startMillis;
  int endMillis;
  String? description;
  String? location;
  bool allDay;
  String? timeZone;

  /// RRULE string (e.g. FREQ=WEEKLY;BYDAY=MO,WE,FR).
  String? recurrenceRule;

  /// UTC millis for EXDATE-like exceptions.
  List<int?>? recurrenceExceptionMillis;

  /// Attendee emails or identifiers.
  List<String?>? attendees;

  String? organizer;
  String? status;
  String? etag;
  int? updatedAtMillis;
  bool isCanceled;
}

/// Host API implemented on Android/iOS. Flutter calls into this.
///
/// Note: Permission must be granted before calling these methods.
/// Use permission_handler in Flutter to request calendar permissions.
@HostApi()
abstract class CalendarHostApi {
  /// List calendars available on the device.
  ///
  /// Throws if permission is not granted.
  List<PigeonCalendar?> listCalendars();

  /// List events in the given UTC time window (can filter calendars).
  ///
  /// Throws if permission is not granted.
  List<PigeonEvent?> listEvents(TimeWindow window);
}

