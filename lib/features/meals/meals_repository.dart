import '../../data/api/calee_hub_client.dart';
import '../../data/models/client_meal.dart';
import '../../data/models/client_shopping_list.dart';

class MealsRepository {
  MealsRepository({required this.hubClient, required this.accessToken});

  final CaleeHubClient hubClient;
  final String accessToken;

  Future<ClientMealList> loadWeek({required String from, required String to}) =>
      hubClient.meals(accessToken: accessToken, from: from, to: to);

  Future<ClientMealList> loadToday(String todayStr) =>
      hubClient.meals(accessToken: accessToken, from: todayStr, to: todayStr);

  Future<ClientMealTemplateList> mealTemplates({String? mealType}) =>
      hubClient.mealTemplates(accessToken: accessToken, mealType: mealType);

  Future<List<ClientStarterMealTemplate>> mealStarterTemplates({
    String? mealType,
    String? pack,
  }) => hubClient.mealStarterTemplates(
    accessToken: accessToken,
    mealType: mealType,
    pack: pack,
  );

  Future<ClientMealTemplate> createMealTemplate({
    required String name,
    required String defaultMealType,
    String? notes,
    String? icon,
    bool? isFavourite,
  }) => hubClient.createMealTemplate(
    accessToken: accessToken,
    name: name,
    defaultMealType: defaultMealType,
    notes: notes,
    icon: icon,
    isFavourite: isFavourite,
  );

  Future<ClientMealTemplate> updateMealTemplate({
    required int templateId,
    String? name,
    String? notes,
    bool? isFavourite,
  }) => hubClient.updateMealTemplate(
    accessToken: accessToken,
    templateId: templateId,
    name: name,
    notes: notes,
    isFavourite: isFavourite,
  );

  Future<void> deleteMealTemplate(int templateId) => hubClient
      .deleteMealTemplate(accessToken: accessToken, templateId: templateId);

  Future<ClientMeal> createMeal({
    required String mealDate,
    required String mealType,
    required String title,
    String? notes,
    int? templateId,
    int? starterTemplateId,
  }) => hubClient.createMeal(
    accessToken: accessToken,
    mealDate: mealDate,
    mealType: mealType,
    title: title,
    notes: notes,
    templateId: templateId,
    starterTemplateId: starterTemplateId,
  );

  Future<ClientMeal> updateMeal({
    required int mealId,
    String? mealDate,
    String? mealType,
    String? title,
    String? notes,
    String? status,
  }) => hubClient.updateMeal(
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

  Future<ClientMealCopyWeekResult> copyWeek({
    required String sourceFrom,
    required String sourceTo,
    required String targetFrom,
    bool overwriteExisting = false,
  }) => hubClient.copyMealWeek(
    accessToken: accessToken,
    sourceFrom: sourceFrom,
    sourceTo: sourceTo,
    targetFrom: targetFrom,
    mode: overwriteExisting ? 'overwrite_existing' : 'skip_existing',
  );
}
