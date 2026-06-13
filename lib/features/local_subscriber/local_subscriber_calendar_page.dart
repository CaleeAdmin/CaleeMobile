import 'dart:async';

import 'package:flutter/material.dart';

import 'local_calendar_event.dart';
import 'local_calendar_ics_service.dart';
import 'local_calendar_subscription.dart';
import 'local_calendar_subscription_repository.dart';

class LocalSubscriberCalendarPage extends StatefulWidget {
  const LocalSubscriberCalendarPage({
    required this.subscriptions,
    required this.repository,
    required this.onSignIn,
    required this.onSubscriptionsChanged,
    super.key,
  });

  final List<LocalCalendarSubscription> subscriptions;
  final LocalCalendarSubscriptionRepository repository;
  final VoidCallback onSignIn;
  final void Function(List<LocalCalendarSubscription>) onSubscriptionsChanged;

  @override
  State<LocalSubscriberCalendarPage> createState() =>
      _LocalSubscriberCalendarPageState();
}

class _LocalSubscriberCalendarPageState
    extends State<LocalSubscriberCalendarPage> {
  final _icsService = const LocalCalendarIcsService();

  List<LocalCalendarSubscription> _subscriptions = [];
  final Map<String, List<LocalCalendarEvent>> _eventsBySubscription = {};
  final Map<String, String?> _errorsBySubscription = {};
  final Set<String> _loadingIds = {};

  @override
  void initState() {
    super.initState();
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
    } on LocalCalendarIcsException catch (e) {
      if (!mounted) return;
      setState(() {
        _errorsBySubscription[sub.id] = e.message;
        _loadingIds.remove(sub.id);
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _errorsBySubscription[sub.id] =
            'Unable to refresh this calendar. Please try again.';
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

  List<LocalCalendarEvent> get _allEvents {
    final all = <LocalCalendarEvent>[];
    for (final sub in _subscriptions) {
      all.addAll(_eventsBySubscription[sub.id] ?? []);
    }
    all.sort((a, b) => a.start.compareTo(b.start));
    return all;
  }

  bool get _isAnyLoading => _loadingIds.isNotEmpty;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

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
                : _buildContent(theme),
          ),
        ],
      ),
    );
  }

  Widget _buildContent(ThemeData theme) {
    final events = _allEvents;
    final errors = _errorsBySubscription.values
        .where((e) => e != null)
        .cast<String>()
        .toList();

    return CustomScrollView(
      slivers: [
        if (errors.isNotEmpty)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
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
          ),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Text(
              'Followed calendars',
              style: theme.textTheme.titleSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ),
        SliverList.builder(
          itemCount: _subscriptions.length,
          itemBuilder: (_, i) => _SubscriptionTile(
            subscription: _subscriptions[i],
            isLoading: _loadingIds.contains(_subscriptions[i].id),
            onRefresh: () => _refreshOne(_subscriptions[i]),
            onRemove: () => _removeSubscription(_subscriptions[i]),
          ),
        ),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
            child: Text(
              'Upcoming events',
              style: theme.textTheme.titleSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ),
        if (events.isEmpty && !_isAnyLoading)
          const SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Text('No upcoming events found.'),
            ),
          )
        else
          SliverList.builder(
            itemCount: events.length,
            itemBuilder: (_, i) => _EventTile(event: events[i]),
          ),
        const SliverToBoxAdapter(child: SizedBox(height: 24)),
      ],
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
                    'Saved on this phone only',
                    style: theme.textTheme.labelMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  Text(
                    'Read-only public calendar · Sign in to sync with your Calee account and Calee Tablet.',
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

// ── Event tile ────────────────────────────────────────────────────────────────

class _EventTile extends StatelessWidget {
  const _EventTile({required this.event});

  final LocalCalendarEvent event;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListTile(
      leading: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            _monthDay(event.start),
            style: theme.textTheme.labelLarge?.copyWith(
              color: theme.colorScheme.primary,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
      title: Text(event.title),
      subtitle: Text(
        event.isAllDay
            ? '${event.subscriptionTitle} · All day'
            : '${event.subscriptionTitle} · ${_timeRange(event.start, event.end)}',
        style: theme.textTheme.bodySmall,
      ),
    );
  }

  String _monthDay(DateTime dt) {
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    return '${months[dt.month - 1]} ${dt.day}';
  }

  String _timeRange(DateTime start, DateTime? end) {
    String fmt(DateTime dt) {
      final h = dt.hour;
      final m = dt.minute;
      final ampm = h < 12 ? 'am' : 'pm';
      final h12 = h % 12 == 0 ? 12 : h % 12;
      return m == 0 ? '$h12$ampm' : '$h12:${m.toString().padLeft(2, '0')}$ampm';
    }

    if (end == null) return fmt(start);
    return '${fmt(start)} – ${fmt(end)}';
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
          'No followed calendars yet.',
          textAlign: TextAlign.center,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}

