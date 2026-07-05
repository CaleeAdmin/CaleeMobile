import 'package:flutter/material.dart';

import '../../data/api/calee_hub_client.dart';
import '../../data/models/client_meal.dart';
import '../../data/models/client_shopping_list.dart';
import '../../shared/meal_icon.dart';
import '../../ui/calee_design.dart';
import '../shopping/shopping_page.dart';
import 'meals_controller.dart';
import 'meals_repository.dart';

const _kMealTypeLabels = {
  'breakfast': 'Breakfast',
  'lunch': 'Lunch',
  'dinner': 'Dinner',
};

const _kBreakfastLunchTypes = ['breakfast', 'lunch'];

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

bool _isSameDay(DateTime a, DateTime b) =>
    a.year == b.year && a.month == b.month && a.day == b.day;

String _weekRangeLabel(DateTime start, DateTime end) {
  if (start.month == end.month) {
    return '${start.day}–${end.day} ${_kMonths[start.month - 1]} ${start.year}';
  }
  return '${start.day} ${_kMonths[start.month - 1]} – ${end.day} ${_kMonths[end.month - 1]} ${start.year}';
}

String _dinnerDayLabel(DateTime day) =>
    '${_kWeekdayShort[day.weekday - 1]} ${day.day} ${_kMonths[day.month - 1]}';

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
  bool _showBreakfastLunch = false;

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
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: _controller.load,
          child: _buildBody(),
        ),
      ),
    );
  }

  Widget _buildBody() {
    return ListView(
      padding: const EdgeInsets.symmetric(
        horizontal: CaleeSpacing.pagePadding,
        vertical: CaleeSpacing.md,
      ),
      children: [
        _buildHeader(),
        const SizedBox(height: CaleeSpacing.md),
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

    return [
      _buildDinnersSection(),
      const SizedBox(height: CaleeSpacing.md),
      _buildGroceryListButton(),
      _buildBreakfastLunchToggle(),
      if (_showBreakfastLunch) ...[
        const SizedBox(height: CaleeSpacing.md),
        _buildBreakfastLunchList(),
      ],
      const SizedBox(height: CaleeSpacing.md),
      _buildCopyWeekButton(),
    ];
  }

  Widget _buildGroceryListButton() {
    return Align(
      alignment: Alignment.centerLeft,
      child: TextButton.icon(
        onPressed: _openShoppingList,
        icon: const Icon(Icons.shopping_cart_outlined, size: 16),
        label: const Text('Build grocery list'),
      ),
    );
  }

  // Shopping lists are a sub-feature of meal planning (see ClientBootstrap
  // .supportsMeals), so the Shopping page is reached from here rather than
  // its own bottom-nav tab — Today/Calendar/Tasks/Chores/Meals/Settings
  // already fill the bar for family households with chores enabled.
  Future<void> _openShoppingList() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ShoppingPage(
          hubClient: widget.hubClient,
          accessToken: widget.accessToken,
          autoGenerate: true,
          initialWeekStart: _controller.weekStart,
          initialWeekEnd: _controller.weekEnd,
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return const Text(
      'Meals',
      style: TextStyle(
        fontSize: 32,
        fontWeight: FontWeight.bold,
        color: CaleeColors.textPrimary,
        height: 1.1,
      ),
    );
  }

  Widget _buildWeekSelector() {
    return Row(
      children: [
        IconButton(
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
          icon: const Icon(Icons.chevron_right),
          color: CaleeColors.primary,
          onPressed: _controller.isLoading ? null : _controller.nextWeek,
        ),
      ],
    );
  }

  Widget _buildCopyWeekButton() {
    final label = _controller.isCurrentWeek
        ? 'Copy last week'
        : 'Copy previous week';
    final disabled = _controller.isCopying || _controller.isLoading;
    return Align(
      alignment: Alignment.centerRight,
      child: TextButton.icon(
        onPressed: disabled ? null : _showCopyWeekSheet,
        icon: const Icon(Icons.content_copy, size: 16),
        label: Text(label),
      ),
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

  // ── This week's dinners ─────────────────────────────────────────────────

  List<DateTime> _weekDays() => List.generate(
    7,
    (i) => DateTime(
      _controller.weekStart.year,
      _controller.weekStart.month,
      _controller.weekStart.day + i,
    ),
  );

  Widget _buildDinnersSection() {
    final days = _weekDays();
    final dinners = {
      for (final d in days) _fmt(d): _controller.mealFor(_fmt(d), 'dinner'),
    };
    final plannedCount = dinners.values.where((m) => m != null).length;
    final now = DateTime.now();
    final todayStr = _fmt(now);
    final showTonight =
        _controller.isCurrentWeek && days.any((d) => _isSameDay(d, now));

    final rows = <Widget>[
      if (showTonight) _buildTonightRow(dinners[todayStr]),
      _buildPlannedCountRow(plannedCount),
      for (final day in days) _buildDinnerRow(day, dinners[_fmt(day)]),
    ];

    return CaleeSection(title: "This week's dinners", children: rows);
  }

  Widget _buildTonightRow(ClientMeal? tonight) {
    final text = tonight != null
        ? 'Tonight: ${mealIconEmoji(title: tonight.title, mealType: 'dinner')} ${tonight.title}'
        : 'Tonight: Pick dinner';
    return _infoRow(text);
  }

  Widget _buildPlannedCountRow(int plannedCount) {
    final text = plannedCount == 7
        ? 'All 7 dinners planned'
        : '$plannedCount of 7 dinners planned';
    return _infoRow(text);
  }

  Widget _infoRow(String text) {
    return CaleeListRow(
      title: text,
      titleStyle: const TextStyle(
        fontSize: 14,
        color: CaleeColors.textSecondary,
      ),
    );
  }

  Widget _buildDinnerRow(DateTime day, ClientMeal? meal) {
    final dateStr = _fmt(day);
    final dayLabel = _dinnerDayLabel(day);
    final leading = SizedBox(
      width: 88,
      child: Text(
        dayLabel,
        style: const TextStyle(fontSize: 13, color: CaleeColors.textSecondary),
      ),
    );

    if (meal == null) {
      return CaleeListRow(
        leading: leading,
        title: 'Pick dinner',
        titleStyle: const TextStyle(
          fontSize: 15,
          color: CaleeColors.textSecondary,
        ),
        onTap: () => _openPickDinnerSheet(dateStr),
      );
    }

    final icon = mealIconEmoji(title: meal.title, mealType: 'dinner');
    final notes = (meal.notes ?? '').trim();
    final titleText = notes.isEmpty
        ? '$icon ${meal.title}'
        : '$icon ${meal.title} · $notes';

    return CaleeListRow(
      leading: leading,
      title: titleText,
      titleMaxLines: 1,
      onTap: () => _openSheet(date: dateStr, mealType: 'dinner', meal: meal),
    );
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

  // ── Breakfast & lunch (hidden by default) ───────────────────────────────

  Widget _buildBreakfastLunchToggle() {
    return Align(
      alignment: Alignment.centerLeft,
      child: TextButton.icon(
        onPressed: () =>
            setState(() => _showBreakfastLunch = !_showBreakfastLunch),
        icon: Icon(
          _showBreakfastLunch ? Icons.expand_less : Icons.expand_more,
          size: 16,
        ),
        label: Text(
          _showBreakfastLunch
              ? 'Hide breakfast & lunch'
              : 'Show breakfast & lunch',
        ),
      ),
    );
  }

  Widget _buildBreakfastLunchList() {
    final days = _weekDays();
    return Column(
      children: [
        for (var i = 0; i < days.length; i++) ...[
          if (i > 0) const SizedBox(height: CaleeSpacing.sectionSpacing),
          _buildBreakfastLunchDaySection(days[i]),
        ],
      ],
    );
  }

  Widget _buildBreakfastLunchDaySection(DateTime day) {
    final dateStr = _fmt(day);

    return CaleeSection(
      title: _dayTitle(day),
      children: _kBreakfastLunchTypes.map((mealType) {
        final meal = _controller.mealFor(dateStr, mealType);

        return CaleeListRow(
          leading: Icon(
            _mealTypeIcon(mealType),
            size: 20,
            color: CaleeColors.textTertiary,
          ),
          title: _kMealTypeLabels[mealType] ?? mealType,
          subtitle: meal != null ? meal.title : 'Not planned',
          subtitleStyle: meal != null
              ? Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: CaleeColors.textPrimary)
              : null,
          trailing: meal != null
              ? const Icon(
                  Icons.chevron_right,
                  size: 20,
                  color: CaleeColors.textTertiary,
                )
              : const Icon(
                  Icons.add,
                  size: 20,
                  color: CaleeColors.textTertiary,
                ),
          onTap: () =>
              _openSheet(date: dateStr, mealType: mealType, meal: meal),
        );
      }).toList(),
    );
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

  IconData _mealTypeIcon(String mealType) {
    switch (mealType) {
      case 'breakfast':
        return Icons.wb_sunny_outlined;
      case 'lunch':
        return Icons.restaurant_outlined;
      default:
        return Icons.restaurant_outlined;
    }
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

  String _formatDateLabel(String date) {
    final parts = date.split('-');
    if (parts.length != 3) return date;
    final d = int.tryParse(parts[2]) ?? 0;
    final m = int.tryParse(parts[1]) ?? 0;
    final months = [
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

  Future<void> _selectTemplate(String name, String? notes) async {
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
      enabled: !_isCreating,
      onTap: () => _selectTemplate(template.name, template.notes),
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
      onTap: () => _selectTemplate(template.name, template.notes),
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
