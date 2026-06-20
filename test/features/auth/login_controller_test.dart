import 'package:flutter_test/flutter_test.dart';
import 'package:calee_mobile/data/api/calee_hub_client.dart';
import 'package:calee_mobile/data/auth/session_store.dart';
import 'package:calee_mobile/data/models/client_bootstrap.dart';
import 'package:calee_mobile/features/auth/auth_repository.dart';
import 'package:calee_mobile/features/auth/login_controller.dart';

// ─── Helpers ──────────────────────────────────────────────────────────────────

ClientLoginResult _makeLoginResult() => ClientLoginResult(
  accessToken: 'at',
  refreshToken: 'rt',
  tokenType: 'Bearer',
  expiresIn: 3600,
  refreshExpiresIn: 86400,
  bootstrap: ClientBootstrap.fromJson({}),
);

// ─── Stub repository ──────────────────────────────────────────────────────────

class _FakeRepository implements AuthRepository {
  @override
  CaleeHubClient get hubClient => throw UnimplementedError();

  @override
  SessionStore get sessionStore => throw UnimplementedError();

  ClientLoginResult? loginResult;
  Exception? loginError;

  @override
  Future<ClientLoginResult> login({
    required String email,
    required String password,
  }) async {
    if (loginError != null) throw loginError!;
    return loginResult!;
  }

  @override
  Future<StoredSession?> loadStoredSession() => throw UnimplementedError();

  @override
  Future<ClientRefreshResult> refresh({required String refreshToken}) =>
      throw UnimplementedError();

  @override
  Future<ClientBootstrap> bootstrap({required String accessToken}) =>
      throw UnimplementedError();

  @override
  Future<void> saveSession({
    required String accessToken,
    required String refreshToken,
  }) => throw UnimplementedError();

  @override
  Future<void> saveAccessToken(String accessToken) =>
      throw UnimplementedError();

  @override
  Future<ClientLoginResult> register({
    required String email,
    required String password,
    required String displayName,
  }) => throw UnimplementedError();

  @override
  Future<void> clearSession() => throw UnimplementedError();

  @override
  void clearAuthCache() {}
}

// ─── Tests ────────────────────────────────────────────────────────────────────

void main() {
  group('LoginController', () {
    late _FakeRepository repo;
    late LoginController controller;

    setUp(() {
      repo = _FakeRepository();
      controller = LoginController(repository: repo);
    });

    tearDown(() {
      controller.dispose();
    });

    test('successful signIn returns result and clears errorMessage', () async {
      repo.loginResult = _makeLoginResult();
      controller.errorMessage = 'stale error';

      final result = await controller.signIn(
        email: 'user@example.com',
        password: 'secret',
      );

      expect(result, isNotNull);
      expect(result!.accessToken, 'at');
      expect(controller.errorMessage, isNull);
    });

    test('CaleeHubException sets backend error message', () async {
      repo.loginError = const CaleeHubException(
        statusCode: 401,
        message: 'Invalid credentials',
      );

      final result = await controller.signIn(
        email: 'user@example.com',
        password: 'wrong',
      );

      expect(result, isNull);
      expect(controller.errorMessage, 'Invalid credentials');
    });

    test('unknown exception sets generic error message', () async {
      repo.loginError = Exception('unexpected');

      final result = await controller.signIn(
        email: 'user@example.com',
        password: 'secret',
      );

      expect(result, isNull);
      expect(controller.errorMessage, 'Unable to sign in. Please try again.');
    });

    test('isLoading toggles true then false around the request', () async {
      final loadingStates = <bool>[];
      controller.addListener(() => loadingStates.add(controller.isLoading));

      repo.loginResult = _makeLoginResult();
      await controller.signIn(email: 'user@example.com', password: 'secret');

      expect(loadingStates, containsAllInOrder([true, false]));
      expect(controller.isLoading, isFalse);
    });

    test('isLoading is false after failed sign-in', () async {
      repo.loginError = const CaleeHubException(
        statusCode: 400,
        message: 'Bad request',
      );

      await controller.signIn(email: 'user@example.com', password: 'secret');

      expect(controller.isLoading, isFalse);
    });
  });
}
