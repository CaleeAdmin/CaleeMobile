import '../../data/models/client_meal.dart';
import '../../data/models/client_shopping_list.dart';
import 'meals_repository.dart';

/// Stable, user-facing group names shared by every reusable-meal surface.
abstract final class MealSuggestionLabels {
  static const familyFavourites = 'Family favourites';
  static const recentlyUsed = 'Recently used';
  static const savedMeals = 'Saved meals';
  static const quickDinnerIdeas = 'Quick dinner ideas';
  static const createNewMeal = 'Create new meal';
}

enum MealSuggestionSource { saved, starter }

/// One reusable meal choice, retaining the source record required to preserve
/// ingredient linkage when it is planned.
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
    required this.savedMeals,
    required this.quickDinnerIdeas,
  });

  final List<MealSuggestion> familyFavourites;
  final List<MealSuggestion> recentlyUsed;
  final List<MealSuggestion> savedMeals;
  final List<MealSuggestion> quickDinnerIdeas;

  bool get isEmpty =>
      familyFavourites.isEmpty &&
      recentlyUsed.isEmpty &&
      savedMeals.isEmpty &&
      quickDinnerIdeas.isEmpty;
}

class MealSuggestionGroups {
  const MealSuggestionGroups({
    required this.allSaved,
    required this.familyFavourites,
    required this.recentlyUsed,
    required this.quickDinnerIdeas,
  });

  static const empty = MealSuggestionGroups(
    allSaved: [],
    familyFavourites: [],
    recentlyUsed: [],
    quickDinnerIdeas: [],
  );

  final List<MealSuggestion> allSaved;
  final List<MealSuggestion> familyFavourites;
  final List<MealSuggestion> recentlyUsed;
  final List<MealSuggestion> quickDinnerIdeas;

  MealSuggestionSearchResults search(String query) {
    final normalized = query.trim().toLowerCase();
    if (normalized.isEmpty) {
      return const MealSuggestionSearchResults(
        familyFavourites: [],
        recentlyUsed: [],
        savedMeals: [],
        quickDinnerIdeas: [],
      );
    }

    final favouriteIds = familyFavourites.map((item) => item.id).toSet();
    final recentIds = recentlyUsed.map((item) => item.id).toSet();
    return MealSuggestionSearchResults(
      familyFavourites: familyFavourites
          .where((item) => item.matches(normalized))
          .toList(),
      recentlyUsed: recentlyUsed
          .where((item) => item.matches(normalized))
          .toList(),
      savedMeals: allSaved
          .where(
            (item) =>
                !favouriteIds.contains(item.id) &&
                !recentIds.contains(item.id) &&
                item.matches(normalized),
          )
          .toList(),
      quickDinnerIdeas: quickDinnerIdeas
          .where((item) => item.matches(normalized))
          .toList(),
    );
  }
}

/// Loads and deterministically groups reusable meals for Pick dinner, Saved
/// Meals, Add meal and Meal search.
class MealSuggestionResolver {
  MealSuggestionResolver(this.repository);

  static const maxRecentlyUsed = 5;

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
      ..sort(_compareSavedName);
    final favourites = allSaved.where((item) => item.isFavourite).toList();
    final recents =
        allSaved
            .where((item) => !item.isFavourite && item.usageCount > 0)
            .toList()
          ..sort(_compareRecentlyUsed);
    final quickIdeas = starterTemplates.map(MealSuggestion.starter).toList()
      ..sort(_compareStarter);

    return MealSuggestionGroups(
      allSaved: List.unmodifiable(allSaved),
      familyFavourites: List.unmodifiable(favourites),
      recentlyUsed: List.unmodifiable(recents.take(maxRecentlyUsed)),
      quickDinnerIdeas: List.unmodifiable(quickIdeas),
    );
  }

  static int _compareSavedName(MealSuggestion a, MealSuggestion b) {
    final name = a.name.toLowerCase().compareTo(b.name.toLowerCase());
    return name != 0 ? name : a.id.compareTo(b.id);
  }

  static int _compareRecentlyUsed(MealSuggestion a, MealSuggestion b) {
    final aUsed = a.lastUsedAt;
    final bUsed = b.lastUsedAt;
    if (aUsed != bUsed) {
      if (aUsed == null) return 1;
      if (bUsed == null) return -1;
      final aInstant = DateTime.tryParse(aUsed);
      final bInstant = DateTime.tryParse(bUsed);
      final used = aInstant != null && bInstant != null
          ? bInstant.compareTo(aInstant)
          : bUsed.compareTo(aUsed);
      if (used != 0) return used;
    }
    final usage = b.usageCount.compareTo(a.usageCount);
    return usage != 0 ? usage : _compareSavedName(a, b);
  }

  static int _compareStarter(MealSuggestion a, MealSuggestion b) {
    final order = a.starterTemplate!.sortOrder.compareTo(
      b.starterTemplate!.sortOrder,
    );
    return order != 0 ? order : _compareSavedName(a, b);
  }
}
