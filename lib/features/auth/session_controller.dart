import 'package:flutter/foundation.dart';

import '../../data/models/client_bootstrap.dart';
import 'auth_repository.dart';

class SessionController extends ChangeNotifier {
  SessionController({required this.repository});

  final AuthRepository repository;

  String? accessToken;
  String? refreshToken;
  ClientBootstrap? bootstrap;
  bool isRestoringSession = true;
  Object? error;

  bool get isSignedIn => accessToken != null && bootstrap != null;

  Future<void> restoreSession() async {
    try {
      final session = await repository.loadStoredSession();

      if (session == null) {
        _finishWithoutSession();
      } else {
        // Set refresh token early so handleUnauthorized can transparently
        // refresh a 401 from bootstrap — it reads refreshToken synchronously.
        refreshToken = session.refreshToken;
        repository.clearAuthCache();

        final bs = await repository.bootstrap(accessToken: session.accessToken);

        // accessToken may already have been updated by handleUnauthorized
        // during a transparent retry, so keep the refreshed value if present.
        accessToken ??= session.accessToken;
        refreshToken = session.refreshToken;
        bootstrap = bs;
        isRestoringSession = false;
        error = null;
      }
    } catch (_) {
      await repository.clearSession();
      _finishWithoutSession();
    }
    notifyListeners();
  }

  Future<String?> handleUnauthorized() async {
    final storedRefreshToken = refreshToken;
    if (storedRefreshToken == null) {
      await signOut();
      return null;
    }

    try {
      final refreshed =
          await repository.refresh(refreshToken: storedRefreshToken);
      final newToken = refreshed.accessToken;
      await repository.saveAccessToken(newToken);
      accessToken = newToken;
      notifyListeners();
      return newToken;
    } catch (_) {
      await repository.clearSession();
      accessToken = null;
      refreshToken = null;
      bootstrap = null;
      notifyListeners();
      return null;
    }
  }

  Future<void> completeSignIn(ClientLoginResult result) async {
    repository.clearAuthCache();
    await repository.saveSession(
      accessToken: result.accessToken,
      refreshToken: result.refreshToken,
    );
    accessToken = result.accessToken;
    refreshToken = result.refreshToken;
    bootstrap = result.bootstrap;
    notifyListeners();
  }

  void updateBootstrap(ClientBootstrap newBootstrap) {
    bootstrap = newBootstrap;
    notifyListeners();
  }

  Future<void> signOut() async {
    repository.clearAuthCache();
    await repository.clearSession();
    accessToken = null;
    refreshToken = null;
    bootstrap = null;
    notifyListeners();
  }

  void _finishWithoutSession() {
    accessToken = null;
    refreshToken = null;
    bootstrap = null;
    isRestoringSession = false;
  }
}
