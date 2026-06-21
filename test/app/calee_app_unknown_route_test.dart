// Widget test: MaterialApp with onUnknownRoute must not throw when Flutter
// navigates to a token-shaped path (e.g. the iOS native-login bridge route).

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _tokenRoute = '/AbCdEfGhIjKlMnOpQrStUvWxYz0123456789_-AB';

Widget _buildApp() {
  return MaterialApp(
    home: const Scaffold(body: Text('home')),
    onUnknownRoute: (settings) => MaterialPageRoute<void>(
      settings: const RouteSettings(name: '/'),
      builder: (_) => const Scaffold(body: Text('home')),
    ),
  );
}

void main() {
  testWidgets('onUnknownRoute prevents crash for token-shaped path', (
    tester,
  ) async {
    await tester.pumpWidget(_buildApp());

    final NavigatorState navigator = tester.state(find.byType(Navigator));
    navigator.pushNamed(_tokenRoute);
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('home'), findsOneWidget);
  });
}
