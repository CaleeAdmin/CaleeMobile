// Guest-mode legal access (CaleeAdmin/calee-hub-web#107).
//
// A signed-out local subscriber has no Settings page. Before this, once past
// Welcome, neither the Privacy Policy nor the Terms of Use was reachable from
// anywhere in the signed-out app. The canonical documents are now offered from
// the "Calendars on this phone" sheet, which is the Guest experience's own
// management surface.
//
// Links only: Guest mode creates no account, so there is nothing to accept and
// no acceptance is asked for.

import 'package:calee_mobile/features/local_subscriber/local_calendar_subscription.dart';
import 'package:calee_mobile/features/local_subscriber/local_calendar_subscription_repository.dart';
import 'package:calee_mobile/features/local_subscriber/local_subscriber_calendar_page.dart';
import 'package:calee_mobile/ui/calee_design.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

LocalCalendarSubscription _sub() => LocalCalendarSubscription(
  id: 'sub1',
  title: 'Test Calendar',
  url: 'https://example.com/cal.ics',
  source: 'example.com',
  createdAt: DateTime(2024, 1, 1),
);

Widget _buildPage() => MaterialApp(
  theme: CaleeTheme.buildThemeData(),
  home: LocalSubscriberCalendarPage(
    subscriptions: [_sub()],
    repository: LocalCalendarSubscriptionRepository(),
    onSignIn: () {},
    onLearnAboutHome: () {},
    onSubscriptionsChanged: (_) {},
  ),
);

Future<void> _openCalendarsSheet(WidgetTester tester) async {
  await tester.pumpWidget(_buildPage());
  await tester.pumpAndSettle();
  await tester.tap(find.byTooltip('Calendars on this phone'));
  await tester.pumpAndSettle();
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('Guest mode reaches both canonical legal documents', (
    tester,
  ) async {
    await _openCalendarsSheet(tester);

    expect(find.byKey(const Key('local_calendar_legal_links')), findsOneWidget);
    expect(find.text('Terms of Use'), findsOneWidget);
    expect(find.text('Privacy Policy'), findsOneWidget);
  });

  testWidgets('the legal links sit below the Calee Home discovery row', (
    tester,
  ) async {
    await _openCalendarsSheet(tester);

    final promo = tester.getRect(
      find.byKey(const Key('local_calendar_home_promo')),
    );
    final legal = tester.getRect(
      find.byKey(const Key('local_calendar_legal_links')),
    );
    expect(legal.top, greaterThanOrEqualTo(promo.bottom));
  });

  // Guest mode is signed out and creates no account. Offering the documents
  // must not turn into asking a Guest to accept anything.
  testWidgets('Guest legal access asks for no acceptance', (tester) async {
    await _openCalendarsSheet(tester);

    expect(find.byType(Checkbox), findsNothing);
    expect(find.byType(CheckboxListTile), findsNothing);
    expect(find.text('Accept'), findsNothing);
    expect(find.text('I agree'), findsNothing);
  });

  // The legal links are a dead end by design: tapping one must not dismiss
  // the sheet into the "learn about Calee Home" navigation, and must not
  // start sign-in.
  testWidgets('offering legal links does not lead to sign-in', (tester) async {
    var signInCalls = 0;
    var learnCalls = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: CaleeTheme.buildThemeData(),
        home: LocalSubscriberCalendarPage(
          subscriptions: [_sub()],
          repository: LocalCalendarSubscriptionRepository(),
          onSignIn: () => signInCalls++,
          onLearnAboutHome: () => learnCalls++,
          onSubscriptionsChanged: (_) {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Calendars on this phone'));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('local_calendar_legal_links')), findsOneWidget);
    expect(signInCalls, 0);
    expect(learnCalls, 0);
  });
}
