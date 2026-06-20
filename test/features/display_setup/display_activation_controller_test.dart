import 'package:flutter_test/flutter_test.dart';
import 'package:calee_mobile/data/api/calee_hub_client.dart';
import 'package:calee_mobile/features/display_setup/display_activation_controller.dart';
import 'package:calee_mobile/features/display_setup/display_setup_repository.dart';

// ─── Stub repository ──────────────────────────────────────────────────────────

class _FakeRepository implements DisplaySetupRepository {
  @override
  CaleeHubClient get hubClient => throw UnimplementedError();

  Exception? error;
  int callCount = 0;

  @override
  Future<void> approveDisplayLogin({
    required String accessToken,
    required String token,
  }) async {
    callCount++;
    if (error != null) throw error!;
  }
}

// ─── Tests ────────────────────────────────────────────────────────────────────

void main() {
  group('DisplayActivationController', () {
    late _FakeRepository repo;
    late DisplayActivationController controller;

    setUp(() {
      repo = _FakeRepository();
      controller = DisplayActivationController(repository: repo);
    });

    tearDown(() {
      controller.dispose();
    });

    test('successful activation returns true and clears errorMessage', () async {
      controller.errorMessage = 'stale';

      final result = await controller.activate(
        accessToken: 'tok',
        token: 'display-token',
      );

      expect(result, isTrue);
      expect(controller.errorMessage, isNull);
      expect(repo.callCount, 1);
    });

    test('CaleeHubException sets errorMessage and returns false', () async {
      repo.error = const CaleeHubException(
        statusCode: 404,
        message: 'Display token not found',
      );

      final result = await controller.activate(
        accessToken: 'tok',
        token: 'bad-token',
      );

      expect(result, isFalse);
      expect(controller.errorMessage, 'Display token not found');
    });

    test('expired token returns specific error message from Hub', () async {
      repo.error = const CaleeHubException(
        statusCode: 410,
        message: 'This QR code has expired. Please scan a new one.',
      );

      final result = await controller.activate(
        accessToken: 'tok',
        token: 'expired-token',
      );

      expect(result, isFalse);
      expect(controller.errorMessage, contains('expired'));
    });

    test('already consumed token returns specific error', () async {
      repo.error = const CaleeHubException(
        statusCode: 409,
        message: 'This display is already connected to an account.',
      );

      final result = await controller.activate(
        accessToken: 'tok',
        token: 'used-token',
      );

      expect(result, isFalse);
      expect(controller.errorMessage, isNotNull);
    });

    test('unknown exception sets generic errorMessage and returns false',
        () async {
      repo.error = Exception('unexpected network failure');

      final result = await controller.activate(
        accessToken: 'tok',
        token: 'tok',
      );

      expect(result, isFalse);
      expect(
        controller.errorMessage,
        'Unable to connect the display. Please try again.',
      );
    });

    test('isLoading toggles true then false around the request', () async {
      final loadingStates = <bool>[];
      controller.addListener(() => loadingStates.add(controller.isLoading));

      await controller.activate(accessToken: 'tok', token: 'tok');

      expect(loadingStates, containsAllInOrder([true, false]));
      expect(controller.isLoading, isFalse);
    });

    test('isLoading is false after failed activation', () async {
      repo.error = const CaleeHubException(
        statusCode: 500,
        message: 'Server error',
      );

      await controller.activate(accessToken: 'tok', token: 'tok');

      expect(controller.isLoading, isFalse);
    });

    test('activate calls repository with correct token and accessToken',
        () async {
      String? capturedToken;
      String? capturedAccessToken;

      final captureRepo = _CapturingRepository(
        onCall: (at, t) {
          capturedAccessToken = at;
          capturedToken = t;
        },
      );
      final ctrl = DisplayActivationController(repository: captureRepo);
      addTearDown(ctrl.dispose);

      await ctrl.activate(accessToken: 'my-access-token', token: 'my-token');

      expect(capturedAccessToken, 'my-access-token');
      expect(capturedToken, 'my-token');
    });
  });
}

class _CapturingRepository implements DisplaySetupRepository {
  _CapturingRepository({required this.onCall});

  final void Function(String accessToken, String token) onCall;

  @override
  CaleeHubClient get hubClient => throw UnimplementedError();

  @override
  Future<void> approveDisplayLogin({
    required String accessToken,
    required String token,
  }) async {
    onCall(accessToken, token);
  }
}
