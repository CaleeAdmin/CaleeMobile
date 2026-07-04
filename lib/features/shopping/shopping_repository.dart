import '../../data/api/calee_hub_client.dart';
import '../../data/models/client_shopping_list.dart';

class ShoppingRepository {
  ShoppingRepository({required this.hubClient, required this.accessToken});

  final CaleeHubClient hubClient;
  final String accessToken;

  Future<ClientShoppingList> loadCurrent({
    required String from,
    required String to,
  }) => hubClient.currentShoppingList(
    accessToken: accessToken,
    from: from,
    to: to,
  );

  Future<ClientShoppingList> generate({
    required String from,
    required String to,
    String mode = 'merge',
  }) => hubClient.generateShoppingList(
    accessToken: accessToken,
    from: from,
    to: to,
    mode: mode,
  );

  Future<ClientShoppingListItem> updateItemChecked({
    required int listId,
    required int itemId,
    required bool checked,
  }) => hubClient.updateShoppingListItem(
    accessToken: accessToken,
    listId: listId,
    itemId: itemId,
    checked: checked,
  );

  Future<ClientShoppingListItem> addItem({
    required int listId,
    required String name,
    String? category,
  }) => hubClient.addShoppingListItem(
    accessToken: accessToken,
    listId: listId,
    name: name,
    category: category,
  );

  Future<void> deleteItem({required int listId, required int itemId}) =>
      hubClient.deleteShoppingListItem(
        accessToken: accessToken,
        listId: listId,
        itemId: itemId,
      );
}
