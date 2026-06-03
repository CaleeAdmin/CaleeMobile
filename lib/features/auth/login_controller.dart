import 'package:flutter/foundation.dart';

import '../../data/api/calee_hub_client.dart';
import '../../data/models/client_bootstrap.dart';
import 'auth_repository.dart';

class LoginController extends ChangeNotifier {
  LoginController({required this.repository});

  final AuthRepository repository;

  bool isLoading = false;
  String? errorMessage;

  Future<ClientLoginResult?> signIn({
    required String email,
    required String password,
  }) async {
    isLoading = true;
    errorMessage = null;
    notifyListeners();

    try {
      final result = await repository.login(email: email, password: password);
      return result;
    } on CaleeHubException catch (e) {
      errorMessage = e.message;
      return null;
    } catch (_) {
      errorMessage = 'Unable to sign in. Please try again.';
      return null;
    } finally {
      isLoading = false;
      notifyListeners();
    }
  }
}
