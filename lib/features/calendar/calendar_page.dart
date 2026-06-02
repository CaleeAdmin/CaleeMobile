import 'dart:async';

import 'package:flutter/material.dart';

import '../../data/api/calee_hub_client.dart';
import '../../data/auth/calee_preferences.dart';
import '../../data/models/client_bootstrap.dart';
import '../../data/models/client_calendar.dart';
import '../../ui/calee_design.dart';
import '../settings/calendar_collections_page.dart';

// ─── Label helpers ────────────────────────────────────────────────────────────

const _kMonthAbbr = [
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
];

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

String _eventTimeLabel(ClientEvent event, {bool use24h = true}) {
  final start = DateTime.tryParse(event.startsAt)?.toLocal();
  if (start == null) return event.allDay ? 'All day' : '';
  if (event.allDay) return 'All day';
  if (use24h) {
    final h = start.hour.toString().padLeft(2, '0');
    final m = start.minute.toString().padLeft(2, '0');
    return '$h:$m';
  } else {
    final hour12 = start.hour % 12;
    final displayHour = hour12 == 0 ? 12 : hour12;
    final m = start.minute.toString().padLeft(2, '0');
    final period = start.hour < 12 ? 'am' : 'pm';
    return '$displayHour:$m $period';
  }
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

  // ── Preferences ───────────────────────────────────────────────────────────
  final _caleePrefs = CaleePreferences();
  StoredPreferences _prefs = const StoredPreferences();

  // ── Search ────────────────────────────────────────────────────────────────
  final TextEditingController _searchController = TextEditingController();

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

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
    _gridStart = _computeGridStart(_selectedMonth, _prefs.firstDayOfWeek);
    _loadMonth();
  }

  // ── Data loading ───────────────────────────────────────────────────────────

  static DateTime _computeGridStart(
    DateTime firstOfMonth,
    FirstDayOfWeek firstDay,
  ) {
    // Sunday-first: offset = weekday % 7  (Mon=1→1, …, Sun=7→0)
    // Monday-first: offset = (weekday+6) % 7  (Mon=1→0, …, Sun=7→6)
    final offset = firstDay == FirstDayOfWeek.monday
        ? (firstOfMonth.weekday + 6) % 7
        : firstOfMonth.weekday % 7;
    return firstOfMonth.subtract(Duration(days: offset));
  }

  Future<void> _loadMonth() async {
    StoredPreferences freshPrefs;
    try {
      freshPrefs = await _caleePrefs.load();
    } catch (_) {
      freshPrefs = _prefs;
    }

    final gridStart = _computeGridStart(_selectedMonth, freshPrefs.firstDayOfWeek);
    final gridEnd = gridStart.add(const Duration(days: 41)); // 6 weeks − 1 day

    setState(() {
      _prefs = freshPrefs;
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
    setState(() {
      _selectedMonth = DateTime(
          _selectedMonth.year, _selectedMonth.month - 1, 1);
      if (_selectedDay.year != _selectedMonth.year ||
          _selectedDay.month != _selectedMonth.month) {
        _selectedDay = _selectedMonth;
      }
    });
    _loadMonth();
  }

  void _nextMonth() {
    setState(() {
      _selectedMonth = DateTime(
          _selectedMonth.year, _selectedMonth.month + 1, 1);
      if (_selectedDay.year != _selectedMonth.year ||
          _selectedDay.month != _selectedMonth.month) {
        _selectedDay = _selectedMonth;
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
        defaultCalendarId: _prefs.defaultCalendarId,
        onCreate: _createEvent,
      ),
    );

    if (created == true && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Event created.')),
      );
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
      title: 'This is a repeating event. Choose whether to remove only this event or the entire series.',
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
      builder: (context) => _CreateEventSheet(
        calendars: [calendar],
        initialEvent: event,
        editScope: editScope,
        onCreate: _createEvent,
        onUpdate: _updateEvent,
      ),
    );

    if (updated == true && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Event updated.')),
      );
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
      deleteScope = await _chooseDeleteScope();
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

  bool _use24h(BuildContext context) => switch (_prefs.timeFormat) {
        TimeFormatPref.h24 => true,
        TimeFormatPref.h12 => false,
        TimeFormatPref.system => MediaQuery.alwaysUse24HourFormatOf(context),
      };

  // ── Search ─────────────────────────────────────────────────────────────────

  String _calendarNameForEvent(ClientEvent event) {
    return _calendarForEvent(event)?.name ?? '';
  }

  List<ClientEvent> _searchEvents(String query) {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return [];
    return _events.where((e) {
      final cal = _calendarForEvent(e);
      if (cal != null && !_isCalendarVisible(cal.id)) return false;
      return (e.title).toLowerCase().contains(q) ||
          (e.location ?? '').toLowerCase().contains(q) ||
          (e.description ?? '').toLowerCase().contains(q) ||
          (cal?.name ?? '').toLowerCase().contains(q);
    }).toList()
      ..sort((a, b) {
        final at = DateTime.tryParse(a.startsAt);
        final bt = DateTime.tryParse(b.startsAt);
        if (at == null || bt == null) return 0;
        return at.compareTo(bt);
      });
  }

  void _openSearchSheet() {
    _searchController.clear();
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: CaleeColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(CaleeRadius.sheet)),
      ),
      builder: (sheetContext) => _CalendarSearchSheet(
        searchController: _searchController,
        searchEvents: _searchEvents,
        calendarNameForEvent: _calendarNameForEvent,
        eventColor: _eventColor,
        use24h: _use24h(context),
        onResultTap: (event) {
          Navigator.of(sheetContext).pop();
          final start = DateTime.tryParse(event.startsAt)?.toLocal();
          if (start == null) return;
          final tapMonth = DateTime(start.year, start.month, 1);
          final sameMonth = tapMonth.year == _selectedMonth.year &&
              tapMonth.month == _selectedMonth.month;
          setState(() {
            _selectedDay = DateTime(start.year, start.month, start.day);
            if (!sameMonth) _selectedMonth = tapMonth;
          });
          if (!sameMonth) _loadMonth();
        },
      ),
    );
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
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Row 1: month navigation
        Padding(
          padding: const EdgeInsets.fromLTRB(
            CaleeSpacing.xs,
            CaleeSpacing.xs,
            CaleeSpacing.xs,
            0,
          ),
          child: Row(
            children: [
              IconButton(
                onPressed: _prevMonth,
                icon: const Icon(Icons.chevron_left),
                iconSize: 24,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
                color: CaleeColors.primary,
                tooltip: 'Previous month',
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
                iconSize: 24,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
                color: CaleeColors.primary,
                tooltip: 'Next month',
              ),
            ],
          ),
        ),
        // Row 2: Today + action icons
        Padding(
          padding: const EdgeInsets.fromLTRB(
            CaleeSpacing.sm,
            0,
            CaleeSpacing.xs,
            CaleeSpacing.xs,
          ),
          child: Row(
            children: [
              Tooltip(
                message: 'Go to today',
                child: TextButton(
                  onPressed: _goToToday,
                  style: TextButton.styleFrom(
                    foregroundColor: CaleeColors.primary,
                    padding: const EdgeInsets.symmetric(
                      horizontal: CaleeSpacing.sm,
                      vertical: CaleeSpacing.xs,
                    ),
                    minimumSize: const Size(44, 36),
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
                constraints: const BoxConstraints(minWidth: 44, minHeight: 36),
                color: CaleeColors.primary,
                tooltip: 'Search events',
              ),
              IconButton(
                onPressed: _openCalendarChooser,
                icon: const Icon(Icons.tune),
                iconSize: 22,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 44, minHeight: 36),
                color: CaleeColors.primary,
                tooltip: 'Calendars',
              ),
              IconButton(
                onPressed: _openCreateEventSheet,
                icon: const Icon(Icons.add),
                iconSize: 22,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 44, minHeight: 36),
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
    if (_prefs.firstDayOfWeek == FirstDayOfWeek.monday) {
      return const ['M', 'T', 'W', 'T', 'F', 'S', 'S'];
    }
    return _kDayAbbr;
  }

  Widget _buildWeekdayHeader() {
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: CaleeSpacing.xs,
        vertical: 2,
      ),
      child: Row(
        children: _weekdayAbbr
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
                eventCount: dayEvents.length,
                onTap: () {
                  final tapMonth = DateTime(date.year, date.month, 1);
                  final sameMonth =
                      tapMonth.year == _selectedMonth.year &&
                      tapMonth.month == _selectedMonth.month;
                  setState(() {
                    _selectedDay = date;
                    if (!sameMonth) _selectedMonth = tapMonth;
                  });
                  if (!sameMonth) _loadMonth();
                },
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
              'No events this day',
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
              use24h: use24h,
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

// ─── Month day cell ───────────────────────────────────────────────────────────

class _DayCell extends StatelessWidget {
  const _DayCell({
    required this.date,
    required this.isCurrentMonth,
    required this.isToday,
    required this.isSelected,
    required this.dotColors,
    required this.eventCount,
    required this.onTap,
  });

  final DateTime date;
  final bool isCurrentMonth;
  final bool isToday;
  final bool isSelected;
  final List<Color> dotColors;
  final int eventCount;
  final VoidCallback onTap;

  String get _semanticLabel {
    final parts = <String>[
      '${date.day} ${_kMonthAbbr[date.month - 1]} ${date.year}',
      if (isToday) 'today',
      if (isSelected) 'selected',
      if (eventCount == 1) '1 event',
      if (eventCount > 1) '$eventCount events',
    ];
    return parts.join(', ');
  }

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

    return Semantics(
      label: _semanticLabel,
      selected: isSelected,
      button: true,
      child: GestureDetector(
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
    this.use24h = true,
  });

  final ClientEvent event;
  final Color color;
  final VoidCallback onTap;
  final String? calendarName;
  final bool hideTime;
  final bool use24h;

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
                  _eventTimeLabel(event, use24h: use24h),
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

// ─── Calendar search sheet ────────────────────────────────────────────────────

class _CalendarSearchSheet extends StatefulWidget {
  const _CalendarSearchSheet({
    required this.searchController,
    required this.searchEvents,
    required this.calendarNameForEvent,
    required this.eventColor,
    required this.onResultTap,
    this.use24h = true,
  });

  final TextEditingController searchController;
  final List<ClientEvent> Function(String query) searchEvents;
  final String Function(ClientEvent) calendarNameForEvent;
  final Color Function(ClientEvent) eventColor;
  final void Function(ClientEvent) onResultTap;
  final bool use24h;

  @override
  State<_CalendarSearchSheet> createState() => _CalendarSearchSheetState();
}

class _CalendarSearchSheetState extends State<_CalendarSearchSheet> {
  List<ClientEvent> _results = [];

  @override
  void initState() {
    super.initState();
    widget.searchController.addListener(_onQueryChanged);
  }

  @override
  void dispose() {
    widget.searchController.removeListener(_onQueryChanged);
    super.dispose();
  }

  void _onQueryChanged() {
    setState(() {
      _results = widget.searchEvents(widget.searchController.text);
    });
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.viewInsetsOf(context).bottom;
    final hasQuery = widget.searchController.text.trim().isNotEmpty;

    return Padding(
      padding: EdgeInsets.only(bottom: bottomInset),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Drag handle
          Padding(
            padding: const EdgeInsets.only(top: CaleeSpacing.sm),
            child: Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: CaleeColors.textTertiary,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          // Search field
          Padding(
            padding: const EdgeInsets.all(CaleeSpacing.md),
            child: TextField(
              controller: widget.searchController,
              autofocus: true,
              textInputAction: TextInputAction.search,
              decoration: InputDecoration(
                hintText: 'Search events…',
                prefixIcon: const Icon(Icons.search, size: 20),
                suffixIcon: hasQuery
                    ? IconButton(
                        icon: const Icon(Icons.close, size: 18),
                        onPressed: () => widget.searchController.clear(),
                      )
                    : null,
              ),
            ),
          ),
          // Results
          ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.sizeOf(context).height * 0.45,
            ),
            child: hasQuery && _results.isEmpty
                ? Padding(
                    padding: const EdgeInsets.all(CaleeSpacing.lg),
                    child: Text(
                      'No events match your search.',
                      style: TextStyle(color: CaleeColors.textSecondary),
                      textAlign: TextAlign.center,
                    ),
                  )
                : ListView.builder(
                    shrinkWrap: true,
                    itemCount: _results.length,
                    itemBuilder: (_, i) {
                      final event = _results[i];
                      return _AgendaEventRow(
                        event: event,
                        color: widget.eventColor(event),
                        calendarName: widget.calendarNameForEvent(event),
                        use24h: widget.use24h,
                        onTap: () => widget.onResultTap(event),
                      );
                    },
                  ),
          ),
          SizedBox(height: CaleeSpacing.md),
        ],
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
      title: 'We couldn\'t load your calendar',
      body: 'Check your connection and try again.',
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
    this.defaultCalendarId,
    this.onUpdate,
  });

  final List<ClientCalendar> calendars;
  final DateTime? initialDate;
  final ClientEvent? initialEvent;
  final String? editScope;
  final String? defaultCalendarId;
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
    if (widget.defaultCalendarId != null) {
      for (final cal in widget.calendars) {
        if (cal.id == widget.defaultCalendarId) {
          _selectedCalendar = cal;
          break;
        }
      }
    }

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
    final today = DateTime(now.year, now.month, now.day);
    _selectedDate = initial != null
        ? DateTime(initial.year, initial.month, initial.day)
        : today;
    _selectedEndDate = _selectedDate;
    _recurrenceEndDate = _selectedDate.add(const Duration(days: 30));

    // Default times: 9:00–10:00 for future dates, next hour for today
    if (_isSameDay(_selectedDate, today)) {
      final nextHour = now.add(const Duration(hours: 1));
      _startTime = TimeOfDay(hour: nextHour.hour, minute: 0);
      _endTime = TimeOfDay(hour: (nextHour.hour + 1) % 24, minute: 0);
    } else {
      _startTime = const TimeOfDay(hour: 9, minute: 0);
      _endTime = const TimeOfDay(hour: 10, minute: 0);
    }
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

  // ── Submit label ───────────────────────────────────────────────────────────

  String get _submitLabel {
    if (!_isEditing) return 'Save Event';
    if (_isEditingSingleOccurrence) return 'Update Event';
    if (widget.initialEvent!.recurring) return 'Update Series';
    return 'Update Event';
  }

  // ── Build ───────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.viewInsetsOf(context).bottom;

    final sheetTitle = _isEditing
        ? _isEditingSingleOccurrence
            ? 'Edit this event'
            : _isEditingRecurringSeriesMetadata
                ? 'Edit series details'
                : widget.initialEvent!.recurring
                    ? 'Edit series'
                    : 'Edit event'
        : 'Add event';

    return SafeArea(
      child: Container(
        color: CaleeColors.scaffoldBackground,
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Drag handle
              Center(
                child: Container(
                  width: 36,
                  height: 4,
                  margin: const EdgeInsets.only(top: CaleeSpacing.sm),
                  decoration: BoxDecoration(
                    color: CaleeColors.separatorOpaque,
                    borderRadius: BorderRadius.circular(CaleeRadius.dot),
                  ),
                ),
              ),
              Flexible(
                child: SingleChildScrollView(
                  padding: EdgeInsets.fromLTRB(
                    CaleeSpacing.md,
                    CaleeSpacing.md,
                    CaleeSpacing.md,
                    CaleeSpacing.md + bottomInset,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // Sheet title
                      Text(
                        sheetTitle,
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                      const SizedBox(height: CaleeSpacing.md),

                      // ── Event ─────────────────────────────────────────────
                      CaleeSection(
                        children: [
                          // Title field
                          CaleeSectionTextFormField(
                            controller: _titleController,
                            enabled: !_isSubmitting,
                            autofocus: true,
                            hintText: 'Title',
                            textInputAction: TextInputAction.next,
                            validator: (value) {
                              if ((value ?? '').trim().isEmpty) {
                                return 'Enter a title';
                              }
                              return null;
                            },
                          ),
                          // Calendar picker
                          CaleeSectionDropdownRow<ClientCalendar>(
                            label: 'Calendar',
                            value: _selectedCalendar,
                            items: [
                              for (final cal in widget.calendars)
                                DropdownMenuItem(
                                  value: cal,
                                  child: Text(cal.name),
                                ),
                            ],
                            onChanged: (cal) {
                              if (cal != null) {
                                setState(() => _selectedCalendar = cal);
                              }
                            },
                            enabled: !_isSubmitting && !_isEditing,
                          ),
                        ],
                      ),

                      // ── Time ──────────────────────────────────────────────
                      if (!_isEditingRecurringSeriesMetadata) ...[
                        const SizedBox(height: CaleeSpacing.sectionSpacing),
                        CaleeSection(
                          children: [
                            CaleeSectionSwitchRow(
                              label: 'All day',
                              value: _allDay,
                              enabled: !_isSubmitting,
                              onChanged: (v) => setState(() => _allDay = v),
                            ),
                            if (_allDay) ...[
                              CaleeSectionPickerRow(
                                label: 'Date',
                                value: _dateLabel(_selectedDate),
                                onTap: _isSubmitting ? null : _pickDate,
                                enabled: !_isSubmitting,
                              ),
                              CaleeSectionPickerRow(
                                label: 'End',
                                value: _dateLabel(_selectedEndDate),
                                onTap: _isSubmitting ? null : _pickEndDate,
                                enabled: !_isSubmitting,
                              ),
                            ] else ...[
                              CaleeSectionPickerRow(
                                label: 'Date',
                                value: _dateLabel(_selectedDate),
                                onTap: _isSubmitting ? null : _pickDate,
                                enabled: !_isSubmitting,
                              ),
                              CaleeSectionPickerRow(
                                label: 'Start',
                                value: _timeLabel(_startTime),
                                onTap: _isSubmitting ? null : _pickStartTime,
                                enabled: !_isSubmitting,
                              ),
                              CaleeSectionPickerRow(
                                label: 'End',
                                value: _timeLabel(_endTime),
                                onTap: _isSubmitting ? null : _pickEndTime,
                                enabled: !_isSubmitting,
                              ),
                            ],
                          ],
                        ),
                      ],

                      // ── Repeat ────────────────────────────────────────────
                      if (!_isEditingSingleOccurrence &&
                          !_isEditingRecurringSeriesMetadata) ...[
                        const SizedBox(height: CaleeSpacing.sectionSpacing),
                        CaleeSection(
                          children: [
                            CaleeSectionDropdownRow<String>(
                              label: 'Repeat',
                              value: _selectedRecurrence,
                              items: const [
                                DropdownMenuItem(
                                  value: 'none',
                                  child: Text('Does not repeat'),
                                ),
                                DropdownMenuItem(
                                  value: 'daily',
                                  child: Text('Daily'),
                                ),
                                DropdownMenuItem(
                                  value: 'weekly',
                                  child: Text('Weekly'),
                                ),
                                DropdownMenuItem(
                                  value: 'monthly',
                                  child: Text('Monthly'),
                                ),
                                DropdownMenuItem(
                                  value: 'yearly',
                                  child: Text('Yearly'),
                                ),
                              ],
                              onChanged: (value) {
                                if (value != null) {
                                  setState(
                                    () => _selectedRecurrence = value,
                                  );
                                }
                              },
                              enabled: !_isSubmitting,
                            ),
                            if (_selectedRecurrence != 'none') ...[
                              CaleeSectionDropdownRow<String>(
                                label: 'Ends',
                                value: _recurrenceEnd,
                                items: const [
                                  DropdownMenuItem(
                                    value: 'never',
                                    child: Text('Never'),
                                  ),
                                  DropdownMenuItem(
                                    value: 'date',
                                    child: Text('On date'),
                                  ),
                                  DropdownMenuItem(
                                    value: 'count',
                                    child: Text('After count'),
                                  ),
                                ],
                                onChanged: (value) {
                                  if (value != null) {
                                    setState(
                                      () => _recurrenceEnd = value,
                                    );
                                  }
                                },
                                enabled: !_isSubmitting,
                              ),
                              if (_recurrenceEnd == 'date')
                                CaleeSectionPickerRow(
                                  label: 'Ends on',
                                  value: _dateLabel(_recurrenceEndDate),
                                  onTap: _isSubmitting
                                      ? null
                                      : _pickRecurrenceEndDate,
                                  enabled: !_isSubmitting,
                                ),
                              if (_recurrenceEnd == 'count')
                                CaleeSectionLabeledTextFormField(
                                  label: 'Times',
                                  controller: _recurrenceCountController,
                                  enabled: !_isSubmitting,
                                  keyboardType: TextInputType.number,
                                  textAlign: TextAlign.right,
                                  hintText: '10',
                                  fieldWidth: 80,
                                  validator: (value) {
                                    if (_selectedRecurrence == 'none' ||
                                        _recurrenceEnd != 'count') {
                                      return null;
                                    }
                                    final count = int.tryParse(
                                      (value ?? '').trim(),
                                    );
                                    if (count == null || count < 1) {
                                      return 'Enter a number of at least 1';
                                    }
                                    return null;
                                  },
                                ),
                            ],
                          ],
                        ),
                      ],

                      // ── Series metadata note ───────────────────────────────
                      if (_isEditingRecurringSeriesMetadata) ...[
                        const SizedBox(height: CaleeSpacing.sectionSpacing),
                        Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: CaleeSpacing.sm,
                          ),
                          child: Text(
                            'Series date, time, and repeat settings are preserved.',
                            style:
                                Theme.of(context).textTheme.bodySmall?.copyWith(
                                      color: CaleeColors.textSecondary,
                                    ),
                          ),
                        ),
                      ],

                      // ── Details ───────────────────────────────────────────
                      const SizedBox(height: CaleeSpacing.sectionSpacing),
                      CaleeSection(
                        children: [
                          CaleeSectionTextFormField(
                            controller: _locationController,
                            enabled: !_isSubmitting,
                            hintText: 'Location',
                          ),
                          CaleeSectionTextFormField(
                            controller: _descriptionController,
                            enabled: !_isSubmitting,
                            hintText: 'Notes',
                            maxLines: 3,
                          ),
                        ],
                      ),

                      // ── Submit ────────────────────────────────────────────
                      const SizedBox(height: CaleeSpacing.lg),
                      FilledButton(
                        onPressed: _isSubmitting ? null : _submit,
                        child: _isSubmitting
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : Text(_submitLabel),
                      ),
                    ],
                  ),
                ),
              ),
            ],
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
