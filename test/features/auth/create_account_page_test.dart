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
    // Form fields must be kept after a retryable failure so the user can
    // just tap Retry rather than re-typing everything.
    expect(find.text('Jane'), findsOneWidget);
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
}
