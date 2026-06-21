import 'package:flutter/foundation.dart';

import '../../data/models/client_profile.dart';
import 'profile_repository.dart';

enum ProfileSaveStatus { idle, saving, saved, error }

class ProfileController extends ChangeNotifier {
  ProfileController({required this.repository});

  final ProfileRepository repository;

  ClientProfile? profile;
  bool isLoading = false;
  Object? loadError;
  ProfileSaveStatus saveStatus = ProfileSaveStatus.idle;
  String? saveError;

  Future<void> load() async {
    isLoading = true;
    loadError = null;
    notifyListeners();

    try {
      profile = await repository.loadProfile();
      loadError = null;
    } catch (e) {
      loadError = e;
    } finally {
      isLoading = false;
      notifyListeners();
    }
  }

  Future<void> save({
    required String firstName,
    required String lastName,
    String? displayName,
    String? timeZone,
    String? postalCode,
    String? countryCode,
    String? locale,
  }) async {
    saveStatus = ProfileSaveStatus.saving;
    saveError = null;
    notifyListeners();

    try {
      profile = await repository.saveProfile(
        firstName: firstName,
        lastName: lastName,
        displayName: displayName,
        timeZone: timeZone,
        postalCode: postalCode,
        countryCode: countryCode,
        locale: locale,
      );
      saveStatus = ProfileSaveStatus.saved;
    } catch (e) {
      saveStatus = ProfileSaveStatus.error;
      saveError = e is Exception ? e.toString() : 'An error occurred';
    } finally {
      notifyListeners();
    }
  }

  void clearSaveStatus() {
    saveStatus = ProfileSaveStatus.idle;
    saveError = null;
    notifyListeners();
  }
}
