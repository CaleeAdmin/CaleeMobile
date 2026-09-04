// App-shell tests for Account Deletion V1 (#556).
//
// These assert the precedence rules the whole slice rests on: a deletion that
// may exist outranks session restoration, ordinary sign-in, onboarding and the
// Guest experience — and, once it is over, hands every one of them back exactly
// as it found them.

import 'dart:convert';

import 'package:calee_mobile/app/calee_app.dart';
import 'package:calee_mobile/data/account_deletion/account_deletion_recovery_store.dart';
import 'package:calee_mobile/data/api/calee_hub_client.dart';
import 'package:calee_mobile/data/auth/session_store.dart';
import 'package:calee_mobile/data/models/client_bootstrap.dart';
import 'package:calee_mobile/features/account_deletion/account_deletion_controller.dart';
import 'package:calee_mobile/features/account_deletion/account_deletion_status_page.dart';
import 'package:calee_mobile/features/account_deletion/delete_account_page.dart';
import 'package:calee_mobile/features/auth/auth_repository.dart';
import 'package:calee_mobile/features/auth/login_page.dart';
import 'package:calee_mobile/features/auth/session_controller.dart';
import 'package:calee_mobile/features/calendar_follow/calendar_follow_link_controller.dart';
import 'package:calee_mobile/features/display_setup/display_activation_controller.dart';
import 'package:calee_mobile/features/display_setup/display_setup_link_controller.dart';
import 'package:calee_mobile/features/display_setup/display_setup_repository.dart';
import 'package:calee_mobile/features/local_subscriber/local_calendar_subscription_repository.dart';
import 'package:calee_mobile/features/local_subscriber/local_subscriber_calendar_page.dart';
import 'package:calee_mobile/features/onboarding/welcome_page.dart';
import 'package:calee_mobile/app/calee_home_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../features/account_deletion/account_deletion_fixtures.dart';

class _FakeSessionController extends SessionController {
  _FakeSessionController()
    : super(
        repository: AuthRepository(
          hubClient: CaleeHubClient(),
          sessionStore: SessionStore(),
        ),
      );

  int signOutCalls = 0;
  int restoreCalls = 0;

  /// Whether a signed-in session is available to restore. Cleared by
  /// [signOut], exactly as clearing the Hub tokens would.
  bool hasStoredSession = false;

  @override
  Future<void> restoreSession() async {
    restoreCalls++;
    if (hasStoredSession) {
      accessToken = 'test_access_token';
      bootstrap = _stubBootstrap();
    } else {
      accessToken = null;
      bootstrap = null;
    }
    isRestoringSession = false;
    notifyListeners();
  }

  @override
  Future<void> signOut() async {
    signOutCalls++;
    hasStoredSession = false;
    accessToken = null;
    bootstrap = null;
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

ClientBootstrap _stubBootstrap() => const ClientBootstrap(
  account: ClientAccount(
    id: 'acct_1',
    displayName: 'Test',
    primaryEmail: 'person@example.com',
    timeZone: 'Australia/Perth',
    status: 'active',
  ),
  services: [],
  contexts: ClientContexts(households: [], organisations: []),
  availableContexts: [],
  capabilities: {},
);

CaleeAppTestDependencies _makeDeps({
  required _FakeSessionController session,
  AccountDeletionController? deletion,
}) {
  final hub = CaleeHubClient();
  return CaleeAppTestDependencies(
    hubClient: hub,
    sessionController: session,
    displaySetupLinkController: _FakeDisplaySetupLinkController(),
    followLinkController: _FakeFollowLinkController(),
    displayActivationController: DisplayActivationController(
      repository: DisplaySetupRepository(hubClient: hub),
    ),
    localSubscriptionRepo: LocalCalendarSubscriptionRepository(),
    accountDeletionController: deletion,
  );
}

String _recoveryRecordJson({String? operationId}) => jsonEncode({
  'recoveryId': storedCredential.recoveryId,
  'recoverySecret': storedCredential.recoverySecret,
  if (operationId != null) 'operationId': operationId,
});

/// Builds the deletion controller the app shell will be given, wired to a
/// session double so the auth handoff is observable.
({AccountDeletionController controller, FakeDeletionSecureStorage storage})
_deletionFor(
  _FakeSessionController session, {
  required FakeDeletionHubClient hub,
  String? seedRecord,
}) {
  final storage = FakeDeletionSecureStorage(
    seedRecord == null
        ? null
        : {AccountDeletionRecoveryStore.recoveryRecordKey: seedRecord},
  );
  return (
    controller: AccountDeletionController(
      hubClient: hub,
      endOrdinarySession: session.signOut,
      recoveryStore: AccountDeletionRecoveryStore(storage: storage),
      credentialGenerator: deterministicGenerator(),
      accountCleanup: RecordingAccountCleanup(),
      cleanupTargets: FakeCleanupTargetStore(),
    ),
    storage: storage,
  );
}

Future<void> _pumpApp(
  WidgetTester tester,
  CaleeAppTestDependencies deps,
) async {
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  tester.view.physicalSize = const Size(900, 2600);
  tester.view.devicePixelRatio = 1.0;
  await tester.pumpWidget(CaleeApp.forTesting(testDeps: deps));
  await tester.pumpAndSettle();
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({
      'calee_pref_migrated_to_shared_prefs': true,
    });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          (call) async => <String, String>{},
        );
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          null,
        );
  });

  group('healthy accounts are unaffected', () {
    testWidgets('a signed-out first run still shows Welcome', (tester) async {
      final session = _FakeSessionController();
      final deletion = _deletionFor(session, hub: FakeDeletionHubClient());

      await _pumpApp(
        tester,
        _makeDeps(session: session, deletion: deletion.controller),
      );

      expect(find.byType(WelcomePage), findsOneWidget);
      expect(find.byType(AccountDeletionStatusPage), findsNothing);
      expect(
        session.signOutCalls,
        0,
        reason: 'no deletion means no session is disturbed',
      );
    });

    testWidgets('a stored session still restores into the signed-in app', (
      tester,
    ) async {
      final session = _FakeSessionController()..hasStoredSession = true;
      final deletion = _deletionFor(session, hub: FakeDeletionHubClient());

      await _pumpApp(
        tester,
        _makeDeps(session: session, deletion: deletion.controller),
      );

      expect(find.byType(CaleeHomePage), findsOneWidget);
      expect(find.byType(AccountDeletionStatusPage), findsNothing);
      expect(session.signOutCalls, 0);
    });
  });

  group('Settings -> Account -> Delete account', () {
    testWidgets('the destructive row is discoverable and opens the flow', (
      tester,
    ) async {
      final session = _FakeSessionController()..hasStoredSession = true;
      final deletion = _deletionFor(session, hub: FakeDeletionHubClient());

      await _pumpApp(
        tester,
        _makeDeps(session: session, deletion: deletion.controller),
      );

      // Into Settings.
      await tester.tap(find.byIcon(Icons.settings_outlined).last);
      await tester.pumpAndSettle();

      final row = find.byKey(const Key('settings_delete_account_row'));
      expect(row, findsOneWidget);
      expect(find.text('Delete account'), findsWidgets);

      // The row sits in the Account section, above Preferences.
      expect(
        tester.getTopLeft(row).dy,
        lessThan(tester.getTopLeft(find.text('PREFERENCES')).dy),
      );

      await tester.tap(row);
      await tester.pumpAndSettle();

      expect(find.byType(DeleteAccountPage), findsOneWidget);
      expect(find.byKey(const Key('delete_account_headline')), findsOneWidget);
    });
  });

  group('the post-acceptance auth boundary', () {
    testWidgets('an accepted request ends ordinary signed-in Calee', (
      tester,
    ) async {
      final session = _FakeSessionController()..hasStoredSession = true;
      final hub = FakeDeletionHubClient(
        onRequest: (_) async => acceptedResult(state: 'quiescing'),
      );
      final deletion = _deletionFor(session, hub: hub);

      await _pumpApp(
        tester,
        _makeDeps(session: session, deletion: deletion.controller),
      );
      await tester.tap(find.byIcon(Icons.settings_outlined).last);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('settings_delete_account_row')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('delete_account_continue_button')));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const Key('delete_account_password_field')),
        'hunter2',
      );
      await tester.enterText(
        find.byKey(const Key('delete_account_confirmation_field')),
        CaleeHubClient.accountDeletionConfirmationPhrase,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('delete_account_submit_button')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete permanently'));
      await tester.pumpAndSettle();

      // Ordinary Calee is over: the Hub tokens are cleared, the Settings and
      // delete-account routes are off the navigator, and the deletion-only
      // surface owns the app.
      expect(session.signOutCalls, 1);
      expect(find.byType(AccountDeletionStatusPage), findsOneWidget);
      expect(find.byType(CaleeHomePage), findsNothing);
      expect(find.byType(DeleteAccountPage), findsNothing);
      expect(
        deletion.storage.holdsRecoveryRecord,
        isTrue,
        reason: 'clearing the session must not take the recovery record',
      );
    });
  });

  group('cold launch', () {
    testWidgets('recovery material outranks session restoration and login', (
      tester,
    ) async {
      final session = _FakeSessionController()..hasStoredSession = true;
      final hub = FakeDeletionHubClient(
        onStatus: (_) async => statusFor('deleting'),
      );
      final deletion = _deletionFor(
        session,
        hub: hub,
        seedRecord: _recoveryRecordJson(),
      );

      await _pumpApp(
        tester,
        _makeDeps(session: session, deletion: deletion.controller),
      );

      expect(find.byType(AccountDeletionStatusPage), findsOneWidget);
      expect(find.byType(CaleeHomePage), findsNothing);
      expect(find.byType(LoginPage), findsNothing);
      expect(find.byType(WelcomePage), findsNothing);
      expect(
        session.signOutCalls,
        greaterThan(0),
        reason: 'normal credentials must not reopen the signed-in app',
      );
      expect(
        hub.statusCredentials.single,
        storedCredential,
        reason: 'the recovery-only route resolves the stored operation',
      );
    });

    testWidgets('the status path needs no bearer token or password', (
      tester,
    ) async {
      // No stored session at all: exactly the state after the identity has
      // been quiesced.
      final session = _FakeSessionController();
      final hub = FakeDeletionHubClient(
        onStatus: (_) async => statusFor('support_required'),
      );
      final deletion = _deletionFor(
        session,
        hub: hub,
        seedRecord: _recoveryRecordJson(operationId: 'op_KNOWN'),
      );

      await _pumpApp(
        tester,
        _makeDeps(session: session, deletion: deletion.controller),
      );

      expect(find.byType(AccountDeletionStatusPage), findsOneWidget);
      expect(hub.statusCount, 1);
      expect(
        find.textContaining('a Calee specialist has to finish it'),
        findsOneWidget,
      );
    });

    testWidgets('Guest calendars are hidden, not destroyed', (tester) async {
      // A Guest subscription exists on this device alongside the deletion.
      SharedPreferences.setMockInitialValues({
        'calee_pref_migrated_to_shared_prefs': true,
        'local_calendar_subscriptions_v1': jsonEncode([
          {
            'id': 'sub1',
            'title': 'School',
            'url': 'https://example.com/school.ics',
            'color': '#FF0000',
            'createdAt': '2026-01-01T00:00:00.000Z',
          },
        ]),
      });

      final session = _FakeSessionController();
      final hub = FakeDeletionHubClient(
        onStatus: (index) async =>
            index == 0 ? statusFor('deleting') : statusFor('restored'),
      );
      final deletion = _deletionFor(
        session,
        hub: hub,
        seedRecord: _recoveryRecordJson(),
      );

      await _pumpApp(
        tester,
        _makeDeps(session: session, deletion: deletion.controller),
      );

      expect(find.byType(AccountDeletionStatusPage), findsOneWidget);
      expect(find.byType(LocalSubscriberCalendarPage), findsNothing);

      // The deletion ends without completing; the Guest experience returns.
      await tester.tap(
        find.byKey(const Key('account_deletion_refresh_button')),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('account_deletion_restored_header')),
        findsOneWidget,
      );

      await tester.tap(
        find.byKey(const Key('account_deletion_sign_in_button')),
      );
      await tester.pumpAndSettle();

      expect(
        find.byType(LocalSubscriberCalendarPage),
        findsOneWidget,
        reason: 'the local calendar was only hidden, never removed',
      );
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      expect(prefs.getString('local_calendar_subscriptions_v1'), isNotNull);
    });

    testWidgets('a completed deletion lands back on ordinary signed-out UX', (
      tester,
    ) async {
      final session = _FakeSessionController();
      final hub = FakeDeletionHubClient(
        onStatus: (_) async => statusFor('completed'),
      );
      final deletion = _deletionFor(
        session,
        hub: hub,
        seedRecord: _recoveryRecordJson(operationId: 'op_KNOWN'),
      );

      await _pumpApp(
        tester,
        _makeDeps(session: session, deletion: deletion.controller),
      );

      expect(
        find.byKey(const Key('account_deletion_completed_header')),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const Key('account_deletion_done_button')));
      await tester.pumpAndSettle();

      expect(find.byType(WelcomePage), findsOneWidget);
      expect(find.byType(AccountDeletionStatusPage), findsNothing);
      expect(
        deletion.storage.holdsRecoveryRecord,
        isFalse,
        reason: 'recovery material is retired once genuinely obsolete',
      );
    });
  });
}
