import 'dart:async';

import 'package:flutter/material.dart';

import 'display_activation_controller.dart';

class DisplaySetupConfirmationPage extends StatefulWidget {
  const DisplaySetupConfirmationPage({
    required this.token,
    required this.accountEmail,
    required this.activationController,
    required this.accessToken,
    required this.onActivated,
    required this.onUseDifferentAccount,
    super.key,
  });

  final String token;
  final String accountEmail;
  final DisplayActivationController activationController;
  final String accessToken;
  final FutureOr<void> Function() onActivated;
  final VoidCallback onUseDifferentAccount;

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
      await widget.onActivated();
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
                          : widget.onUseDifferentAccount,
                      child: const Text('Use a different account'),
                    ),
                    const SizedBox(height: 12),
                    TextButton(
                      onPressed: isLoading
                          ? null
                          : () => Navigator.of(context).pop(),
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
