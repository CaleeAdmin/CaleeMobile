import 'package:flutter/foundation.dart';

import '../../data/api/calee_hub_client.dart';
import '../../data/models/client_bootstrap.dart';
import 'auth_repository.dart';

class CreateAccountController extends ChangeNotifier {
  CreateAccountController({required this.repository});

  final AuthRepository repository;

  bool isLoading = false;
  String? errorMessage;
  String? errorCode;

  bool get isRetryable => errorCode == 'ONBOARDING_RETRYABLE';

  Future<ClientLoginResult?> register({
    required String firstName,
    required String lastName,
    required String email,
    required String confirmEmail,
    required String redeemCode,
    required String password,
    required String confirmPassword,
  }) async {
    isLoading = true;
    errorMessage = null;
    errorCode = null;
    notifyListeners();

    try {
      final result = await repository.register(
        firstName: firstName,
        lastName: lastName,
        email: email,
        confirmEmail: confirmEmail,
        redeemCode: redeemCode,
        password: password,
        confirmPassword: confirmPassword,
      );
      isLoading = false;
      notifyListeners();
      return result;
    } on CaleeHubException catch (e) {
      isLoading = false;
      errorCode = e.code;
      errorMessage = _messageForException(e);
      notifyListeners();
      return null;
    } catch (_) {
      isLoading = false;
      errorCode = null;
      errorMessage = 'Unable to create account. Please try again.';
      notifyListeners();
      return null;
    }
  }

  String _messageForException(CaleeHubException e) {
    switch (e.code) {
      case 'ACCOUNT_EXISTS_SIGN_IN':
        return 'This email already has a Calee account. Please sign in instead.';
      case 'ONBOARDING_RETRYABLE':
        return 'Calee did not finish setup. Please tap Retry.';
      case 'ONBOARDING_SUPPORT_REQUIRED':
        return 'Calee could not finish setup automatically. Please contact Calee support.';
      case 'PORTAL_APP_PASSWORD_UNAVAILABLE':
        return 'Calee could not finish setting up your calendar service. Please contact Calee support.';
      default:
        return e.message;
    }
  }
}
