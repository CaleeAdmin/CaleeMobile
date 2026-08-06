import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:open_filex/open_filex.dart';
import 'package:share_plus/share_plus.dart';

import '../../../data/api/calee_hub_client.dart';
import '../../../data/models/client_calendar.dart';
import '../../../ui/calee_design.dart';
import '../attachment_cache_manager.dart';
import '../attachment_error_policy.dart';
import '../attachment_upload_staging_manager.dart';
import '../attachment_upload_status.dart';
import '../pending_attachment_upload.dart';

enum _AttachmentSource { camera, gallery, file }

/// Shown whenever a staged file is gone: at the pre-send check, on a retry,
/// and if the filesystem gives way mid-upload. One wording, because it is
/// one situation, and the only thing the user can do about it is pick the
/// file again.
const _kStagedFileGoneMessage =
    'This file is no longer available. Choose it again.';

/// One attempt to send one [PendingAttachmentUpload]: the exclusive right to
/// preflight it and then upload it.
///
/// It exists because "is an upload running?" could not be answered honestly
/// during preflight. `_sendPendingUpload` verifies the staged file before it
/// builds a request, and across that await `_isUploading` was still false,
/// no other flag was set, and an initial `selected` operation shows no
/// pending row -- so Add stayed enabled, Retry stayed tappable, and a second
/// invocation could enter the same window. Whichever one arrived second then
/// uploaded a discarded or superseded operation, competed over
/// `_uploadCancelToken`, and let one invocation's terminal state overwrite
/// another's.
///
/// The claim is a single slot ([_EventAttachmentsSectionState._uploadAttempt])
/// taken SYNCHRONOUSLY before the first await and held until the invocation
/// that took it returns -- through preflight, through the transfer, and
/// through the settlement that follows a failure. Every check is by object
/// identity, never by a boolean, so a stale invocation can only ever release
/// or clear the attempt it owns itself.
class _UploadAttempt {
  _UploadAttempt(this.operation);

  /// The operation this attempt was claimed for. An attempt is void the
  /// moment this stops being the section's current pending operation --
  /// which is exactly what Discard and editor-close do.
  final PendingAttachmentUpload operation;
}

/// Why the attachment list could not be loaded, in the only terms the UI
/// needs: what to say, and whether anything the user does from here can
/// change the answer.
///
/// The section used to catch every load failure as a bare `Object` and give
/// all of them the same "Could not load attachments / Tap to try again" row.
/// That was wrong in both directions. An unsupported calendar and a deleted
/// event cannot be fixed by tapping, so inviting a retry is a lie -- and
/// worse, Add stayed enabled, so the user could pick a file for an event
/// that would reject every upload. A dropped connection, meanwhile, really
/// is worth another tap and must not disable anything.
@immutable
class _AttachmentLoadFailure {
  const _AttachmentLoadFailure({
    required this.title,
    required this.subtitle,
    required this.canRetry,
    required this.blocksMutations,
  });

  final String title;
  final String? subtitle;

  /// Whether tapping the row could plausibly produce a different result.
  final bool canRetry;

  /// Whether the failure means no attachment may be CHANGED on this event
  /// at all -- adding, retrying an upload, or removing. True only for the
  /// terminal calendar/event/session failures.
  ///
  /// Named for mutations rather than for Add, which is what it used to say
  /// and what it used to do. Add was gated on it and Remove was not, so
  /// after an expired session or a deleted event the user could still tap
  /// the delete control on an existing row and send a DELETE that could
  /// only fail -- or, worse, succeed against something the section could no
  /// longer read. Every server mutation is one decision, and this is it.
  ///
  /// Read-only actions are deliberately NOT covered: viewing filenames,
  /// opening, downloading and sharing an attachment already listed remain
  /// available, because a list that loaded before the failure is still an
  /// accurate list of what is attached.
  final bool blocksMutations;
}

/// Where the attachment list stands, as one value rather than as an
/// inference over `_attachments == null`.
///
/// That nullable list was the whole state model, and it could not express
/// the difference between the two situations it was being asked about.
/// "Null" meant BOTH "the first request has not answered yet" and "there is
/// no list", and nothing at all distinguished "loading for the first time"
/// from "refreshing a list I already have". So the editor could show
///
///     Loading attachments…
///     Add attachment
///
/// with Add fully enabled -- because Add was gated on the calendar's
/// capabilities and the pending upload, never on whether the list had come
/// back. Tapping it opened the picker, staged the file, and started an
/// upload against an event whose attachments were still unknown; the screen
/// could then show a spinner and a failed upload for the same event at the
/// same time, which is not a state that means anything.
///
/// Three fields, from which every question the section asks is derived:
///
///  * [baseline] -- the last list Hub actually returned. Non-null is the
///    definition of "a successful list result exists", and an EMPTY list is
///    a perfectly good one: an event with no attachments is a fact, not a
///    missing answer.
///  * [isRequestActive] -- a list request owns the section right now.
///    Combined with [baseline] this separates initial loading from
///    refreshing without a second flag that could disagree with it.
///  * [failure] -- how the last request ended, when it failed. Kept
///    ALONGSIDE [baseline] rather than instead of it, which is what lets a
///    failed refresh report itself without discarding a list that is still
///    perfectly valid.
@immutable
class _AttachmentListState {
  const _AttachmentListState({
    this.baseline,
    this.isRequestActive = false,
    this.failure,
  });

  /// Nothing loaded, nothing running, nothing failed: the state the section
  /// is in for the instant between construction and its first request.
  static const initial = _AttachmentListState();

  final List<CalendarAttachment>? baseline;
  final bool isRequestActive;
  final _AttachmentLoadFailure? failure;

  /// A list request has succeeded at least once.
  bool get hasBaseline => baseline != null;

  /// The first request is in flight -- no list has ever landed. This is the
  /// only state that shows the "Loading attachments…" row; a later request
  /// over an existing list is deliberately NOT a loading state, because the
  /// rows the user is reading stay visible through it.
  bool get isInitialLoading => isRequestActive && !hasBaseline;

  /// A RECOVERABLE refresh failed over a list that is still on screen --
  /// which is a different sentence to the user than a load failing: their
  /// attachments are not gone, this view may just be a moment out of date.
  ///
  /// Deliberately excludes terminal failures. "Could not refresh
  /// attachments" would be a poor way to say that the calendar no longer
  /// supports attachments, that the event has been deleted, or that the
  /// session has expired -- those keep their own wording whether or not a
  /// baseline happens to be on screen, because they are not about this
  /// request being out of date.
  bool get hasRecoverableRefreshFailure =>
      hasBaseline && failure != null && failure!.canRetry;

  /// These four -- [hasBaseline], [isRequestActive], [isInitialLoading] and
  /// [failure] (with its own `canRetry`) -- separate every state this section
  /// has to act differently in, with no state expressible two ways:
  ///
  ///   idle, nothing loaded    !hasBaseline && !isRequestActive && no failure
  ///   initial loading         isInitialLoading
  ///   baseline loaded          hasBaseline && !isRequestActive
  ///   refreshing a baseline    hasBaseline &&  isRequestActive
  ///   retryable initial fail  !hasBaseline && failure!.canRetry
  ///   terminal failure         failure != null && !failure!.canRetry

  /// The single answer to "may the user choose a file right now?".
  ///
  /// Every clause earns its place:
  ///  * [hasBaseline] -- the defect this exists to close. No file may be
  ///    selected for an event whose attachments have never been read.
  ///  * `!isRequestActive` -- including during a refresh. An upload started
  ///    against a list that is being replaced would be racing the very
  ///    answer that decides whether it is allowed (limits, capability).
  ///  * `!failure.blocksMutations` -- an unsupported calendar or a missing event
  ///    is terminal whether or not a baseline was loaded first.
  bool get allowsAdd =>
      hasBaseline && !isRequestActive && !(failure?.blocksMutations ?? false);

  /// Entering a request. A previous failure is cleared here so a stale
  /// error row cannot sit under a live spinner; [baseline] is deliberately
  /// KEPT, which is what makes a refresh non-destructive.
  _AttachmentListState starting() =>
      _AttachmentListState(baseline: baseline, isRequestActive: true);

  /// A request succeeded. Replaces the baseline wholesale (including with
  /// an empty list) and clears any failure.
  _AttachmentListState withBaseline(List<CalendarAttachment> attachments) =>
      _AttachmentListState(baseline: attachments, isRequestActive: false);

  /// A request failed. The previous baseline -- if there was one -- SURVIVES
  /// this: a background refresh that could not reach Hub says nothing about
  /// the attachments the user is already looking at, and blanking them
  /// would destroy known-good information to report a transient failure.
  _AttachmentListState withFailure(_AttachmentLoadFailure failure) =>
      _AttachmentListState(
        baseline: baseline,
        isRequestActive: false,
        failure: failure,
      );

  /// The list after an operation whose result Hub has CONFIRMED: an upload
  /// that completed, or a detach that returned the event's new list.
  ///
  /// This is the newest truth there is, so it displaces everything the
  /// section previously believed:
  ///
  ///  * the baseline is replaced, obviously;
  ///  * [isRequestActive] goes false, because the caller disowns whatever
  ///    list request was in flight at the same moment (see
  ///    `_applyAuthoritativeAttachments`). A refresh that started before
  ///    this mutation was reading older server state, and letting it land
  ///    afterwards would make a just-uploaded attachment vanish or a
  ///    just-detached one come back;
  ///  * [failure] is CLEARED. It used to be carried over, so a refresh that
  ///    had failed a moment earlier left "Could not refresh attachments" on
  ///    screen above a list that had just been confirmed by the server --
  ///    an error about information that is no longer the information being
  ///    shown.
  _AttachmentListState withAuthoritativeAttachments(
    List<CalendarAttachment> attachments,
  ) => _AttachmentListState(baseline: attachments);
}

/// What the attachments section is currently doing, as far as anything
/// outside it needs to care.
///
/// Three booleans, not an inference over unrelated flags: the editor above
/// has to decide whether closing right now would destroy work, and "is a
/// spinner visible somewhere" is not that question. They are kept apart
/// because the honest answer to "may I close?" differs for each:
///
///  * [hasActiveTransfer] -- bytes are moving under a cancel token, so the
///    editor may offer to cancel and close.
///  * [hasActiveAction] -- an attachment action is running that has no
///    cancellation mechanism at all (the platform viewer opening, the
///    native share sheet, a detach request already sent). The editor must
///    wait for it, and must NOT offer to cancel something it cannot.
///  * [hasUnresolvedUpload] -- an upload exists whose outcome nobody knows
///    yet, which is the case that silently loses a user's document if the
///    screen simply disappears. Only the user resolves it, by retrying or
///    discarding.
@immutable
class AttachmentOperationState {
  const AttachmentOperationState({
    required this.hasActiveTransfer,
    required this.hasActiveAction,
    required this.hasUnresolvedUpload,
  });

  /// Nothing in flight and nothing owed to the user.
  static const idle = AttachmentOperationState(
    hasActiveTransfer: false,
    hasActiveAction: false,
    hasUnresolvedUpload: false,
  );

  /// An upload is sending bytes, or a download backing an open/share is
  /// receiving them. Cancellable through the transfer tokens.
  final bool hasActiveTransfer;

  /// An attachment action is running that cannot be cancelled: opening a
  /// downloaded file in the platform viewer, the native share sheet, or a
  /// detach request that has already left. It can only be waited out.
  final bool hasActiveAction;

  /// An upload operation is neither finished nor abandoned -- retryable,
  /// reconciling, or cancelled with an uncertain server-side outcome.
  final bool hasUnresolvedUpload;

  bool get blocksEditorClose =>
      hasActiveTransfer || hasActiveAction || hasUnresolvedUpload;

  @override
  bool operator ==(Object other) =>
      other is AttachmentOperationState &&
      other.hasActiveTransfer == hasActiveTransfer &&
      other.hasActiveAction == hasActiveAction &&
      other.hasUnresolvedUpload == hasUnresolvedUpload;

  @override
  int get hashCode =>
      Object.hash(hasActiveTransfer, hasActiveAction, hasUnresolvedUpload);

  @override
  String toString() =>
      'AttachmentOperationState(hasActiveTransfer: $hasActiveTransfer, '
      'hasActiveAction: $hasActiveAction, '
      'hasUnresolvedUpload: $hasUnresolvedUpload)';
}

/// The two things an owning editor needs to be able to ask of an
/// [EventAttachmentsSection] when the user tries to close it.
///
/// Deliberately tiny: it holds no state, rebuilds nothing, and is not a
/// general-purpose controller. The section binds itself on init and unbinds
/// on dispose, so calling either method after the section is gone is a
/// no-op rather than an error.
class EventAttachmentsController {
  /// The section State object that currently owns this controller.
  ///
  /// Ownership is tracked by this token rather than by comparing the bound
  /// callbacks: those are instance-method tear-offs, and Dart does not
  /// promise that two tear-offs of the same method are identical objects.
  /// A comparison that happened to fail would leave the controller bound to
  /// a disposed section -- exactly the case unbinding exists to prevent.
  Object? _owner;
  Future<void> Function()? _cancelActiveTransfers;
  VoidCallback? _discardUnresolvedUpload;

  /// True while an [EventAttachmentsSection] is mounted and bound to this
  /// controller.
  bool get isAttached => _owner != null;

  /// Cancels the in-flight uploads and downloads -- the work that HAS a
  /// cancel token -- and completes once they have unwound (or a short grace
  /// period has passed), so the caller never acts on top of a still-spinning
  /// transfer.
  ///
  /// Does not shut the section down. It is typically called as part of
  /// closing an editor, but the caller may well stay open afterwards: an
  /// open, share or remove has no cancellation mechanism and may still be
  /// finishing. The section is fully usable again once this returns --
  /// adding, retrying, opening, sharing and removing all work as normal.
  Future<void> cancelActiveTransfers() async {
    final cancel = _cancelActiveTransfers;
    if (cancel != null) await cancel();
  }

  /// Abandons an unresolved upload: invalidates its status poll and clears
  /// it, so no late callback can restore it afterwards.
  void discardUnresolvedUpload() => _discardUnresolvedUpload?.call();

  void _bind({
    required Object owner,
    required Future<void> Function() cancelActiveTransfers,
    required VoidCallback discardUnresolvedUpload,
  }) {
    _owner = owner;
    _cancelActiveTransfers = cancelActiveTransfers;
    _discardUnresolvedUpload = discardUnresolvedUpload;
  }

  /// Unbinds only if [owner] is still the current owner, so a section that
  /// has already handed the controller to its replacement (the new section
  /// binds before the old one disposes) does not tear down the new
  /// binding on its way out.
  void _unbind(Object owner) {
    if (!identical(_owner, owner)) return;
    _owner = null;
    _cancelActiveTransfers = null;
    _discardUnresolvedUpload = null;
  }
}

/// The outcome of asking the operating system for a file.
///
/// Exactly three cases, kept apart on purpose: the user backing out is
/// silent, a file that cannot be used is a message, and a usable file is a
/// file plus the name the user knows it by plus its verified size. The old
/// code collapsed "no path" and "unreadable" into the cancellation branch,
/// so a picked-but-unusable file looked to the user exactly like having
/// changed their mind.
sealed class _AttachmentPickResult {
  const _AttachmentPickResult();
}

class _AttachmentReady extends _AttachmentPickResult {
  const _AttachmentReady({
    required this.file,
    required this.originalFilename,
    required this.size,
  });

  final File file;
  final String originalFilename;
  final int size;
}

class _AttachmentPickCancelled extends _AttachmentPickResult {
  const _AttachmentPickCancelled();
}

class _AttachmentPickFailed extends _AttachmentPickResult {
  const _AttachmentPickFailed(this.message);

  /// Already user-facing Calee wording; raw platform text never reaches it.
  final String message;
}

/// Attachments section for the event editor (and, unchanged, for viewing a
/// recurring event's occurrence). Hidden entirely when there's nothing to
/// show and nothing the caller can do (no attachments, [canAdd] false);
/// otherwise always visible, even with zero attachments, so an "Add
/// attachment" affordance stays reachable.
class EventAttachmentsSection extends StatefulWidget {
  const EventAttachmentsSection({
    required this.eventId,
    required this.calendarId,
    required this.hubClient,
    required this.accessToken,
    required this.canAdd,
    required this.canRemove,
    required this.isSeriesScoped,
    this.openFile = OpenFilex.open,
    this.cacheManager,
    this.stagingManager,
    this.statusPollSchedule,
    this.onOperationStateChanged,
    this.controller,
    super.key,
  });

  final String eventId;

  /// The calendar THIS EVENT belongs to, sent with every attachment
  /// operation so Hub can go straight to it instead of searching the
  /// account's calendars for the event's UID.
  ///
  /// It must be the event's own `calendarId`, not whichever calendar the
  /// editor currently has selected. Those are the same value right up until
  /// the user picks a different calendar in the middle of editing -- at
  /// which point the selection describes where the event is being MOVED TO,
  /// while its attachments still live where the event actually is. Sending
  /// the selection would point every attachment call at a calendar the
  /// event is not in yet, and the honest answer to that is "event not
  /// found".
  ///
  /// A locator only. Hub still derives what this account may see from the
  /// bearer token and the event id; this cannot grant access to anything,
  /// and a value that does not resolve fails closed rather than widening
  /// the search.
  final String calendarId;

  final CaleeHubClient hubClient;
  final String accessToken;
  final bool canAdd;
  final bool canRemove;

  /// True when the caller is viewing this section from an occurrence
  /// context (a single occurrence of a recurring event) -- attachments
  /// always belong to the whole series, so add/remove are disabled
  /// regardless of [canAdd]/[canRemove] and an explanatory footer is shown,
  /// but existing attachments are still listed and still downloadable.
  final bool isSeriesScoped;

  /// Opens a downloaded attachment with the platform's default viewer.
  /// Injected (like [hubClient]) rather than calling OpenFilex.open()
  /// directly, since -- unlike image_picker/path_provider -- open_filex has
  /// no platform-interface testing seam, and its non-mobile fallback spawns
  /// a real OS process (e.g. `xdg-open` on Linux), which is unsafe to run
  /// for real in a test/CI environment.
  final Future<OpenResult> Function(String path) openFile;

  /// Owns the on-disk lifecycle of downloaded copies. Injected so tests can
  /// supply a temp-directory provider instead of path_provider's platform
  /// channel; defaults to a manager backed by the real application cache
  /// directory.
  final AttachmentCacheManager? cacheManager;

  /// Owns the on-disk lifecycle of the file going the other way: the picker
  /// selection copied into Calee-controlled storage before it is uploaded.
  /// Deliberately a separate manager from [cacheManager] -- see
  /// [AttachmentUploadStagingManager] for why downloaded copies and staged
  /// uploads cannot share one lifecycle. Injected on the same terms, for the
  /// same reason.
  final AttachmentUploadStagingManager? stagingManager;

  /// The status-polling schedule, as the wait BEFORE each attempt:
  ///
  ///   attempt 1 immediately, then waits of 1s, 2s and 4s before attempts
  ///   2, 3 and 4. Four requests in total, ~7s of waiting.
  ///
  /// Expressed this way on purpose. The list used to be `[1s, 2s, 4s, 8s]`
  /// read as "the backoff AFTER attempt n", which meant the first attempt
  /// fired immediately and the loop broke out after the fourth -- so the 8s
  /// entry was never used, and the documented schedule described a delay that
  /// did not exist. One entry per attempt, holding that attempt's own wait,
  /// cannot drift from the behavior that way: every entry is consumed, and
  /// the number of entries IS the number of requests.
  ///
  /// Bounded on purpose, too. An operation Hub is still working on can
  /// legitimately hold its lease for minutes, and polling until it resolves
  /// would either spin forever or pin the UI on a spinner the user cannot
  /// escape. After the last attempt the operation is simply left in an honest
  /// unresolved state with Retry and Discard available -- the user is told
  /// what is known, not shown a guess.
  static const List<Duration> defaultStatusPollSchedule = [
    Duration.zero,
    Duration(seconds: 1),
    Duration(seconds: 2),
    Duration(seconds: 4),
  ];

  /// Overrides [defaultStatusPollSchedule]. Injected only so tests can drive
  /// the bounded-polling behavior without waiting the real schedule out.
  @visibleForTesting
  final List<Duration>? statusPollSchedule;

  /// Reports whether an attachment operation is in flight or unresolved,
  /// whenever that answer changes (and once more, as
  /// [AttachmentOperationState.idle], when this section is disposed).
  ///
  /// The owning editor cannot see any of this from the outside, and used to
  /// close over the top of it. Redundant notifications are suppressed: only
  /// an effective change is reported.
  final ValueChanged<AttachmentOperationState>? onOperationStateChanged;

  /// Lets the owning editor cancel in-flight transfers and discard an
  /// unresolved upload as part of its own close policy.
  final EventAttachmentsController? controller;

  @override
  State<EventAttachmentsSection> createState() =>
      _EventAttachmentsSectionState();
}

class _EventAttachmentsSectionState extends State<EventAttachmentsSection> {
  _AttachmentListState _listState = _AttachmentListState.initial;

  /// Identifies the list request that currently speaks for this section.
  ///
  /// Bumped whenever a running request is DISOWNED -- by disposal, or by the
  /// section being rebuilt for a different event or calendar. Every
  /// completion re-checks its own generation before it writes anything, so
  /// a response that was asked for on behalf of a previous event cannot
  /// land in the list of the current one, and a response that arrives after
  /// this screen is gone cannot call setState at all.
  ///
  /// A counter, not a timer: nothing here waits a plausible interval and
  /// hopes. Whether a result is stale is decided by whether the section
  /// still wants it, which is knowable exactly.
  int _listGeneration = 0;

  /// True while a list request owns the section. This is the single-flight
  /// lock, and it is the reason two Retry taps produce one request rather
  /// than two: the second call returns before it can start anything.
  ///
  /// Distinct from [_AttachmentListState.isRequestActive], which is what
  /// the UI renders. This is the lock; that is the picture.
  bool _listRequestInFlight = false;

  bool _isUploading = false;
  double? _uploadProgress;
  AttachmentTransferCancelToken? _uploadCancelToken;
  final Set<String> _busyAttachmentIds = {};
  late final AttachmentCacheManager _cache =
      widget.cacheManager ?? AttachmentCacheManager();
  late final AttachmentUploadStagingManager _staging =
      widget.stagingManager ?? AttachmentUploadStagingManager();

  /// One cancel token per in-flight download, keyed by attachment ID, so
  /// several attachments can be opened or shared at once and each stays
  /// individually cancellable. Entries are removed in the download's
  /// `finally`, so the map is exactly the set of live downloads.
  final Map<String, AttachmentTransferCancelToken> _downloadTokens = {};

  /// Set when this section is being PERMANENTLY torn down, and never
  /// cleared. Only [dispose] sets it.
  bool _closing = false;

  /// True only while [_cancelActiveTransfersAndSettle] is stopping the
  /// current transfers and waiting for them to unwind.
  ///
  /// Transient on purpose. Cancelling transfers used to be the last thing
  /// that ever happened to this section, so it could safely mark itself
  /// closed -- but the editor above may now stay open after cancelling (an
  /// open or share that cannot be cancelled is still finishing), and a
  /// section stuck in teardown mode would silently refuse every later Add,
  /// Retry, Open, Share and Remove while looking perfectly usable.
  bool _cancellingTransfers = false;

  bool _disposed = false;

  /// The single condition for "do not START anything new right now" --
  /// permanently gone, temporarily cancelling, or already disposed.
  ///
  /// Deliberately distinct from [_closing] alone: work already running is
  /// not affected by this, and once a temporary cancellation ends the
  /// section is fully usable again.
  bool get _stoppingAttachmentWork =>
      _closing || _cancellingTransfers || _disposed;

  /// The last state handed to [EventAttachmentsSection.onOperationStateChanged],
  /// so an unchanged state is not re-reported.
  AttachmentOperationState _reportedOperationState =
      AttachmentOperationState.idle;

  /// Completed once every active transfer has stopped. Only created while
  /// somebody is waiting (the editor's "cancel attachment and close" path).
  Completer<void>? _transfersSettled;

  /// The current logical upload operation, if any. Survives timeouts and
  /// retries so the SAME idempotency key is reused -- see
  /// [PendingAttachmentUpload].
  PendingAttachmentUpload? _pendingUpload;

  /// The one attempt currently allowed to send [_pendingUpload], or null when
  /// no send is in progress. See [_UploadAttempt] for what this fixes.
  ///
  /// Non-null covers the WHOLE of a send, not just the transfer: the
  /// preflight before any bytes move, the transfer itself, and the
  /// settlement afterwards (a failure is handled across awaits, during which
  /// `_isUploading` is already false). A second send is refused for all of
  /// it, which is what makes a stale invocation's `finally` structurally
  /// unable to clear a newer attempt's state -- a newer attempt cannot exist
  /// yet.
  _UploadAttempt? _uploadAttempt;

  /// True while any attempt owns the pending operation. Add and Retry are
  /// both inert while this holds.
  bool get _uploadAttemptInProgress => _uploadAttempt != null;

  /// Set when Hub says attachments are unsupported for this calendar.
  bool _attachmentsDisabled = false;

  /// THE gate for every attachment change that reaches Hub: adding a file,
  /// retrying a pending upload, and removing an existing attachment.
  ///
  /// One decision, because they are one question -- "can a change to this
  /// event's attachments succeed right now?" -- and answering it in three
  /// places is what let them disagree. Add was gated on the list's terminal
  /// failures; Remove was gated on `canRemove && !isSeriesScoped` alone. So
  /// after a final 401, an unsupported calendar or a deleted event, the Add
  /// row correctly went away while the delete control on every existing row
  /// stayed live, and tapping it sent a DELETE for an event the section had
  /// just been told it could not read.
  ///
  /// False when any of these hold:
  ///
  ///  * the list failed terminally -- expired session,
  ///    ATTACHMENTS_NOT_SUPPORTED_FOR_CALENDAR, EVENT_NOT_FOUND, or any
  ///    other failure the policy classifies as `blocksMutations`;
  ///  * Hub has told us this calendar does not support attachments at all;
  ///  * this is an occurrence-scoped view, where attachments belong to the
  ///    series and neither add nor remove applies;
  ///  * a teardown or transfer cancellation is under way.
  ///
  /// Deliberately NOT false for a transient refresh failure over a good
  /// baseline: a dropped connection says nothing about whether the event
  /// can be changed, and `canRetry` failures leave `blocksMutations` false
  /// precisely so a network hiccup cannot lock the section.
  ///
  /// Read-only actions are outside this entirely. Viewing a filename,
  /// opening, downloading and sharing stay available through all of the
  /// above, because a list that loaded before the failure is still an
  /// accurate list of what is attached.
  bool get _serverMutationsAllowed =>
      !widget.isSeriesScoped &&
      !_attachmentsDisabled &&
      !(_listState.failure?.blocksMutations ?? false) &&
      !_stoppingAttachmentWork;

  /// Whether attaching a file to THIS EVENT is possible in principle: the
  /// mutation gate, plus the calendar's own add capability.
  ///
  /// Says nothing about whether it may happen right NOW -- that is
  /// [_effectiveCanAdd].
  bool get _canAddCapability => _serverMutationsAllowed && widget.canAdd;

  /// Whether "Add attachment" may be used AT ALL right now.
  ///
  /// [_AttachmentListState.allowsAdd] is the clause the original defect was
  /// about: nothing may be attached to an event whose attachment list has
  /// never successfully loaded, and nothing may be started while a list
  /// request is in flight.
  bool get _effectiveCanAdd => _canAddCapability && _listState.allowsAdd;

  /// Whether the Add row is tappable.
  ///
  /// [_effectiveCanAdd] answers "is attaching allowed at all right now";
  /// the rest is about work this section is already doing -- a transfer in
  /// progress, an attempt holding the pending operation (the preflight
  /// window a second tap used to slip through), or an unresolved upload the
  /// user must answer for first.
  ///
  /// Both this and the guards inside [_addAttachment] exist on purpose:
  /// this one is for taps, those are for races and programmatic calls.
  bool get _addRowEnabled =>
      _effectiveCanAdd &&
      !_isUploading &&
      !_uploadAttemptInProgress &&
      !_pendingUploadNeedsAction;

  /// Whether an existing attachment may be removed. Same gate as Add, plus
  /// the calendar's own remove capability -- a detach is a server mutation
  /// like any other.
  bool get _effectiveCanRemove => _serverMutationsAllowed && widget.canRemove;

  /// True when a pending upload is waiting on the user to retry or discard
  /// it. Deliberately excludes states the app is still resolving on its
  /// own, and states that are already finished.
  bool get _pendingUploadNeedsAction {
    final pending = _pendingUpload;
    return pending != null && pending.canRetryWithSameKey;
  }

  @override
  void initState() {
    super.initState();
    widget.controller?._bind(
      owner: this,
      cancelActiveTransfers: _cancelActiveTransfersAndSettle,
      discardUnresolvedUpload: _discardPendingUpload,
    );
    _load();
  }

  @override
  void didUpdateWidget(EventAttachmentsSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.controller, widget.controller)) {
      oldWidget.controller?._unbind(this);
      widget.controller?._bind(
        owner: this,
        cancelActiveTransfers: _cancelActiveTransfersAndSettle,
        discardUnresolvedUpload: _discardPendingUpload,
      );
    }

    // The section is now being shown for a DIFFERENT event, or for the same
    // event on a different calendar. Everything on screen describes the old
    // one, and so does any request still in flight for it.
    //
    // Disowning that request is the point. Without it, a slow list call for
    // the previous event could return after this one's has already
    // succeeded and overwrite it -- the user would be looking at one
    // event's attachments under another event's name, and Add would be
    // gated on a baseline that belongs to neither.
    if (oldWidget.eventId != widget.eventId ||
        oldWidget.calendarId != widget.calendarId) {
      _invalidateListRequest();
      setState(() {
        _listState = _AttachmentListState.initial;
        // A capability answer is a property of the calendar it came from,
        // so it does not carry over to a different one.
        _attachmentsDisabled = false;
      });
      _load();
    }
  }

  /// Disowns whatever list request is running, so its result can no longer
  /// be applied and a new one may start immediately.
  ///
  /// Releases the single-flight lock as well as bumping the generation: the
  /// disowned request's own `finally` is generation-guarded and will not
  /// touch the lock again, so leaving it held would refuse every later load
  /// for the lifetime of the section.
  void _invalidateListRequest() {
    _listGeneration++;
    _listRequestInFlight = false;
  }

  /// Adopts a list Hub has CONFIRMED -- the attachment an upload returned,
  /// or the list a detach returned -- as the section's new truth.
  ///
  /// The disown is the point, and it must happen in the same breath as the
  /// write. Without it:
  ///
  ///   1. a baseline is on screen;
  ///   2. a refresh starts, and reads the server's state as it was THEN;
  ///   3. an upload (or detach) completes, and its result is applied;
  ///   4. the refresh returns, still carrying the older state;
  ///   5. it overwrites the newer one.
  ///
  /// The user watches the attachment they just added disappear, or the one
  /// they just removed come back. Nothing about that is slow enough to be
  /// unlikely -- the upload and the refresh are both in flight together, and
  /// a list request that started first can easily finish second.
  ///
  /// Bumping the generation makes the in-flight request stale by definition,
  /// so its completion returns without touching state, and its `finally`
  /// (guarded on the same generation) cannot release the lock this method
  /// just cleared on behalf of whatever comes next. Serializing mutations
  /// against refreshes would also work, but would make an upload wait on a
  /// request whose answer it is about to supersede.
  void _applyAuthoritativeAttachments(List<CalendarAttachment> attachments) {
    _invalidateListRequest();
    _listState = _listState.withAuthoritativeAttachments(attachments);
  }

  /// Teardown, in the only order that closes the cache-lifecycle race:
  /// stop starting things, invalidate the reconciliation loop, cancel the
  /// transfers that are already running, then close the cache. A transfer
  /// that completes after all of that finds a closed manager and deletes
  /// its own target instead of repopulating a cache nobody owns any more.
  @override
  void dispose() {
    _closing = true;
    _disposed = true;
    // Stops any in-flight status poll from continuing past this screen: the
    // generation check runs before every attempt and before every setState.
    _pollGeneration++;
    // Same for the attachment list: a request still on the wire is disowned
    // here, so its completion finds a generation that has moved on and
    // returns without touching a disposed State.
    _invalidateListRequest();
    _cancelActiveTransferTokens();
    // Uncancellable actions (a viewer opening, the share sheet, a detach
    // already sent) are simply let go: nothing here can stop them, and this
    // screen no longer represents them. Clearing the set keeps the final
    // report below honestly idle.
    _busyAttachmentIds.clear();
    // Anyone awaiting "the transfers have stopped" is released here rather
    // than left holding a future this state object will never complete.
    _completeTransfersSettled();
    // Cached copies are only meant to live as long as the editor screen --
    // confidential family documents must not accumulate in the cache
    // directory across sessions. The staged upload, if any, goes with them:
    // this screen was the only thing that could ever have finished it, and
    // an editor closing is the end of the operation it belonged to.
    unawaited(_cache.close());
    unawaited(_staging.close());
    // Last word to the parent: whatever it was blocking on is over.
    widget.controller?._unbind(this);
    if (_reportedOperationState != AttachmentOperationState.idle) {
      widget.onOperationStateChanged?.call(AttachmentOperationState.idle);
      _reportedOperationState = AttachmentOperationState.idle;
    }
    super.dispose();
  }

  // ── Operation state ──────────────────────────────────────────────────────

  bool get _hasActiveTransfer => _isUploading || _downloadTokens.isNotEmpty;

  /// An open, share or remove is under way. Deliberately separate from
  /// [_hasActiveTransfer]: the download half of an open/share is
  /// cancellable, but the platform viewer, the native share sheet and a
  /// detach request already on the wire are not. Reporting these as
  /// "transfers" would let the editor promise a cancellation it has no way
  /// to perform.
  bool get _hasActiveAction => _busyAttachmentIds.isNotEmpty;

  /// An upload that is not currently sending bytes but is not finished
  /// either: retryable, reconciling, or cancelled with an unknown
  /// server-side outcome. Exactly the states a close would silently drop.
  bool get _hasUnresolvedUpload {
    final pending = _pendingUpload;
    return !_isUploading && pending != null && pending.isActive;
  }

  AttachmentOperationState get _operationState => AttachmentOperationState(
    hasActiveTransfer: _hasActiveTransfer,
    hasActiveAction: _hasActiveAction,
    hasUnresolvedUpload: _hasUnresolvedUpload,
  );

  /// Marks [attachmentId] as having an action running, and tells the parent.
  /// Open, share and remove all go through this pair rather than touching
  /// the set directly, so no path can change it without reporting.
  void _markAttachmentBusy(String attachmentId) {
    if (mounted) {
      setState(() => _busyAttachmentIds.add(attachmentId));
    } else {
      _busyAttachmentIds.add(attachmentId);
    }
    _notifyOperationState();
  }

  /// The counterpart of [_markAttachmentBusy]. Removes even when unmounted,
  /// so a failed or cancelled action can never leave an attachment marked
  /// busy for good.
  void _markAttachmentIdle(String attachmentId) {
    if (mounted) {
      setState(() => _busyAttachmentIds.remove(attachmentId));
    } else {
      _busyAttachmentIds.remove(attachmentId);
    }
    _notifyOperationState();
  }

  /// Reports the current state upward if -- and only if -- it differs from
  /// what was reported last. Called from every place that can change it,
  /// including the ones that run after disposal, which is why the disposed
  /// check lives here rather than at each call site.
  void _notifyOperationState() {
    if (!_hasActiveTransfer) _completeTransfersSettled();
    if (_disposed) return;
    final state = _operationState;
    if (state == _reportedOperationState) return;
    _reportedOperationState = state;
    widget.onOperationStateChanged?.call(state);
  }

  void _completeTransfersSettled() {
    final settled = _transfersSettled;
    _transfersSettled = null;
    if (settled != null && !settled.isCompleted) settled.complete();
  }

  /// Cancels the upload and every download. Idempotent: a cancelled token
  /// ignores further cancels, and tokens remove themselves from tracking in
  /// their own `finally`, so cancelling twice cannot double-free anything.
  void _cancelActiveTransferTokens() {
    _uploadCancelToken?.cancel();
    for (final token in _downloadTokens.values.toList()) {
      token.cancel();
    }
  }

  /// Stops the transfers that CAN be stopped, then waits for them to unwind
  /// so the caller is not left acting on top of a live one.
  ///
  /// Usually part of closing the editor, but deliberately not the same
  /// thing: an uncancellable open or share may still be finishing
  /// afterwards, in which case the editor stays open and this section must
  /// remain completely usable. So this marks a TEMPORARY state -- new work
  /// is refused only while the cancellation is in progress, and the flag is
  /// cleared however this returns (settled, timed out, or thrown).
  ///
  /// Bounded: a transfer that refuses to unwind must not trap the user in
  /// the editor; disposal cancels everything again regardless.
  Future<void> _cancelActiveTransfersAndSettle() async {
    if (_disposed) return;
    _setCancellingTransfers(true);
    try {
      _cancelActiveTransferTokens();
      if (!_hasActiveTransfer || _disposed) return;
      final settled = _transfersSettled ??= Completer<void>();
      await settled.future.timeout(
        const Duration(seconds: 5),
        onTimeout: () {
          if (kDebugMode) {
            debugPrint(
              'EventAttachmentsSection: transfers did not settle before close',
            );
          }
        },
      );
    } finally {
      // Never left set: the editor may be staying open, and the only other
      // way out of this section is dispose(), which sets _closing anyway.
      _setCancellingTransfers(false);
    }
  }

  /// Flips the transient flag and rebuilds, because the "Add attachment"
  /// row's enabled state reads it: while transfers are being cancelled the
  /// row must not be tappable at all, rather than relying on the guard
  /// inside the handler to swallow the tap afterwards.
  void _setCancellingTransfers(bool value) {
    if (_cancellingTransfers == value) return;
    if (mounted) {
      setState(() => _cancellingTransfers = value);
    } else {
      _cancellingTransfers = value;
    }
  }

  /// Loads (or reloads) the attachment list. The ONE entry point: initial
  /// load, Retry, and every post-operation refresh all come through here, so
  /// there is exactly one place that can start a list request.
  ///
  /// Single-flight, by returning early rather than by cancelling: a second
  /// call while one is running is not a different question, so the honest
  /// answer is the one already on its way. That is what makes two quick
  /// Retry taps produce one request -- and it matters beyond tidiness,
  /// because two overlapping requests could complete out of order and leave
  /// the older answer on screen.
  ///
  /// Nothing here waits a fixed interval or races a delay. Ownership is
  /// decided by [_listGeneration], which is exact.
  Future<void> _load() async {
    // A teardown or an in-progress transfer cancellation is not the moment
    // to start a request whose result nothing will be able to apply.
    if (_listRequestInFlight || _stoppingAttachmentWork || !mounted) return;

    final generation = _listGeneration;
    _listRequestInFlight = true;
    // Add goes inert for the duration of the request -- initial or refresh.
    setState(() => _listState = _listState.starting());

    try {
      final attachments = await widget.hubClient.listAttachments(
        accessToken: widget.accessToken,
        eventId: widget.eventId,
        calendarId: widget.calendarId,
      );
      // The generation check is what makes a stale result harmless: this
      // request no longer speaks for the section, so its answer -- however
      // successful -- is discarded rather than applied over a newer one.
      if (!mounted || generation != _listGeneration) return;
      setState(() => _listState = _listState.withBaseline(attachments));
    } catch (error) {
      _debugLogAttachmentFailure('list', error);
      if (!mounted || generation != _listGeneration) return;
      final failure = _classifyLoadFailure(error);
      setState(() {
        // Keeps any existing baseline: see _AttachmentListState.withFailure.
        _listState = _listState.withFailure(failure);
        // A calendar that does not support attachments is a property of the
        // calendar, not of this request -- it stays disabled until the
        // section is rebuilt for a different one.
        if (error is CaleeHubException &&
            error.code == 'ATTACHMENTS_NOT_SUPPORTED_FOR_CALENDAR') {
          _attachmentsDisabled = true;
        }
      });
    } finally {
      // Only the owning request releases the lock. A disowned one must not,
      // or it would unlock the section on behalf of the request that
      // replaced it.
      if (generation == _listGeneration) _listRequestInFlight = false;
    }
  }

  /// Turns a list failure into the row the user sees, and into whether Add
  /// survives it. See [_AttachmentLoadFailure] for why this is not one
  /// generic branch.
  ///
  /// The default is deliberately the forgiving one: an unrecognised failure
  /// keeps Retry, because refusing a retry over a code this build has never
  /// heard of is the worse mistake. It does NOT keep Add: with no
  /// successful list there is no baseline, and `_effectiveCanAdd` refuses
  /// on that alone regardless of what is decided here.
  static _AttachmentLoadFailure _classifyLoadFailure(Object error) {
    final failure = _classifyLoadFailureKind(error);
    final reference = error is CaleeHubException
        ? attachmentSupportReference(error)
        : null;
    if (reference == null) return failure;

    // On its own line, under whatever the row already said -- and only when
    // Hub actually sent an id, so no row ever reads "Reference: null".
    return _AttachmentLoadFailure(
      title: failure.title,
      subtitle: failure.subtitle == null
          ? 'Reference: $reference'
          : '${failure.subtitle}\nReference: $reference',
      canRetry: failure.canRetry,
      blocksMutations: failure.blocksMutations,
    );
  }

  static _AttachmentLoadFailure _classifyLoadFailureKind(Object error) {
    if (error is! CaleeHubException) {
      return const _AttachmentLoadFailure(
        title: 'Could not load attachments',
        subtitle: 'Tap to try again',
        canRetry: true,
        blocksMutations: false,
      );
    }

    switch (error.code) {
      case 'ATTACHMENTS_NOT_SUPPORTED_FOR_CALENDAR':
        // Tapping cannot change a calendar's capabilities, and adding is
        // guaranteed to be rejected the same way.
        return const _AttachmentLoadFailure(
          title: 'Attachments are not supported for this calendar.',
          subtitle: null,
          canRetry: false,
          blocksMutations: true,
        );

      case 'EVENT_NOT_FOUND':
        // The event is gone or this editor is holding a stale ID. Letting
        // the user choose a file for it would stage and queue an upload
        // that cannot land.
        return const _AttachmentLoadFailure(
          title: 'This event is no longer available.',
          subtitle: null,
          canRetry: false,
          blocksMutations: true,
        );

      case 'NETWORK_ERROR':
      case 'TIMEOUT':
        // Says nothing about the calendar or the event: capability is
        // untouched and Add stays available.
        return const _AttachmentLoadFailure(
          title: 'Could not load attachments',
          subtitle: 'Check your connection and tap to try again.',
          canRetry: true,
          blocksMutations: false,
        );
    }

    // CaleeHubClient has already refreshed the token and retried once by the
    // time a 401 reaches here, so this is a session the app cannot repair on
    // the user's behalf -- and that makes it TERMINAL for this section, not
    // retryable.
    //
    // It used to offer both a Retry and a live Add. Neither could work: the
    // retry re-sends the same request under the same dead session and comes
    // back 401 every time, and Add would let the user pick a file, stage it
    // and start an upload that is refused the same way -- with the staged
    // file then waiting on a Retry that also cannot succeed. Attaching
    // anything has to wait for the session to be repaired somewhere else.
    //
    // Existing rows are deliberately left alone: a baseline loaded before
    // the session expired is still an accurate list of what is attached, and
    // is worth reading even though nothing can be changed. Signing the user
    // out from here is out of scope.
    if (error.statusCode == 401) {
      return const _AttachmentLoadFailure(
        title: 'Your session has expired',
        subtitle: 'Please sign out and sign in again.',
        canRetry: false,
        blocksMutations: true,
      );
    }

    return const _AttachmentLoadFailure(
      title: 'Could not load attachments',
      subtitle: 'Tap to try again',
      canRetry: true,
      blocksMutations: false,
    );
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  // ── Add ──────────────────────────────────────────────────────────────────

  /// Asks which source to attach from. Both the top Close control and the
  /// bottom Cancel row simply dismiss the sheet, leaving the completer to
  /// resolve to null -- neither starts a picker.
  Future<_AttachmentSource?> _pickSource() async {
    final result = Completer<_AttachmentSource?>();
    await CaleeActionSheet.show(
      context: context,
      title: 'Add attachment',
      showCloseButton: true,
      closeTooltip: 'Close without attaching',
      actions: [
        CaleeAction(
          label: 'Take photo',
          icon: Icons.camera_alt_outlined,
          onTap: () => result.complete(_AttachmentSource.camera),
        ),
        CaleeAction(
          label: 'Choose photo',
          icon: Icons.photo_library_outlined,
          onTap: () => result.complete(_AttachmentSource.gallery),
        ),
        CaleeAction(
          label: 'Choose file',
          icon: Icons.attach_file,
          onTap: () => result.complete(_AttachmentSource.file),
        ),
      ],
    );
    if (!result.isCompleted) result.complete(null);
    return result.future;
  }

  /// Entry point for the "Add attachment" row.
  ///
  /// Wrapped rather than left bare because this runs as a fire-and-forget
  /// tap handler: anything that escaped it would surface as an unhandled
  /// asynchronous error with no message and no recovery, which is precisely
  /// what a failing picker used to do.
  Future<void> _addAttachment() async {
    if (!_effectiveCanAdd ||
        _stoppingAttachmentWork ||
        _uploadAttemptInProgress) {
      return;
    }
    try {
      await _runAddAttachment();
    } catch (error) {
      _debugLogAttachmentFailure('add', error);
      if (mounted) {
        _showMessage('Could not attach this file. Please try again.');
      }
    }
  }

  /// Guarded at all three points where this flow can be overtaken by a
  /// teardown or a transfer cancellation.
  ///
  /// The first check is the important one, and it is about ROUTES, not just
  /// wasted work: [_pickSource] pushes a modal sheet, and pushing one after
  /// the editor has committed to closing would put an attachment-owned
  /// route on top of the editor -- so the editor's own `Navigator.pop()`
  /// would dismiss the source sheet instead of the editor, leaving the
  /// editor open but already marked as closing. The guard lives here rather
  /// than only in [_addAttachment] because this method owns the modal, and
  /// must stay safe if it is ever called from somewhere else.
  ///
  /// [_uploadAttemptInProgress] is checked alongside the teardown flag at
  /// each of those points. The Add row is already inert while an attempt
  /// owns the pending operation, so this is the layer for races and
  /// programmatic calls: a selection accepted here would replace the very
  /// operation an in-flight preflight is about to send, and then be refused
  /// by the single-flight guard and left with nothing to send it.
  ///
  /// [_effectiveCanAdd] joins them at every one of those points, and is the
  /// guard this method exists to hold. The row being disabled stops taps;
  /// it does not stop a call that arrives from anywhere else, and it does
  /// not help at all across the two long awaits below -- the source sheet
  /// and the OS picker are both open for as long as the user takes, and the
  /// initial list request can fail terminally (unsupported calendar,
  /// deleted event) at any point during them. Re-reading it after each
  /// await is what stops a file picked before that answer arrived from
  /// being staged and queued afterwards.
  Future<void> _runAddAttachment() async {
    if (!_effectiveCanAdd ||
        _stoppingAttachmentWork ||
        _uploadAttemptInProgress) {
      return;
    }

    final source = await _pickSource();
    if (source == null ||
        !mounted ||
        !_effectiveCanAdd ||
        _stoppingAttachmentWork ||
        _uploadAttemptInProgress) {
      return;
    }

    final result = await _pickAttachmentFile(source);
    // Re-checked after the picker await: a cancellation (or a teardown) can
    // begin while the OS picker is up, and the file that comes back must not
    // start an upload into either.
    if (!mounted ||
        !_effectiveCanAdd ||
        _stoppingAttachmentWork ||
        _uploadAttemptInProgress) {
      return;
    }

    switch (result) {
      // A normal cancellation is not an error and says nothing to the user.
      case _AttachmentPickCancelled():
        return;
      case _AttachmentPickFailed(:final message):
        _showMessage(message);
      case _AttachmentReady(:final file, :final originalFilename):
        // Copy into storage Calee owns BEFORE anything else knows about the
        // selection. Both pickers hand back a path in an OS-managed
        // temporary directory; from here on the operation reads only its own
        // staged copy, so the OS reclaiming that temporary file -- or
        // Android killing the app behind the camera -- can no longer turn a
        // queued upload into a permanent failure.
        final StagedAttachmentFile staged;
        try {
          staged = await _staging.stage(
            source: file,
            originalFilename: originalFilename,
          );
        } on AttachmentStagingClosedException {
          // Teardown won the race. The screen is going; say nothing.
          return;
        } on AttachmentStagingException catch (error) {
          _debugLogStagingFailure(error);
          if (mounted) _showMessage(error.message);
          return;
        }

        // Re-checked after the copy: a cancellation or teardown can land
        // while bytes are being written, and the staged file must not
        // outlive a section that will never upload it.
        if (!mounted || _stoppingAttachmentWork) {
          unawaited(_staging.discard(staged));
          return;
        }

        // One logical operation begins here -- and with it, ONE idempotency
        // key that will survive every timeout and retry below, and ONE
        // staged file that outlives all of them too.
        final pending = PendingAttachmentUpload(staged: staged);
        setState(() => _pendingUpload = pending);
        _notifyOperationState();
        await _sendPendingUpload();
    }
  }

  /// Runs the picker for [source] and validates whatever comes back.
  ///
  /// Every failure mode of a native picker lands here as one of three
  /// results: cancelled (silent), failed (one clear Calee message), or
  /// ready. Nothing escapes as an exception, and no platform text is
  /// forwarded to the UI.
  Future<_AttachmentPickResult> _pickAttachmentFile(
    _AttachmentSource source,
  ) async {
    try {
      return source == _AttachmentSource.file
          ? await _pickDocument()
          : await _pickPhoto(source);
    } on PlatformException catch (error) {
      _debugLogAttachmentFailure('pick', error);
      return _AttachmentPickFailed(_pickerPlatformMessage(error.code));
    } catch (error) {
      _debugLogAttachmentFailure('pick', error);
      return const _AttachmentPickFailed(
        'Could not open the file picker. Please try again.',
      );
    }
  }

  Future<_AttachmentPickResult> _pickDocument() async {
    final result = await _runDocumentPicker();
    // The plugin's own "the user backed out" answer.
    if (result == null) return const _AttachmentPickCancelled();

    final files = result.files;
    if (files.isEmpty) {
      return const _AttachmentPickFailed(
        'No file was selected. Please try again.',
      );
    }
    if (files.length > 1) {
      // allowMultiple is false, so more than one entry means the platform
      // did something that was not asked for. Picking one of them would be
      // a guess about which document the user meant.
      return const _AttachmentPickFailed(
        'Please choose a single file to attach.',
      );
    }

    final picked = files.single;
    final path = picked.path;
    if (path == null || path.isEmpty) {
      // A cloud/provider entry can come back with no local path at all (not
      // downloaded yet, or stream-only). Previously indistinguishable from
      // a cancellation, which left the user tapping Add and getting nothing.
      return const _AttachmentPickFailed(
        'That file could not be read from this app. Try saving it to your '
        'device first, then attach it.',
      );
    }

    final name = picked.name.trim();
    return _validateSelection(
      File(path),
      // The picker's displayed name, NOT the (often cache/temp) path -- see
      // CaleeHubClient.uploadAttachment's originalFilename. When even that
      // is missing, a neutral name carrying only the extension is used;
      // local cache path structure is never presented as the user's name.
      name.isEmpty ? _neutralFilename('attachment', _extensionOf(path)) : name,
    );
  }

  /// Shows only the extensions Hub accepts, where the plugin and platform
  /// support filtering, and falls back to an unfiltered picker where they do
  /// not. The filter is convenience only -- the checks in
  /// [_validateSelection] and, above all, Hub's own content inspection stay
  /// authoritative. An extension is never treated as proof of content type.
  Future<FilePickerResult?> _runDocumentPicker() async {
    try {
      return await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: _pickerAllowedExtensions,
        allowMultiple: false,
        withData: false,
      );
    } on ArgumentError {
      return FilePicker.pickFiles(allowMultiple: false, withData: false);
    } on UnimplementedError {
      return FilePicker.pickFiles(allowMultiple: false, withData: false);
    }
  }

  Future<_AttachmentPickResult> _pickPhoto(_AttachmentSource source) async {
    final xFile = await ImagePicker().pickImage(
      source: source == _AttachmentSource.camera
          ? ImageSource.camera
          : ImageSource.gallery,
    );
    if (xFile == null) return const _AttachmentPickCancelled();
    if (xFile.path.isEmpty) {
      return const _AttachmentPickFailed(
        'That photo could not be read. Please try again.',
      );
    }
    return _validateSelection(File(xFile.path), _photoFilename(xFile));
  }

  /// The one place local selections are checked, shared by both picker
  /// paths: the file still exists, its metadata can be read, it is neither
  /// empty nor over the 10 MB cap, and its extension is one Hub accepts.
  Future<_AttachmentPickResult> _validateSelection(
    File file,
    String originalFilename,
  ) async {
    final int size;
    try {
      // Reading the length answers "does it still exist" and "how big is it"
      // in one filesystem call, so there is no window between the two in
      // which the file could vanish.
      size = await file.length();
    } on PathNotFoundException {
      // Both pickers hand back a copy in a temporary directory, which the OS
      // can reclaim -- and on Android the app can be killed and restarted
      // between the pick and this check.
      return const _AttachmentPickFailed(
        'That file is no longer available. Please choose it again.',
      );
    } catch (error) {
      _debugLogAttachmentFailure('metadata', error);
      return const _AttachmentPickFailed(
        'That file could not be read. Please choose it again.',
      );
    }

    if (size <= 0) {
      return const _AttachmentPickFailed(
        'This file is empty and cannot be attached.',
      );
    }
    if (size > kAttachmentMaxBytes) {
      return const _AttachmentPickFailed(
        'This file is too large to attach (max 10 MB).',
      );
    }
    if (!kAttachmentAllowedExtensions.contains(
      _extensionOf(originalFilename),
    )) {
      return const _AttachmentPickFailed('This file type cannot be attached.');
    }

    return _AttachmentReady(
      file: file,
      originalFilename: originalFilename,
      size: size,
    );
  }

  static List<String> get _pickerAllowedExtensions =>
      kAttachmentAllowedExtensions.toList();

  /// The name to record for a camera/gallery pick.
  ///
  /// [XFile.name] is what the picker reported, and is used verbatim whenever
  /// it exists. Camera captures can arrive unnamed; rather than jumping
  /// straight to `photo.jpg` -- which mislabels a HEIC or PNG capture and
  /// leaves Hub to reconcile a name that contradicts the bytes -- the
  /// extension is taken from the reported MIME type, then from the
  /// temporary file's own extension.
  ///
  /// Each of those sources is ACCEPTED only if it yields a supported
  /// extension, so an uninformative MIME type cannot shadow a perfectly
  /// good one on the path: a capture reported as `application/octet-stream`
  /// at `/tmp/capture.heic` is a heic, not the jpg that first-non-empty
  /// order would have called it.
  ///
  /// Only the EXTENSION ever comes from the path -- the generated basename
  /// is local cache structure, not a name any user chose.
  static String _photoFilename(XFile xFile) {
    final name = xFile.name.trim();
    if (name.isNotEmpty) return name;

    final mimeExtension = _extensionFromMimeType(xFile.mimeType);
    if (kAttachmentAllowedExtensions.contains(mimeExtension)) {
      return 'photo.$mimeExtension';
    }

    final pathExtension = _extensionOf(xFile.path);
    if (kAttachmentAllowedExtensions.contains(pathExtension)) {
      return 'photo.$pathExtension';
    }

    return 'photo.jpg';
  }

  /// `attachment.pdf` when the extension is one Hub accepts; otherwise a
  /// bare name rather than an invented type.
  static String _neutralFilename(String base, String extension) {
    if (!kAttachmentAllowedExtensions.contains(extension)) return base;
    return '$base.$extension';
  }

  static String _extensionFromMimeType(String? mimeType) {
    if (mimeType == null) return '';
    final subtype = mimeType.split('/').last.split(';').first;
    final cleaned = subtype.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
    return cleaned == 'jpeg' ? 'jpg' : cleaned;
  }

  /// The lowercased, `[a-z0-9]`-only extension of [value], or '' when there
  /// is none worth trusting.
  static String _extensionOf(String value) {
    final lastDot = value.lastIndexOf('.');
    if (lastDot < 0 || lastDot == value.length - 1) return '';
    return value
        .substring(lastDot + 1)
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]'), '');
  }

  /// Maps a platform picker failure to Calee wording. A permission denial
  /// gets its own message because "try again" is useless advice for it;
  /// everything else shares one honest fallback. The platform's own text is
  /// never surfaced -- it is not written for users, and can carry paths.
  static String _pickerPlatformMessage(String? code) {
    final normalized = code?.toLowerCase() ?? '';
    if (normalized.contains('denied') ||
        normalized.contains('permission') ||
        normalized.contains('access')) {
      return 'Calee does not have permission to use the camera or your '
          'photos. You can allow this in Settings.';
    }
    if (normalized.contains('already_active')) {
      return 'Another file selection is already open.';
    }
    return 'Could not open the file picker. Please try again.';
  }

  /// Debug-only, and deliberately the most specific SAFE detail available
  /// for each kind of failure.
  ///
  /// A Hub failure logs [CaleeHubException.debugSummary] -- status, stable
  /// code, Hub's own user-safe message, request ID and endpoint, all already
  /// parsed by CaleeHubClient from `x-calee-request-id` / `x-request-id` /
  /// `meta.requestId`. That request ID is the one thing that makes a
  /// production report traceable to a Hub log line, and reducing every list
  /// failure to "CaleeHubException" is what made the original defect
  /// undiagnosable from the client side. Everything else stays
  /// category-level: an exception's type, plus a platform exception's own
  /// code, is enough to tell those apart.
  ///
  /// Never logged, on any path: access or refresh tokens, file contents,
  /// multipart bodies, user filenames, or local file paths.
  static void _debugLogAttachmentFailure(String stage, Object error) {
    if (!kDebugMode) return;
    final String detail;
    if (error is CaleeHubException) {
      detail = error.debugSummary;
    } else if (error is PlatformException) {
      detail = 'PlatformException(${error.code})';
    } else {
      detail = error.runtimeType.toString();
    }
    debugPrint('EventAttachmentsSection: $stage failed -- $detail');
  }

  /// Local-file failures get their own record: the stage that failed and the
  /// reason slug the staging manager classified it as. Deliberately no path
  /// and no filename -- the slug already says whether the file was missing,
  /// unreadable, empty, too large, of a rejected type, or failed
  /// verification after the copy.
  static void _debugLogStagingFailure(AttachmentStagingException error) {
    if (!kDebugMode) return;
    debugPrint(
      'EventAttachmentsSection: staging failed -- reason: ${error.reason}',
    );
  }

  /// A failure raised by the local filesystem rather than by Hub.
  ///
  /// This is the distinction the generic `catch` in [_sendPendingUpload] did
  /// not make. `uploadAttachment` reads the staged file itself (`length()`,
  /// then `openRead()`), and CaleeHubClient converts only socket, handshake,
  /// timeout and HTTP failures into a CaleeHubException -- a
  /// FileSystemException travels out raw. Treated as a generic failure it
  /// became `retryable`, offering a Retry against a file that is not there,
  /// which fails identically every time it is tapped.
  static bool _isLocalFileFailure(Object error) => error is FileSystemException;

  /// Sends (or re-sends) [_pendingUpload], always with its original
  /// idempotency key. Retrying via this method is what makes a retry the
  /// SAME operation to Hub rather than a new one that could duplicate.
  Future<void> _sendPendingUpload() async {
    final pending = _pendingUpload;
    if (pending == null || !mounted || _stoppingAttachmentWork) return;
    // Single-flight. An attempt already owns this operation -- still
    // preflighting it, sending it, or settling its outcome -- so a second
    // Add, a second Retry tap or a programmatic re-entry is refused here,
    // silently and before anything is claimed or mutated.
    if (_uploadAttempt != null || _isUploading) return;

    // Claimed SYNCHRONOUSLY, before the first await, so no other invocation
    // can reach the window this used to leave open. The setState is what
    // makes Add and Retry inert for the duration -- see
    // [_uploadAttemptInProgress].
    final attempt = _UploadAttempt(pending);
    setState(() => _uploadAttempt = attempt);

    try {
      // Before a request is built, not halfway through streaming one: a
      // staged file that is missing, unreadable or the wrong size can never
      // be uploaded, so Hub is not asked and the operation ends here rather
      // than being offered as a retry that cannot succeed.
      final intact = await _staging.isIntact(pending.staged);

      // Discard, editor-close or a teardown may have landed while that ran.
      // Any of them makes this attempt void: return silently, without
      // calling Hub, showing a message, touching the attachment rows or
      // deleting a file another path now owns.
      if (!_ownsUploadAttempt(attempt)) return;

      if (!intact) {
        if (kDebugMode) {
          debugPrint(
            'EventAttachmentsSection: upload aborted -- staged file missing '
            'or size-mismatched (expected ${pending.size} bytes)',
          );
        }
        await _finalizePendingUploadAsFailed(
          pending,
          message: _kStagedFileGoneMessage,
        );
        return;
      }

      await _runUploadAttempt(attempt, pending);
    } finally {
      // Identity-guarded: an attempt only ever releases its own claim.
      _releaseUploadAttempt(attempt);
    }
  }

  /// True while [attempt] is still the section's live attempt AND still
  /// speaks for the section's current pending operation.
  ///
  /// Both halves matter. The first fails if the section moved on to another
  /// attempt; the second fails the instant Discard or editor-close clears
  /// [_pendingUpload], which is how a preflight that is already in flight is
  /// invalidated without having to reach into it.
  bool _ownsUploadAttempt(_UploadAttempt attempt) =>
      mounted &&
      !_stoppingAttachmentWork &&
      identical(_uploadAttempt, attempt) &&
      identical(_pendingUpload, attempt.operation);

  void _releaseUploadAttempt(_UploadAttempt attempt) {
    if (!identical(_uploadAttempt, attempt)) return;
    if (mounted) {
      setState(() => _uploadAttempt = null);
    } else {
      _uploadAttempt = null;
    }
  }

  /// The transfer half of one attempt. Only the invocation still holding the
  /// claim gets here, so exactly one cancel token, one `_isUploading` and one
  /// set of progress callbacks exist at a time.
  Future<void> _runUploadAttempt(
    _UploadAttempt attempt,
    PendingAttachmentUpload pending,
  ) async {
    final cancelToken = AttachmentTransferCancelToken();
    var bytesLeftTheApp = false;
    pending.state = AttachmentUploadState.uploading;
    setState(() {
      _isUploading = true;
      _uploadProgress = 0;
      _uploadCancelToken = cancelToken;
    });
    _notifyOperationState();

    try {
      final attachment = await widget.hubClient.uploadAttachment(
        accessToken: widget.accessToken,
        eventId: widget.eventId,
        calendarId: widget.calendarId,
        // The STAGED copy, never the picker's path -- see
        // [PendingAttachmentUpload]. The name on the wire still comes from
        // originalFilename, so the generated staging basename is not
        // exposed here or anywhere else.
        file: pending.stagedFile,
        originalFilename: pending.originalFilename,
        idempotencyKey: pending.idempotencyKey,
        cancelToken: cancelToken,
        onProgress: (sent, total) {
          if (sent > 0) bytesLeftTheApp = true;
          // A progress callback from an attempt the section has moved past
          // must not drive the spinner for whatever owns it now.
          if (!mounted || !identical(_uploadAttempt, attempt)) return;
          setState(() => _uploadProgress = total > 0 ? sent / total : null);
        },
      );
      // Bytes have stopped moving the moment the call returns -- exactly as
      // on the failure path below. Ending the transferring state here, and
      // not after the awaited cleanup inside _completePendingUpload, is what
      // keeps a screen waiting on this upload from sitting through a
      // filesystem delete before it can close.
      _markUploadStopped(attempt);
      if (!mounted) return;
      await _completePendingUpload(pending, attachment);
    } on CaleeHubException catch (e) {
      // Bytes have stopped moving the moment the call returns, so the
      // "transferring" state ends HERE -- not after the reconciliation that
      // may follow. Otherwise a screen waiting on an upload to stop would
      // sit through the whole status poll before it could close.
      _markUploadStopped(attempt);
      if (!mounted) return;
      // _applyUploadFailure re-checks operation identity itself before it
      // writes anything back.
      await _handleUploadFailure(e, pending, bytesLeftTheApp);
    } catch (error) {
      _markUploadStopped(attempt);
      if (!mounted) return;
      _debugLogAttachmentFailure('upload', error);
      // The user discarded this operation while it was failing. Reporting it
      // now would put a late error on screen for something they dropped, and
      // finalizing it would delete a staged file the discard path already
      // owns.
      if (!identical(_pendingUpload, pending)) return;
      // A local file failure is not a transient network failure, and must
      // not borrow its Retry: the same missing file cannot be sent by
      // asking again. Everything else keeps the operation and its key.
      if (_isLocalFileFailure(error)) {
        await _finalizePendingUploadAsFailed(
          pending,
          message: _kStagedFileGoneMessage,
        );
      } else {
        pending.state = AttachmentUploadState.retryable;
        _showMessage('Could not upload this attachment. Please try again.');
      }
    } finally {
      _markUploadStopped(attempt);
    }
  }

  // ── Pending-operation lifecycle ──────────────────────────────────────────
  //
  // Every end of an upload operation goes through exactly one of the three
  // helpers below, so the staged file has exactly one owner and exactly one
  // deletion point. Scattering File.delete() across the branches is how a
  // confidential document ends up either leaked in the cache directory or
  // deleted out from under an operation that could still have finished.
  //
  // The rule is about KNOWLEDGE, not about success: the staged file is
  // deleted once the operation's outcome is decided (it landed, the user
  // dropped it, or it failed in a way retrying cannot fix), and kept while
  // the outcome is still open (uploading, retryable, reconciling, cancelled
  // with an unknown server-side result). A single timed-out request decides
  // nothing, and must never take the file with it.

  /// The upload landed. Adds the attachment, clears the operation and
  /// releases its staged file.
  ///
  /// Everything the user and the owning editor can observe happens
  /// synchronously; only the deletion is awaited, and nothing is gated on
  /// it. A cleanup that is slow -- or that fails outright, which
  /// [AttachmentUploadStagingManager.discard] absorbs -- must not hold a
  /// finished upload on screen.
  Future<void> _completePendingUpload(
    PendingAttachmentUpload pending,
    CalendarAttachment attachment,
  ) async {
    pending.state = AttachmentUploadState.completed;
    setState(() {
      // Appended to the baseline, and adopted as AUTHORITATIVE: Hub
      // confirmed this attachment exists on this event, which is newer than
      // anything a list request already in flight can be carrying. That
      // request is disowned here -- see _applyAuthoritativeAttachments.
      //
      // `...?` on a nullable baseline because a completed upload PROVES a
      // list exists: an event that just accepted an attachment has at least
      // this one, so recording it establishes the baseline if -- through
      // some path that bypassed the Add gate -- there somehow is not one.
      _applyAuthoritativeAttachments([...?_listState.baseline, attachment]);
      // Only clears the operation that actually completed: a discard while
      // this was in flight already replaced it with null, and must not be
      // undone here.
      if (identical(_pendingUpload, pending)) _pendingUpload = null;
    });
    _notifyOperationState();
    await _staging.discard(pending.staged);
  }

  /// The operation failed in a way retrying cannot fix. Clears it, deletes
  /// its staged file, and shows [message] -- which must tell the user what
  /// to do instead, because no Retry will be offered.
  ///
  /// Clearing is what makes this terminal in the UI as well as in the state
  /// machine: a `failedFinal` operation left in place shows no Retry (its
  /// [PendingAttachmentUpload.canRetryWithSameKey] is false) but keeps the
  /// user's file on disk with nothing left to claim it.
  Future<void> _finalizePendingUploadAsFailed(
    PendingAttachmentUpload pending, {
    required String message,
  }) async {
    pending.state = AttachmentUploadState.failedFinal;
    // Any in-flight status poll for this operation is over too -- its answer
    // could only reinstate something the user has already been told is done.
    _pollGeneration++;
    if (mounted) {
      setState(() {
        if (identical(_pendingUpload, pending)) _pendingUpload = null;
      });
      if (message.isNotEmpty) _showMessage(message);
    } else if (identical(_pendingUpload, pending)) {
      _pendingUpload = null;
    }
    // Reported before the deletion, for the same reason as
    // _completePendingUpload: the editor's "may I close?" answer is already
    // decided, and must not wait on the filesystem to hear it.
    _notifyOperationState();
    await _staging.discard(pending.staged);
  }

  /// Ends the "an upload is sending bytes" state. Idempotent, and safe after
  /// disposal: it only touches the widget tree while still mounted, but
  /// always updates the flags an awaiting close depends on.
  ///
  /// Re-reports the operation state even when the transfer fields were
  /// already clear. A second call is not redundant: the pending operation's
  /// own fate is usually decided BETWEEN the two calls (cleared, finalized,
  /// or left retryable), and an early return here would strand the parent
  /// on the state as it stood before that decision.
  void _markUploadStopped(_UploadAttempt attempt) {
    // Scoped to the attempt that owns the transfer fields. A stale
    // invocation unwinding after its operation was discarded must not clear
    // the spinner, progress or cancel token of whatever holds them now.
    //
    // This is deliberately identity-only, and does NOT go through
    // [_ownsUploadAttempt]: an attempt whose operation was discarded
    // mid-transfer still has to put its own transfer state away, or the
    // upload row would stay stuck on "Uploading…" for good.
    if (!identical(_uploadAttempt, attempt)) return;

    final wasTransferring =
        _isUploading || _uploadCancelToken != null || _uploadProgress != null;
    if (wasTransferring) {
      if (mounted) {
        setState(() {
          _isUploading = false;
          _uploadProgress = null;
          _uploadCancelToken = null;
        });
      } else {
        _isUploading = false;
        _uploadProgress = null;
        _uploadCancelToken = null;
      }
    }
    _notifyOperationState();
  }

  /// Applies the per-code policy to a failed upload and then reports the
  /// resulting state upward.
  ///
  /// The reporting lives here, not at the call site, because every branch
  /// below decides a DIFFERENT fate for the pending operation -- cleared,
  /// finalized, left retryable, or handed to reconciliation -- and each of
  /// those changes whether the editor above may close without asking.
  Future<void> _handleUploadFailure(
    CaleeHubException e,
    PendingAttachmentUpload pending,
    bool bytesLeftTheApp,
  ) async {
    try {
      await _applyUploadFailure(e, pending, bytesLeftTheApp);
    } finally {
      _notifyOperationState();
    }
  }

  Future<void> _applyUploadFailure(
    CaleeHubException e,
    PendingAttachmentUpload pending,
    bool bytesLeftTheApp,
  ) async {
    // The user discarded this operation while it was failing. Its outcome is
    // no longer anybody's business, and writing state back here would put a
    // deliberately abandoned upload back on screen.
    if (!identical(_pendingUpload, pending)) return;

    if (e.code == 'CANCELLED') {
      // Whether this is safe to forget depends on whether anything could
      // have reached Hub. If bytes went out, the server-side outcome is
      // unknown and must be reconciled before the operation is dropped.
      if (bytesLeftTheApp) {
        // The staged file is KEPT: the server-side outcome is unknown, and
        // the reconciliation below may well end in a retry of this same
        // operation, with this same key, from this same file.
        pending.state = AttachmentUploadState.cancelledUncertain;
        setState(() {});
        await _reconcilePendingUpload();
      } else {
        // Nothing reached Hub, so nothing is owed to anyone. The operation
        // is dropped outright and its staged file goes with it.
        pending.state = AttachmentUploadState.cancelledBeforeSend;
        setState(() => _pendingUpload = null);
        await _staging.discard(pending.staged);
      }
      return;
    }

    final decision = decideAttachmentError(e);
    if (decision.nextUploadState != null) {
      pending.state = decision.nextUploadState!;
    }

    // Terminal is terminal, whatever else the policy asks for. Every code
    // whose decision is failedFinal ends the operation here -- cleared, with
    // its staged file deleted -- rather than only the two actions that
    // happened to null it out. ATTACHMENT_LIMIT_REACHED and
    // ATTACHMENT_OCCURRENCE_NOT_SUPPORTED are showMessageOnly precisely so
    // their own wording survives, and they used to leave a dead operation
    // holding the user's file on disk indefinitely.
    if (decision.nextUploadState == AttachmentUploadState.failedFinal) {
      if (decision.action == AttachmentErrorAction.disableAttachments) {
        setState(() => _attachmentsDisabled = true);
      }
      await _finalizePendingUploadAsFailed(
        pending,
        message: attachmentErrorMessageWithReference(decision.message, e),
      );
      if (decision.action == AttachmentErrorAction.disableAttachments ||
          decision.action == AttachmentErrorAction.refreshList) {
        unawaited(_load());
      }
      return;
    }

    if (decision.message.isNotEmpty) {
      _showMessage(attachmentErrorMessageWithReference(decision.message, e));
    }

    switch (decision.action) {
      case AttachmentErrorAction.reconcile:
        await _reconcilePendingUpload();
      case AttachmentErrorAction.refreshList:
        unawaited(_load());
      case AttachmentErrorAction.discardOperation:
        // Non-terminal discards keep no claim on the file either.
        setState(() => _pendingUpload = null);
        await _staging.discard(pending.staged);
      case AttachmentErrorAction.disableAttachments:
        setState(() {
          _attachmentsDisabled = true;
          _pendingUpload = null;
        });
        await _staging.discard(pending.staged);
        unawaited(_load());
      case AttachmentErrorAction.showMessageOnly:
        // Retryable, reconciling or uncertain: the outcome is still open, so
        // the staged file and the idempotency key both stay exactly as they
        // are.
        setState(() {});
    }
  }

  List<Duration> get _statusPollSchedule =>
      widget.statusPollSchedule ??
      EventAttachmentsSection.defaultStatusPollSchedule;

  /// Guards against overlapping status requests -- a Retry tap arriving while
  /// a poll is in flight must not start a second one.
  bool _statusPollInFlight = false;

  /// Bumped whenever the pending operation is discarded or replaced, so an
  /// in-flight poll for a superseded operation cannot write its result back.
  int _pollGeneration = 0;

  /// Resolves an UNCERTAIN outcome by asking Hub about THIS OPERATION's
  /// idempotency key.
  ///
  /// The previous implementation listed the event's attachments and declared
  /// success if any of them had the same filename and size as the file it had
  /// sent. That is not identity. Two genuinely different files can share a
  /// name and a byte count, and an event may already carry a same-named
  /// attachment from an earlier upload -- in which case the app would report
  /// success, clear the pending operation, and the user's document would
  /// never be attached at all. Nothing about a filename, a size, a MIME type,
  /// an attachment count or a list ordering is used here; those are display
  /// details, not identity.
  ///
  /// The key is never rotated by this method: whatever it learns, a retry
  /// must be recognisable to Hub as the SAME logical upload.
  Future<void> _reconcilePendingUpload() async {
    if (_statusPollInFlight || _stoppingAttachmentWork) return;
    _statusPollInFlight = true;
    final generation = _pollGeneration;
    try {
      await _pollUploadStatus(generation);
    } finally {
      _statusPollInFlight = false;
      // The poll can resolve the operation (completed, or finally failed),
      // which ends the editor's reason to block on it.
      _notifyOperationState();
    }
  }

  Future<void> _pollUploadStatus(int generation) async {
    final schedule = _statusPollSchedule;
    for (var attempt = 0; attempt < schedule.length; attempt++) {
      // Each entry is THIS attempt's own wait. The first is Duration.zero, so
      // the first check is immediate; every later one waits before asking.
      final wait = schedule[attempt];
      if (wait > Duration.zero) {
        await Future<void>.delayed(wait);
      }

      // Every stop condition is re-checked before each attempt: a disposed
      // widget, a discarded or replaced operation, or a completed one all end
      // the poll immediately rather than after the next delay elapses.
      if (!mounted || generation != _pollGeneration) return;
      final pending = _pendingUpload;
      if (pending == null || !pending.isActive) return;

      AttachmentUploadStatus status;
      try {
        status = await widget.hubClient.attachmentUploadStatus(
          accessToken: widget.accessToken,
          eventId: widget.eventId,
          calendarId: widget.calendarId,
          idempotencyKey: pending.idempotencyKey,
        );
      } on CaleeHubException catch (e) {
        if (!mounted || generation != _pollGeneration) return;
        _debugLogAttachmentFailure('upload status', e);
        await _applyStatusCheckFailure(pending, e);
        return;
      } catch (_) {
        if (!mounted || generation != _pollGeneration) return;
        // A transport failure tells us nothing about the upload. Keep the
        // operation and its key, and stay explicitly uncertain.
        setState(() => pending.state = AttachmentUploadState.retryable);
        _showMessage(
          'Could not check on that upload just now. You can try again.',
        );
        return;
      }

      if (!mounted || generation != _pollGeneration) return;

      if (status.isUsableCompletion) {
        // Hub confirmed this operation landed. That is as decided as an
        // outcome gets, so the staged file is released here too.
        await _completePendingUpload(pending, status.attachment!);
        // Re-read the list so ordering and any server-side normalization are
        // reflected, but the COMPLETION itself is already decided.
        unawaited(_load());
        return;
      }

      if (status.kind.isFinalFailure) {
        await _finalizePendingUploadAsFailed(
          pending,
          message: status.kind == AttachmentUploadStatusKind.expired
              ? 'That upload can no longer be confirmed. Please choose the file again.'
              : 'That upload did not complete. Please choose the file again.',
        );
        return;
      }

      if (status.kind == AttachmentUploadStatusKind.retryable) {
        setState(() => pending.state = AttachmentUploadState.retryable);
        _showMessage('That upload did not complete. You can try again.');
        return;
      }

      // in_progress / reconciliation_required / unknown: not established yet.
      setState(
        () =>
            pending.state = status.kind == AttachmentUploadStatusKind.inProgress
            ? AttachmentUploadState.uploading
            : AttachmentUploadState.reconciling,
      );
    }

    if (!mounted || generation != _pollGeneration) return;
    final pending = _pendingUpload;
    if (pending == null || !pending.isActive) return;

    // Polling ran out without a definite answer. Say so plainly and leave
    // Retry / Discard to the user -- do NOT decide on their behalf.
    setState(() => pending.state = AttachmentUploadState.reconciling);
    _showMessage(
      'Still confirming that upload. You can check again or discard it.',
    );
  }

  Future<void> _applyStatusCheckFailure(
    PendingAttachmentUpload pending,
    CaleeHubException e,
  ) async {
    // Hub does not know this key. That is NOT success -- and it is not a
    // reason to re-upload silently either, since the operation may have been
    // deliberately detached. Require an explicit decision from the user.
    if (e.statusCode == 404 || e.statusCode == 410) {
      await _finalizePendingUploadAsFailed(
        pending,
        message:
            'That upload could not be confirmed. Please choose the file again.',
      );
      return;
    }
    // Hub could not answer, which says nothing about the upload. The
    // operation, its key and its staged file all stay.
    setState(() => pending.state = AttachmentUploadState.retryable);
    _showMessage('Could not check on that upload just now. You can try again.');
  }

  /// Explicit user action: re-send the SAME operation with the SAME key.
  Future<void> _retryPendingUpload() => _sendPendingUpload();

  /// Abandons the operation -- by the user tapping Discard, or by the editor
  /// above closing with the user's explicit agreement. Only after this does
  /// a subsequent pick mint a new idempotency key.
  ///
  /// Bumping the generation stops any in-flight status poll from writing
  /// back a result for an operation that is over, and the identity checks in
  /// [_handleUploadFailure] and [_sendPendingUpload] stop a late upload
  /// callback from restoring it. The upload token is cancelled too, so
  /// discarding from the close path does not leave bytes on the wire.
  ///
  /// Clearing [_pendingUpload] is also what voids an attempt that is
  /// mid-preflight: [_ownsUploadAttempt] compares the attempt's operation
  /// against the current one, so a staged-file check still in flight comes
  /// back to find it no longer speaks for anything and returns without
  /// calling Hub. Nothing here waits for that check -- the attempt releases
  /// its own claim when it unwinds.
  ///
  /// Stays SYNCHRONOUS. It is the editor's close path
  /// ([EventAttachmentsController.discardUnresolvedUpload]), and closing a
  /// screen must not wait on the filesystem: the operation is detached and
  /// invalidated here and now, and only the deletion of its staged file --
  /// which nothing is waiting for and which handles its own failures -- is
  /// left to run unawaited.
  void _discardPendingUpload() {
    final pending = _pendingUpload;
    _pollGeneration++;
    _uploadCancelToken?.cancel();
    if (mounted) {
      setState(() => _pendingUpload = null);
    } else {
      _pendingUpload = null;
    }
    if (pending != null) {
      pending.state = AttachmentUploadState.failedFinal;
      unawaited(_staging.discard(pending.staged));
    }
    _notifyOperationState();
  }

  void _cancelUpload() {
    _uploadCancelToken?.cancel();
  }

  // ── Remove ───────────────────────────────────────────────────────────────

  /// Removes [attachment] from the event, after confirming with the user.
  ///
  /// [_serverMutationsAllowed] is checked at THREE points, and all three are
  /// required:
  ///
  ///  1. before the dialog opens -- a disabled control does not stop a
  ///     programmatic call, and this method must be safe from anywhere;
  ///  2. after the dialog closes -- the destructive dialog is modal and
  ///     stays open for as long as the user takes to read it, which is
  ///     easily long enough for a refresh already in flight to come back
  ///     with an expired session, a deleted event, or a calendar that no
  ///     longer supports attachments;
  ///  3. immediately before the request leaves -- nothing awaits between (2)
  ///     and here today, but a detach cannot be recalled once sent, so the
  ///     check sits against the call itself rather than trusting the
  ///     distance to it.
  ///
  /// The sequence this exists for: baseline visible, Remove confirmation
  /// opens, a held refresh returns a final 401, the user taps Remove -- and
  /// no DELETE is sent.
  Future<void> _removeAttachment(CalendarAttachment attachment) async {
    if (!_effectiveCanRemove ||
        _stoppingAttachmentWork ||
        _busyAttachmentIds.contains(attachment.id)) {
      return;
    }
    final confirmed = await CaleeDestructiveDialog.show(
      context: context,
      title: 'Remove attachment?',
      body:
          '"${attachment.filename}" will be removed from this event. '
          'The original file is not deleted.',
      confirmLabel: 'Remove',
    );
    // Re-checked after the confirmation: a detach cannot be recalled once
    // sent, so it must not be started into a teardown, a cancellation, or a
    // terminal list result that landed while the dialog was up.
    if (!confirmed ||
        !mounted ||
        !_effectiveCanRemove ||
        _stoppingAttachmentWork) {
      return;
    }

    // A detach request that has left cannot be recalled, so the editor is
    // told an action is running for exactly as long as it is in flight.
    _markAttachmentBusy(attachment.id);
    try {
      // Last check, against the call itself.
      if (!_effectiveCanRemove) return;
      final updated = await widget.hubClient.detachAttachment(
        accessToken: widget.accessToken,
        eventId: widget.eventId,
        calendarId: widget.calendarId,
        attachmentId: attachment.id,
      );
      if (!mounted) return;
      // Hub's own post-detach list, which is authoritative -- it replaces
      // the baseline rather than being a second, weaker source beside it,
      // and disowns any refresh still in flight, which would otherwise be
      // able to put the detached attachment back.
      setState(() => _applyAuthoritativeAttachments(updated));
      unawaited(_cache.evict(attachment.id));
    } on CaleeHubException catch (e) {
      if (!mounted) return;
      if (e.statusCode == 409 || e.code == 'ATTACHMENT_NOT_FOUND') {
        _showMessage('This event changed elsewhere. Refreshing attachments.');
        await _load();
        unawaited(_cache.evict(attachment.id));
      } else {
        _showMessage(
          _friendlyErrorMessage(
            e,
            fallback: 'Could not remove this attachment. Please try again.',
          ),
        );
      }
    } catch (error) {
      if (!mounted) return;
      _debugLogAttachmentFailure('remove', error);
      _showMessage('Could not remove this attachment. Please try again.');
    } finally {
      _markAttachmentIdle(attachment.id);
    }
  }

  // ── Download / open / share ─────────────────────────────────────────────

  /// Always re-downloads rather than trusting a previously cached copy: the
  /// attachment API exposes no content-version/ETag an attachment ID could
  /// be validated against, so a cached file can never be proven current.
  /// [AttachmentCacheManager] deletes the previous copy first and hands
  /// back a fresh, unpredictably-named target.
  /// Returns null when there is nothing to hand on: the screen is closing,
  /// the cache is closed, or the download was cancelled. Callers treat that
  /// as "stop quietly", never as an error.
  Future<String?> _ensureDownloaded(CalendarAttachment attachment) async {
    if (_stoppingAttachmentWork) return null;

    // Registered BEFORE the first await, so a teardown that begins while the
    // cache target is still being prepared already sees this download and
    // cancels it -- there is no window in which a transfer is running but
    // untracked.
    final token = AttachmentTransferCancelToken();
    _downloadTokens[attachment.id] = token;
    _notifyOperationState();
    try {
      final destination = await _cache.prepareDownloadTarget(
        attachmentId: attachment.id,
        originalFilename: attachment.filename,
      );
      try {
        await widget.hubClient.downloadAttachment(
          accessToken: widget.accessToken,
          eventId: widget.eventId,
          calendarId: widget.calendarId,
          attachmentId: attachment.id,
          destinationFile: destination,
          cancelToken: token,
        );
      } catch (_) {
        // Never leave a partial (or truncated -- see Part E) file behind for
        // the user to open or share. By handle, not by lookup: a teardown
        // that landed while this was downloading has already untracked the
        // path, and only the handle can still find it.
        await _cache.discardDownload(
          attachmentId: attachment.id,
          file: destination,
        );
        rethrow;
      }
      // If the section tore down while these bytes were arriving, the cache
      // is closed and this deletes the file rather than committing it. That
      // is the race the old synchronous commit() lost: a download finishing
      // after clear() re-registered a confidential copy nobody would delete.
      final kept = await _cache.finalizeDownload(
        attachmentId: attachment.id,
        file: destination,
      );
      return kept ? destination.path : null;
    } on AttachmentCacheClosedException {
      return null;
    } finally {
      _downloadTokens.remove(attachment.id);
      _notifyOperationState();
    }
  }

  /// True for the exception a cancelled transfer raises. A cancellation the
  /// app itself requested is not something to apologise to the user for.
  static bool _isCancellation(Object error) =>
      error is CaleeHubException && error.code == 'CANCELLED';

  Future<void> _openAttachment(CalendarAttachment attachment) async {
    if (!attachment.downloadAvailable ||
        _busyAttachmentIds.contains(attachment.id) ||
        _stoppingAttachmentWork) {
      return;
    }
    _markAttachmentBusy(attachment.id);
    try {
      final path = await _ensureDownloaded(attachment);
      if (path == null || !mounted) return;
      final result = await widget.openFile(path);
      if (result.type != ResultType.done && mounted) {
        _showMessage('Could not open this attachment.');
      }
    } on CaleeHubException catch (e) {
      if (_isCancellation(e) || !mounted) return;
      if (e.code == 'ATTACHMENT_FILE_UNAVAILABLE') {
        _showMessage('This file is no longer available.');
        await _load();
      } else {
        _showMessage(
          _friendlyErrorMessage(
            e,
            fallback: 'Could not open this attachment. Please try again.',
          ),
        );
      }
    } catch (error) {
      if (_isCancellation(error) || !mounted) return;
      _debugLogAttachmentFailure('open', error);
      _showMessage('Could not open this attachment. Please try again.');
    } finally {
      _markAttachmentIdle(attachment.id);
    }
  }

  /// [origin] is the on-screen rect of the control the user tapped. iPadOS
  /// anchors the share sheet to it as a popover; without it the sheet has
  /// nowhere to point and UIKit rejects the presentation outright.
  Future<void> _shareAttachment(
    CalendarAttachment attachment,
    Rect? origin,
  ) async {
    if (!attachment.downloadAvailable ||
        _busyAttachmentIds.contains(attachment.id) ||
        _stoppingAttachmentWork) {
      return;
    }
    _markAttachmentBusy(attachment.id);
    try {
      final path = await _ensureDownloaded(attachment);
      if (path == null || !mounted) return;
      await SharePlus.instance.share(
        ShareParams(
          files: [XFile(path)],
          // The recipient must see the document's real name. The file on
          // disk keeps its unpredictable cache basename -- renaming it would
          // undo the reason it is unpredictable -- so the name is overridden
          // for the share only.
          fileNameOverrides: [attachment.filename],
          sharePositionOrigin: origin ?? _fallbackShareOrigin(),
        ),
      );
      // A dismissed share sheet is a normal outcome, not a failure: the
      // result is deliberately not turned into a message.
    } on CaleeHubException catch (e) {
      if (_isCancellation(e) || !mounted) return;
      if (e.code == 'ATTACHMENT_FILE_UNAVAILABLE') {
        _showMessage('This file is no longer available.');
        await _load();
      } else {
        _showMessage(
          _friendlyErrorMessage(
            e,
            fallback: 'Could not share this attachment. Please try again.',
          ),
        );
      }
    } catch (error) {
      if (_isCancellation(error) || !mounted) return;
      _debugLogAttachmentFailure('share', error);
      _showMessage('Could not share this attachment. Please try again.');
    } finally {
      _markAttachmentIdle(attachment.id);
    }
  }

  /// Used only if the tapped control has somehow lost its geometry (it was
  /// scrolled out and rebuilt away between the tap and this call). A rect in
  /// the middle of the screen still gives iPadOS somewhere valid to anchor.
  Rect _fallbackShareOrigin() {
    final size = MediaQuery.sizeOf(context);
    return Rect.fromCenter(
      center: Offset(size.width / 2, size.height / 2),
      width: 1,
      height: 1,
    );
  }

  /// The user-facing wording for [e], with Hub's request ID appended as a
  /// support reference when the response carried one.
  ///
  /// The reference is added HERE, once, rather than at each of the six call
  /// sites that show one of these messages -- and the full
  /// [CaleeHubException.debugSummary] (endpoint, Hub's raw message) still
  /// goes only to the debug log, never here.
  String _friendlyErrorMessage(
    CaleeHubException e, {
    required String fallback,
  }) => attachmentErrorMessageWithReference(
    _friendlyErrorText(e, fallback: fallback),
    e,
  );

  static String _friendlyErrorText(
    CaleeHubException e, {
    required String fallback,
  }) {
    if (e.code == 'ATTACHMENT_TOO_LARGE') {
      return 'This file is too large to attach.';
    }
    if (e.code == 'ATTACHMENT_TYPE_NOT_ALLOWED') {
      return 'This file type cannot be attached.';
    }
    if (e.code == 'ATTACHMENT_LIMIT_REACHED') {
      return 'This event has reached its attachment limit.';
    }
    if (e.code == 'ATTACHMENTS_NOT_SUPPORTED_FOR_CALENDAR') {
      return 'Attachments are not supported for this calendar.';
    }
    if (e.code == 'NETWORK_ERROR' || e.code == 'TIMEOUT') {
      return 'Check your connection and try again.';
    }
    return fallback;
  }

  // ── Build ────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final listState = _listState;
    final attachments = listState.baseline;
    final loadFailure = listState.failure;
    final hasNothingToShow =
        attachments != null &&
        attachments.isEmpty &&
        !_canAddCapability &&
        !listState.isRequestActive &&
        loadFailure == null;

    if (hasNothingToShow) return const SizedBox.shrink();

    return CaleeSection(
      title: 'Attachments',
      footer: widget.isSeriesScoped
          ? 'Applies to all events in this series'
          : null,
      children: [
        // Only ever the INITIAL load. A refresh over an existing list
        // deliberately shows no spinner row here: replacing rows the user
        // is reading with "Loading attachments…" would hide known-good
        // information to report progress on a request that may well change
        // nothing. The refresh is instead expressed by Add going inert.
        if (listState.isInitialLoading)
          const CaleeListRow(
            key: Key('attachment_loading_row'),
            title: 'Loading attachments…',
            leading: SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ),
        if (loadFailure != null)
          CaleeListRow(
            key: const Key('attachment_load_error_row'),
            // A failure over an existing list is a REFRESH failure, and
            // saying so is the difference between "your attachments are
            // gone" and "this list may be a moment out of date" -- the rows
            // below it are still there and still usable.
            title: listState.hasRecoverableRefreshFailure
                ? 'Could not refresh attachments'
                : loadFailure.title,
            subtitle: loadFailure.subtitle,
            leading: const Icon(
              Icons.error_outline,
              color: CaleeColors.destructive,
            ),
            // A terminal calendar/event failure is not tappable at all:
            // offering a retry that provably cannot change the answer is
            // what made these failures indistinguishable in the first
            // place. Nor is anything tappable while a request is already
            // running -- _load() would refuse it anyway, and a live-looking
            // control that does nothing is worse than a quiet one.
            onTap: loadFailure.canRetry && !listState.isRequestActive
                ? _load
                : null,
          ),
        if (attachments != null)
          for (final attachment in attachments)
            _AttachmentRow(
              key: ValueKey(attachment.id),
              attachment: attachment,
              busy: _busyAttachmentIds.contains(attachment.id),
              canRemove: _effectiveCanRemove,
              onOpen: () => _openAttachment(attachment),
              onShare: (origin) => _shareAttachment(attachment, origin),
              onRemove: () => _removeAttachment(attachment),
            ),
        // A pending operation that is neither in flight nor finished needs
        // explicit user resolution -- retrying reuses the SAME idempotency
        // key, discarding is the only thing that lets a later pick mint a
        // new one (Part G).
        //
        // Gated on THE OPERATION ITSELF, and on nothing else. Not on the
        // calendar's capability, not on `_attachmentsDisabled`, not on the
        // list's failure state, not on list readiness. Those all describe
        // whether a NEW upload could start; this row is about one that
        // already did, and whose staged file is on disk right now.
        //
        // The case that forced this: a refresh returns
        // ATTACHMENTS_NOT_SUPPORTED_FOR_CALENDAR, the section sets
        // `_attachmentsDisabled`, and the whole row vanished -- taking
        // Discard with it. The staged file stayed on disk, the operation
        // stayed unresolved, and the editor stayed blocked on it with
        // nothing on screen the user could press. A terminal result must
        // never strand a staged file behind an invisible control.
        //
        // (It cannot appear during the INITIAL load at all -- Add was never
        // available, so no operation can exist yet.)
        if (_pendingUploadNeedsAction && !_isUploading)
          CaleeListRow(
            key: const Key('pending_upload_row'),
            title: _pendingUpload!.isUncertain
                ? 'Checking "${_pendingUpload!.originalFilename}"…'
                : 'Could not attach "${_pendingUpload!.originalFilename}"',
            subtitle: _pendingUpload!.isUncertain
                ? 'Confirming whether this upload completed'
                : 'Tap Retry to finish this upload',
            leading: const Icon(
              Icons.error_outline,
              color: CaleeColors.destructive,
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextButton(
                  key: const Key('retry_pending_upload'),
                  // Inert while an attempt already owns this operation --
                  // during the staged-file preflight of a retry, and while
                  // a previous attempt is still settling. Tapping through
                  // that window used to start a duplicate send of the same
                  // key.
                  //
                  // Also inert after a terminal list failure: a retry is an
                  // upload, and no attachment mutation may start against a
                  // calendar that cannot take them, an event that is gone,
                  // or an expired session. Discard beside it stays live
                  // through all of it -- abandoning the operation is exactly
                  // what the user must still be able to do, and is the only
                  // thing that releases the staged file and unblocks the
                  // editor.
                  onPressed:
                      (_uploadAttemptInProgress || !_serverMutationsAllowed)
                      ? null
                      : _retryPendingUpload,
                  child: const Text('Retry'),
                ),
                TextButton(
                  key: const Key('discard_pending_upload'),
                  // NEVER conditional. Discarding sends nothing to Hub: it
                  // detaches the operation, deletes the staged file through
                  // the existing cleanup lifecycle, and reports the section
                  // idle so the editor stops blocking on it. That is exactly
                  // what the user needs MOST when everything else has failed
                  // terminally, so it is the one control that cannot be
                  // taken away.
                  onPressed: _discardPendingUpload,
                  child: const Text('Discard'),
                ),
              ],
            ),
          ),
        // Shown whenever this event COULD take an attachment, and disabled
        // when it cannot take one right now -- rather than disappearing and
        // reappearing as the list loads. The affordance staying put, greyed,
        // beneath "Loading attachments…" is the honest picture: attaching is
        // possible here, just not yet.
        if (_canAddCapability)
          CaleeListRow(
            key: const Key('add_attachment_row'),
            title: _isUploading ? 'Uploading…' : 'Add attachment',
            leading: _isUploading
                ? SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      value: _uploadProgress,
                    ),
                  )
                : Icon(
                    Icons.add,
                    color: _addRowEnabled
                        ? CaleeColors.primary
                        : CaleeColors.textTertiary,
                  ),
            titleStyle: TextStyle(
              color: (_isUploading || !_addRowEnabled)
                  ? CaleeColors.textSecondary
                  : CaleeColors.primary,
              fontWeight: FontWeight.w600,
            ),
            trailing: _isUploading
                ? TextButton(
                    onPressed: _cancelUpload,
                    child: const Text('Cancel'),
                  )
                : null,
            onTap: _addRowEnabled ? _addAttachment : null,
          ),
      ],
    );
  }
}

class _AttachmentRow extends StatelessWidget {
  const _AttachmentRow({
    required this.attachment,
    required this.busy,
    required this.canRemove,
    required this.onOpen,
    required this.onShare,
    required this.onRemove,
    super.key,
  });

  /// Minimum tap target for the row's icon actions. 48 is Material's
  /// standard and comfortably clears the 44 the platform HIGs ask for; the
  /// icon itself stays 20 so the row's density is unchanged.
  static const double _actionTargetSize = 48;
  static const double _actionIconSize = 20;

  final CalendarAttachment attachment;
  final bool busy;
  final bool canRemove;
  final VoidCallback onOpen;

  /// Receives the share control's own on-screen rect, which iPadOS needs to
  /// anchor the share sheet to.
  final ValueChanged<Rect?> onShare;
  final VoidCallback onRemove;

  /// The global rect of whatever [context] is currently laid out as, or null
  /// if it has no geometry (not laid out, or already gone).
  static Rect? _globalRectOf(BuildContext context) {
    final box = context.findRenderObject();
    if (box is! RenderBox || !box.hasSize || !box.attached) return null;
    return box.localToGlobal(Offset.zero) & box.size;
  }

  IconData get _icon {
    final type = attachment.contentType ?? '';
    if (type.startsWith('image/')) return Icons.image_outlined;
    if (type == 'application/pdf') return Icons.picture_as_pdf_outlined;
    return Icons.insert_drive_file_outlined;
  }

  String get _subtitle {
    if (!attachment.downloadAvailable) return 'File no longer available';
    return attachment.formattedSize ?? ' ';
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label:
          '${attachment.filename}. '
          '${attachment.downloadAvailable ? 'Available to download' : 'File no longer available'}.',
      child: CaleeListRow(
        title: attachment.filename,
        titleMaxLines: 1,
        subtitle: _subtitle,
        subtitleStyle: attachment.downloadAvailable
            ? null
            : const TextStyle(color: CaleeColors.destructive),
        leading: Icon(
          _icon,
          color: attachment.downloadAvailable
              ? CaleeColors.textSecondary
              : CaleeColors.textTertiary,
        ),
        onTap: attachment.downloadAvailable && !busy ? onOpen : null,
        trailing: busy
            ? const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (attachment.downloadAvailable)
                    Tooltip(
                      message: 'Share ${attachment.filename}',
                      // The Builder's context resolves to this button's own
                      // render box, which is the rect iPadOS anchors the
                      // share popover to. Taking it at tap time (rather than
                      // caching it) keeps it correct after scrolling.
                      child: Builder(
                        builder: (buttonContext) => IconButton(
                          icon: const Icon(
                            Icons.ios_share,
                            size: _actionIconSize,
                          ),
                          onPressed: () =>
                              onShare(_globalRectOf(buttonContext)),
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(
                            minWidth: _actionTargetSize,
                            minHeight: _actionTargetSize,
                          ),
                        ),
                      ),
                    ),
                  if (canRemove)
                    Tooltip(
                      message: 'Remove ${attachment.filename} from event',
                      child: IconButton(
                        icon: const Icon(
                          Icons.close,
                          size: _actionIconSize,
                          color: CaleeColors.destructive,
                        ),
                        onPressed: onRemove,
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(
                          minWidth: _actionTargetSize,
                          minHeight: _actionTargetSize,
                        ),
                      ),
                    ),
                ],
              ),
      ),
    );
  }
}
