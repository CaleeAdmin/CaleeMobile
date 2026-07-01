import '../../data/api/calee_hub_client.dart';
import '../../data/models/client_meal.dart';

class MealsRepository {
  MealsRepository({
    required this.hubClient,
    required this.accessToken,
  });

  final CaleeHubClient hubClient;
  final String accessToken;

  Future<ClientMealList> loadWeek({
    required String from,
    required String to,
  }) =>
      hubClient.meals(accessToken: accessToken, from: from, to: to);

  Future<ClientMealList> loadToday(String todayStr) =>
      hubClient.meals(accessToken: accessToken, from: todayStr, to: todayStr);

  Future<ClientMeal> createMeal({
    required String mealDate,
    required String mealType,
    required String title,
    String? notes,
  }) =>
      hubClient.createMeal(
        accessToken: accessToken,
        mealDate: mealDate,
        mealType: mealType,
        title: title,
        notes: notes,
      );

  Future<ClientMeal> updateMeal({
    required int mealId,
    String? mealDate,
    String? mealType,
    String? title,
    String? notes,
    String? status,
  }) =>
      hubClient.updateMeal(
        accessToken: accessToken,
        mealId: mealId,
        mealDate: mealDate,
        mealType: mealType,
        title: title,
        notes: notes,
        status: status,
      );

  Future<void> deleteMeal(int mealId) =>
      hubClient.deleteMeal(accessToken: accessToken, mealId: mealId);
}
