import 'package:flutter/foundation.dart';

import '../../data/api/calee_hub_client.dart';
import 'display_setup_repository.dart';

class DisplayActivationController extends ChangeNotifier {
  DisplayActivationController({required this.repository});

  final DisplaySetupRepository repository;

  bool isLoading = false;
  String? errorMessage;

  Future<bool> activate({
    required String accessToken,
    required String token,
  }) async {
    isLoading = true;
    errorMessage = null;
    notifyListeners();

    try {
      await repository.approveDisplayLogin(
        accessToken: accessToken,
        token: token,
      );
      isLoading = false;
      notifyListeners();
      return true;
    } on CaleeHubException catch (e) {
      isLoading = false;
      errorMessage = e.message;
      notifyListeners();
      return false;
    } catch (_) {
      isLoading = false;
      errorMessage = 'Unable to connect the display. Please try again.';
      notifyListeners();
      return false;
    }
  }
}
