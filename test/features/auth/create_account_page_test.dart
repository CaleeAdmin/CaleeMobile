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
  String? registeredEmail;
  String? registeredConfirmEmail;
  String? registeredRedeemCode;
  String? registeredPassword;

  @override
  Future<ClientLoginResult> register({
    required String email,
    required String confirmEmail,
    required String redeemCode,
    required String password,
  }) async {
    registerCallCount += 1;
    registeredEmail = email;
    registeredConfirmEmail = confirmEmail;
    registeredRedeemCode = redeemCode;
    registeredPassword = password;
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

Future<void> _enterValidAccountDetails(
  WidgetTester tester, {
  String email = 'user@example.com',
  String confirmEmail = 'user@example.com',
  String password = 'password123',
  String confirmPassword = 'password123',
}) async {
  await tester.enterText(find.byType(TextFormField).at(0), email);
  await tester.enterText(find.byType(TextFormField).at(1), confirmEmail);
  await tester.enterText(find.byType(TextFormField).at(2), 'REDEEM-CODE');
  await tester.enterText(find.byType(TextFormField).at(3), password);
  await tester.enterText(find.byType(TextFormField).at(4), confirmPassword);
}

Future<void> _tapCreateAccount(WidgetTester tester) async {
  await tester.ensureVisible(
    find.widgetWithText(FilledButton, 'Create account'),
  );
  await tester.tap(find.widgetWithText(FilledButton, 'Create account'));
  await tester.pump();
}

void main() {
  testWidgets('CreateAccountPage shows Confirm password', (tester) async {
    await _pumpCreateAccountPage(tester);

    expect(find.text('Confirm password'), findsOneWidget);
  });

  testWidgets('empty confirm password shows error', (tester) async {
    final repository = await _pumpCreateAccountPage(tester);
    await _enterValidAccountDetails(tester, confirmPassword: '');

    await _tapCreateAccount(tester);

    expect(find.text('Confirm password is required.'), findsOneWidget);
    expect(repository.registerCallCount, 0);
  });

  testWidgets('mismatched confirm password shows error', (tester) async {
    final repository = await _pumpCreateAccountPage(tester);
    await _enterValidAccountDetails(tester, confirmPassword: 'different123');

    await _tapCreateAccount(tester);

    expect(find.text('Confirm password must match password.'), findsOneWidget);
    expect(repository.registerCallCount, 0);
  });

  testWidgets('matching confirm password allows submit', (tester) async {
    var accountCreated = false;
    final repository = await _pumpCreateAccountPage(
      tester,
      onAccountCreated: (_) => accountCreated = true,
    );
    await _enterValidAccountDetails(tester);

    await _tapCreateAccount(tester);
    await tester.pump();

    expect(repository.registerCallCount, 1);
    expect(repository.registeredEmail, 'user@example.com');
    expect(repository.registeredConfirmEmail, 'user@example.com');
    expect(repository.registeredRedeemCode, 'REDEEM-CODE');
    expect(repository.registeredPassword, 'password123');
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
