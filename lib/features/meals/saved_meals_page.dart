import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../data/api/calee_hub_client.dart';
import '../../data/models/client_meal.dart';
import '../../data/models/client_shopping_list.dart';
import '../../shared/meal_icon.dart';
import '../../ui/calee_design.dart';
import 'meal_suggestion_resolver.dart';
import 'meal_suggestion_section.dart';
import 'meals_controller.dart';

const _kMealTypeLabels = {
  'breakfast': 'Breakfast',
  'lunch': 'Lunch',
  'dinner': 'Dinner',
};

const _kMealTypeOrder = ['breakfast', 'lunch', 'dinner'];

/// Human-readable usage/favourite metadata for a household saved meal, shown
/// as a [CaleeListRow] subtitle. Shared with [PickDinnerSheet] so the two
/// surfaces read consistently.
String? savedMealMetadata(ClientMealTemplate template) {
  if (template.usageCount <= 0) return null;
  final n = template.usageCount;
  return 'Used $n time${n == 1 ? '' : 's'}';
}

/// Subtitle shown under an ingredient's name: quantity and category (kept
/// subtle), joined together when both are present.
String? _ingredientSubtitle(ClientTemplateIngredient ingredient) {
  final quantity = ingredient.quantityText?.trim();
  final category = ingredient.category?.trim();
  final parts = <String>[
    if (quantity != null && quantity.isNotEmpty) quantity,
    if (category != null && category.isNotEmpty) category,
  ];
  return parts.isEmpty ? null : parts.join(' · ');
}

/// Family-friendly text for [error], falling back to [friendly] instead of
/// surfacing raw backend messages. In debug builds only, appends
/// [CaleeHubException.debugSummary] so developers can still see what failed.
String _friendlyErrorText(Object error, String friendly) {
  return kDebugMode && error is CaleeHubException
      ? '$friendly\nDebug: ${error.debugSummary}'
      : friendly;
}

/// Full-screen Saved Meals management view, reached from the Meals page top
/// bar. Lists the household's own saved meals ("Family favourites" and
/// "Recently used", both editable) alongside Calee's shared starter ideas
/// ("Quick dinner ideas", read-only), and lets the user add any of them to
/// the current week via the existing [MealsController.createMeal] path so
/// grocery ingredient linkage is preserved.
class SavedMealsPage extends StatefulWidget {
  const SavedMealsPage({
    required this.hubClient,
    required this.accessToken,
    required this.controller,
    super.key,
  });

  final CaleeHubClient hubClient;
  final String accessToken;
  final MealsController controller;

  @override
  State<SavedMealsPage> createState() => _SavedMealsPageState();
}

class _SavedMealsPageState extends State<SavedMealsPage> {
  late Future<MealSuggestionGroups> _future;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<MealSuggestionGroups> _load() =>
      MealSuggestionResolver(widget.controller.repository).load();

  void _reload() {
    setState(() {
      _future = _load();
    });
  }

  Future<void> _openSearchSheet() async {
    final data = await _future.catchError((_) => MealSuggestionGroups.empty);
    if (!mounted) return;
    await CaleeBottomSheet.show<void>(
      context: context,
      title: 'Search saved meals',
      child: _SavedMealsSearchSheet(
        suggestions: data,
        onCreateNewMeal: () {
          Navigator.of(context).pop();
          _openCreateSheet();
        },
        onTapSuggestion: (suggestion) {
          Navigator.of(context).pop();
          final saved = suggestion.savedTemplate;
          if (saved != null) {
            _openManageSheet(saved);
          } else {
            _openQuickIdeaSheet(suggestion.starterTemplate!);
          }
        },
      ),
    );
  }

  Future<void> _openManageSheet(ClientMealTemplate template) async {
    await ManageSavedMealSheet.show(
      context: context,
      template: template,
      controller: widget.controller,
    );
    if (mounted) _reload();
  }

  Future<void> _openQuickIdeaSheet(ClientStarterMealTemplate template) async {
    await QuickDinnerIdeaSheet.show(
      context: context,
      template: template,
      controller: widget.controller,
    );
  }

  Future<void> _openCreateSheet() async {
    final created = await CreateSavedMealSheet.show(
      context: context,
      controller: widget.controller,
    );
    if (created && mounted) _reload();
  }

  @override
  Widget build(BuildContext context) {
    return CaleeScaffold(
      appBar: AppBar(
        title: const Text('Saved meals'),
        backgroundColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        actions: [
          IconButton(
            key: const Key('saved_meals_search_button'),
            onPressed: _openSearchSheet,
            icon: const Icon(Icons.search),
            tooltip: 'Search saved meals',
          ),
          IconButton(
            onPressed: _openCreateSheet,
            icon: const Icon(Icons.add),
            tooltip: 'Create saved meal',
          ),
        ],
      ),
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: () async => _reload(),
          child: FutureBuilder<MealSuggestionGroups>(
            future: _future,
            builder: (context, snapshot) {
              if (snapshot.connectionState != ConnectionState.done) {
                return const Center(child: CircularProgressIndicator());
              }
              if (snapshot.hasError) {
                return _buildLoadError();
              }
              return _buildContent(snapshot.data!);
            },
          ),
        ),
      ),
    );
  }

  Widget _buildLoadError() {
    return ListView(
      padding: const EdgeInsets.all(CaleeSpacing.xl),
      children: [
        CaleeEmptyState(
          icon: Icons.error_outline,
          title: 'Could not load saved meals',
          body: 'Check your connection, then try again.',
          action: FilledButton(
            onPressed: _reload,
            child: const Text('Try again'),
          ),
        ),
        const SizedBox(height: CaleeSpacing.md),
        OutlinedButton.icon(
          key: const Key('saved_meals_create_new_failed'),
          onPressed: _openCreateSheet,
          icon: const Icon(Icons.add),
          label: const Text(MealSuggestionLabels.createNewMeal),
        ),
      ],
    );
  }

  Widget _buildContent(MealSuggestionGroups options) {
    final noSavedMealsYet =
        options.familyFavourites.isEmpty &&
        options.recentlyUsed.isEmpty &&
        options.otherSaved.isEmpty;
    return ListView(
      padding: const EdgeInsets.symmetric(
        horizontal: CaleeSpacing.pagePadding,
        vertical: CaleeSpacing.md,
      ),
      children: [
        if (noSavedMealsYet) ...[
          const Text(
            'Create saved meals for dinners your family repeats often.',
            style: TextStyle(fontSize: 14, color: CaleeColors.textSecondary),
          ),
          const SizedBox(height: CaleeSpacing.md),
          OutlinedButton.icon(
            key: const Key('saved_meals_create_new_empty'),
            onPressed: _openCreateSheet,
            icon: const Icon(Icons.add),
            label: const Text(MealSuggestionLabels.createNewMeal),
          ),
          const SizedBox(height: CaleeSpacing.sectionSpacing),
        ],
        MealSuggestionSection(
          key: const Key('saved_meals_family_favourites_section'),
          sectionId: 'family_favourites',
          title: MealSuggestionLabels.familyFavourites,
          suggestions: options.familyFavourites,
          emptyText: 'No family favourites yet',
          itemBuilder: _favouriteRow,
        ),
        const SizedBox(height: CaleeSpacing.sectionSpacing),
        MealSuggestionSection(
          key: const Key('saved_meals_recently_used_section'),
          sectionId: 'recently_used',
          title: MealSuggestionLabels.recentlyUsed,
          suggestions: options.recentlyUsed,
          emptyText: 'No recently used meals yet',
          itemBuilder: _recentRow,
        ),
        const SizedBox(height: CaleeSpacing.sectionSpacing),
        MealSuggestionSection(
          key: const Key('saved_meals_quick_dinner_ideas_section'),
          sectionId: 'quick_dinner_ideas',
          title: MealSuggestionLabels.quickDinnerIdeas,
          footer: "Calee's starter ideas — tap Add to this week to use one.",
          suggestions: options.quickDinnerIdeas,
          emptyText: 'No quick dinner ideas yet',
          itemBuilder: _quickIdeaRow,
        ),
        const SizedBox(height: CaleeSpacing.lg),
      ],
    );
  }

  Widget _favouriteRow(MealSuggestion suggestion) {
    final template = suggestion.savedTemplate!;
    return CaleeListRow(
      key: ValueKey('meal_suggestion_saved_${suggestion.id}'),
      leading: Text(
        mealIconEmoji(
          icon: template.icon,
          title: template.name,
          mealType: template.defaultMealType,
        ),
        style: const TextStyle(fontSize: 18),
      ),
      title: template.name,
      subtitle: savedMealMetadata(template),
      trailing: const Icon(Icons.star, size: 18, color: CaleeColors.primary),
      onTap: () => _openManageSheet(template),
    );
  }

  Widget _recentRow(MealSuggestion suggestion) {
    final template = suggestion.savedTemplate!;
    return CaleeListRow(
      key: ValueKey('meal_suggestion_saved_${suggestion.id}'),
      leading: Text(
        mealIconEmoji(
          icon: template.icon,
          title: template.name,
          mealType: template.defaultMealType,
        ),
        style: const TextStyle(fontSize: 18),
      ),
      title: template.name,
      subtitle: savedMealMetadata(template),
      onTap: () => _openManageSheet(template),
    );
  }

  Widget _quickIdeaRow(MealSuggestion suggestion) {
    final template = suggestion.starterTemplate!;
    return CaleeListRow(
      key: ValueKey('meal_suggestion_starter_${suggestion.id}'),
      leading: Text(
        mealIconEmoji(
          icon: template.icon,
          title: template.name,
          mealType: template.defaultMealType,
        ),
        style: const TextStyle(fontSize: 18),
      ),
      title: template.name,
      onTap: () => _openQuickIdeaSheet(template),
    );
  }
}

// ─────────────────────────────────────────────
// Search
// ─────────────────────────────────────────────

class _SavedMealsSearchSheet extends StatefulWidget {
  const _SavedMealsSearchSheet({
    required this.suggestions,
    required this.onCreateNewMeal,
    required this.onTapSuggestion,
  });

  final MealSuggestionGroups suggestions;
  final VoidCallback onCreateNewMeal;
  final ValueChanged<MealSuggestion> onTapSuggestion;

  @override
  State<_SavedMealsSearchSheet> createState() => _SavedMealsSearchSheetState();
}

class _SavedMealsSearchSheetState extends State<_SavedMealsSearchSheet> {
  final _controller = TextEditingController();
  MealSuggestionSearchResults _results = MealSuggestionGroups.empty.search('');

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onQueryChanged);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onQueryChanged() {
    setState(() => _results = widget.suggestions.search(_controller.text));
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: MediaQuery.sizeOf(context).height * 0.65,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            key: const Key('saved_meals_search_field'),
            controller: _controller,
            autofocus: true,
            textInputAction: TextInputAction.search,
            decoration: InputDecoration(
              hintText: 'Search saved meals and ideas…',
              prefixIcon: const Icon(Icons.search_outlined),
              suffixIcon: _controller.text.isNotEmpty
                  ? IconButton(
                      icon: const Icon(Icons.clear),
                      onPressed: _controller.clear,
                    )
                  : null,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(CaleeRadius.card),
                borderSide: BorderSide.none,
              ),
              filled: true,
              fillColor: CaleeColors.groupedBackground,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: CaleeSpacing.md,
                vertical: CaleeSpacing.sm,
              ),
            ),
          ),
          const SizedBox(height: CaleeSpacing.md),
          Expanded(child: _buildResults()),
          const SizedBox(height: CaleeSpacing.sm),
          OutlinedButton.icon(
            key: const Key('saved_meals_search_create_new'),
            onPressed: widget.onCreateNewMeal,
            icon: const Icon(Icons.add),
            label: const Text(MealSuggestionLabels.createNewMeal),
          ),
        ],
      ),
    );
  }

  Widget _buildResults() {
    if (_controller.text.trim().isEmpty) {
      return const Center(
        child: Text(
          'Type to search',
          style: TextStyle(color: CaleeColors.textTertiary),
        ),
      );
    }
    if (_results.isEmpty) {
      return const Center(
        child: Text(
          'No saved meals or ideas found',
          style: TextStyle(color: CaleeColors.textTertiary),
        ),
      );
    }
    return ListView(
      children: [
        if (_results.familyFavourites.isNotEmpty) ...[
          _resultSection(
            'search_family_favourites',
            MealSuggestionLabels.familyFavourites,
            _results.familyFavourites,
          ),
          const SizedBox(height: CaleeSpacing.md),
        ],
        if (_results.recentlyUsed.isNotEmpty) ...[
          _resultSection(
            'search_recently_used',
            MealSuggestionLabels.recentlyUsed,
            _results.recentlyUsed,
          ),
          const SizedBox(height: CaleeSpacing.md),
        ],
        if (_results.quickDinnerIdeas.isNotEmpty) ...[
          _resultSection(
            'search_quick_dinner_ideas',
            MealSuggestionLabels.quickDinnerIdeas,
            _results.quickDinnerIdeas,
          ),
          const SizedBox(height: CaleeSpacing.md),
        ],
        if (_results.otherSaved.isNotEmpty)
          _resultSection(
            'search_saved_meals',
            MealSuggestionLabels.savedMeals,
            _results.otherSaved,
          ),
      ],
    );
  }

  Widget _resultSection(
    String sectionId,
    String title,
    List<MealSuggestion> suggestions,
  ) {
    return MealSuggestionSection(
      sectionId: sectionId,
      title: title,
      suggestions: suggestions,
      emptyText: '',
      itemBuilder: _resultRow,
    );
  }

  Widget _resultRow(MealSuggestion suggestion) {
    return CaleeListRow(
      key: ValueKey('meal_search_${suggestion.source.name}_${suggestion.id}'),
      leading: Text(
        mealIconEmoji(
          icon: suggestion.icon,
          title: suggestion.name,
          mealType: suggestion.defaultMealType,
        ),
        style: const TextStyle(fontSize: 18),
      ),
      title: suggestion.name,
      subtitle: suggestion.savedTemplate == null
          ? null
          : savedMealMetadata(suggestion.savedTemplate!),
      trailing: const Icon(Icons.chevron_right),
      onTap: () => widget.onTapSuggestion(suggestion),
    );
  }
}

// ─────────────────────────────────────────────
// ManageSavedMealSheet
// ─────────────────────────────────────────────

/// Bottom sheet for editing a household saved meal: rename, notes, favourite
/// toggle, ingredients, delete, and adding it to the current week.
class ManageSavedMealSheet extends StatefulWidget {
  const ManageSavedMealSheet({
    required this.template,
    required this.controller,
    super.key,
  });

  final ClientMealTemplate template;
  final MealsController controller;

  static Future<void> show({
    required BuildContext context,
    required ClientMealTemplate template,
    required MealsController controller,
  }) {
    return CaleeBottomSheet.show<void>(
      context: context,
      title: 'Edit saved meal',
      child: ManageSavedMealSheet(template: template, controller: controller),
    );
  }

  @override
  State<ManageSavedMealSheet> createState() => _ManageSavedMealSheetState();
}

class _ManageSavedMealSheetState extends State<ManageSavedMealSheet> {
  late final TextEditingController _nameController;
  late final TextEditingController _notesController;
  late bool _isFavourite;
  bool _isSaving = false;
  String? _error;

  List<ClientTemplateIngredient> _ingredients = [];
  bool _loadingIngredients = true;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.template.name);
    _notesController = TextEditingController(text: widget.template.notes ?? '');
    _isFavourite = widget.template.isFavourite;
    _loadIngredients();
  }

  Future<void> _loadIngredients() async {
    try {
      final ingredients = await widget.controller.repository
          .mealTemplateIngredients(widget.template.id);
      if (mounted) {
        setState(() {
          _ingredients = ingredients;
          _loadingIngredients = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loadingIngredients = false);
    }
  }

  Future<void> _addIngredient() async {
    final saved = await _ManageIngredientSheet.show(
      context: context,
      controller: widget.controller,
      templateId: widget.template.id,
    );
    if (saved != null && mounted) {
      setState(() => _ingredients = [..._ingredients, saved]);
    }
  }

  Future<void> _editIngredient(ClientTemplateIngredient ingredient) async {
    final saved = await _ManageIngredientSheet.show(
      context: context,
      controller: widget.controller,
      templateId: widget.template.id,
      ingredient: ingredient,
    );
    if (saved != null && mounted) {
      setState(() {
        _ingredients = [
          for (final existing in _ingredients)
            existing.id == saved.id ? saved : existing,
        ];
      });
    }
  }

  Future<void> _deleteIngredient(ClientTemplateIngredient ingredient) async {
    final confirmed = await CaleeDestructiveDialog.show(
      context: context,
      title: 'Delete ingredient?',
      body: 'Remove "${ingredient.name}" from this saved meal?',
      confirmLabel: 'Delete',
    );
    if (!confirmed || !mounted) return;

    try {
      await widget.controller.repository.deleteMealTemplateIngredient(
        templateId: widget.template.id,
        ingredientId: ingredient.id,
      );
      if (mounted) {
        setState(() {
          _ingredients = _ingredients
              .where((existing) => existing.id != ingredient.id)
              .toList();
        });
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              _friendlyErrorText(e, 'Could not delete ingredient.'),
            ),
          ),
        );
      }
    }
  }

  @override
  void dispose() {
    _nameController.dispose();
    _notesController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final name = _nameController.text.trim();
    if (name.isEmpty) {
      setState(() => _error = 'Please enter a name');
      return;
    }
    setState(() {
      _isSaving = true;
      _error = null;
    });
    try {
      await widget.controller.repository.updateMealTemplate(
        templateId: widget.template.id,
        name: name,
        notes: _notesController.text.trim(),
        isFavourite: _isFavourite,
      );
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) {
        setState(() {
          _isSaving = false;
          _error = _friendlyErrorText(
            e,
            'Could not save changes. Please try again.',
          );
        });
      }
    }
  }

  Future<void> _delete() async {
    final confirmed = await CaleeDestructiveDialog.show(
      context: context,
      title: 'Delete saved meal?',
      body: 'Remove "${widget.template.name}" from your saved meals?',
      confirmLabel: 'Delete',
    );
    if (!confirmed || !mounted) return;

    setState(() {
      _isSaving = true;
      _error = null;
    });
    try {
      await widget.controller.repository.deleteMealTemplate(widget.template.id);
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) {
        setState(() {
          _isSaving = false;
          _error = _friendlyErrorText(
            e,
            'Could not delete this saved meal. Please try again.',
          );
        });
      }
    }
  }

  Future<void> _addToWeek() async {
    final result = await AddSavedMealToWeekSheet.show(
      context: context,
      title: widget.template.name,
      defaultMealType: widget.template.defaultMealType,
      weekStart: widget.controller.weekStart,
      weekEnd: widget.controller.weekEnd,
    );
    if (result == null || !mounted) return;
    try {
      await widget.controller.createMeal(
        mealDate: result.mealDate,
        mealType: result.mealType,
        title: widget.template.name,
        notes: widget.template.notes,
        templateId: widget.template.id,
      );
      if (mounted) {
        Navigator.of(context).pop();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Added "${widget.template.name}" to this week.'),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not add meal to the week.')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          CaleeSection(
            children: [
              CaleeSectionTextFormField(
                controller: _nameController,
                hintText: 'Meal name',
                enabled: !_isSaving,
                textInputAction: TextInputAction.next,
              ),
              CaleeSectionTextFormField(
                controller: _notesController,
                hintText: 'Notes (optional)',
                enabled: !_isSaving,
                maxLines: 3,
                minLines: 1,
                textInputAction: TextInputAction.done,
              ),
              CaleeSectionSwitchRow(
                label: 'Favourite',
                value: _isFavourite,
                enabled: !_isSaving,
                onChanged: (value) => setState(() => _isFavourite = value),
              ),
            ],
          ),
          const SizedBox(height: CaleeSpacing.md),
          CaleeSection(
            title: 'Ingredients',
            children: [
              if (_loadingIngredients)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: CaleeSpacing.md),
                  child: Center(
                    child: SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  ),
                )
              else if (_ingredients.isEmpty)
                const CaleeListRow(
                  title: 'No ingredients yet',
                  subtitle:
                      'Add ingredients to build grocery lists from this meal.',
                )
              else
                for (final ingredient in _ingredients)
                  CaleeListRow(
                    title: ingredient.name,
                    subtitle: _ingredientSubtitle(ingredient),
                    onTap: _isSaving ? null : () => _editIngredient(ingredient),
                    trailing: IconButton(
                      icon: const Icon(
                        Icons.close,
                        size: 18,
                        color: CaleeColors.textTertiary,
                      ),
                      onPressed: _isSaving
                          ? null
                          : () => _deleteIngredient(ingredient),
                    ),
                  ),
              CaleeListRow(
                title: 'Add ingredient',
                leading: const Icon(
                  Icons.add,
                  color: CaleeColors.primary,
                  size: 20,
                ),
                titleStyle: const TextStyle(
                  color: CaleeColors.primary,
                  fontSize: 16,
                ),
                onTap: _isSaving ? null : _addIngredient,
              ),
            ],
          ),
          if (_error != null) ...[
            const SizedBox(height: CaleeSpacing.sm),
            Text(
              _error!,
              style: const TextStyle(
                fontSize: 13,
                color: CaleeColors.destructive,
              ),
              textAlign: TextAlign.center,
            ),
          ],
          const SizedBox(height: CaleeSpacing.md),
          FilledButton(
            onPressed: _isSaving ? null : _save,
            child: _isSaving
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                : const Text('Save'),
          ),
          const SizedBox(height: CaleeSpacing.sm),
          OutlinedButton.icon(
            onPressed: _isSaving ? null : _addToWeek,
            icon: const Icon(Icons.calendar_today, size: 18),
            label: const Text('Add to this week'),
          ),
          const SizedBox(height: CaleeSpacing.sm),
          OutlinedButton(
            onPressed: _isSaving ? null : _delete,
            style: OutlinedButton.styleFrom(
              foregroundColor: CaleeColors.destructive,
              side: const BorderSide(color: CaleeColors.destructive),
            ),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────
// _ManageIngredientSheet
// ─────────────────────────────────────────────

/// Bottom sheet for adding or editing a single ingredient on a household
/// saved meal. Passing [ingredient] edits it in place; omitting it creates a
/// new one. Pops the saved [ClientTemplateIngredient] on success.
///
// TODO: quantityText is a plain free-text field today (e.g. "500g"). Future:
// household default serving count, a per-saved-meal serving count, and
// scaling this quantity relative to servings. Not implemented yet.
class _ManageIngredientSheet extends StatefulWidget {
  const _ManageIngredientSheet({
    required this.controller,
    required this.templateId,
    this.ingredient,
  });

  final MealsController controller;
  final int templateId;
  final ClientTemplateIngredient? ingredient;

  static Future<ClientTemplateIngredient?> show({
    required BuildContext context,
    required MealsController controller,
    required int templateId,
    ClientTemplateIngredient? ingredient,
  }) {
    return CaleeBottomSheet.show<ClientTemplateIngredient?>(
      context: context,
      title: ingredient == null ? 'Add ingredient' : 'Edit ingredient',
      child: _ManageIngredientSheet(
        controller: controller,
        templateId: templateId,
        ingredient: ingredient,
      ),
    );
  }

  @override
  State<_ManageIngredientSheet> createState() => _ManageIngredientSheetState();
}

class _ManageIngredientSheetState extends State<_ManageIngredientSheet> {
  late final TextEditingController _nameController;
  late final TextEditingController _quantityController;
  late final TextEditingController _categoryController;
  bool _isSaving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(
      text: widget.ingredient?.name ?? '',
    );
    _quantityController = TextEditingController(
      text: widget.ingredient?.quantityText ?? '',
    );
    _categoryController = TextEditingController(
      text: widget.ingredient?.category ?? '',
    );
  }

  @override
  void dispose() {
    _nameController.dispose();
    _quantityController.dispose();
    _categoryController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final name = _nameController.text.trim();
    if (name.isEmpty) {
      setState(() => _error = 'Please enter an ingredient name');
      return;
    }
    setState(() {
      _isSaving = true;
      _error = null;
    });

    final quantityText = _quantityController.text.trim();
    final category = _categoryController.text.trim();

    try {
      final existing = widget.ingredient;
      final saved = existing == null
          ? await widget.controller.repository.addMealTemplateIngredient(
              templateId: widget.templateId,
              name: name,
              quantityText: quantityText.isEmpty ? null : quantityText,
              category: category.isEmpty ? null : category,
            )
          : await widget.controller.repository.updateMealTemplateIngredient(
              templateId: widget.templateId,
              ingredientId: existing.id,
              name: name,
              quantityText: quantityText.isEmpty ? null : quantityText,
              category: category.isEmpty ? null : category,
            );
      if (mounted) Navigator.of(context).pop(saved);
    } catch (e) {
      if (mounted) {
        setState(() {
          _isSaving = false;
          _error = _friendlyErrorText(e, 'Could not save ingredient.');
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          CaleeSection(
            children: [
              CaleeSectionTextFormField(
                controller: _nameController,
                hintText: 'Ingredient name',
                enabled: !_isSaving,
                autofocus: widget.ingredient == null,
                textInputAction: TextInputAction.next,
              ),
              CaleeSectionTextFormField(
                controller: _quantityController,
                hintText: 'Quantity optional',
                enabled: !_isSaving,
                textInputAction: TextInputAction.next,
              ),
              CaleeSectionTextFormField(
                controller: _categoryController,
                hintText: 'Category optional',
                enabled: !_isSaving,
                textInputAction: TextInputAction.done,
              ),
            ],
          ),
          if (_error != null) ...[
            const SizedBox(height: CaleeSpacing.sm),
            Text(
              _error!,
              style: const TextStyle(
                fontSize: 13,
                color: CaleeColors.destructive,
              ),
              textAlign: TextAlign.center,
            ),
          ],
          const SizedBox(height: CaleeSpacing.md),
          FilledButton(
            onPressed: _isSaving ? null : _save,
            child: _isSaving
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                : const Text('Save'),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────
// CreateSavedMealSheet
// ─────────────────────────────────────────────

/// Bottom sheet for creating a brand-new household saved meal.
class CreateSavedMealSheet extends StatefulWidget {
  const CreateSavedMealSheet({required this.controller, super.key});

  final MealsController controller;

  /// Returns true if a saved meal was created, false if the sheet was
  /// dismissed without saving.
  static Future<bool> show({
    required BuildContext context,
    required MealsController controller,
  }) async {
    final created = await CaleeBottomSheet.show<bool>(
      context: context,
      title: 'Create saved meal',
      child: CreateSavedMealSheet(controller: controller),
    );
    return created ?? false;
  }

  @override
  State<CreateSavedMealSheet> createState() => _CreateSavedMealSheetState();
}

class _CreateSavedMealSheetState extends State<CreateSavedMealSheet> {
  final _nameController = TextEditingController();
  final _notesController = TextEditingController();
  String _mealType = 'dinner';
  bool _isFavourite = false;
  bool _isSaving = false;
  String? _error;

  @override
  void dispose() {
    _nameController.dispose();
    _notesController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final name = _nameController.text.trim();
    if (name.isEmpty) {
      setState(() => _error = 'Please enter a name');
      return;
    }
    setState(() {
      _isSaving = true;
      _error = null;
    });
    try {
      await widget.controller.repository.createMealTemplate(
        name: name,
        defaultMealType: _mealType,
        notes: _notesController.text.trim(),
        isFavourite: _isFavourite,
      );
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) {
        setState(() {
          _isSaving = false;
          _error = _friendlyErrorText(
            e,
            'Could not create saved meal. Please try again.',
          );
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          CaleeSection(
            children: [
              CaleeSectionTextFormField(
                controller: _nameController,
                hintText: 'Meal name',
                enabled: !_isSaving,
                textInputAction: TextInputAction.next,
              ),
              CaleeSectionDropdownRow<String>(
                label: 'Meal type',
                value: _mealType,
                enabled: !_isSaving,
                items: _kMealTypeOrder
                    .map(
                      (type) => DropdownMenuItem(
                        value: type,
                        child: Text(_kMealTypeLabels[type] ?? type),
                      ),
                    )
                    .toList(),
                onChanged: (value) {
                  if (value != null) setState(() => _mealType = value);
                },
              ),
              CaleeSectionTextFormField(
                controller: _notesController,
                hintText: 'Notes (optional)',
                enabled: !_isSaving,
                maxLines: 3,
                minLines: 1,
                textInputAction: TextInputAction.done,
              ),
              CaleeSectionSwitchRow(
                label: 'Favourite',
                value: _isFavourite,
                enabled: !_isSaving,
                onChanged: (value) => setState(() => _isFavourite = value),
              ),
            ],
          ),
          if (_error != null) ...[
            const SizedBox(height: CaleeSpacing.sm),
            Text(
              _error!,
              style: const TextStyle(
                fontSize: 13,
                color: CaleeColors.destructive,
              ),
              textAlign: TextAlign.center,
            ),
          ],
          const SizedBox(height: CaleeSpacing.md),
          FilledButton(
            onPressed: _isSaving ? null : _save,
            child: _isSaving
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                : const Text('Save'),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────
// QuickDinnerIdeaSheet
// ─────────────────────────────────────────────

/// Read-only detail sheet for a Calee-provided quick dinner idea (starter
/// template). Only lets the user add it to the week — starter ideas cannot
/// be renamed, edited or deleted from CaleeMobile.
class QuickDinnerIdeaSheet extends StatefulWidget {
  const QuickDinnerIdeaSheet({
    required this.template,
    required this.controller,
    super.key,
  });

  final ClientStarterMealTemplate template;
  final MealsController controller;

  static Future<void> show({
    required BuildContext context,
    required ClientStarterMealTemplate template,
    required MealsController controller,
  }) {
    return CaleeBottomSheet.show<void>(
      context: context,
      title: 'Quick dinner idea',
      child: QuickDinnerIdeaSheet(template: template, controller: controller),
    );
  }

  @override
  State<QuickDinnerIdeaSheet> createState() => _QuickDinnerIdeaSheetState();
}

class _QuickDinnerIdeaSheetState extends State<QuickDinnerIdeaSheet> {
  bool _isAdding = false;

  Future<void> _addToWeek() async {
    final result = await AddSavedMealToWeekSheet.show(
      context: context,
      title: widget.template.name,
      defaultMealType: widget.template.defaultMealType,
      weekStart: widget.controller.weekStart,
      weekEnd: widget.controller.weekEnd,
    );
    if (result == null || !mounted) return;

    setState(() => _isAdding = true);
    try {
      await widget.controller.createMeal(
        mealDate: result.mealDate,
        mealType: result.mealType,
        title: widget.template.name,
        notes: widget.template.notes,
        starterTemplateId: widget.template.id,
      );
      if (mounted) {
        Navigator.of(context).pop();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Added "${widget.template.name}" to this week.'),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isAdding = false);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not add meal to the week.')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final notes = widget.template.notes;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        CaleeSection(
          children: [
            CaleeListRow(
              leading: Text(
                mealIconEmoji(
                  icon: widget.template.icon,
                  title: widget.template.name,
                  mealType: widget.template.defaultMealType,
                ),
                style: const TextStyle(fontSize: 18),
              ),
              title: widget.template.name,
              subtitle: notes != null && notes.isNotEmpty ? notes : null,
              trailing: const SizedBox.shrink(),
            ),
          ],
        ),
        if (widget.template.ingredients.isNotEmpty) ...[
          const SizedBox(height: CaleeSpacing.md),
          CaleeSection(
            title: 'Ingredients',
            children: [
              for (final ingredient in widget.template.ingredients)
                CaleeListRow(
                  title: ingredient.name,
                  subtitle: _ingredientSubtitle(ingredient),
                ),
            ],
          ),
        ],
        const SizedBox(height: CaleeSpacing.sm),
        const Text(
          "Quick dinner ideas come from Calee's starter library and can't be edited.",
          style: TextStyle(fontSize: 13, color: CaleeColors.textSecondary),
        ),
        const SizedBox(height: CaleeSpacing.md),
        FilledButton.icon(
          onPressed: _isAdding ? null : _addToWeek,
          icon: _isAdding
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.white,
                  ),
                )
              : const Icon(Icons.calendar_today, size: 18),
          label: const Text('Add to this week'),
        ),
      ],
    );
  }
}

// ─────────────────────────────────────────────
// AddSavedMealToWeekSheet
// ─────────────────────────────────────────────

class AddToWeekResult {
  const AddToWeekResult({required this.mealDate, required this.mealType});

  final String mealDate;
  final String mealType;
}

/// Small sheet to pick a date and meal type before adding a saved meal or
/// quick dinner idea to the current week. Mirrors the date/meal-type pickers
/// used by [AddMealSheet].
class AddSavedMealToWeekSheet extends StatefulWidget {
  const AddSavedMealToWeekSheet({
    required this.title,
    required this.defaultMealType,
    required this.weekStart,
    required this.weekEnd,
    super.key,
  });

  final String title;
  final String defaultMealType;

  /// Bounds of the week currently visible on the Meals page, used to default
  /// the date picker so "Add to this week" lands in the week the user is
  /// looking at rather than always defaulting to today.
  final DateTime weekStart;
  final DateTime weekEnd;

  static Future<AddToWeekResult?> show({
    required BuildContext context,
    required String title,
    required String defaultMealType,
    required DateTime weekStart,
    required DateTime weekEnd,
  }) {
    return CaleeBottomSheet.show<AddToWeekResult>(
      context: context,
      title: 'Add to this week',
      child: AddSavedMealToWeekSheet(
        title: title,
        defaultMealType: defaultMealType,
        weekStart: weekStart,
        weekEnd: weekEnd,
      ),
    );
  }

  @override
  State<AddSavedMealToWeekSheet> createState() =>
      _AddSavedMealToWeekSheetState();
}

class _AddSavedMealToWeekSheetState extends State<AddSavedMealToWeekSheet> {
  late DateTime _date;
  late String _mealType;

  @override
  void initState() {
    super.initState();
    final today = DateTime.now();
    final todayDate = DateTime(today.year, today.month, today.day);
    final withinVisibleWeek =
        !todayDate.isBefore(widget.weekStart) &&
        !todayDate.isAfter(widget.weekEnd);
    _date = withinVisibleWeek ? todayDate : widget.weekStart;
    _mealType = _kMealTypeOrder.contains(widget.defaultMealType)
        ? widget.defaultMealType
        : 'dinner';
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _date,
      firstDate: DateTime(_date.year - 1),
      lastDate: DateTime(_date.year + 5),
    );
    if (picked != null && mounted) {
      setState(() => _date = picked);
    }
  }

  String _fmt(DateTime d) {
    final y = d.year.toString().padLeft(4, '0');
    final m = d.month.toString().padLeft(2, '0');
    final day = d.day.toString().padLeft(2, '0');
    return '$y-$m-$day';
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          widget.title,
          style: const TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w600,
            color: CaleeColors.textPrimary,
          ),
        ),
        const SizedBox(height: CaleeSpacing.md),
        CaleeSection(
          children: [
            CaleeSectionPickerRow(
              label: 'Date',
              value: _fmt(_date),
              onTap: _pickDate,
            ),
            CaleeSectionDropdownRow<String>(
              label: 'Meal type',
              value: _mealType,
              items: _kMealTypeOrder
                  .map(
                    (type) => DropdownMenuItem(
                      value: type,
                      child: Text(_kMealTypeLabels[type] ?? type),
                    ),
                  )
                  .toList(),
              onChanged: (value) {
                if (value != null) setState(() => _mealType = value);
              },
            ),
          ],
        ),
        const SizedBox(height: CaleeSpacing.md),
        FilledButton(
          onPressed: () => Navigator.of(
            context,
          ).pop(AddToWeekResult(mealDate: _fmt(_date), mealType: _mealType)),
          child: const Text('Add to this week'),
        ),
      ],
    );
  }
}
