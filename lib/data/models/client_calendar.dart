class ClientCalendarList {
  const ClientCalendarList({required this.calendars});

  factory ClientCalendarList.fromJson(Map<String, dynamic> json) {
    return ClientCalendarList(
      calendars: (json['calendars'] as List<dynamic>? ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(ClientCalendar.fromJson)
          .toList(),
    );
  }

  final List<ClientCalendar> calendars;
}

// Calee calendar model
//
// Calee displays all calendars together, but only Calee calendars are edited
// in Calee.
//
// Calee calendars:
// - Are created and managed by Calee.
// - Are fully two-way editable.
// - Can be edited in CaleeMobile, Calee Portal, and optionally through CalDAV.
// - Are best for events users want to manage directly in Calee.
//
// Connected / non-Calee calendars:
// - Come from Google, Apple/iCloud, Outlook, school, sport, roster, booking,
//   or other calendar systems.
// - Are added using subscription URLs for now, such as ICS, webcal, private
//   iCal, published calendar, or shared calendar links.
// - Are read-only in Calee.
// - Must be edited in the original app or provider.
// - Are best for showing existing events on the Calee display.
//
// UX implications:
// - Calee calendar events may show create, edit, and delete controls.
// - Connected calendar events should show read-only messaging and should not
//   expose edit/delete controls in CaleeMobile.
// - User-facing wording should say "Add calendars you already use so their
//   events appear on your Calee display", not "manage everything in Calee".
class ClientCalendar {
  const ClientCalendar({
    required this.id,
    required this.serviceId,
    required this.serviceName,
    required this.name,
    required this.components,
    required this.primaryKind,
    required this.supportsEvents,
    required this.supportsTasks,
    required this.supportsChores,
    required this.readOnly,
    required this.isSubscription,
    required this.source,
    this.color,
    this.subscriptionUrl,
  });

  factory ClientCalendar.fromJson(Map<String, dynamic> json) {
    return ClientCalendar(
      id: json['id'] as String? ?? '',
      serviceId: json['serviceId'] as String? ?? '',
      serviceName: json['serviceName'] as String? ?? '',
      name: json['name'] as String? ?? '',
      color: json['color'] as String?,
      components: (json['components'] as List<dynamic>? ?? const [])
          .whereType<String>()
          .toList(),
      primaryKind: json['primaryKind'] as String? ?? 'calendar',
      supportsEvents: json['supportsEvents'] as bool? ?? true,
      supportsTasks: json['supportsTasks'] as bool? ?? false,
      supportsChores: json['supportsChores'] as bool? ?? false,
      readOnly: json['readOnly'] as bool? ?? false,
      isSubscription: json['isSubscription'] as bool? ?? false,
      subscriptionUrl: json['subscriptionUrl'] as String?,
      source: json['source'] as String? ?? '',
    );
  }

  final String id;
  final String serviceId;
  final String serviceName;
  final String name;
  final String? color;
  final List<String> components;
  final String primaryKind;
  final bool supportsEvents;
  final bool supportsTasks;
  final bool supportsChores;
  final bool readOnly;
  final bool isSubscription;
  final String? subscriptionUrl;
  final String source;

  bool get isCalendarKind => primaryKind == 'calendar';
  bool get isTaskKind => primaryKind == 'tasks';
  bool get isChoreKind => primaryKind == 'chores';
}

class ClientEventList {
  const ClientEventList({
    required this.from,
    required this.to,
    required this.events,
  });

  factory ClientEventList.fromJson(Map<String, dynamic> json) {
    return ClientEventList(
      from: json['from'] as String? ?? '',
      to: json['to'] as String? ?? '',
      events: (json['events'] as List<dynamic>? ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(ClientEvent.fromJson)
          .toList(),
    );
  }

  final String from;
  final String to;
  final List<ClientEvent> events;
}

class ClientEvent {
  const ClientEvent({
    required this.id,
    required this.calendarId,
    required this.serviceId,
    required this.serviceName,
    required this.title,
    required this.startsAt,
    required this.endsAt,
    required this.allDay,
    required this.source,
    required this.recurring,
    this.location,
    this.description,
    this.recurrence,
    this.seriesId,
    this.recurrenceId,
    this.occurrenceId,
  });

  factory ClientEvent.fromJson(Map<String, dynamic> json) {
    return ClientEvent(
      id: json['id'] as String? ?? '',
      calendarId: json['calendarId'] as String? ?? '',
      serviceId: json['serviceId'] as String? ?? '',
      serviceName: json['serviceName'] as String? ?? '',
      title: json['title'] as String? ?? '',
      startsAt: json['startsAt'] as String? ?? '',
      endsAt: json['endsAt'] as String? ?? '',
      allDay: json['allDay'] as bool? ?? false,
      location: json['location'] as String?,
      description: json['description'] as String?,
      source: json['source'] as String? ?? '',
      recurring: json['recurring'] as bool? ?? false,
      recurrence: json['recurrence'] as String?,
      seriesId: json['seriesId'] as String?,
      recurrenceId: json['recurrenceId'] as String?,
      occurrenceId: json['occurrenceId'] as String?,
    );
  }

  final String id;
  final String calendarId;
  final String serviceId;
  final String serviceName;
  final String title;
  final String startsAt;
  final String endsAt;
  final bool allDay;
  final String? location;
  final String? description;
  final String source;
  final bool recurring;
  final String? recurrence;
  final String? seriesId;
  final String? recurrenceId;
  final String? occurrenceId;

  String get writableEventId {
    if (recurring && (seriesId ?? '').trim().isNotEmpty) {
      return seriesId!.trim();
    }

    return id;
  }
}
