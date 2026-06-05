class ClientPersonList {
  const ClientPersonList({required this.people});

  factory ClientPersonList.fromJson(Map<String, dynamic> json) {
    return ClientPersonList(
      people: (json['people'] as List<dynamic>? ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(ClientPerson.fromJson)
          .toList(),
    );
  }

  final List<ClientPerson> people;
}

class ClientPerson {
  const ClientPerson({
    required this.id,
    required this.householdId,
    required this.displayName,
    required this.avatarColor,
    required this.role,
    required this.status,
    required this.sortOrder,
    required this.createdAt,
    required this.updatedAt,
  });

  factory ClientPerson.fromJson(Map<String, dynamic> json) {
    return ClientPerson(
      id: _stringValue(json['id']),
      householdId: json['householdId'] as String? ?? '',
      displayName: json['displayName'] as String? ?? '',
      avatarColor: json['avatarColor'] as String?,
      role: json['role'] as String? ?? 'member',
      status: json['status'] as String? ?? 'active',
      sortOrder: json['sortOrder'] is int ? json['sortOrder'] as int : 0,
      createdAt: json['createdAt'] as String? ?? '',
      updatedAt: json['updatedAt'] as String? ?? '',
    );
  }

  final String id;
  final String householdId;
  final String displayName;
  final String? avatarColor;
  final String role;
  final String status;
  final int sortOrder;
  final String createdAt;
  final String updatedAt;

  bool get isArchived => status == 'archived';
  bool get isActive => status == 'active';

  static String _stringValue(Object? value) {
    if (value == null) {
      return '';
    }

    return value.toString();
  }
}
