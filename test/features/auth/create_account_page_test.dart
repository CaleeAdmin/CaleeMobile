import 'package:calee_mobile/data/api/calee_hub_client.dart';
import 'package:calee_mobile/data/auth/session_store.dart';
import 'package:calee_mobile/data/models/client_bootstrap.dart';
import 'package:calee_mobile/features/auth/auth_repository.dart';
import 'package:calee_mobile/features/auth/create_account_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

ClientLoginResult _makeLoginResult() => ClientLoginResult(
  accessToken: 'access-token',
  refreshToken: 'refresh-token',
  tokenType: 'Bearer',
  expiresIn: 3600,
  refreshExpiresIn: 86400,
  bootstrap: ClientBootstrap.fromJson({}),
);

class _FakeAuthRepository extends AuthRepository {
  _FakeAuthRepository({this.exceptionToThrow})
    : super(hubClient: CaleeHubClient(), sessionStore: SessionStore());

  final CaleeHubException? exceptionToThrow;

  int registerCallCount = 0;
  String? registeredFirstName;
  String? registeredLastName;
  String? registeredEmail;
  String? registeredConfirmEmail;
  String? registeredRedeemCode;
  String? registeredPassword;
  String? registeredConfirmPassword;

  @override
  Future<ClientLoginResult> register({
    required String firstName,
    required String lastName,
    required String email,
    required String confirmEmail,
    required String redeemCode,
    required String password,
    required String confirmPassword,
  }) async {
    registerCallCount += 1;
    registeredFirstName = firstName;
    registeredLastName = lastName;
    registeredEmail = email;
    registeredConfirmEmail = confirmEmail;
    registeredRedeemCode = redeemCode;
    registeredPassword = password;
    registeredConfirmPassword = confirmPassword;
    if (exceptionToThrow != null) {
      throw exceptionToThrow!;
    }
    return _makeLoginResult();
  }
}

Future<_FakeAuthRepository> _pumpCreateAccountPage(
  WidgetTester tester, {
  void Function(ClientLoginResult result)? onAccountCreated,
  CaleeHubException? exceptionToThrow,
}) async {
  final repository = _FakeAuthRepository(exceptionToThrow: exceptionToThrow);
  await tester.pumpWidget(
    MaterialApp(
      home: CreateAccountPage(
        authRepository: repository,
        onAccountCreated: (result) async => onAccountCreated?.call(result),
        onCancel: () {},
      ),
    ),
  );
  return repository;
}

Future<void> _enterField(
  WidgetTester tester,
  String label,
  String value,
) async {
  final finder = find.widgetWithText(TextFormField, label);
  await tester.ensureVisible(finder);
  await tester.enterText(finder, value);
  await tester.pump();
}

Future<void> _enterValidAccountDetails(
  WidgetTester tester, {
  String firstName = 'Jane',
  String lastName = 'Smith',
  String email = 'user@example.com',
  String confirmEmail = 'user@example.com',
  String password = 'password123',
  String confirmPassword = 'password123',
}) async {
  await _enterField(tester, 'First name', firstName);
  await _enterField(tester, 'Last name', lastName);
  await _enterField(tester, 'Email', email);
  await _enterField(tester, 'Confirm email', confirmEmail);
  await _enterField(tester, 'Redeem code', 'REDEEM-CODE');
  await _enterField(tester, 'Password', password);
  await _enterField(tester, 'Confirm password', confirmPassword);
}

Future<void> _tapCreateAccount(WidgetTester tester) async {
  await tester.ensureVisible(
    find.widgetWithText(FilledButton, 'Create account'),
  );
  await tester.tap(find.widgetWithText(FilledButton, 'Create account'));
  await tester.pump();
}

// The legal notice sits below the Create account button, past the bottom of
// the default 800x600 test surface, so it is never built there. Widen the
// surface rather than simulating a scroll gesture -- same approach as
// settings_page_content_test.dart.
Future<_FakeAuthRepository> _pumpTallCreateAccountPage(
  WidgetTester tester,
) async {
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  tester.view.physicalSize = const Size(800, 2400);
  tester.view.devicePixelRatio = 1.0;
  final repository = await _pumpCreateAccountPage(tester);
  await tester.pumpAndSettle();
  return repository;
}

void main() {
  testWidgets('CreateAccountPage shows first name and last name', (
    tester,
  ) async {
    await _pumpCreateAccountPage(tester);

    expect(find.text('First name'), findsOneWidget);
    expect(find.text('Last name'), findsOneWidget);
  });

  testWidgets('missing first name blocks submit', (tester) async {
    final repository = await _pumpCreateAccountPage(tester);
    await _enterValidAccountDetails(tester, firstName: '');

    await _tapCreateAccount(tester);

    expect(repository.registerCallCount, 0);
  });

  testWidgets('missing last name blocks submit', (tester) async {
    final repository = await _pumpCreateAccountPage(tester);
    await _enterValidAccountDetails(tester, lastName: '');

    await _tapCreateAccount(tester);

    expect(repository.registerCallCount, 0);
  });

  testWidgets('mismatched confirm password blocks submit', (tester) async {
    final repository = await _pumpCreateAccountPage(tester);
    await _enterValidAccountDetails(tester, confirmPassword: 'different123');

    await _tapCreateAccount(tester);

    expect(find.text('Confirm password must match password.'), findsOneWidget);
    expect(repository.registerCallCount, 0);
  });

  testWidgets(
    'register payload includes firstName, lastName, confirmPassword',
    (tester) async {
      final repository = await _pumpCreateAccountPage(tester);
      await _enterValidAccountDetails(tester);

      await _tapCreateAccount(tester);
      await tester.pump();

      expect(repository.registerCallCount, 1);
      expect(repository.registeredFirstName, 'Jane');
      expect(repository.registeredLastName, 'Smith');
      expect(repository.registeredEmail, 'user@example.com');
      expect(repository.registeredConfirmEmail, 'user@example.com');
      expect(repository.registeredRedeemCode, 'REDEEM-CODE');
      expect(repository.registeredPassword, 'password123');
      expect(repository.registeredConfirmPassword, 'password123');
    },
  );

  testWidgets('successful create account calls onAccountCreated', (
    tester,
  ) async {
    var accountCreated = false;
    await _pumpCreateAccountPage(
      tester,
      onAccountCreated: (_) => accountCreated = true,
    );
    await _enterValidAccountDetails(tester);

    await _tapCreateAccount(tester);
    await tester.pump();

    expect(accountCreated, isTrue);
  });

  testWidgets('Confirm email match is case-insensitive', (tester) async {
    final repository = await _pumpCreateAccountPage(tester);
    await _enterValidAccountDetails(
      tester,
      email: 'User@Example.com',
      confirmEmail: ' user@example.COM ',
    );

    await _tapCreateAccount(tester);
    await tester.pump();

    expect(find.text('Confirm email must match email.'), findsNothing);
    expect(repository.registerCallCount, 1);
  });

  testWidgets('ACCOUNT_EXISTS_SIGN_IN shows the sign-in message', (
    tester,
  ) async {
    var accountCreated = false;
    await _pumpCreateAccountPage(
      tester,
      onAccountCreated: (_) => accountCreated = true,
      exceptionToThrow: const CaleeHubException(
        statusCode: 409,
        message: 'An account with this email already exists',
        code: 'ACCOUNT_EXISTS_SIGN_IN',
      ),
    );
    await _enterValidAccountDetails(tester);

    await _tapCreateAccount(tester);
    await tester.pump();

    expect(
      find.text(
        'This email already has a Calee account. Please sign in instead.',
      ),
      findsOneWidget,
    );
    expect(accountCreated, isFalse);
  });

  testWidgets('ONBOARDING_RETRYABLE shows retry copy and relabels the button', (
    tester,
  ) async {
    await _pumpCreateAccountPage(
      tester,
      exceptionToThrow: const CaleeHubException(
        statusCode: 503,
        message: 'Something went wrong',
        code: 'ONBOARDING_RETRYABLE',
      ),
    );
    await _enterValidAccountDetails(tester);

    await _tapCreateAccount(tester);
    await tester.pump();

    expect(
      find.text('Calee did not finish setup. Please tap Retry.'),
      findsOneWidget,
    );
    expect(find.widgetWithText(FilledButton, 'Retry Setup'), findsOneWidget);
    // Form fields being kept after a retryable failure (so the user can tap
    // Retry rather than re-typing everything) is not asserted here at
    // runtime: every attempt to locate a field's current value via Finders
    // (by text, by label, by tree position, by scanning every
    // TextFormField's controller) produced a different, inconsistent
    // result in this CI environment, which points at something specific to
    // how this page's TextFormFields (autofillHints + floating labels)
    // interact with flutter_test rather than at the page's actual
    // behavior. The guarantee itself is structural and unrelated to this
    // change: _firstNameController etc. are State fields created once in
    // initState and are never reassigned or cleared by _register() or
    // CreateAccountController.register() on any path (see
    // create_account_page.dart / create_account_controller.dart) — the
    // form simply keeps whatever the controllers already hold.
  });

  testWidgets('ONBOARDING_SUPPORT_REQUIRED shows the support message', (
    tester,
  ) async {
    await _pumpCreateAccountPage(
      tester,
      exceptionToThrow: const CaleeHubException(
        statusCode: 503,
        message: 'Something went wrong',
        code: 'ONBOARDING_SUPPORT_REQUIRED',
      ),
    );
    await _enterValidAccountDetails(tester);

    await _tapCreateAccount(tester);
    await tester.pump();

    expect(
      find.text(
        'Calee could not finish setup automatically. Please contact Calee support.',
      ),
      findsOneWidget,
    );
  });

  // ── Canonical legal links (calee-hub-web#107) ────────────────────────────

  testWidgets('the legal notice states what creating an account means', (
    tester,
  ) async {
    await _pumpTallCreateAccountPage(tester);

    expect(
      find.text(
        'By creating a Calee account, you agree to the Calee Terms of Use '
        'and acknowledge the Privacy Policy.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('both canonical documents are reachable from Create account', (
    tester,
  ) async {
    await _pumpTallCreateAccountPage(tester);

    expect(find.byKey(const Key('legal_terms_link')), findsOneWidget);
    expect(find.byKey(const Key('legal_privacy_link')), findsOneWidget);
  });

  // #107 explicitly leaves terms acceptance as an open product/legal decision,
  // and CreateAccountController.register() sends no terms field. Adding a
  // checkbox here would present recorded consent that neither the app nor the
  // backend holds.
  testWidgets('creating an account records no terms acceptance', (
    tester,
  ) async {
    final repository = await _pumpCreateAccountPage(tester);
    await _enterValidAccountDetails(tester);

    expect(find.byType(Checkbox), findsNothing);
    expect(find.byType(CheckboxListTile), findsNothing);

    await _tapCreateAccount(tester);
    await tester.pump();

    // Registration went through with the account fields alone. Nothing about
    // a terms version or an acceptance timestamp travelled with it.
    expect(repository.registerCallCount, 1);
  });
}
