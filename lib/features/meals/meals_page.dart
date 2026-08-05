import 'package:flutter/material.dart';

import '../../data/api/calee_hub_client.dart';
import '../../data/models/client_meal.dart';
import '../../data/models/client_shopping_list.dart';
import '../../shared/meal_icon.dart';
import '../../ui/calee_design.dart';
import '../shopping/shopping_page.dart';
import 'meals_controller.dart';
import 'meals_repository.dart';
import 'saved_meals_page.dart';

/// Stable identity for the meal-plan scroll container.
///
/// Exported so tests (unit and integration) can target the real product list
/// rather than picking a Scrollable positionally: `.first`/`.last` resolve to
/// whichever container happens to come first in the tree, and both throw
/// `Bad state: No element` when evaluated while the list is rebuilding.
const Key mealsListKey = Key('meals-list');

const _kMealTypeLabels = {
  'breakfast': 'Breakfast',
  'lunch': 'Lunch',
  'dinner': 'Dinner',
};

const _kMealTypeEmoji = {'breakfast': '🍳', 'lunch': '🥪', 'dinner': '🍽'};

const _kMealTypeOrder = ['breakfast', 'lunch', 'dinner'];

const _kWeekdayShort = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

const _kMonths = [
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];

String _fmt(DateTime d) {
  final y = d.year.toString().padLeft(4, '0');
  final m = d.month.toString().padLeft(2, '0');
  final day = d.day.toString().padLeft(2, '0');
  return '$y-$m-$day';
}

String _formatDateLabel(String date) {
  final parts = date.split('-');
  if (parts.length != 3) return date;
  final d = int.tryParse(parts[2]) ?? 0;
  final m = int.tryParse(parts[1]) ?? 0;
  const months = [
    '',
    'January',
    'February',
    'March',
    'April',
    'May',
    'June',
    'July',
    'August',
    'September',
    'October',
    'November',
    'December',
  ];
  final month = m >= 1 && m <= 12 ? months[m] : '';
  return '$d $month ${parts[0]}';
}

String _weekRangeLabel(DateTime start, DateTime end) {
  if (start.month == end.month) {
    return '${start.day}–${end.day} ${_kMonths[start.month - 1]} ${start.year}';
  }
  return '${start.day} ${_kMonths[start.month - 1]} – ${end.day} ${_kMonths[end.month - 1]} ${start.year}';
}

class MealsPage extends StatefulWidget {
  const MealsPage({
    required this.hubClient,
    required this.accessToken,
    super.key,
  });

  final CaleeHubClient hubClient;
  final String accessToken;

  @override
  State<MealsPage> createState() => _MealsPageState();
}

class _MealsPageState extends State<MealsPage> {
  late final MealsController _controller;

  @override
  void initState() {
    super.initState();
    _controller = MealsController(
      repository: MealsRepository(
        hubClient: widget.hubClient,
        accessToken: widget.accessToken,
      ),
    );
    _controller.addListener(_onControllerChanged);
    _controller.load();
  }

  @override
  void dispose() {
    _controller.removeListener(_onControllerChanged);
    _controller.dispose();
    super.dispose();
  }

  void _onControllerChanged() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return CaleeScaffold(
      key: const Key('meals_plan_root'),
      appBar: _buildTopBar(),
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: _controller.load,
          child: _buildBody(),
        ),
      ),
    );
  }

  PreferredSizeWidget _buildTopBar() {
    return PreferredSize(
      preferredSize: const Size.fromHeight(64),
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            CaleeSpacing.md,
            CaleeSpacing.xs,
            CaleeSpacing.xs,
            CaleeSpacing.xs,
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              const Expanded(
                child: Text(
                  'Meals',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w600,
                    color: CaleeColors.textPrimary,
                  ),
                ),
              ),
              IconButton(
                onPressed: _openSearchSheet,
                icon: const Icon(Icons.search),
                iconSize: 22,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
                color: CaleeColors.primary,
                tooltip: 'Search meals',
              ),
              IconButton(
                onPressed: _openSavedMeals,
                icon: const Icon(Icons.bookmark_outline),
                iconSize: 22,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
                color: CaleeColors.primary,
                tooltip: 'Saved meals',
              ),
              IconButton(
                onPressed: _showShoppingActions,
                icon: const Icon(Icons.shopping_cart_outlined),
                iconSize: 22,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
                color: CaleeColors.primary,
                tooltip: 'Shopping',
              ),
              IconButton(
                onPressed: (_controller.isCopying || _controller.isLoading)
                    ? null
                    : _showCopyWeekSheet,
                icon: const Icon(Icons.content_copy),
                iconSize: 22,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
                color: CaleeColors.primary,
                tooltip: 'Copy last week',
              ),
              IconButton(
                key: const Key('meals_add_button'),
                onPressed: _openAddMealSheet,
                icon: const Icon(Icons.add),
                iconSize: 22,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
                color: CaleeColors.primary,
                tooltip: 'Add meal',
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBody() {
    return ListView(
      // Stable identity for the meal-plan scroll container, kept mounted
      // across week changes (the loading state is a child, not a replacement).
      // The regression suite scrolls this list by key rather than resolving
      // `find.byType(Scrollable)` positionally, which selects the wrong
      // container as soon as the page holds more than one.
      key: mealsListKey,
      padding: const EdgeInsets.symmetric(
        horizontal: CaleeSpacing.pagePadding,
        vertical: CaleeSpacing.md,
      ),
      children: [
        _buildWeekSelector(),
        const SizedBox(height: CaleeSpacing.md),
        ..._buildContent(),
        const SizedBox(height: CaleeSpacing.lg),
      ],
    );
  }

  List<Widget> _buildContent() {
    if (_controller.isLoading && _controller.mealList == null) {
      return [
        const Center(
          child: Padding(
            padding: EdgeInsets.all(CaleeSpacing.xl),
            child: CircularProgressIndicator(),
          ),
        ),
      ];
    }

    if (_controller.error != null && _controller.mealList == null) {
      return [_buildError()];
    }

    final days = _weekDays();
    return [
      for (var i = 0; i < days.length; i++) ...[
        if (i > 0) const SizedBox(height: CaleeSpacing.sectionSpacing),
        _buildDaySection(days[i]),
      ],
    ];
  }

  // There is no non-mutating way to ask the backend "does a shopping list
  // exist for this week?" — the current-list endpoint gets-or-creates one,
  // so probing it here just to decide whether to show "Open shopping list"
  // would create an empty list as a side effect. Always show both actions
  // instead; ShoppingPage renders a clean empty state when there's nothing
  // to show yet.
  void _showShoppingActions() {
    CaleeActionSheet.show(
      context: context,
      title: 'Shopping',
      actions: [
        CaleeAction(
          label: 'Build grocery list',
          icon: Icons.shopping_cart_outlined,
          onTap: () => _openShoppingList(autoGenerate: true),
        ),
        CaleeAction(
          label: 'Open shopping list',
          icon: Icons.list_alt_outlined,
          onTap: () => _openShoppingList(autoGenerate: false),
        ),
      ],
    );
  }

  void _openAddMealSheet() {
    AddMealSheet.show(context: context, controller: _controller);
  }

  Future<void> _openSavedMeals() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => SavedMealsPage(
          hubClient: widget.hubClient,
          accessToken: widget.accessToken,
          controller: _controller,
        ),
      ),
    );
  }

  // Shopping lists are a sub-feature of meal planning (see ClientBootstrap
  // .supportsMeals), so the Shopping page is reached from here rather than
  // its own bottom-nav tab — Today/Calendar/Tasks/Chores/Meals/Settings
  // already fill the bar for family households with chores enabled.
  Future<void> _openShoppingList({required bool autoGenerate}) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ShoppingPage(
          hubClient: widget.hubClient,
          accessToken: widget.accessToken,
          autoGenerate: autoGenerate,
          initialWeekStart: _controller.weekStart,
          initialWeekEnd: _controller.weekEnd,
        ),
      ),
    );
  }

  void _openSearchSheet() {
    final allMeals = _controller.mealList?.meals ?? const <ClientMeal>[];
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: CaleeColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(CaleeRadius.sheet),
        ),
      ),
      builder: (sheetContext) => _MealSearchSheet(
        meals: allMeals,
        onTapMeal: (meal) {
          Navigator.of(sheetContext).pop();
          _openSheet(date: meal.mealDate, mealType: meal.mealType, meal: meal);
        },
      ),
    );
  }

  Widget _buildWeekSelector() {
    return Row(
      children: [
        IconButton(
          key: const Key('meals_week_previous'),
          icon: const Icon(Icons.chevron_left),
          color: CaleeColors.primary,
          onPressed: _controller.isLoading ? null : _controller.previousWeek,
        ),
        Expanded(
          child: GestureDetector(
            onTap: _controller.isCurrentWeek
                ? null
                : _controller.goToCurrentWeek,
            child: Column(
              children: [
                Text(
                  _weekRangeLabel(_controller.weekStart, _controller.weekEnd),
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: CaleeColors.textPrimary,
                  ),
                ),
                if (!_controller.isCurrentWeek)
                  const Text(
                    'Tap to go to current week',
                    style: TextStyle(fontSize: 11, color: CaleeColors.primary),
                  ),
              ],
            ),
          ),
        ),
        IconButton(
          key: const Key('meals_week_next'),
          icon: const Icon(Icons.chevron_right),
          color: CaleeColors.primary,
          onPressed: _controller.isLoading ? null : _controller.nextWeek,
        ),
      ],
    );
  }

  Future<void> _showCopyWeekSheet() async {
    final overwrite = await _CopyWeekSheet.show(context: context);
    if (overwrite == null || !mounted) return;
    try {
      final result = await _controller.copyPreviousWeekToVisibleWeek(
        overwriteExisting: overwrite,
      );
      if (mounted) _onCopyResult(result);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(e.toString())));
      }
    }
  }

  void _onCopyResult(ClientMealCopyWeekResult result) {
    if (!mounted) return;
    final String msg;
    if (result.count == 0) {
      msg = 'Nothing to copy.';
    } else if (result.skippedCount > 0) {
      final n = result.count;
      final s = result.skippedCount;
      msg = 'Copied $n meal${n != 1 ? 's' : ''}. Skipped $s already planned.';
    } else {
      final n = result.count;
      msg = 'Copied $n meal${n != 1 ? 's' : ''}.';
    }
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  // ── Day sections ─────────────────────────────────────────────────────────

  List<DateTime> _weekDays() => List.generate(
    7,
    (i) => DateTime(
      _controller.weekStart.year,
      _controller.weekStart.month,
      _controller.weekStart.day + i,
    ),
  );

  Widget _buildDaySection(DateTime day) {
    final dateStr = _fmt(day);

    return CaleeSection(
      title: _dayTitle(day),
      children: _kMealTypeOrder
          .map((mealType) => _buildMealRow(dateStr, mealType))
          .toList(),
    );
  }

  Widget _buildMealRow(String dateStr, String mealType) {
    final meal = _controller.mealFor(dateStr, mealType);
    final emoji = _kMealTypeEmoji[mealType] ?? '';
    final label = _kMealTypeLabels[mealType] ?? mealType;

    final Widget valueText;
    if (meal == null) {
      valueText = Text(
        'Add $mealType',
        style: const TextStyle(fontSize: 15, color: CaleeColors.textSecondary),
      );
    } else {
      valueText = Text(
        meal.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 15, color: CaleeColors.textPrimary),
      );
    }

    return CaleeListRow(
      key: ValueKey('meal_row_${dateStr}_$mealType'),
      leading: Text(emoji, style: const TextStyle(fontSize: 18)),
      title: label,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(child: valueText),
          const SizedBox(width: CaleeSpacing.xs),
          const Icon(
            Icons.chevron_right,
            size: 20,
            color: CaleeColors.textTertiary,
          ),
        ],
      ),
      onTap: () => _onMealRowTap(dateStr, mealType, meal),
    );
  }

  void _onMealRowTap(String dateStr, String mealType, ClientMeal? meal) {
    if (meal != null) {
      _openSheet(date: dateStr, mealType: mealType, meal: meal);
      return;
    }
    if (mealType == 'dinner') {
      _openPickDinnerSheet(dateStr);
    } else {
      _openSheet(date: dateStr, mealType: mealType, meal: null);
    }
  }

  Future<void> _openPickDinnerSheet(String date) async {
    final result = await PickDinnerSheet.show(
      context: context,
      date: date,
      controller: _controller,
    );
    if (result == 'create_new' && mounted) {
      await _openSheet(date: date, mealType: 'dinner', meal: null);
    }
  }

  String _dayTitle(DateTime day) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final tomorrow = today.add(const Duration(days: 1));
    final dayDate = DateTime(day.year, day.month, day.day);

    if (dayDate == today) return 'Today';
    if (dayDate == tomorrow) return 'Tomorrow';

    final weekday = _kWeekdayShort[day.weekday - 1];
    final month = _kMonths[day.month - 1];
    return '$weekday, ${day.day} $month';
  }

  Widget _buildError() {
    return Padding(
      padding: const EdgeInsets.all(CaleeSpacing.xl),
      child: Column(
        children: [
          const Icon(
            Icons.error_outline,
            size: 40,
            color: CaleeColors.destructive,
          ),
          const SizedBox(height: CaleeSpacing.md),
          const Text(
            'Could not load meals',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w600,
              color: CaleeColors.textPrimary,
            ),
          ),
          const SizedBox(height: CaleeSpacing.sm),
          TextButton(
            onPressed: _controller.load,
            child: const Text('Try again'),
          ),
        ],
      ),
    );
  }

  Future<void> _openSheet({
    required String date,
    required String mealType,
    required ClientMeal? meal,
  }) async {
    await MealFormSheet.show(
      context: context,
      date: date,
      mealType: mealType,
      existingMeal: meal,
      controller: _controller,
    );
  }
}

class MealFormSheet extends StatefulWidget {
  const MealFormSheet({
    required this.date,
    required this.mealType,
    required this.controller,
    this.existingMeal,
    super.key,
  });

  final String date;
  final String mealType;
  final MealsController controller;
  final ClientMeal? existingMeal;

  static Future<void> show({
    required BuildContext context,
    required String date,
    required String mealType,
    required MealsController controller,
    ClientMeal? existingMeal,
  }) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: CaleeColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(CaleeRadius.sheet),
        ),
      ),
      builder: (_) => MealFormSheet(
        date: date,
        mealType: mealType,
        controller: controller,
        existingMeal: existingMeal,
      ),
    );
  }

  @override
  State<MealFormSheet> createState() => _MealFormSheetState();
}

class _MealFormSheetState extends State<MealFormSheet> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _titleController;
  late final TextEditingController _notesController;
  bool _isSaving = false;
  String? _saveError;

  bool get _isEditing => widget.existingMeal != null;

  @override
  void initState() {
    super.initState();
    _titleController = TextEditingController(
      text: widget.existingMeal?.title ?? '',
    );
    _notesController = TextEditingController(
      text: widget.existingMeal?.notes ?? '',
    );
  }

  @override
  void dispose() {
    _titleController.dispose();
    _notesController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    final title = _titleController.text.trim();
    final notes = _notesController.text.trim();

    setState(() {
      _isSaving = true;
      _saveError = null;
    });

    try {
      if (_isEditing) {
        await widget.controller.updateMeal(
          mealId: widget.existingMeal!.id,
          title: title,
          notes: notes,
        );
      } else {
        await widget.controller.createMeal(
          mealDate: widget.date,
          mealType: widget.mealType,
          title: title,
          notes: notes.isEmpty ? null : notes,
        );
      }
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) {
        setState(() {
          _isSaving = false;
          _saveError = e.toString();
        });
      }
    }
  }

  Future<void> _delete() async {
    final meal = widget.existingMeal;
    if (meal == null) return;

    final confirmed = await CaleeDestructiveDialog.show(
      context: context,
      title: 'Delete meal?',
      body: 'Remove "${meal.title}"?',
      confirmLabel: 'Delete',
    );

    if (!confirmed || !mounted) return;

    setState(() {
      _isSaving = true;
      _saveError = null;
    });

    try {
      await widget.controller.deleteMeal(meal.id);
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) {
        setState(() {
          _isSaving = false;
          _saveError = e.toString();
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.viewInsetsOf(context).bottom;
    final mealTypeLabel = _kMealTypeLabels[widget.mealType] ?? widget.mealType;
    final title = _isEditing ? 'Edit $mealTypeLabel' : 'Add $mealTypeLabel';

    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          CaleeSpacing.md,
          CaleeSpacing.sm,
          CaleeSpacing.md,
          CaleeSpacing.md + bottomInset,
        ),
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Container(
                  width: 36,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: CaleeSpacing.md),
                  decoration: BoxDecoration(
                    color: CaleeColors.separatorOpaque,
                    borderRadius: BorderRadius.circular(CaleeRadius.dot),
                  ),
                ),
              ),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      title,
                      style: const TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w700,
                        color: CaleeColors.textPrimary,
                      ),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.of(context).maybePop(),
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                  ),
                ],
              ),
              const SizedBox(height: CaleeSpacing.md),
              CaleeSection(
                children: [
                  CaleeListRow(
                    title: _formatDateLabel(widget.date),
                    leading: const Icon(
                      Icons.calendar_today,
                      size: 18,
                      color: CaleeColors.textTertiary,
                    ),
                    trailing: const SizedBox.shrink(),
                  ),
                  CaleeListRow(
                    title: mealTypeLabel,
                    leading: const Icon(
                      Icons.restaurant,
                      size: 18,
                      color: CaleeColors.textTertiary,
                    ),
                    trailing: const SizedBox.shrink(),
                  ),
                ],
              ),
              const SizedBox(height: CaleeSpacing.md),
              CaleeSection(
                children: [
                  CaleeSectionTextFormField(
                    key: const Key('meal_title_field'),
                    controller: _titleController,
                    hintText: 'Meal title',
                    autofocus: !_isEditing,
                    textInputAction: TextInputAction.next,
                    validator: (v) {
                      if (v == null || v.trim().isEmpty) {
                        return 'Please enter a meal title';
                      }
                      return null;
                    },
                  ),
                  CaleeSectionTextFormField(
                    controller: _notesController,
                    hintText: 'Notes (optional)',
                    maxLines: 3,
                    minLines: 1,
                    textInputAction: TextInputAction.done,
                  ),
                ],
              ),
              if (_saveError != null) ...[
                const SizedBox(height: CaleeSpacing.sm),
                Text(
                  _saveError!,
                  style: const TextStyle(
                    fontSize: 13,
                    color: CaleeColors.destructive,
                  ),
                  textAlign: TextAlign.center,
                ),
              ],
              const SizedBox(height: CaleeSpacing.md),
              FilledButton(
                key: const Key('meal_save_button'),
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
              if (_isEditing) ...[
                const SizedBox(height: CaleeSpacing.sm),
                OutlinedButton(
                  key: const Key('meal_delete_button'),
                  onPressed: _isSaving ? null : _delete,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: CaleeColors.destructive,
                    side: const BorderSide(color: CaleeColors.destructive),
                  ),
                  child: const Text('Delete'),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────
// AddMealSheet
// ─────────────────────────────────────────────

/// Bottom sheet opened from the Meals page top-bar "+" button. Lets the user
/// pick a date and meal type in addition to the title/notes fields that
/// [MealFormSheet] already offers, then saves through the same
/// [MealsController.createMeal] path.
class AddMealSheet extends StatefulWidget {
  const AddMealSheet({required this.controller, super.key});

  final MealsController controller;

  static Future<void> show({
    required BuildContext context,
    required MealsController controller,
  }) {
    return CaleeBottomSheet.show<void>(
      context: context,
      title: 'Add meal',
      child: AddMealSheet(controller: controller),
    );
  }

  @override
  State<AddMealSheet> createState() => _AddMealSheetState();
}

class _AddMealSheetState extends State<AddMealSheet> {
  final _formKey = GlobalKey<FormState>();
  final _titleController = TextEditingController();
  final _notesController = TextEditingController();
  late DateTime _date;
  String _mealType = 'dinner';
  bool _isSaving = false;
  String? _saveError;

  @override
  void initState() {
    super.initState();
    _date = DateTime.now();
  }

  @override
  void dispose() {
    _titleController.dispose();
    _notesController.dispose();
    super.dispose();
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

  Future<void> _save() async {
    if (_isSaving || !(_formKey.currentState?.validate() ?? false)) return;
    final title = _titleController.text.trim();
    final notes = _notesController.text.trim();

    setState(() {
      _isSaving = true;
      _saveError = null;
    });

    try {
      await widget.controller.createMeal(
        mealDate: _fmt(_date),
        mealType: _mealType,
        title: title,
        notes: notes.isEmpty ? null : notes,
      );
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) {
        setState(() {
          _isSaving = false;
          _saveError = e.toString();
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Form(
      key: _formKey,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            CaleeSection(
              children: [
                CaleeSectionPickerRow(
                  label: 'Date',
                  value: _formatDateLabel(_fmt(_date)),
                  onTap: _isSaving ? null : _pickDate,
                  enabled: !_isSaving,
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
              ],
            ),
            const SizedBox(height: CaleeSpacing.md),
            CaleeSection(
              children: [
                CaleeSectionTextFormField(
                  key: const Key('meal_title_field'),
                  controller: _titleController,
                  hintText: 'Meal title',
                  enabled: !_isSaving,
                  autofocus: true,
                  textInputAction: TextInputAction.next,
                  validator: (v) {
                    if (v == null || v.trim().isEmpty) {
                      return 'Please enter a meal title';
                    }
                    return null;
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
              ],
            ),
            if (_saveError != null) ...[
              const SizedBox(height: CaleeSpacing.sm),
              Text(
                _saveError!,
                style: const TextStyle(
                  fontSize: 13,
                  color: CaleeColors.destructive,
                ),
                textAlign: TextAlign.center,
              ),
            ],
            const SizedBox(height: CaleeSpacing.md),
            FilledButton(
              key: const Key('meal_save_button'),
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
      ),
    );
  }
}

// ─────────────────────────────────────────────
// PickDinnerSheet
// ─────────────────────────────────────────────

/// Bottom sheet shown when tapping a missing dinner row in the Meals page.
/// Offers the household's own meal templates ("Family favourites"), starter
/// templates from the shared library ("Quick dinner ideas"), and a way to
/// create a brand-new meal from scratch.
class PickDinnerSheet extends StatefulWidget {
  const PickDinnerSheet({
    required this.date,
    required this.controller,
    super.key,
  });

  final String date;
  final MealsController controller;

  /// Shows the sheet. Resolves to `'create_new'` when the caller should open
  /// the plain meal-creation form next, or `null` when a template was
  /// selected (already created) or the sheet was dismissed.
  static Future<String?> show({
    required BuildContext context,
    required String date,
    required MealsController controller,
  }) {
    return CaleeBottomSheet.show<String>(
      context: context,
      title: 'Pick dinner',
      child: PickDinnerSheet(date: date, controller: controller),
    );
  }

  @override
  State<PickDinnerSheet> createState() => _PickDinnerSheetState();
}

class _PickDinnerOptions {
  const _PickDinnerOptions({
    required this.favourites,
    required this.quickIdeas,
  });

  final List<ClientMealTemplate> favourites;
  final List<ClientStarterMealTemplate> quickIdeas;
}

class _PickDinnerSheetState extends State<PickDinnerSheet> {
  late Future<_PickDinnerOptions> _future;
  bool _isCreating = false;
  Object? _createError;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<_PickDinnerOptions> _load() async {
    final repository = widget.controller.repository;
    final results = await Future.wait([
      repository.mealTemplates(mealType: 'dinner'),
      repository.mealStarterTemplates(mealType: 'dinner'),
    ]);
    return _PickDinnerOptions(
      favourites: (results[0] as ClientMealTemplateList).templates,
      quickIdeas: results[1] as List<ClientStarterMealTemplate>,
    );
  }

  Future<void> _selectTemplate(
    String name,
    String? notes, {
    int? templateId,
    int? starterTemplateId,
  }) async {
    if (_isCreating) return;
    setState(() {
      _isCreating = true;
      _createError = null;
    });

    try {
      await widget.controller.createMeal(
        mealDate: widget.date,
        mealType: 'dinner',
        title: name,
        notes: notes,
        templateId: templateId,
        starterTemplateId: starterTemplateId,
      );
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) {
        setState(() {
          _isCreating = false;
          _createError = e;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<_PickDinnerOptions>(
      future: _future,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Padding(
            padding: EdgeInsets.all(CaleeSpacing.xl),
            child: Center(child: CircularProgressIndicator()),
          );
        }
        if (snapshot.hasError) {
          return _buildLoadError();
        }

        final options = snapshot.data!;
        return SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              CaleeSection(
                title: 'Family favourites',
                children: options.favourites.isEmpty
                    ? [_mutedRow('No family favourites yet')]
                    : options.favourites.map(_favouriteRow).toList(),
              ),
              const SizedBox(height: CaleeSpacing.md),
              CaleeSection(
                title: 'Quick dinner ideas',
                children: options.quickIdeas.isEmpty
                    ? [_mutedRow('No quick dinner ideas yet')]
                    : options.quickIdeas.map(_quickIdeaRow).toList(),
              ),
              if (_createError != null) ...[
                const SizedBox(height: CaleeSpacing.sm),
                const Text(
                  'Could not create meal. Try again.',
                  style: TextStyle(
                    fontSize: 13,
                    color: CaleeColors.destructive,
                  ),
                  textAlign: TextAlign.center,
                ),
              ],
              const SizedBox(height: CaleeSpacing.md),
              OutlinedButton.icon(
                onPressed: _isCreating
                    ? null
                    : () => Navigator.of(context).pop('create_new'),
                icon: const Icon(Icons.add),
                label: const Text('Create new meal'),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _favouriteRow(ClientMealTemplate template) {
    return CaleeListRow(
      leading: Text(
        mealIconEmoji(
          icon: template.icon,
          title: template.name,
          mealType: 'dinner',
        ),
        style: const TextStyle(fontSize: 18),
      ),
      title: template.name,
      subtitle: savedMealMetadata(template),
      trailing: template.isFavourite
          ? const Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.star, size: 18, color: CaleeColors.primary),
                SizedBox(width: CaleeSpacing.xs),
                Icon(
                  Icons.chevron_right,
                  size: 20,
                  color: CaleeColors.textTertiary,
                ),
              ],
            )
          : null,
      enabled: !_isCreating,
      onTap: () => _selectTemplate(
        template.name,
        template.notes,
        templateId: template.id,
      ),
    );
  }

  Widget _quickIdeaRow(ClientStarterMealTemplate template) {
    return CaleeListRow(
      leading: Text(
        mealIconEmoji(
          icon: template.icon,
          title: template.name,
          mealType: 'dinner',
        ),
        style: const TextStyle(fontSize: 18),
      ),
      title: template.name,
      enabled: !_isCreating,
      onTap: () => _selectTemplate(
        template.name,
        template.notes,
        starterTemplateId: template.id,
      ),
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

  Widget _buildLoadError() {
    return Padding(
      padding: const EdgeInsets.all(CaleeSpacing.xl),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(
            Icons.error_outline,
            size: 36,
            color: CaleeColors.destructive,
          ),
          const SizedBox(height: CaleeSpacing.sm),
          const Text(
            'Could not load dinner ideas',
            style: TextStyle(fontSize: 15, color: CaleeColors.textPrimary),
          ),
          const SizedBox(height: CaleeSpacing.sm),
          TextButton(
            onPressed: () => setState(() => _future = _load()),
            child: const Text('Try again'),
          ),
        ],
      ),
    );
  }
}

class _CopyWeekSheet extends StatefulWidget {
  const _CopyWeekSheet();

  static Future<bool?> show({required BuildContext context}) {
    return showModalBottomSheet<bool>(
      context: context,
      backgroundColor: CaleeColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(CaleeRadius.sheet),
        ),
      ),
      builder: (_) => const _CopyWeekSheet(),
    );
  }

  @override
  State<_CopyWeekSheet> createState() => _CopyWeekSheetState();
}

class _CopyWeekSheetState extends State<_CopyWeekSheet> {
  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.viewInsetsOf(context).bottom;
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          CaleeSpacing.md,
          CaleeSpacing.sm,
          CaleeSpacing.md,
          CaleeSpacing.md + bottomInset,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(
                width: 36,
                height: 4,
                margin: const EdgeInsets.only(bottom: CaleeSpacing.md),
                decoration: BoxDecoration(
                  color: CaleeColors.separatorOpaque,
                  borderRadius: BorderRadius.circular(CaleeRadius.dot),
                ),
              ),
            ),
            const Text(
              'Copy previous week?',
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w700,
                color: CaleeColors.textPrimary,
              ),
            ),
            const SizedBox(height: CaleeSpacing.sm),
            const Text(
              'This copies breakfast, lunch and dinner into the week shown.',
              style: TextStyle(fontSize: 14, color: CaleeColors.textTertiary),
            ),
            const SizedBox(height: CaleeSpacing.lg),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Copy empty slots'),
            ),
            const SizedBox(height: CaleeSpacing.sm),
            OutlinedButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Replace this week'),
            ),
            const SizedBox(height: CaleeSpacing.sm),
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────
// Search support
// ─────────────────────────────────────────────

class _MealSearchSheet extends StatefulWidget {
  const _MealSearchSheet({required this.meals, required this.onTapMeal});

  final List<ClientMeal> meals;
  final ValueChanged<ClientMeal> onTapMeal;

  @override
  State<_MealSearchSheet> createState() => _MealSearchSheetState();
}

class _MealSearchSheetState extends State<_MealSearchSheet> {
  final _controller = TextEditingController();
  List<ClientMeal> _results = [];

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
          : widget.meals
                .where(
                  (meal) =>
                      meal.title.toLowerCase().contains(q) ||
                      (meal.notes ?? '').toLowerCase().contains(q),
                )
                .toList();
    });
  }

  String _resultSubtitle(ClientMeal meal) {
    final label = _kMealTypeLabels[meal.mealType] ?? meal.mealType;
    final parts = meal.mealDate.split('-');
    if (parts.length != 3) return label;
    return '$label · ${parts[2]}/${parts[1]}/${parts[0]}';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.6,
      minChildSize: 0.4,
      maxChildSize: 0.92,
      builder: (context, scrollController) => Padding(
        padding: EdgeInsets.only(bottom: bottomInset),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                CaleeSpacing.pagePadding,
                CaleeSpacing.md,
                CaleeSpacing.pagePadding,
                CaleeSpacing.sm,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Center(
                    child: Container(
                      width: 36,
                      height: 4,
                      margin: const EdgeInsets.only(bottom: CaleeSpacing.md),
                      decoration: BoxDecoration(
                        color: CaleeColors.textTertiary.withValues(alpha: 0.4),
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          'Search this week',
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w600,
                            color: CaleeColors.textPrimary,
                          ),
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.close),
                        onPressed: () => Navigator.of(context).maybePop(),
                      ),
                    ],
                  ),
                  const SizedBox(height: CaleeSpacing.sm),
                  TextField(
                    controller: _controller,
                    autofocus: true,
                    textInputAction: TextInputAction.search,
                    decoration: InputDecoration(
                      hintText: 'Search this week by meal title…',
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
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: _controller.text.trim().isEmpty
                  ? Center(
                      child: Text(
                        'Type to search',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: CaleeColors.textTertiary,
                        ),
                      ),
                    )
                  : _results.isEmpty
                  ? Center(
                      child: Text(
                        'No meals found',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: CaleeColors.textTertiary,
                        ),
                      ),
                    )
                  : ListView.builder(
                      controller: scrollController,
                      padding: const EdgeInsets.symmetric(
                        horizontal: CaleeSpacing.pagePadding,
                        vertical: CaleeSpacing.sm,
                      ),
                      itemCount: _results.length,
                      itemBuilder: (context, index) {
                        final meal = _results[index];
                        final emoji = _kMealTypeEmoji[meal.mealType] ?? '';
                        return CaleeListRow(
                          leading: Text(
                            emoji,
                            style: const TextStyle(fontSize: 18),
                          ),
                          title: meal.title,
                          subtitle: _resultSubtitle(meal),
                          onTap: () => widget.onTapMeal(meal),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
