class DeletedItem {
  const DeletedItem({
    required this.deletedItemId,
    required this.serviceId,
    required this.provider,
    required this.type,
    required this.title,
    this.subtitle,
    required this.deletedAt,
    this.expiresAt,
    required this.canRestore,
    required this.canDeletePermanently,
    required this.restoreConflictPossible,
  });

  factory DeletedItem.fromJson(Map<String, dynamic> json) {
    return DeletedItem(
      deletedItemId: json['deletedItemId'] as String? ?? '',
      serviceId: json['serviceId'] as String? ?? '',
      provider: json['provider'] as String? ?? '',
      type: json['type'] as String? ?? '',
      title: json['title'] as String? ?? '',
      subtitle: json['subtitle'] as String?,
      deletedAt: json['deletedAt'] as String? ?? '',
      expiresAt: json['expiresAt'] as String?,
      canRestore: json['canRestore'] as bool? ?? false,
      canDeletePermanently: json['canDeletePermanently'] as bool? ?? false,
      restoreConflictPossible:
          json['restoreConflictPossible'] as bool? ?? false,
    );
  }

  final String deletedItemId;
  final String serviceId;
  final String provider;
  final String type;
  final String title;
  final String? subtitle;
  final String deletedAt;
  final String? expiresAt;
  final bool canRestore;
  final bool canDeletePermanently;
  final bool restoreConflictPossible;

  bool get isListType =>
      type == 'calendar' || type == 'task_list' || type == 'chore_list';
}

class DeletedItemsResponse {
  const DeletedItemsResponse({
    required this.items,
    required this.unsupportedServices,
    this.nextCursor,
  });

  factory DeletedItemsResponse.fromJson(Map<String, dynamic> json) {
    return DeletedItemsResponse(
      items: (json['items'] as List<dynamic>? ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(DeletedItem.fromJson)
          .toList(),
      unsupportedServices:
          (json['unsupportedServices'] as List<dynamic>? ?? const [])
              .whereType<Map<String, dynamic>>()
              .map(UnsupportedDeletedItemsService.fromJson)
              .toList(),
      nextCursor: json['nextCursor'] as String? ?? json['cursor'] as String?,
    );
  }

  final List<DeletedItem> items;
  final List<UnsupportedDeletedItemsService> unsupportedServices;
  final String? nextCursor;
}

class UnsupportedDeletedItemsService {
  const UnsupportedDeletedItemsService({
    required this.serviceId,
    required this.displayName,
    this.provider,
    this.supportsDeletedItems,
    this.message,
  });

  factory UnsupportedDeletedItemsService.fromJson(Map<String, dynamic> json) {
    return UnsupportedDeletedItemsService(
      serviceId: json['serviceId'] as String? ?? '',
      displayName:
          json['displayName'] as String? ??
          json['serviceId'] as String? ??
          'Connected service',
      provider: json['provider'] as String?,
      supportsDeletedItems: json['supportsDeletedItems'] as bool?,
      message: json['message'] as String?,
    );
  }

  final String serviceId;
  final String displayName;
  final String? provider;
  final bool? supportsDeletedItems;
  final String? message;
}
