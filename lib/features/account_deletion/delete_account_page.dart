import 'package:flutter/material.dart';

import '../../data/api/calee_hub_client.dart';
import '../../ui/calee_theme.dart';
import '../../ui/calee_widgets.dart';
import 'account_deletion_controller.dart';

/// Settings -> Account -> Delete account (#556).
///
/// Two deliberate steps before anything irreversible happens:
///
///   1. an explanation of what permanent deletion actually does, with a plain
///      Cancel;
///   2. recent re-authentication AND the exact destructive phrase, typed --
///      then one more destructive confirmation.
///
/// The typed phrase is a CLIENT-SIDE gate. The phrase the Hub receives is
/// always [CaleeHubClient.accountDeletionConfirmationPhrase], supplied by the
/// client itself, so what the customer types can never become a wrong value on
/// the wire.
///
/// NOTHING HERE TALKS TO THE HUB OR THE SECURE STORE. Every decision about what
/// a failure meant belongs to [AccountDeletionController]; this widget renders
/// its phase and forwards two strings.
class DeleteAccountPage extends StatefulWidget {
  const DeleteAccountPage({
    required this.controller,
    required this.accessToken,
    required this.accountId,
    this.accountEmail,
    super.key,
  });

  final AccountDeletionController controller;

  /// The live bearer token. Deletion is the one destructive route that still
  /// needs ordinary authentication -- the recovery credential replaces it only
  /// AFTER the operation exists.
  final String accessToken;

  /// Remembered so a completion observed days from now cleans up the right
  /// account rather than the device.
  final String accountId;

  /// Shown so the customer can see WHICH account is about to be deleted.
  final String? accountEmail;

  @override
  State<DeleteAccountPage> createState() => _DeleteAccountPageState();
}

class _DeleteAccountPageState extends State<DeleteAccountPage> {
  final _passwordController = TextEditingController();
  final _confirmationController = TextEditingController();

  /// False until the customer has read the explanation and chosen to continue.
  /// The password and confirmation fields do not exist before that.
  bool _showingConfirmationStep = false;
  bool _passwordVisible = false;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onControllerChanged);
    _passwordController.addListener(_onFieldChanged);
    _confirmationController.addListener(_onFieldChanged);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onControllerChanged);
    _passwordController.dispose();
    _confirmationController.dispose();
    super.dispose();
  }

  void _onControllerChanged() {
    if (mounted) setState(() {});
  }

  void _onFieldChanged() {
    if (mounted) setState(() {});
  }

  /// The typed phrase must match the Hub's exact wording, ignoring case and
  /// surrounding/repeated whitespace. Nothing looser: this is the interaction
  /// that makes an accidental permanent deletion impossible.
  bool get _confirmationMatches {
    final typed = _confirmationController.text
        .trim()
        .replaceAll(RegExp(r'\s+'), ' ')
        .toUpperCase();
    return typed == CaleeHubClient.accountDeletionConfirmationPhrase;
  }

  bool get _passwordProvided => _passwordController.text.isNotEmpty;

  bool get _canSubmit =>
      _passwordProvided && _confirmationMatches && !widget.controller.isBusy;

  Future<void> _submit() async {
    if (!_canSubmit) return;

    // The last gate. Everything after this point may be irreversible.
    final confirmed = await CaleeDestructiveDialog.show(
      context: context,
      title: 'Delete your Calee account?',
      body:
          'This permanently deletes your Calee account and your personal data, '
          'subject to the retention rules Calee is required to follow. Once '
          'Calee accepts this request there is no Undo in the app.',
      confirmLabel: 'Delete permanently',
      cancelLabel: 'Keep my account',
    );
    if (!confirmed || !mounted) return;

    await widget.controller.submit(
      accessToken: widget.accessToken,
      password: _passwordController.text,
      accountId: widget.accountId,
    );

    if (!mounted) return;
    // The password is finished with the moment the request has been answered.
    // It is never persisted, and it does not linger in a controller either.
    _passwordController.clear();
  }

  @override
  Widget build(BuildContext context) {
    final phase = widget.controller.phase;

    return PopScope(
      // While the outcome is unknown the two explicit exits on the retry card
      // are the only ways out: a swipe back would leave a possibly-committed
      // deletion behind an ordinary Settings screen.
      canPop: phase != AccountDeletionPhase.retryable,
      child: CaleeScaffold(
        appBar: AppBar(
          title: const Text('Delete account'),
          backgroundColor: CaleeColors.surface,
          automaticallyImplyLeading: phase != AccountDeletionPhase.retryable,
        ),
        body: SafeArea(
          child: ListView(
            padding: const EdgeInsets.symmetric(
              horizontal: CaleeSpacing.pagePadding,
              vertical: CaleeSpacing.md,
            ),
            children: phase == AccountDeletionPhase.retryable
                ? _retryChildren(context)
                : _flowChildren(context),
          ),
        ),
      ),
    );
  }

  // ── Step 1 and 2 ──────────────────────────────────────────────────────────

  List<Widget> _flowChildren(BuildContext context) {
    return [
      const _PermanentDeletionExplanation(),
      const SizedBox(height: CaleeSpacing.sectionSpacing),
      if (widget.controller.phase == AccountDeletionPhase.refused) ...[
        _RefusalNotice(
          reason: widget.controller.refusalReason,
          requestId: widget.controller.requestFailure?.requestId,
        ),
        const SizedBox(height: CaleeSpacing.sectionSpacing),
      ],
      if (!_showingConfirmationStep)
        _StepOneActions(
          accountEmail: widget.accountEmail,
          onCancel: () => Navigator.of(context).maybePop(),
          onContinue: () => setState(() => _showingConfirmationStep = true),
        )
      else
        _ConfirmationStep(
          passwordController: _passwordController,
          confirmationController: _confirmationController,
          passwordVisible: _passwordVisible,
          onTogglePasswordVisible: () =>
              setState(() => _passwordVisible = !_passwordVisible),
          confirmationMatches: _confirmationMatches,
          canSubmit: _canSubmit,
          isBusy: widget.controller.isBusy,
          onCancel: () => Navigator.of(context).maybePop(),
          onSubmit: _submit,
        ),
      const SizedBox(height: CaleeSpacing.xl),
    ];
  }

  // ── The unknown-outcome card ──────────────────────────────────────────────

  List<Widget> _retryChildren(BuildContext context) {
    final needsFreshMaterial =
        widget.controller.requestFailure?.requiresFreshRecoveryMaterial ??
        false;

    return [
      CaleeSection(
        title: 'Not confirmed',
        children: [
          Padding(
            padding: const EdgeInsets.all(CaleeSpacing.md),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  needsFreshMaterial
                      ? "Calee couldn't use the recovery details saved on this "
                            'phone.'
                      : "Calee couldn't confirm your deletion request.",
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: CaleeSpacing.sm),
                Text(
                  needsFreshMaterial
                      ? 'New recovery details have been saved securely on this '
                            'phone. Nothing has been deleted. You can send the '
                            'request again.'
                      : 'Your request may or may not have reached Calee. '
                            'Sending it again is safe — Calee recognises a '
                            'repeat of the same request and will never create a '
                            'second deletion.',
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: CaleeColors.textSecondary,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
      const SizedBox(height: CaleeSpacing.sectionSpacing),

      // The password is deliberately not retained across a submission, so the
      // retry re-authenticates rather than replaying a held secret. The
      // recovery credential, by contrast, is reused unchanged: that is what
      // makes the Hub's idempotent replay resolve the operation that may
      // already exist instead of creating a second one.
      CaleeSection(
        title: 'Confirm it is you',
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: CaleeSpacing.md,
              vertical: CaleeSpacing.sm,
            ),
            child: TextField(
              key: const Key('delete_account_password_field'),
              controller: _passwordController,
              obscureText: !_passwordVisible,
              decoration: InputDecoration(
                labelText: 'Your Calee password',
                border: const OutlineInputBorder(),
                suffixIcon: IconButton(
                  icon: Icon(
                    _passwordVisible
                        ? Icons.visibility_off_outlined
                        : Icons.visibility_outlined,
                    size: 20,
                  ),
                  onPressed: () =>
                      setState(() => _passwordVisible = !_passwordVisible),
                  tooltip: _passwordVisible ? 'Hide password' : 'Show password',
                ),
              ),
            ),
          ),
        ],
      ),
      const SizedBox(height: CaleeSpacing.sectionSpacing),
      _PrimaryDestructiveButton(
        key: const Key('delete_account_retry_button'),
        label: 'Try again',
        busy: widget.controller.isBusy,
        onPressed: _canSubmit ? _submit : null,
      ),
      const SizedBox(height: CaleeSpacing.sm),
      TextButton(
        key: const Key('delete_account_check_status_button'),
        onPressed: widget.controller.isBusy
            ? null
            : () => widget.controller.leaveRetry(),
        child: const Text('Check deletion status instead'),
      ),
      const SizedBox(height: CaleeSpacing.xl),
    ];
  }
}

// ─────────────────────────────────────────────
// Explanation
// ─────────────────────────────────────────────

/// What permanent deletion is, and — just as importantly — what it is not.
///
/// NO NUMERIC TIMEFRAME APPEARS HERE. Calee has not published a measured
/// completion window, and the Hub's own `completionWindowMessage` only exists
/// once an operation does. Inventing "within 24 hours" on this screen would be
/// a promise nobody has measured.
class _PermanentDeletionExplanation extends StatelessWidget {
  const _PermanentDeletionExplanation();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Icon(
              Icons.warning_amber_rounded,
              color: CaleeColors.destructive,
              size: 24,
            ),
            const SizedBox(width: CaleeSpacing.sm),
            Expanded(
              child: Text(
                'This permanently deletes your account',
                key: const Key('delete_account_headline'),
                style: theme.textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w700,
                  color: CaleeColors.destructive,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: CaleeSpacing.sm),
        Text(
          'This is not signing out, and it is not pausing your account. '
          'Deleting is permanent and cannot be undone from the app.',
          style: theme.textTheme.bodyMedium?.copyWith(
            color: CaleeColors.textSecondary,
          ),
        ),
        const SizedBox(height: CaleeSpacing.sectionSpacing),
        const CaleeSection(
          title: 'What happens',
          children: [
            _ExplanationPoint(
              icon: Icons.delete_forever_outlined,
              text:
                  'Your Calee account and the personal data held with it are '
                  'permanently deleted, apart from anything Calee is required '
                  'to keep under approved retention rules.',
            ),
            _ExplanationPoint(
              icon: Icons.groups_outlined,
              text:
                  'Things owned by a household, business or organisation are '
                  'not deleted with you. Other people keep what belongs to '
                  'them.',
            ),
            _ExplanationPoint(
              icon: Icons.tv_outlined,
              text:
                  'A Calee Home display or tablet that belongs to your '
                  'household stays with the household. Deleting your own '
                  'account does not remove it.',
            ),
            _ExplanationPoint(
              icon: Icons.schedule_outlined,
              text:
                  'Deletion is processed after you confirm. Calee will confirm '
                  'in the app when it has finished.',
            ),
            _ExplanationPoint(
              icon: Icons.block_outlined,
              text:
                  'You can cancel any time before you confirm. Once Calee has '
                  'accepted the request, the app has no Undo.',
            ),
          ],
        ),
      ],
    );
  }
}

class _ExplanationPoint extends StatelessWidget {
  const _ExplanationPoint({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: CaleeSpacing.md,
        vertical: 11,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 20, color: CaleeColors.textTertiary),
          const SizedBox(width: CaleeSpacing.md),
          Expanded(
            child: Text(
              text,
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(color: CaleeColors.textPrimary),
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────
// Step 1 actions
// ─────────────────────────────────────────────

class _StepOneActions extends StatelessWidget {
  const _StepOneActions({
    required this.accountEmail,
    required this.onCancel,
    required this.onContinue,
  });

  final String? accountEmail;
  final VoidCallback onCancel;
  final VoidCallback onContinue;

  @override
  Widget build(BuildContext context) {
    final email = accountEmail;

    return Column(
      children: [
        if (email != null && email.isNotEmpty) ...[
          CaleeSection(
            children: [
              CaleeListRow(
                title: email,
                subtitle: 'The account that will be deleted',
                leading: const Icon(
                  Icons.person_outline,
                  size: 20,
                  color: CaleeColors.textTertiary,
                ),
                trailing: const SizedBox.shrink(),
              ),
            ],
          ),
          const SizedBox(height: CaleeSpacing.sectionSpacing),
        ],
        _PrimaryDestructiveButton(
          key: const Key('delete_account_continue_button'),
          label: 'Continue',
          onPressed: onContinue,
        ),
        const SizedBox(height: CaleeSpacing.sm),
        TextButton(
          key: const Key('delete_account_cancel_button'),
          onPressed: onCancel,
          child: const Text('Cancel'),
        ),
      ],
    );
  }
}

// ─────────────────────────────────────────────
// Step 2: re-authentication + destructive phrase
// ─────────────────────────────────────────────

class _ConfirmationStep extends StatelessWidget {
  const _ConfirmationStep({
    required this.passwordController,
    required this.confirmationController,
    required this.passwordVisible,
    required this.onTogglePasswordVisible,
    required this.confirmationMatches,
    required this.canSubmit,
    required this.isBusy,
    required this.onCancel,
    required this.onSubmit,
  });

  final TextEditingController passwordController;
  final TextEditingController confirmationController;
  final bool passwordVisible;
  final VoidCallback onTogglePasswordVisible;
  final bool confirmationMatches;
  final bool canSubmit;
  final bool isBusy;
  final VoidCallback onCancel;
  final VoidCallback onSubmit;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        CaleeSection(
          title: 'Confirm it is you',
          footer:
              'Calee asks for your password again because deleting an account '
              'cannot be undone.',
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: CaleeSpacing.md,
                vertical: CaleeSpacing.sm,
              ),
              child: TextField(
                key: const Key('delete_account_password_field'),
                controller: passwordController,
                obscureText: !passwordVisible,
                autofillHints: const [AutofillHints.password],
                decoration: InputDecoration(
                  labelText: 'Your Calee password',
                  border: const OutlineInputBorder(),
                  suffixIcon: IconButton(
                    icon: Icon(
                      passwordVisible
                          ? Icons.visibility_off_outlined
                          : Icons.visibility_outlined,
                      size: 20,
                    ),
                    onPressed: onTogglePasswordVisible,
                    tooltip: passwordVisible
                        ? 'Hide password'
                        : 'Show password',
                  ),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: CaleeSpacing.sectionSpacing),
        CaleeSection(
          title: 'Type the confirmation',
          footer:
              'Type it exactly. This is deliberately awkward so an account is '
              'never deleted by a stray tap.',
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                CaleeSpacing.md,
                CaleeSpacing.sm,
                CaleeSpacing.md,
                CaleeSpacing.sm,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'To continue, type:',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: CaleeColors.textSecondary,
                    ),
                  ),
                  const SizedBox(height: CaleeSpacing.xs),
                  SelectableText(
                    CaleeHubClient.accountDeletionConfirmationPhrase,
                    key: const Key('delete_account_required_phrase'),
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.5,
                    ),
                  ),
                  const SizedBox(height: CaleeSpacing.sm),
                  TextField(
                    key: const Key('delete_account_confirmation_field'),
                    controller: confirmationController,
                    autocorrect: false,
                    enableSuggestions: false,
                    textCapitalization: TextCapitalization.characters,
                    decoration: InputDecoration(
                      labelText: 'Confirmation',
                      border: const OutlineInputBorder(),
                      suffixIcon: confirmationMatches
                          ? const Icon(
                              Icons.check_circle_outline,
                              color: CaleeColors.success,
                              size: 20,
                            )
                          : null,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: CaleeSpacing.sectionSpacing),
        _PrimaryDestructiveButton(
          key: const Key('delete_account_submit_button'),
          label: 'Delete my account permanently',
          busy: isBusy,
          onPressed: canSubmit ? onSubmit : null,
        ),
        const SizedBox(height: CaleeSpacing.sm),
        TextButton(
          key: const Key('delete_account_cancel_button'),
          onPressed: isBusy ? null : onCancel,
          child: const Text('Cancel'),
        ),
      ],
    );
  }
}

// ─────────────────────────────────────────────
// Refusal notice
// ─────────────────────────────────────────────

/// Guidance for a refusal the Hub PROVED happened before anything was created.
///
/// Every message here is safe to show to a signed-in customer whose account is
/// untouched, because that is exactly the situation: `isPreAcceptance` is a
/// fact, not an assumption.
class _RefusalNotice extends StatelessWidget {
  const _RefusalNotice({required this.reason, this.requestId});

  final AccountDeletionRefusalReason? reason;
  final String? requestId;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (title, body) = _copyFor(reason);

    return Container(
      key: const Key('delete_account_refusal_notice'),
      padding: const EdgeInsets.all(CaleeSpacing.md),
      decoration: BoxDecoration(
        color: CaleeColors.destructive.withAlpha(CaleeAlpha.pct8),
        borderRadius: BorderRadius.circular(CaleeRadius.card),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w700,
              color: CaleeColors.destructive,
            ),
          ),
          const SizedBox(height: CaleeSpacing.xs),
          Text(
            body,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: CaleeColors.textPrimary,
            ),
          ),
          if (requestId != null && requestId!.isNotEmpty) ...[
            const SizedBox(height: CaleeSpacing.sm),
            Text(
              'Reference: $requestId',
              style: theme.textTheme.bodySmall?.copyWith(
                color: CaleeColors.textSecondary,
              ),
            ),
          ],
        ],
      ),
    );
  }

  static (String, String) _copyFor(AccountDeletionRefusalReason? reason) {
    switch (reason) {
      case AccountDeletionRefusalReason.reauthenticationRejected:
      case null:
        return (
          "That password didn't work",
          'Your account has not been changed. Check your password and try '
              'again.',
        );
      case AccountDeletionRefusalReason.reauthenticationUnsupported:
        return (
          "This account can't be deleted in the app",
          'Your account has not been changed. Please contact Calee support to '
              'delete it.',
        );
      case AccountDeletionRefusalReason.managedAccount:
        return (
          'Your organisation manages this account',
          'Your account has not been changed. Whoever administers your '
              'organisation needs to remove it for you.',
        );
      case AccountDeletionRefusalReason.sessionExpired:
        return (
          'Please sign in again',
          'Your account has not been changed. Your session has expired, so '
              'Calee could not verify this request.',
        );
      case AccountDeletionRefusalReason.contractRejected:
        return (
          "Calee couldn't accept this request",
          'Your account has not been changed. Please try again, or contact '
              'Calee support if this keeps happening.',
        );
      case AccountDeletionRefusalReason.recoveryMaterialUnavailable:
        return (
          "Calee couldn't prepare this phone",
          'Nothing was sent and your account has not been changed. Calee could '
              'not securely save the details it needs to keep you informed '
              'about a deletion, so it stopped before asking.',
        );
    }
  }
}

// ─────────────────────────────────────────────
// Shared button
// ─────────────────────────────────────────────

class _PrimaryDestructiveButton extends StatelessWidget {
  const _PrimaryDestructiveButton({
    required this.label,
    required this.onPressed,
    this.busy = false,
    super.key,
  });

  final String label;
  final VoidCallback? onPressed;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      child: FilledButton(
        style: FilledButton.styleFrom(
          backgroundColor: CaleeColors.destructive,
          foregroundColor: CaleeColors.textInverse,
          padding: const EdgeInsets.symmetric(vertical: CaleeSpacing.md),
        ),
        onPressed: busy ? null : onPressed,
        child: busy
            ? const SizedBox(
                height: 20,
                width: 20,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: CaleeColors.textInverse,
                ),
              )
            : Text(label),
      ),
    );
  }
}
