import 'package:flutter_test/flutter_test.dart';
import 'package:calee_mobile/data/api/calee_hub_client.dart';
import 'package:calee_mobile/data/auth/session_store.dart';
import 'package:calee_mobile/data/models/client_bootstrap.dart';
import 'package:calee_mobile/features/auth/auth_repository.dart';
import 'package:calee_mobile/features/auth/session_controller.dart';

// ─── Helpers ──────────────────────────────────────────────────────────────────

ClientBootstrap _makeBootstrap() => ClientBootstrap.fromJson({});

ClientLoginResult _makeLoginResult({
  String accessToken = 'access-token',
  String refreshToken = 'refresh-token',
}) => ClientLoginResult(
  accessToken: accessToken,
  refreshToken: refreshToken,
  tokenType: 'Bearer',
  expiresIn: 3600,
  refreshExpiresIn: 86400,
  bootstrap: _makeBootstrap(),
);

ClientRefreshResult _makeRefreshResult({
  String accessToken = 'new-access-token',
}) => ClientRefreshResult(
  accessToken: accessToken,
  tokenType: 'Bearer',
  expiresIn: 3600,
);

// ─── Stub repository ──────────────────────────────────────────────────────────

class _FakeRepository implements AuthRepository {
  @override
  CaleeHubClient get hubClient => throw UnimplementedError();

  @override
  SessionStore get sessionStore => throw UnimplementedError();

  StoredSession? storedSession;
  ClientRefreshResult? refreshResult;
  Exception? bootstrapError;
  Exception? refreshError;
  bool clearSessionCalled = false;
  bool clearAuthCacheCalled = false;
  String? savedAccessToken;
  String? savedSessionAccessToken;
  String? savedSessionRefreshToken;

  @override
  Future<StoredSession?> loadStoredSession() async => storedSession;

  @override
  Future<ClientLoginResult> login({
    required String email,
    required String password,
  }) => throw UnimplementedError();

  @override
  Future<ClientRefreshResult> refresh({required String refreshToken}) async {
    if (refreshError != null) throw refreshError!;
    return refreshResult!;
  }

  @override
  Future<ClientBootstrap> bootstrap({required String accessToken}) async {
    if (bootstrapError != null) throw bootstrapError!;
    return _makeBootstrap();
  }

  @override
  Future<void> saveSession({
    required String accessToken,
    required String refreshToken,
  }) async {
    savedSessionAccessToken = accessToken;
    savedSessionRefreshToken = refreshToken;
  }

  @override
  Future<void> saveAccessToken(String accessToken) async {
    savedAccessToken = accessToken;
  }

  @override
  Future<void> clearSession() async {
    clearSessionCalled = true;
  }

  @override
  Future<ClientLoginResult> register({
    required String email,
    required String confirmEmail,
    required String redeemCode,
    required String password,
  }) => throw UnimplementedError();

  @override
  void clearAuthCache() {
    clearAuthCacheCalled = true;
  }
}

// ─── Tests ────────────────────────────────────────────────────────────────────

void main() {
  group('SessionController', () {
    late _FakeRepository repo;
    late SessionController controller;

    setUp(() {
      repo = _FakeRepository();
      controller = SessionController(repository: repo);
    });

    tearDown(() {
      controller.dispose();
    });

    // ── restoreSession ────────────────────────────────────────────────────────

    test(
      'restoreSession with no stored session sets isRestoringSession=false and signed out',
      () async {
        repo.storedSession = null;

        await controller.restoreSession();

        expect(controller.isRestoringSession, isFalse);
        expect(controller.isSignedIn, isFalse);
        expect(controller.accessToken, isNull);
        expect(controller.bootstrap, isNull);
      },
    );

    test(
      'restoreSession with stored session loads bootstrap and signs in',
      () async {
        repo.storedSession = const StoredSession(
          accessToken: 'at',
          refreshToken: 'rt',
        );

        await controller.restoreSession();

        expect(controller.isRestoringSession, isFalse);
        expect(controller.isSignedIn, isTrue);
        expect(controller.accessToken, 'at');
        expect(controller.refreshToken, 'rt');
        expect(controller.bootstrap, isNotNull);
        expect(repo.clearAuthCacheCalled, isTrue);
      },
    );

    test('restoreSession failure clears session and signs out', () async {
      repo.storedSession = const StoredSession(
        accessToken: 'at',
        refreshToken: 'rt',
      );
      repo.bootstrapError = Exception('network error');

      await controller.restoreSession();

      expect(controller.isRestoringSession, isFalse);
      expect(controller.isSignedIn, isFalse);
      expect(repo.clearSessionCalled, isTrue);
    });

    // ── handleUnauthorized ────────────────────────────────────────────────────

    test(
      'handleUnauthorized without refresh token signs out and returns null',
      () async {
        controller.refreshToken = null;

        final result = await controller.handleUnauthorized();

        expect(result, isNull);
        expect(controller.isSignedIn, isFalse);
        expect(repo.clearSessionCalled, isTrue);
      },
    );

    test(
      'handleUnauthorized with refresh success saves access token and returns it',
      () async {
        controller.refreshToken = 'rt';
        repo.refreshResult = _makeRefreshResult(accessToken: 'new-at');

        final result = await controller.handleUnauthorized();

        expect(result, 'new-at');
        expect(controller.accessToken, 'new-at');
        expect(repo.savedAccessToken, 'new-at');
      },
    );

    test(
      'handleUnauthorized refresh failure clears session and returns null',
      () async {
        controller.refreshToken = 'rt';
        repo.refreshError = Exception('refresh failed');

        final result = await controller.handleUnauthorized();

        expect(result, isNull);
        expect(controller.accessToken, isNull);
        expect(controller.refreshToken, isNull);
        expect(controller.bootstrap, isNull);
        expect(repo.clearSessionCalled, isTrue);
      },
    );

    // ── completeSignIn ────────────────────────────────────────────────────────

    test('completeSignIn saves session and updates state', () async {
      final loginResult = _makeLoginResult(
        accessToken: 'at2',
        refreshToken: 'rt2',
      );

      await controller.completeSignIn(loginResult);

      expect(controller.accessToken, 'at2');
      expect(controller.refreshToken, 'rt2');
      expect(controller.bootstrap, loginResult.bootstrap);
      expect(repo.savedSessionAccessToken, 'at2');
      expect(repo.savedSessionRefreshToken, 'rt2');
      expect(repo.clearAuthCacheCalled, isTrue);
    });

    // ── updateBootstrap ───────────────────────────────────────────────────────

    test('updateBootstrap updates bootstrap in memory', () {
      final bs = _makeBootstrap();
      controller.updateBootstrap(bs);
      expect(controller.bootstrap, bs);
    });

    // ── signOut ───────────────────────────────────────────────────────────────

    test('signOut clears session and state', () async {
      controller.accessToken = 'at';
      controller.refreshToken = 'rt';
      controller.bootstrap = _makeBootstrap();

      await controller.signOut();

      expect(controller.accessToken, isNull);
      expect(controller.refreshToken, isNull);
      expect(controller.bootstrap, isNull);
      expect(repo.clearSessionCalled, isTrue);
      expect(repo.clearAuthCacheCalled, isTrue);
    });

    // ── notifyListeners ───────────────────────────────────────────────────────

    test('restoreSession notifies listeners', () async {
      int notifyCount = 0;
      controller.addListener(() => notifyCount++);
      repo.storedSession = null;

      await controller.restoreSession();

      expect(notifyCount, greaterThan(0));
    });
  });
}
