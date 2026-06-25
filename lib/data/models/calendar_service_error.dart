import '../api/calee_hub_client.dart';

const _serviceConnectionCodes = {
  'SERVICE_CREDENTIAL_INVALID',
  'BUSINESS_CALENDAR_CONNECTION_BROKEN',
  'PORTAL_CALENDAR_CONNECTION_BROKEN',
  'SCHOOL_CALENDAR_CONNECTION_BROKEN',
  'CALENDAR_SERVICE_CONNECTION_BROKEN',
  'CALENDAR_SERVICE_UNAVAILABLE',
};

bool isCalendarServiceConnectionCode(String? code) =>
    code != null && _serviceConnectionCodes.contains(code);

class CalendarServiceError {
  const CalendarServiceError({
    required this.code,
    this.serviceId,
    this.serviceName,
    this.message,
  });

  factory CalendarServiceError.fromJson(Map<String, dynamic> json) {
    return CalendarServiceError(
      code: json['code'] as String? ?? 'CALENDAR_SERVICE_CONNECTION_BROKEN',
      serviceId: json['serviceId'] as String?,
      serviceName: json['serviceName'] as String?,
      message: json['message'] as String?,
    );
  }

  factory CalendarServiceError.fromException(CaleeHubException e) {
    return CalendarServiceError(
      code: e.code ?? 'CALENDAR_SERVICE_CONNECTION_BROKEN',
      serviceId: e.serviceId,
      serviceName: e.serviceName,
      message: e.message,
    );
  }

  final String code;
  final String? serviceId;
  final String? serviceName;
  final String? message;

  bool get isServiceConnectionError => isCalendarServiceConnectionCode(code);

  String get displayServiceName {
    final name = serviceName?.trim();
    if (name != null && name.isNotEmpty) return name;
    final id = serviceId?.trim();
    if (id != null && id.isNotEmpty) return id;
    return 'Calendar service';
  }

  String get repairMessage =>
      '$displayServiceName calendar connection needs repair. '
      'Please contact Calee support.';
}
