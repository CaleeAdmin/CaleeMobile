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
  _FakeAuthRepository()
    : super(hubClient: CaleeHubClient(), sessionStore: SessionStore());

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
    return _makeLoginResult();
  }
}

Future<_FakeAuthRepository> _pumpCreateAccountPage(
  WidgetTester tester, {
  void Function(ClientLoginResult result)? onAccountCreated,
}) async {
  final repository = _FakeAuthRepository();
  await tester.pumpWidget(
    MaterialApp(
      home: CreateAccountPage(
        authRepository: repository,
        onAccountCreated: (result) async => onAccountCreated?.call(result),
      ),
    ),
  );
  return repository;
}

// Field indices: 0=firstName, 1=lastName, 2=email, 3=confirmEmail, 4=redeemCode, 5=password, 6=confirmPassword
Future<void> _enterValidAccountDetails(
  WidgetTester tester, {
  String firstName = 'Jane',
  String lastName = 'Smith',
  String email = 'user@example.com',
  String confirmEmail = 'user@example.com',
  String password = 'password123',
  String confirmPassword = 'password123',
}) async {
  await tester.enterText(find.byType(TextFormField).at(0), firstName);
  await tester.enterText(find.byType(TextFormField).at(1), lastName);
  await tester.enterText(find.byType(TextFormField).at(2), email);
  await tester.enterText(find.byType(TextFormField).at(3), confirmEmail);
  await tester.enterText(find.byType(TextFormField).at(4), 'REDEEM-CODE');
  await tester.enterText(find.byType(TextFormField).at(5), password);
  await tester.enterText(find.byType(TextFormField).at(6), confirmPassword);
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

    expect(find.text('First name is required.'), findsOneWidget);
    expect(repository.registerCallCount, 0);
  });

  testWidgets('missing last name blocks submit', (tester) async {
    final repository = await _pumpCreateAccountPage(tester);
    await _enterValidAccountDetails(tester, lastName: '');

    await _tapCreateAccount(tester);

    expect(find.text('Last name is required.'), findsOneWidget);
    expect(repository.registerCallCount, 0);
  });

  testWidgets('mismatched confirm password blocks submit', (tester) async {
    final repository = await _pumpCreateAccountPage(tester);
    await _enterValidAccountDetails(tester, confirmPassword: 'different123');

    await _tapCreateAccount(tester);

    expect(find.text('Confirm password must match password.'), findsOneWidget);
    expect(repository.registerCallCount, 0);
  });

  testWidgets('register payload includes firstName, lastName, confirmPassword', (
    tester,
  ) async {
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
  });

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
}
