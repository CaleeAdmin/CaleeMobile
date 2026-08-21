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
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../../ui/calee_design.dart';
import '../calendar/shared/calendar_display_event.dart';
import 'calee_public_calendar_source.dart';
import 'local_event_link_service.dart';
import 'local_event_share_launcher.dart';

const Key kLocalEventDetailsSheetKey = Key('local_event_details_sheet');
const Key kLocalEventShareButtonKey = Key('local_event_share_button');
const Key kLocalEventShareUnavailableKey = Key('local_event_share_unavailable');
const Key kLocalEventShareErrorKey = Key('local_event_share_error');
const Key kLocalEventShareSpinnerKey = Key('local_event_share_button_spinner');

/// The rect handed to the platform as the iPad share-popover anchor.
const Key kLocalEventShareAnchorKey = Key('local_event_share_anchor');

/// Shown when the mint request, or the share sheet itself, did not work.
///
/// One wording for every cause. A 503, a dropped connection, a rejected
/// source and a malformed response are the same event from here: nothing the
/// user did is wrong, and the only useful next step is to try again.
const String kLocalEventShareFailureMessage =
    'Unable to share this event right now. Please try again.';

/// Why this event does or does not offer a Share action.
enum LocalEventShareAvailability {
  /// A registered public Calee source AND a portable canonical identity.
  available,

  /// A registered public Calee source, but this occurrence has no canonical
  /// identity another client could resolve — a recurring occurrence whose
  /// `RECURRENCE-ID` this contract refuses to guess at. Details still open;
  /// no link is invented for it.
  unavailableForEvent,

  /// Not an already-public Calee calendar: a private family feed, Google,
  /// Outlook, an arbitrary HTTPS `.ics`. V1 sharing does not cover these at
  /// all, so the sheet says nothing about sharing rather than implying this
  /// one event is the problem.
  unsupportedSource,
}

/// The complete set of values sent to the mint endpoint for one occurrence.
///
/// Assembled by the calendar page from `canonicalEventLinkIdentity()` before
/// the sheet opens, so the sheet never touches a `LocalCalendarEvent` and can
/// never reach for the wrong field: there is no display recurrence id and no
/// local UI id in here to pick up by mistake.
@immutable
class LocalEventShareTarget {
  const LocalEventShareTarget({
    required this.source,
    required this.uid,
    this.occurrenceId,
  });

  final CaleePublicCalendarSource source;

  /// The verbatim source `UID`.
  final String uid;

  /// The CANONICAL recurrence identity, or null for a one-off.
  final String? occurrenceId;
}

class LocalEventDetailsSheet extends StatefulWidget {
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
  State<LocalEventDetailsSheet> createState() => _LocalEventDetailsSheetState();
}

class _LocalEventDetailsSheetState extends State<LocalEventDetailsSheet> {
  /// The in-flight share attempt, or null when idle.
  ///
  /// A plain `bool` could not answer this honestly. The button is rebuilt
  /// disabled only on the frame AFTER the first tap, so two taps in one frame
  /// both reach the handler; and a late failure from an attempt the user has
  /// already superseded must not overwrite the current one's state. The claim
  /// is therefore an object taken SYNCHRONOUSLY before the first await, and
  /// every subsequent check is by identity.
  Object? _attempt;

  String? _error;

  final GlobalKey _shareAnchorKey = GlobalKey(debugLabel: 'shareAnchor');

  bool get _isSharing => _attempt != null;

  Future<void> _share() async {
    // Synchronous claim: a second tap in the same frame finds the slot taken
    // and returns, so one tap is one mint request and one share sheet.
    if (_attempt != null) return;
    final target = widget.shareTarget;
    if (target == null) return;

    final attempt = Object();
    setState(() {
      _attempt = attempt;
      _error = null;
    });

    // Read the anchor BEFORE the await. After it the button may have been
    // replaced by the spinner layout, and on iPad a stale or absent rect is
    // the difference between a popover and a rejected presentation.
    final origin = _shareOrigin();

    try {
      final url = await widget.eventLinkService.mint(
        source: target.source,
        uid: target.uid,
        occurrenceId: target.occurrenceId,
      );

      // The sheet may have been dismissed while the request was in flight, and
      // the user may have started a newer attempt. Either way this one is over:
      // no share sheet from a dead route, no setState on a disposed State.
      if (!mounted || !identical(_attempt, attempt)) return;

      await widget.shareLauncher.share(
        url: url,
        title: widget.event.title,
        sharePositionOrigin: origin,
      );
    } catch (_) {
      if (!mounted || !identical(_attempt, attempt)) return;
      // Shown inline, in the sheet the user is looking at — never as a
      // snackbar over whatever page happens to be underneath by now.
      setState(() => _error = kLocalEventShareFailureMessage);
    } finally {
      if (mounted && identical(_attempt, attempt)) {
        setState(() => _attempt = null);
      }
    }
  }

  /// The tapped button's rect, or a valid on-screen fallback if it has lost
  /// its geometry between the tap and this call.
  Rect _shareOrigin() {
    final box = _shareAnchorKey.currentContext?.findRenderObject();
    if (box is RenderBox && box.attached && box.hasSize) {
      return box.localToGlobal(Offset.zero) & box.size;
    }
    final size = MediaQuery.sizeOf(context);
    return Rect.fromCenter(
      center: Offset(size.width / 2, size.height / 2),
      width: 1,
      height: 1,
    );
  }

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
                          color: widget.event.color,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                      Expanded(
                        child: Text(
                          widget.event.title,
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: CaleeSpacing.md),
                  _DetailRow(
                    icon: Icons.event_outlined,
                    label: _dateLabel(widget.event.start),
                  ),
                  _DetailRow(
                    icon: Icons.schedule_outlined,
                    label: _timeLabel(),
                  ),
                  if (widget.event.calendarName.trim().isNotEmpty)
                    _DetailRow(
                      icon: Icons.calendar_today_outlined,
                      label: widget.event.calendarName.trim(),
                    ),
                  ..._buildShareSection(theme),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  List<Widget> _buildShareSection(ThemeData theme) {
    switch (widget.availability) {
      case LocalEventShareAvailability.unsupportedSource:
        // Nothing at all. Sharing is not a property of this event that
        // happens to be off; it is not offered for this kind of calendar.
        return const [];

      case LocalEventShareAvailability.unavailableForEvent:
        return [
          const SizedBox(height: CaleeSpacing.md),
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.only(top: CaleeSpacing.md),
            child: Text(
              "Sharing isn't available for this event.",
              key: kLocalEventShareUnavailableKey,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ];

      case LocalEventShareAvailability.available:
        return [
          const SizedBox(height: CaleeSpacing.md),
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.only(top: CaleeSpacing.md),
            child: KeyedSubtree(
              key: kLocalEventShareAnchorKey,
              child: SizedBox(
                // The anchor box wraps the button exactly, so the iPad popover
                // points at what the user actually touched. A widget carries
                // one key, so the geometry GlobalKey lives here and the button
                // keeps its own identifying key.
                key: _shareAnchorKey,
                width: double.infinity,
                child: FilledButton.icon(
                  key: kLocalEventShareButtonKey,
                  onPressed: _isSharing ? null : _share,
                  icon: _isSharing
                      ? const SizedBox(
                          key: kLocalEventShareSpinnerKey,
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.ios_share, size: 20),
                  label: const Text('Share event'),
                  style: FilledButton.styleFrom(
                    minimumSize: const Size(48, 48),
                  ),
                ),
              ),
            ),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: CaleeSpacing.sm),
              // A live region, so the failure is announced rather than
              // silently appearing under a button the user is still looking
              // at — the sheet keeps focus, so nothing else would say it.
              child: Semantics(
                liveRegion: true,
                child: Text(
                  _error!,
                  key: kLocalEventShareErrorKey,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.error,
                  ),
                ),
              ),
            ),
        ];
    }
  }

  String _timeLabel() {
    if (widget.event.allDay) return 'All day';
    final end = widget.event.end;
    if (end == null) return _clock(widget.event.start);
    return '${_clock(widget.event.start)}–${_clock(end)}';
  }

  String _clock(DateTime dt) {
    if (widget.use24h) {
      return '${_two(dt.hour)}:${_two(dt.minute)}';
    }
    final h12 = dt.hour % 12 == 0 ? 12 : dt.hour % 12;
    final period = dt.hour < 12 ? 'AM' : 'PM';
    if (dt.minute == 0) return '$h12 $period';
    return '$h12:${_two(dt.minute)} $period';
  }
}

String _two(int value) => value.toString().padLeft(2, '0');

const List<String> _kMonthNames = [
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

const List<String> _kFullDayNames = [
  'Sunday',
  'Monday',
  'Tuesday',
  'Wednesday',
  'Thursday',
  'Friday',
  'Saturday',
];

String _dateLabel(DateTime day) =>
    '${_kFullDayNames[day.weekday % 7]} ${day.day} '
    '${_kMonthNames[day.month - 1]} ${day.year}';

class _DetailRow extends StatelessWidget {
  const _DetailRow({required this.icon, required this.label});

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
