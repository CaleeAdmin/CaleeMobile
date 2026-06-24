import 'package:flutter/material.dart';

import '../../../data/api/calee_hub_client.dart';
import '../../../data/models/external_calendar_connection.dart';
import '../../../ui/calee_design.dart';

class GoogleCalendarSelectionPage extends StatefulWidget {
  const GoogleCalendarSelectionPage({
    required this.hubClient,
    required this.accessToken,
    required this.connection,
    required this.onViewCalendar,
    required this.onDone,
    super.key,
  });

  final CaleeHubClient hubClient;
  final String accessToken;
  final ExternalCalendarConnection connection;
  final VoidCallback onViewCalendar;
  final VoidCallback onDone;

  @override
  State<GoogleCalendarSelectionPage> createState() =>
      _GoogleCalendarSelectionPageState();
}

class _GoogleCalendarSelectionPageState
    extends State<GoogleCalendarSelectionPage> {
  List<ExternalCalendar>? _calendars;
  bool _isLoading = true;
  String? _loadError;

  final _syncingIds = <String>{};
  final _syncSuccessIds = <String>{};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _isLoading = true;
      _loadError = null;
    });
    try {
      final cals = await widget.hubClient.externalCalendarsForConnection(
        accessToken: widget.accessToken,
        connectionId: widget.connection.id,
      );
      if (mounted) setState(() {
        _calendars = cals;
        _isLoading = false;
      });
    } catch (error) {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _loadError = _friendlyError(error);
        });
      }
    }
  }

  Future<void> _toggleCalendar(ExternalCalendar cal, bool enabled) async {
    final cals = _calendars;
    if (cals == null) return;

    final idx = cals.indexWhere((c) => c.id == cal.id);
    if (idx < 0) return;

    final updated = ExternalCalendar.fromJson({
      'id': cal.id,
      'providerKey': cal.providerKey,
      'externalCalendarId': cal.externalCalendarId,
      'displayName': cal.displayName,
      'providerDisplayName': cal.providerDisplayName,
      'color': cal.color,
      'timeZone': cal.timeZone,
      'accessRole': cal.accessRole,
      'syncEnabled': enabled,
      'visibilityStatus': cal.visibilityStatus,
      'accessMode': cal.accessMode,
      'sourceOfTruthPolicy': cal.sourceOfTruthPolicy,
      'privacySettings': cal.privacySettings.toJson(),
      'syncStatus': cal.syncStatus,
      'lastSyncedAt': cal.lastSyncedAt,
    });

    setState(() {
      _calendars = [
        ...cals.sublist(0, idx),
        updated,
        ...cals.sublist(idx + 1),
      ];
    });

    try {
      await widget.hubClient.updateExternalCalendar(
        accessToken: widget.accessToken,
        externalCalendarId: cal.id,
        syncEnabled: enabled,
      );
    } catch (error) {
      if (mounted) {
        // Roll back
        setState(() {
          final rollback = ExternalCalendar.fromJson({
            'id': cal.id,
            'providerKey': cal.providerKey,
            'externalCalendarId': cal.externalCalendarId,
            'displayName': cal.displayName,
            'providerDisplayName': cal.providerDisplayName,
            'color': cal.color,
            'timeZone': cal.timeZone,
            'accessRole': cal.accessRole,
            'syncEnabled': cal.syncEnabled,
            'visibilityStatus': cal.visibilityStatus,
            'accessMode': cal.accessMode,
            'sourceOfTruthPolicy': cal.sourceOfTruthPolicy,
            'privacySettings': cal.privacySettings.toJson(),
            'syncStatus': cal.syncStatus,
            'lastSyncedAt': cal.lastSyncedAt,
          });
          final cur = _calendars ?? [];
          final i = cur.indexWhere((c) => c.id == cal.id);
          if (i >= 0) {
            _calendars = [
              ...cur.sublist(0, i),
              rollback,
              ...cur.sublist(i + 1),
            ];
          }
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(_friendlyError(error))),
        );
      }
    }
  }

  Future<void> _syncCalendar(ExternalCalendar cal) async {
    if (_syncingIds.contains(cal.id)) return;
    setState(() => _syncingIds.add(cal.id));

    try {
      await widget.hubClient.syncExternalCalendarNow(
        accessToken: widget.accessToken,
        externalCalendarId: cal.id,
      );
      if (mounted) {
        setState(() {
          _syncingIds.remove(cal.id);
          _syncSuccessIds.add(cal.id);
        });
        Future.delayed(const Duration(seconds: 3), () {
          if (mounted) setState(() => _syncSuccessIds.remove(cal.id));
        });
      }
    } catch (error) {
      if (mounted) {
        setState(() => _syncingIds.remove(cal.id));
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(_friendlyError(error))),
        );
      }
    }
  }

  Future<void> _syncAll() async {
    final cals = _calendars?.where((c) => c.syncEnabled).toList();
    if (cals == null || cals.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Turn on at least one calendar before syncing.'),
        ),
      );
      return;
    }
    for (final cal in cals) {
      await _syncCalendar(cal);
    }
  }

  Future<void> _disconnect() async {
    final confirmed = await CaleeDestructiveDialog.show(
      context: context,
      title: 'Disconnect Google Calendar?',
      body:
          'Google events will be removed from Calee, but nothing will be deleted from Google.',
      confirmLabel: 'Disconnect',
    );
    if (!confirmed || !mounted) return;

    try {
      await widget.hubClient.disconnectExternalCalendarConnection(
        accessToken: widget.accessToken,
        connectionId: widget.connection.id,
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Google Calendar disconnected.')),
        );
        Navigator.of(context).popUntil((route) => route.isFirst);
        widget.onViewCalendar();
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(_friendlyError(error))),
        );
      }
    }
  }

  String _friendlyError(Object error) {
    if (error is! CaleeHubException) {
      return 'Something went wrong. Please try again.';
    }
    return switch (error.code) {
      'GOOGLE_REFRESH_FAILED' => 'Google needs to be reconnected.',
      'GOOGLE_EVENTS_FAILED' =>
        'We could not sync Google Calendar right now. Please try again.',
      'GOOGLE_CALENDAR_LIST_FAILED' =>
        'We could not load your Google calendars right now. Please try again.',
      'CALENDAR_NOT_ENABLED' => 'Turn this calendar on before syncing.',
      'CONNECTION_NOT_FOUND' => 'Google connection not found. Please reconnect.',
      'CONNECTION_NOT_ACTIVE' =>
        'Google connection is no longer active. Please reconnect.',
      _ => error.message,
    };
  }

  Color _calendarColor(ExternalCalendar cal) {
    final hex = cal.color;
    if (hex != null && hex.isNotEmpty) {
      final norm = hex.startsWith('#') ? hex : '#$hex';
      final parsed = int.tryParse(norm.replaceFirst('#', '0xFF'));
      if (parsed != null) return Color(parsed);
    }
    return CaleeColors.dotBlue;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final connection = widget.connection;
    final accountLabel =
        connection.externalAccountEmail ?? 'Google Calendar connected';

    return CaleeScaffold(
      appBar: AppBar(title: const Text('Choose Google Calendars')),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _loadError != null
          ? _ErrorBody(
              message: _loadError!,
              onRetry: _load,
            )
          : _buildBody(theme, accountLabel),
    );
  }

  Widget _buildBody(ThemeData theme, String accountLabel) {
    final cals = _calendars ?? [];

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(
        CaleeSpacing.pagePadding,
        CaleeSpacing.md,
        CaleeSpacing.pagePadding,
        96,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Choose which Google calendars to show in Calee.',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: CaleeColors.textSecondary,
            ),
          ),
          const SizedBox(height: CaleeSpacing.xs),
          Text(
            accountLabel,
            style: theme.textTheme.bodySmall?.copyWith(
              color: CaleeColors.textSecondary,
            ),
          ),
          const SizedBox(height: CaleeSpacing.sectionSpacing),
          if (cals.isEmpty)
            Text(
              'No calendars found for this Google account.',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: CaleeColors.textSecondary,
              ),
            )
          else
            CaleeSection(
              children: [
                for (final cal in cals)
                  _CalendarRow(
                    calendar: cal,
                    color: _calendarColor(cal),
                    isSyncing: _syncingIds.contains(cal.id),
                    syncSuccess: _syncSuccessIds.contains(cal.id),
                    onToggle: (v) => _toggleCalendar(cal, v),
                    onSync: () => _syncCalendar(cal),
                  ),
              ],
            ),
          const SizedBox(height: CaleeSpacing.sectionSpacing),
          FilledButton(
            onPressed: _syncAll,
            child: const Text('Sync selected calendars now'),
          ),
          const SizedBox(height: CaleeSpacing.sm),
          OutlinedButton(
            onPressed: widget.onViewCalendar,
            child: const Text('View calendar'),
          ),
          const SizedBox(height: CaleeSpacing.sectionSpacing),
          // ── Connection management ──────────────────────────────────────
          CaleeSection(
            children: [
              _DetailInfoRow(
                label: 'Status',
                value: connection.isActive ? 'Connected' : 'Needs attention',
              ),
              _DetailInfoRow(
                label: 'Account',
                value: connection.externalAccountEmail ?? 'Google Calendar',
              ),
            ],
          ),
          const SizedBox(height: CaleeSpacing.sm),
          TextButton(
            onPressed: _disconnect,
            style: TextButton.styleFrom(
              foregroundColor: CaleeColors.destructive,
            ),
            child: const Text('Disconnect Google Calendar'),
          ),
        ],
      ),
    );
  }
}

class _CalendarRow extends StatelessWidget {
  const _CalendarRow({
    required this.calendar,
    required this.color,
    required this.isSyncing,
    required this.syncSuccess,
    required this.onToggle,
    required this.onSync,
  });

  final ExternalCalendar calendar;
  final Color color;
  final bool isSyncing;
  final bool syncSuccess;
  final void Function(bool) onToggle;
  final VoidCallback onSync;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: CaleeSpacing.md,
        vertical: 8,
      ),
      child: Row(
        children: [
          Container(
            width: 14,
            height: 14,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: CaleeSpacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  calendar.displayName,
                  style: theme.textTheme.bodyMedium,
                ),
                Text(
                  'Read-only from Google',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: CaleeColors.textSecondary,
                  ),
                ),
                if (syncSuccess)
                  Text(
                    'Synced',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: Colors.green,
                    ),
                  ),
              ],
            ),
          ),
          if (calendar.syncEnabled)
            isSyncing
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : IconButton(
                    icon: const Icon(Icons.sync, size: 18),
                    color: CaleeColors.primary,
                    tooltip: 'Sync now',
                    onPressed: onSync,
                  ),
          Switch(
            value: calendar.syncEnabled,
            onChanged: onToggle,
          ),
        ],
      ),
    );
  }
}

class _DetailInfoRow extends StatelessWidget {
  const _DetailInfoRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: CaleeSpacing.md,
        vertical: 11,
      ),
      child: Row(
        children: [
          Text(
            label,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: CaleeColors.textSecondary,
            ),
          ),
          const Spacer(),
          Flexible(
            child: Text(
              value,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: CaleeColors.textPrimary,
              ),
              textAlign: TextAlign.right,
            ),
          ),
        ],
      ),
    );
  }
}

class _ErrorBody extends StatelessWidget {
  const _ErrorBody({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(CaleeSpacing.pagePadding),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              message,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: CaleeColors.textSecondary,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: CaleeSpacing.md),
            FilledButton(onPressed: onRetry, child: const Text('Try again')),
          ],
        ),
      ),
    );
  }
}
