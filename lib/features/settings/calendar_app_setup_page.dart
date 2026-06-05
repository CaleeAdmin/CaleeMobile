import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../data/api/calee_hub_client.dart';
import '../../data/models/client_caldav_account.dart';
import '../../ui/calee_theme.dart';
import '../../ui/calee_widgets.dart';

class CalendarAppSetupPage extends StatefulWidget {
  const CalendarAppSetupPage({
    required this.hubClient,
    required this.accessToken,
    required this.serviceId,
    super.key,
  });

  final CaleeHubClient hubClient;
  final String accessToken;
  final String serviceId;

  @override
  State<CalendarAppSetupPage> createState() => _CalendarAppSetupPageState();
}

class _CalendarAppSetupPageState extends State<CalendarAppSetupPage> {
  ClientCalDavAccount? _account;
  bool _loading = true;
  String? _error;
  bool _passwordVisible = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final account = await widget.hubClient.caldavAccount(
        accessToken: widget.accessToken,
        serviceId: widget.serviceId,
      );
      if (!mounted) return;
      setState(() {
        _account = account;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error =
            'Could not load Calendar App Setup. Please try again.'
            '${kDebugMode && error is CaleeHubException ? '\nDebug: ${error.debugSummary}' : ''}';
      });
    }
  }

  void _copy(BuildContext context, String value) {
    Clipboard.setData(ClipboardData(text: value));
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Copied')));
  }

  @override
  Widget build(BuildContext context) {
    return CaleeScaffold(
      appBar: AppBar(title: const Text('Calendar App Setup')),
      body: _buildBody(context),
    );
  }

  Widget _buildBody(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_error != null) {
      return CaleeEmptyState(
        icon: Icons.error_outline,
        title: 'Something went wrong',
        body: _error!,
        action: TextButton(onPressed: _load, child: const Text('Try again')),
      );
    }

    final account = _account!;
    return ListView(
      padding: const EdgeInsets.symmetric(
        horizontal: CaleeSpacing.pagePadding,
        vertical: CaleeSpacing.md,
      ),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            CaleeSpacing.sm,
            0,
            CaleeSpacing.sm,
            CaleeSpacing.md,
          ),
          child: Text(
            'Use these details to add this Calee calendar service to Apple Calendar or another app that supports CalDAV.',
            style: Theme.of(
              context,
            ).textTheme.bodyMedium?.copyWith(color: CaleeColors.textSecondary),
          ),
        ),
        CaleeSection(
          children: [
            _FieldRow(
              label: 'Server',
              value: account.server,
              onCopy: () => _copy(context, account.server),
            ),
            _FieldRow(
              label: 'Username',
              value: account.username,
              onCopy: () => _copy(context, account.username),
            ),
            _PasswordRow(
              value: account.password,
              visible: _passwordVisible,
              onToggleVisibility: () =>
                  setState(() => _passwordVisible = !_passwordVisible),
              onCopy: () => _copy(context, account.password),
            ),
            _FieldRow(
              label: 'Description',
              value: account.description,
              onCopy: () => _copy(context, account.description),
            ),
          ],
        ),
        const SizedBox(height: 96),
      ],
    );
  }
}

// ─────────────────────────────────────────────
// _FieldRow
// ─────────────────────────────────────────────

class _FieldRow extends StatelessWidget {
  const _FieldRow({
    required this.label,
    required this.value,
    required this.onCopy,
  });

  final String label;
  final String value;
  final VoidCallback onCopy;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: CaleeSpacing.md,
        vertical: 11,
      ),
      child: Row(
        children: [
          SizedBox(
            width: 96,
            child: Text(
              label,
              style: const TextStyle(
                fontSize: 16,
                color: CaleeColors.textPrimary,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(
                fontSize: 14,
                color: CaleeColors.textSecondary,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: CaleeSpacing.xs),
          TextButton(
            onPressed: onCopy,
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: CaleeSpacing.sm),
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            child: const Text('Copy'),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────
// _PasswordRow
// ─────────────────────────────────────────────

class _PasswordRow extends StatelessWidget {
  const _PasswordRow({
    required this.value,
    required this.visible,
    required this.onToggleVisibility,
    required this.onCopy,
  });

  final String value;
  final bool visible;
  final VoidCallback onToggleVisibility;
  final VoidCallback onCopy;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: CaleeSpacing.md,
        vertical: 11,
      ),
      child: Row(
        children: [
          const SizedBox(
            width: 96,
            child: Text(
              'Password',
              style: TextStyle(fontSize: 16, color: CaleeColors.textPrimary),
            ),
          ),
          Expanded(
            child: Text(
              visible ? value : '••••••••',
              style: const TextStyle(
                fontSize: 14,
                color: CaleeColors.textSecondary,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: CaleeSpacing.xs),
          TextButton(
            onPressed: onToggleVisibility,
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: CaleeSpacing.xs),
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            child: Text(visible ? 'Hide' : 'Show'),
          ),
          TextButton(
            onPressed: onCopy,
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: CaleeSpacing.xs),
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            child: const Text('Copy'),
          ),
        ],
      ),
    );
  }
}
