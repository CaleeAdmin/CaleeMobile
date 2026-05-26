class ClientTaskList {
  const ClientTaskList({
    required this.from,
    required this.to,
    required this.tasks,
  });

  factory ClientTaskList.fromJson(Map<String, dynamic> json) {
    return ClientTaskList(
      from: json['from'] as String? ?? '',
      to: json['to'] as String? ?? '',
      tasks: (json['tasks'] as List<dynamic>? ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(ClientTask.fromJson)
          .toList(),
    );
  }

  final String from;
  final String to;
  final List<ClientTask> tasks;
}

class ClientTask {
  const ClientTask({
    required this.id,
    required this.calendarId,
    required this.serviceId,
    required this.serviceName,
    required this.title,
    required this.status,
    required this.dueAt,
    required this.completedAt,
    required this.description,
    required this.source,
  });

  factory ClientTask.fromJson(Map<String, dynamic> json) {
    return ClientTask(
      id: json['id'] as String? ?? '',
      calendarId: json['calendarId'] as String? ?? '',
      serviceId: json['serviceId'] as String? ?? '',
      serviceName: json['serviceName'] as String? ?? '',
      title: json['title'] as String? ?? 'Untitled task',
      status: json['status'] as String? ?? '',
      dueAt: json['dueAt'] as String?,
      completedAt: json['completedAt'] as String?,
      description: json['description'] as String?,
      source: json['source'] as String? ?? '',
    );
  }

  final String id;
  final String calendarId;
  final String serviceId;
  final String serviceName;
  final String title;
  final String status;
  final String? dueAt;
  final String? completedAt;
  final String? description;
  final String source;

  bool get isCompleted => status == 'completed';

  String get statusLabel {
    switch (status) {
      case 'needsaction':
        return 'To do';
      case 'completed':
        return 'Completed';
      case 'cancelled':
        return 'Cancelled';
      case 'inprocess':
        return 'In progress';
      default:
        return status.isEmpty ? 'Task' : status;
    }
  }
}
