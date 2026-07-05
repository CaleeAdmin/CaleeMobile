// Unit tests for ShoppingController.
//
// Covers: the controller uses an explicitly supplied week range for
// load/generate instead of always defaulting to today's calendar week (see
// MealsPage, which now passes its visible week through to ShoppingPage).

import 'package:calee_mobile/data/api/calee_hub_client.dart';
import 'package:calee_mobile/data/models/client_shopping_list.dart';
import 'package:calee_mobile/features/shopping/shopping_controller.dart';
import 'package:calee_mobile/features/shopping/shopping_repository.dart';
import 'package:flutter_test/flutter_test.dart';

class _StubHub extends CaleeHubClient {
  _StubHub() : super();

  String? lastLoadFrom;
  String? lastLoadTo;
  String? lastGenerateFrom;
  String? lastGenerateTo;

  @override
  Future<ClientShoppingList> currentShoppingList({
    required String accessToken,
    required String from,
    required String to,
  }) async {
    lastLoadFrom = from;
    lastLoadTo = to;
    return _list(from: from, to: to);
  }

  @override
  Future<ClientShoppingList> generateShoppingList({
    required String accessToken,
    required String from,
    required String to,
    String mode = 'merge',
  }) async {
    lastGenerateFrom = from;
    lastGenerateTo = to;
    return _list(from: from, to: to);
  }
}

ClientShoppingList _list({required String from, required String to}) {
  return ClientShoppingList(
    id: 1,
    householdId: 'h1',
    title: 'Shopping list',
    fromDate: from,
    toDate: to,
    status: 'active',
    items: const [],
  );
}

String _fmt(DateTime d) {
  final y = d.year.toString().padLeft(4, '0');
  final m = d.month.toString().padLeft(2, '0');
  final day = d.day.toString().padLeft(2, '0');
  return '$y-$m-$day';
}

ShoppingController _controllerFor(
  CaleeHubClient hub, {
  DateTime? start,
  DateTime? end,
}) {
  final repo = ShoppingRepository(hubClient: hub, accessToken: 't');
  return ShoppingController(
    repository: repo,
    initialWeekStart: start,
    initialWeekEnd: end,
  );
}

void main() {
  group('ShoppingController — supplied week range', () {
    test('exposes the supplied range via weekStartStr/weekEndStr', () {
      final controller = _controllerFor(
        _StubHub(),
        start: DateTime(2024, 1, 1),
        end: DateTime(2024, 1, 7),
      );

      expect(controller.weekStartStr, '2024-01-01');
      expect(controller.weekEndStr, '2024-01-07');
    });

    test('load() requests the supplied range, not the current week', () async {
      final hub = _StubHub();
      final controller = _controllerFor(
        hub,
        start: DateTime(2024, 1, 1),
        end: DateTime(2024, 1, 7),
      );

      await controller.load();

      expect(hub.lastLoadFrom, '2024-01-01');
      expect(hub.lastLoadTo, '2024-01-07');
    });

    test(
      'generate() requests the supplied range, not the current week',
      () async {
        final hub = _StubHub();
        final controller = _controllerFor(
          hub,
          start: DateTime(2024, 1, 1),
          end: DateTime(2024, 1, 7),
        );

        await controller.generate();

        expect(hub.lastGenerateFrom, '2024-01-01');
        expect(hub.lastGenerateTo, '2024-01-07');
      },
    );
  });

  group('ShoppingController — default week', () {
    test('defaults to the current Monday-to-Sunday week when no range is '
        'supplied', () {
      final controller = _controllerFor(_StubHub());

      final now = DateTime.now();
      final monday = DateTime(now.year, now.month, now.day - (now.weekday - 1));
      final sunday = DateTime(monday.year, monday.month, monday.day + 6);

      expect(controller.weekStartStr, _fmt(monday));
      expect(controller.weekEndStr, _fmt(sunday));
    });
  });
}
