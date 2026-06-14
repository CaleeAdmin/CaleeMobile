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
    this.cursor,
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
      cursor: json['cursor'] as String?,
    );
  }

  final List<DeletedItem> items;
  final List<UnsupportedDeletedItemsService> unsupportedServices;
  final String? cursor;
}

class UnsupportedDeletedItemsService {
  const UnsupportedDeletedItemsService({
    required this.serviceId,
    required this.displayName,
  });

  factory UnsupportedDeletedItemsService.fromJson(
    Map<String, dynamic> json,
  ) {
    return UnsupportedDeletedItemsService(
      serviceId: json['serviceId'] as String? ?? '',
      displayName: json['displayName'] as String? ?? '',
    );
  }

  final String serviceId;
  final String displayName;
}
