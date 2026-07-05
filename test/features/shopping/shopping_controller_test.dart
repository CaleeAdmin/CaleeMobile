// Unit tests for ShoppingController.
//
// Covers: with no initialWeekStart it defaults to the current Monday-aligned
// week; a supplied initialWeekStart is used instead (snapped to its Monday),
// so load()/generate() request that week rather than today's; loadById()
// loads a specific list regardless of the current week.

import 'package:calee_mobile/data/api/calee_hub_client.dart';
import 'package:calee_mobile/data/models/client_shopping_list.dart';
import 'package:calee_mobile/features/shopping/shopping_controller.dart';
import 'package:calee_mobile/features/shopping/shopping_repository.dart';
import 'package:flutter_test/flutter_test.dart';

// ── Stubs ─────────────────────────────────────────────────────────────────────

class _StubHub extends CaleeHubClient {
  _StubHub() : super();

  final List<({String from, String to})> currentCalls = [];
  final List<({String from, String to, String mode})> generateCalls = [];
  final List<int> getByIdCalls = [];
  Object? getByIdError;

  @override
  Future<ClientShoppingList> currentShoppingList({
    required String accessToken,
    required String from,
    required String to,
  }) async {
    currentCalls.add((from: from, to: to));
    return _list(from: from, to: to);
  }

  @override
  Future<ClientShoppingList> generateShoppingList({
    required String accessToken,
    required String from,
    required String to,
    String mode = 'merge',
  }) async {
    generateCalls.add((from: from, to: to, mode: mode));
    return _list(from: from, to: to);
  }

  @override
  Future<ClientShoppingList> getShoppingList({
    required String accessToken,
    required int listId,
  }) async {
    getByIdCalls.add(listId);
    if (getByIdError != null) throw getByIdError!;
    return _list(from: '2024-01-15', to: '2024-01-21', id: listId);
  }

  ClientShoppingList _list({
    required String from,
    required String to,
    int id = 3,
  }) {
    return ClientShoppingList(
      id: id,
      householdId: 'h1',
      title: 'Shopping list',
      fromDate: from,
      toDate: to,
      status: 'active',
      items: const [],
    );
  }
}

// ── Helpers ────────────────────────────────────────────────────────────────────

String _fmt(DateTime d) {
  final y = d.year.toString().padLeft(4, '0');
  final m = d.month.toString().padLeft(2, '0');
  final day = d.day.toString().padLeft(2, '0');
  return '$y-$m-$day';
}

DateTime _mondayOf(DateTime date) =>
    DateTime(date.year, date.month, date.day - (date.weekday - 1));

ShoppingController _controller(_StubHub hub, {DateTime? initialWeekStart}) {
  return ShoppingController(
    repository: ShoppingRepository(hubClient: hub, accessToken: 'tok'),
    initialWeekStart: initialWeekStart,
  );
}

// ── Tests ──────────────────────────────────────────────────────────────────────

void main() {
  group('ShoppingController — week defaults', () {
    test('defaults to the current Monday-aligned week when no initialWeekStart '
        'is supplied', () {
      final controller = _controller(_StubHub());
      final expectedMonday = _mondayOf(DateTime.now());

      expect(controller.weekStartStr, _fmt(expectedMonday));
      expect(
        controller.weekEndStr,
        _fmt(expectedMonday.add(const Duration(days: 6))),
      );
    });

    test('uses the supplied initialWeekStart week instead of today', () {
      // A Wednesday, deliberately not Monday-aligned and not "this week".
      final visibleWeekDay = DateTime(2024, 1, 17);
      final controller = _controller(
        _StubHub(),
        initialWeekStart: visibleWeekDay,
      );

      expect(controller.weekStartStr, '2024-01-15');
      expect(controller.weekEndStr, '2024-01-21');
    });
  });

  group('ShoppingController — load/generate use the supplied week', () {
    test('load() requests the supplied week, not the current week', () async {
      final hub = _StubHub();
      final controller = _controller(
        hub,
        initialWeekStart: DateTime(2024, 1, 15),
      );

      await controller.load();

      expect(hub.currentCalls.single.from, '2024-01-15');
      expect(hub.currentCalls.single.to, '2024-01-21');
    });

    test(
      'generate() requests the supplied week, not the current week',
      () async {
        final hub = _StubHub();
        final controller = _controller(
          hub,
          initialWeekStart: DateTime(2024, 1, 15),
        );

        await controller.generate();

        expect(hub.generateCalls.single.from, '2024-01-15');
        expect(hub.generateCalls.single.to, '2024-01-21');
        expect(hub.generateCalls.single.mode, 'merge');
      },
    );
  });

  group('ShoppingController.loadById', () {
    test(
      'loads a specific list by id regardless of the current week',
      () async {
        final hub = _StubHub();
        final controller = _controller(hub);

        await controller.loadById(42);

        expect(hub.getByIdCalls.single, 42);
        expect(controller.shoppingList?.id, 42);
        expect(controller.error, isNull);
      },
    );

    test('surfaces an error when the list cannot be found', () async {
      final hub = _StubHub()
        ..getByIdError = const CaleeHubException(
          statusCode: 404,
          message: 'Not found',
        );
      final controller = _controller(hub);

      await controller.loadById(99);

      expect(controller.shoppingList, isNull);
      expect(controller.error, isNotNull);
    });
  });
}
