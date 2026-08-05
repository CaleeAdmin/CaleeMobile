// Widget tests: the public-calendar decision page. The local read-only add
// must be the unmistakable primary action, the Calee-for-home promotion must
// stay compact and secondary, and no copy may imply a free account, backup,
// or sync for the local calendar.

import 'package:calee_mobile/features/calendar_follow/calendar_follow_intent.dart';
import 'package:calee_mobile/features/calendar_follow/follow_calendar_page.dart';
import 'package:calee_mobile/ui/calee_design.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _addToPhoneButton = Key('calendar_follow_add_to_phone_button');
const _openCalendarButton = Key('calendar_follow_open_calendar_button');
const _homePromo = Key('calendar_follow_home_promo');
const _existingCustomerSignIn = Key(
  'calendar_follow_existing_customer_sign_in',
);
const _cancelButton = Key('calendar_follow_cancel_button');

ResolvedCalendarFollowIntent _intent({String title = 'School Calendar'}) =>
    ResolvedCalendarFollowIntent(
      title: title,
      url: 'https://example.com/cal.ics',
      source: 'example.com',
    );

class _Callbacks {
  int addToPhone = 0;
  int openLocalCalendar = 0;
  int learnAboutHome = 0;
  int existingCustomerSignIn = 0;
  int cancel = 0;
}

Widget _buildPage({
  ResolvedCalendarFollowIntent? intent,
  bool alreadyFollowed = false,
  _Callbacks? callbacks,
}) {
  final c = callbacks ?? _Callbacks();
  return MaterialApp(
    theme: CaleeTheme.buildThemeData(),
    home: FollowCalendarPage(
      intent: intent ?? _intent(),
      alreadyFollowed: alreadyFollowed,
      onAddToPhone: () => c.addToPhone++,
      onOpenLocalCalendar: () => c.openLocalCalendar++,
      onLearnAboutHome: () => c.learnAboutHome++,
      onExistingCustomerSignIn: () => c.existingCustomerSignIn++,
      onCancel: () => c.cancel++,
    ),
  );
}

void main() {
  group('FollowCalendarPage — normal state', () {
    testWidgets('shows the local-add primary flow and calendar title', (
      tester,
    ) async {
      await tester.pumpWidget(_buildPage(intent: _intent()));

      expect(find.text('Add this calendar'), findsOneWidget);
      expect(find.text('School Calendar'), findsOneWidget);
      // Card heading and primary button both read "Add to this phone".
      expect(find.text('Add to this phone'), findsNWidgets(2));
      expect(
        find.textContaining('No account or purchase required.'),
        findsOneWidget,
      );
      expect(find.byKey(_addToPhoneButton), findsOneWidget);
    });

    testWidgets('shows the compact shared-family-screen promotion', (
      tester,
    ) async {
      await tester.pumpWidget(_buildPage());

      expect(find.byKey(_homePromo), findsOneWidget);
      expect(
        find.text('See this calendar on a shared family screen'),
        findsOneWidget,
      );
      expect(find.text('Discover Calee for your home.'), findsOneWidget);
      expect(find.byIcon(Icons.chevron_right), findsOneWidget);
      // The approved white-framed product thumbnail leads the row.
      expect(
        find.descendant(
          of: find.byKey(_homePromo),
          matching: find.byKey(const Key('calee_home_product_thumbnail')),
        ),
        findsOneWidget,
      );
    });

    testWidgets('shows the existing-customer sign-in row and Cancel', (
      tester,
    ) async {
      await tester.pumpWidget(_buildPage());
      await tester.scrollUntilVisible(find.byKey(_cancelButton), 200);

      expect(find.byKey(_existingCustomerSignIn), findsOneWidget);
      expect(find.text('Already have Calee at home? Sign in'), findsOneWidget);
      expect(find.byKey(_cancelButton), findsOneWidget);
      expect(find.text('Cancel'), findsOneWidget);
    });

    testWidgets('never shows account-tier or sync copy', (tester) async {
      await tester.pumpWidget(_buildPage());

      expect(find.textContaining('Add to Calee'), findsNothing);
      expect(find.textContaining('Advanced'), findsNothing);
      expect(find.textContaining('free account'), findsNothing);
      expect(find.textContaining('Free Calee account'), findsNothing);
      expect(find.textContaining('Sign in to link'), findsNothing);
      expect(find.textContaining('backed up'), findsNothing);
      expect(find.textContaining('synced'), findsNothing);
      expect(find.textContaining('linked to your Calee account'), findsNothing);
      expect(find.textContaining('other devices'), findsNothing);
    });

    testWidgets('tapping the primary button calls only onAddToPhone', (
      tester,
    ) async {
      final callbacks = _Callbacks();
      await tester.pumpWidget(_buildPage(callbacks: callbacks));

      await tester.tap(find.byKey(_addToPhoneButton));
      await tester.pump();

      expect(callbacks.addToPhone, 1);
      expect(callbacks.openLocalCalendar, 0);
      expect(callbacks.learnAboutHome, 0);
      expect(callbacks.existingCustomerSignIn, 0);
      expect(callbacks.cancel, 0);
    });

    testWidgets('tapping the promotion calls onLearnAboutHome', (tester) async {
      final callbacks = _Callbacks();
      await tester.pumpWidget(_buildPage(callbacks: callbacks));

      await tester.tap(find.byKey(_homePromo));
      await tester.pump();

      expect(callbacks.learnAboutHome, 1);
      expect(callbacks.addToPhone, 0);
      expect(callbacks.existingCustomerSignIn, 0);
    });

    testWidgets('tapping existing-customer Sign in calls the right callback', (
      tester,
    ) async {
      final callbacks = _Callbacks();
      await tester.pumpWidget(_buildPage(callbacks: callbacks));
      await tester.ensureVisible(find.byKey(_existingCustomerSignIn));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(_existingCustomerSignIn));
      await tester.pump();

      expect(callbacks.existingCustomerSignIn, 1);
      expect(callbacks.addToPhone, 0);
      expect(callbacks.learnAboutHome, 0);
    });

    testWidgets('tapping Cancel calls onCancel', (tester) async {
      final callbacks = _Callbacks();
      await tester.pumpWidget(_buildPage(callbacks: callbacks));
      await tester.scrollUntilVisible(find.byKey(_cancelButton), 200);
      await tester.ensureVisible(find.byKey(_cancelButton));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(_cancelButton));
      await tester.pump();

      expect(callbacks.cancel, 1);
      expect(callbacks.addToPhone, 0);
    });

    testWidgets('system back cancels the pending follow flow', (tester) async {
      final callbacks = _Callbacks();
      await tester.pumpWidget(_buildPage(callbacks: callbacks));

      final dynamic widgetsAppState = tester.state(find.byType(WidgetsApp));
      await widgetsAppState.didPopRoute();
      await tester.pump();

      expect(callbacks.cancel, 1);
    });
  });

  group('FollowCalendarPage — already-followed state', () {
    testWidgets('shows Open calendar and no duplicate Add button', (
      tester,
    ) async {
      await tester.pumpWidget(_buildPage(alreadyFollowed: true));

      expect(find.text('Already on this phone'), findsOneWidget);
      expect(
        find.text('This read-only calendar is already available in Calee.'),
        findsOneWidget,
      );
      expect(find.byKey(_openCalendarButton), findsOneWidget);
      expect(find.text('Open calendar'), findsOneWidget);
      expect(find.byKey(_addToPhoneButton), findsNothing);
      expect(find.text('Add to this phone'), findsNothing);
    });

    testWidgets('keeps the promotion and existing-customer sign-in row', (
      tester,
    ) async {
      await tester.pumpWidget(_buildPage(alreadyFollowed: true));

      expect(find.byKey(_homePromo), findsOneWidget);
      expect(find.byKey(_existingCustomerSignIn), findsOneWidget);
    });

    testWidgets('Open calendar calls only onOpenLocalCalendar', (tester) async {
      final callbacks = _Callbacks();
      await tester.pumpWidget(
        _buildPage(alreadyFollowed: true, callbacks: callbacks),
      );

      await tester.tap(find.byKey(_openCalendarButton));
      await tester.pump();

      expect(callbacks.openLocalCalendar, 1);
      expect(callbacks.addToPhone, 0);
      expect(callbacks.cancel, 0);
    });
  });

  group('FollowCalendarPage — responsive & accessibility', () {
    testWidgets('renders without exceptions on a small viewport', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(320, 480);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        _buildPage(
          intent: _intent(
            title: 'A Rather Long Public Calendar Name That Wraps',
          ),
        ),
      );

      expect(tester.takeException(), isNull);
      expect(find.byKey(_addToPhoneButton), findsOneWidget);
    });

    testWidgets('renders without overflow at 2.0 text scale', (tester) async {
      tester.view.physicalSize = const Size(360, 640);
      tester.view.devicePixelRatio = 1.0;
      tester.platformDispatcher.textScaleFactorTestValue = 2.0;
      addTearDown(tester.view.reset);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

      await tester.pumpWidget(_buildPage());

      expect(tester.takeException(), isNull);

      // Every action must remain reachable by scrolling.
      await tester.scrollUntilVisible(find.byKey(_cancelButton), 200);
      expect(tester.takeException(), isNull);
      expect(find.byKey(_cancelButton), findsOneWidget);
    });

    testWidgets('promotion row meets the 48dp minimum tap target', (
      tester,
    ) async {
      await tester.pumpWidget(_buildPage());

      final promoSize = tester.getSize(find.byKey(_homePromo));
      expect(promoSize.height, greaterThanOrEqualTo(48));
    });
  });
}
