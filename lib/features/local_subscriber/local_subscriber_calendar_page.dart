import 'dart:async';

import 'package:flutter/material.dart';

import '../../ui/calee_design.dart';
import '../calendar/shared/calendar_display_event.dart';
import '../calendar/shared/calendar_display_event_adapters.dart';
import '../calendar/shared/read_only_calendar_view.dart';
import 'local_calendar_event.dart';
import 'local_calendar_ics_service.dart';
import 'local_calendar_subscription.dart';
import 'local_calendar_subscription_repository.dart';

// Palette cycled per subscription (index % length).
const _kSubscriptionColors = [
  CaleeColors.dotBlue,
  CaleeColors.dotGreen,
  CaleeColors.dotOrange,
  CaleeColors.dotPurple,
  CaleeColors.dotPink,
  CaleeColors.dotTeal,
  CaleeColors.dotRed,
];

class LocalSubscriberCalendarPage extends StatefulWidget {
  const LocalSubscriberCalendarPage({
    required this.subscriptions,
    required this.repository,
    required this.onSignIn,
    required this.onSubscriptionsChanged,
    this.icsService,
    super.key,
  });

  final List<LocalCalendarSubscription> subscriptions;
  final LocalCalendarSubscriptionRepository repository;
  final VoidCallback onSignIn;
  final void Function(List<LocalCalendarSubscription>) onSubscriptionsChanged;

  /// Overrideable for tests; defaults to [LocalCalendarIcsService].
  final LocalCalendarIcsService? icsService;

  @override
  State<LocalSubscriberCalendarPage> createState() =>
      _LocalSubscriberCalendarPageState();
}

class _LocalSubscriberCalendarPageState
    extends State<LocalSubscriberCalendarPage> {
  LocalCalendarIcsService get _icsService =>
      widget.icsService ?? const LocalCalendarIcsService();

  List<LocalCalendarSubscription> _subscriptions = [];
  final Map<String, List<LocalCalendarEvent>> _eventsBySubscription = {};
  final Map<String, String?> _errorsBySubscription = {};
  final Set<String> _loadingIds = {};

  late DateTime _today;
  late DateTime _selectedMonth;
  late DateTime _selectedDay;
  CalendarDisplayViewMode _viewMode = CalendarDisplayViewMode.month;

  @override
  void initState() {
    super.initState();
    _today = DateTime.now();
    _selectedMonth = DateTime(_today.year, _today.month);
    _selectedDay = _today;
    _subscriptions = List.of(widget.subscriptions);
    _refreshAll();
  }

  @override
  void didUpdateWidget(LocalSubscriberCalendarPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.subscriptions != widget.subscriptions) {
      _subscriptions = List.of(widget.subscriptions);
      _refreshAll();
    }
  }

  Future<void> _refreshAll() async {
    for (final sub in _subscriptions) {
      unawaited(_refreshOne(sub));
    }
  }

  Future<void> _refreshOne(LocalCalendarSubscription sub) async {
    setState(() {
      _loadingIds.add(sub.id);
      _errorsBySubscription.remove(sub.id);
    });
    try {
      final events = await _icsService.fetchEvents(sub);
      await widget.repository.updateLastFetchedAt(sub.id, DateTime.now());
      if (!mounted) return;
      setState(() {
        _eventsBySubscription[sub.id] = events;
        _loadingIds.remove(sub.id);
      });
    } on LocalCalendarIcsException catch (_) {
      if (!mounted) return;
      setState(() {
        _errorsBySubscription[sub.id] =
            '"${sub.title}" could not be refreshed. Please try again.';
        _loadingIds.remove(sub.id);
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _errorsBySubscription[sub.id] =
            '"${sub.title}" could not be refreshed. Please try again.';
        _loadingIds.remove(sub.id);
      });
    }
  }

  Future<void> _removeSubscription(LocalCalendarSubscription sub) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Remove calendar'),
        content: Text('Remove "${sub.title}" from this phone?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Keep'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    await widget.repository.remove(sub.id);
    final updated = await widget.repository.list();
    if (!mounted) return;

    setState(() {
      _subscriptions = updated;
      _eventsBySubscription.remove(sub.id);
      _errorsBySubscription.remove(sub.id);
      _loadingIds.remove(sub.id);
    });
    widget.onSubscriptionsChanged(updated);
  }

  bool get _isAnyLoading => _loadingIds.isNotEmpty;

  Color _colorForSubscription(int index) =>
      _kSubscriptionColors[index % _kSubscriptionColors.length];

  List<CalendarDisplayEvent> get _displayEvents {
    final all = <CalendarDisplayEvent>[];
    for (var i = 0; i < _subscriptions.length; i++) {
      final sub = _subscriptions[i];
      final color = _colorForSubscription(i);
      final subEvents = _eventsBySubscription[sub.id] ?? [];
      for (final e in subEvents) {
        all.add(
          calendarDisplayEventFromLocalEvent(
            e,
            subscription: sub,
            color: color,
          ),
        );
      }
    }
    return all;
  }

  void _openCalendarsSheet() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: CaleeColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(CaleeRadius.sheet),
        ),
      ),
      builder: (_) => _CalendarsSheet(
        subscriptions: _subscriptions,
        loadingIds: Set.of(_loadingIds),
        errorsBySubscription: Map.of(_errorsBySubscription),
        onRefresh: _refreshOne,
        onRemove: _removeSubscription,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final use24h = MediaQuery.alwaysUse24HourFormatOf(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Calee'),
        actions: [
          if (_isAnyLoading)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16),
              child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            )
          else
            IconButton(
              icon: const Icon(Icons.refresh),
              tooltip: 'Refresh',
              onPressed: _refreshAll,
            ),
        ],
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _LocalSubscriberBanner(onSignIn: widget.onSignIn),
          Expanded(
            child: _subscriptions.isEmpty
                ? _EmptyState()
                : ReadOnlyCalendarView(
                    selectedMonth: _selectedMonth,
                    selectedDay: _selectedDay,
                    today: _today,
                    firstDayOfWeek: 0,
                    events: _displayEvents,
                    viewMode: _viewMode,
                    use24h: use24h,
                    onViewModeChanged: (mode) =>
                        setState(() => _viewMode = mode),
                    onPreviousMonth: () => setState(() {
                      _selectedMonth = DateTime(
                        _selectedMonth.year,
                        _selectedMonth.month - 1,
                      );
                    }),
                    onNextMonth: () => setState(() {
                      _selectedMonth = DateTime(
                        _selectedMonth.year,
                        _selectedMonth.month + 1,
                      );
                    }),
                    onGoToToday: () => setState(() {
                      _today = DateTime.now();
                      _selectedMonth = DateTime(_today.year, _today.month);
                      _selectedDay = _today;
                    }),
                    onSelectDay: (day) => setState(() => _selectedDay = day),
                    actionWidgets: [
                      IconButton(
                        icon: const Icon(Icons.calendar_month_outlined),
                        color: CaleeColors.primary,
                        tooltip: 'Calendars on this phone',
                        onPressed: _openCalendarsSheet,
                      ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}

// ── Banner ────────────────────────────────────────────────────────────────────

class _LocalSubscriberBanner extends StatelessWidget {
  const _LocalSubscriberBanner({required this.onSignIn});

  final VoidCallback onSignIn;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ColoredBox(
      color: theme.colorScheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Added on this phone only',
                    style: theme.textTheme.labelMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  Text(
                    'Read-only public calendar · Sign in to link it to your Calee account and Calee display.',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            FilledButton.tonal(
              onPressed: onSignIn,
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                minimumSize: const Size(0, 36),
              ),
              child: const Text('Sign in'),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Calendars sheet ───────────────────────────────────────────────────────────

class _CalendarsSheet extends StatelessWidget {
  const _CalendarsSheet({
    required this.subscriptions,
    required this.loadingIds,
    required this.errorsBySubscription,
    required this.onRefresh,
    required this.onRemove,
  });

  final List<LocalCalendarSubscription> subscriptions;
  final Set<String> loadingIds;
  final Map<String, String?> errorsBySubscription;
  final void Function(LocalCalendarSubscription) onRefresh;
  final void Function(LocalCalendarSubscription) onRemove;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final errors = errorsBySubscription.values
        .where((e) => e != null)
        .cast<String>()
        .toList();

    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(height: 8),
          Container(
            width: 36,
            height: 4,
            decoration: BoxDecoration(
              color: theme.colorScheme.onSurfaceVariant.withAlpha(
                CaleeAlpha.pct24,
              ),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(height: 12),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 8, 8),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    'Calendars on this phone',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: () => Navigator.of(context).maybePop(),
                ),
              ],
            ),
          ),
          if (errors.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Column(
                children: errors
                    .map(
                      (e) => Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: _ErrorBanner(message: e),
                      ),
                    )
                    .toList(),
              ),
            ),
          ...subscriptions.map(
            (sub) => _SubscriptionTile(
              subscription: sub,
              isLoading: loadingIds.contains(sub.id),
              onRefresh: () => onRefresh(sub),
              onRemove: () => onRemove(sub),
            ),
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }
}

// ── Subscription tile ─────────────────────────────────────────────────────────

class _SubscriptionTile extends StatelessWidget {
  const _SubscriptionTile({
    required this.subscription,
    required this.isLoading,
    required this.onRefresh,
    required this.onRemove,
  });

  final LocalCalendarSubscription subscription;
  final bool isLoading;
  final VoidCallback onRefresh;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListTile(
      leading: Icon(
        Icons.calendar_today_outlined,
        color: theme.colorScheme.primary,
      ),
      title: Text(subscription.title),
      subtitle: Text(
        subscription.source.isNotEmpty ? subscription.source : subscription.url,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.bodySmall,
      ),
      trailing: isLoading
          ? const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : PopupMenuButton<String>(
              onSelected: (value) {
                if (value == 'refresh') onRefresh();
                if (value == 'remove') onRemove();
              },
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'refresh', child: Text('Refresh')),
                PopupMenuItem(value: 'remove', child: Text('Remove')),
              ],
            ),
    );
  }
}

// ── Error banner ──────────────────────────────────────────────────────────────

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.errorContainer,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Icon(Icons.warning_amber_outlined, color: theme.colorScheme.error),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: TextStyle(color: theme.colorScheme.onErrorContainer),
            ),
          ),
        ],
      ),
    );
  }
}

// ── Empty state ───────────────────────────────────────────────────────────────

class _EmptyState extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Text(
          'No calendars added on this phone yet.',
          textAlign: TextAlign.center,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}
