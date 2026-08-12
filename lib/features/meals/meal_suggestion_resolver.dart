import '../../data/models/client_meal.dart';
import '../../data/models/client_shopping_list.dart';
import 'meals_repository.dart';

abstract final class MealSuggestionLabels {
  static const familyFavourites = 'Family favourites';
  static const recentlyUsed = 'Recently used';
  static const savedMeals = 'Saved meals';
  static const quickDinnerIdeas = 'Quick dinner ideas';
  static const createNewMeal = 'Create new meal';
}

enum MealSuggestionSource { saved, starter }

class MealSuggestion {
  const MealSuggestion._({
    required this.source,
    required this.id,
    required this.name,
    required this.defaultMealType,
    required this.icon,
    required this.notes,
    required this.isFavourite,
    required this.usageCount,
    required this.lastUsedAt,
    this.savedTemplate,
    this.starterTemplate,
  });

  factory MealSuggestion.saved(ClientMealTemplate template) {
    return MealSuggestion._(
      source: MealSuggestionSource.saved,
      id: template.id,
      name: template.name,
      defaultMealType: template.defaultMealType,
      icon: template.icon,
      notes: template.notes,
      isFavourite: template.isFavourite,
      usageCount: template.usageCount,
      lastUsedAt: template.lastUsedAt,
      savedTemplate: template,
    );
  }

  factory MealSuggestion.starter(ClientStarterMealTemplate template) {
    return MealSuggestion._(
      source: MealSuggestionSource.starter,
      id: template.id,
      name: template.name,
      defaultMealType: template.defaultMealType,
      icon: template.icon,
      notes: template.notes,
      isFavourite: false,
      usageCount: 0,
      lastUsedAt: null,
      starterTemplate: template,
    );
  }

  final MealSuggestionSource source;
  final int id;
  final String name;
  final String defaultMealType;
  final String? icon;
  final String? notes;
  final bool isFavourite;
  final int usageCount;
  final String? lastUsedAt;
  final ClientMealTemplate? savedTemplate;
  final ClientStarterMealTemplate? starterTemplate;

  int? get templateId => source == MealSuggestionSource.saved ? id : null;

  int? get starterTemplateId =>
      source == MealSuggestionSource.starter ? id : null;

  bool matches(String normalizedQuery) {
    return name.toLowerCase().contains(normalizedQuery) ||
        (notes ?? '').toLowerCase().contains(normalizedQuery);
  }
}

class MealSuggestionSearchResults {
  const MealSuggestionSearchResults({
    required this.familyFavourites,
    required this.recentlyUsed,
    required this.quickDinnerIdeas,
    required this.otherSaved,
  });

  final List<MealSuggestion> familyFavourites;
  final List<MealSuggestion> recentlyUsed;
  final List<MealSuggestion> quickDinnerIdeas;
  final List<MealSuggestion> otherSaved;

  bool get isEmpty =>
      familyFavourites.isEmpty &&
      recentlyUsed.isEmpty &&
      quickDinnerIdeas.isEmpty &&
      otherSaved.isEmpty;
}

class MealSuggestionGroups {
  const MealSuggestionGroups({
    required this.familyFavourites,
    required this.recentlyUsed,
    required this.quickDinnerIdeas,
    required this.otherSaved,
  });

  static const empty = MealSuggestionGroups(
    familyFavourites: [],
    recentlyUsed: [],
    quickDinnerIdeas: [],
    otherSaved: [],
  );

  final List<MealSuggestion> familyFavourites;
  final List<MealSuggestion> recentlyUsed;
  final List<MealSuggestion> quickDinnerIdeas;
  final List<MealSuggestion> otherSaved;

  MealSuggestionSearchResults search(String query) {
    final normalized = query.trim().toLowerCase();
    if (normalized.isEmpty) {
      return const MealSuggestionSearchResults(
        familyFavourites: [],
        recentlyUsed: [],
        quickDinnerIdeas: [],
        otherSaved: [],
      );
    }
    return MealSuggestionSearchResults(
      familyFavourites: familyFavourites
          .where((item) => item.matches(normalized))
          .toList(),
      recentlyUsed: recentlyUsed
          .where((item) => item.matches(normalized))
          .toList(),
      quickDinnerIdeas: quickDinnerIdeas
          .where((item) => item.matches(normalized))
          .toList(),
      otherSaved: otherSaved.where((item) => item.matches(normalized)).toList(),
    );
  }
}

class MealSuggestionResolver {
  MealSuggestionResolver(this.repository);

  final MealsRepository repository;

  Future<MealSuggestionGroups> load({String? mealType}) async {
    final includeQuickDinnerIdeas = mealType == null || mealType == 'dinner';
    final results = await Future.wait<Object>([
      repository.mealTemplates(mealType: mealType),
      if (includeQuickDinnerIdeas)
        repository.mealStarterTemplates(mealType: 'dinner'),
    ]);
    return resolve(
      savedTemplates: (results.first as ClientMealTemplateList).templates,
      starterTemplates: includeQuickDinnerIdeas
          ? results[1] as List<ClientStarterMealTemplate>
          : const [],
    );
  }

  static MealSuggestionGroups resolve({
    required List<ClientMealTemplate> savedTemplates,
    required List<ClientStarterMealTemplate> starterTemplates,
  }) {
    final allSaved = savedTemplates.map(MealSuggestion.saved).toList()
      ..sort(_compareName);
    final favourites = allSaved.where((item) => item.isFavourite).toList();
    final recents =
        allSaved
            .where((item) => !item.isFavourite && item.usageCount > 0)
            .toList()
          ..sort(_compareRecentlyUsed);
    final recentIds = recents.map((item) => item.id).toSet();
    final otherSaved = allSaved
        .where((item) => !item.isFavourite && !recentIds.contains(item.id))
        .toList();
    final quickIdeas = starterTemplates.map(MealSuggestion.starter).toList()
      ..sort(_compareStarter);

    return MealSuggestionGroups(
      familyFavourites: List.unmodifiable(favourites),
      recentlyUsed: List.unmodifiable(recents),
      quickDinnerIdeas: List.unmodifiable(quickIdeas),
      otherSaved: List.unmodifiable(otherSaved),
    );
  }

  static int _compareName(MealSuggestion a, MealSuggestion b) {
    final name = a.name.toLowerCase().compareTo(b.name.toLowerCase());
    return name != 0 ? name : a.id.compareTo(b.id);
  }

  static int _compareRecentlyUsed(MealSuggestion a, MealSuggestion b) {
    final aUsed = _parseInstant(a.lastUsedAt);
    final bUsed = _parseInstant(b.lastUsedAt);
    if (aUsed != bUsed) {
      if (aUsed == null) return 1;
      if (bUsed == null) return -1;
      final used = bUsed.compareTo(aUsed);
      if (used != 0) return used;
    }
    final usage = b.usageCount.compareTo(a.usageCount);
    return usage != 0 ? usage : _compareName(a, b);
  }

  static DateTime? _parseInstant(String? value) =>
      value == null ? null : DateTime.tryParse(value);

  static int _compareStarter(MealSuggestion a, MealSuggestion b) {
    final order = a.starterTemplate!.sortOrder.compareTo(
      b.starterTemplate!.sortOrder,
    );
    return order != 0 ? order : _compareName(a, b);
  }
}
