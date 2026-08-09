// Layout regression tests: the Welcome page across screen sizes and text
// scales.
//
// Welcome gained the shared-calendar recovery guidance, which made the page
// taller and required it to scroll. Making a page scrollable is easy to get
// subtly wrong: a bare SingleChildScrollView hands its child unbounded
// height, which silently collapses a Center and pins the whole page to the
// top. These tests pin both halves of the requirement — the established
// centred layout survives on a normal phone, and nothing overflows on a short
// screen or at accessibility text sizes.

import 'package:calee_mobile/features/onboarding/welcome_page.dart';
import 'package:calee_mobile/ui/calee_design.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

// Representative viewports, in logical pixels at devicePixelRatio 1.
const _kNormalPhone = Size(390, 844); // modern handset
const _kShortPhone = Size(320, 480); // small/legacy handset

Future<void> _pumpWelcome(
  WidgetTester tester, {
  required Size size,
  double textScale = 1.0,
  VoidCallback? onCreateAccount,
  VoidCallback? onSignIn,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    MaterialApp(
      theme: CaleeTheme.buildThemeData(),
      home: Builder(
        builder: (context) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(textScale)),
          child: WelcomePage(
            onCreateAccount: onCreateAccount ?? () {},
            onSignIn: onSignIn ?? () {},
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('normal phone keeps the established vertically centred layout', (
    tester,
  ) async {
    await _pumpWelcome(tester, size: _kNormalPhone);

    // The whole page fits, so nothing scrolls and nothing overflows.
    expect(tester.takeException(), isNull);

    // Content is balanced about the middle of the screen rather than pinned
    // to the top — the regression a bare scroll view would introduce.
    final top = tester.getRect(find.byIcon(Icons.tv_outlined)).top;
    final bottom = tester.getRect(find.text('Terms and Conditions')).bottom;
    final contentCentre = (top + bottom) / 2;
    final screenCentre = _kNormalPhone.height / 2;
    expect((contentCentre - screenCentre).abs(), lessThan(8));

    // And it is genuinely off the top edge.
    expect(top, greaterThan(48));
  });

  testWidgets('normal phone keeps the account actions primary and prominent', (
    tester,
  ) async {
    var created = 0;
    var signedIn = 0;
    await _pumpWelcome(
      tester,
      size: _kNormalPhone,
      onCreateAccount: () => created++,
      onSignIn: () => signedIn++,
    );

    // Create account stays the filled primary action, sign-in stays available,
    // and both are tappable without scrolling.
    final createAccount = find.widgetWithText(FilledButton, 'Create account');
    final signIn = find.widgetWithText(TextButton, 'I already have an account');
    expect(createAccount, findsOneWidget);
    expect(signIn, findsOneWidget);

    await tester.tap(createAccount);
    await tester.tap(signIn);
    expect(created, 1);
    expect(signedIn, 1);

    // The recovery guidance is present but secondary: it sits below both
    // account actions.
    final recovery = find.byKey(const Key('welcome_shared_calendar_recovery'));
    expect(recovery, findsOneWidget);
    expect(
      tester.getRect(recovery).top,
      greaterThan(tester.getRect(signIn).bottom),
    );
  });

  testWidgets('short phone scrolls instead of overflowing', (tester) async {
    await _pumpWelcome(tester, size: _kShortPhone);

    expect(tester.takeException(), isNull);
    expect(find.byType(Scrollable), findsOneWidget);

    // Both account actions and the terms link remain reachable.
    for (final target in [
      find.widgetWithText(FilledButton, 'Create account'),
      find.widgetWithText(TextButton, 'I already have an account'),
      find.text('Terms and Conditions'),
    ]) {
      await tester.ensureVisible(target);
      await tester.pumpAndSettle();
      expect(target, findsOneWidget);
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('large accessibility text scrolls without overflowing', (
    tester,
  ) async {
    await _pumpWelcome(tester, size: _kNormalPhone, textScale: 2.0);

    expect(tester.takeException(), isNull);

    await tester.ensureVisible(
      find.widgetWithText(FilledButton, 'Create account'),
    );
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Terms and Conditions'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'the most demanding combination — short screen and large text — still '
    'lays out cleanly',
    (tester) async {
      await _pumpWelcome(tester, size: _kShortPhone, textScale: 2.0);

      expect(tester.takeException(), isNull);

      await tester.ensureVisible(
        find.widgetWithText(FilledButton, 'Create account'),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      // The recovery guidance is still there, still explanatory only, and
      // Welcome still offers no way to acquire a calendar directly.
      await tester.ensureVisible(
        find.byKey(const Key('welcome_shared_calendar_recovery')),
      );
      await tester.pumpAndSettle();
      expect(find.text('Following a shared calendar?'), findsOneWidget);
      expect(find.text('Follow a calendar'), findsNothing);
      expect(find.byType(TextField), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}
