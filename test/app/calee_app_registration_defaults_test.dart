// Tests that account creation flow proceeds to next screen even when
// the post-registration profile defaulting step fails.

import 'package:calee_mobile/app/calee_app.dart';
import 'package:calee_mobile/data/api/calee_hub_client.dart';
import 'package:calee_mobile/data/auth/session_store.dart';
import 'package:calee_mobile/data/device/device_profile_defaults_provider.dart';
import 'package:calee_mobile/data/models/client_bootstrap.dart';
import 'package:calee_mobile/data/models/device_profile_defaults.dart';
import 'package:calee_mobile/features/auth/auth_repository.dart';
import 'package:calee_mobile/features/auth/session_controller.dart';
import 'package:calee_mobile/features/calendar_follow/calendar_follow_link_controller.dart';
import 'package:calee_mobile/features/display_setup/display_activation_controller.dart';
import 'package:calee_mobile/features/display_setup/display_setup_link_controller.dart';
import 'package:calee_mobile/features/display_setup/display_setup_repository.dart';
import 'package:calee_mobile/features/local_subscriber/local_calendar_subscription_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _kBootstrap = ClientBootstrap(
  account: ClientAccount(
    id: 'u1',
    displayName: 'Test User',
    primaryEmail: 'test@example.com',
    timeZone: 'Australia/Perth',
    status: 'active',
  ),
  services: [],
  contexts: ClientContexts(households: [], organisations: []),
  availableContexts: [],
  capabilities: {},
);

ClientLoginResult _makeLoginResult() => ClientLoginResult(
  accessToken: 'access-token',
  refreshToken: 'refresh-token',
  tokenType: 'Bearer',
  expiresIn: 3600,
  refreshExpiresIn: 86400,
  bootstrap: _kBootstrap,
);

class _FakeAuthRepository extends AuthRepository {
  _FakeAuthRepository()
    : super(hubClient: CaleeHubClient(), sessionStore: SessionStore());

  @override
  Future<ClientLoginResult> register({
    required String firstName,
    required String lastName,
    required String email,
    required String confirmEmail,
    required String redeemCode,
    required String password,
    required String confirmPassword,
  }) async => _makeLoginResult();

  @override
  void clearAuthCache() {}

  @override
  Future<void> saveSession({
    required String accessToken,
    required String refreshToken,
  }) async {}
}

class _FakeSessionController extends SessionController {
  _FakeSessionController(AuthRepository repo) : super(repository: repo);

  @override
  Future<void> restoreSession() async {
    isRestoringSession = false;
    notifyListeners();
  }

  @override
  Future<void> completeSignIn(ClientLoginResult result) async {
    accessToken = result.accessToken;
    refreshToken = result.refreshToken;
    bootstrap = result.bootstrap;
    notifyListeners();
  }
}

class _ThrowingProvider extends DeviceProfileDefaultsProvider {
  @override
  Future<DeviceProfileDefaults> load() async {
    throw Exception('platform channel unavailable in tests');
  }
}

class _FakeFollowLinkController extends CalendarFollowLinkController {
  @override
  Future<void> init() async {}
}

class _FakeDisplaySetupLinkController extends DisplaySetupLinkController {
  @override
  Future<void> init() async {}
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets(
    'registration proceeds past account creation even when profile defaults provider throws',
    (tester) async {
      final repo = _FakeAuthRepository();
      final session = _FakeSessionController(repo);
      final hub = CaleeHubClient();

      final deps = CaleeAppTestDependencies(
        hubClient: hub,
        sessionController: session,
        displaySetupLinkController: _FakeDisplaySetupLinkController(),
        followLinkController: _FakeFollowLinkController(),
        displayActivationController: DisplayActivationController(
          repository: DisplaySetupRepository(hubClient: hub),
        ),
        localSubscriptionRepo: LocalCalendarSubscriptionRepository(),
        deviceProfileDefaultsProvider: _ThrowingProvider(),
      );

      await tester.pumpWidget(CaleeApp.forTesting(testDeps: deps));
      await tester.pump();

      // Navigate to CreateAccountPage
      await tester.tap(find.text('Create account'));
      await tester.pump();
      expect(find.text('Create your Calee account'), findsOneWidget);

      // Fill in the registration form
      await tester.enterText(find.byType(TextFormField).at(0), 'Jane');
      await tester.enterText(find.byType(TextFormField).at(1), 'Smith');
      await tester.enterText(
        find.byType(TextFormField).at(2),
        'jane@example.com',
      );
      await tester.enterText(
        find.byType(TextFormField).at(3),
        'jane@example.com',
      );
      await tester.enterText(find.byType(TextFormField).at(4), 'REDEEM');
      await tester.enterText(find.byType(TextFormField).at(5), 'password123');
      await tester.enterText(find.byType(TextFormField).at(6), 'password123');

      // Submit
      final createButton = find.widgetWithText(FilledButton, 'Create account');
      final listView = find.byType(ListView);

      for (var i = 0; i < 8 && createButton.evaluate().isEmpty; i++) {
        await tester.drag(listView, const Offset(0, -300));
        await tester.pump();
      }

      expect(createButton, findsOneWidget);
      await tester.tap(createButton);
      // Process the tap, the async register() call, and the state rebuild.
      await tester.pump();
      await tester.pump();
      await tester.pump();

      // App must not be stuck on the registration page.
      // The throwing profile defaults provider must not block onboarding.
      expect(find.text('Create your Calee account'), findsNothing);
    },
  );
}
