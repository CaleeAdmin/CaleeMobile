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
import 'local_subscriber_promotion_preferences.dart';

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
    required this.onLearnAboutHome,
    required this.onSubscriptionsChanged,
    this.icsService,
    this.promotionPreferences,
    this.openCalendarsSheetOnStart = false,
    this.onCalendarsSheetOpened,
    super.key,
  });

  final List<LocalCalendarSubscription> subscriptions;
  final LocalCalendarSubscriptionRepository repository;

  /// Opens the normal sign-in flow for existing Calee Home customers.
  /// Signing in never migrates, links, or removes the locally stored
  /// calendar subscriptions.
  final VoidCallback onSignIn;

  /// Opens the Calee-for-home marketing page from the inline promotion and
  /// the calendars sheet's discovery row. Must never consume local calendar
  /// state.
  final VoidCallback onLearnAboutHome;

  final void Function(List<LocalCalendarSubscription>) onSubscriptionsChanged;

  /// Overrideable for tests; defaults to [LocalCalendarIcsService].
  final LocalCalendarIcsService? icsService;

  /// Overrideable for tests; defaults to [LocalSubscriberPromotionPreferences].
  final LocalSubscriberPromotionPreferences? promotionPreferences;

  /// Opens the "Calendars on this phone" management sheet as soon as the
  /// page appears. Used by the sixth-calendar limit screen's "Manage my
  /// calendars" action so the user lands directly where a calendar can be
  /// removed to make room.
  final bool openCalendarsSheetOnStart;

  /// Called once [openCalendarsSheetOnStart] has been honoured, so the owner
  /// can clear its one-shot request.
  final VoidCallback? onCalendarsSheetOpened;

  @override
  State<LocalSubscriberCalendarPage> createState() =>
      _LocalSubscriberCalendarPageState();
}

class _LocalSubscriberCalendarPageState
    extends State<LocalSubscriberCalendarPage> {
  LocalCalendarIcsService get _icsService =>
      widget.icsService ?? const LocalCalendarIcsService();

  LocalSubscriberPromotionPreferences get _promotionPreferences =>
      widget.promotionPreferences ??
      const LocalSubscriberPromotionPreferences();

  List<LocalCalendarSubscription> _subscriptions = [];
  final Map<String, List<LocalCalendarEvent>> _eventsBySubscription = {};
  final Map<String, String?> _errorsBySubscription = {};
  final Set<String> _loadingIds = {};

  // Tri-state: null while the saved preference is loading (nothing rendered,
  // so a previously dismissed promotion never flashes in and out), then the
  // persisted dismissal value.
  bool? _inlinePromoDismissed;

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
    unawaited(_loadInlinePromoPreference());
    if (widget.openCalendarsSheetOnStart) {
      // After the first frame so the sheet is presented over a built page.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        widget.onCalendarsSheetOpened?.call();
        unawaited(_openCalendarsSheet());
      });
    }
  }

  Future<void> _loadInlinePromoPreference() async {
    final dismissed = await _promotionPreferences
        .isInlineHomePromotionDismissed();
    if (!mounted) return;
    setState(() => _inlinePromoDismissed = dismissed);
  }

  void _dismissInlineHomePromo() {
    // Hide immediately; persisting is best-effort and never blocks the UI.
    setState(() => _inlinePromoDismissed = true);
    unawaited(_promotionPreferences.dismissInlineHomePromotion());
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

  Future<void> _openCalendarsSheet() async {
    final action = await showModalBottomSheet<_CalendarsSheetAction>(
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
    if (!mounted) return;
    // The sheet dismisses itself before the action runs, so external
    // navigation (and any failure snackbar) happens over the calendar page,
    // never behind a still-open modal.
    if (action == _CalendarsSheetAction.learnAboutHome) {
      widget.onLearnAboutHome();
    }
  }

  @override
  Widget build(BuildContext context) {
    final use24h = MediaQuery.alwaysUse24HourFormatOf(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Calee'),
        actions: [
          // Refresh keeps its slot while calendars load, and the Sign in
          // action stays visible and tappable throughout.
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
          // Existing Calee Home customers sign in here; local calendars are
          // never migrated or linked by signing in.
          Padding(
            padding: const EdgeInsets.only(right: CaleeSpacing.xs),
            child: Tooltip(
              message: 'Sign in to Calee',
              child: TextButton.icon(
                key: const Key('local_calendar_sign_in_button'),
                onPressed: widget.onSignIn,
                icon: const Icon(Icons.login, size: 20),
                label: const Text('Sign in'),
                style: TextButton.styleFrom(
                  minimumSize: const Size(48, 48),
                  padding: const EdgeInsets.symmetric(
                    horizontal: CaleeSpacing.sm,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          // Compact, dismissible Calee-for-home discovery strip. Only ever
          // shown in this signed-out local-calendar mode, and only once the
          // saved preference confirms it was not previously dismissed.
          if (_inlinePromoDismissed == false)
            _InlineHomePromo(
              onTap: widget.onLearnAboutHome,
              onDismiss: _dismissInlineHomePromo,
            ),
          Expanded(
            child: _subscriptions.isEmpty
                ? _EmptyState()
                : _buildCalendar(use24h),
          ),
        ],
      ),
    );
  }

  Widget _buildCalendar(bool use24h) {
    return ReadOnlyCalendarView(
      selectedMonth: _selectedMonth,
      selectedDay: _selectedDay,
      today: _today,
      firstDayOfWeek: 0,
      events: _displayEvents,
      viewMode: _viewMode,
      use24h: use24h,
      onViewModeChanged: (mode) => setState(() => _viewMode = mode),
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
    );
  }
}

// ── Inline Calee-for-home promotion ───────────────────────────────────────────

/// Compact, dismissible discovery strip shown between the app bar and the
/// read-only calendar. Visually secondary to the calendar: no pricing, no
/// feature list, no large sales button. The whole body is one tappable
/// navigation surface; the dismiss control is a separate action that only
/// hides the strip.
class _InlineHomePromo extends StatelessWidget {
  const _InlineHomePromo({required this.onTap, required this.onDismiss});

  final VoidCallback onTap;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    // Secondary chrome: the strip grows with accessibility text (wrapping,
    // never truncating), but its scaling is moderated so enormous text sizes
    // cannot let a promotion crowd the calendar — the page's primary
    // content — off the screen.
    return MediaQuery.withClampedTextScaling(
      maxScaleFactor: 1.6,
      child: Builder(builder: _buildStrip),
    );
  }

  Widget _buildStrip(BuildContext context) {
    final theme = Theme.of(context);
    // The thumbnail is purely decorative (excluded from semantics), so at
    // large text sizes its width is handed back to the wrapping text.
    final showThumbnail = MediaQuery.textScalerOf(context).scale(100) <= 130;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        CaleeSpacing.md,
        CaleeSpacing.sm,
        CaleeSpacing.md,
        CaleeSpacing.sm,
      ),
      child: Material(
        key: const Key('local_calendar_inline_home_promo'),
        color: theme.colorScheme.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(CaleeRadius.card),
          side: BorderSide(color: theme.colorScheme.outlineVariant),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: MergeSemantics(
                child: Semantics(
                  button: true,
                  child: InkWell(
                    borderRadius: const BorderRadius.horizontal(
                      left: Radius.circular(CaleeRadius.card),
                    ),
                    onTap: onTap,
                    child: ConstrainedBox(
                      // Compact by default, but only a minimum: large
                      // accessibility text expands the strip instead of
                      // truncating.
                      constraints: const BoxConstraints(minHeight: 72),
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(
                          CaleeSpacing.md,
                          CaleeSpacing.sm,
                          0,
                          CaleeSpacing.sm,
                        ),
                        child: Row(
                          children: [
                            if (showThumbnail) ...[
                              const CaleeHomeProductThumbnail(),
                              const SizedBox(width: CaleeSpacing.md),
                            ],
                            Expanded(
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    'See this calendar on a family screen',
                                    style: theme.textTheme.bodyMedium?.copyWith(
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    'Discover Calee for your home.',
                                    style: theme.textTheme.bodySmall?.copyWith(
                                      color: theme.colorScheme.onSurfaceVariant,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(width: CaleeSpacing.xs),
                            Icon(
                              Icons.chevron_right,
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            IconButton(
              key: const Key('local_calendar_inline_home_promo_dismiss'),
              icon: const Icon(Icons.close, size: 20),
              color: theme.colorScheme.onSurfaceVariant,
              tooltip: 'Dismiss',
              onPressed: onDismiss,
            ),
          ],
        ),
      ),
    );
  }
}

// ── Calendars sheet ───────────────────────────────────────────────────────────

/// Result of the calendars bottom sheet: an action the owning page performs
/// after the sheet has been dismissed.
enum _CalendarsSheetAction { learnAboutHome }

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
      // Height-bounded: the drag handle and heading stay fixed while the
      // error banners, calendar rows, and the Calee-for-home discovery row
      // scroll — many calendars or large accessibility text can no longer
      // overflow, and a short list still produces a compact sheet.
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.85,
        ),
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
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          'Calendars on this phone',
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 2),
                        // Informational allowance, shown where it is
                        // relevant. Not an upgrade wall: the conversion
                        // experience only appears if a sixth unique calendar
                        // is actually attempted.
                        Text(
                          '${subscriptions.length} of '
                          '$kMaxLocalCalendarSubscriptions calendars',
                          key: const Key('local_calendars_sheet_allowance'),
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.of(context).maybePop(),
                  ),
                ],
              ),
            ),
            Flexible(
              child: ListView(
                key: const Key('local_calendars_sheet_list'),
                shrinkWrap: true,
                children: [
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
                  const Divider(),
                  _HomePromoTile(
                    onTap: () => Navigator.of(
                      context,
                    ).pop(_CalendarsSheetAction.learnAboutHome),
                  ),
                  const SizedBox(height: 8),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Calee-for-home discovery row ──────────────────────────────────────────────

class _HomePromoTile extends StatelessWidget {
  const _HomePromoTile({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListTile(
      key: const Key('local_calendar_home_promo'),
      onTap: onTap,
      minTileHeight: 48,
      leading: const CaleeHomeProductThumbnail(),
      title: const Text('Calee for your home'),
      subtitle: Text(
        'One shared screen for the whole family',
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
      trailing: Icon(
        Icons.chevron_right,
        color: theme.colorScheme.onSurfaceVariant,
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
