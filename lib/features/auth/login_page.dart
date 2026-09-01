import 'package:flutter/material.dart';

import '../../data/models/client_bootstrap.dart';
import '../../ui/calee_legal_links.dart';
import 'auth_repository.dart';
import 'forgot_password_page.dart';
import 'login_controller.dart';

class LoginPage extends StatefulWidget {
  const LoginPage({
    required this.authRepository,
    required this.onSignedIn,
    required this.onCancel,
    super.key,
  });

  final AuthRepository authRepository;
  final Future<void> Function(ClientLoginResult result) onSignedIn;
  final VoidCallback onCancel;

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final _formKey = GlobalKey<FormState>();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();

  bool _obscurePassword = true;
  late final LoginController _loginController;

  @override
  void initState() {
    super.initState();
    _loginController = LoginController(repository: widget.authRepository);
  }

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    _loginController.dispose();
    super.dispose();
  }

  Future<void> _signIn() async {
    if (!_formKey.currentState!.validate()) {
      return;
    }

    final result = await _loginController.signIn(
      email: _emailController.text.trim(),
      password: _passwordController.text,
    );

    if (!mounted || result == null) return;

    await widget.onSignedIn(result);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        leading: BackButton(
          key: const Key('login_cancel_button'),
          onPressed: widget.onCancel,
        ),
      ),
      body: SafeArea(
        minimum: const EdgeInsets.all(24),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Form(
              key: _formKey,
              child: AnimatedBuilder(
                animation: _loginController,
                builder: (context, _) {
                  final isLoading = _loginController.isLoading;
                  final errorMessage = _loginController.errorMessage;
                  return ListView(
                    shrinkWrap: true,
                    children: [
                      Center(
                        child: Image.asset(
                          'assets/calee_logo.png',
                          width: 150,
                          fit: BoxFit.contain,
                          semanticLabel: 'Calee',
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Sign in to Calee',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.titleMedium,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Manage calendars, tasks and displays connected to your Calee account.',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodyMedium,
                      ),
                      const SizedBox(height: 32),
                      TextFormField(
                        key: const Key('login_email_field'),
                        controller: _emailController,
                        keyboardType: TextInputType.emailAddress,
                        textInputAction: TextInputAction.next,
                        autofillHints: const [AutofillHints.email],
                        decoration: const InputDecoration(
                          labelText: 'Email',
                          border: OutlineInputBorder(),
                        ),
                        validator: (value) {
                          if (value == null || value.trim().isEmpty) {
                            return 'Enter your email';
                          }
                          return null;
                        },
                      ),
                      const SizedBox(height: 16),
                      TextFormField(
                        key: const Key('login_password_field'),
                        controller: _passwordController,
                        obscureText: _obscurePassword,
                        textInputAction: TextInputAction.done,
                        autofillHints: const [AutofillHints.password],
                        onFieldSubmitted: (_) => isLoading ? null : _signIn(),
                        decoration: InputDecoration(
                          labelText: 'Password',
                          border: const OutlineInputBorder(),
                          suffixIcon: IconButton(
                            key: const Key('login_toggle_password_visibility'),
                            icon: Icon(
                              _obscurePassword
                                  ? Icons.visibility_outlined
                                  : Icons.visibility_off_outlined,
                              size: 20,
                            ),
                            onPressed: () => setState(
                              () => _obscurePassword = !_obscurePassword,
                            ),
                            tooltip: _obscurePassword
                                ? 'Show password'
                                : 'Hide password',
                          ),
                        ),
                        validator: (value) {
                          if (value == null || value.isEmpty) {
                            return 'Enter your password';
                          }
                          return null;
                        },
                      ),
                      const SizedBox(height: 8),
                      Align(
                        alignment: Alignment.centerRight,
                        child: TextButton(
                          onPressed: () => Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) => ForgotPasswordPage(
                                authRepository: widget.authRepository,
                              ),
                            ),
                          ),
                          style: TextButton.styleFrom(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 0,
                              vertical: 4,
                            ),
                            minimumSize: const Size(0, 36),
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          ),
                          child: const Text('Forgot password?'),
                        ),
                      ),
                      if (errorMessage != null) ...[
                        const SizedBox(height: 8),
                        Text(
                          errorMessage,
                          key: const Key('login_error_message'),
                          style: TextStyle(color: theme.colorScheme.error),
                        ),
                      ],
                      const SizedBox(height: 24),
                      FilledButton(
                        key: const Key('login_submit_button'),
                        onPressed: isLoading ? null : _signIn,
                        child: isLoading
                            ? const SizedBox.square(
                                dimension: 20,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Text('Sign in'),
                      ),
                      const SizedBox(height: 32),
                      // TODO(CaleeMobile onboarding):
                      // Add the "New to Calee? Connect a Calee display" entry point after the
                      // Calee Display auth changeover is stable.
                      //
                      // End-to-end target flow:
                      //
                      // 1. User opens CaleeMobile without an existing session.
                      // 2. Login screen shows:
                      //    - "Sign in to Calee"
                      //    - "Manage calendars, tasks and displays connected to your Calee account."
                      //    - email/password sign-in
                      //    - "Forgot password?"
                      //    - Terms of Use / Privacy Policy links
                      //    - future link: "New to Calee? Connect a Calee display"
                      //
                      // 3. When the future setup link is enabled, tapping it should start the
                      //    official Hub/Core onboarding flow, not a separate CaleeMobile-only
                      //    onboarding implementation.
                      //
                      // 4. Hub/Core onboarding should handle:
                      //    - Calee account creation or identification
                      //    - Calee display activation
                      //    - redeem code / activation validation if required
                      //    - display native-login completion
                      //    - provider guidance for iCloud / Google / Outlook / calendar links
                      //    - creation of any required account/service credentials
                      //
                      // 5. After onboarding completes successfully:
                      //    - the Calee display should auto-login
                      //    - Hub/Core should generate a short-lived, one-time mobile handoff code
                      //    - the browser should offer "Open Calee app" / "Get the Calee app"
                      //    - if CaleeMobile is installed, the handoff link should open the app
                      //    - CaleeMobile should exchange the one-time code for its own mobile session
                      //    - CaleeMobile should store the mobile session securely
                      //    - user should land on the post-setup home screen, likely Today or Calendar
                      //
                      // 6. Security requirements:
                      //    - do not pass passwords in URLs
                      //    - do not pass temporary passwords in URLs
                      //    - do not pass Nextcloud app passwords in URLs
                      //    - do not reuse the Calee display session as the mobile session
                      //    - use a short-lived, single-use handoff code
                      //    - bind the handoff to the onboarding flow and expected account
                      //    - handle expired, already-used, cancelled, and invalid handoff states
                      //
                      // 7. Fallback behaviour:
                      //    - if mobile handoff fails, show the normal CaleeMobile sign-in screen
                      //    - explain that setup may be complete but mobile sign-in is still required
                      //    - provide a safe "Try again" or "Sign in manually" option
                      //
                      // 8. Related future feature:
                      //    Add "Link a Calee display" for existing signed-in users.
                      //    This should let a signed-in CaleeMobile user scan a Calee display QR code,
                      //    approve the display login through Hub/Core, and allow the Calee display to
                      //    auto-login. This should use the CaleeMobile account session, not stored
                      //    Nextcloud/app-password credentials from the legacy CaleeSync flow.
                      //
                      // Do not enable the setup link until the Calee Display auth changeover,
                      // Hub/Core mobile handoff endpoint, app link/universal link routing, and
                      // CaleeMobile session exchange are implemented and tested end-to-end.
                      // Both canonical documents, from the one shared
                      // widget. This used to be a single "Terms and
                      // Conditions" button pointing at the Portal terms.
                      const CaleeLegalLinks(),
                    ],
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }
}
