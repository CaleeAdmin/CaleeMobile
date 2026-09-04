// Widget tests for Settings -> Account -> Delete account (#556).
//
// The point of this screen is that it is HARD to use by accident, and honest
// about what it does. Both are asserted here.

import 'package:calee_mobile/data/api/calee_hub_client.dart';
import 'package:calee_mobile/features/account_deletion/account_deletion_controller.dart';
import 'package:calee_mobile/features/account_deletion/delete_account_page.dart';
import 'package:calee_mobile/ui/calee_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'account_deletion_fixtures.dart';

const _phrase = CaleeHubClient.accountDeletionConfirmationPhrase;

Widget _wrap(AccountDeletionController controller) => MaterialApp(
  theme: CaleeTheme.buildThemeData(),
  home: DeleteAccountPage(
    controller: controller,
    accessToken: 'tok',
    accountId: 'acct_1',
    accountEmail: 'person@example.com',
  ),
);

/// The page's content is long; a tall surface lays it all out without needing
/// scroll gestures between assertions.
Future<void> _pumpTall(WidgetTester tester, Widget widget) async {
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  tester.view.physicalSize = const Size(900, 2600);
  tester.view.devicePixelRatio = 1.0;
  await tester.pumpWidget(widget);
  await tester.pumpAndSettle();
}

Future<void> _reachConfirmationStep(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('delete_account_continue_button')));
  await tester.pumpAndSettle();
}

void main() {
  group('explanation step', () {
    testWidgets('says permanent deletion, not sign out', (tester) async {
      final hub = FakeDeletionHubClient();
      final fixture = buildController(hub: hub);

      await _pumpTall(tester, _wrap(fixture.controller));

      expect(find.byKey(const Key('delete_account_headline')), findsOneWidget);
      expect(
        find.textContaining('not signing out', findRichText: true),
        findsOneWidget,
      );
      expect(
        find.textContaining('permanently deleted', findRichText: true),
        findsWidgets,
      );
    });

    testWidgets('covers the #556 consequences the customer must know', (
      tester,
    ) async {
      final hub = FakeDeletionHubClient();
      final fixture = buildController(hub: hub);

      await _pumpTall(tester, _wrap(fixture.controller));

      // Approved retention rules, rather than an unqualified "everything goes".
      expect(find.textContaining('retention rules'), findsWidgets);
      // Other subjects' resources are not deleted with the account.
      expect(
        find.textContaining('household, business or organisation'),
        findsWidgets,
      );
      // Household Home/tablet entitlement survives.
      expect(find.textContaining('Calee Home display'), findsOneWidget);
      // Cancellable before, no Undo after.
      expect(find.textContaining('cancel any time before'), findsOneWidget);
      expect(find.textContaining('has no Undo'), findsOneWidget);
    });

    testWidgets('invents no numeric completion timeframe', (tester) async {
      final hub = FakeDeletionHubClient();
      final fixture = buildController(hub: hub);

      await _pumpTall(tester, _wrap(fixture.controller));

      // The Hub owns the completion window and only publishes it on the status
      // projection. This screen must not manufacture one.
      for (final invented in const [
        '24 hours',
        '48 hours',
        '7 days',
        '30 days',
        'within 24',
      ]) {
        expect(
          find.textContaining(invented),
          findsNothing,
          reason: 'no unmeasured SLA may appear before the Hub supplies one',
        );
      }
    });

    testWidgets('shows which account is about to be deleted', (tester) async {
      final hub = FakeDeletionHubClient();
      final fixture = buildController(hub: hub);

      await _pumpTall(tester, _wrap(fixture.controller));

      expect(find.text('person@example.com'), findsOneWidget);
    });

    testWidgets('offers no password or confirmation field yet', (tester) async {
      final hub = FakeDeletionHubClient();
      final fixture = buildController(hub: hub);

      await _pumpTall(tester, _wrap(fixture.controller));

      expect(
        find.byKey(const Key('delete_account_password_field')),
        findsNothing,
      );
      expect(
        find.byKey(const Key('delete_account_submit_button')),
        findsNothing,
      );
    });
  });

  group('the destructive action cannot be triggered accidentally', () {
    testWidgets('the submit button is disabled with both fields empty', (
      tester,
    ) async {
      final hub = FakeDeletionHubClient(
        onRequest: (_) async => acceptedResult(),
      );
      final fixture = buildController(hub: hub);
      await _pumpTall(tester, _wrap(fixture.controller));
      await _reachConfirmationStep(tester);

      final button = tester.widget<FilledButton>(
        find.descendant(
          of: find.byKey(const Key('delete_account_submit_button')),
          matching: find.byType(FilledButton),
        ),
      );
      expect(button.onPressed, isNull);

      await tester.tap(
        find.byKey(const Key('delete_account_submit_button')),
        warnIfMissed: false,
      );
      await tester.pumpAndSettle();

      expect(hub.requestCount, 0);
    });

    testWidgets('a password alone is not enough', (tester) async {
      final hub = FakeDeletionHubClient(
        onRequest: (_) async => acceptedResult(),
      );
      final fixture = buildController(hub: hub);
      await _pumpTall(tester, _wrap(fixture.controller));
      await _reachConfirmationStep(tester);

      await tester.enterText(
        find.byKey(const Key('delete_account_password_field')),
        'hunter2',
      );
      await tester.pumpAndSettle();

      await tester.tap(
        find.byKey(const Key('delete_account_submit_button')),
        warnIfMissed: false,
      );
      await tester.pumpAndSettle();

      expect(hub.requestCount, 0);
      expect(fixture.controller.phase, AccountDeletionPhase.inactive);
    });

    testWidgets('the exact phrase alone is not enough — re-auth is required', (
      tester,
    ) async {
      final hub = FakeDeletionHubClient(
        onRequest: (_) async => acceptedResult(),
      );
      final fixture = buildController(hub: hub);
      await _pumpTall(tester, _wrap(fixture.controller));
      await _reachConfirmationStep(tester);

      await tester.enterText(
        find.byKey(const Key('delete_account_confirmation_field')),
        _phrase,
      );
      await tester.pumpAndSettle();

      await tester.tap(
        find.byKey(const Key('delete_account_submit_button')),
        warnIfMissed: false,
      );
      await tester.pumpAndSettle();

      expect(
        hub.requestCount,
        0,
        reason: 'recent re-authentication is required for the first request',
      );
    });

    testWidgets('a nearly-right phrase is refused', (tester) async {
      final hub = FakeDeletionHubClient(
        onRequest: (_) async => acceptedResult(),
      );
      final fixture = buildController(hub: hub);
      await _pumpTall(tester, _wrap(fixture.controller));
      await _reachConfirmationStep(tester);

      await tester.enterText(
        find.byKey(const Key('delete_account_password_field')),
        'hunter2',
      );
      await tester.enterText(
        find.byKey(const Key('delete_account_confirmation_field')),
        'DELETE MY ACCOUNT',
      );
      await tester.pumpAndSettle();

      await tester.tap(
        find.byKey(const Key('delete_account_submit_button')),
        warnIfMissed: false,
      );
      await tester.pumpAndSettle();

      expect(hub.requestCount, 0);
    });

    testWidgets('even a complete form needs one more explicit confirmation', (
      tester,
    ) async {
      final hub = FakeDeletionHubClient(
        onRequest: (_) async => acceptedResult(),
      );
      final fixture = buildController(hub: hub);
      await _pumpTall(tester, _wrap(fixture.controller));
      await _reachConfirmationStep(tester);

      await tester.enterText(
        find.byKey(const Key('delete_account_password_field')),
        'hunter2',
      );
      await tester.enterText(
        find.byKey(const Key('delete_account_confirmation_field')),
        _phrase,
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('delete_account_submit_button')));
      await tester.pumpAndSettle();

      // The dialog is up; nothing has been sent.
      expect(find.text('Delete your Calee account?'), findsOneWidget);
      expect(hub.requestCount, 0);

      await tester.tap(find.text('Keep my account'));
      await tester.pumpAndSettle();

      expect(
        hub.requestCount,
        0,
        reason: 'cancelling the final confirmation sends nothing',
      );
      expect(fixture.controller.phase, AccountDeletionPhase.inactive);
    });
  });

  group('submitting', () {
    testWidgets('sends the password and the Hub-owned confirmation phrase', (
      tester,
    ) async {
      final hub = FakeDeletionHubClient(
        onRequest: (_) async => acceptedResult(),
      );
      final fixture = buildController(hub: hub);
      await _pumpTall(tester, _wrap(fixture.controller));
      await _reachConfirmationStep(tester);

      await tester.enterText(
        find.byKey(const Key('delete_account_password_field')),
        'hunter2',
      );
      await tester.enterText(
        find.byKey(const Key('delete_account_confirmation_field')),
        // Typed casually: the gate is forgiving about case and spacing, and
        // the wire value is the client's own constant either way.
        '  delete my calee account  ',
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('delete_account_submit_button')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete permanently'));
      await tester.pumpAndSettle();

      expect(hub.requestCount, 1);
      expect(hub.requestPasswords.single, 'hunter2');
      expect(hub.requestAccessTokens.single, 'tok');
      expect(fixture.controller.phase, AccountDeletionPhase.tracking);
    });

    testWidgets('a rejected password keeps the customer here, signed in', (
      tester,
    ) async {
      final hub = FakeDeletionHubClient(
        onRequest: (_) async => throw const CaleeHubException(
          statusCode: 401,
          code: 'DELETION_REAUTH_REQUIRED',
          message: 'reauth',
        ),
      );
      final fixture = buildController(hub: hub);
      await _pumpTall(tester, _wrap(fixture.controller));
      await _reachConfirmationStep(tester);

      await tester.enterText(
        find.byKey(const Key('delete_account_password_field')),
        'wrong',
      );
      await tester.enterText(
        find.byKey(const Key('delete_account_confirmation_field')),
        _phrase,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('delete_account_submit_button')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete permanently'));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('delete_account_refusal_notice')),
        findsOneWidget,
      );
      expect(find.textContaining("That password didn't work"), findsOneWidget);
      expect(
        find.textContaining('has not been changed'),
        findsOneWidget,
        reason: 'a pre-acceptance refusal must not imply deletion started',
      );
      expect(fixture.controller.ownsAppSurface, isFalse);
    });

    testWidgets('a lost response offers a same-credential retry, not an Undo', (
      tester,
    ) async {
      final hub = FakeDeletionHubClient(
        onRequest: (_) async => throw const CaleeHubException(
          statusCode: 503,
          code: 'DELETION_UNAVAILABLE',
          message: 'unavailable',
        ),
        onStatus: (_) async => throw const CaleeHubException(
          statusCode: 404,
          code: 'DELETION_OPERATION_NOT_FOUND',
          message: 'not found',
        ),
      );
      final fixture = buildController(hub: hub);
      await _pumpTall(tester, _wrap(fixture.controller));
      await _reachConfirmationStep(tester);

      await tester.enterText(
        find.byKey(const Key('delete_account_password_field')),
        'hunter2',
      );
      await tester.enterText(
        find.byKey(const Key('delete_account_confirmation_field')),
        _phrase,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('delete_account_submit_button')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete permanently'));
      await tester.pumpAndSettle();

      expect(fixture.controller.phase, AccountDeletionPhase.retryable);
      expect(
        find.byKey(const Key('delete_account_retry_button')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('delete_account_check_status_button')),
        findsOneWidget,
      );
      expect(
        find.textContaining('may or may not have reached Calee'),
        findsOneWidget,
      );
      expect(
        find.textContaining('never create a second deletion'),
        findsOneWidget,
      );

      // The retry must be reachable, and must reuse the SAME credential.
      await tester.enterText(
        find.byKey(const Key('delete_account_password_field')),
        'hunter2',
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('delete_account_retry_button')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete permanently'));
      await tester.pumpAndSettle();

      expect(hub.requestCount, 2);
      expect(
        hub.requestCredentials[0],
        hub.requestCredentials[1],
        reason: 'a retry after a lost response never mints a new credential',
      );
    });
  });
}
