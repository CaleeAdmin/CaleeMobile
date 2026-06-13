import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../data/api/calee_hub_client.dart';
import '../../data/auth/calee_preferences.dart';
import '../../data/models/client_bootstrap.dart';
import '../../data/models/client_calendar.dart';
import '../../ui/calee_design.dart';
import '../settings/calendar_collections_page.dart';
import 'calendar_controller.dart';
import 'calendar_repository.dart';
import 'widgets/calendar_chooser_sheet.dart';
import 'widgets/calendar_day_cell.dart';
import 'widgets/calendar_error_state.dart';
import 'widgets/calendar_event_row.dart';
import 'widgets/calendar_search_sheet.dart';
import 'widgets/calendar_widget_helpers.dart';
import 'widgets/create_event_sheet.dart';

// ─── Label helpers ────────────────────────────────────────────────────────────

const _kMonthNames = [
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

const _kDayAbbr = ['S', 'M', 'T', 'W', 'T', 'F', 'S'];

const _kFullDayNames = [
  'Sunday',
  'Monday',
  'Tuesday',
  'Wednesday',
  'Thursday',
  'Friday',
  'Saturday',
];

String _monthYearLabel(DateTime d) => '${_kMonthNames[d.month - 1]} ${d.year}';

// ─── View mode ────────────────────────────────────────────────────────────────

enum _CalendarViewMode { month, agenda }

// ─── Page ─────────────────────────────────────────────────────────────────────

class CalendarPage extends StatefulWidget {
  const CalendarPage({
    required this.hubClient,
    required this.accessToken,
    required this.services,
    super.key,
  });

  final CaleeHubClient hubClient;
  final String accessToken;
  final List<ClientService> services;

  @override
  State<CalendarPage> createState() => _CalendarPageState();
}

class _CalendarPageState extends State<CalendarPage> {
  // ── Controller / search ───────────────────────────────────────────────────

  late CalendarController _controller;
  final TextEditingController _searchController = TextEditingController();
  _CalendarViewMode _viewMode = _CalendarViewMode.month;

  @override
  void initState() {
    super.initState();
    final repository = CalendarRepository(
      hubClient: widget.hubClient,
      accessToken: widget.accessToken,
      preferences: CaleePreferences(),
    );
    _controller = CalendarController(repository: repository);
    _controller.loadMonth();
  }

  @override
  void dispose() {
    _controller.dispose();
    _searchController.dispose();
    super.dispose();
  }

  // ── CRUD shortcuts ────────────────────────────────────────────────────────

  void _openCollectionCreateShortcut() {
    _openCalendarCollectionsShortcut(autoOpenCreate: true);
  }

  void _openCollectionSubscribeShortcut() {
    _openCalendarCollectionsShortcut(autoOpenSubscribe: true);
  }

  void _openCalendarCollectionsShortcut({
    bool autoOpenCreate = false,
    bool autoOpenSubscribe = false,
  }) {
    Navigator.of(context)
        .push(
          MaterialPageRoute<void>(
            builder: (_) => CalendarCollectionsPage(
              hubClient: widget.hubClient,
              accessToken: widget.accessToken,
              services: widget.services,
              initialCreateKind: autoOpenCreate ? 'calendar' : null,
              autoOpenCreate: autoOpenCreate,
              autoOpenSubscribe: autoOpenSubscribe,
            ),
          ),
        )
        .then((_) {
          if (mounted) _controller.refresh();
        });
  }

  // ── Calendar visibility ────────────────────────────────────────────────────

  void _openCalendarChooser() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: CaleeColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(CaleeRadius.sheet),
        ),
      ),
      builder: (_) => CalendarChooserSheet(
        calendars: _controller.calendars,
        initialHiddenIds: Set.from(_controller.hiddenCalendarIds),
        hubClient: widget.hubClient,
        accessToken: widget.accessToken,
        onToggle: _controller.toggleCalendarVisibility,
        onShowAll: _controller.showAllCalendars,
        onNewCalendar: _openCollectionCreateShortcut,
        onSubscribeFromLink: _openCollectionSubscribeShortcut,
        onCalendarMutated: (String? message) {
          _controller.refresh();
          if (message != null && mounted) {
            ScaffoldMessenger.of(
              context,
            ).showSnackBar(SnackBar(content: Text(message)));
          }
        },
      ),
    );
  }

  // ── Create event ──────────────────────────────────────────────────────────

  Future<void> _openCreateEventSheet() async {
    final writableCalendars = _controller.calendars
        .where((c) => !c.readOnly)
        .toList();

    if (writableCalendars.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('No writable calendar is available.'),
          action: SnackBarAction(
            label: 'Create',
            onPressed: _openCollectionCreateShortcut,
          ),
        ),
      );
      return;
    }

    final created = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: CaleeColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(CaleeRadius.sheet),
        ),
      ),
      builder: (context) => CreateEventSheet(
        calendars: writableCalendars,
        initialDate: _controller.selectedDay,
        defaultCalendarId: _controller.preferences.defaultCalendarId,
        onCreate: _controller.createEvent,
      ),
    );

    if (created == true && mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Event created.')));
    }
  }

  // ── Edit / delete event ───────────────────────────────────────────────────

  void _openEventActions(ClientEvent event) {
    final calendar = _controller.calendarForEvent(event);
    final canWrite = calendar != null && !calendar.readOnly;

    if (!canWrite) {
      CaleeActionSheet.show(
        context: context,
        title: event.recurring
            ? 'This recurring event is from a read-only calendar.\nYou can view it, but changes must be made in the original calendar.'
            : 'This event is from a read-only calendar.\nYou can view it, but changes must be made in the original calendar.',
        actions: const [],
      );
      return;
    }

    final writeableCalendar = calendar;

    CaleeActionSheet.show(
      context: context,
      title: event.title,
      actions: [
        CaleeAction(
          label: event.recurring ? 'Edit…' : 'Edit Event',
          icon: Icons.edit_outlined,
          onTap: () async {
            final editScope = await _chooseEditScope(event);
            if (editScope == null || !mounted) return;
            await _openEditEventSheet(
              event,
              writeableCalendar,
              editScope: editScope,
            );
          },
        ),
        CaleeAction(
          label: event.recurring ? 'Delete…' : 'Delete Event',
          icon: Icons.delete_outline,
          isDestructive: true,
          onTap: () => _confirmDeleteEvent(event),
        ),
      ],
    );
  }

  Future<String?> _chooseEditScope(ClientEvent event) async {
    if (!event.recurring) return 'series';

    final result = Completer<String?>();
    await CaleeActionSheet.show(
      context: context,
      title: 'This is a repeating event.',
      actions: [
        CaleeAction(
          label: 'Edit This Event',
          icon: Icons.edit_outlined,
          onTap: () => result.complete('occurrence'),
        ),
        CaleeAction(
          label: 'Edit Entire Series',
          icon: Icons.edit_outlined,
          onTap: () => result.complete('series'),
        ),
      ],
    );
    if (!result.isCompleted) result.complete(null);
    return result.future;
  }

  Future<String?> _chooseDeleteScope() async {
    final result = Completer<String?>();
    await CaleeActionSheet.show(
      context: context,
      title:
          'This is a repeating event. Choose whether to remove only this event or the entire series.',
      actions: [
        CaleeAction(
          label: 'Delete This Event',
          icon: Icons.delete_outline,
          isDestructive: true,
          onTap: () => result.complete('occurrence'),
        ),
        CaleeAction(
          label: 'Delete Entire Series',
          icon: Icons.delete_outline,
          isDestructive: true,
          onTap: () => result.complete('series'),
        ),
      ],
    );
    if (!result.isCompleted) result.complete(null);
    return result.future;
  }

  Future<void> _openEditEventSheet(
    ClientEvent event,
    ClientCalendar calendar, {
    String? editScope,
  }) async {
    final updated = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: CaleeColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(CaleeRadius.sheet),
        ),
      ),
      builder: (context) => CreateEventSheet(
        calendars: [calendar],
        initialEvent: event,
        editScope: editScope,
        onCreate: _controller.createEvent,
        onUpdate: _controller.updateEvent,
      ),
    );

    if (updated == true && mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Event updated.')));
    }
  }

  Future<void> _confirmDeleteEvent(ClientEvent event) async {
    String? deleteScope;

    if (!event.recurring) {
      final confirmed = await CaleeDestructiveDialog.show(
        context: context,
        title: 'Delete event?',
        body: 'Delete "${event.title}"? This cannot be undone.',
        confirmLabel: 'Delete',
      );
      if (!confirmed || !mounted) return;
      deleteScope = 'series';
    } else {
      deleteScope = await _chooseDeleteScope();
      if (deleteScope == null || !mounted) return;
    }

    final deleteOccurrence = event.recurring && deleteScope == 'occurrence';

    try {
      await _controller.deleteEvent(event: event, deleteScope: deleteScope);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              deleteOccurrence
                  ? 'Recurring event deleted.'
                  : event.recurring
                  ? 'Recurring series deleted.'
                  : 'Event deleted.',
            ),
          ),
        );
      }
    } catch (error) {
      if (mounted) {
        final friendly = deleteOccurrence
            ? 'Unable to delete recurring event.'
            : event.recurring
            ? 'Unable to delete recurring series.'
            : 'Unable to delete event.';
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              kDebugMode && error is CaleeHubException
                  ? '$friendly\nDebug: ${error.debugSummary}'
                  : friendly,
            ),
          ),
        );
      }
    }
  }

  // ── Helpers ────────────────────────────────────────────────────────────────

  Color _eventColor(ClientEvent event) {
    final cal = _controller.calendarForEvent(event);
    if (cal?.color != null) {
      final parsed = parseCalendarHexColor(cal!.color!);
      if (parsed != null) return parsed;
    }
    return CaleeColors.dotBlue;
  }

  String _agendaDateLabel(DateTime day) {
    if (isSameCalendarDay(day, _controller.today)) return 'Today';
    final weekday = _kFullDayNames[day.weekday % 7]; // Sun=0
    return '$weekday ${day.day} ${_kMonthNames[day.month - 1]}';
  }

  bool _use24h(BuildContext context) =>
      switch (_controller.preferences.timeFormat) {
        TimeFormatPref.h24 => true,
        TimeFormatPref.h12 => false,
        TimeFormatPref.system => MediaQuery.alwaysUse24HourFormatOf(context),
      };

  // ── Search ─────────────────────────────────────────────────────────────────

  String _calendarNameForEvent(ClientEvent event) {
    return _controller.calendarForEvent(event)?.name ?? '';
  }

  void _openSearchSheet() {
    _searchController.clear();
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: CaleeColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(CaleeRadius.sheet),
        ),
      ),
      builder: (sheetContext) => CalendarSearchSheet(
        searchController: _searchController,
        searchEvents: _controller.searchEvents,
        calendarNameForEvent: _calendarNameForEvent,
        eventColor: _eventColor,
        use24h: _use24h(context),
        onResultTap: (event) {
          Navigator.of(sheetContext).pop();
          _controller.selectSearchResult(event);
        },
      ),
    );
  }

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        if (_controller.isLoading &&
            _controller.calendars.isEmpty &&
            _controller.events.isEmpty) {
          return CaleeScaffold(
            body: const Center(child: CircularProgressIndicator()),
          );
        }

        if (_controller.error != null &&
            _controller.calendars.isEmpty &&
            _controller.events.isEmpty) {
          return CaleeScaffold(
            body: CalendarErrorState(onRetry: _controller.refresh),
          );
        }

        final screenHeight = MediaQuery.sizeOf(context).height;
        final compactHeight = screenHeight < 520;
        final veryCompactHeight = screenHeight < 430;

        return CaleeScaffold(
          body: SafeArea(
            child: Column(
              children: [
                _buildTopBar(
                  compactHeight: compactHeight,
                  veryCompactHeight: veryCompactHeight,
                ),
                _buildViewSwitcher(),
                if (_viewMode == _CalendarViewMode.month) ...[
                  _buildWeekdayHeader(compactHeight: compactHeight),
                  Flexible(
                    fit: FlexFit.loose,
                    child: _buildMonthGrid(
                      compactHeight: compactHeight,
                      veryCompactHeight: veryCompactHeight,
                    ),
                  ),
                  const Divider(height: 1),
                  Expanded(
                    child: RefreshIndicator(
                      onRefresh: _controller.refresh,
                      child: ListView(
                        padding: EdgeInsets.zero,
                        children: _buildAgendaItems(),
                      ),
                    ),
                  ),
                ] else ...[
                  Expanded(
                    child: RefreshIndicator(
                      onRefresh: _controller.refresh,
                      child: _buildAgendaMonthView(),
                    ),
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildViewSwitcher() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        CaleeSpacing.md,
        0,
        CaleeSpacing.md,
        CaleeSpacing.xs,
      ),
      child: SegmentedButton<_CalendarViewMode>(
        segments: const [
          ButtonSegment(
            value: _CalendarViewMode.month,
            label: Text('Month'),
          ),
          ButtonSegment(
            value: _CalendarViewMode.agenda,
            label: Text('Agenda'),
          ),
        ],
        selected: {_viewMode},
        onSelectionChanged: (selected) =>
            setState(() => _viewMode = selected.first),
        style: ButtonStyle(
          visualDensity: VisualDensity.compact,
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
      ),
    );
  }

  Widget _buildAgendaMonthView() {
    final use24h = _use24h(context);
    final month = _controller.selectedMonth;
    final daysInMonth = DateUtils.getDaysInMonth(month.year, month.month);

    final dayWidgets = <Widget>[];
    var hasAnyEvent = false;

    for (var d = 1; d <= daysInMonth; d++) {
      final day = DateTime(month.year, month.month, d);
      final dayEvents = _controller.eventsForDay(day);
      if (dayEvents.isEmpty) continue;

      hasAnyEvent = true;
      final allDay = dayEvents.where((e) => e.allDay).toList();
      final timed = dayEvents.where((e) => !e.allDay).toList();

      dayWidgets.add(
        Padding(
          padding: const EdgeInsets.fromLTRB(
            CaleeSpacing.md,
            CaleeSpacing.md,
            CaleeSpacing.md,
            2,
          ),
          child: Text(
            _agendaDateLabel(day),
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: isSameCalendarDay(day, _controller.today)
                  ? CaleeColors.primary
                  : CaleeColors.textSecondary,
              letterSpacing: 0.2,
            ),
          ),
        ),
      );

      for (final event in [...allDay, ...timed]) {
        dayWidgets.add(
          CalendarAgendaEventRow(
            event: event,
            color: _eventColor(event),
            calendarName: _controller.calendarForEvent(event)?.name,
            hideTime: event.allDay,
            use24h: use24h,
            onTap: () => _openEventActions(event),
          ),
        );
      }
    }

    if (!hasAnyEvent) {
      return ListView(
        padding: const EdgeInsets.symmetric(vertical: CaleeSpacing.xl),
        children: [
          Center(
            child: Text(
              'No events this month',
              style: TextStyle(fontSize: 15, color: CaleeColors.textTertiary),
            ),
          ),
        ],
      );
    }

    dayWidgets.add(const SizedBox(height: CaleeSpacing.xl));
    return ListView(padding: EdgeInsets.zero, children: dayWidgets);
  }

  Widget _buildTopBar({
    bool compactHeight = false,
    bool veryCompactHeight = false,
  }) {
    final outerPad = veryCompactHeight
        ? 2.0
        : compactHeight
        ? 4.0
        : CaleeSpacing.xs;
    final navIconMinH = compactHeight ? 36.0 : 44.0;
    final actionIconMinH = compactHeight ? 32.0 : 36.0;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Row 1: month navigation
        Padding(
          padding: EdgeInsets.fromLTRB(
            CaleeSpacing.xs,
            outerPad,
            CaleeSpacing.xs,
            0,
          ),
          child: Row(
            children: [
              IconButton(
                onPressed: _controller.previousMonth,
                icon: const Icon(Icons.chevron_left),
                iconSize: 24,
                padding: EdgeInsets.zero,
                constraints: BoxConstraints(
                  minWidth: 44,
                  minHeight: navIconMinH,
                ),
                color: CaleeColors.primary,
                tooltip: 'Previous month',
              ),
              Expanded(
                child: Text(
                  _monthYearLabel(_controller.selectedMonth),
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w600,
                    color: CaleeColors.textPrimary,
                  ),
                ),
              ),
              IconButton(
                onPressed: _controller.nextMonth,
                icon: const Icon(Icons.chevron_right),
                iconSize: 24,
                padding: EdgeInsets.zero,
                constraints: BoxConstraints(
                  minWidth: 44,
                  minHeight: navIconMinH,
                ),
                color: CaleeColors.primary,
                tooltip: 'Next month',
              ),
            ],
          ),
        ),
        // Row 2: Today + action icons
        Padding(
          padding: EdgeInsets.fromLTRB(
            CaleeSpacing.sm,
            0,
            CaleeSpacing.xs,
            outerPad,
          ),
          child: Row(
            children: [
              Tooltip(
                message: 'Go to today',
                child: TextButton(
                  onPressed: _controller.goToToday,
                  style: TextButton.styleFrom(
                    foregroundColor: CaleeColors.primary,
                    padding: const EdgeInsets.symmetric(
                      horizontal: CaleeSpacing.sm,
                      vertical: CaleeSpacing.xs,
                    ),
                    minimumSize: Size(44, actionIconMinH),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  child: const Text(
                    'Today',
                    style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
                  ),
                ),
              ),
              const Spacer(),
              IconButton(
                onPressed: _openSearchSheet,
                icon: const Icon(Icons.search),
                iconSize: 22,
                padding: EdgeInsets.zero,
                constraints: BoxConstraints(
                  minWidth: 44,
                  minHeight: actionIconMinH,
                ),
                color: CaleeColors.primary,
                tooltip: 'Search events',
              ),
              IconButton(
                onPressed: _openCalendarChooser,
                icon: const Icon(Icons.tune),
                iconSize: 22,
                padding: EdgeInsets.zero,
                constraints: BoxConstraints(
                  minWidth: 44,
                  minHeight: actionIconMinH,
                ),
                color: CaleeColors.primary,
                tooltip: 'Calendars',
              ),
              IconButton(
                onPressed: _openCreateEventSheet,
                icon: const Icon(Icons.add),
                iconSize: 22,
                padding: EdgeInsets.zero,
                constraints: BoxConstraints(
                  minWidth: 44,
                  minHeight: actionIconMinH,
                ),
                color: CaleeColors.primary,
                tooltip: 'Add event',
              ),
            ],
          ),
        ),
      ],
    );
  }

  List<String> get _weekdayAbbr {
    if (_controller.preferences.firstDayOfWeek == FirstDayOfWeek.monday) {
      return const ['M', 'T', 'W', 'T', 'F', 'S', 'S'];
    }
    return _kDayAbbr;
  }

  Widget _buildWeekdayHeader({bool compactHeight = false}) {
    final vertPad = compactHeight ? 1.0 : 2.0;
    final fontSize = compactHeight ? 11.0 : 12.0;

    return Padding(
      padding: EdgeInsets.symmetric(
        horizontal: CaleeSpacing.xs,
        vertical: vertPad,
      ),
      child: Row(
        children: _weekdayAbbr
            .map(
              (d) => Expanded(
                child: Center(
                  child: Text(
                    d,
                    style: TextStyle(
                      fontSize: fontSize,
                      fontWeight: FontWeight.w500,
                      color: CaleeColors.textSecondary,
                    ),
                  ),
                ),
              ),
            )
            .toList(),
      ),
    );
  }

  Widget _buildMonthGrid({
    bool compactHeight = false,
    bool veryCompactHeight = false,
  }) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final cellSize = constraints.maxWidth / 7;
        final desiredHeight = cellSize * 6;
        final height = constraints.hasBoundedHeight
            ? desiredHeight.clamp(0.0, constraints.maxHeight)
            : desiredHeight;
        return SizedBox(
          height: height,
          child: GridView.builder(
            physics: const NeverScrollableScrollPhysics(),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 7,
            ),
            itemCount: 42,
            itemBuilder: (context, index) {
              final date = _controller.gridStart.add(Duration(days: index));
              final dayEvents = _controller.eventsForDay(date);
              final dotColors = dayEvents.take(3).map(_eventColor).toList();
              return CalendarDayCell(
                date: date,
                isCurrentMonth: date.month == _controller.selectedMonth.month,
                isToday: isSameCalendarDay(date, _controller.today),
                isSelected: isSameCalendarDay(date, _controller.selectedDay),
                dotColors: dotColors,
                eventCount: dayEvents.length,
                compactHeight: compactHeight,
                veryCompactHeight: veryCompactHeight,
                onTap: () => _controller.selectDay(date),
              );
            },
          ),
        );
      },
    );
  }

  Widget _buildAgendaSectionHeading(String label) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        CaleeSpacing.md,
        CaleeSpacing.sm,
        CaleeSpacing.md,
        2,
      ),
      child: Text(
        label,
        style: const TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: CaleeColors.textSecondary,
          letterSpacing: 0.4,
        ),
      ),
    );
  }

  List<Widget> _buildAgendaItems() {
    final items = <Widget>[];
    final use24h = _use24h(context);

    // Date header
    items.add(
      Padding(
        padding: const EdgeInsets.fromLTRB(
          CaleeSpacing.md,
          CaleeSpacing.md,
          CaleeSpacing.md,
          CaleeSpacing.xs,
        ),
        child: Text(
          _agendaDateLabel(_controller.selectedDay),
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: isSameCalendarDay(_controller.selectedDay, _controller.today)
                ? CaleeColors.primary
                : CaleeColors.textSecondary,
            letterSpacing: 0.2,
          ),
        ),
      ),
    );

    final dayEvents = _controller.eventsForDay(_controller.selectedDay);
    final allDayEvents = dayEvents.where((e) => e.allDay).toList();
    final timedEvents = dayEvents.where((e) => !e.allDay).toList();

    if (dayEvents.isEmpty) {
      items.add(
        Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: CaleeSpacing.md,
            vertical: CaleeSpacing.lg,
          ),
          child: Center(
            child: Text(
              'No events this day',
              style: TextStyle(fontSize: 15, color: CaleeColors.textTertiary),
            ),
          ),
        ),
      );
    } else {
      if (allDayEvents.isNotEmpty) {
        items.add(_buildAgendaSectionHeading('All-day'));
        for (final event in allDayEvents) {
          items.add(
            CalendarAgendaEventRow(
              event: event,
              color: _eventColor(event),
              calendarName: _controller.calendarForEvent(event)?.name,
              hideTime: true,
              use24h: use24h,
              onTap: () => _openEventActions(event),
            ),
          );
        }
      }

      if (timedEvents.isNotEmpty) {
        items.add(_buildAgendaSectionHeading('Events'));
        for (final event in timedEvents) {
          items.add(
            CalendarAgendaEventRow(
              event: event,
              color: _eventColor(event),
              calendarName: _controller.calendarForEvent(event)?.name,
              use24h: use24h,
              onTap: () => _openEventActions(event),
            ),
          );
        }
      }
    }

    // Bottom padding so content isn't cut off
    items.add(const SizedBox(height: CaleeSpacing.xl));

    return items;
  }
}
