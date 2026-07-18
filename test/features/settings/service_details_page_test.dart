// Widget tests for ServiceDetailsPage — verifies the Calendar App Status
// row and the calendar-app-setup helper text that explain what "needs
// attention" means on the Settings page.

import 'package:calee_mobile/data/api/calee_hub_client.dart';
import 'package:calee_mobile/data/models/client_bootstrap.dart';
import 'package:calee_mobile/features/settings/service_details_page.dart';
import 'package:calee_mobile/ui/calee_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

ClientService _serviceWith({
  required String accessStatus,
  required String calendarCredentialStatus,
}) => ClientService(
  id: 'business',
  displayName: 'Calee Business',
  baseUrl: 'https://business.example.com',
  launchUrl: 'https://business.example.com',
  serviceType: 'nextcloud_portal',
  accessStatus: accessStatus,
  calendarCredentialStatus: calendarCredentialStatus,
  source: 'portal',
  capabilities: const {},
);

Widget _wrap(ClientService service) => MaterialApp(
  theme: CaleeTheme.buildThemeData(),
  home: ServiceDetailsPage(
    hubClient: CaleeHubClient(baseUri: Uri.parse('http://localhost')),
    accessToken: 'tok',
    service: service,
  ),
);

void main() {
  testWidgets('shows "Connected" calendar app status when active', (
    tester,
  ) async {
    final service = _serviceWith(
      accessStatus: 'active',
      calendarCredentialStatus: 'connected',
    );
    await tester.pumpWidget(_wrap(service));

    expect(find.text('Calendar App Status'), findsOneWidget);
    expect(find.text('Connected'), findsOneWidget);
  });

  testWidgets(
    'shows "Setup needed" calendar app status and helper text when missing',
    (tester) async {
      final service = _serviceWith(
        accessStatus: 'active',
        calendarCredentialStatus: 'missing',
      );
      await tester.pumpWidget(_wrap(service));

      expect(find.text('Calendar App Status'), findsOneWidget);
      expect(find.text('Setup needed'), findsOneWidget);
      expect(
        find.text(
          'Set up the calendar app connection so this service can use '
          'calendar features.',
        ),
        findsOneWidget,
      );
    },
  );

  testWidgets('hides Calendar App Status row when unsupported', (tester) async {
    final service = _serviceWith(
      accessStatus: 'active',
      calendarCredentialStatus: 'unsupported',
    );
    await tester.pumpWidget(_wrap(service));

    expect(find.text('Calendar App Status'), findsNothing);
  });
}
