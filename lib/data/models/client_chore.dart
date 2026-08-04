String normalizeChoreKind(String? value) {
  final raw = value?.trim() ?? '';
  if (raw.isEmpty) return 'baseChore';

  switch (raw) {
    case 'chore':
    case 'base_chore':
    case 'baseChore':
      return 'baseChore';
    case 'completion_log':
    case 'completionLog':
      return 'completionLog';
    default:
      return raw;
  }
}

String normalizeChoreSection(String? value) {
  final raw = value?.trim() ?? '';
  if (raw.isEmpty) return 'todoToday';

  switch (raw) {
    case 'today':
    case 'todo_today':
    case 'todoToday':
      return 'todoToday';
    case 'done_today':
    case 'done-today':
    case 'completedToday':
    case 'doneToday':
      return 'doneToday';
    case 'future':
    case 'history':
    case 'overdue':
      return raw;
    default:
      return raw;
  }
}

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
    required this.baseChoreId,
    required this.occurrenceDate,
    required this.completionLogId,
    required this.completedToday,
    required this.section,
    required this.recurrence,
    required this.points,
    required this.metadataPoints,
    required this.assigneePersonId,
    required this.assigneeName,
    required this.assigneeAvatarColor,
    required this.approvalState,
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
      kind: normalizeChoreKind(json['kind'] as String?),
      choreUid: json['choreUid'] as String?,
      parentChoreUid: json['parentChoreUid'] as String?,
      baseChoreId: json['baseChoreId'] as String?,
      occurrenceDate: json['occurrenceDate'] as String?,
      completionLogId: json['completionLogId'] as String?,
      completedToday: json['completedToday'] as bool? ?? false,
      section: normalizeChoreSection(json['section'] as String?),
      recurrence: json['recurrence'] as String?,
      points: json['points'] is int ? json['points'] as int : 1,
      metadataPoints: json['metadataPoints'] is int
          ? json['metadataPoints'] as int
          : null,
      assigneePersonId: json['assigneePersonId']?.toString(),
      assigneeName: json['assigneeName'] as String?,
      assigneeAvatarColor: json['assigneeAvatarColor'] as String?,
      approvalState: json['approvalState'] as String? ?? 'none',
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
  final String? baseChoreId;
  final String? occurrenceDate;
  final String? completionLogId;
  final bool completedToday;
  final String section;
  final String? recurrence;
  final int points;
  final int? metadataPoints;
  final String? assigneePersonId;
  final String? assigneeName;
  final String? assigneeAvatarColor;
  final String approvalState;

  ClientChore copyWith({bool? completedToday, String? section}) {
    return ClientChore(
      id: id,
      calendarId: calendarId,
      serviceId: serviceId,
      serviceName: serviceName,
      title: title,
      scheduledAt: scheduledAt,
      scheduledDate: scheduledDate,
      description: description,
      source: source,
      kind: kind,
      choreUid: choreUid,
      parentChoreUid: parentChoreUid,
      baseChoreId: baseChoreId,
      occurrenceDate: occurrenceDate,
      completionLogId: completionLogId,
      completedToday: completedToday ?? this.completedToday,
      section: section ?? this.section,
      recurrence: recurrence,
      points: points,
      metadataPoints: metadataPoints,
      assigneePersonId: assigneePersonId,
      assigneeName: assigneeName,
      assigneeAvatarColor: assigneeAvatarColor,
      approvalState: approvalState,
    );
  }

  /// The occurrence date this row represents, in `YYYY-MM-DD` form: the
  /// server-provided [occurrenceDate] for expanded recurring rows, falling
  /// back to [scheduledDate] / [scheduledAt] for rows that predate expansion.
  String? get effectiveOccurrenceDate {
    final value = occurrenceDate ?? scheduledDate ?? scheduledAt;
    if (value == null || value.trim().isEmpty) return null;
    return value.trim().split('T').first;
  }

  /// The id that edit/delete/skip/stopRepeating/complete actions must target.
  /// Virtual occurrence ids (`serviceId:choreUid:date`) are never a valid
  /// CalDAV component id — actions always target the base chore.
  String get completionActionId {
    final base = baseChoreId?.trim();
    if (base != null && base.isNotEmpty) return base;

    if (isBaseChore && id.trim().isNotEmpty) return id;

    final uid = choreUid ?? parentChoreUid;
    if (uid == null || uid.trim().isEmpty || serviceId.trim().isEmpty) {
      return '';
    }

    return '$serviceId:$uid';
  }

  bool get canToggleCompletion {
    if (completionActionId.trim().isEmpty) return false;
    if (normalizedSection == 'history') return false;
    return true;
  }

  bool get hasAssignee =>
      assigneePersonId != null &&
      assigneePersonId!.trim().isNotEmpty &&
      assigneeName != null &&
      assigneeName!.trim().isNotEmpty;

  String get normalizedKind => normalizeChoreKind(kind);
  String get normalizedSection => normalizeChoreSection(section);

  bool get isCompletionLog => normalizedKind == 'completionLog';
  bool get isBaseChore => normalizedKind == 'baseChore';
  bool get isRecurring => recurrence != null && recurrence!.trim().isNotEmpty;
}
