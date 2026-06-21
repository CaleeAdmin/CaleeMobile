import '../../data/api/calee_hub_client.dart';
import '../../data/auth/session_store.dart';
import '../../data/models/client_bootstrap.dart';

class AuthRepository {
  const AuthRepository({required this.hubClient, required this.sessionStore});

  final CaleeHubClient hubClient;
  final SessionStore sessionStore;

  Future<StoredSession?> loadStoredSession() => sessionStore.loadSession();

  Future<ClientLoginResult> login({
    required String email,
    required String password,
  }) => hubClient.login(email: email, password: password);

  Future<ClientRefreshResult> refresh({required String refreshToken}) =>
      hubClient.refresh(refreshToken: refreshToken);

  Future<ClientBootstrap> bootstrap({required String accessToken}) =>
      hubClient.bootstrap(accessToken: accessToken);

  Future<void> saveSession({
    required String accessToken,
    required String refreshToken,
  }) => sessionStore.saveSession(
    accessToken: accessToken,
    refreshToken: refreshToken,
  );

  Future<void> saveAccessToken(String accessToken) =>
      sessionStore.saveAccessToken(accessToken);

  Future<ClientLoginResult> register({
    required String firstName,
    required String lastName,
    required String email,
    required String confirmEmail,
    required String redeemCode,
    required String password,
    required String confirmPassword,
  }) => hubClient.register(
    firstName: firstName,
    lastName: lastName,
    email: email,
    confirmEmail: confirmEmail,
    redeemCode: redeemCode,
    password: password,
    confirmPassword: confirmPassword,
  );

  Future<void> clearSession() => sessionStore.clear();

  void clearAuthCache() => hubClient.clearAuthCache();
}
