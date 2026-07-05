class ClientTemplateIngredient {
  const ClientTemplateIngredient({
    required this.id,
    required this.name,
    required this.normalizedName,
    required this.optional,
    required this.sortOrder,
    this.templateId,
    this.starterTemplateId,
    this.householdId,
    this.quantityText,
    this.unit,
    this.category,
    this.createdAt,
    this.updatedAt,
  });

  factory ClientTemplateIngredient.fromJson(Map<String, dynamic> json) {
    return ClientTemplateIngredient(
      id: json['id'] is int
          ? json['id'] as int
          : int.tryParse(json['id']?.toString() ?? '') ?? 0,
      templateId: json['templateId'] is int
          ? json['templateId'] as int
          : int.tryParse(json['templateId']?.toString() ?? ''),
      starterTemplateId: json['starterTemplateId'] is int
          ? json['starterTemplateId'] as int
          : int.tryParse(json['starterTemplateId']?.toString() ?? ''),
      householdId: json['householdId'] as String?,
      name: json['name'] as String? ?? '',
      normalizedName: json['normalizedName'] as String? ?? '',
      quantityText: json['quantityText'] as String?,
      unit: json['unit'] as String?,
      category: json['category'] as String?,
      optional: json['optional'] as bool? ?? false,
      sortOrder: json['sortOrder'] is int
          ? json['sortOrder'] as int
          : int.tryParse(json['sortOrder']?.toString() ?? '') ?? 0,
      createdAt: json['createdAt'] as String?,
      updatedAt: json['updatedAt'] as String?,
    );
  }

  final int id;
  final int? templateId;
  final int? starterTemplateId;
  final String? householdId;
  final String name;
  final String normalizedName;
  final String? quantityText;
  final String? unit;
  final String? category;
  final bool optional;
  final int sortOrder;
  final String? createdAt;
  final String? updatedAt;
}

class ClientStarterMealTemplate {
  const ClientStarterMealTemplate({
    required this.id,
    required this.slug,
    required this.name,
    required this.defaultMealType,
    required this.kidFriendly,
    required this.freezerFriendly,
    required this.lunchboxFriendly,
    required this.sortOrder,
    required this.version,
    required this.active,
    required this.ingredients,
    this.icon,
    this.imageAssetKey,
    this.notes,
    this.difficulty,
    this.prepMinutes,
    this.servings,
    this.tagsJson,
    this.recipeUrl,
    this.recipeNote,
    this.region,
    this.pack,
  });

  factory ClientStarterMealTemplate.fromJson(Map<String, dynamic> json) {
    return ClientStarterMealTemplate(
      id: json['id'] is int
          ? json['id'] as int
          : int.tryParse(json['id']?.toString() ?? '') ?? 0,
      slug: json['slug'] as String? ?? '',
      name: json['name'] as String? ?? '',
      defaultMealType: json['defaultMealType'] as String? ?? '',
      icon: json['icon'] as String?,
      imageAssetKey: json['imageAssetKey'] as String?,
      notes: json['notes'] as String?,
      difficulty: json['difficulty'] as String?,
      prepMinutes: json['prepMinutes'] is int
          ? json['prepMinutes'] as int
          : int.tryParse(json['prepMinutes']?.toString() ?? ''),
      servings: json['servings'] is int
          ? json['servings'] as int
          : int.tryParse(json['servings']?.toString() ?? ''),
      kidFriendly: json['kidFriendly'] as bool? ?? false,
      freezerFriendly: json['freezerFriendly'] as bool? ?? false,
      lunchboxFriendly: json['lunchboxFriendly'] as bool? ?? false,
      tagsJson: json['tagsJson'] as String?,
      recipeUrl: json['recipeUrl'] as String?,
      recipeNote: json['recipeNote'] as String?,
      region: json['region'] as String?,
      pack: json['pack'] as String?,
      sortOrder: json['sortOrder'] is int
          ? json['sortOrder'] as int
          : int.tryParse(json['sortOrder']?.toString() ?? '') ?? 0,
      version: json['version'] is int
          ? json['version'] as int
          : int.tryParse(json['version']?.toString() ?? '') ?? 1,
      active: json['active'] as bool? ?? true,
      ingredients: (json['ingredients'] as List<dynamic>? ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(ClientTemplateIngredient.fromJson)
          .toList(),
    );
  }

  final int id;
  final String slug;
  final String name;
  final String defaultMealType;
  final String? icon;
  final String? imageAssetKey;
  final String? notes;
  final String? difficulty;
  final int? prepMinutes;
  final int? servings;
  final bool kidFriendly;
  final bool freezerFriendly;
  final bool lunchboxFriendly;
  final String? tagsJson;
  final String? recipeUrl;
  final String? recipeNote;
  final String? region;
  final String? pack;
  final int sortOrder;
  final int version;
  final bool active;
  final List<ClientTemplateIngredient> ingredients;
}

class ClientShoppingListItem {
  const ClientShoppingListItem({
    required this.id,
    required this.shoppingListId,
    required this.householdId,
    required this.name,
    required this.checked,
    required this.manuallyAdded,
    required this.manuallyRemoved,
    required this.sortOrder,
    this.sourceType,
    this.sourceMealItemId,
    this.sourceTemplateId,
    this.sourceStarterTemplateId,
    this.normalizedName,
    this.quantityText,
    this.unit,
    this.category,
    this.checkedAt,
    this.createdAt,
    this.updatedAt,
    this.deletedAt,
  });

  factory ClientShoppingListItem.fromJson(Map<String, dynamic> json) {
    return ClientShoppingListItem(
      id: json['id'] is int
          ? json['id'] as int
          : int.tryParse(json['id']?.toString() ?? '') ?? 0,
      shoppingListId: json['shoppingListId'] is int
          ? json['shoppingListId'] as int
          : int.tryParse(json['shoppingListId']?.toString() ?? '') ?? 0,
      householdId: json['householdId'] as String? ?? '',
      sourceType: json['sourceType'] as String?,
      sourceMealItemId: json['sourceMealItemId'] is int
          ? json['sourceMealItemId'] as int
          : int.tryParse(json['sourceMealItemId']?.toString() ?? ''),
      sourceTemplateId: json['sourceTemplateId'] is int
          ? json['sourceTemplateId'] as int
          : int.tryParse(json['sourceTemplateId']?.toString() ?? ''),
      sourceStarterTemplateId: json['sourceStarterTemplateId'] is int
          ? json['sourceStarterTemplateId'] as int
          : int.tryParse(json['sourceStarterTemplateId']?.toString() ?? ''),
      name: json['name'] as String? ?? '',
      normalizedName: json['normalizedName'] as String?,
      quantityText: json['quantityText'] as String?,
      unit: json['unit'] as String?,
      category: json['category'] as String?,
      checked: json['checked'] as bool? ?? false,
      checkedAt: json['checkedAt'] as String?,
      manuallyAdded: json['manuallyAdded'] as bool? ?? false,
      manuallyRemoved: json['manuallyRemoved'] as bool? ?? false,
      sortOrder: json['sortOrder'] is int
          ? json['sortOrder'] as int
          : int.tryParse(json['sortOrder']?.toString() ?? '') ?? 0,
      createdAt: json['createdAt'] as String?,
      updatedAt: json['updatedAt'] as String?,
      deletedAt: json['deletedAt'] as String?,
    );
  }

  final int id;
  final int shoppingListId;
  final String householdId;
  final String? sourceType;
  final int? sourceMealItemId;
  final int? sourceTemplateId;
  final int? sourceStarterTemplateId;
  final String name;
  final String? normalizedName;
  final String? quantityText;
  final String? unit;
  final String? category;
  final bool checked;
  final String? checkedAt;
  final bool manuallyAdded;
  final bool manuallyRemoved;
  final int sortOrder;
  final String? createdAt;
  final String? updatedAt;
  final String? deletedAt;

  /// Category label for display/grouping — falls back to 'Other' when the
  /// backend hasn't categorised this item.
  String get displayCategory {
    final trimmed = category?.trim() ?? '';
    return trimmed.isEmpty ? 'Other' : trimmed;
  }
}

class ClientShoppingList {
  const ClientShoppingList({
    required this.id,
    required this.householdId,
    required this.title,
    required this.fromDate,
    required this.toDate,
    required this.status,
    required this.items,
    this.createdByAccountId,
    this.createdAt,
    this.updatedAt,
    this.archivedAt,
  });

  factory ClientShoppingList.fromJson(Map<String, dynamic> json) {
    return ClientShoppingList(
      id: json['id'] is int
          ? json['id'] as int
          : int.tryParse(json['id']?.toString() ?? '') ?? 0,
      householdId: json['householdId'] as String? ?? '',
      title: json['title'] as String? ?? '',
      fromDate: json['fromDate'] as String? ?? '',
      toDate: json['toDate'] as String? ?? '',
      status: json['status'] as String? ?? 'active',
      createdByAccountId: json['createdByAccountId'] as String?,
      createdAt: json['createdAt'] as String?,
      updatedAt: json['updatedAt'] as String?,
      archivedAt: json['archivedAt'] as String?,
      items: (json['items'] as List<dynamic>? ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(ClientShoppingListItem.fromJson)
          .toList(),
    );
  }

  final int id;
  final String householdId;
  final String title;
  final String fromDate;
  final String toDate;
  final String status;
  final String? createdByAccountId;
  final String? createdAt;
  final String? updatedAt;
  final String? archivedAt;

  /// Mutable, growable list (as produced by `.toList()`), so
  /// [ShoppingController] can splice items in place for optimistic updates
  /// without needing a `copyWith` on this DTO.
  final List<ClientShoppingListItem> items;
}
