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
import 'shared/calendar_display_event.dart';
import 'shared/calendar_display_event_adapters.dart';
import 'shared/read_only_calendar_view.dart';
import 'widgets/calendar_chooser_sheet.dart';
import 'widgets/calendar_error_state.dart';
import 'widgets/calendar_search_sheet.dart';
import 'widgets/calendar_widget_helpers.dart';
import 'widgets/create_event_sheet.dart';

class CalendarPage extends StatefulWidget {
  const CalendarPage({
    required this.hubClient,
    required this.accessToken,
    required this.services,
    required this.accountId,
    required this.isFamilyUxContext,
    this.refreshGeneration = 0,
    super.key,
  });

  final CaleeHubClient hubClient;
  final String accessToken;
  final List<ClientService> services;
  final String accountId;

  /// UX-only: hides the Chore lists section (and the "Chore list" create
  /// option) for business/workspace accounts, matching Chores/Meals gating.
  final bool isFamilyUxContext;
  // Increment to trigger a refresh of calendars and events from the parent.
  final int refreshGeneration;

  @override
  State<CalendarPage> createState() => _CalendarPageState();
}

class _CalendarPageState extends State<CalendarPage> {
  late CalendarController _controller;
  final TextEditingController _searchController = TextEditingController();
  CalendarDisplayViewMode _viewMode = CalendarDisplayViewMode.month;

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
  void didUpdateWidget(CalendarPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.refreshGeneration != widget.refreshGeneration) {
      _controller.refresh();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    _searchController.dispose();
    super.dispose();
  }

  // ── Collection shortcuts ──────────────────────────────────────────────────

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
              accountId: widget.accountId,
              isFamilyUxContext: widget.isFamilyUxContext,
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
        .where((c) => !c.readOnly && !c.isExternal)
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
        use24h: _use24h(context),
        initialDate: _controller.selectedDay,
        defaultCalendarId: _controller.preferences.defaultCalendarId,
        onCreate: _controller.createEvent,
        hubClient: widget.hubClient,
        accessToken: widget.accessToken,
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
    final isReadOnly =
        calendar == null ||
        calendar.readOnly ||
        calendar.isExternal ||
        event.isReadOnly;

    if (isReadOnly) {
      final isGoogle =
          event.isGoogleEvent || (calendar?.isGoogleCalendar ?? false);
      final message = isGoogle
          ? 'This event comes from Google Calendar. Edit it in Google Calendar.'
          : event.recurring
          ? 'This recurring event is from a read-only calendar.\nYou can view it, but changes must be made in the original calendar.'
          : 'This event is from a read-only calendar.\nYou can view it, but changes must be made in the original calendar.';
      CaleeActionSheet.show(
        context: context,
        title: message,
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
        use24h: _use24h(context),
        initialEvent: event,
        editScope: editScope,
        onCreate: _controller.createEvent,
        onUpdate: _controller.updateEvent,
        hubClient: widget.hubClient,
        accessToken: widget.accessToken,
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

  // ── Search ─────────────────────────────────────────────────────────────────

  bool _use24h(BuildContext context) =>
      switch (_controller.preferences.timeFormat) {
        TimeFormatPref.h24 => true,
        TimeFormatPref.h12 => false,
        TimeFormatPref.system => MediaQuery.alwaysUse24HourFormatOf(context),
      };

  String _calendarNameForEvent(ClientEvent event) {
    return _controller.calendarForEvent(event)?.name ?? '';
  }

  Color _eventColor(ClientEvent event) {
    final cal = _controller.calendarForEvent(event);
    if (cal?.color != null) {
      final parsed = parseCalendarHexColor(cal!.color!);
      if (parsed != null) return parsed;
    }
    return CaleeColors.dotBlue;
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

  // ── Display event conversion ──────────────────────────────────────────────

  List<CalendarDisplayEvent> get _visibleDisplayEvents {
    return _controller.events
        .where((e) {
          final cal = _controller.calendarForEvent(e);
          return cal == null || _controller.isCalendarVisible(cal.id);
        })
        .map(
          (e) => calendarDisplayEventFromClientEvent(
            e,
            calendar: _controller.calendarForEvent(e),
          ),
        )
        .toList();
  }

  void _onDisplayEventTap(CalendarDisplayEvent displayEvent) {
    final matches = _controller.events
        .where((e) => e.id == displayEvent.id)
        .toList();
    if (matches.isEmpty) return;
    _openEventActions(matches.first);
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

        if (_controller.calendarServiceErrors.isNotEmpty &&
            _controller.calendars.isEmpty &&
            _controller.events.isEmpty &&
            !_controller.isLoading) {
          return CaleeScaffold(
            body: CalendarServiceConnectionErrorState(
              errors: _controller.calendarServiceErrors,
              onRetry: _controller.refresh,
            ),
          );
        }

        final use24h = _use24h(context);
        final firstDayOfWeek =
            _controller.preferences.firstDayOfWeek == FirstDayOfWeek.monday
            ? 1
            : 0;
        final actionIconMinH = MediaQuery.sizeOf(context).height < 520
            ? 32.0
            : 36.0;

        final serviceErrors = _controller.calendarServiceErrors;
        final hasPartialServiceError =
            serviceErrors.isNotEmpty && _controller.calendars.isNotEmpty;

        final calendarView = ReadOnlyCalendarView(
          selectedMonth: _controller.selectedMonth,
          selectedDay: _controller.selectedDay,
          today: _controller.today,
          firstDayOfWeek: firstDayOfWeek,
          events: _visibleDisplayEvents,
          viewMode: _viewMode,
          onViewModeChanged: (m) => setState(() => _viewMode = m),
          onPreviousMonth: _controller.previousMonth,
          onNextMonth: _controller.nextMonth,
          onGoToToday: _controller.goToToday,
          onSelectDay: _controller.selectDay,
          onEventTap: _onDisplayEventTap,
          use24h: use24h,
          actionWidgets: [
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
        );

        return CaleeScaffold(
          body: SafeArea(
            child: hasPartialServiceError
                ? Column(
                    children: [
                      CalendarServiceWarningBanner(errors: serviceErrors),
                      Expanded(child: calendarView),
                    ],
                  )
                : calendarView,
          ),
        );
      },
    );
  }
}
