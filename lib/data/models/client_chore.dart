class ClientChoreList {
  const ClientChoreList({
    required this.from,
    required this.to,
    required this.chores,
  });

  factory ClientChoreList.fromJson(Map<String, dynamic> json) {
    return ClientChoreList(
      from: json['from'] as String? ?? '',
      to: json['to'] as String? ?? '',
      chores: (json['chores'] as List<dynamic>? ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(ClientChore.fromJson)
          .toList(),
    );
  }

  final String from;
  final String to;
  final List<ClientChore> chores;
}

class ClientChore {
  const ClientChore({
    required this.id,
    required this.calendarId,
    required this.serviceId,
    required this.serviceName,
    required this.title,
    required this.scheduledAt,
    required this.description,
    required this.source,
  });

  factory ClientChore.fromJson(Map<String, dynamic> json) {
    return ClientChore(
      id: json['id'] as String? ?? '',
      calendarId: json['calendarId'] as String? ?? '',
      serviceId: json['serviceId'] as String? ?? '',
      serviceName: json['serviceName'] as String? ?? '',
      title: json['title'] as String? ?? 'Untitled chore',
      scheduledAt: json['scheduledAt'] as String?,
      description: json['description'] as String?,
      source: json['source'] as String? ?? '',
    );
  }

  final String id;
  final String calendarId;
  final String serviceId;
  final String serviceName;
  final String title;
  final String? scheduledAt;
  final String? description;
  final String source;
}
