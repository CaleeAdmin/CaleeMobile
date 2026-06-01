import 'package:flutter/material.dart';

import '../../data/api/calee_hub_client.dart';
import '../../data/models/client_bootstrap.dart';
import '../../data/models/client_calendar.dart';
import '../../ui/calee_design.dart';
import '../settings/calendar_collections_page.dart';

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

bool _isSameDay(DateTime a, DateTime b) =>
    a.year == b.year && a.month == b.month && a.day == b.day;

String _eventTimeLabel(ClientEvent event) {
  final start = DateTime.tryParse(event.startsAt)?.toLocal();
  if (start == null) return event.allDay ? 'All day' : '';
  if (event.allDay) return 'All day';
  final h = start.hour.toString().padLeft(2, '0');
  final m = start.minute.toString().padLeft(2, '0');
  return '$h:$m';
}

Color? _parseHexColor(String hex) {
  final clean = hex.startsWith('#') ? hex.substring(1) : hex;
  if (clean.length == 6) {
    final value = int.tryParse(clean, radix: 16);
    if (value != null) return Color(0xFF000000 | value);
  }
  if (clean.length == 8) {
    final value = int.tryParse(clean, radix: 16);
    if (value != null) return Color(value);
  }
  return null;
}

String? _subscriptionHost(String? url) {
  if (url == null || url.isEmpty) return null;
  final host = Uri.tryParse(url)?.host;
  return (host == null || host.isEmpty) ? null : host;
}

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
  // ── State ──────────────────────────────────────────────────────────────────

  late DateTime _today;
  late DateTime _selectedMonth; // always the 1st of the displayed month
  late DateTime _selectedDay;

  List<ClientCalendar> _calendars = [];
  List<ClientEvent> _events = [];
  bool _loading = false;
  Object? _error;
  final Set<String> _hiddenCalendarIds = {};

  // Grid start: first Sunday on or before the first of _selectedMonth
  late DateTime _gridStart;

  // ── Lifecycle ──────────────────────────────────────────────────────────────

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _today = DateTime(now.year, now.month, now.day);
    _selectedDay = _today;
    _selectedMonth = DateTime(now.year, now.month, 1);
    _gridStart = _computeGridStart(_selectedMonth);
    _loadMonth();
  }

  // ── Data loading ───────────────────────────────────────────────────────────

  static DateTime _computeGridStart(DateTime firstOfMonth) {
    // weekday: Mon=1 … Sun=7 → Sunday-first offset: (weekday % 7) gives Sun=0
    final offset = firstOfMonth.weekday % 7;
    return firstOfMonth.subtract(Duration(days: offset));
  }

  Future<void> _loadMonth() async {
    final gridStart = _computeGridStart(_selectedMonth);
    final gridEnd = gridStart.add(const Duration(days: 41)); // 6 weeks − 1 day

    setState(() {
      _gridStart = gridStart;
      _loading = true;
      _error = null;
    });

    try {
      final results = await Future.wait([
        widget.hubClient.calendars(accessToken: widget.accessToken),
        widget.hubClient.events(
          accessToken: widget.accessToken,
          from: _formatDate(gridStart),
          to: _formatDate(gridEnd),
        ),
      ]);

      if (!mounted) return;

      setState(() {
        _calendars = (results[0] as ClientCalendarList)
            .calendars
            .where((c) => c.isCalendarKind)
            .toList();
        _events = (results[1] as ClientEventList).events;
        _loading = false;
        // Remove stale hidden IDs for deleted/unsubscribed calendars
        _hiddenCalendarIds.removeWhere(
          (id) => !_calendars.any((cal) => cal.id == id),
        );
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e;
        _loading = false;
      });
    }
  }

  // ── Month navigation ───────────────────────────────────────────────────────

  void _goToToday() {
    final now = DateTime.now();
    final newToday = DateTime(now.year, now.month, now.day);
    final newMonth = DateTime(now.year, now.month, 1);
    final sameMonth = newMonth.year == _selectedMonth.year &&
        newMonth.month == _selectedMonth.month;
    setState(() {
      _today = newToday;
      _selectedDay = newToday;
      _selectedMonth = newMonth;
    });
    if (!sameMonth) {
      _loadMonth();
    }
  }

  void _prevMonth() {
    final newMonth = DateTime(_selectedMonth.year, _selectedMonth.month - 1, 1);
    setState(() {
      _selectedMonth = newMonth;
      if (_selectedDay.year != newMonth.year ||
          _selectedDay.month != newMonth.month) {
        _selectedDay = newMonth;
      }
    });
    _loadMonth();
  }

  void _nextMonth() {
    final newMonth = DateTime(_selectedMonth.year, _selectedMonth.month + 1, 1);
    setState(() {
      _selectedMonth = newMonth;
      if (_selectedDay.year != newMonth.year ||
          _selectedDay.month != newMonth.month) {
        _selectedDay = newMonth;
      }
    });
    _loadMonth();
  }

  // ── CRUD (preserved) ───────────────────────────────────────────────────────

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
      if (mounted) _loadMonth();
    });
  }

  // ── Calendar visibility ────────────────────────────────────────────────────

  bool _isCalendarVisible(String calendarId) =>
      !_hiddenCalendarIds.contains(calendarId);

  void _toggleCalendarVisibility(String calendarId) {
    setState(() {
      if (_hiddenCalendarIds.contains(calendarId)) {
        _hiddenCalendarIds.remove(calendarId);
      } else {
        _hiddenCalendarIds.add(calendarId);
      }
    });
  }

  void _showAllCalendars() => setState(() => _hiddenCalendarIds.clear());

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
      builder: (_) => _CalendarChooserSheet(
        calendars: _calendars,
        initialHiddenIds: Set.from(_hiddenCalendarIds),
        hubClient: widget.hubClient,
        accessToken: widget.accessToken,
        onToggle: _toggleCalendarVisibility,
        onShowAll: _showAllCalendars,
        onNewCalendar: _openCollectionCreateShortcut,
        onSubscribeFromLink: _openCollectionSubscribeShortcut,
        onCalendarMutated: (String? message) {
          _loadMonth();
          if (message != null && mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text(message)),
            );
          }
        },
      ),
    );
  }

  Future<void> _openCreateEventSheet() async {
    final writableCalendars = _calendars.where((c) => !c.readOnly).toList();

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
      builder: (context) => _CreateEventSheet(
        calendars: writableCalendars,
        initialDate: _selectedDay,
        onCreate: _createEvent,
      ),
    );

    if (created == true && mounted) {
      _loadMonth();
    }
  }

  ClientCalendar? _calendarForEvent(ClientEvent event) {
    for (final calendar in _calendars) {
      if (calendar.id == event.calendarId ||
          calendar.id.endsWith(':${event.calendarId}') ||
          event.calendarId.endsWith(':${calendar.id}')) {
        return calendar;
      }
    }
    return null;
  }

  void _openEventActions(ClientEvent event) {
    final calendar = _calendarForEvent(event);
    final canWrite = calendar != null && !calendar.readOnly;

    if (!canWrite) {
      CaleeActionSheet.show(
        context: context,
        title: event.recurring
            ? 'This recurring event is from a read-only calendar.'
            : 'This event is from a read-only calendar.',
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
          label: event.recurring ? 'Edit series' : 'Edit event',
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
          label: event.recurring ? 'Delete series' : 'Delete event',
          icon: Icons.delete_outline,
          isDestructive: true,
          onTap: () => _confirmDeleteEvent(event),
        ),
      ],
    );
  }

  Future<String?> _chooseEditScope(ClientEvent event) async {
    if (!event.recurring) return 'series';

    return showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Edit recurring event?'),
        content: Text(
          'Edit only this event, or edit "${event.title}" and the entire recurring series?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(null),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop('occurrence'),
            child: const Text('Edit this event'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop('series'),
            child: const Text('Edit entire series'),
          ),
        ],
      ),
    );
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
      builder: (context) => _CreateEventSheet(
        calendars: [calendar],
        initialEvent: event,
        editScope: editScope,
        onCreate: _createEvent,
        onUpdate: _updateEvent,
      ),
    );

    if (updated == true && mounted) {
      _loadMonth();
    }
  }

  Future<void> _updateEvent({
    required ClientEvent event,
    required String title,
    required DateTime? startsAt,
    required DateTime? endsAt,
    required bool? allDay,
    String? location,
    String? description,
    String? recurrence,
    String? editScope,
  }) async {
    final editOccurrence = event.recurring && editScope == 'occurrence';
    final editSeriesMetadataOnly = event.recurring && editScope == 'series';

    await widget.hubClient.updateEvent(
      accessToken: widget.accessToken,
      eventId: editOccurrence ? event.id : event.writableEventId,
      title: title,
      startsAt: editSeriesMetadataOnly || startsAt == null
          ? null
          : allDay == true
              ? _formatDate(startsAt)
              : startsAt.toIso8601String(),
      endsAt: editSeriesMetadataOnly || endsAt == null
          ? null
          : allDay == true
              ? _formatDate(endsAt)
              : endsAt.toIso8601String(),
      allDay: editSeriesMetadataOnly ? null : allDay,
      location: location,
      description: description,
      recurrence: editOccurrence || editSeriesMetadataOnly ? null : recurrence,
      includeRecurrence: !editOccurrence && !editSeriesMetadataOnly,
      scope: event.recurring ? editScope : null,
    );
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
      deleteScope = await showDialog<String>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Delete recurring event?'),
          content: Text(
            'Delete only this event, or delete "${event.title}" and the entire recurring series?',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(null),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).pop('occurrence'),
              child: const Text('Delete this event'),
            ),
            TextButton(
              style: TextButton.styleFrom(
                foregroundColor: CaleeColors.destructive,
              ),
              onPressed: () => Navigator.of(context).pop('series'),
              child: const Text(
                'Delete entire series',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
          ],
        ),
      );
      if (deleteScope == null || !mounted) return;
    }

    final deleteOccurrence = event.recurring && deleteScope == 'occurrence';

    try {
      await widget.hubClient.deleteEvent(
        accessToken: widget.accessToken,
        eventId: deleteOccurrence ? event.id : event.writableEventId,
        scope: event.recurring ? deleteScope : null,
      );

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
        _loadMonth();
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              error is CaleeHubException
                  ? error.message
                  : deleteOccurrence
                      ? 'Unable to delete recurring event.'
                      : event.recurring
                          ? 'Unable to delete recurring series.'
                          : 'Unable to delete event.',
            ),
          ),
        );
      }
    }
  }

  Future<void> _createEvent({
    required ClientCalendar calendar,
    required String title,
    required DateTime startsAt,
    required DateTime endsAt,
    required bool allDay,
    String? location,
    String? description,
    String? recurrence,
  }) async {
    await widget.hubClient.createEvent(
      accessToken: widget.accessToken,
      serviceId: calendar.serviceId,
      calendarId: calendar.id,
      title: title,
      startsAt: allDay ? _formatDate(startsAt) : startsAt.toIso8601String(),
      endsAt: allDay ? _formatDate(endsAt) : endsAt.toIso8601String(),
      allDay: allDay,
      location: location,
      description: description,
      recurrence: recurrence,
    );
  }

  // ── Helpers ────────────────────────────────────────────────────────────────

  String _formatDate(DateTime value) {
    final local = value.toLocal();
    final year = local.year.toString().padLeft(4, '0');
    final month = local.month.toString().padLeft(2, '0');
    final day = local.day.toString().padLeft(2, '0');
    return '$year-$month-$day';
  }

  List<ClientEvent> _eventsForDay(DateTime day) {
    final result = <ClientEvent>[];
    for (final event in _events) {
      final cal = _calendarForEvent(event);
      if (cal != null && !_isCalendarVisible(cal.id)) continue;
      final start = DateTime.tryParse(event.startsAt)?.toLocal();
      if (start == null) continue;
      if (event.allDay) {
        final end = DateTime.tryParse(event.endsAt)?.toLocal();
        final startDate = DateTime(start.year, start.month, start.day);
        // all-day endsAt is exclusive
        final endDate = end != null
            ? DateTime(end.year, end.month, end.day)
                .subtract(const Duration(days: 1))
            : startDate;
        final check = DateTime(day.year, day.month, day.day);
        if (!check.isBefore(startDate) && !check.isAfter(endDate)) {
          result.add(event);
        }
      } else {
        if (start.year == day.year &&
            start.month == day.month &&
            start.day == day.day) {
          result.add(event);
        }
      }
    }
    result.sort((a, b) {
      final at = DateTime.tryParse(a.startsAt);
      final bt = DateTime.tryParse(b.startsAt);
      if (at == null || bt == null) return 0;
      return at.compareTo(bt);
    });
    return result;
  }

  Color _eventColor(ClientEvent event) {
    final cal = _calendarForEvent(event);
    if (cal?.color != null) {
      final parsed = _parseHexColor(cal!.color!);
      if (parsed != null) return parsed;
    }
    return CaleeColors.dotBlue;
  }

  String _agendaDateLabel(DateTime day) {
    if (_isSameDay(day, _today)) return 'Today';
    final weekday = _kFullDayNames[day.weekday % 7]; // Sun=0
    return '$weekday ${day.day} ${_kMonthNames[day.month - 1]}';
  }

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    if (_loading && _calendars.isEmpty && _events.isEmpty) {
      return CaleeScaffold(
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    if (_error != null && _calendars.isEmpty && _events.isEmpty) {
      return CaleeScaffold(
        body: _CalendarErrorState(onRetry: _loadMonth),
      );
    }

    return CaleeScaffold(
      body: SafeArea(
        child: Column(
          children: [
            _buildTopBar(),
            _buildWeekdayHeader(),
            _buildMonthGrid(),
            const Divider(height: 1),
            Expanded(
              child: RefreshIndicator(
                onRefresh: _loadMonth,
                child: ListView(
                  padding: EdgeInsets.zero,
                  children: _buildAgendaItems(),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTopBar() {
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: CaleeSpacing.sm,
        vertical: CaleeSpacing.xs,
      ),
      child: Row(
        children: [
          TextButton(
            onPressed: _goToToday,
            style: TextButton.styleFrom(
              foregroundColor: CaleeColors.primary,
              padding: const EdgeInsets.symmetric(
                horizontal: CaleeSpacing.sm,
                vertical: CaleeSpacing.xs,
              ),
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            child: const Text(
              'Today',
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
            ),
          ),
          const SizedBox(width: CaleeSpacing.xs),
          IconButton(
            onPressed: _prevMonth,
            icon: const Icon(Icons.chevron_left),
            iconSize: 22,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
            color: CaleeColors.primary,
          ),
          Expanded(
            child: Text(
              _monthYearLabel(_selectedMonth),
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w600,
                color: CaleeColors.textPrimary,
              ),
            ),
          ),
          IconButton(
            onPressed: _nextMonth,
            icon: const Icon(Icons.chevron_right),
            iconSize: 22,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
            color: CaleeColors.primary,
          ),
          const SizedBox(width: CaleeSpacing.xs),
          IconButton(
            onPressed: _openCalendarChooser,
            icon: const Icon(Icons.tune),
            iconSize: 22,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
            color: CaleeColors.primary,
            tooltip: 'Calendars',
          ),
          IconButton(
            onPressed: _openCreateEventSheet,
            icon: const Icon(Icons.add),
            iconSize: 22,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
            color: CaleeColors.primary,
            tooltip: 'Add event',
          ),
        ],
      ),
    );
  }

  Widget _buildWeekdayHeader() {
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: CaleeSpacing.xs,
        vertical: 2,
      ),
      child: Row(
        children: _kDayAbbr
            .map(
              (d) => Expanded(
                child: Center(
                  child: Text(
                    d,
                    style: const TextStyle(
                      fontSize: 12,
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

  Widget _buildMonthGrid() {
    return LayoutBuilder(
      builder: (context, constraints) {
        final cellSize = constraints.maxWidth / 7;
        return SizedBox(
          height: cellSize * 6,
          child: GridView.builder(
            physics: const NeverScrollableScrollPhysics(),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 7,
            ),
            itemCount: 42,
            itemBuilder: (context, index) {
              final date = _gridStart.add(Duration(days: index));
              final dayEvents = _eventsForDay(date);
              final dotColors = dayEvents.take(3).map(_eventColor).toList();
              return _DayCell(
                date: date,
                isCurrentMonth: date.month == _selectedMonth.month,
                isToday: _isSameDay(date, _today),
                isSelected: _isSameDay(date, _selectedDay),
                dotColors: dotColors,
                onTap: () => setState(() => _selectedDay = date),
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
          _agendaDateLabel(_selectedDay),
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: _isSameDay(_selectedDay, _today)
                ? CaleeColors.primary
                : CaleeColors.textSecondary,
            letterSpacing: 0.2,
          ),
        ),
      ),
    );

    final dayEvents = _eventsForDay(_selectedDay);
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
              'No events',
              style: TextStyle(
                fontSize: 15,
                color: CaleeColors.textTertiary,
              ),
            ),
          ),
        ),
      );
    } else {
      if (allDayEvents.isNotEmpty) {
        items.add(_buildAgendaSectionHeading('All-day'));
        for (final event in allDayEvents) {
          items.add(
            _AgendaEventRow(
              event: event,
              color: _eventColor(event),
              calendarName: _calendarForEvent(event)?.name,
              hideTime: true,
              onTap: () => _openEventActions(event),
            ),
          );
        }
      }

      if (timedEvents.isNotEmpty) {
        items.add(_buildAgendaSectionHeading('Timed'));
        for (final event in timedEvents) {
          items.add(
            _AgendaEventRow(
              event: event,
              color: _eventColor(event),
              calendarName: _calendarForEvent(event)?.name,
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

// ─── Month day cell ───────────────────────────────────────────────────────────

class _DayCell extends StatelessWidget {
  const _DayCell({
    required this.date,
    required this.isCurrentMonth,
    required this.isToday,
    required this.isSelected,
    required this.dotColors,
    required this.onTap,
  });

  final DateTime date;
  final bool isCurrentMonth;
  final bool isToday;
  final bool isSelected;
  final List<Color> dotColors;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final Color numberColor;
    final Color? bgColor;

    if (isToday && isSelected) {
      bgColor = CaleeColors.primary;
      numberColor = Colors.white;
    } else if (isToday) {
      bgColor = CaleeColors.primary;
      numberColor = Colors.white;
    } else if (isSelected) {
      bgColor = CaleeColors.primary.withAlpha(30);
      numberColor = CaleeColors.primary;
    } else if (isCurrentMonth) {
      bgColor = null;
      numberColor = CaleeColors.textPrimary;
    } else {
      bgColor = null;
      numberColor = CaleeColors.textTertiary;
    }

    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 30,
            height: 30,
            decoration: bgColor != null
                ? BoxDecoration(color: bgColor, shape: BoxShape.circle)
                : null,
            alignment: Alignment.center,
            child: Text(
              '${date.day}',
              style: TextStyle(
                fontSize: 14,
                fontWeight: isToday ? FontWeight.w700 : FontWeight.w400,
                color: numberColor,
              ),
            ),
          ),
          const SizedBox(height: 3),
          _EventDots(colors: dotColors),
        ],
      ),
    );
  }
}

// ─── Event dots row ───────────────────────────────────────────────────────────

class _EventDots extends StatelessWidget {
  const _EventDots({required this.colors});

  final List<Color> colors;

  @override
  Widget build(BuildContext context) {
    if (colors.isEmpty) {
      return const SizedBox(height: 5);
    }

    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        for (int i = 0; i < colors.length; i++) ...[
          if (i > 0) const SizedBox(width: 2),
          Container(
            width: 5,
            height: 5,
            decoration: BoxDecoration(
              color: colors[i],
              shape: BoxShape.circle,
            ),
          ),
        ],
      ],
    );
  }
}

// ─── Agenda event row ─────────────────────────────────────────────────────────

class _AgendaEventRow extends StatelessWidget {
  const _AgendaEventRow({
    required this.event,
    required this.color,
    required this.onTap,
    this.calendarName,
    this.hideTime = false,
  });

  final ClientEvent event;
  final Color color;
  final VoidCallback onTap;
  final String? calendarName;
  final bool hideTime;

  @override
  Widget build(BuildContext context) {
    final subtitle = [
      if (calendarName != null && calendarName!.trim().isNotEmpty)
        calendarName!.trim(),
      if ((event.location ?? '').trim().isNotEmpty) event.location!.trim(),
    ].join(' · ');

    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: CaleeSpacing.md,
          vertical: 10,
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Colored left bar
            Container(
              width: 3,
              height: subtitle.isNotEmpty ? 40 : 22,
              decoration: BoxDecoration(
                color: color,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(width: CaleeSpacing.sm + 2),
            // Time (omitted for all-day rows inside the All-day section)
            if (!hideTime) ...[
              SizedBox(
                width: 42,
                child: Text(
                  _eventTimeLabel(event),
                  style: const TextStyle(
                    fontSize: 13,
                    color: CaleeColors.textSecondary,
                    height: 1.4,
                  ),
                ),
              ),
              const SizedBox(width: CaleeSpacing.sm),
            ],
            // Title + subtitle
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    event.title,
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w500,
                      color: CaleeColors.textPrimary,
                    ),
                  ),
                  if (subtitle.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: const TextStyle(
                        fontSize: 12,
                        color: CaleeColors.textSecondary,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Error state ──────────────────────────────────────────────────────────────

class _CalendarErrorState extends StatelessWidget {
  const _CalendarErrorState({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return CaleeEmptyState(
      icon: Icons.cloud_off_outlined,
      title: 'Unable to load calendar',
      body: 'Check your connection, then try again.',
      action: FilledButton(
        onPressed: onRetry,
        child: const Text('Try again'),
      ),
    );
  }
}

// ─── Create / Edit event sheet ────────────────────────────────────────────────

class _CreateEventSheet extends StatefulWidget {
  const _CreateEventSheet({
    required this.calendars,
    required this.onCreate,
    this.initialDate,
    this.initialEvent,
    this.editScope,
    this.onUpdate,
  });

  final List<ClientCalendar> calendars;
  final DateTime? initialDate;
  final ClientEvent? initialEvent;
  final String? editScope;
  final Future<void> Function({
    required ClientCalendar calendar,
    required String title,
    required DateTime startsAt,
    required DateTime endsAt,
    required bool allDay,
    String? location,
    String? description,
    String? recurrence,
  }) onCreate;
  final Future<void> Function({
    required ClientEvent event,
    required String title,
    required DateTime? startsAt,
    required DateTime? endsAt,
    required bool? allDay,
    String? location,
    String? description,
    String? recurrence,
    String? editScope,
  })? onUpdate;

  @override
  State<_CreateEventSheet> createState() => _CreateEventSheetState();
}

class _CreateEventSheetState extends State<_CreateEventSheet> {
  final _formKey = GlobalKey<FormState>();
  final _titleController = TextEditingController();
  final _locationController = TextEditingController();
  final _descriptionController = TextEditingController();
  final _recurrenceCountController = TextEditingController(text: '10');

  late ClientCalendar _selectedCalendar;
  late DateTime _selectedDate;
  late DateTime _selectedEndDate;
  late TimeOfDay _startTime;
  late TimeOfDay _endTime;
  String _selectedRecurrence = 'none';
  String _recurrenceEnd = 'never';
  late DateTime _recurrenceEndDate;
  bool _allDay = false;
  bool _isSubmitting = false;

  bool get _isEditing => widget.initialEvent != null;
  bool get _isEditingSingleOccurrence =>
      _isEditing &&
      widget.initialEvent!.recurring &&
      widget.editScope == 'occurrence';

  bool get _isEditingRecurringSeriesMetadata =>
      _isEditing &&
      widget.initialEvent!.recurring &&
      widget.editScope == 'series';

  @override
  void initState() {
    super.initState();

    _selectedCalendar = widget.calendars.first;

    final event = widget.initialEvent;
    if (event != null) {
      _titleController.text = event.title;
      _locationController.text = event.location ?? '';
      _descriptionController.text = event.description ?? '';
      _allDay = event.allDay;

      final start =
          DateTime.tryParse(event.startsAt)?.toLocal() ?? DateTime.now();
      final end = DateTime.tryParse(event.endsAt)?.toLocal() ??
          start.add(const Duration(hours: 1));

      _selectedDate = DateTime(start.year, start.month, start.day);
      _recurrenceEndDate = _selectedDate.add(const Duration(days: 30));
      _selectedEndDate = event.allDay
          ? DateTime(end.year, end.month, end.day)
              .subtract(const Duration(days: 1))
          : _selectedDate;

      if (!_isEditingSingleOccurrence) {
        _applyInitialRecurrence(event.recurrence);
      }

      if (_selectedEndDate.isBefore(_selectedDate)) {
        _selectedEndDate = _selectedDate;
      }

      _startTime = TimeOfDay(hour: start.hour, minute: start.minute);
      _endTime = TimeOfDay(hour: end.hour, minute: end.minute);
      return;
    }

    // Use initialDate from calendar selection if provided, else today
    final initial = widget.initialDate;
    final now = DateTime.now();
    _selectedDate = initial != null
        ? DateTime(initial.year, initial.month, initial.day)
        : DateTime(now.year, now.month, now.day);
    _selectedEndDate = _selectedDate;
    _recurrenceEndDate = _selectedDate.add(const Duration(days: 30));

    final nextHour = now.add(const Duration(hours: 1));
    _startTime = TimeOfDay(hour: nextHour.hour, minute: 0);
    _endTime = TimeOfDay(hour: (nextHour.hour + 1) % 24, minute: 0);
  }

  @override
  void dispose() {
    _titleController.dispose();
    _locationController.dispose();
    _descriptionController.dispose();
    _recurrenceCountController.dispose();
    super.dispose();
  }

  DateTime _dateTimeFor(TimeOfDay time) {
    return DateTime(
      _selectedDate.year,
      _selectedDate.month,
      _selectedDate.day,
      time.hour,
      time.minute,
    );
  }

  String _dateLabel(DateTime value) {
    return '${value.day}/${value.month}/${value.year}';
  }

  String _timeLabel(TimeOfDay value) {
    final hour = value.hour.toString().padLeft(2, '0');
    final minute = value.minute.toString().padLeft(2, '0');
    return '$hour:$minute';
  }

  Map<String, String> _parseRRule(String? recurrence) {
    final value = (recurrence ?? '').trim();
    if (value.isEmpty) return {};

    final parts = <String, String>{};
    for (final part in value.split(';')) {
      final separator = part.indexOf('=');
      if (separator <= 0 || separator == part.length - 1) continue;
      final key = part.substring(0, separator).trim().toUpperCase();
      final parsedValue = part.substring(separator + 1).trim().toUpperCase();
      parts[key] = parsedValue;
    }
    return parts;
  }

  DateTime? _dateFromRRuleUntil(String? value) {
    if (value == null || value.length < 8) return null;
    final rawDate = value.substring(0, 8);
    final year = int.tryParse(rawDate.substring(0, 4));
    final month = int.tryParse(rawDate.substring(4, 6));
    final day = int.tryParse(rawDate.substring(6, 8));
    if (year == null || month == null || day == null) return null;
    return DateTime(year, month, day);
  }

  void _applyInitialRecurrence(String? recurrence) {
    final parts = _parseRRule(recurrence);
    final frequency = parts['FREQ'];

    _selectedRecurrence = switch (frequency) {
      'DAILY' => 'daily',
      'WEEKLY' => 'weekly',
      'MONTHLY' => 'monthly',
      'YEARLY' => 'yearly',
      _ => 'none',
    };

    final count = parts['COUNT'];
    final until = parts['UNTIL'];

    if (count != null && count.isNotEmpty) {
      _recurrenceEnd = 'count';
      _recurrenceCountController.text = count;
    } else if (until != null && until.isNotEmpty) {
      _recurrenceEnd = 'date';
      final parsedUntil = _dateFromRRuleUntil(until);
      if (parsedUntil != null) {
        _recurrenceEndDate = parsedUntil;
      }
    } else {
      _recurrenceEnd = 'never';
    }
  }

  String? _recurrenceValue() {
    final frequency = switch (_selectedRecurrence) {
      'daily' => 'DAILY',
      'weekly' => 'WEEKLY',
      'monthly' => 'MONTHLY',
      'yearly' => 'YEARLY',
      _ => null,
    };

    if (frequency == null) return null;

    final parts = <String>['FREQ=$frequency'];

    if (_recurrenceEnd == 'count') {
      final count = int.tryParse(_recurrenceCountController.text.trim());
      if (count == null || count < 1) {
        throw const FormatException('Enter a repeat count of at least 1.');
      }
      parts.add('COUNT=$count');
    } else if (_recurrenceEnd == 'date') {
      parts.add('UNTIL=${_formatRRuleUntil(_recurrenceEndDate)}');
    }

    return parts.join(';');
  }

  String _formatRRuleUntil(DateTime value) {
    if (_allDay) {
      final year = value.year.toString().padLeft(4, '0');
      final month = value.month.toString().padLeft(2, '0');
      final day = value.day.toString().padLeft(2, '0');
      return '$year$month$day';
    }

    final localEndOfDay =
        DateTime(value.year, value.month, value.day, 23, 59, 59);
    final utc = localEndOfDay.toUtc();

    final year = utc.year.toString().padLeft(4, '0');
    final month = utc.month.toString().padLeft(2, '0');
    final day = utc.day.toString().padLeft(2, '0');
    final hour = utc.hour.toString().padLeft(2, '0');
    final minute = utc.minute.toString().padLeft(2, '0');
    final second = utc.second.toString().padLeft(2, '0');

    return '$year$month${day}T$hour$minute${second}Z';
  }

  String _recurrenceLabel(String value) {
    switch (value) {
      case 'daily':
        return 'Daily';
      case 'weekly':
        return 'Weekly';
      case 'monthly':
        return 'Monthly';
      case 'yearly':
        return 'Yearly';
      default:
        return 'Does not repeat';
    }
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _selectedDate,
      firstDate: DateTime(2020),
      lastDate: DateTime(2100),
    );

    if (picked != null && mounted) {
      setState(() {
        _selectedDate = DateTime(picked.year, picked.month, picked.day);
        if (_selectedEndDate.isBefore(_selectedDate)) {
          _selectedEndDate = _selectedDate;
        }
      });
    }
  }

  Future<void> _pickRecurrenceEndDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _recurrenceEndDate.isBefore(_selectedDate)
          ? _selectedDate
          : _recurrenceEndDate,
      firstDate: _selectedDate,
      lastDate: DateTime(2100),
    );

    if (picked != null && mounted) {
      setState(() {
        _recurrenceEndDate = DateTime(picked.year, picked.month, picked.day);
      });
    }
  }

  Future<void> _pickEndDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _selectedEndDate.isBefore(_selectedDate)
          ? _selectedDate
          : _selectedEndDate,
      firstDate: _selectedDate,
      lastDate: DateTime(2100),
    );

    if (picked != null && mounted) {
      setState(() {
        _selectedEndDate = DateTime(picked.year, picked.month, picked.day);
      });
    }
  }

  Future<void> _pickStartTime() async {
    final picked = await showTimePicker(
      context: context,
      initialTime: _startTime,
    );

    if (picked != null && mounted) {
      setState(() {
        _startTime = picked;
      });
    }
  }

  Future<void> _pickEndTime() async {
    final picked = await showTimePicker(
      context: context,
      initialTime: _endTime,
    );

    if (picked != null && mounted) {
      setState(() {
        _endTime = picked;
      });
    }
  }

  Future<void> _submit() async {
    if (_isSubmitting || !_formKey.currentState!.validate()) return;

    final metadataOnly = _isEditingRecurringSeriesMetadata;
    DateTime? startsAt;
    DateTime? endsAt;

    if (!metadataOnly) {
      startsAt = _dateTimeFor(_startTime);
      endsAt = _dateTimeFor(_endTime);

      if (_allDay) {
        if (_selectedEndDate.isBefore(_selectedDate)) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('End date must be on or after start date.'),
            ),
          );
          return;
        }
        endsAt = _selectedEndDate.add(const Duration(days: 1));
      } else if (!endsAt.isAfter(startsAt)) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('End time must be after start time.')),
        );
        return;
      }
    }

    setState(() {
      _isSubmitting = true;
    });

    try {
      final title = _titleController.text.trim();
      final location = _locationController.text.trim().isEmpty
          ? null
          : _locationController.text.trim();
      final description = _descriptionController.text.trim().isEmpty
          ? null
          : _descriptionController.text.trim();

      if (_isEditing) {
        await widget.onUpdate!(
          event: widget.initialEvent!,
          title: title,
          startsAt: startsAt,
          endsAt: endsAt,
          allDay: metadataOnly ? null : _allDay,
          location: location,
          description: description,
          recurrence: _isEditingSingleOccurrence || metadataOnly
              ? null
              : _recurrenceValue(),
          editScope: widget.editScope,
        );
      } else {
        await widget.onCreate(
          calendar: _selectedCalendar,
          title: title,
          startsAt: startsAt!,
          endsAt: endsAt!,
          allDay: _allDay,
          location: location,
          description: description,
          recurrence: _recurrenceValue(),
        );
      }

      if (mounted) {
        Navigator.of(context).pop(true);
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _isSubmitting = false;
        });

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              error is CaleeHubException
                  ? error.message
                  : _isEditing
                      ? widget.initialEvent!.recurring
                          ? 'Unable to update recurring series.'
                          : 'Unable to update event.'
                      : 'Unable to create event.',
            ),
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.viewInsetsOf(context).bottom;

    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(16, 16, 16, 16 + bottomInset),
        child: Form(
          key: _formKey,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  _isEditing
                      ? _isEditingSingleOccurrence
                          ? 'Edit this event'
                          : _isEditingRecurringSeriesMetadata
                              ? 'Edit series details'
                              : widget.initialEvent!.recurring
                                  ? 'Edit series'
                                  : 'Edit event'
                      : 'Add event',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 16),
                DropdownButtonFormField<ClientCalendar>(
                  initialValue: _selectedCalendar,
                  decoration: const InputDecoration(
                    labelText: 'Calendar',
                    border: OutlineInputBorder(),
                  ),
                  items: [
                    for (final calendar in widget.calendars)
                      DropdownMenuItem(
                        value: calendar,
                        child: Text(calendar.name),
                      ),
                  ],
                  onChanged: _isSubmitting || _isEditing
                      ? null
                      : (calendar) {
                          if (calendar != null) {
                            setState(() {
                              _selectedCalendar = calendar;
                            });
                          }
                        },
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _titleController,
                  enabled: !_isSubmitting,
                  autofocus: true,
                  decoration: const InputDecoration(
                    labelText: 'Title',
                    border: OutlineInputBorder(),
                  ),
                  validator: (value) {
                    if ((value ?? '').trim().isEmpty) {
                      return 'Enter a title';
                    }
                    return null;
                  },
                ),
                if (!_isEditingRecurringSeriesMetadata) ...[
                  const SizedBox(height: 12),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('All day'),
                    value: _allDay,
                    onChanged: _isSubmitting
                        ? null
                        : (value) {
                            setState(() {
                              _allDay = value;
                            });
                          },
                  ),
                  if (_allDay) ...[
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: _isSubmitting ? null : _pickDate,
                            icon: const Icon(Icons.today_outlined),
                            label: Text('Start ${_dateLabel(_selectedDate)}'),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: _isSubmitting ? null : _pickEndDate,
                            icon: const Icon(Icons.event_available_outlined),
                            label: Text('End ${_dateLabel(_selectedEndDate)}'),
                          ),
                        ),
                      ],
                    ),
                  ] else ...[
                    OutlinedButton.icon(
                      onPressed: _isSubmitting ? null : _pickDate,
                      icon: const Icon(Icons.today_outlined),
                      label: Text(_dateLabel(_selectedDate)),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: _isSubmitting ? null : _pickStartTime,
                            icon: const Icon(Icons.schedule_outlined),
                            label: Text('Start ${_timeLabel(_startTime)}'),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: _isSubmitting ? null : _pickEndTime,
                            icon: const Icon(Icons.schedule),
                            label: Text('End ${_timeLabel(_endTime)}'),
                          ),
                        ),
                      ],
                    ),
                  ],
                ],
                if (!_isEditingSingleOccurrence &&
                    !_isEditingRecurringSeriesMetadata) ...[
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String>(
                    initialValue: _selectedRecurrence,
                    decoration: const InputDecoration(
                      labelText: 'Repeat',
                      border: OutlineInputBorder(),
                    ),
                    items: const [
                      DropdownMenuItem(
                          value: 'none', child: Text('Does not repeat')),
                      DropdownMenuItem(value: 'daily', child: Text('Daily')),
                      DropdownMenuItem(value: 'weekly', child: Text('Weekly')),
                      DropdownMenuItem(
                          value: 'monthly', child: Text('Monthly')),
                      DropdownMenuItem(value: 'yearly', child: Text('Yearly')),
                    ],
                    onChanged: _isSubmitting
                        ? null
                        : (value) {
                            if (value != null) {
                              setState(() {
                                _selectedRecurrence = value;
                              });
                            }
                          },
                  ),
                  if (_selectedRecurrence != 'none') ...[
                    const SizedBox(height: 12),
                    DropdownButtonFormField<String>(
                      initialValue: _recurrenceEnd,
                      decoration: const InputDecoration(
                        labelText: 'Ends',
                        border: OutlineInputBorder(),
                      ),
                      items: const [
                        DropdownMenuItem(value: 'never', child: Text('Never')),
                        DropdownMenuItem(value: 'date', child: Text('On date')),
                        DropdownMenuItem(
                            value: 'count', child: Text('After count')),
                      ],
                      onChanged: _isSubmitting
                          ? null
                          : (value) {
                              if (value != null) {
                                setState(() {
                                  _recurrenceEnd = value;
                                });
                              }
                            },
                    ),
                    if (_recurrenceEnd == 'date') ...[
                      const SizedBox(height: 8),
                      OutlinedButton.icon(
                        onPressed:
                            _isSubmitting ? null : _pickRecurrenceEndDate,
                        icon: const Icon(Icons.event_repeat_outlined),
                        label: Text('Ends ${_dateLabel(_recurrenceEndDate)}'),
                      ),
                    ],
                    if (_recurrenceEnd == 'count') ...[
                      const SizedBox(height: 8),
                      TextFormField(
                        controller: _recurrenceCountController,
                        enabled: !_isSubmitting,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(
                          labelText: 'Number of repeats',
                          border: OutlineInputBorder(),
                        ),
                        validator: (value) {
                          if (_selectedRecurrence == 'none' ||
                              _recurrenceEnd != 'count') {
                            return null;
                          }
                          final count = int.tryParse((value ?? '').trim());
                          if (count == null || count < 1) {
                            return 'Enter a number of at least 1';
                          }
                          return null;
                        },
                      ),
                    ],
                    const SizedBox(height: 8),
                    Text(
                      'Repeats ${_recurrenceLabel(_selectedRecurrence).toLowerCase()}${_recurrenceEnd == 'never' ? '' : _recurrenceEnd == 'date' ? ' until ${_dateLabel(_recurrenceEndDate)}' : ' ${_recurrenceCountController.text.trim().isEmpty ? '' : 'for ${_recurrenceCountController.text.trim()} times'}'}.',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ],
                if (_isEditingRecurringSeriesMetadata) ...[
                  const SizedBox(height: 12),
                  Text(
                    'Series date, time, and repeat settings are preserved.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
                const SizedBox(height: 12),
                TextFormField(
                  controller: _locationController,
                  enabled: !_isSubmitting,
                  decoration: const InputDecoration(
                    labelText: 'Location',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _descriptionController,
                  enabled: !_isSubmitting,
                  maxLines: 3,
                  decoration: const InputDecoration(
                    labelText: 'Description',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 16),
                FilledButton(
                  onPressed: _isSubmitting ? null : _submit,
                  child: _isSubmitting
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Text(
                          _isEditing
                              ? widget.initialEvent!.recurring
                                  ? 'Update series'
                                  : 'Update event'
                              : 'Save event',
                        ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ─── Calendar chooser sheet ───────────────────────────────────────────────────

class _CalendarChooserSheet extends StatefulWidget {
  const _CalendarChooserSheet({
    required this.calendars,
    required this.initialHiddenIds,
    required this.hubClient,
    required this.accessToken,
    required this.onToggle,
    required this.onShowAll,
    required this.onNewCalendar,
    required this.onSubscribeFromLink,
    required this.onCalendarMutated,
  });

  final List<ClientCalendar> calendars;
  final Set<String> initialHiddenIds;
  final CaleeHubClient hubClient;
  final String accessToken;
  final void Function(String calendarId) onToggle;
  final VoidCallback onShowAll;
  final VoidCallback onNewCalendar;
  final VoidCallback onSubscribeFromLink;
  final void Function(String? message) onCalendarMutated;

  @override
  State<_CalendarChooserSheet> createState() => _CalendarChooserSheetState();
}

class _CalendarChooserSheetState extends State<_CalendarChooserSheet> {
  late Set<String> _hidden;

  @override
  void initState() {
    super.initState();
    _hidden = Set.from(widget.initialHiddenIds);
  }

  bool _isVisible(ClientCalendar cal) => !_hidden.contains(cal.id);

  void _toggle(ClientCalendar cal) {
    setState(() {
      if (_hidden.contains(cal.id)) {
        _hidden.remove(cal.id);
      } else {
        _hidden.add(cal.id);
      }
    });
    widget.onToggle(cal.id);
  }

  void _showAll() {
    setState(() => _hidden.clear());
    widget.onShowAll();
  }

  Color _calendarColor(ClientCalendar cal) {
    if (cal.color != null) {
      final parsed = _parseHexColor(cal.color!);
      if (parsed != null) return parsed;
    }
    return CaleeColors.dotBlue;
  }

  String _subtitleFor(ClientCalendar cal) {
    final parts = <String>[];
    if (cal.serviceName.trim().isNotEmpty) parts.add(cal.serviceName.trim());
    if (cal.isSubscription) parts.add('Subscribed');
    if (cal.readOnly) parts.add('Read-only');
    return parts.join(' · ');
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final maxHeight = MediaQuery.of(context).size.height * 0.85;
    final hasHidden = _hidden.isNotEmpty;

    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: maxHeight),
      child: SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(
                width: 36,
                height: 4,
                margin: const EdgeInsets.only(
                  top: CaleeSpacing.sm,
                  bottom: CaleeSpacing.md,
                ),
                decoration: BoxDecoration(
                  color: CaleeColors.separatorOpaque,
                  borderRadius: BorderRadius.circular(CaleeRadius.dot),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(
                CaleeSpacing.md,
                0,
                CaleeSpacing.md,
                CaleeSpacing.md,
              ),
              child: Row(
                children: [
                  Text('Calendars', style: theme.textTheme.titleLarge),
                  const Spacer(),
                  if (hasHidden)
                    TextButton(
                      onPressed: _showAll,
                      style: TextButton.styleFrom(
                        foregroundColor: CaleeColors.primary,
                        padding: const EdgeInsets.symmetric(
                          horizontal: CaleeSpacing.sm,
                          vertical: CaleeSpacing.xs,
                        ),
                        minimumSize: Size.zero,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      child: const Text('Show All'),
                    ),
                ],
              ),
            ),
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(
                  CaleeSpacing.md,
                  0,
                  CaleeSpacing.md,
                  CaleeSpacing.md,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _buildCalendarSection(),
                    const SizedBox(height: CaleeSpacing.sectionSpacing),
                    _buildAddSection(),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _openCalendarDetailSheet(ClientCalendar cal) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: CaleeColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(CaleeRadius.sheet),
        ),
      ),
      builder: (_) => _CalendarDetailSheet(
        calendar: cal,
        color: _calendarColor(cal),
        hubClient: widget.hubClient,
        accessToken: widget.accessToken,
        initiallyVisible: _isVisible(cal),
        onToggleAndClose: () {
          _toggle(cal);
          Navigator.of(context).pop(); // close detail sheet
        },
        onMutated: (String? message) {
          Navigator.of(context).pop(); // close detail sheet (top)
          Navigator.of(context).pop(); // close chooser sheet
          widget.onCalendarMutated(message);
        },
      ),
    );
  }

  Widget _buildCalendarSection() {
    if (widget.calendars.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: CaleeSpacing.lg),
        child: Text(
          'No calendars',
          style: const TextStyle(
            color: CaleeColors.textTertiary,
            fontSize: 15,
          ),
          textAlign: TextAlign.center,
        ),
      );
    }

    return CaleeSection(
      children: [
        for (final cal in widget.calendars)
          _CalendarChooserRow(
            calendar: cal,
            isVisible: _isVisible(cal),
            color: _calendarColor(cal),
            subtitle: _subtitleFor(cal),
            onTap: () => _toggle(cal),
            onInfoTap: () => _openCalendarDetailSheet(cal),
          ),
      ],
    );
  }

  void _showAddCaleeCalendarSheet() {
    Navigator.of(context).pop();
    CaleeBottomSheet.show<void>(
      context: context,
      title: 'Add Calee Calendar',
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            'Calee calendars will help you create ready-made public calendars.',
            style: TextStyle(fontSize: 15, color: CaleeColors.textSecondary),
          ),
          const SizedBox(height: CaleeSpacing.xs),
          const Text(
            'Examples: School, Sport Events, Holidays',
            style: TextStyle(fontSize: 13, color: CaleeColors.textTertiary),
          ),
          const SizedBox(height: CaleeSpacing.lg),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Got it'),
          ),
        ],
      ),
    );
  }

  Widget _buildAddSection() {
    return CaleeSection(
      title: 'Add',
      children: [
        CaleeListRow(
          title: 'New Calendar',
          leading: const Icon(
            Icons.add_circle_outline,
            color: CaleeColors.primary,
            size: 22,
          ),
          onTap: () {
            Navigator.of(context).pop();
            widget.onNewCalendar();
          },
        ),
        CaleeListRow(
          title: 'Subscribe from Link',
          leading: const Icon(
            Icons.link_outlined,
            color: CaleeColors.primary,
            size: 22,
          ),
          onTap: () {
            Navigator.of(context).pop();
            widget.onSubscribeFromLink();
          },
        ),
        CaleeListRow(
          title: 'Add Calee Calendar',
          leading: const Icon(
            Icons.public_outlined,
            color: CaleeColors.primary,
            size: 22,
          ),
          onTap: () => _showAddCaleeCalendarSheet(),
        ),
      ],
    );
  }
}

// ─── Calendar chooser row ─────────────────────────────────────────────────────

class _CalendarChooserRow extends StatelessWidget {
  const _CalendarChooserRow({
    required this.calendar,
    required this.isVisible,
    required this.color,
    required this.subtitle,
    required this.onTap,
    required this.onInfoTap,
  });

  final ClientCalendar calendar;
  final bool isVisible;
  final Color color;
  final String subtitle;
  final VoidCallback onTap;
  final VoidCallback onInfoTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.only(
          left: CaleeSpacing.md,
          top: 11,
          bottom: 11,
        ),
        child: Row(
          children: [
            _CalendarVisibilityDot(color: color, isVisible: isVisible),
            const SizedBox(width: CaleeSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    calendar.name,
                    style: const TextStyle(
                      fontSize: 16,
                      color: CaleeColors.textPrimary,
                    ),
                  ),
                  if (subtitle.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: const TextStyle(
                        fontSize: 12,
                        color: CaleeColors.textSecondary,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            // Info button — independently tappable, does NOT toggle visibility
            GestureDetector(
              onTap: onInfoTap,
              behavior: HitTestBehavior.opaque,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: CaleeSpacing.sm + 2,
                  vertical: CaleeSpacing.sm,
                ),
                child: Icon(
                  Icons.info_outline,
                  size: 20,
                  color: CaleeColors.textTertiary,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Calendar visibility dot ──────────────────────────────────────────────────

class _CalendarVisibilityDot extends StatelessWidget {
  const _CalendarVisibilityDot({
    required this.color,
    required this.isVisible,
  });

  final Color color;
  final bool isVisible;

  @override
  Widget build(BuildContext context) {
    if (isVisible) {
      return Container(
        width: 22,
        height: 22,
        decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        child: const Icon(Icons.check, color: Colors.white, size: 14),
      );
    }
    return Container(
      width: 22,
      height: 22,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(color: CaleeColors.textTertiary, width: 1.5),
      ),
    );
  }
}

// ─── Calendar detail sheet ────────────────────────────────────────────────────

const List<(String, Color)> _kDetailColorPalette = [
  ('#FF3B30', CaleeColors.dotRed),
  ('#FF9500', CaleeColors.dotOrange),
  ('#FFCC00', CaleeColors.dotYellow),
  ('#34C759', CaleeColors.dotGreen),
  ('#5AC8FA', CaleeColors.dotTeal),
  ('#007AFF', CaleeColors.dotBlue),
  ('#AF52DE', CaleeColors.dotPurple),
  ('#FF2D55', CaleeColors.dotPink),
  ('#8E8E93', CaleeColors.dotGray),
];

enum _DetailMode { info, edit }

class _CalendarDetailSheet extends StatefulWidget {
  const _CalendarDetailSheet({
    required this.calendar,
    required this.color,
    required this.hubClient,
    required this.accessToken,
    required this.initiallyVisible,
    required this.onToggleAndClose,
    required this.onMutated,
  });

  final ClientCalendar calendar;
  final Color color;
  final CaleeHubClient hubClient;
  final String accessToken;
  final bool initiallyVisible;
  final VoidCallback onToggleAndClose;
  final void Function(String? message) onMutated;

  @override
  State<_CalendarDetailSheet> createState() => _CalendarDetailSheetState();
}

class _CalendarDetailSheetState extends State<_CalendarDetailSheet> {
  _DetailMode _mode = _DetailMode.info;
  final _formKey = GlobalKey<FormState>();
  late TextEditingController _nameController;
  late TextEditingController _colorController;
  bool _isSubmitting = false;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.calendar.name);
    _colorController = TextEditingController(text: widget.calendar.color ?? '');
    _colorController.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _nameController.dispose();
    _colorController.dispose();
    super.dispose();
  }

  bool get _canEdit =>
      !widget.calendar.readOnly || widget.calendar.isSubscription;

  bool get _canDelete =>
      !widget.calendar.readOnly || widget.calendar.isSubscription;

  bool _isPaletteSelected(String hex) =>
      _colorController.text.trim().toUpperCase() == hex.toUpperCase();

  Color get _previewColor {
    final hex = _colorController.text.trim();
    if (hex.isEmpty) return widget.color;
    return _parseHexColor(hex) ?? widget.color;
  }

  Future<void> _submitEdit() async {
    if (_isSubmitting || !_formKey.currentState!.validate()) return;
    setState(() => _isSubmitting = true);
    try {
      await widget.hubClient.updateCalendar(
        accessToken: widget.accessToken,
        calendarId: widget.calendar.id,
        name: _nameController.text.trim(),
        color: _colorController.text.trim().isEmpty
            ? null
            : _colorController.text.trim(),
      );
      if (mounted) widget.onMutated('Calendar updated.');
    } catch (error) {
      if (mounted) {
        setState(() => _isSubmitting = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              error is CaleeHubException
                  ? error.message
                  : 'Unable to update calendar.',
            ),
          ),
        );
      }
    }
  }

  Future<void> _confirmDelete() async {
    final cal = widget.calendar;
    final isSubscription = cal.isSubscription;

    final title = isSubscription
        ? 'Unsubscribe from Calendar?'
        : 'Delete Calendar?';
    final body = isSubscription
        ? 'This removes "${cal.name}" from Calee. '
            'The original external calendar and feed are not changed. '
            'This cannot be undone from Calee.'
        : 'Delete "${cal.name}" and its events from Calee? '
            'This cannot be undone.';
    final confirmLabel = isSubscription ? 'Unsubscribe' : 'Delete Calendar';

    final confirmed = await CaleeDestructiveDialog.show(
      context: context,
      title: title,
      body: body,
      confirmLabel: confirmLabel,
    );
    if (!confirmed || !mounted) return;

    setState(() => _isSubmitting = true);
    try {
      await widget.hubClient.deleteCalendar(
        accessToken: widget.accessToken,
        calendarId: cal.id,
        confirmDeleteItems: true,
      );
      if (mounted) {
        widget.onMutated(
          isSubscription ? 'Calendar unsubscribed.' : 'Calendar deleted.',
        );
      }
    } catch (error) {
      if (mounted) {
        setState(() => _isSubmitting = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              error is CaleeHubException
                  ? error.message
                  : 'Unable to remove calendar.',
            ),
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.viewInsetsOf(context).bottom;
    final maxHeight = MediaQuery.of(context).size.height * 0.9;

    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: maxHeight),
      child: SafeArea(
        child: Padding(
          padding: EdgeInsets.fromLTRB(
            CaleeSpacing.md,
            CaleeSpacing.sm,
            CaleeSpacing.md,
            CaleeSpacing.md + bottomInset,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Container(
                  width: 36,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: CaleeSpacing.md),
                  decoration: BoxDecoration(
                    color: CaleeColors.separatorOpaque,
                    borderRadius: BorderRadius.circular(CaleeRadius.dot),
                  ),
                ),
              ),
              Flexible(
                child: _mode == _DetailMode.info
                    ? _buildInfoMode()
                    : _buildEditMode(),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildInfoMode() {
    final cal = widget.calendar;
    final host = _subscriptionHost(cal.subscriptionUrl);
    final theme = Theme.of(context);

    return SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Header: color dot + calendar name
          Row(
            children: [
              Container(
                width: 20,
                height: 20,
                decoration: BoxDecoration(
                  color: widget.color,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: CaleeSpacing.sm),
              Expanded(
                child: Text(
                  cal.name,
                  style: theme.textTheme.titleLarge,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: CaleeSpacing.md),

          // Info section
          CaleeSection(
            children: [
              if (cal.serviceName.trim().isNotEmpty)
                _DetailInfoRow(
                  label: 'Account',
                  value: cal.serviceName.trim(),
                ),
              _DetailInfoRow(
                label: 'Visibility',
                value: widget.initiallyVisible ? 'Shown' : 'Hidden',
              ),
              if (cal.isSubscription)
                const _DetailInfoRow(label: 'Type', value: 'Subscribed'),
              if (cal.readOnly)
                const _DetailInfoRow(label: 'Access', value: 'Read-only'),
              // Show source host only — never the full URL (may contain tokens)
              if (host != null)
                _DetailInfoRow(label: 'Source', value: host),
            ],
          ),
          const SizedBox(height: CaleeSpacing.sectionSpacing),

          // Actions section
          CaleeSection(
            children: [
              _DetailActionRow(
                icon: widget.initiallyVisible
                    ? Icons.visibility_off_outlined
                    : Icons.visibility_outlined,
                title: widget.initiallyVisible
                    ? 'Hide Calendar'
                    : 'Show Calendar',
                onTap: _isSubmitting ? null : widget.onToggleAndClose,
              ),
              if (_canEdit)
                _DetailActionRow(
                  icon: Icons.edit_outlined,
                  title: 'Edit Name & Color',
                  onTap: _isSubmitting
                      ? null
                      : () => setState(() => _mode = _DetailMode.edit),
                ),
              if (_canDelete)
                _DetailActionRow(
                  icon: cal.isSubscription
                      ? Icons.link_off
                      : Icons.delete_outline,
                  title: cal.isSubscription ? 'Unsubscribe' : 'Delete Calendar',
                  isDestructive: true,
                  trailing: _isSubmitting
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : null,
                  onTap: _isSubmitting ? null : _confirmDelete,
                ),
            ],
          ),
          const SizedBox(height: CaleeSpacing.md),
        ],
      ),
    );
  }

  Widget _buildEditMode() {
    final theme = Theme.of(context);

    return Form(
      key: _formKey,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Header with back button
            Row(
              children: [
                GestureDetector(
                  onTap: _isSubmitting
                      ? null
                      : () => setState(() => _mode = _DetailMode.info),
                  child: const Icon(
                    Icons.arrow_back_ios,
                    size: 20,
                    color: CaleeColors.primary,
                  ),
                ),
                const SizedBox(width: CaleeSpacing.sm),
                Text('Edit Calendar', style: theme.textTheme.titleLarge),
              ],
            ),
            const SizedBox(height: CaleeSpacing.md),

            // Color preview dot + name field
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Container(
                  width: 24,
                  height: 24,
                  decoration: BoxDecoration(
                    color: _previewColor,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: CaleeSpacing.sm),
                Expanded(
                  child: TextFormField(
                    controller: _nameController,
                    enabled: !_isSubmitting,
                    autofocus: true,
                    textCapitalization: TextCapitalization.words,
                    decoration: const InputDecoration(labelText: 'Name'),
                    validator: (value) =>
                        (value ?? '').trim().isEmpty ? 'Enter a name' : null,
                  ),
                ),
              ],
            ),
            const SizedBox(height: CaleeSpacing.md),

            Text(
              'Color',
              style: theme.textTheme.bodySmall?.copyWith(
                color: CaleeColors.textSecondary,
              ),
            ),
            const SizedBox(height: CaleeSpacing.sm),

            Wrap(
              spacing: CaleeSpacing.sm,
              runSpacing: CaleeSpacing.sm,
              children: [
                for (final (hex, color) in _kDetailColorPalette)
                  _DetailColorSwatch(
                    hex: hex,
                    color: color,
                    isSelected: _isPaletteSelected(hex),
                    onTap: () => setState(() => _colorController.text = hex),
                  ),
              ],
            ),
            const SizedBox(height: CaleeSpacing.sm + 4),

            TextFormField(
              controller: _colorController,
              enabled: !_isSubmitting,
              decoration: const InputDecoration(
                labelText: 'Custom color',
                hintText: '#007AFF',
              ),
              validator: (value) {
                final c = (value ?? '').trim();
                if (c.isEmpty) return null;
                final norm = c.startsWith('#') ? c : '#$c';
                if (!RegExp(r'^#[0-9A-Fa-f]{6}$').hasMatch(norm)) {
                  return 'Use a color like #007AFF';
                }
                return null;
              },
            ),
            const SizedBox(height: CaleeSpacing.md),

            FilledButton(
              onPressed: _isSubmitting ? null : _submitEdit,
              child: _isSubmitting
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('Save'),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Detail info row ──────────────────────────────────────────────────────────

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

// ─── Detail action row ────────────────────────────────────────────────────────

class _DetailActionRow extends StatelessWidget {
  const _DetailActionRow({
    required this.icon,
    required this.title,
    this.isDestructive = false,
    this.onTap,
    this.trailing,
  });

  final IconData icon;
  final String title;
  final bool isDestructive;
  final VoidCallback? onTap;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final textColor =
        isDestructive ? CaleeColors.destructive : CaleeColors.textPrimary;
    final iconColor =
        isDestructive ? CaleeColors.destructive : CaleeColors.primary;

    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: CaleeSpacing.md,
          vertical: 13,
        ),
        child: Row(
          children: [
            Icon(icon, color: iconColor, size: 22),
            const SizedBox(width: CaleeSpacing.md),
            Expanded(
              child: Text(
                title,
                style: TextStyle(fontSize: 16, color: textColor),
              ),
            ),
            if (trailing != null) trailing!,
          ],
        ),
      ),
    );
  }
}

// ─── Detail color swatch ──────────────────────────────────────────────────────

class _DetailColorSwatch extends StatelessWidget {
  const _DetailColorSwatch({
    required this.hex,
    required this.color,
    required this.isSelected,
    required this.onTap,
  });

  final String hex;
  final Color color;
  final bool isSelected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        width: 30,
        height: 30,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: color,
          border: isSelected
              ? Border.all(
                  color: CaleeColors.textPrimary,
                  width: 2,
                  strokeAlign: BorderSide.strokeAlignOutside,
                )
              : null,
        ),
        child: isSelected
            ? const Icon(Icons.check, size: 16, color: Colors.white)
            : null,
      ),
    );
  }
}
