import 'package:calee_mobile/data/api/calee_hub_client.dart';
import 'package:calee_mobile/data/models/client_bootstrap.dart';
import 'package:calee_mobile/features/calendar_onboarding/calendar_source_picker_page.dart';
import 'package:calee_mobile/features/display_setup/display_activation_success_page.dart';
import 'package:calee_mobile/ui/calee_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _StubHubClient extends CaleeHubClient {
  _StubHubClient() : super(baseUri: Uri.parse('http://localhost'));
}

ClientService _portalService() => const ClientService(
  id: 'portal',
  displayName: 'Calee Portal',
  serviceType: 'calee_portal',
  baseUrl: 'http://localhost',
  launchUrl: '',
  accessStatus: 'active',
  calendarCredentialStatus: 'connected',
  source: 'calee',
  capabilities: {},
);

Widget _wrap({required VoidCallback onDone, List<ClientService>? services}) {
  return MaterialApp(
    theme: CaleeTheme.buildThemeData(),
    home: const Scaffold(body: Text('Home')),
    routes: {
      '/success': (_) => DisplayActivationSuccessPage(
        hubClient: _StubHubClient(),
        accessToken: 'token',
        services: services ?? const [],
        accountId: 'acct1',
        onDone: onDone,
      ),
    },
  );
}

Future<void> _pushSuccess(WidgetTester tester) async {
  final context = tester.element(find.text('Home'));
  Navigator.of(context).pushNamed('/success');
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('Do this later pops back and calls onDone', (tester) async {
    var doneCalls = 0;

    await tester.pumpWidget(_wrap(onDone: () => doneCalls++));
    await _pushSuccess(tester);

    expect(find.text('Your Calee display is ready'), findsOneWidget);

    await tester.tap(find.text('Do this later'));
    await tester.pumpAndSettle();

    expect(doneCalls, 1);
    expect(find.text('Home'), findsOneWidget);
    expect(find.text('Your Calee display is ready'), findsNothing);
  });

  testWidgets('Add calendars opens CalendarSourcePickerPage', (tester) async {
    await tester.pumpWidget(_wrap(onDone: () {}));
    await _pushSuccess(tester);

    await tester.tap(find.text('Add calendars'));
    await tester.pumpAndSettle();

    expect(find.byType(CalendarSourcePickerPage), findsOneWidget);
    expect(find.text('Where is your calendar?'), findsOneWidget);
  });

  testWidgets('shows Add calendars and not Add another calendar with services', (
    tester,
  ) async {
    await tester.pumpWidget(
      _wrap(onDone: () {}, services: [_portalService()]),
    );
    await _pushSuccess(tester);

    expect(find.text('Add calendars'), findsOneWidget);
    expect(find.text('Add another calendar'), findsNothing);
    expect(find.text('Done'), findsNothing);
    expect(find.text('Do this later'), findsOneWidget);
  });
}
