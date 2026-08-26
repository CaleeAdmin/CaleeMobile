/// Read-only details for one event in a phone-only calendar subscription,
/// plus the signed-out Share action (CaleeAdmin/CaleeMobile#558).
///
/// Everything shown here is already on the screen behind it: title, date,
/// time, and which followed calendar the event came from. Nothing identifying
/// the SOURCE is displayed — not the `UID`, not the recurrence identity, not
/// the subscription or DAV URL, not the public calendar token, not the local
/// id. Those travel to CalEmbed inside the mint request and nowhere else.
///
/// There is no Edit and no Delete. A followed calendar is read-only on this
/// phone, and this sheet does not change that.
///
/// Under CaleeAdmin/CaleeMobile#566 the share control, the date/time wording
/// and the detail row moved into `features/calendar/shared/` so the signed-in
/// `EventDetailsSheet` presents the same occurrence the same way. This file
/// re-exports the share types it used to declare, so every existing importer
/// (and every existing test) keeps working unchanged.
library;

import 'package:flutter/material.dart';

import '../../ui/calee_design.dart';
import '../calendar/shared/calendar_display_event.dart';
import '../calendar/shared/event_detail_formatting.dart';
import '../calendar/shared/event_share_action.dart';
import '../calendar/widgets/event_details_sheet.dart';
import 'local_event_link_service.dart';
import 'local_event_share_launcher.dart';

export '../calendar/shared/event_share_action.dart'
    show
        EventShareAction,
        LocalEventShareAvailability,
        LocalEventShareTarget,
        kLocalEventShareAnchorKey,
        kLocalEventShareButtonKey,
        kLocalEventShareErrorKey,
        kLocalEventShareFailureMessage,
        kLocalEventShareSpinnerKey,
        kLocalEventShareUnavailableKey;

const Key kLocalEventDetailsSheetKey = Key('local_event_details_sheet');

class LocalEventDetailsSheet extends StatelessWidget {
  const LocalEventDetailsSheet({
    required this.event,
    required this.availability,
    required this.eventLinkService,
    required this.shareLauncher,
    this.shareTarget,
    this.use24h = true,
    super.key,
  });

  final CalendarDisplayEvent event;
  final LocalEventShareAvailability availability;
  final LocalEventLinkService eventLinkService;
  final LocalEventShareLauncher shareLauncher;

  /// Non-null exactly when [availability] is
  /// [LocalEventShareAvailability.available].
  final LocalEventShareTarget? shareTarget;

  final bool use24h;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return SafeArea(
      key: kLocalEventDetailsSheetKey,
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
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        width: 4,
                        height: 22,
                        margin: const EdgeInsets.only(
                          top: 3,
                          right: CaleeSpacing.sm,
                        ),
                        decoration: BoxDecoration(
                          color: event.color,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                      Expanded(
                        child: Text(
                          event.title,
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: CaleeSpacing.md),
                  EventDetailRow(
                    icon: Icons.event_outlined,
                    label: eventDetailDateLabel(event),
                  ),
                  EventDetailRow(
                    icon: Icons.schedule_outlined,
                    label: eventDetailTimeLabel(event, use24h: use24h),
                  ),
                  if (event.calendarName.trim().isNotEmpty)
                    EventDetailRow(
                      icon: Icons.calendar_today_outlined,
                      label: event.calendarName.trim(),
                    ),
                  EventShareAction(
                    availability: availability,
                    shareTarget: shareTarget,
                    shareTitle: event.title,
                    eventLinkService: eventLinkService,
                    shareLauncher: shareLauncher,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
