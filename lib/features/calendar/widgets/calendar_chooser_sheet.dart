import 'package:flutter/material.dart';

import '../../../data/api/calee_hub_client.dart';
import '../../../data/models/client_calendar.dart';
import '../../../ui/calee_design.dart';
import 'calendar_detail_sheet.dart';
import 'calendar_widget_helpers.dart';

class CalendarChooserSheet extends StatefulWidget {
  const CalendarChooserSheet({
    required this.calendars,
    required this.initialHiddenIds,
    required this.hubClient,
    required this.accessToken,
    required this.onToggle,
    required this.onShowAll,
    required this.onNewCalendar,
    required this.onSubscribeFromLink,
    required this.onCalendarMutated,
    super.key,
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
  State<CalendarChooserSheet> createState() => _CalendarChooserSheetState();
}

class _CalendarChooserSheetState extends State<CalendarChooserSheet> {
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
      final parsed = parseCalendarHexColor(cal.color!);
      if (parsed != null) return parsed;
    }
    return CaleeColors.dotBlue;
  }

  String _subtitleFor(ClientCalendar cal) {
    final parts = <String>[];
    if (cal.serviceName.trim().isNotEmpty) parts.add(cal.serviceName.trim());
    if (cal.isSubscription) parts.add('Connected calendar');
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
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.of(context).maybePop(),
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
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
      builder: (_) => CalendarDetailSheet(
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
          style: const TextStyle(color: CaleeColors.textTertiary, fontSize: 15),
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
      title: 'Add Calee calendar',
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            'Calee calendars help you add ready-made public calendars.',
            style: TextStyle(fontSize: 15, color: CaleeColors.textSecondary),
          ),
          const SizedBox(height: CaleeSpacing.xs),
          const Text(
            'Examples: school, sport events, holidays',
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
          title: 'New calendar',
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
          key: const Key('calendar_chooser_subscribe_from_link'),
          title: 'Add calendar link',
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
          title: 'Add Calee calendar',
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

class _CalendarVisibilityDot extends StatelessWidget {
  const _CalendarVisibilityDot({required this.color, required this.isVisible});

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
