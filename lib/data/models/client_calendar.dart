class ClientCalendarList {
  const ClientCalendarList({
    required this.calendars,
  });

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

class ClientCalendar {
  const ClientCalendar({
    required this.id,
    required this.serviceId,
    required this.serviceName,
    required this.name,
    required this.readOnly,
    required this.source,
    this.color,
  });

  factory ClientCalendar.fromJson(Map<String, dynamic> json) {
    return ClientCalendar(
      id: json['id'] as String? ?? '',
      serviceId: json['serviceId'] as String? ?? '',
      serviceName: json['serviceName'] as String? ?? '',
      name: json['name'] as String? ?? '',
      color: json['color'] as String?,
      readOnly: json['readOnly'] as bool? ?? false,
      source: json['source'] as String? ?? '',
    );
  }

  final String id;
  final String serviceId;
  final String serviceName;
  final String name;
  final String? color;
  final bool readOnly;
  final String source;
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
    this.location,
    this.description,
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
}
