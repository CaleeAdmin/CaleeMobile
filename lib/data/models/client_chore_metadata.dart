class ClientChoreMetadata {
  const ClientChoreMetadata({
    required this.id,
    required this.householdId,
    required this.choreUid,
    required this.assigneePersonId,
    required this.points,
    required this.approvalState,
    required this.createdAt,
    required this.updatedAt,
  });

  factory ClientChoreMetadata.fromJson(Map<String, dynamic> json) {
    return ClientChoreMetadata(
      id: json['id']?.toString(),
      householdId: json['householdId'] as String? ?? '',
      choreUid: json['choreUid'] as String? ?? '',
      assigneePersonId: json['assigneePersonId']?.toString(),
      points: json['points'] is int ? json['points'] as int : 1,
      approvalState: json['approvalState'] as String? ?? 'none',
      createdAt: json['createdAt'] as String?,
      updatedAt: json['updatedAt'] as String?,
    );
  }

  final String? id;
  final String householdId;
  final String choreUid;
  final String? assigneePersonId;
  final int points;
  final String approvalState;
  final String? createdAt;
  final String? updatedAt;

  bool get hasAssignee =>
      assigneePersonId != null && assigneePersonId!.isNotEmpty;
  bool get requiresApproval => approvalState == 'pending';
}
