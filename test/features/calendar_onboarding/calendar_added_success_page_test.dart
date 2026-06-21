import 'package:calee_mobile/data/api/calee_hub_client.dart';
import 'package:calee_mobile/data/models/client_bootstrap.dart';
import 'package:calee_mobile/features/calendar_onboarding/calendar_added_success_page.dart';
import 'package:calee_mobile/features/calendar_onboarding/calendar_onboarding_page.dart';
import 'package:calee_mobile/features/calendar_onboarding/calendar_source_picker_page.dart';
import 'package:calee_mobile/features/display_setup/display_activation_success_page.dart';
import 'package:calee_mobile/ui/calee_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _StubHubClient extends CaleeHubClient {
  _StubHubClient() : super(baseUri: Uri.parse('http://localhost'));
}

void _setUpSharedPrefs() {
  SharedPreferences.setMockInitialValues({
    'calee_pref_migrated_to_shared_prefs': true,
  });
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
        const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
        (call) async => <String, String>{},
      );
}

void _tearDownSharedPrefs() {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
        const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
        null,
      );
}

// Pushes CalendarSourcePickerPage (with route name) then CalendarAddedSuccessPage on top.
Widget _wrapWithNamedPicker({VoidCallback? onViewCalendar}) {
  return MaterialApp(
    theme: CaleeTheme.buildThemeData(),
    home: Builder(
      builder: (context) => Scaffold(
        body: ElevatedButton(
          onPressed: () {
            Navigator.of(context).push(
              MaterialPageRoute<void>(
                settings: const RouteSettings(
                  name: CalendarSourcePickerPage.routeName,
                ),
                builder: (_) => CalendarSourcePickerPage(
                  hubClient: _StubHubClient(),
                  accessToken: 'token',
                  services: const [],
                  accountId: 'acct1',
                  onDone: () {},
                  onViewCalendar: onViewCalendar ?? () {},
                ),
              ),
            );
          },
          child: const Text('Open Picker'),
        ),
      ),
    ),
  );
}

Future<void> _pushSuccessOnTopOfPicker(WidgetTester tester) async {
  await tester.tap(find.text('Open Picker'));
  await tester.pumpAndSettle();

  final context = tester.element(find.text('Where is your calendar?'));
  Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => CalendarAddedSuccessPage(onViewCalendar: () {}),
    ),
  );
  await tester.pumpAndSettle();
}

// Pushes CalendarAddedSuccessPage directly on top of the home (no named picker).
Widget _wrapWithoutNamedPicker({VoidCallback? onViewCalendar}) {
  return MaterialApp(
    theme: CaleeTheme.buildThemeData(),
    home: Builder(
      builder: (context) => Scaffold(
        body: ElevatedButton(
          onPressed: () {
            Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => CalendarAddedSuccessPage(
                  onViewCalendar: onViewCalendar ?? () {},
                ),
              ),
            );
          },
          child: const Text('Home'),
        ),
      ),
    ),
  );
}

void main() {
  setUp(_setUpSharedPrefs);
  tearDown(_tearDownSharedPrefs);

  group('CalendarAddedSuccessPage — Add another calendar', () {
    testWidgets(
      'returns to CalendarSourcePickerPage when named route is present',
      (tester) async {
        await tester.pumpWidget(_wrapWithNamedPicker());
        await _pushSuccessOnTopOfPicker(tester);

        expect(find.text('Calendar added to Calee'), findsOneWidget);

        await tester.tap(find.text('Add another calendar'));
        await tester.pumpAndSettle();

        expect(find.text('Where is your calendar?'), findsOneWidget);
        expect(find.text('Calendar added to Calee'), findsNothing);
      },
    );

    testWidgets(
      'does not blank the app when named route is missing — stops at first route',
      (tester) async {
        await tester.pumpWidget(_wrapWithoutNamedPicker());
        await tester.tap(find.text('Home'));
        await tester.pumpAndSettle();

        expect(find.text('Calendar added to Calee'), findsOneWidget);

        await tester.tap(find.text('Add another calendar'));
        await tester.pumpAndSettle();

        // Must be back at the home screen (isFirst), not blank.
        expect(find.text('Home'), findsOneWidget);
        expect(find.text('Calendar added to Calee'), findsNothing);
      },
    );

    testWidgets('View calendar calls onViewCalendar callback', (tester) async {
      var viewCalled = false;
      await tester.pumpWidget(_wrapWithoutNamedPicker(
        onViewCalendar: () => viewCalled = true,
      ));
      await tester.tap(find.text('Home'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('View calendar'));
      await tester.pumpAndSettle();

      expect(viewCalled, isTrue);
    });
  });

  group(
    'CalendarOnboardingPage → source picker → success → Add another calendar',
    () {
      testWidgets('returns to source picker', (tester) async {
        await tester.pumpWidget(
          MaterialApp(
            theme: CaleeTheme.buildThemeData(),
            home: CalendarOnboardingPage(
              hubClient: _StubHubClient(),
              accessToken: 'token',
              services: const [],
              accountId: 'acct1',
              onDismissed: () {},
              onViewCalendar: () {},
            ),
          ),
        );

        await tester.tap(find.text('Add existing calendars'));
        await tester.pumpAndSettle();
        expect(find.text('Where is your calendar?'), findsOneWidget);

        // Push success page on top of source picker (simulates completing a calendar add).
        final pickerContext = tester.element(find.text('Where is your calendar?'));
        Navigator.of(pickerContext).push(
          MaterialPageRoute<void>(
            builder: (_) => CalendarAddedSuccessPage(onViewCalendar: () {}),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('Calendar added to Calee'), findsOneWidget);

        await tester.tap(find.text('Add another calendar'));
        await tester.pumpAndSettle();

        expect(find.text('Where is your calendar?'), findsOneWidget);
        expect(find.text('Calendar added to Calee'), findsNothing);
      });
    },
  );

  group(
    'DisplayActivationSuccessPage → source picker → success → Add another calendar',
    () {
      testWidgets('returns to source picker', (tester) async {
        await tester.pumpWidget(
          MaterialApp(
            theme: CaleeTheme.buildThemeData(),
            home: const Scaffold(body: Text('Start')),
          ),
        );

        final startCtx = tester.element(find.text('Start'));
        Navigator.of(startCtx).push(
          MaterialPageRoute<void>(
            builder: (_) => DisplayActivationSuccessPage(
              hubClient: _StubHubClient(),
              accessToken: 'token',
              services: const [],
              accountId: 'acct1',
              onDone: () {},
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('Your Calee display is ready'), findsOneWidget);

        await tester.tap(find.text('Add calendars'));
        await tester.pumpAndSettle();
        expect(find.text('Where is your calendar?'), findsOneWidget);

        // Push success page on top of source picker.
        final pickerCtx = tester.element(find.text('Where is your calendar?'));
        Navigator.of(pickerCtx).push(
          MaterialPageRoute<void>(
            builder: (_) => CalendarAddedSuccessPage(onViewCalendar: () {}),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('Calendar added to Calee'), findsOneWidget);

        await tester.tap(find.text('Add another calendar'));
        await tester.pumpAndSettle();

        expect(find.text('Where is your calendar?'), findsOneWidget);
        expect(find.text('Calendar added to Calee'), findsNothing);
      });
    },
  );
}
