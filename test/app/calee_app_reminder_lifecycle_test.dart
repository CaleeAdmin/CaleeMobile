// Widget tests verifying CaleeApp drives the reminder coordinator at the right
// lifecycle points: a restored/fresh signed-in session refreshes reminders, an
// app resume refreshes them, and a signed-out app never does.

import 'package:calee_mobile/app/calee_app.dart';
import 'package:calee_mobile/data/api/calee_hub_client.dart';
import 'package:calee_mobile/data/auth/session_store.dart';
import 'package:calee_mobile/data/models/client_bootstrap.dart';
import 'package:calee_mobile/features/auth/auth_repository.dart';
import 'package:calee_mobile/features/auth/session_controller.dart';
import 'package:calee_mobile/features/calendar_follow/calendar_follow_link_controller.dart';
import 'package:calee_mobile/features/display_setup/display_activation_controller.dart';
import 'package:calee_mobile/features/display_setup/display_setup_link_controller.dart';
import 'package:calee_mobile/features/display_setup/display_setup_repository.dart';
import 'package:calee_mobile/features/local_subscriber/local_calendar_subscription_repository.dart';
import 'package:calee_mobile/features/notifications/calendar_reminder_coordinator.dart';
import 'package:calee_mobile/features/notifications/local_calendar_notification_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ── Fakes ─────────────────────────────────────────────────────────────────────

ClientBootstrap _stubBootstrap() => const ClientBootstrap(
  account: ClientAccount(
    id: 'u1',
    displayName: 'Test',
    primaryEmail: 'test@example.com',
    timeZone: 'Australia/Perth',
    status: 'active',
  ),
  services: [],
  contexts: ClientContexts(households: [], organisations: []),
  availableContexts: [],
  capabilities: {},
);

class _FakeSessionController extends SessionController {
  _FakeSessionController()
    : super(
        repository: AuthRepository(
          hubClient: CaleeHubClient(),
          sessionStore: SessionStore(),
        ),
      );

  @override
  Future<void> restoreSession() async {}

  @override
  Future<void> refreshBootstrap() async {}

  void finishRestore({required bool signedIn}) {
    if (signedIn) {
      accessToken = 'test_access_token';
      bootstrap = _stubBootstrap();
    } else {
      accessToken = null;
      bootstrap = null;
    }
    isRestoringSession = false;
    notifyListeners();
  }

  /// Mimics [SessionController.handleUnauthorized]'s failure path clearing the
  /// session (tokens + bootstrap) and notifying listeners.
  void simulateUnauthorizedSignOut() {
    accessToken = null;
    refreshToken = null;
    bootstrap = null;
    notifyListeners();
  }

  /// Switches the signed-in session to a different account.
  void switchAccount({required String accountId}) {
    accessToken = 'test_access_token_$accountId';
    bootstrap = ClientBootstrap(
      account: ClientAccount(
        id: accountId,
        displayName: 'Test',
        primaryEmail: '$accountId@example.com',
        timeZone: 'Australia/Perth',
        status: 'active',
      ),
      services: const [],
      contexts: const ClientContexts(households: [], organisations: []),
      availableContexts: const [],
      capabilities: const {},
    );
    notifyListeners();
  }
}

class _FakeDisplaySetupLinkController extends DisplaySetupLinkController {
  @override
  Future<void> init() async {}
}

class _FakeFollowLinkController extends CalendarFollowLinkController {
  @override
  Future<void> init() async {}
}

class _RecordingCoordinator extends CalendarReminderCoordinator {
  _RecordingCoordinator()
    : super(hubClient: CaleeHubClient(baseUri: Uri.parse('http://localhost')));

  final List<CalendarReminderRefreshReason> reasons = [];
  final List<String> begunAccounts = [];
  int endSessionCount = 0;

  @override
  int beginSession({required String accountId}) {
    begunAccounts.add(accountId);
    return super.beginSession(accountId: accountId);
  }

  @override
  Future<CalendarReminderDisableResult> endSession() async {
    endSessionCount++;
    // Do not touch the real notification service in a widget test.
    return const CalendarReminderDisableResult(
      cancelledCount: 0,
      failedCount: 0,
      manifestPersisted: true,
    );
  }

  @override
  Future<CalendarReminderRefreshResult> refresh({
    required String? accessToken,
    required CalendarReminderRefreshReason reason,
    bool force = false,
  }) async {
    reasons.add(reason);
    return CalendarReminderRefreshResult(
      reason: reason,
      status: CalendarReminderRefreshStatus.reconciled,
      completedAt: DateTime(2026),
    );
  }
}

CaleeAppTestDependencies _makeDeps({
  required SessionController session,
  required CalendarReminderCoordinator coordinator,
}) {
  final hub = CaleeHubClient(baseUri: Uri.parse('http://localhost'));
  return CaleeAppTestDependencies(
    hubClient: hub,
    sessionController: session,
    displaySetupLinkController: _FakeDisplaySetupLinkController(),
    followLinkController: _FakeFollowLinkController(),
    displayActivationController: DisplayActivationController(
      repository: DisplaySetupRepository(hubClient: hub),
    ),
    localSubscriptionRepo: LocalCalendarSubscriptionRepository(),
    reminderCoordinator: coordinator,
  );
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('restored signed-in session triggers a sessionRestored refresh', (
    tester,
  ) async {
    final session = _FakeSessionController();
    final coordinator = _RecordingCoordinator();

    await tester.pumpWidget(
      CaleeApp.forTesting(
        testDeps: _makeDeps(session: session, coordinator: coordinator),
      ),
    );

    session.finishRestore(signedIn: true);
    await tester.pump();

    expect(
      coordinator.reasons,
      contains(CalendarReminderRefreshReason.sessionRestored),
    );
  });

  testWidgets('signed-out app does not trigger any reminder refresh', (
    tester,
  ) async {
    final session = _FakeSessionController();
    final coordinator = _RecordingCoordinator();

    await tester.pumpWidget(
      CaleeApp.forTesting(
        testDeps: _makeDeps(session: session, coordinator: coordinator),
      ),
    );

    session.finishRestore(signedIn: false);
    await tester.pump();

    expect(coordinator.reasons, isEmpty);
  });

  testWidgets('app resume while signed in triggers an appResumed refresh', (
    tester,
  ) async {
    final session = _FakeSessionController();
    final coordinator = _RecordingCoordinator();

    await tester.pumpWidget(
      CaleeApp.forTesting(
        testDeps: _makeDeps(session: session, coordinator: coordinator),
      ),
    );

    session.finishRestore(signedIn: true);
    await tester.pump();
    coordinator.reasons.clear();

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();

    expect(coordinator.reasons, [CalendarReminderRefreshReason.appResumed]);
  });

  testWidgets('restored signed-in session begins an account-scoped reminder '
      'session', (tester) async {
    final session = _FakeSessionController();
    final coordinator = _RecordingCoordinator();

    await tester.pumpWidget(
      CaleeApp.forTesting(
        testDeps: _makeDeps(session: session, coordinator: coordinator),
      ),
    );

    session.finishRestore(signedIn: true);
    await tester.pump();

    expect(coordinator.begunAccounts, ['u1']);
    expect(coordinator.endSessionCount, 0);
  });

  testWidgets('signing out ends the reminder session (targeted cleanup)', (
    tester,
  ) async {
    final session = _FakeSessionController();
    final coordinator = _RecordingCoordinator();

    await tester.pumpWidget(
      CaleeApp.forTesting(
        testDeps: _makeDeps(session: session, coordinator: coordinator),
      ),
    );

    session.finishRestore(signedIn: true);
    await tester.pump();
    expect(coordinator.endSessionCount, 0);

    session.finishRestore(signedIn: false);
    await tester.pump();

    expect(
      coordinator.endSessionCount,
      1,
      reason: 'sign-out ends the reminder session and cleans up',
    );
  });

  testWidgets('an unauthorized automatic sign-out invalidates reminder work', (
    tester,
  ) async {
    final session = _FakeSessionController();
    final coordinator = _RecordingCoordinator();

    await tester.pumpWidget(
      CaleeApp.forTesting(
        testDeps: _makeDeps(session: session, coordinator: coordinator),
      ),
    );

    session.finishRestore(signedIn: true);
    await tester.pump();

    session.simulateUnauthorizedSignOut();
    await tester.pump();

    expect(
      coordinator.endSessionCount,
      1,
      reason: 'an unauthorized sign-out must invalidate reminder work',
    );
  });

  testWidgets('signed-out app never begins or ends a reminder session', (
    tester,
  ) async {
    final session = _FakeSessionController();
    final coordinator = _RecordingCoordinator();

    await tester.pumpWidget(
      CaleeApp.forTesting(
        testDeps: _makeDeps(session: session, coordinator: coordinator),
      ),
    );

    session.finishRestore(signedIn: false);
    await tester.pump();

    expect(coordinator.begunAccounts, isEmpty);
    expect(coordinator.endSessionCount, 0);
    expect(coordinator.reasons, isEmpty);
  });

  testWidgets('switching accounts begins a fresh reminder session for the new '
      'account', (tester) async {
    final session = _FakeSessionController();
    final coordinator = _RecordingCoordinator();

    await tester.pumpWidget(
      CaleeApp.forTesting(
        testDeps: _makeDeps(session: session, coordinator: coordinator),
      ),
    );

    session.finishRestore(signedIn: true); // account u1
    await tester.pump();
    session.switchAccount(accountId: 'u2');
    await tester.pump();

    expect(coordinator.begunAccounts, ['u1', 'u2']);
  });
}
