import 'package:flutter/foundation.dart';

import '../../data/api/calee_hub_client.dart';
import 'auth_repository.dart';

class ForgotPasswordController extends ChangeNotifier {
  ForgotPasswordController({required this.repository});

  final AuthRepository repository;

  bool isLoading = false;
  bool didSend = false;
  String? errorMessage;

  Future<void> requestReset({required String email}) async {
    isLoading = true;
    didSend = false;
    errorMessage = null;
    notifyListeners();

    try {
      await repository.requestPasswordReset(email: email);
      didSend = true;
    } on CaleeHubException catch (e) {
      errorMessage = e.message;
    } catch (_) {
      errorMessage = 'Unable to send reset instructions. Please try again.';
    } finally {
      isLoading = false;
      notifyListeners();
    }
  }
}
