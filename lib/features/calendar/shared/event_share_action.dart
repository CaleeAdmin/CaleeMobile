/// The ONE public Event Link share control, and the values it needs.
///
/// Extracted from `local_event_details_sheet.dart` under
/// CaleeAdmin/CaleeMobile#566 so the signed-out details sheet and the
/// signed-in [EventDetailsSheet] present the SAME share action rather than
/// two implementations that have to be kept in step. Nothing about the
/// behaviour changed in the move: the synchronous single-attempt claim, the
/// iPad popover anchor captured before the mint await, the inline retryable
/// failure and the "sheet dismissed mid-mint" guard are the same code that
/// shipped with CaleeAdmin/CaleeMobile#562, and the same keys identify it.
///
/// This widget decides NOTHING about eligibility. It is handed an
/// [LocalEventShareAvailability] and, when available, the exact
/// [LocalEventShareTarget] to mint — so a source that must never be shared
/// cannot reach a request from here by any route.
library;

import 'package:flutter/material.dart';

import '../../../ui/calee_design.dart';
import '../../local_subscriber/calee_public_calendar_source.dart';
import '../../local_subscriber/local_event_link_service.dart';
import '../../local_subscriber/local_event_share_launcher.dart';

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
/// Assembled by the calling page from the canonical identity BEFORE the sheet
/// opens, so no sheet ever touches a source event and none can reach for the
/// wrong field: there is no display recurrence id and no local UI id in here
/// to pick up by mistake.
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

/// Renders nothing at all for [LocalEventShareAvailability.unsupportedSource].
///
/// Sharing is not a property of that kind of calendar that happens to be
/// switched off, so the surrounding sheet says nothing about it.
class EventShareAction extends StatefulWidget {
  const EventShareAction({
    required this.availability,
    required this.shareTitle,
    required this.eventLinkService,
    required this.shareLauncher,
    this.shareTarget,
    this.showSeparator = true,
    super.key,
  });

  final LocalEventShareAvailability availability;

  /// The event title handed to the OS share sheet alongside the link. Never
  /// sent to the mint endpoint.
  final String shareTitle;

  final LocalEventLinkService eventLinkService;
  final LocalEventShareLauncher shareLauncher;

  /// Non-null exactly when [availability] is
  /// [LocalEventShareAvailability.available].
  final LocalEventShareTarget? shareTarget;

  /// Whether to draw the divider that separates this action from the details
  /// above it. Off when the host already drew one for its own actions.
  final bool showSeparator;

  @override
  State<EventShareAction> createState() => _EventShareActionState();
}

class _EventShareActionState extends State<EventShareAction> {
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
        title: widget.shareTitle,
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
    final children = _buildChildren(theme);
    if (children.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: children,
    );
  }

  List<Widget> _buildChildren(ThemeData theme) {
    switch (widget.availability) {
      case LocalEventShareAvailability.unsupportedSource:
        // Nothing at all. Sharing is not a property of this event that
        // happens to be off; it is not offered for this kind of calendar.
        return const [];

      case LocalEventShareAvailability.unavailableForEvent:
        return [
          if (widget.showSeparator) ...[
            const SizedBox(height: CaleeSpacing.md),
            const Divider(height: 1),
          ],
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
          if (widget.showSeparator) ...[
            const SizedBox(height: CaleeSpacing.md),
            const Divider(height: 1),
          ],
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
}
