class CalendarShareAliasDto {
  final String userUid;
  final String aliasEmail;
  final String token;
  final bool isActive;
  final String wasCreated;
  final String domain;
  final String copyValue;

  const CalendarShareAliasDto({
    required this.userUid,
    required this.aliasEmail,
    required this.token,
    required this.isActive,
    required this.wasCreated,
    required this.domain,
    required this.copyValue,
  });

  factory CalendarShareAliasDto.fromJson(Map<String, dynamic> json) {
    return CalendarShareAliasDto(
      userUid: (json['userUid'] ?? json['user_uid'] ?? '').toString(),
      aliasEmail: (json['aliasEmail'] ?? json['alias_email'] ?? '').toString(),
      token: (json['token'] ?? '').toString(),
      isActive: _toBool(json['isActive'] ?? json['is_active']),
      wasCreated: (json['wasCreated'] ?? json['was_created'] ?? '').toString(),
      domain: (json['domain'] ?? '').toString(),
      copyValue: (json['copyValue'] ?? json['copy_value'] ?? json['aliasEmail'] ?? json['alias_email'] ?? '')
          .toString(),
    );
  }

  static bool _toBool(dynamic value) {
    if (value is bool) return value;
    final normalized = (value ?? '').toString().trim().toLowerCase();
    return normalized == '1' || normalized == 'true' || normalized == 'yes';
  }
}

class RotateCalendarShareAliasDto {
  final String userUid;
  final String oldAliasEmail;
  final String aliasEmail;
  final String token;
  final bool isActive;
  final String rotatedAt;

  const RotateCalendarShareAliasDto({
    required this.userUid,
    required this.oldAliasEmail,
    required this.aliasEmail,
    required this.token,
    required this.isActive,
    required this.rotatedAt,
  });

  factory RotateCalendarShareAliasDto.fromJson(Map<String, dynamic> json) {
    return RotateCalendarShareAliasDto(
      userUid: (json['userUid'] ?? json['user_uid'] ?? '').toString(),
      oldAliasEmail: (json['oldAliasEmail'] ?? json['old_alias_email'] ?? '').toString(),
      aliasEmail: (json['aliasEmail'] ?? json['alias_email'] ?? '').toString(),
      token: (json['token'] ?? '').toString(),
      isActive: CalendarShareAliasDto._toBool(json['isActive'] ?? json['is_active']),
      rotatedAt: (json['rotatedAt'] ?? json['rotated_at'] ?? '').toString(),
    );
  }
}
