import 'package:flutter/material.dart';

import '../../data/account_deletion/account_deletion_failure.dart';
import '../../data/models/account_deletion_status.dart';
import '../../ui/calee_theme.dart';
import '../../ui/calee_widgets.dart';
import 'account_deletion_controller.dart';

/// The deletion-only status and recovery surface (#556).
///
/// This is the whole app while a deletion operation may exist. It is reached
/// from an accepted request, from an unknown outcome, and from a cold launch
/// that found recovery material — and it works with NO bearer token and NO
/// password, because by the time it matters the Keycloak identity behind those
/// may be quiesced or gone.
///
/// THE RULE THIS SCREEN ENFORCES: `completed` is the only wording that says a
/// deletion succeeded, and it is reached only from
/// [AccountDeletionController.isDeletionCompleted], which is an exact match on
/// the Hub's own state string. `restored` is terminal and says deletion did NOT
/// happen. Everything else — including a state this build has never seen — is
/// rendered as still in progress.
class AccountDeletionStatusPage extends StatefulWidget {
  const AccountDeletionStatusPage({
    required this.controller,
    required this.onFinished,
    super.key,
  });

  final AccountDeletionController controller;

  /// Hands the app back to ordinary signed-out Calee once the customer has
  /// acknowledged a terminal outcome.
  final VoidCallback onFinished;

  @override
  State<AccountDeletionStatusPage> createState() =>
      _AccountDeletionStatusPageState();
}

class _AccountDeletionStatusPageState extends State<AccountDeletionStatusPage> {
  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onChanged);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  void _finish() {
    widget.controller.acknowledgeTerminalOutcome();
    widget.onFinished();
  }

  Future<void> _abandon() async {
    final confirmed = await CaleeDestructiveDialog.show(
      context: context,
      title: 'Go back to signing in?',
      body:
          'Calee has no record of a deletion request for the recovery details '
          'saved on this phone. If a request did reach Calee it will still be '
          'processed, and Calee will email you. This phone will stop tracking '
          'it.',
      confirmLabel: 'Back to sign in',
      cancelLabel: 'Keep checking',
    );
    if (!confirmed || !mounted) return;
    await widget.controller.abandonUnconfirmedRequest();
    if (!mounted) return;
    widget.onFinished();
  }

  @override
  Widget build(BuildContext context) {
    return CaleeScaffold(
      appBar: AppBar(
        title: const Text('Account deletion'),
        backgroundColor: CaleeColors.surface,
        automaticallyImplyLeading: false,
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.symmetric(
            horizontal: CaleeSpacing.pagePadding,
            vertical: CaleeSpacing.md,
          ),
          children: _children(context),
        ),
      ),
    );
  }

  List<Widget> _children(BuildContext context) {
    final controller = widget.controller;

    switch (controller.phase) {
      case AccountDeletionPhase.completed:
        return _completedChildren(context);
      case AccountDeletionPhase.restored:
        return _restoredChildren(context);
      case AccountDeletionPhase.unrecoverable:
        return _unrecoverableChildren(context);
      case AccountDeletionPhase.unresolved:
        return _unresolvedChildren(context);
      case AccountDeletionPhase.tracking:
        return _trackingChildren(context);
      // Not reachable: none of these owns the app surface. Rendering the
      // in-progress card is the fail-closed answer if that ever changes.
      case AccountDeletionPhase.inactive:
      case AccountDeletionPhase.submitting:
      case AccountDeletionPhase.refused:
      case AccountDeletionPhase.retryable:
        return _trackingChildren(context);
    }
  }

  // ── In progress ───────────────────────────────────────────────────────────

  List<Widget> _trackingChildren(BuildContext context) {
    final status = widget.controller.status;
    final copy = _progressCopy(status);

    return [
      _StatusHeader(
        key: const Key('account_deletion_progress_header'),
        icon: copy.icon,
        tint: copy.tint,
        title: copy.title,
        body: copy.body,
      ),
      const SizedBox(height: CaleeSpacing.sectionSpacing),

      // The Hub's OWN approved wording about how long this may take. Rendered
      // verbatim, never composed: this client has no measured figure to offer
      // and must not invent one.
      if (status?.completionWindowMessage != null) ...[
        _InfoCard(
          key: const Key('account_deletion_completion_window'),
          icon: Icons.schedule_outlined,
          text: status!.completionWindowMessage!,
        ),
        const SizedBox(height: CaleeSpacing.sectionSpacing),
      ],

      _StatusFailureNotice(failure: widget.controller.statusFailure),
      _ReferenceSection(controller: widget.controller),
      const SizedBox(height: CaleeSpacing.sectionSpacing),
      _RefreshButton(
        busy: widget.controller.isBusy,
        onPressed: widget.controller.refreshStatus,
      ),
      const SizedBox(height: CaleeSpacing.xl),
    ];
  }

  /// Copy for every nonterminal state, and for one this build has never seen.
  ///
  /// Reads [AccountDeletionStatus.knownState] — which is null for an
  /// unrecognised wire string — rather than `isTerminal`, so an unfamiliar
  /// future state can only ever land on the neutral in-progress wording. It can
  /// never read as success.
  static _ProgressCopy _progressCopy(AccountDeletionStatus? status) {
    switch (status?.knownState) {
      case AccountDeletionState.requested:
        return const _ProgressCopy(
          icon: Icons.hourglass_top_outlined,
          tint: CaleeColors.primary,
          title: 'Your deletion request has been received',
          body:
              'Calee has your request and will start working through it. Your '
              'account is no longer available to use.',
        );
      case AccountDeletionState.quiescing:
        return const _ProgressCopy(
          icon: Icons.hourglass_top_outlined,
          tint: CaleeColors.primary,
          title: 'Calee is preparing your account for deletion',
          body:
              'Access to your account has been closed off while Calee gets '
              'everything ready to delete.',
        );
      case AccountDeletionState.deleting:
        return const _ProgressCopy(
          icon: Icons.delete_sweep_outlined,
          tint: CaleeColors.primary,
          title: 'Calee is deleting your account',
          body:
              'Your account and personal data are being removed now. This page '
              'will show a confirmation once it has finished.',
        );
      case AccountDeletionState.failedRetryable:
        return const _ProgressCopy(
          icon: Icons.replay_outlined,
          tint: CaleeColors.warning,
          title: 'Deletion is taking longer than expected',
          body:
              'Something interrupted the deletion and Calee is retrying it. '
              'Your request is still in place — there is nothing you need to '
              'send again.',
        );
      case AccountDeletionState.supportRequired:
        return const _ProgressCopy(
          icon: Icons.support_agent_outlined,
          tint: CaleeColors.warning,
          title: 'A Calee specialist is finishing this',
          body:
              'Your deletion could not be completed automatically, so a Calee '
              'specialist has to finish it. Your request is still in place and '
              'does not need to be sent again. Quote the reference below if '
              'you contact Calee about it.',
        );
      // `completed` and `restored` never reach this method — the controller
      // routes them to their own phases. Listed so a change to that routing
      // fails loudly here rather than rendering an ending as progress.
      case AccountDeletionState.completed:
      case AccountDeletionState.restored:
      case null:
        return const _ProgressCopy(
          icon: Icons.hourglass_top_outlined,
          tint: CaleeColors.primary,
          title: 'Calee is still working on your request',
          body:
              'Your deletion request is in progress. Check back here for a '
              'confirmation once it has finished.',
        );
    }
  }

  // ── Not confirmed ─────────────────────────────────────────────────────────

  List<Widget> _unresolvedChildren(BuildContext context) {
    return [
      const _StatusHeader(
        key: Key('account_deletion_unresolved_header'),
        icon: Icons.help_outline,
        tint: CaleeColors.warning,
        title: "Calee couldn't confirm your deletion request",
        // Deliberately says neither "it was deleted" nor "nothing happened".
        // Both would be claims this app cannot make.
        body:
            'Your request may or may not have reached Calee. Your recovery '
            'details are saved securely on this phone, so checking again is '
            'safe and will never start a second deletion.',
      ),
      const SizedBox(height: CaleeSpacing.sectionSpacing),
      _StatusFailureNotice(failure: widget.controller.statusFailure),
      _ReferenceSection(controller: widget.controller),
      const SizedBox(height: CaleeSpacing.sectionSpacing),
      _RefreshButton(
        busy: widget.controller.isBusy,
        onPressed: widget.controller.refreshStatus,
      ),
      if (widget.controller.canAbandonUnconfirmedRequest) ...[
        const SizedBox(height: CaleeSpacing.sm),
        TextButton(
          key: const Key('account_deletion_abandon_button'),
          onPressed: widget.controller.isBusy ? null : _abandon,
          child: const Text('Back to sign in'),
        ),
      ],
      const SizedBox(height: CaleeSpacing.xl),
    ];
  }

  // ── Cannot be followed from this phone ────────────────────────────────────

  List<Widget> _unrecoverableChildren(BuildContext context) {
    return [
      const _StatusHeader(
        key: Key('account_deletion_unrecoverable_header'),
        icon: Icons.support_agent_outlined,
        tint: CaleeColors.warning,
        title: "This phone can't follow your deletion",
        body:
            'Calee is holding different recovery details for this account, so '
            'this phone cannot read the status. Your request has not been '
            'cancelled and does not need to be sent again — please contact '
            'Calee support with the reference below.',
      ),
      const SizedBox(height: CaleeSpacing.sectionSpacing),
      _ReferenceSection(controller: widget.controller),
      const SizedBox(height: CaleeSpacing.xl),
    ];
  }

  // ── Terminal: completed ───────────────────────────────────────────────────

  List<Widget> _completedChildren(BuildContext context) {
    final status = widget.controller.status;

    return [
      const _StatusHeader(
        key: Key('account_deletion_completed_header'),
        icon: Icons.check_circle_outline,
        tint: CaleeColors.success,
        title: 'Your Calee account has been deleted',
        body:
            'Your account and your personal data have been permanently '
            'deleted, apart from anything Calee is required to keep under '
            'approved retention rules. Your sign-in details no longer work.',
      ),
      const SizedBox(height: CaleeSpacing.sectionSpacing),
      const _InfoCard(
        icon: Icons.groups_outlined,
        text:
            'Anything owned by a household, business or organisation stays '
            'with them, including a Calee Home display set up for a household.',
      ),
      if (status?.completedAt != null) ...[
        const SizedBox(height: CaleeSpacing.sm),
        _InfoCard(
          icon: Icons.event_available_outlined,
          text: 'Completed on ${_formatDate(status!.completedAt!)}.',
        ),
      ],
      const SizedBox(height: CaleeSpacing.sectionSpacing),
      _PrimaryButton(
        key: const Key('account_deletion_done_button'),
        label: 'Done',
        onPressed: _finish,
      ),
      const SizedBox(height: CaleeSpacing.xl),
    ];
  }

  // ── Terminal: restored ────────────────────────────────────────────────────

  List<Widget> _restoredChildren(BuildContext context) {
    return [
      const _StatusHeader(
        key: Key('account_deletion_restored_header'),
        icon: Icons.undo_outlined,
        tint: CaleeColors.info,
        // States the outcome first, so it can never be skim-read as success.
        title: 'Your account was not deleted',
        body:
            'Calee stopped the deletion before anything was removed and your '
            'account has been restored. You can sign in and carry on as '
            'normal, and you can ask to delete your account again whenever you '
            'want.',
      ),
      const SizedBox(height: CaleeSpacing.sectionSpacing),
      _PrimaryButton(
        key: const Key('account_deletion_sign_in_button'),
        label: 'Sign in',
        onPressed: _finish,
      ),
      const SizedBox(height: CaleeSpacing.xl),
    ];
  }

  static String _formatDate(DateTime value) {
    final local = value.toLocal();
    const months = [
      'January',
      'February',
      'March',
      'April',
      'May',
      'June',
      'July',
      'August',
      'September',
      'October',
      'November',
      'December',
    ];
    return '${local.day} ${months[local.month - 1]} ${local.year}';
  }
}

// ─────────────────────────────────────────────
// Pieces
// ─────────────────────────────────────────────

class _ProgressCopy {
  const _ProgressCopy({
    required this.icon,
    required this.tint,
    required this.title,
    required this.body,
  });

  final IconData icon;
  final Color tint;
  final String title;
  final String body;
}

class _StatusHeader extends StatelessWidget {
  const _StatusHeader({
    required this.icon,
    required this.tint,
    required this.title,
    required this.body,
    super.key,
  });

  final IconData icon;
  final Color tint;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 48,
          height: 48,
          decoration: BoxDecoration(
            color: tint.withAlpha(CaleeAlpha.pct10),
            shape: BoxShape.circle,
          ),
          child: Icon(icon, color: tint, size: 26),
        ),
        const SizedBox(height: CaleeSpacing.md),
        Text(
          title,
          style: theme.textTheme.titleLarge?.copyWith(
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: CaleeSpacing.sm),
        Text(
          body,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: CaleeColors.textSecondary,
          ),
        ),
      ],
    );
  }
}

class _InfoCard extends StatelessWidget {
  const _InfoCard({required this.icon, required this.text, super.key});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(CaleeSpacing.md),
      decoration: BoxDecoration(
        color: CaleeColors.surface,
        borderRadius: BorderRadius.circular(CaleeRadius.card),
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

/// Why the last status read did not answer. Never presented as an outcome.
class _StatusFailureNotice extends StatelessWidget {
  const _StatusFailureNotice({required this.failure});

  final AccountDeletionStatusFailure? failure;

  @override
  Widget build(BuildContext context) {
    final f = failure;
    if (f == null) return const SizedBox.shrink();

    final text = switch (f.kind) {
      // The Hub answers 404 identically for unknown, malformed and wrong
      // material so the route cannot be used as an oracle. This client cannot
      // tell them apart either, and must not pretend to.
      AccountDeletionStatusFailureKind.notFound =>
        'Calee has no deletion request matching the recovery details saved on '
            'this phone.',
      AccountDeletionStatusFailureKind.unavailable =>
        "Calee couldn't be reached just now, so this status may be out of "
            'date. Nothing has changed about your request.',
    };

    return Padding(
      padding: const EdgeInsets.only(bottom: CaleeSpacing.sectionSpacing),
      child: Container(
        key: const Key('account_deletion_status_failure_notice'),
        padding: const EdgeInsets.all(CaleeSpacing.md),
        decoration: BoxDecoration(
          color: CaleeColors.warning.withAlpha(CaleeAlpha.pct8),
          borderRadius: BorderRadius.circular(CaleeRadius.card),
        ),
        child: Text(
          text,
          style: Theme.of(
            context,
          ).textTheme.bodyMedium?.copyWith(color: CaleeColors.textPrimary),
        ),
      ),
    );
  }
}

/// The handles a support conversation can use.
///
/// The recovery ID is PUBLIC by design — naming an operation is not
/// authorising it — and is what lets support find the operation. The recovery
/// SECRET is never rendered, never logged and never leaves the request body.
class _ReferenceSection extends StatelessWidget {
  const _ReferenceSection({required this.controller});

  final AccountDeletionController controller;

  @override
  Widget build(BuildContext context) {
    final operationId = controller.operationIdForSupport;
    final recoveryId = controller.recoveryIdForSupport;
    if (operationId == null && recoveryId == null) {
      return const SizedBox.shrink();
    }

    return CaleeSection(
      title: 'Reference',
      footer: 'Quote this if you contact Calee about your deletion.',
      children: [
        if (operationId != null)
          CaleeListRow(
            key: const Key('account_deletion_operation_id_row'),
            title: 'Request',
            subtitle: operationId,
            trailing: const SizedBox.shrink(),
          ),
        if (recoveryId != null)
          CaleeListRow(
            key: const Key('account_deletion_recovery_id_row'),
            title: 'This phone',
            subtitle: recoveryId,
            trailing: const SizedBox.shrink(),
          ),
      ],
    );
  }
}

class _RefreshButton extends StatelessWidget {
  const _RefreshButton({required this.busy, required this.onPressed});

  final bool busy;
  final Future<void> Function() onPressed;

  @override
  Widget build(BuildContext context) {
    return _PrimaryButton(
      key: const Key('account_deletion_refresh_button'),
      label: 'Check status',
      busy: busy,
      onPressed: busy ? null : () => onPressed(),
    );
  }
}

class _PrimaryButton extends StatelessWidget {
  const _PrimaryButton({
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
          backgroundColor: CaleeColors.primary,
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
