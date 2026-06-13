import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../data/api/calee_hub_client.dart';
import '../../data/models/client_service_calendar_address.dart';
import '../../ui/calee_theme.dart';
import '../../ui/calee_widgets.dart';
import 'service_calendar_address_api.dart';

class CalendarSharingAddressPage extends StatefulWidget {
  const CalendarSharingAddressPage({
    required this.hubClient,
    required this.accessToken,
    required this.serviceId,
    super.key,
  });

  final CaleeHubClient hubClient;
  final String accessToken;
  final String serviceId;

  @override
  State<CalendarSharingAddressPage> createState() =>
      _CalendarSharingAddressPageState();
}

class _CalendarSharingAddressPageState
    extends State<CalendarSharingAddressPage> {
  late final ServiceCalendarAddressApi _api;
  ClientServiceCalendarAddress? _address;
  bool _loading = true;
  bool _rotating = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _api = ServiceCalendarAddressApi(hubClient: widget.hubClient);
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final address = await _api.load(
        accessToken: widget.accessToken,
        serviceId: widget.serviceId,
      );
      if (!mounted) return;
      setState(() {
        _address = address;
        _loading = false;
      });
    } catch (e, st) {
      if (kDebugMode) {
        debugPrint('[CalendarSharingAddressPage] load failed: $e\n$st');
      }
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = kDebugMode
            ? 'Could not load Calendar Sharing Address. $e'
            : 'Could not load Calendar Sharing Address. Please try again.';
      });
    }
  }

  Future<void> _rotate() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Reset sharing address?'),
        content: const Text(
          'Only reset this address if it has been shared with the wrong person or you need a new receiving address.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Reset'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    setState(() {
      _rotating = true;
      _error = null;
    });

    try {
      final address = await _api.rotate(
        accessToken: widget.accessToken,
        serviceId: widget.serviceId,
      );
      if (!mounted) return;
      setState(() {
        _address = address;
        _rotating = false;
      });
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Sharing address reset')));
    } catch (e, st) {
      if (kDebugMode) {
        debugPrint('[CalendarSharingAddressPage] rotate failed: $e\n$st');
      }
      if (!mounted) return;
      setState(() {
        _rotating = false;
        _error = kDebugMode
            ? 'Could not reset Calendar Sharing Address. $e'
            : 'Could not reset Calendar Sharing Address. Please try again.';
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
      appBar: AppBar(title: const Text('Calendar Sharing Address')),
      body: _buildBody(context),
    );
  }

  Widget _buildBody(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_error != null && _address == null) {
      return CaleeEmptyState(
        icon: Icons.error_outline,
        title: 'Something went wrong',
        body: _error!,
        action: TextButton(onPressed: _load, child: const Text('Try again')),
      );
    }

    final address = _address!;
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
            'Use this email address when another calendar service asks who to share the calendar with.',
            style: Theme.of(
              context,
            ).textTheme.bodyMedium?.copyWith(color: CaleeColors.textSecondary),
          ),
        ),
        CaleeSection(
          children: [
            _AddressRow(
              value: address.address,
              onCopy: () => _copy(context, address.copyValue),
            ),
          ],
        ),
        const SizedBox(height: CaleeSpacing.sm),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: CaleeSpacing.sm),
          child: Text(
            'This address is only for receiving shared calendar invitations. It is not your login email.',
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: CaleeColors.textSecondary),
          ),
        ),
        if (_error != null) ...[
          const SizedBox(height: CaleeSpacing.md),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: CaleeSpacing.sm),
            child: Text(
              _error!,
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: CaleeColors.destructive),
            ),
          ),
        ],
        const SizedBox(height: CaleeSpacing.sectionSpacing),
        CaleeSection(
          children: [
            CaleeListRow(
              title: _rotating ? 'Resetting…' : 'Reset sharing address',
              subtitle:
                  'Use only if this address was shared with the wrong person.',
              enabled: !_rotating,
              onTap: _rotating ? null : _rotate,
              titleStyle: Theme.of(
                context,
              ).textTheme.bodyLarge?.copyWith(color: CaleeColors.destructive),
              trailing: _rotating
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : null,
            ),
          ],
        ),
        const SizedBox(height: 96),
      ],
    );
  }
}

class _AddressRow extends StatelessWidget {
  const _AddressRow({required this.value, required this.onCopy});

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
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'Sharing email address',
                  style: TextStyle(
                    fontSize: 16,
                    color: CaleeColors.textPrimary,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  value,
                  style: const TextStyle(
                    fontSize: 14,
                    color: CaleeColors.textSecondary,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ],
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
