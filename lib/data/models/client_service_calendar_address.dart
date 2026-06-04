class ClientServiceCalendarAddress {
  const ClientServiceCalendarAddress({
    required this.serviceId,
    required this.serviceName,
    required this.address,
    required this.copyValue,
    required this.isActive,
    this.rotatedAt,
  });

  factory ClientServiceCalendarAddress.fromJson(Map<String, dynamic> json) {
    final rawAddress = json['sharingEmailAddress'] as String? ?? '';
    return ClientServiceCalendarAddress(
      serviceId: json['serviceId'] as String? ?? '',
      serviceName: json['serviceName'] as String? ?? '',
      address: rawAddress,
      copyValue: json['copyValue'] as String? ?? rawAddress,
      isActive: json['isActive'] as bool? ?? true,
      rotatedAt: json['rotatedAt'] as String?,
    );
  }

  final String serviceId;
  final String serviceName;
  final String address;
  final String copyValue;
  final bool isActive;
  final String? rotatedAt;
}
