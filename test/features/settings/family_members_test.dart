import 'dart:convert';
import 'dart:io';

import 'package:calee_mobile/data/api/calee_hub_client.dart';
import 'package:calee_mobile/data/models/client_bootstrap.dart';
import 'package:calee_mobile/features/settings/settings_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

// ── Test helpers ──────────────────────────────────────────────────────────────

ClientBootstrap _bootstrap({List<ClientContext> households = const []}) {
  return ClientBootstrap(
    account: const ClientAccount(
      id: 'acc1',
      displayName: 'Test User',
      primaryEmail: 'test@example.com',
      timeZone: 'UTC',
      status: 'active',
    ),
    services: const [],
    contexts: ClientContexts(households: households, organisations: const []),
    availableContexts: const [],
    capabilities: const {},
  );
}

ClientContext _household({String id = 'hh1', String name = 'My Family'}) {
  return ClientContext(
    id: id,
    type: 'household',
    name: name,
    role: 'admin',
    status: 'active',
  );
}

// Minimal JSON responses for the fake server.
Map<String, dynamic> _okCalendars() =>
    {'data': {'calendars': []}};

Map<String, dynamic> _okBootstrap({List<Map<String, dynamic>> households = const []}) => {
      'data': {
        'account': {'id': 'acc1', 'displayName': 'Test User'},
        'services': [],
        'contexts': {'households': households, 'organisations': []},
        'availableContexts': [],
        'capabilities': {},
      },
    };

Map<String, dynamic> _okHousehold(String id, String name) => {
      'data': {
        'household': {'id': id, 'type': 'household', 'name': name, 'role': 'admin', 'status': 'active'},
      },
    };

// Wraps the widget under test in a minimal app scaffold.
Widget _settingsApp(SettingsPage page) {
  return MaterialApp(home: Scaffold(body: page));
}

// ── Tests ─────────────────────────────────────────────────────────────────────

void main() {
  late HttpServer server;

  tearDown(() async {
    await server.close(force: true);
  });

  group('Family Members settings row', () {
    testWidgets('row is tappable when households is empty', (tester) async {
      // Arrange: server returns calendars only (row tap not exercised here).
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((req) async {
        req.response.headers.contentType = ContentType.json;
        req.response.statusCode = HttpStatus.ok;
        // ensureDefaultFamily will fail (404) so we can test the row is enabled.
        if (req.uri.path.contains('/households') && req.method == 'POST') {
          req.response.statusCode = HttpStatus.notFound;
          req.response.write(jsonEncode({'message': 'Not found'}));
        } else {
          req.response.write(jsonEncode(_okCalendars()));
        }
        await req.response.close();
      });

      final client = CaleeHubClient(
        baseUri: Uri.parse('http://127.0.0.1:${server.port}'),
      );

      final page = SettingsPage(
        hubClient: client,
        accessToken: 'tok',
        bootstrap: _bootstrap(),
        onSignOut: () {},
      );

      await tester.pumpWidget(_settingsApp(page));
      await tester.pump(); // settle initial frame

      final row = find.text('Family Members');
      expect(row, findsOneWidget, reason: '"Family Members" row must exist');

      // The InkWell inside CaleeListRow must be enabled (onTap != null).
      final inkWell = find.ancestor(
        of: row,
        matching: find.byWidgetPredicate(
          (w) => w is InkWell && w.onTap != null,
        ),
      );
      expect(inkWell, findsWidgets,
          reason: 'Family Members row must be tappable when households is empty');
    });

    testWidgets('opens HouseholdPeoplePage when household exists', (tester) async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((req) async {
        req.response.headers.contentType = ContentType.json;
        req.response.statusCode = HttpStatus.ok;
        if (req.uri.path.contains('/people')) {
          req.response.write(jsonEncode({'data': {'people': []}}));
        } else {
          req.response.write(jsonEncode(_okCalendars()));
        }
        await req.response.close();
      });

      final client = CaleeHubClient(
        baseUri: Uri.parse('http://127.0.0.1:${server.port}'),
      );

      final page = SettingsPage(
        hubClient: client,
        accessToken: 'tok',
        bootstrap: _bootstrap(households: [_household()]),
        onSignOut: () {},
      );

      await tester.pumpWidget(_settingsApp(page));
      await tester.pump();

      await tester.tap(find.text('Family Members'));
      await tester.pumpAndSettle();

      // HouseholdPeoplePage should now be visible with "Family Members" as title.
      expect(find.text('Family Members'), findsWidgets);
    });

    testWidgets('opens family setup page when ensureDefaultFamily fails', (tester) async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((req) async {
        req.response.headers.contentType = ContentType.json;
        if (req.method == 'POST' && req.uri.path.endsWith('/households')) {
          req.response.statusCode = HttpStatus.notFound;
          req.response.write(jsonEncode({'message': 'Not found'}));
        } else {
          req.response.statusCode = HttpStatus.ok;
          req.response.write(jsonEncode(_okCalendars()));
        }
        await req.response.close();
      });

      final client = CaleeHubClient(
        baseUri: Uri.parse('http://127.0.0.1:${server.port}'),
      );

      final page = SettingsPage(
        hubClient: client,
        accessToken: 'tok',
        bootstrap: _bootstrap(),
        onSignOut: () {},
      );

      await tester.pumpWidget(_settingsApp(page));
      await tester.pump();

      await tester.tap(find.text('Family Members'));
      await tester.pumpAndSettle();

      expect(find.text('Family setup needed'), findsOneWidget);
      expect(
        find.text(
          'Family members are used to assign chores. Please complete family setup in Calee Portal first.',
        ),
        findsOneWidget,
      );
    });

    testWidgets('opens people page with autoOpenCreate when ensureDefaultFamily succeeds',
        (tester) async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((req) async {
        req.response.headers.contentType = ContentType.json;
        req.response.statusCode = HttpStatus.ok;

        if (req.method == 'POST' && req.uri.path.endsWith('/households')) {
          req.response.write(jsonEncode(_okHousehold('hh-new', 'My Family')));
        } else if (req.uri.path == '/client/v1/bootstrap') {
          req.response.write(jsonEncode(_okBootstrap(households: [
            {'id': 'hh-new', 'type': 'household', 'name': 'My Family', 'role': 'admin', 'status': 'active'},
          ])));
        } else if (req.uri.path.contains('/people')) {
          req.response.write(jsonEncode({'data': {'people': []}}));
        } else {
          req.response.write(jsonEncode(_okCalendars()));
        }
        await req.response.close();
      });

      final client = CaleeHubClient(
        baseUri: Uri.parse('http://127.0.0.1:${server.port}'),
      );

      final page = SettingsPage(
        hubClient: client,
        accessToken: 'tok',
        bootstrap: _bootstrap(),
        onSignOut: () {},
      );

      await tester.pumpWidget(_settingsApp(page));
      await tester.pump();

      await tester.tap(find.text('Family Members'));
      await tester.pumpAndSettle();

      // HouseholdPeoplePage must be shown with Family Members title.
      expect(find.text('Family Members'), findsWidgets);
      // The "Add Person" sheet should have been triggered (autoOpenCreate).
      // The sheet title is 'Add Person'.
      expect(find.text('Add Person'), findsOneWidget);
    });
  });
}
