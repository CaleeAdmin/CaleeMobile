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
