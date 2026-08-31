import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../data/api/calee_hub_client.dart';
import '../../data/auth/calee_preferences.dart';
import '../../data/models/client_bootstrap.dart';
import '../../data/models/client_calendar.dart';
import '../../ui/calee_design.dart';
import '../local_subscriber/local_event_link_service.dart';
import '../local_subscriber/local_event_share_launcher.dart';
import '../notifications/calendar_reminder_coordinator.dart';
import '../settings/calendar_collections_page.dart';
import 'calendar_controller.dart';
import 'calendar_repository.dart';
import 'event_capabilities.dart';
import 'event_move_eligibility.dart';
import 'shared/calendar_display_event.dart';
import 'shared/calendar_display_event_adapters.dart';
import 'shared/read_only_calendar_view.dart';
import 'widgets/calendar_chooser_sheet.dart';
import 'widgets/calendar_error_state.dart';
import 'widgets/calendar_search_sheet.dart';
import 'widgets/calendar_widget_helpers.dart';
import 'widgets/create_event_sheet.dart';
import 'widgets/event_details_sheet.dart';

class CalendarPage extends StatefulWidget {
  const CalendarPage({
    required this.hubClient,
    required this.accessToken,
    required this.services,
    required this.accountId,
    required this.isFamilyUxContext,
    this.reminderCoordinator,
    this.eventLinkService,
    this.shareLauncher,
    this.refreshGeneration = 0,
    this.isActive = true,
    super.key,
  });

  final CaleeHubClient hubClient;
  final String accessToken;
  final List<ClientService> services;
  final String accountId;

  /// UX-only: hides the Chore lists section (and the "Chore list" create
  /// option) for business/workspace accounts, matching Chores/Meals gating.
  final bool isFamilyUxContext;

  /// App-level reminder coordinator. When present, successful event CRUD and
  /// manual refreshes trigger an independent upcoming-reminder refresh. Null in
  /// contexts (e.g. some tests) that do not exercise reminders.
  final CalendarReminderCoordinator? reminderCoordinator;

  /// Mints the canonical CalEmbed Event Link for a shared event. The very
  /// same seam signed-out sharing uses (CaleeAdmin/CaleeMobile#562), not a
  /// signed-in variant of it: one endpoint, one request shape, one client.
  /// Overrideable for tests; defaults to [CalEmbedEventLinkService].
  final LocalEventLinkService? eventLinkService;

  /// Opens the OS share sheet. Overrideable so a widget test can assert which
  /// URL was shared without a platform channel; defaults to
  /// [SharePlusEventShareLauncher].
  final LocalEventShareLauncher? shareLauncher;

  // Increment to trigger a refresh of calendars and events from the parent.
  final int refreshGeneration;

  /// Whether Calendar is the tab currently on screen. The home page keeps every
  /// tab mounted in an IndexedStack, so a hidden Calendar must not spend a
  /// network round trip refreshing when the app resumes — selecting the tab
  /// again bumps [refreshGeneration], which reloads it anyway.
  final bool isActive;

  @override
  State<CalendarPage> createState() => _CalendarPageState();
}

class _CalendarPageState extends State<CalendarPage>
    with WidgetsBindingObserver {
  late CalendarController _controller;
  final TextEditingController _searchController = TextEditingController();
  CalendarDisplayViewMode _viewMode = CalendarDisplayViewMode.month;

  /// True once the app has left the foreground. Cleared on the next resume, so
  /// exactly one refresh happens per background→foreground round trip and a
  /// repeated (or duplicated) `resumed` notification cannot queue another.
  bool _wasBackgrounded = false;

  LocalEventLinkService get _eventLinkService =>
      widget.eventLinkService ?? const CalEmbedEventLinkService();

  LocalEventShareLauncher get _shareLauncher =>
      widget.shareLauncher ?? const SharePlusEventShareLauncher();

  /// Every rendered [CalendarDisplayEvent] mapped back to the exact
  /// [ClientEvent] and [ClientCalendar] it was built from, keyed by OBJECT
  /// IDENTITY.
  ///
  /// This replaced a lookup that searched `_controller.events` for
  /// `e.id == displayEvent.id`. Hub's event `id` is a LOCAL COMPOSITE key that
  /// `contracts/event-occurrence-identity/v1` declares non-normative, and
  /// CaleeAdmin/calee-hub-core#421 documents cases where two distinct source
  /// UIDs produce the same one. Selecting a source by it could therefore edit,
  /// delete, or mint a public link for a DIFFERENT event from the row the user
  /// touched. [ReadOnlyCalendarEventRow] hands back the very object it was
  /// given, so identity is exact and needs no id at all.
  ///
  /// Rebuilt in the same pass as the display list (see [_buildDisplayEvents]),
  /// so a refresh can never leave a tap pointing at a stale source row.
  final Map<CalendarDisplayEvent, _ClientEventOrigin> _eventOrigins =
      HashMap<CalendarDisplayEvent, _ClientEventOrigin>.identity();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final repository = CalendarRepository(
      hubClient: widget.hubClient,
      accessToken: widget.accessToken,
      preferences: CaleePreferences(),
    );
    _controller = CalendarController(
      repository: repository,
      onRequestReminderRefresh: _requestReminderRefresh,
    );
    _controller.loadMonth();
  }

  /// Bridges CalendarController's explicit-change/manual-refresh hooks to the
  /// app-level reminder coordinator, supplying this page's access token. Kept
  /// no-op when no coordinator was injected.
  Future<void> _requestReminderRefresh(
    CalendarReminderRefreshReason reason,
  ) async {
    final coordinator = widget.reminderCoordinator;
    if (coordinator == null) return;
    await coordinator.refresh(accessToken: widget.accessToken, reason: reason);
  }

  @override
  void didUpdateWidget(CalendarPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.refreshGeneration != widget.refreshGeneration) {
      _controller.refresh();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (state != AppLifecycleState.resumed) {
      _wasBackgrounded = true;
      return;
    }
    if (!_wasBackgrounded) return;
    _wasBackgrounded = false;
    // Calendar keeps its controller (and its already-loaded events) alive in
    // the home IndexedStack, so anything that reached the hub while the app was
    // away — a subscribed calendar picking up new events, for example — stayed
    // invisible until the user left the tab and came back. Refetch just the
    // month already on screen, without a blocking spinner, and only while
    // Calendar is the visible tab: a hidden one reloads via refreshGeneration
    // when it is next selected.
    if (!widget.isActive || !mounted) return;
    unawaited(_controller.refreshInBackground());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
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

    // Creating an event never shows the attachments section (attaching
    // needs an event ID), so there is no attachment work for a drag to
    // bypass and this sheet keeps its normal drag-to-dismiss.
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
    // Editing IS the case that can hold attachment work, and the editor
    // decides for itself when it may close. Flutter's drag-to-dismiss calls
    // Navigator.pop() directly, which no PopScope can intercept, so dragging
    // is off here; the barrier stays dismissible because that path goes
    // through maybePop() and IS intercepted.
    // Every calendar this event could actually be MOVED to, not just the one
    // it is in. That list is what makes the editor's Calendar row a working
    // control instead of a label -- and it is filtered rather than "all
    // calendars", so the editor never offers a destination Hub would refuse
    // (see event_move_eligibility.dart).
    //
    // The fallback keeps the pre-existing behaviour exactly for an event whose
    // own calendar is not a valid destination (read-only, external, a kind
    // that cannot hold events): the editor is given that one calendar, so it
    // opens on the right one and the row stays disabled because there is
    // nowhere to move to.
    final destinations = eventMoveDestinations(
      event: event,
      calendars: _controller.calendars,
    );
    final sheetCalendars = destinations.any((c) => c.id == calendar.id)
        ? destinations
        : [calendar];

    final updated = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      enableDrag: false,
      backgroundColor: CaleeColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(CaleeRadius.sheet),
        ),
      ),
      builder: (context) => CreateEventSheet(
        calendars: sheetCalendars,
        use24h: _use24h(context),
        // Matches enableDrag above: no handle on a sheet that cannot be
        // dragged.
        showDragHandle: false,
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
          // Resolved from the exact ClientEvent Search handed back, BEFORE
          // the sheet closes and before selectSearchResult() can trigger a
          // month load that replaces _controller.events. Search deliberately
          // does not look the event up again by its legacy composite id:
          // that id can collide, so a re-lookup could open a different event
          // from the one the user chose.
          final calendar = _controller.calendarForEvent(event);
          Navigator.of(sheetContext).pop();
          _controller.selectSearchResult(event);
          unawaited(_openEventDetails(event, calendar));
        },
      ),
    );
  }

  // ── Display event conversion ──────────────────────────────────────────────

  /// Builds the display list AND the source mapping in one pass, so the two
  /// can never disagree about which [ClientEvent] produced which row.
  List<CalendarDisplayEvent> _buildDisplayEvents() {
    _eventOrigins.clear();
    final all = <CalendarDisplayEvent>[];
    for (final event in _controller.events) {
      final calendar = _controller.calendarForEvent(event);
      if (calendar != null && !_controller.isCalendarVisible(calendar.id)) {
        continue;
      }
      final displayEvent = calendarDisplayEventFromClientEvent(
        event,
        calendar: calendar,
      );
      _eventOrigins[displayEvent] = _ClientEventOrigin(
        event: event,
        calendar: calendar,
      );
      all.add(displayEvent);
    }
    return all;
  }

  /// Opens details for one tapped row, from its EXACT source event.
  ///
  /// There is no routing decision left to make here: every event opens the
  /// same details surface, and what that surface offers is decided by
  /// [resolveEventCapabilities] from the exact [ClientEvent] and
  /// [ClientCalendar]. A tap that resolved to no origin at all is the one
  /// case that does nothing — there is no event to show.
  void _onDisplayEventTap(CalendarDisplayEvent displayEvent) {
    final origin = _eventOrigins[displayEvent];
    if (origin == null) return;
    unawaited(
      _openEventDetails(origin.event, origin.calendar, display: displayEvent),
    );
  }

  /// The ONE signed-in event surface, shared by Month, Agenda and Search.
  ///
  /// [display] is passed when the caller already has the very object a row was
  /// built from; Search has only the [ClientEvent], so an equivalent display
  /// model is built from the same adapter the list uses.
  ///
  /// The sheet RETURNS an action instead of performing one. By the time the
  /// await below completes the details route is gone, so the existing edit and
  /// delete flows run with nothing stale underneath them — and they run
  /// against [event], the exact object the user tapped, never against an id
  /// looked up again afterwards.
  Future<void> _openEventDetails(
    ClientEvent event,
    ClientCalendar? calendar, {
    CalendarDisplayEvent? display,
  }) async {
    final details = EventDetailsContext(
      event: event,
      calendar: calendar,
      display:
          display ??
          calendarDisplayEventFromClientEvent(event, calendar: calendar),
      capabilities: resolveEventCapabilities(event: event, calendar: calendar),
    );

    final action = await showModalBottomSheet<EventDetailsAction>(
      context: context,
      isScrollControlled: true,
      backgroundColor: CaleeColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(CaleeRadius.sheet),
        ),
      ),
      builder: (_) => EventDetailsSheet(
        details: details,
        eventLinkService: _eventLinkService,
        shareLauncher: _shareLauncher,
        use24h: _use24h(context),
      ),
    );

    if (action == null || !mounted) return;

    switch (action) {
      case EventDetailsAction.edit:
        // Re-checked rather than trusted: the sheet only ever offers Edit when
        // the capability allows it, and a null calendar can never be editable,
        // but this is the last gate before a write path.
        if (!details.capabilities.canEdit || calendar == null) return;
        final editScope = await _chooseEditScope(event);
        if (editScope == null || !mounted) return;
        await _openEditEventSheet(event, calendar, editScope: editScope);
      case EventDetailsAction.delete:
        if (!details.capabilities.canDelete) return;
        await _confirmDeleteEvent(event);
    }
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
          events: _buildDisplayEvents(),
          viewMode: _viewMode,
          onViewModeChanged: (m) => setState(() => _viewMode = m),
          onPreviousMonth: _controller.previousMonth,
          onNextMonth: _controller.nextMonth,
          onGoToToday: _controller.goToToday,
          onSelectDay: _controller.selectDay,
          onEventTap: _onDisplayEventTap,
          // A pull is an explicit user refresh, so it goes through refresh()
          // (manual-refresh + reminder semantics), not refreshInBackground().
          // Returning the real future keeps the indicator up until the reload
          // finishes; load sequencing in the controller stops it racing an
          // app-resume refresh.
          onRefresh: _controller.refresh,
          use24h: use24h,
          actionWidgets: [
            IconButton(
              key: const Key('calendar_search_button'),
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
              key: const Key('calendar_filter_button'),
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
              key: const Key('calendar_add_event_button'),
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

/// One rendered row's exact source: the [ClientEvent] it was built from and
/// the [ClientCalendar] that event was read from.
///
/// Kept private and kept OFF [CalendarDisplayEvent]. The display model is
/// shared with the signed-out calendar, and widening it with a source UID and
/// a recurrence identity just to solve a lookup would put source identity on
/// every event the app renders — including ones that must never be shared.
class _ClientEventOrigin {
  const _ClientEventOrigin({required this.event, required this.calendar});

  final ClientEvent event;

  /// Null when the controller could not resolve the event's calendar. Such an
  /// event has no provable source, so it can never be shared.
  final ClientCalendar? calendar;
}
