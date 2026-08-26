/// Read-only-first details for ONE signed-in calendar event, with whatever
/// actions that exact event actually supports (CaleeAdmin/CaleeMobile#566).
///
/// Every tap on a Month row, an Agenda row or a Search result arrives here
/// first. What differs between a private family appointment, a followed club
/// calendar and a Google feed is not WHETHER details open — it is which
/// actions the resolved [EventCapabilities] permit.
///
/// The sheet is a presenter. It decides nothing about permission, source or
/// publication: those arrive already decided in [EventDetailsContext], so
/// there is no second place a rule could be re-derived slightly differently.
///
/// It also RETURNS rather than acts. Edit and Delete pop this route with an
/// [EventDetailsAction] and the calendar page runs its existing flows once the
/// route is gone — so the recurrence choosers, the destructive confirmation
/// and the attachment-aware editor stay exactly where they are, and no stale
/// details route is left underneath holding a `ClientEvent` a refresh has
/// since replaced.
///
/// Nothing identifying the SOURCE is rendered: no source UID, no canonical
/// recurrence identity, no Hub composite/series/occurrence id, no subscription
/// or DAV URL, no public token, no account or person id, and no raw RRULE.
/// Those values travel inside the mint request and nowhere else.
library;

import 'package:flutter/material.dart';

import '../../../ui/calee_design.dart';
import '../../local_subscriber/local_event_link_service.dart';
import '../../local_subscriber/local_event_share_launcher.dart';
import '../event_capabilities.dart';
import '../shared/event_detail_formatting.dart';
import '../shared/event_share_action.dart';

const Key kEventDetailsSheetKey = Key('event_details_sheet');
const Key kEventDetailsEditKey = Key('calendar_event_details_edit');
const Key kEventDetailsDeleteKey = Key('calendar_event_details_delete');
const Key kEventDetailsSourceNoteKey = Key('event_details_source_note');

/// What the user chose to do next. Null (a plain dismissal) means nothing.
enum EventDetailsAction { edit, delete }

class EventDetailsSheet extends StatelessWidget {
  const EventDetailsSheet({
    required this.details,
    required this.eventLinkService,
    required this.shareLauncher,
    this.use24h = true,
    super.key,
  });

  final EventDetailsContext details;
  final LocalEventLinkService eventLinkService;
  final LocalEventShareLauncher shareLauncher;
  final bool use24h;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final display = details.display;
    final capabilities = details.capabilities;
    final location = (display.location ?? '').trim();
    final description = (display.description ?? '').trim();
    final calendarName = display.calendarName.trim();
    final note = capabilities.readOnlyNote;

    final actions = _buildActions(context, theme);

    return SafeArea(
      key: kEventDetailsSheetKey,
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
            Flexible(
              child: ListView(
                shrinkWrap: true,
                padding: const EdgeInsets.fromLTRB(
                  CaleeSpacing.md,
                  0,
                  CaleeSpacing.md,
                  CaleeSpacing.md,
                ),
                children: [
                  _Title(title: display.title, color: display.color),
                  const SizedBox(height: CaleeSpacing.md),
                  EventDetailRow(
                    icon: Icons.event_outlined,
                    label: eventDetailDateLabel(display),
                  ),
                  EventDetailRow(
                    icon: Icons.schedule_outlined,
                    label: eventDetailTimeLabel(display, use24h: use24h),
                  ),
                  // Positive recurrence only. `recurring == false` is not
                  // authoritative for every source Hub forwards, so asserting
                  // "does not repeat" would be a claim this app cannot make.
                  // The rule itself is never rendered: an RRULE is not copy.
                  if (details.event.recurring)
                    const EventDetailRow(
                      icon: Icons.repeat,
                      label: 'Repeating event',
                    ),
                  if (calendarName.isNotEmpty)
                    EventDetailRow(
                      icon: Icons.calendar_today_outlined,
                      label: calendarName,
                    ),
                  if (location.isNotEmpty)
                    EventDetailRow(icon: Icons.place_outlined, label: location),
                  if (description.isNotEmpty)
                    EventDetailRow(
                      icon: Icons.notes_outlined,
                      label: description,
                    ),
                  if (note != null)
                    Padding(
                      padding: const EdgeInsets.only(top: CaleeSpacing.sm),
                      child: Text(
                        note,
                        key: kEventDetailsSourceNoteKey,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ...actions,
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Edit/Delete and Share, each present purely on its own capability.
  ///
  /// A public writable event legitimately shows all three.
  List<Widget> _buildActions(BuildContext context, ThemeData theme) {
    final capabilities = details.capabilities;
    final recurring = details.event.recurring;
    final hasMutation = capabilities.canEdit || capabilities.canDelete;

    if (!hasMutation &&
        capabilities.shareState.availability ==
            LocalEventShareAvailability.unsupportedSource) {
      // Nothing this user may do, and nothing to say about sharing this kind
      // of calendar. The details above already carry the read-only note.
      return const [];
    }

    return [
      const SizedBox(height: CaleeSpacing.md),
      const Divider(height: 1),
      if (capabilities.canEdit)
        Padding(
          padding: const EdgeInsets.only(top: CaleeSpacing.md),
          child: SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              key: kEventDetailsEditKey,
              onPressed: () =>
                  Navigator.of(context).pop(EventDetailsAction.edit),
              icon: const Icon(Icons.edit_outlined, size: 20),
              // The existing wording, including the ellipsis that tells a
              // user of a repeating event that a choice is coming.
              label: Text(recurring ? 'Edit…' : 'Edit Event'),
              style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
            ),
          ),
        ),
      if (capabilities.canDelete)
        Padding(
          padding: const EdgeInsets.only(top: CaleeSpacing.sm),
          child: SizedBox(
            width: double.infinity,
            child: TextButton.icon(
              key: kEventDetailsDeleteKey,
              onPressed: () =>
                  Navigator.of(context).pop(EventDetailsAction.delete),
              icon: const Icon(Icons.delete_outline, size: 20),
              label: Text(recurring ? 'Delete…' : 'Delete Event'),
              style: TextButton.styleFrom(
                foregroundColor: theme.colorScheme.error,
                minimumSize: const Size(48, 48),
              ),
            ),
          ),
        ),
      Padding(
        padding: EdgeInsets.only(top: hasMutation ? CaleeSpacing.sm : 0),
        child: EventShareAction(
          availability: capabilities.shareState.availability,
          shareTarget: capabilities.shareState.target,
          shareTitle: details.display.title,
          eventLinkService: eventLinkService,
          shareLauncher: shareLauncher,
          // The divider above already separates the action area.
          showSeparator: !hasMutation,
        ),
      ),
    ];
  }
}

class _Title extends StatelessWidget {
  const _Title({required this.title, required this.color});

  final String title;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ExcludeSemantics(
          child: Container(
            width: 4,
            height: 22,
            margin: const EdgeInsets.only(top: 3, right: CaleeSpacing.sm),
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
        ),
        Expanded(
          child: Semantics(
            header: true,
            child: Text(
              title,
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// One labelled line of event detail.
///
/// Shared with the signed-out details sheet so both read identically to a
/// screen reader: the icon is decorative and excluded, and the row is merged
/// into a single announcement.
class EventDetailRow extends StatelessWidget {
  const EventDetailRow({required this.icon, required this.label, super.key});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return MergeSemantics(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Decorative: the text beside it already says everything a screen
            // reader needs.
            ExcludeSemantics(
              child: Icon(
                icon,
                size: 18,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(width: CaleeSpacing.sm),
            Expanded(child: Text(label, style: theme.textTheme.bodyMedium)),
          ],
        ),
      ),
    );
  }
}
