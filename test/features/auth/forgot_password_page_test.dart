import 'package:calee_mobile/data/api/calee_hub_client.dart';
import 'package:calee_mobile/data/auth/session_store.dart';
import 'package:calee_mobile/features/auth/auth_repository.dart';
import 'package:calee_mobile/features/auth/forgot_password_page.dart';
import 'package:calee_mobile/features/auth/login_page.dart';
import 'package:calee_mobile/data/models/client_bootstrap.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

// ─── Fake repository ──────────────────────────────────────────────────────────

class _FakeAuthRepository extends AuthRepository {
  _FakeAuthRepository()
    : super(hubClient: CaleeHubClient(), sessionStore: SessionStore());

  int resetCallCount = 0;
  String? lastResetEmail;
  Exception? resetError;

  @override
  Future<void> requestPasswordReset({required String email}) async {
    if (resetError != null) throw resetError!;
    resetCallCount += 1;
    lastResetEmail = email;
  }

  @override
  Future<ClientLoginResult> login({
    required String email,
    required String password,
  }) async => throw UnimplementedError();
}

// ─── Pump helpers ─────────────────────────────────────────────────────────────

Future<_FakeAuthRepository> _pumpForgotPasswordPage(WidgetTester tester) async {
  final repository = _FakeAuthRepository();
  await tester.pumpWidget(
    MaterialApp(home: ForgotPasswordPage(authRepository: repository)),
  );
  return repository;
}

Future<_FakeAuthRepository> _pumpLoginPage(WidgetTester tester) async {
  final repository = _FakeAuthRepository();
  await tester.pumpWidget(
    MaterialApp(
      home: LoginPage(
        authRepository: repository,
        onSignedIn: (_) async {},
        onCancel: () {},
      ),
    ),
  );
  return repository;
}

// ─── Tests ────────────────────────────────────────────────────────────────────

void main() {
  group('LoginPage forgot password', () {
    testWidgets('shows "Forgot password?" button', (tester) async {
      await _pumpLoginPage(tester);

      expect(find.text('Forgot password?'), findsOneWidget);
    });

    testWidgets('tapping "Forgot password?" opens ForgotPasswordPage', (
      tester,
    ) async {
      await _pumpLoginPage(tester);

      await tester.tap(find.text('Forgot password?'));
      await tester.pumpAndSettle();

      expect(find.text('Reset your password'), findsOneWidget);
    });

    testWidgets(
      'forgot password no longer launches https://hub.calee.com.au/login',
      (tester) async {
        await _pumpLoginPage(tester);

        await tester.tap(find.text('Forgot password?'));
        await tester.pumpAndSettle();

        // ForgotPasswordPage is shown in-app, not a browser URL
        expect(find.byType(ForgotPasswordPage), findsOneWidget);
      },
    );

    testWidgets('Terms and Conditions button is still present', (tester) async {
      await _pumpLoginPage(tester);

      expect(find.text('Terms and Conditions'), findsOneWidget);
    });
  });

  group('ForgotPasswordPage', () {
    testWidgets('shows "Reset your password" title', (tester) async {
      await _pumpForgotPasswordPage(tester);

      expect(find.text('Reset your password'), findsOneWidget);
    });

    testWidgets('shows email field', (tester) async {
      await _pumpForgotPasswordPage(tester);

      expect(find.widgetWithText(TextFormField, 'Email'), findsOneWidget);
    });

    testWidgets('empty email shows "Enter your email"', (tester) async {
      await _pumpForgotPasswordPage(tester);

      await tester.tap(find.widgetWithText(FilledButton, 'Send reset link'));
      await tester.pump();

      expect(find.text('Enter your email'), findsOneWidget);
    });

    testWidgets('invalid email shows "Enter a valid email"', (tester) async {
      await _pumpForgotPasswordPage(tester);

      await tester.enterText(
        find.widgetWithText(TextFormField, 'Email'),
        'not-an-email',
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Send reset link'));
      await tester.pump();

      expect(find.text('Enter a valid email'), findsOneWidget);
    });

    testWidgets('valid email calls requestPasswordReset', (tester) async {
      final repository = await _pumpForgotPasswordPage(tester);

      await tester.enterText(
        find.widgetWithText(TextFormField, 'Email'),
        'user@example.com',
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Send reset link'));
      await tester.pump();

      expect(repository.resetCallCount, 1);
      expect(repository.lastResetEmail, 'user@example.com');
    });

    testWidgets('success shows "Check your email"', (tester) async {
      await _pumpForgotPasswordPage(tester);

      await tester.enterText(
        find.widgetWithText(TextFormField, 'Email'),
        'user@example.com',
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Send reset link'));
      await tester.pump();

      expect(find.text('Check your email'), findsOneWidget);
    });

    testWidgets('success message is generic', (tester) async {
      await _pumpForgotPasswordPage(tester);

      await tester.enterText(
        find.widgetWithText(TextFormField, 'Email'),
        'user@example.com',
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Send reset link'));
      await tester.pump();

      expect(
        find.text(
          'If a Calee account exists for this email, we\'ve sent password reset instructions.',
        ),
        findsOneWidget,
      );
    });

    testWidgets('success shows "Back to sign in" button', (tester) async {
      await _pumpForgotPasswordPage(tester);

      await tester.enterText(
        find.widgetWithText(TextFormField, 'Email'),
        'user@example.com',
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Send reset link'));
      await tester.pump();

      expect(find.text('Back to sign in'), findsOneWidget);
    });

    testWidgets('CaleeHubException message is displayed', (tester) async {
      final repository = await _pumpForgotPasswordPage(tester);
      repository.resetError = const CaleeHubException(
        statusCode: 429,
        message: 'Too many requests. Please try again later.',
      );

      await tester.enterText(
        find.widgetWithText(TextFormField, 'Email'),
        'user@example.com',
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Send reset link'));
      await tester.pump();

      expect(
        find.text('Too many requests. Please try again later.'),
        findsOneWidget,
      );
    });

    testWidgets('unknown exception shows generic error message', (
      tester,
    ) async {
      final repository = await _pumpForgotPasswordPage(tester);
      repository.resetError = Exception('network failure');

      await tester.enterText(
        find.widgetWithText(TextFormField, 'Email'),
        'user@example.com',
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Send reset link'));
      await tester.pump();

      expect(
        find.text('Unable to send reset instructions. Please try again.'),
        findsOneWidget,
      );
    });
  });
}
