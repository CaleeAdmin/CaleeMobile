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
    required this.scheduledDate,
    required this.description,
    required this.source,
    required this.kind,
    required this.choreUid,
    required this.parentChoreUid,
    required this.completionLogId,
    required this.completedToday,
    required this.section,
    required this.recurrence,
    required this.points,
  });

  factory ClientChore.fromJson(Map<String, dynamic> json) {
    return ClientChore(
      id: json['id'] as String? ?? '',
      calendarId: json['calendarId'] as String? ?? '',
      serviceId: json['serviceId'] as String? ?? '',
      serviceName: json['serviceName'] as String? ?? '',
      title: json['title'] as String? ?? 'Untitled chore',
      scheduledAt: json['scheduledAt'] as String?,
      scheduledDate: json['scheduledDate'] as String?,
      description: json['description'] as String?,
      source: json['source'] as String? ?? '',
      kind: json['kind'] as String? ?? 'baseChore',
      choreUid: json['choreUid'] as String?,
      parentChoreUid: json['parentChoreUid'] as String?,
      completionLogId: json['completionLogId'] as String?,
      completedToday: json['completedToday'] as bool? ?? false,
      section: json['section'] as String? ?? 'future',
      recurrence: json['recurrence'] as String?,
      points: json['points'] is int ? json['points'] as int : 1,
    );
  }

  final String id;
  final String calendarId;
  final String serviceId;
  final String serviceName;
  final String title;
  final String? scheduledAt;
  final String? scheduledDate;
  final String? description;
  final String source;
  final String kind;
  final String? choreUid;
  final String? parentChoreUid;
  final String? completionLogId;
  final bool completedToday;
  final String section;
  final String? recurrence;
  final int points;

  String get completionActionId {
    if (isBaseChore && id.trim().isNotEmpty) {
      return id;
    }

    final uid = choreUid ?? parentChoreUid;
    if (uid == null || uid.trim().isEmpty || serviceId.trim().isEmpty) {
      return '';
    }

    return '$serviceId:$uid';
  }

  bool get canToggleCompletion {
    if (completionActionId.trim().isEmpty) {
      return false;
    }

    return section == 'todoToday' ||
        section == 'overdue' ||
        section == 'doneToday';
  }

  bool get isCompletionLog => kind == 'completionLog';
  bool get isBaseChore => kind == 'baseChore';
  bool get isRecurring => recurrence != null && recurrence!.trim().isNotEmpty;
}
