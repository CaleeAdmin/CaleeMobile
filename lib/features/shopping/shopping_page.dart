import 'package:flutter/material.dart';

import '../../data/api/calee_hub_client.dart';
import '../../data/models/client_shopping_list.dart';
import '../../ui/calee_design.dart';
import 'shopping_controller.dart';
import 'shopping_repository.dart';

// TODO(CaleeAdmin/CaleeMobile#404): support an app/universal link that opens
// a specific shopping list (GET /client/v1/shopping-lists/{listId} already
// exists server-side for this). Until then, this page is reachable purely
// through in-app navigation from the Meals page.

enum _ShoppingFilter { all, toBuy, bought }

class ShoppingPage extends StatefulWidget {
  const ShoppingPage({
    required this.hubClient,
    required this.accessToken,
    this.autoGenerate = false,
    this.initialWeekStart,
    this.initialWeekEnd,
    super.key,
  });

  final CaleeHubClient hubClient;
  final String accessToken;

  /// When true, generates the shopping list from the current meal plan on
  /// first load instead of just fetching whatever list already exists. Used
  /// by the Meals page's "Generate shopping list" entry point.
  final bool autoGenerate;

  /// Start of the week to load/generate for, taken from the Meals page's
  /// currently visible week. Null defaults to the current calendar week.
  final DateTime? initialWeekStart;

  /// End of the week to load/generate for. Null defaults to
  /// initialWeekStart + 6 days (or the current calendar week's end, when
  /// initialWeekStart is also null).
  final DateTime? initialWeekEnd;

  @override
  State<ShoppingPage> createState() => _ShoppingPageState();
}

class _ShoppingPageState extends State<ShoppingPage> {
  late final ShoppingController _controller;
  _ShoppingFilter _filter = _ShoppingFilter.all;

  @override
  void initState() {
    super.initState();
    _controller = ShoppingController(
      repository: ShoppingRepository(
        hubClient: widget.hubClient,
        accessToken: widget.accessToken,
      ),
      initialWeekStart: widget.initialWeekStart,
      initialWeekEnd: widget.initialWeekEnd,
    );
    _controller.addListener(_onControllerChanged);
    if (widget.autoGenerate) {
      _controller.generate();
    } else {
      _controller.load();
    }
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

  Future<void> _generate() async {
    try {
      await _controller.generate();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not generate shopping list.')),
        );
      }
    }
  }

  Future<void> _openAddItemSheet() async {
    if (_controller.shoppingList == null) return;
    await CaleeBottomSheet.show<void>(
      context: context,
      title: 'Add item',
      child: _AddShoppingItemForm(controller: _controller),
    );
  }

  Future<void> _confirmDeleteItem(ClientShoppingListItem item) async {
    final confirmed = await CaleeDestructiveDialog.show(
      context: context,
      title: 'Remove item?',
      body: 'Remove "${item.name}" from the list?',
      confirmLabel: 'Remove',
    );
    if (!confirmed || !mounted) return;

    try {
      await _controller.deleteItem(item.id);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not remove ${item.name}.')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return CaleeScaffold(
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
      ),
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
        _buildActionsRow(),
        const SizedBox(height: CaleeSpacing.md),
        _buildContent(),
        const SizedBox(height: CaleeSpacing.lg),
      ],
    );
  }

  Widget _buildHeader() {
    return const Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Shopping',
          style: TextStyle(
            fontSize: 32,
            fontWeight: FontWeight.bold,
            color: CaleeColors.textPrimary,
            height: 1.1,
          ),
        ),
        SizedBox(height: 2),
        Text(
          'This week',
          style: TextStyle(fontSize: 15, color: CaleeColors.textSecondary),
        ),
      ],
    );
  }

  Widget _buildActionsRow() {
    final busy = _controller.isSyncing || _controller.isLoading;
    final hasList = _controller.shoppingList != null;

    return Row(
      children: [
        Expanded(
          child: TextButton.icon(
            onPressed: busy ? null : _generate,
            icon: const Icon(Icons.auto_awesome, size: 16),
            label: const Text('Generate from meal plan'),
          ),
        ),
        if (hasList)
          TextButton.icon(
            onPressed: busy ? null : _openAddItemSheet,
            icon: const Icon(Icons.add, size: 16),
            label: const Text('Add item'),
          ),
      ],
    );
  }

  Widget _buildFilterControl() {
    return Align(
      alignment: Alignment.centerLeft,
      child: SegmentedButton<_ShoppingFilter>(
        segments: const [
          ButtonSegment(value: _ShoppingFilter.all, label: Text('Show all')),
          ButtonSegment(value: _ShoppingFilter.toBuy, label: Text('To buy')),
          ButtonSegment(value: _ShoppingFilter.bought, label: Text('Bought')),
        ],
        selected: {_filter},
        onSelectionChanged: (selection) {
          setState(() => _filter = selection.first);
        },
        style: const ButtonStyle(
          visualDensity: VisualDensity.compact,
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
      ),
    );
  }

  Widget _buildContent() {
    final list = _controller.shoppingList;

    if (_controller.isLoading && list == null) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(CaleeSpacing.xl),
          child: CircularProgressIndicator(),
        ),
      );
    }

    if (list == null) {
      if (_controller.error != null) {
        return _buildLoadErrorState();
      }
      return _buildEmptyState();
    }

    if (list.items.isEmpty) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_controller.error != null) _buildInlineErrorBanner(),
          _buildEmptyState(),
        ],
      );
    }

    final filteredItems = _applyFilter(list.items);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_controller.error != null) _buildInlineErrorBanner(),
        _buildFilterControl(),
        const SizedBox(height: CaleeSpacing.md),
        if (filteredItems.isEmpty)
          _buildNoMatchesForFilterState()
        else
          _buildGroupedSections(filteredItems),
      ],
    );
  }

  Widget _buildLoadErrorState() {
    return CaleeEmptyState(
      icon: Icons.cloud_off_outlined,
      title: 'Could not load shopping list',
      body: 'Check your connection, then try again.',
      action: FilledButton(
        onPressed: _controller.load,
        child: const Text('Try again'),
      ),
    );
  }

  Widget _buildInlineErrorBanner() {
    return Padding(
      padding: const EdgeInsets.only(bottom: CaleeSpacing.md),
      child: Container(
        padding: const EdgeInsets.all(CaleeSpacing.sm),
        decoration: BoxDecoration(
          color: CaleeColors.destructive.withAlpha(CaleeAlpha.pct10),
          borderRadius: BorderRadius.circular(CaleeRadius.card),
        ),
        child: Row(
          children: [
            const Icon(
              Icons.error_outline,
              size: 18,
              color: CaleeColors.destructive,
            ),
            const SizedBox(width: CaleeSpacing.sm),
            Expanded(
              child: Text(
                _controller.error.toString(),
                style: const TextStyle(
                  fontSize: 13,
                  color: CaleeColors.destructive,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmptyState() {
    final hasList = _controller.shoppingList != null;
    return CaleeEmptyState(
      icon: Icons.shopping_cart_outlined,
      title: 'No items yet',
      body:
          "Generate a shopping list from this week's meal plan, or add items yourself.",
      action: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          FilledButton.icon(
            onPressed: _controller.isSyncing ? null : _generate,
            icon: const Icon(Icons.auto_awesome),
            label: const Text('Generate from meal plan'),
          ),
          if (hasList) ...[
            const SizedBox(height: CaleeSpacing.sm),
            OutlinedButton.icon(
              onPressed: _controller.isSyncing ? null : _openAddItemSheet,
              icon: const Icon(Icons.add),
              label: const Text('Add item'),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildNoMatchesForFilterState() {
    return const CaleeEmptyState(
      icon: Icons.filter_alt_off_outlined,
      title: 'Nothing here',
      body: 'No items match this filter.',
    );
  }

  Widget _buildGroupedSections(List<ClientShoppingListItem> items) {
    final grouped = _groupByCategory(items);
    final categories = grouped.keys.toList()
      ..sort((a, b) {
        if (a == 'Other' && b != 'Other') return 1;
        if (b == 'Other' && a != 'Other') return -1;
        return a.compareTo(b);
      });

    return Column(
      children: [
        for (var i = 0; i < categories.length; i++) ...[
          if (i > 0) const SizedBox(height: CaleeSpacing.sectionSpacing),
          _buildCategorySection(categories[i], grouped[categories[i]]!),
        ],
      ],
    );
  }

  // Manual fold — no grouping dependency needed for this small dataset.
  Map<String, List<ClientShoppingListItem>> _groupByCategory(
    List<ClientShoppingListItem> items,
  ) {
    final grouped = <String, List<ClientShoppingListItem>>{};
    for (final item in items) {
      grouped.putIfAbsent(item.displayCategory, () => []).add(item);
    }
    for (final group in grouped.values) {
      group.sort((a, b) {
        final orderCmp = a.sortOrder.compareTo(b.sortOrder);
        if (orderCmp != 0) return orderCmp;
        return a.name.toLowerCase().compareTo(b.name.toLowerCase());
      });
    }
    return grouped;
  }

  List<ClientShoppingListItem> _applyFilter(
    List<ClientShoppingListItem> items,
  ) {
    switch (_filter) {
      case _ShoppingFilter.all:
        return items;
      case _ShoppingFilter.toBuy:
        return items.where((item) => !item.checked).toList();
      case _ShoppingFilter.bought:
        return items.where((item) => item.checked).toList();
    }
  }

  Widget _buildCategorySection(
    String category,
    List<ClientShoppingListItem> items,
  ) {
    return CaleeSection(
      title: category,
      trailing: '${items.length}',
      children: items.map((item) {
        final isPending = _controller.isItemPending(item.id);
        final onToggle = isPending
            ? null
            : () => _controller.toggleChecked(item.id);

        return CaleeListRow(
          leading: Semantics(
            label: item.checked
                ? 'Mark ${item.name} as not bought'
                : 'Mark ${item.name} as bought',
            button: true,
            excludeSemantics: true,
            child: CaleeCheckCircle(
              isChecked: item.checked,
              isLoading: isPending,
              onTap: onToggle,
              size: 28,
            ),
          ),
          title: item.name,
          subtitle: _itemSubtitle(item),
          titleStyle: item.checked
              ? const TextStyle(
                  fontSize: 16,
                  color: CaleeColors.textTertiary,
                  decoration: TextDecoration.lineThrough,
                )
              : null,
          trailing: IconButton(
            icon: const Icon(
              Icons.close,
              size: 18,
              color: CaleeColors.textTertiary,
            ),
            onPressed: () => _confirmDeleteItem(item),
            tooltip: 'Remove ${item.name}',
          ),
          onTap: onToggle,
        );
      }).toList(),
    );
  }

  String? _itemSubtitle(ClientShoppingListItem item) {
    final parts = [
      if ((item.quantityText ?? '').trim().isNotEmpty)
        item.quantityText!.trim(),
      if ((item.unit ?? '').trim().isNotEmpty) item.unit!.trim(),
    ];
    return parts.isEmpty ? null : parts.join(' ');
  }
}

class _AddShoppingItemForm extends StatefulWidget {
  const _AddShoppingItemForm({required this.controller});

  final ShoppingController controller;

  @override
  State<_AddShoppingItemForm> createState() => _AddShoppingItemFormState();
}

class _AddShoppingItemFormState extends State<_AddShoppingItemForm> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _categoryController = TextEditingController();
  bool _isSaving = false;
  String? _saveError;

  @override
  void dispose() {
    _nameController.dispose();
    _categoryController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    final name = _nameController.text.trim();
    final category = _categoryController.text.trim();

    setState(() {
      _isSaving = true;
      _saveError = null;
    });

    try {
      await widget.controller.addItem(
        name: name,
        category: category.isEmpty ? null : category,
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
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          CaleeSection(
            children: [
              CaleeSectionTextFormField(
                controller: _nameController,
                hintText: 'Item name',
                autofocus: true,
                textInputAction: TextInputAction.next,
                validator: (v) {
                  if (v == null || v.trim().isEmpty) {
                    return 'Please enter an item name';
                  }
                  return null;
                },
              ),
              CaleeSectionTextFormField(
                controller: _categoryController,
                hintText: 'Category (optional)',
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
                : const Text('Add'),
          ),
        ],
      ),
    );
  }
}
