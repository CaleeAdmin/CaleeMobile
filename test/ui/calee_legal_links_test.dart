// The canonical Calee legal links (CaleeAdmin/calee-hub-web#107).
//
// Welcome, Login and Create Account each used to carry their own hard-coded
// `https://portal.calee.com.au/terms` literal and offer Terms alone. Three
// copies of a URL is how they came to point at a Portal-specific document that
// does not describe a household using the mobile app, while the Privacy Policy
// was not reachable from the app at all.
//
// These tests pin the two things that regression needs: the exact canonical
// URL constants, and that both documents are offered together wherever the
// shared widget is used.

import 'package:calee_mobile/config/calee_links.dart';
import 'package:calee_mobile/ui/calee_legal_links.dart';
import 'package:calee_mobile/ui/calee_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('canonical URL constants', () {
    // Written out in full rather than referenced, so that changing the
    // constant is a deliberate act that must also change this test. A test
    // that compared kCaleeTermsUrl to kCaleeTermsUrl would pass for any value.
    test('Terms of Use is the canonical calee.com.au document', () {
      expect(kCaleeTermsUrl, 'https://calee.com.au/terms/');
    });

    test('Privacy Policy is the canonical calee.com.au document', () {
      expect(kCaleePrivacyUrl, 'https://calee.com.au/privacy/');
    });

    test('both are https and on calee.com.au', () {
      for (final url in [kCaleeTermsUrl, kCaleePrivacyUrl]) {
        final uri = Uri.parse(url);
        expect(uri.scheme, 'https', reason: '$url must be https');
        expect(uri.host, 'calee.com.au', reason: '$url must be canonical');
      }
    });

    test('neither points at Portal any more', () {
      for (final url in [kCaleeTermsUrl, kCaleePrivacyUrl, kCaleeForHomeUrl]) {
        expect(url, isNot(contains('portal.calee.com.au')));
      }
    });
  });

  group('CaleeLegalLinks', () {
    testWidgets('offers both documents', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: CaleeTheme.buildThemeData(),
          home: const Scaffold(body: Center(child: CaleeLegalLinks())),
        ),
      );

      expect(find.text('Terms of Use'), findsOneWidget);
      expect(find.text('Privacy Policy'), findsOneWidget);
    });

    testWidgets('each link opens its own canonical URL', (tester) async {
      final opened = <String>[];
      await tester.pumpWidget(
        MaterialApp(
          theme: CaleeTheme.buildThemeData(),
          home: Scaffold(
            body: Center(
              child: CaleeLegalLinks(launcher: (url) async => opened.add(url)),
            ),
          ),
        ),
      );

      await tester.tap(find.byKey(const Key('legal_terms_link')));
      await tester.pumpAndSettle();
      expect(opened, ['https://calee.com.au/terms/']);

      await tester.tap(find.byKey(const Key('legal_privacy_link')));
      await tester.pumpAndSettle();
      expect(opened, [
        'https://calee.com.au/terms/',
        'https://calee.com.au/privacy/',
      ]);
    });

    testWidgets('stacks rather than overflowing at large text sizes', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(320, 480);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        MaterialApp(
          theme: CaleeTheme.buildThemeData(),
          home: Builder(
            builder: (context) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: const TextScaler.linear(2.0)),
              child: const Scaffold(body: Center(child: CaleeLegalLinks())),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.text('Terms of Use'), findsOneWidget);
      expect(find.text('Privacy Policy'), findsOneWidget);
    });
  });

  group('CaleeAccountLegalNotice', () {
    testWidgets('states what creating an account means', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: CaleeTheme.buildThemeData(),
          home: const Scaffold(body: Center(child: CaleeAccountLegalNotice())),
        ),
      );

      expect(
        find.text(
          'By creating a Calee account, you agree to the Calee Terms of Use '
          'and acknowledge the Privacy Policy.',
        ),
        findsOneWidget,
      );
      expect(find.byKey(const Key('legal_terms_link')), findsOneWidget);
      expect(find.byKey(const Key('legal_privacy_link')), findsOneWidget);
    });

    // #107 leaves terms acceptance as an open product/legal decision. This
    // notice must stay a statement plus two links: introducing a checkbox here
    // would create the appearance of recorded consent that nothing in the app
    // or the backend actually stores.
    testWidgets('introduces no acceptance control', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: CaleeTheme.buildThemeData(),
          home: const Scaffold(body: Center(child: CaleeAccountLegalNotice())),
        ),
      );

      expect(find.byType(Checkbox), findsNothing);
      expect(find.byType(CheckboxListTile), findsNothing);
      expect(find.byType(Switch), findsNothing);
      expect(find.byType(Radio<bool>), findsNothing);
    });
  });
}
