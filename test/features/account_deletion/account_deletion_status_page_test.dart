// Widget tests for the deletion-only status and recovery surface (#556).
//
// This is the screen a customer reads once ordinary access to Calee is gone,
// so its central obligation is not to lie. `completed` is the only wording
// that says a deletion succeeded; every other state — including one this build
// has never seen — must read as unfinished.

import 'package:calee_mobile/data/api/calee_hub_client.dart';
import 'package:calee_mobile/data/models/account_deletion_status.dart';
import 'package:calee_mobile/features/account_deletion/account_deletion_controller.dart';
import 'package:calee_mobile/features/account_deletion/account_deletion_status_page.dart';
import 'package:calee_mobile/ui/calee_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'account_deletion_fixtures.dart';

/// Words that would tell a customer their account is gone. None of them may
/// appear for any state but `completed`.
const _successWords = <String>[
  'has been deleted',
  'was deleted',
  'successfully deleted',
  'deletion complete',
  'Deleted',
];

Widget _wrap(
  AccountDeletionController controller, {
  VoidCallback? onFinished,
}) => MaterialApp(
  theme: CaleeTheme.buildThemeData(),
  home: AccountDeletionStatusPage(
    controller: controller,
    onFinished: onFinished ?? () {},
  ),
);

Future<void> _pumpTall(WidgetTester tester, Widget widget) async {
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  tester.view.physicalSize = const Size(900, 2400);
  tester.view.devicePixelRatio = 1.0;
  await tester.pumpWidget(widget);
  await tester.pumpAndSettle();
}

/// Drives a controller to a tracked operation in [state].
Future<({AccountDeletionController controller, FakeDeletionHubClient hub})>
_trackingIn(String state, {String? completionWindowMessage}) async {
  final hub = FakeDeletionHubClient(
    onRequest: (_) async => acceptedResult(
      state: state,
      completionWindowMessage: completionWindowMessage,
    ),
  );
  final fixture = buildController(hub: hub);
  await fixture.controller.submit(
    accessToken: 'tok',
    password: 'hunter2',
    accountId: 'acct_1',
  );
  return (controller: fixture.controller, hub: hub);
}

void expectNoSuccessClaim(WidgetTester tester) {
  for (final word in _successWords) {
    expect(
      find.textContaining(word),
      findsNothing,
      reason: 'only the exact `completed` state may read as success',
    );
  }
}

void main() {
  group('nonterminal states are never shown as successful deletion', () {
    for (final state in const [
      'requested',
      'quiescing',
      'deleting',
      'failed_retryable',
      'support_required',
    ]) {
      testWidgets('$state renders as unfinished', (tester) async {
        final f = await _trackingIn(state);

        await _pumpTall(tester, _wrap(f.controller));

        expect(
          find.byKey(const Key('account_deletion_progress_header')),
          findsOneWidget,
        );
        expect(
          find.byKey(const Key('account_deletion_completed_header')),
          findsNothing,
        );
        expectNoSuccessClaim(tester);
      });
    }

    testWidgets('an unknown future state fails closed', (tester) async {
      final f = await _trackingIn('incinerating');

      await _pumpTall(tester, _wrap(f.controller));

      expect(
        find.byKey(const Key('account_deletion_progress_header')),
        findsOneWidget,
      );
      expect(
        find.textContaining('still working on your request'),
        findsOneWidget,
      );
      expectNoSuccessClaim(tester);
    });

    testWidgets('a terminal-flagged unknown state is still not success', (
      tester,
    ) async {
      final hub = FakeDeletionHubClient(
        onRequest: (_) async => AccountDeletionRequestResult(
          status: statusFor('purged', isTerminal: true),
          created: true,
          recoveryCredentialMatched: true,
        ),
      );
      final fixture = buildController(hub: hub);
      await fixture.controller.submit(
        accessToken: 'tok',
        password: 'hunter2',
        accountId: 'acct_1',
      );

      await _pumpTall(tester, _wrap(fixture.controller));

      expect(
        find.byKey(const Key('account_deletion_completed_header')),
        findsNothing,
      );
      expectNoSuccessClaim(tester);
    });
  });

  group('support and retry states are bounded and useful', () {
    testWidgets('support_required does not ask for a second deletion', (
      tester,
    ) async {
      final f = await _trackingIn('support_required');

      await _pumpTall(tester, _wrap(f.controller));

      expect(
        find.textContaining('a Calee specialist has to finish it'),
        findsOneWidget,
      );
      expect(
        find.textContaining('does not need to be sent again'),
        findsOneWidget,
      );
      // The public handle is what a support conversation quotes.
      expect(
        find.byKey(const Key('account_deletion_operation_id_row')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('account_deletion_recovery_id_row')),
        findsOneWidget,
      );
    });

    testWidgets('failed_retryable says Calee is retrying, not the customer', (
      tester,
    ) async {
      final f = await _trackingIn('failed_retryable');

      await _pumpTall(tester, _wrap(f.controller));

      expect(find.textContaining('Calee is retrying it'), findsOneWidget);
      expect(
        find.textContaining('nothing you need to send again'),
        findsOneWidget,
      );
    });

    testWidgets('never renders the recovery secret', (tester) async {
      final f = await _trackingIn('support_required');

      await _pumpTall(tester, _wrap(f.controller));

      final secret = f.hub.requestCredentials.single.recoverySecret;
      expect(find.textContaining(secret), findsNothing);
    });
  });

  group('completion window', () {
    testWidgets('renders the Hub message rather than a hard-coded SLA', (
      tester,
    ) async {
      const message =
          'Calee usually finishes deletions well within a week, and will email '
          'you when yours is done.';
      final f = await _trackingIn(
        'quiescing',
        completionWindowMessage: message,
      );

      await _pumpTall(tester, _wrap(f.controller));

      expect(
        find.byKey(const Key('account_deletion_completion_window')),
        findsOneWidget,
      );
      expect(find.text(message), findsOneWidget);
    });

    testWidgets('shows nothing at all when the Hub sends no message', (
      tester,
    ) async {
      final f = await _trackingIn('quiescing');

      await _pumpTall(tester, _wrap(f.controller));

      expect(
        find.byKey(const Key('account_deletion_completion_window')),
        findsNothing,
        reason: 'an absent Hub message is not an invitation to invent one',
      );
    });
  });

  group('terminal outcomes', () {
    testWidgets('completed is the only success, and says so truthfully', (
      tester,
    ) async {
      final hub = FakeDeletionHubClient(
        onRequest: (_) async => acceptedResult(),
        onStatus: (_) async =>
            statusFor('completed', completedAt: '2026-09-02T10:00:00Z'),
      );
      final fixture = buildController(hub: hub);
      await fixture.controller.submit(
        accessToken: 'tok',
        password: 'hunter2',
        accountId: 'acct_1',
      );
      await fixture.controller.refreshStatus();

      var finished = false;
      await _pumpTall(
        tester,
        _wrap(fixture.controller, onFinished: () => finished = true),
      );

      expect(
        find.byKey(const Key('account_deletion_completed_header')),
        findsOneWidget,
      );
      expect(find.textContaining('has been deleted'), findsOneWidget);
      expect(find.textContaining('retention rules'), findsOneWidget);
      expect(fixture.cleanup.clearedAccountIds, ['acct_1']);

      await tester.tap(find.byKey(const Key('account_deletion_done_button')));
      await tester.pumpAndSettle();

      expect(finished, isTrue);
      expect(fixture.controller.phase, AccountDeletionPhase.inactive);
    });

    testWidgets('restored says deletion did NOT happen', (tester) async {
      final hub = FakeDeletionHubClient(
        onRequest: (_) async => acceptedResult(),
        onStatus: (_) async => statusFor('restored'),
      );
      final fixture = buildController(hub: hub);
      await fixture.controller.submit(
        accessToken: 'tok',
        password: 'hunter2',
        accountId: 'acct_1',
      );
      await fixture.controller.refreshStatus();

      var finished = false;
      await _pumpTall(
        tester,
        _wrap(fixture.controller, onFinished: () => finished = true),
      );

      expect(
        find.byKey(const Key('account_deletion_restored_header')),
        findsOneWidget,
      );
      expect(find.text('Your account was not deleted'), findsOneWidget);
      expect(
        find.byKey(const Key('account_deletion_completed_header')),
        findsNothing,
      );
      expectNoSuccessClaim(tester);
      expect(
        fixture.cleanup.clearedAccountIds,
        isEmpty,
        reason: 'the account survived, so none of its local state is removed',
      );

      // Straight back to ordinary sign-in.
      await tester.tap(
        find.byKey(const Key('account_deletion_sign_in_button')),
      );
      await tester.pumpAndSettle();

      expect(finished, isTrue);
      expect(fixture.controller.phase, AccountDeletionPhase.inactive);
    });
  });

  group('unresolved outcomes', () {
    testWidgets('claims neither deletion nor that nothing happened', (
      tester,
    ) async {
      final hub = FakeDeletionHubClient(
        onStatus: (_) async => throw const CaleeHubException(
          statusCode: 500,
          code: 'SERVER',
          message: 'server',
        ),
      );
      final fixture = buildController(hub: hub);
      // A cold launch that found recovery material for an unconfirmed request.
      final storage = fixture.storage;
      storage.values['calee_account_deletion_recovery_v1'] =
          '{"recoveryId":"${storedCredential.recoveryId}",'
          '"recoverySecret":"${storedCredential.recoverySecret}"}';
      await fixture.controller.restore();
      await fixture.controller.refreshStatus();

      await _pumpTall(tester, _wrap(fixture.controller));

      expect(
        find.byKey(const Key('account_deletion_unresolved_header')),
        findsOneWidget,
      );
      expect(
        find.textContaining('may or may not have reached Calee'),
        findsOneWidget,
      );
      expectNoSuccessClaim(tester);
      expect(
        find.byKey(const Key('account_deletion_abandon_button')),
        findsNothing,
        reason: 'an unreachable Hub is not an answer, so there is no exit yet',
      );
      expect(
        find.byKey(const Key('account_deletion_refresh_button')),
        findsOneWidget,
      );
    });

    testWidgets('offers an exit once the Hub itself says it has no record', (
      tester,
    ) async {
      final hub = FakeDeletionHubClient(
        onStatus: (_) async => throw const CaleeHubException(
          statusCode: 404,
          code: 'DELETION_OPERATION_NOT_FOUND',
          message: 'not found',
        ),
      );
      final fixture = buildController(hub: hub);
      fixture.storage.values['calee_account_deletion_recovery_v1'] =
          '{"recoveryId":"${storedCredential.recoveryId}",'
          '"recoverySecret":"${storedCredential.recoverySecret}"}';
      await fixture.controller.restore();
      await fixture.controller.refreshStatus();

      var finished = false;
      await _pumpTall(
        tester,
        _wrap(fixture.controller, onFinished: () => finished = true),
      );

      expect(
        find.byKey(const Key('account_deletion_abandon_button')),
        findsOneWidget,
      );

      // The exit is itself confirmed, and explains what it does and does not
      // mean before anything is discarded.
      await tester.tap(
        find.byKey(const Key('account_deletion_abandon_button')),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('it will still be processed'), findsOneWidget);

      await tester.tap(find.text('Keep checking'));
      await tester.pumpAndSettle();
      expect(finished, isFalse);
      expect(fixture.storage.holdsRecoveryRecord, isTrue);

      await tester.tap(
        find.byKey(const Key('account_deletion_abandon_button')),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        // Scoped to the dialog: the page's own exit carries the same label.
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.text('Back to sign in'),
        ),
      );
      await tester.pumpAndSettle();

      expect(finished, isTrue);
      expect(fixture.storage.holdsRecoveryRecord, isFalse);
    });

    testWidgets('a credential the Hub did not match is a support state', (
      tester,
    ) async {
      final hub = FakeDeletionHubClient(
        onRequest: (_) async =>
            acceptedResult(recoveryCredentialMatched: false),
      );
      final fixture = buildController(hub: hub);
      await fixture.controller.submit(
        accessToken: 'tok',
        password: 'hunter2',
        accountId: 'acct_1',
      );

      await _pumpTall(tester, _wrap(fixture.controller));

      expect(
        find.byKey(const Key('account_deletion_unrecoverable_header')),
        findsOneWidget,
      );
      expect(
        find.textContaining('has not been cancelled'),
        findsOneWidget,
        reason: 'this is not presented as safely recoverable, nor as cancelled',
      );
      expect(
        find.byKey(const Key('account_deletion_recovery_id_row')),
        findsOneWidget,
      );
      expectNoSuccessClaim(tester);
    });
  });
}
