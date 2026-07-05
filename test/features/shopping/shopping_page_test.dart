// Widget tests for ShoppingPage.
//
// Covers: items are grouped by category; tapping an item optimistically
// toggles checked (and reverts on failure); the generate button calls the
// repository; a load failure shows a retry affordance; the add-item sheet
// adds a new item to the list.

import 'dart:async';

import 'package:calee_mobile/data/api/calee_hub_client.dart';
import 'package:calee_mobile/data/models/client_shopping_list.dart';
import 'package:calee_mobile/features/shopping/shopping_page.dart';
import 'package:calee_mobile/ui/calee_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

// ── Stubs ─────────────────────────────────────────────────────────────────────

class _StubHub extends CaleeHubClient {
  _StubHub({this._shoppingList, this._loadError}) : super();

  final ClientShoppingList? _shoppingList;
  final Object? _loadError;

  int loadCallCount = 0;
  bool generateCalled = false;
  String? lastGenerateFrom;
  String? lastGenerateTo;
  bool getByIdCalled = false;
  int? lastGetByIdListId;
  bool updateCalled = false;
  int? lastUpdatedItemId;
  bool? lastCheckedValue;
  bool updateShouldFail = false;
  // When set, updateShoppingListItem waits on this instead of resolving
  // immediately, so a test can inspect the optimistic UI state mid-flight.
  Completer<ClientShoppingListItem>? updatePending;
  bool addItemCalled = false;
  String? lastAddedName;
  String? lastAddedCategory;
  bool deleteCalled = false;

  @override
  Future<ClientShoppingList> currentShoppingList({
    required String accessToken,
    required String from,
    required String to,
  }) async {
    loadCallCount++;
    if (_loadError != null) throw _loadError;
    return _shoppingList!;
  }

  @override
  Future<ClientShoppingList> generateShoppingList({
    required String accessToken,
    required String from,
    required String to,
    String mode = 'merge',
  }) async {
    generateCalled = true;
    lastGenerateFrom = from;
    lastGenerateTo = to;
    return _shoppingList!;
  }

  @override
  Future<ClientShoppingList> getShoppingList({
    required String accessToken,
    required int listId,
  }) async {
    getByIdCalled = true;
    lastGetByIdListId = listId;
    return _shoppingList!;
  }

  @override
  Future<ClientShoppingListItem> updateShoppingListItem({
    required String accessToken,
    required int listId,
    required int itemId,
    required bool checked,
  }) async {
    updateCalled = true;
    lastUpdatedItemId = itemId;
    lastCheckedValue = checked;

    if (updatePending != null) {
      return updatePending!.future;
    }
    if (updateShouldFail) {
      throw const CaleeHubException(statusCode: 500, message: 'Server error');
    }

    final original = _shoppingList!.items.firstWhere((i) => i.id == itemId);
    return ClientShoppingListItem(
      id: original.id,
      shoppingListId: original.shoppingListId,
      householdId: original.householdId,
      name: original.name,
      category: original.category,
      checked: checked,
      manuallyAdded: original.manuallyAdded,
      manuallyRemoved: original.manuallyRemoved,
      sortOrder: original.sortOrder,
    );
  }

  @override
  Future<ClientShoppingListItem> addShoppingListItem({
    required String accessToken,
    required int listId,
    required String name,
    String? category,
  }) async {
    addItemCalled = true;
    lastAddedName = name;
    lastAddedCategory = category;
    return ClientShoppingListItem(
      id: 999,
      shoppingListId: listId,
      householdId: 'h1',
      name: name,
      category: category,
      checked: false,
      manuallyAdded: true,
      manuallyRemoved: false,
      sortOrder: 99,
    );
  }

  @override
  Future<void> deleteShoppingListItem({
    required String accessToken,
    required int listId,
    required int itemId,
  }) async {
    deleteCalled = true;
  }
}

// ── Fixtures ───────────────────────────────────────────────────────────────────

const _kMilk = ClientShoppingListItem(
  id: 1,
  shoppingListId: 3,
  householdId: 'h1',
  name: 'Milk',
  category: 'Dairy',
  checked: false,
  manuallyAdded: false,
  manuallyRemoved: false,
  sortOrder: 0,
);

const _kTacoShells = ClientShoppingListItem(
  id: 2,
  shoppingListId: 3,
  householdId: 'h1',
  name: 'Taco shells',
  category: 'Pantry',
  checked: false,
  manuallyAdded: false,
  manuallyRemoved: false,
  sortOrder: 0,
);

ClientShoppingList _list({List<ClientShoppingListItem>? items}) {
  return ClientShoppingList(
    id: 3,
    householdId: 'h1',
    title: 'Shopping list',
    fromDate: '2024-01-15',
    toDate: '2024-01-21',
    status: 'active',
    items: items ?? [_kMilk, _kTacoShells],
  );
}

// ── Build helpers ──────────────────────────────────────────────────────────────

Widget _buildPage(_StubHub hub) {
  return MaterialApp(
    theme: CaleeTheme.buildThemeData(),
    home: ShoppingPage(hubClient: hub, accessToken: 'tok'),
  );
}

// ── Tests ──────────────────────────────────────────────────────────────────────

void main() {
  group('ShoppingPage — grouping', () {
    testWidgets('groups items by category', (tester) async {
      final hub = _StubHub(shoppingList: _list());
      await tester.pumpWidget(_buildPage(hub));
      await tester.pump();
      await tester.pump();

      expect(find.text('DAIRY'), findsOneWidget);
      expect(find.text('PANTRY'), findsOneWidget);
      expect(find.text('Milk'), findsOneWidget);
      expect(find.text('Taco shells'), findsOneWidget);
    });

    testWidgets('items with no category are grouped under Other', (
      tester,
    ) async {
      const uncategorised = ClientShoppingListItem(
        id: 5,
        shoppingListId: 3,
        householdId: 'h1',
        name: 'Mystery item',
        checked: false,
        manuallyAdded: false,
        manuallyRemoved: false,
        sortOrder: 0,
      );
      final hub = _StubHub(shoppingList: _list(items: [uncategorised]));
      await tester.pumpWidget(_buildPage(hub));
      await tester.pump();
      await tester.pump();

      expect(find.text('OTHER'), findsOneWidget);
      expect(find.text('Mystery item'), findsOneWidget);
    });
  });

  group('ShoppingPage — toggle checked', () {
    testWidgets(
      'tapping an item optimistically toggles checked before the network '
      'call resolves, and calls the stub update method',
      (tester) async {
        final pending = Completer<ClientShoppingListItem>();
        final hub = _StubHub(shoppingList: _list())..updatePending = pending;

        await tester.pumpWidget(_buildPage(hub));
        await tester.pump();
        await tester.pump();

        await tester.tap(find.text('Milk'));
        await tester.pump();

        // The network call is still pending, but the row should already
        // show as checked (strikethrough title) — this is the optimism.
        final textWidget = tester.widget<Text>(find.text('Milk'));
        expect(textWidget.style?.decoration, TextDecoration.lineThrough);

        expect(hub.updateCalled, isTrue);
        expect(hub.lastUpdatedItemId, 1);
        expect(hub.lastCheckedValue, isTrue);

        // Resolve the network call so nothing is left pending once the test
        // finishes.
        pending.complete(
          const ClientShoppingListItem(
            id: 1,
            shoppingListId: 3,
            householdId: 'h1',
            name: 'Milk',
            category: 'Dairy',
            checked: true,
            manuallyAdded: false,
            manuallyRemoved: false,
            sortOrder: 0,
          ),
        );
        await tester.pump();
        await tester.pump();
      },
    );

    testWidgets('reverts the optimistic flip when the update call fails', (
      tester,
    ) async {
      final hub = _StubHub(shoppingList: _list())..updateShouldFail = true;

      await tester.pumpWidget(_buildPage(hub));
      await tester.pump();
      await tester.pump();

      await tester.tap(find.text('Milk'));
      await tester.pump();
      await tester.pump();

      final textWidget = tester.widget<Text>(find.text('Milk'));
      expect(textWidget.style?.decoration, isNot(TextDecoration.lineThrough));
    });
  });

  group('ShoppingPage — generate', () {
    testWidgets('tapping "Generate from meal plan" calls the repository', (
      tester,
    ) async {
      final hub = _StubHub(shoppingList: _list());
      await tester.pumpWidget(_buildPage(hub));
      await tester.pump();
      await tester.pump();

      await tester.tap(find.text('Generate from meal plan'));
      await tester.pump();
      await tester.pump();

      expect(hub.generateCalled, isTrue);
    });
  });

  group('ShoppingPage — error state', () {
    testWidgets('shows a retry affordance when the initial load fails', (
      tester,
    ) async {
      final hub = _StubHub(
        loadError: const CaleeHubException(
          statusCode: 500,
          message: 'Server error',
        ),
      );
      await tester.pumpWidget(_buildPage(hub));
      await tester.pump();
      await tester.pump();

      expect(find.text('Could not load shopping list'), findsOneWidget);
      expect(find.text('Try again'), findsOneWidget);
    });

    testWidgets('tapping Try again retries the load', (tester) async {
      final hub = _StubHub(
        loadError: const CaleeHubException(
          statusCode: 500,
          message: 'Server error',
        ),
      );
      await tester.pumpWidget(_buildPage(hub));
      await tester.pump();
      await tester.pump();

      expect(hub.loadCallCount, 1);

      await tester.tap(find.text('Try again'));
      await tester.pump();
      await tester.pump();

      expect(hub.loadCallCount, greaterThan(1));
    });
  });

  group('ShoppingPage — initialWeekStart', () {
    testWidgets('autoGenerate uses the supplied week, not the current week', (
      tester,
    ) async {
      final hub = _StubHub(shoppingList: _list());
      await tester.pumpWidget(
        MaterialApp(
          theme: CaleeTheme.buildThemeData(),
          home: ShoppingPage(
            hubClient: hub,
            accessToken: 'tok',
            autoGenerate: true,
            initialWeekStart: DateTime(2024, 1, 17),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();

      expect(hub.generateCalled, isTrue);
      expect(hub.lastGenerateFrom, '2024-01-15');
      expect(hub.lastGenerateTo, '2024-01-21');
    });
  });

  group('ShoppingPage — initialListId', () {
    testWidgets('loads the specific list by id instead of the current week', (
      tester,
    ) async {
      final hub = _StubHub(shoppingList: _list());
      await tester.pumpWidget(
        MaterialApp(
          theme: CaleeTheme.buildThemeData(),
          home: ShoppingPage(
            hubClient: hub,
            accessToken: 'tok',
            initialListId: 3,
          ),
        ),
      );
      await tester.pump();
      await tester.pump();

      expect(hub.getByIdCalled, isTrue);
      expect(hub.lastGetByIdListId, 3);
      expect(hub.loadCallCount, 0);
      expect(hub.generateCalled, isFalse);
      expect(find.text('Milk'), findsOneWidget);
    });
  });

  group('ShoppingPage — add item', () {
    testWidgets('adding an item calls the stub and shows the new item', (
      tester,
    ) async {
      final hub = _StubHub(shoppingList: _list());
      await tester.pumpWidget(_buildPage(hub));
      await tester.pump();
      await tester.pump();

      await tester.tap(find.text('Add item'));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextFormField).first, 'Eggs');
      await tester.tap(find.text('Add'));
      await tester.pumpAndSettle();

      expect(hub.addItemCalled, isTrue);
      expect(hub.lastAddedName, 'Eggs');
      expect(find.text('Eggs'), findsOneWidget);
    });
  });
}
