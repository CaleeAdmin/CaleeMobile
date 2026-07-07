import 'package:flutter/foundation.dart';

import '../../data/models/client_meal.dart';
import 'meals_repository.dart';

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

class MealsController extends ChangeNotifier {
  MealsController({required this.repository}) {
    _weekStart = _mondayOf(DateTime.now());
  }

  final MealsRepository repository;

  late DateTime _weekStart;
  bool isLoading = false;
  bool isSaving = false;
  bool isCopying = false;
  Object? error;
  ClientMealList? mealList;

  DateTime get weekStart => _weekStart;

  DateTime get weekEnd =>
      DateTime(_weekStart.year, _weekStart.month, _weekStart.day + 6);

  String get weekStartStr => _formatDate(_weekStart);
  String get weekEndStr => _formatDate(weekEnd);

  bool get isCurrentWeek {
    final today = _mondayOf(DateTime.now());
    return _weekStart.year == today.year &&
        _weekStart.month == today.month &&
        _weekStart.day == today.day;
  }

  Future<void> load() async {
    if (isLoading) return;
    isLoading = true;
    error = null;
    notifyListeners();

    try {
      mealList = await repository.loadWeek(from: weekStartStr, to: weekEndStr);
      error = null;
    } catch (e) {
      error = e;
    } finally {
      isLoading = false;
      notifyListeners();
    }
  }

  void previousWeek() {
    _weekStart = DateTime(
      _weekStart.year,
      _weekStart.month,
      _weekStart.day - 7,
    );
    load();
  }

  void nextWeek() {
    _weekStart = DateTime(
      _weekStart.year,
      _weekStart.month,
      _weekStart.day + 7,
    );
    load();
  }

  void goToCurrentWeek() {
    _weekStart = _mondayOf(DateTime.now());
    load();
  }

  ClientMeal? mealFor(String date, String mealType) {
    return mealList?.meals
        .where((m) => m.mealDate == date && m.mealType == mealType)
        .firstOrNull;
  }

  Future<void> createMeal({
    required String mealDate,
    required String mealType,
    required String title,
    String? notes,
    int? templateId,
    int? starterTemplateId,
  }) async {
    isSaving = true;
    notifyListeners();
    try {
      await repository.createMeal(
        mealDate: mealDate,
        mealType: mealType,
        title: title,
        notes: notes,
        templateId: templateId,
        starterTemplateId: starterTemplateId,
      );
      await load();
    } finally {
      isSaving = false;
      notifyListeners();
    }
  }

  Future<void> updateMeal({
    required int mealId,
    String? title,
    String? notes,
    String? status,
  }) async {
    isSaving = true;
    notifyListeners();
    try {
      await repository.updateMeal(
        mealId: mealId,
        title: title,
        notes: notes,
        status: status,
      );
      await load();
    } finally {
      isSaving = false;
      notifyListeners();
    }
  }

  Future<void> deleteMeal(int mealId) async {
    isSaving = true;
    notifyListeners();
    try {
      await repository.deleteMeal(mealId);
      await load();
    } finally {
      isSaving = false;
      notifyListeners();
    }
  }

  Future<ClientMealCopyWeekResult> copyPreviousWeekToVisibleWeek({
    required bool overwriteExisting,
  }) async {
    final sourceStart = DateTime(
      _weekStart.year,
      _weekStart.month,
      _weekStart.day - 7,
    );
    final sourceEnd = DateTime(
      sourceStart.year,
      sourceStart.month,
      sourceStart.day + 6,
    );
    isCopying = true;
    notifyListeners();
    try {
      final result = await repository.copyWeek(
        sourceFrom: _formatDate(sourceStart),
        sourceTo: _formatDate(sourceEnd),
        targetFrom: weekStartStr,
        overwriteExisting: overwriteExisting,
      );
      await load();
      return result;
    } finally {
      isCopying = false;
      notifyListeners();
    }
  }
}
