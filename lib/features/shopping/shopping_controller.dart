import 'package:flutter/foundation.dart';

import '../../data/api/calee_hub_client.dart';
import '../../data/models/client_shopping_list.dart';
import 'shopping_repository.dart';

String _formatDate(DateTime value) {
  final y = value.year.toString().padLeft(4, '0');
  final m = value.month.toString().padLeft(2, '0');
  final d = value.day.toString().padLeft(2, '0');
  return '$y-$m-$d';
}

DateTime _mondayOf(DateTime date) {
  final weekday = date.weekday; // 1=Mon, 7=Sun
  return DateTime(date.year, date.month, date.day - (weekday - 1));
}

/// Returns a copy of [item] with [checked] applied. This is a small local
/// helper (rather than a `copyWith` on the model itself) so the model
/// classes stay plain DTOs, consistent with the rest of this app's API
/// models.
ClientShoppingListItem _withChecked(ClientShoppingListItem item, bool checked) {
  return ClientShoppingListItem(
    id: item.id,
    shoppingListId: item.shoppingListId,
    householdId: item.householdId,
    sourceType: item.sourceType,
    sourceMealItemId: item.sourceMealItemId,
    sourceTemplateId: item.sourceTemplateId,
    sourceStarterTemplateId: item.sourceStarterTemplateId,
    name: item.name,
    normalizedName: item.normalizedName,
    quantityText: item.quantityText,
    unit: item.unit,
    category: item.category,
    checked: checked,
    checkedAt: item.checkedAt,
    manuallyAdded: item.manuallyAdded,
    manuallyRemoved: item.manuallyRemoved,
    sortOrder: item.sortOrder,
    createdAt: item.createdAt,
    updatedAt: item.updatedAt,
    deletedAt: item.deletedAt,
  );
}

/// Manual `ChangeNotifier` state for the Shopping page. This app has no
/// Provider/Riverpod/Bloc — pages own a controller and call
/// `addListener`/`setState`, exactly like [ChangeNotifier]-based controllers
/// elsewhere (e.g. `MealsController`).
class ShoppingController extends ChangeNotifier {
  ShoppingController({required this.repository, DateTime? initialWeekStart}) {
    _weekStart = _mondayOf(initialWeekStart ?? DateTime.now());
  }

  final ShoppingRepository repository;

  late DateTime _weekStart;
  bool isLoading = false;
  bool isSyncing = false;
  Object? error;
  ClientShoppingList? shoppingList;

  // Item ids with an in-flight checked/unchecked request. Backs the per-row
  // spinner and stops re-entrant taps on the same item. A simple in-memory
  // set — no persistence, per this app's conventions.
  final Set<int> _pendingItemIds = {};

  String get weekStartStr => _formatDate(_weekStart);

  String get weekEndStr => _formatDate(
    DateTime(_weekStart.year, _weekStart.month, _weekStart.day + 6),
  );

  bool isItemPending(int itemId) => _pendingItemIds.contains(itemId);

  Future<void> load() async {
    if (isLoading) return;
    isLoading = true;
    error = null;
    notifyListeners();

    try {
      shoppingList = await repository.loadCurrent(
        from: weekStartStr,
        to: weekEndStr,
      );
      error = null;
    } on CaleeHubException catch (e) {
      if (e.statusCode == 404) {
        // No shopping list has been generated for this week yet. That's not
        // a failure — the page offers its own "Generate from meal plan"
        // action for this case.
        shoppingList = null;
        error = null;
      } else {
        error = e;
      }
    } catch (e) {
      error = e;
    } finally {
      isLoading = false;
      notifyListeners();
    }
  }

  /// Loads a specific list by id, regardless of [_weekStart] — used when
  /// opening from the shopping-list deep link (see
  /// `ShoppingListLinkController`), where the tablet's QR code identifies an
  /// exact list rather than a week.
  Future<void> loadById(int listId) async {
    if (isLoading) return;
    isLoading = true;
    error = null;
    notifyListeners();

    try {
      shoppingList = await repository.loadById(listId: listId);
      error = null;
    } catch (e) {
      error = e;
    } finally {
      isLoading = false;
      notifyListeners();
    }
  }

  Future<void> generate({String mode = 'merge'}) async {
    isSyncing = true;
    notifyListeners();

    try {
      shoppingList = await repository.generate(
        from: weekStartStr,
        to: weekEndStr,
        mode: mode,
      );
      error = null;
    } catch (e) {
      error = e;
      rethrow;
    } finally {
      isSyncing = false;
      notifyListeners();
    }
  }

  /// Optimistically flips [itemId]'s checked state, then confirms with the
  /// server. Reverts the local flip and sets [error] if the request fails.
  Future<void> toggleChecked(int itemId) async {
    final list = shoppingList;
    if (list == null || _pendingItemIds.contains(itemId)) return;

    final index = list.items.indexWhere((item) => item.id == itemId);
    if (index == -1) return;

    final original = list.items[index];
    final optimisticChecked = !original.checked;

    error = null;
    list.items[index] = _withChecked(original, optimisticChecked);
    _pendingItemIds.add(itemId);
    notifyListeners();

    try {
      final updated = await repository.updateItemChecked(
        listId: list.id,
        itemId: itemId,
        checked: optimisticChecked,
      );
      if (identical(shoppingList, list)) {
        final i = list.items.indexWhere((item) => item.id == itemId);
        if (i != -1) list.items[i] = updated;
      }
    } catch (e) {
      if (identical(shoppingList, list)) {
        final i = list.items.indexWhere((item) => item.id == itemId);
        if (i != -1) list.items[i] = original;
      }
      error = e;
    } finally {
      _pendingItemIds.remove(itemId);
      notifyListeners();
    }
  }

  Future<void> addItem({required String name, String? category}) async {
    final list = shoppingList;
    if (list == null) return;

    isSyncing = true;
    notifyListeners();
    try {
      final item = await repository.addItem(
        listId: list.id,
        name: name,
        category: category,
      );
      if (identical(shoppingList, list)) {
        list.items.add(item);
      }
    } finally {
      isSyncing = false;
      notifyListeners();
    }
  }

  Future<void> deleteItem(int itemId) async {
    final list = shoppingList;
    if (list == null) return;

    final index = list.items.indexWhere((item) => item.id == itemId);
    if (index == -1) return;

    final removed = list.items[index];
    list.items.removeAt(index);
    isSyncing = true;
    notifyListeners();

    try {
      await repository.deleteItem(listId: list.id, itemId: itemId);
    } catch (e) {
      if (identical(shoppingList, list)) {
        final insertAt = index.clamp(0, list.items.length);
        list.items.insert(insertAt, removed);
      }
      rethrow;
    } finally {
      isSyncing = false;
      notifyListeners();
    }
  }
}
