import 'package:flutter/material.dart';

import '../../../data/models/client_calendar.dart';
import '../../../ui/calee_design.dart';
import 'calendar_event_row.dart';

class CalendarSearchSheet extends StatefulWidget {
  const CalendarSearchSheet({
    required this.searchController,
    required this.searchEvents,
    required this.calendarNameForEvent,
    required this.eventColor,
    required this.onResultTap,
    this.use24h = true,
    super.key,
  });

  final TextEditingController searchController;
  final List<ClientEvent> Function(String query) searchEvents;
  final String Function(ClientEvent) calendarNameForEvent;
  final Color Function(ClientEvent) eventColor;
  final void Function(ClientEvent) onResultTap;
  final bool use24h;

  @override
  State<CalendarSearchSheet> createState() => _CalendarSearchSheetState();
}

class _CalendarSearchSheetState extends State<CalendarSearchSheet> {
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
          // Sheet header
          Padding(
            padding: const EdgeInsets.fromLTRB(
              CaleeSpacing.md,
              CaleeSpacing.sm,
              CaleeSpacing.sm,
              0,
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    'Search Events',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: () => Navigator.of(context).maybePop(),
                ),
              ],
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
                      return CalendarAgendaEventRow(
                        key: ValueKey(event.id),
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
