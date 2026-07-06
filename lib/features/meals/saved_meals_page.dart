import 'package:flutter/material.dart';

import '../../data/api/calee_hub_client.dart';
import '../../data/models/client_meal.dart';
import '../../data/models/client_shopping_list.dart';
import '../../shared/meal_icon.dart';
import '../../ui/calee_design.dart';
import 'meals_controller.dart';

const _kMealTypeLabels = {
  'breakfast': 'Breakfast',
  'lunch': 'Lunch',
  'dinner': 'Dinner',
};

const _kMealTypeOrder = ['breakfast', 'lunch', 'dinner'];

/// Recent-meals section shows at most this many non-favourite household
/// templates, most-recently-used first.
const _kMaxRecentMeals = 5;

/// Human-readable usage/favourite metadata for a household saved meal, shown
/// as a [CaleeListRow] subtitle. Shared with [PickDinnerSheet] so the two
/// surfaces read consistently.
String? savedMealMetadata(ClientMealTemplate template) {
  if (template.usageCount <= 0) return null;
  final n = template.usageCount;
  return 'Used $n time${n == 1 ? '' : 's'}';
}

/// Full-screen Saved Meals management view, reached from the Meals page top
/// bar. Lists the household's own saved meals ("Family favourites" and
/// "Recent meals", both editable) alongside Calee's shared starter ideas
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

class _SavedMealsOptions {
  const _SavedMealsOptions({
    required this.allSaved,
    required this.favourites,
    required this.recents,
    required this.quickIdeas,
  });

  /// All household templates (favourites + non-favourites), used for local
  /// search across the full saved-meals list rather than just the
  /// (possibly truncated) sections shown on screen.
  final List<ClientMealTemplate> allSaved;
  final List<ClientMealTemplate> favourites;
  final List<ClientMealTemplate> recents;
  final List<ClientStarterMealTemplate> quickIdeas;
}

class _SavedMealsPageState extends State<SavedMealsPage> {
  late Future<_SavedMealsOptions> _future;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<_SavedMealsOptions> _load() async {
    final repository = widget.controller.repository;
    final results = await Future.wait([
      repository.mealTemplates(),
      repository.mealStarterTemplates(mealType: 'dinner'),
    ]);
    final templates = (results[0] as ClientMealTemplateList).templates;
    final favourites = templates.where((t) => t.isFavourite).toList();
    final recents = templates
        .where((t) => !t.isFavourite && t.usageCount > 0)
        .toList();
    // The API doesn't guarantee ordering, so sort client-side: most recently
    // used first, then most used, then alphabetically.
    recents.sort((a, b) {
      final aUsed = a.lastUsedAt;
      final bUsed = b.lastUsedAt;
      if (aUsed != bUsed) {
        if (aUsed == null) return 1;
        if (bUsed == null) return -1;
        final cmp = bUsed.compareTo(aUsed);
        if (cmp != 0) return cmp;
      }
      final usageCmp = b.usageCount.compareTo(a.usageCount);
      if (usageCmp != 0) return usageCmp;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    return _SavedMealsOptions(
      allSaved: templates,
      favourites: favourites,
      recents: recents.take(_kMaxRecentMeals).toList(),
      quickIdeas: results[1] as List<ClientStarterMealTemplate>,
    );
  }

  void _reload() {
    setState(() {
      _future = _load();
    });
  }

  Future<void> _openSearchSheet() async {
    final data = await _future.catchError((_) {
      return const _SavedMealsOptions(
        allSaved: [],
        favourites: [],
        recents: [],
        quickIdeas: [],
      );
    });
    if (!mounted) return;
    await CaleeBottomSheet.show<void>(
      context: context,
      title: 'Search saved meals',
      child: _SavedMealsSearchSheet(
        templates: data.allSaved,
        onTapTemplate: (template) {
          Navigator.of(context).pop();
          _openManageSheet(template);
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
          child: FutureBuilder<_SavedMealsOptions>(
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
      ],
    );
  }

  Widget _buildContent(_SavedMealsOptions options) {
    final noSavedMealsYet =
        options.favourites.isEmpty && options.recents.isEmpty;
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
          const SizedBox(height: CaleeSpacing.sectionSpacing),
        ],
        CaleeSection(
          title: 'Family favourites',
          children: options.favourites.isEmpty
              ? [_mutedRow('No family favourites yet')]
              : options.favourites.map(_favouriteRow).toList(),
        ),
        const SizedBox(height: CaleeSpacing.sectionSpacing),
        CaleeSection(
          title: 'Recent meals',
          children: options.recents.isEmpty
              ? [_mutedRow('No recent meals yet')]
              : options.recents.map(_recentRow).toList(),
        ),
        const SizedBox(height: CaleeSpacing.sectionSpacing),
        CaleeSection(
          title: 'Quick dinner ideas',
          footer: "Calee's starter ideas — tap Add to this week to use one.",
          children: options.quickIdeas.isEmpty
              ? [_mutedRow('No quick dinner ideas yet')]
              : options.quickIdeas.map(_quickIdeaRow).toList(),
        ),
        const SizedBox(height: CaleeSpacing.lg),
      ],
    );
  }

  Widget _favouriteRow(ClientMealTemplate template) {
    return CaleeListRow(
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

  Widget _recentRow(ClientMealTemplate template) {
    return CaleeListRow(
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

  Widget _quickIdeaRow(ClientStarterMealTemplate template) {
    return CaleeListRow(
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

  Widget _mutedRow(String text) {
    return CaleeListRow(
      title: text,
      titleStyle: const TextStyle(
        fontSize: 14,
        color: CaleeColors.textSecondary,
      ),
    );
  }
}

// ─────────────────────────────────────────────
// Search
// ─────────────────────────────────────────────

class _SavedMealsSearchSheet extends StatefulWidget {
  const _SavedMealsSearchSheet({
    required this.templates,
    required this.onTapTemplate,
  });

  final List<ClientMealTemplate> templates;
  final ValueChanged<ClientMealTemplate> onTapTemplate;

  @override
  State<_SavedMealsSearchSheet> createState() => _SavedMealsSearchSheetState();
}

class _SavedMealsSearchSheetState extends State<_SavedMealsSearchSheet> {
  final _controller = TextEditingController();
  List<ClientMealTemplate> _results = [];

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
    final q = _controller.text.trim().toLowerCase();
    setState(() {
      _results = q.isEmpty
          ? []
          : widget.templates
                .where(
                  (t) =>
                      t.name.toLowerCase().contains(q) ||
                      (t.notes ?? '').toLowerCase().contains(q),
                )
                .toList();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          controller: _controller,
          autofocus: true,
          textInputAction: TextInputAction.search,
          decoration: InputDecoration(
            hintText: 'Search saved meals by name…',
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
        if (_controller.text.trim().isEmpty)
          Padding(
            padding: const EdgeInsets.all(CaleeSpacing.lg),
            child: Text(
              'Type to search',
              textAlign: TextAlign.center,
              style: const TextStyle(color: CaleeColors.textTertiary),
            ),
          )
        else if (_results.isEmpty)
          Padding(
            padding: const EdgeInsets.all(CaleeSpacing.lg),
            child: Text(
              'No saved meals found',
              textAlign: TextAlign.center,
              style: const TextStyle(color: CaleeColors.textTertiary),
            ),
          )
        else
          CaleeSection(
            children: _results
                .map(
                  (t) => CaleeListRow(
                    leading: Text(
                      mealIconEmoji(
                        icon: t.icon,
                        title: t.name,
                        mealType: t.defaultMealType,
                      ),
                      style: const TextStyle(fontSize: 18),
                    ),
                    title: t.name,
                    subtitle: savedMealMetadata(t),
                    onTap: () => widget.onTapTemplate(t),
                  ),
                )
                .toList(),
          ),
      ],
    );
  }
}

// ─────────────────────────────────────────────
// ManageSavedMealSheet
// ─────────────────────────────────────────────

/// Bottom sheet for editing a household saved meal: rename, notes, favourite
/// toggle, delete, and adding it to the current week.
///
/// Future: manage ingredients for saved meals — [ClientMealTemplate] doesn't
/// carry ingredient data from the API yet, so there's nothing to edit here.
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

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.template.name);
    _notesController = TextEditingController(text: widget.template.notes ?? '');
    _isFavourite = widget.template.isFavourite;
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
          _error = e.toString();
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
          _error = e.toString();
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
          _error = e.toString();
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
