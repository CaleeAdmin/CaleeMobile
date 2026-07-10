import 'package:flutter/material.dart';

import 'display_activation_controller.dart';

/// The way a [DisplaySetupConfirmationPage] route finished.
///
/// The route is pushed as a `MaterialPageRoute<DisplaySetupConfirmationResult>`
/// and every explicit button pops with one of these values. When the route
/// future completes with `null` — Android system Back, [Navigator.maybePop],
/// the iOS interactive back gesture, or any other pop not initiated by a
/// button — the owner treats it as an implicit [cancelled].
enum DisplaySetupConfirmationResult {
  cancelled,
  useDifferentAccount,
  activated,
}

class DisplaySetupConfirmationPage extends StatefulWidget {
  const DisplaySetupConfirmationPage({
    required this.token,
    required this.accountEmail,
    required this.activationController,
    required this.accessToken,
    super.key,
  });

  final String token;
  final String accountEmail;
  final DisplayActivationController activationController;
  final String accessToken;

  @override
  State<DisplaySetupConfirmationPage> createState() =>
      _DisplaySetupConfirmationPageState();
}

class _DisplaySetupConfirmationPageState
    extends State<DisplaySetupConfirmationPage> {
  Future<void> _connectDisplay() async {
    final success = await widget.activationController.activate(
      accessToken: widget.accessToken,
      token: widget.token,
    );
    if (success && mounted) {
      Navigator.of(context).pop(DisplaySetupConfirmationResult.activated);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: SafeArea(
        minimum: const EdgeInsets.all(24),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: AnimatedBuilder(
              animation: widget.activationController,
              builder: (context, _) {
                final isLoading = widget.activationController.isLoading;
                final errorMessage = widget.activationController.errorMessage;
                return Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Icon(Icons.tv_outlined, size: 48),
                    const SizedBox(height: 16),
                    Text(
                      'Connect this Calee display?',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.headlineSmall?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Signed in as ${widget.accountEmail}',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    if (errorMessage != null) ...[
                      const SizedBox(height: 12),
                      Text(
                        errorMessage,
                        textAlign: TextAlign.center,
                        style: TextStyle(color: theme.colorScheme.error),
                      ),
                    ],
                    const SizedBox(height: 32),
                    FilledButton(
                      onPressed: isLoading ? null : _connectDisplay,
                      child: isLoading
                          ? const SizedBox.square(
                              dimension: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Text('Connect display'),
                    ),
                    const SizedBox(height: 12),
                    OutlinedButton(
                      onPressed: isLoading
                          ? null
                          : () => Navigator.of(context).pop(
                              DisplaySetupConfirmationResult
                                  .useDifferentAccount,
                            ),
                      child: const Text('Use a different account'),
                    ),
                    const SizedBox(height: 12),
                    TextButton(
                      onPressed: isLoading
                          ? null
                          : () => Navigator.of(
                              context,
                            ).pop(DisplaySetupConfirmationResult.cancelled),
                      child: const Text('Cancel'),
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}
