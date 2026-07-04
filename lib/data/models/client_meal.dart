class ClientMealList {
  const ClientMealList({
    required this.householdId,
    required this.from,
    required this.to,
    required this.meals,
  });

  factory ClientMealList.fromJson(Map<String, dynamic> json) {
    return ClientMealList(
      householdId: json['householdId'] as String? ?? '',
      from: json['from'] as String? ?? '',
      to: json['to'] as String? ?? '',
      meals: (json['meals'] as List<dynamic>? ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(ClientMeal.fromJson)
          .toList(),
    );
  }

  final String householdId;
  final String from;
  final String to;
  final List<ClientMeal> meals;
}

class ClientMeal {
  const ClientMeal({
    required this.id,
    required this.householdId,
    required this.mealDate,
    required this.mealType,
    required this.title,
    required this.status,
    required this.source,
    this.notes,
    this.assignedPersonId,
    this.templateId,
    this.recipeId,
    this.linkedEventId,
    this.difficulty,
    this.prepMinutes,
    this.servings,
    this.leftoverPlan,
    this.createdByAccountId,
    this.createdAt,
    this.updatedAt,
    this.deletedAt,
  });

  factory ClientMeal.fromJson(Map<String, dynamic> json) {
    return ClientMeal(
      id: json['id'] is int
          ? json['id'] as int
          : int.tryParse(json['id']?.toString() ?? '') ?? 0,
      householdId: json['householdId'] as String? ?? '',
      mealDate: json['mealDate'] as String? ?? '',
      mealType: json['mealType'] as String? ?? '',
      title: json['title'] as String? ?? 'Untitled meal',
      status: json['status'] as String? ?? 'planned',
      source: json['source'] as String? ?? 'manual',
      notes: json['notes'] as String?,
      assignedPersonId: json['assignedPersonId'] is int
          ? json['assignedPersonId'] as int
          : int.tryParse(json['assignedPersonId']?.toString() ?? ''),
      templateId: json['templateId'] is int
          ? json['templateId'] as int
          : int.tryParse(json['templateId']?.toString() ?? ''),
      recipeId: json['recipeId'] is int
          ? json['recipeId'] as int
          : int.tryParse(json['recipeId']?.toString() ?? ''),
      linkedEventId: json['linkedEventId'] as String?,
      difficulty: json['difficulty'] as String?,
      prepMinutes: json['prepMinutes'] is int
          ? json['prepMinutes'] as int
          : int.tryParse(json['prepMinutes']?.toString() ?? ''),
      servings: json['servings'] is int
          ? json['servings'] as int
          : int.tryParse(json['servings']?.toString() ?? ''),
      leftoverPlan: json['leftoverPlan'] as String?,
      createdByAccountId: json['createdByAccountId'] as String?,
      createdAt: json['createdAt'] as String?,
      updatedAt: json['updatedAt'] as String?,
      deletedAt: json['deletedAt'] as String?,
    );
  }

  final int id;
  final String householdId;
  final String mealDate;
  final String mealType;
  final String title;
  final String? notes;
  final int? assignedPersonId;
  final String status;
  final String source;
  final int? templateId;
  final int? recipeId;
  final String? linkedEventId;
  final String? difficulty;
  final int? prepMinutes;
  final int? servings;
  final String? leftoverPlan;
  final String? createdByAccountId;
  final String? createdAt;
  final String? updatedAt;
  final String? deletedAt;

  String get mealTypeLabel {
    switch (mealType) {
      case 'breakfast':
        return 'Breakfast';
      case 'lunch':
        return 'Lunch';
      case 'dinner':
        return 'Dinner';
      default:
        return mealType.isEmpty ? 'Meal' : mealType;
    }
  }
}

class ClientMealTemplateList {
  const ClientMealTemplateList({required this.templates});

  factory ClientMealTemplateList.fromJson(Map<String, dynamic> json) {
    return ClientMealTemplateList(
      templates: (json['templates'] as List<dynamic>? ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(ClientMealTemplate.fromJson)
          .toList(),
    );
  }

  final List<ClientMealTemplate> templates;
}

class ClientMealTemplate {
  const ClientMealTemplate({
    required this.id,
    required this.householdId,
    required this.name,
    required this.defaultMealType,
    required this.kidFriendly,
    required this.freezerFriendly,
    required this.lunchboxFriendly,
    required this.isFavourite,
    required this.usageCount,
    this.icon,
    this.notes,
  });

  factory ClientMealTemplate.fromJson(Map<String, dynamic> json) {
    return ClientMealTemplate(
      id: json['id'] is int
          ? json['id'] as int
          : int.tryParse(json['id']?.toString() ?? '') ?? 0,
      householdId: json['householdId'] as String? ?? '',
      name: json['name'] as String? ?? '',
      defaultMealType: json['defaultMealType'] as String? ?? '',
      icon: json['icon'] as String?,
      notes: json['notes'] as String?,
      kidFriendly: json['kidFriendly'] as bool? ?? false,
      freezerFriendly: json['freezerFriendly'] as bool? ?? false,
      lunchboxFriendly: json['lunchboxFriendly'] as bool? ?? false,
      isFavourite: json['isFavourite'] as bool? ?? false,
      usageCount: json['usageCount'] is int
          ? json['usageCount'] as int
          : int.tryParse(json['usageCount']?.toString() ?? '') ?? 0,
    );
  }

  final int id;
  final String householdId;
  final String name;
  final String defaultMealType;
  final String? icon;
  final String? notes;
  final bool kidFriendly;
  final bool freezerFriendly;
  final bool lunchboxFriendly;
  final bool isFavourite;
  final int usageCount;
}

class ClientMealCopyWeekResult {
  const ClientMealCopyWeekResult({
    required this.householdId,
    required this.sourceFrom,
    this.sourceTo,
    required this.targetFrom,
    required this.mode,
    required this.mealTypes,
    required this.copiedMeals,
    required this.count,
    required this.skippedCount,
  });

  factory ClientMealCopyWeekResult.fromJson(Map<String, dynamic> json) {
    final rawMeals = json['copiedMeals'] ?? json['meals'];
    final meals = (rawMeals is List)
        ? rawMeals
              .whereType<Map<String, dynamic>>()
              .map(ClientMeal.fromJson)
              .toList()
        : <ClientMeal>[];
    final count = json['count'] is int
        ? json['count'] as int
        : (json['count'] != null
              ? int.tryParse(json['count'].toString()) ?? meals.length
              : meals.length);
    final skippedCount = json['skippedCount'] is int
        ? json['skippedCount'] as int
        : (json['skippedCount'] != null
              ? int.tryParse(json['skippedCount'].toString()) ?? 0
              : 0);
    return ClientMealCopyWeekResult(
      householdId: json['householdId'] as String? ?? '',
      sourceFrom: json['sourceFrom'] as String? ?? '',
      sourceTo: json['sourceTo'] as String?,
      targetFrom: json['targetFrom'] as String? ?? '',
      mode: json['mode'] as String? ?? 'skip_existing',
      mealTypes: (json['mealTypes'] as List<dynamic>? ?? const [])
          .whereType<String>()
          .toList(),
      copiedMeals: meals,
      count: count,
      skippedCount: skippedCount,
    );
  }

  final String householdId;
  final String sourceFrom;
  final String? sourceTo;
  final String targetFrom;
  final String mode;
  final List<String> mealTypes;
  final List<ClientMeal> copiedMeals;
  final int count;
  final int skippedCount;
}
