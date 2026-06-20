import 'package:flutter/foundation.dart';

import '../../data/api/calee_hub_client.dart';
import '../../data/models/client_bootstrap.dart';
import 'auth_repository.dart';

class CreateAccountController extends ChangeNotifier {
  CreateAccountController({required this.repository});

  final AuthRepository repository;

  bool isLoading = false;
  String? errorMessage;

  Future<ClientLoginResult?> register({
    required String email,
    required String password,
    required String displayName,
  }) async {
    isLoading = true;
    errorMessage = null;
    notifyListeners();

    try {
      final result = await repository.register(
        email: email,
        password: password,
        displayName: displayName,
      );
      isLoading = false;
      notifyListeners();
      return result;
    } on CaleeHubException catch (e) {
      isLoading = false;
      errorMessage = e.message;
      notifyListeners();
      return null;
    } catch (_) {
      isLoading = false;
      errorMessage = 'Unable to create account. Please try again.';
      notifyListeners();
      return null;
    }
  }
}
