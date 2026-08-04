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
import '../attachment_upload_status.dart';
import '../pending_attachment_upload.dart';

/// Conservative client-side pre-check mirroring calee-hub-core's default
/// allowlist (core_attachments_cfg.php). Server-side content inspection
/// remains authoritative for every upload; this only gives fast feedback
/// before a network round trip (Phase 6: "show validation failures before
/// network upload where possible").
const kAttachmentMaxBytes = 10 * 1024 * 1024;
const kAttachmentAllowedExtensions = {
  'jpg',
  'jpeg',
  'png',
  'heic',
  'heif',
  'pdf',
  'txt',
  'doc',
  'docx',
  'xls',
  'xlsx',
  'ppt',
  'pptx',
};

enum _AttachmentSource { camera, gallery, file }

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

  /// Cancels every in-flight upload and download, completing once they have
  /// unwound (or a short grace period has passed), so the caller never
  /// dismisses a screen on top of a still-spinning transfer.
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
    required this.hubClient,
    required this.accessToken,
    required this.canAdd,
    required this.canRemove,
    required this.isSeriesScoped,
    this.openFile = OpenFilex.open,
    this.cacheManager,
    this.statusPollSchedule,
    this.onOperationStateChanged,
    this.controller,
    super.key,
  });

  final String eventId;
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
  List<CalendarAttachment>? _attachments;
  Object? _loadError;
  bool _isUploading = false;
  double? _uploadProgress;
  AttachmentTransferCancelToken? _uploadCancelToken;
  final Set<String> _busyAttachmentIds = {};
  late final AttachmentCacheManager _cache =
      widget.cacheManager ?? AttachmentCacheManager();

  /// One cancel token per in-flight download, keyed by attachment ID, so
  /// several attachments can be opened or shared at once and each stays
  /// individually cancellable. Entries are removed in the download's
  /// `finally`, so the map is exactly the set of live downloads.
  final Map<String, AttachmentTransferCancelToken> _downloadTokens = {};

  /// Set the moment teardown begins -- explicit close or dispose -- and
  /// never cleared. Everything that could start new work checks it first,
  /// so nothing is kicked off on the way out.
  bool _closing = false;

  bool _disposed = false;

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

  /// Set when Hub says attachments are unsupported for this calendar.
  bool _attachmentsDisabled = false;

  bool get _effectiveCanAdd =>
      widget.canAdd && !widget.isSeriesScoped && !_attachmentsDisabled;
  bool get _effectiveCanRemove => widget.canRemove && !widget.isSeriesScoped;

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
    // directory across sessions.
    unawaited(_cache.close());
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

  /// The editor's "cancel attachment and close" path: stop the transfers,
  /// then wait for them to actually unwind so the screen is not dismissed
  /// on top of a live one. Bounded -- a transfer that refuses to unwind must
  /// not trap the user in the editor; disposal cancels it again regardless.
  Future<void> _cancelActiveTransfersAndSettle() async {
    // Only ever reached because the editor is closing with the user's
    // agreement, so nothing new may start from here on -- including from a
    // callback that lands while the cancellations are unwinding.
    _closing = true;
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
  }

  Future<void> _load() async {
    setState(() => _loadError = null);
    try {
      final attachments = await widget.hubClient.listAttachments(
        accessToken: widget.accessToken,
        eventId: widget.eventId,
      );
      if (!mounted) return;
      setState(() => _attachments = attachments);
    } catch (error) {
      if (!mounted) return;
      setState(() => _loadError = error);
    }
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
    try {
      await _runAddAttachment();
    } catch (error) {
      _debugLogAttachmentFailure('add', error);
      if (mounted) {
        _showMessage('Could not attach this file. Please try again.');
      }
    }
  }

  Future<void> _runAddAttachment() async {
    final source = await _pickSource();
    if (source == null || !mounted || _closing) return;

    final result = await _pickAttachmentFile(source);
    if (!mounted || _closing) return;

    switch (result) {
      // A normal cancellation is not an error and says nothing to the user.
      case _AttachmentPickCancelled():
        return;
      case _AttachmentPickFailed(:final message):
        _showMessage(message);
      case _AttachmentReady(:final file, :final originalFilename, :final size):
        // One logical operation begins here -- and with it, ONE idempotency
        // key that will survive every timeout and retry below.
        final pending = PendingAttachmentUpload(
          file: file,
          originalFilename: originalFilename,
          size: size,
        );
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

  /// Debug-only and deliberately category-level: an exception's type -- plus
  /// a platform exception's own code -- is enough to tell these failures
  /// apart. File contents, filenames, paths and tokens are never logged.
  static void _debugLogAttachmentFailure(String stage, Object error) {
    if (!kDebugMode) return;
    final detail = error is PlatformException
        ? 'PlatformException(${error.code})'
        : error.runtimeType.toString();
    debugPrint('EventAttachmentsSection: $stage failed -- $detail');
  }

  /// Sends (or re-sends) [_pendingUpload], always with its original
  /// idempotency key. Retrying via this method is what makes a retry the
  /// SAME operation to Hub rather than a new one that could duplicate.
  Future<void> _sendPendingUpload() async {
    final pending = _pendingUpload;
    if (pending == null || !mounted || _closing) return;

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
        file: pending.file,
        originalFilename: pending.originalFilename,
        idempotencyKey: pending.idempotencyKey,
        cancelToken: cancelToken,
        onProgress: (sent, total) {
          if (sent > 0) bytesLeftTheApp = true;
          if (!mounted) return;
          setState(() => _uploadProgress = total > 0 ? sent / total : null);
        },
      );
      if (!mounted) return;
      pending.state = AttachmentUploadState.completed;
      setState(() {
        _attachments = [...?_attachments, attachment];
        // Only clears the operation that actually completed: a discard
        // while this was in flight already replaced it with null, and
        // must not be undone here.
        if (identical(_pendingUpload, pending)) _pendingUpload = null;
      });
    } on CaleeHubException catch (e) {
      // Bytes have stopped moving the moment the call returns, so the
      // "transferring" state ends HERE -- not after the reconciliation that
      // may follow. Otherwise a screen waiting on an upload to stop would
      // sit through the whole status poll before it could close.
      _markUploadStopped();
      if (!mounted) return;
      await _handleUploadFailure(e, pending, bytesLeftTheApp);
    } catch (error) {
      _markUploadStopped();
      if (!mounted) return;
      _debugLogAttachmentFailure('upload', error);
      pending.state = AttachmentUploadState.retryable;
      _showMessage('Could not upload this attachment. Please try again.');
    } finally {
      _markUploadStopped();
    }
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
  void _markUploadStopped() {
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
        pending.state = AttachmentUploadState.cancelledUncertain;
        setState(() {});
        await _reconcilePendingUpload();
      } else {
        pending.state = AttachmentUploadState.cancelledBeforeSend;
        setState(() => _pendingUpload = null);
      }
      return;
    }

    final decision = decideAttachmentError(e);
    if (decision.message.isNotEmpty) {
      _showMessage(decision.message);
    }
    if (decision.nextUploadState != null) {
      pending.state = decision.nextUploadState!;
    }

    switch (decision.action) {
      case AttachmentErrorAction.reconcile:
        await _reconcilePendingUpload();
      case AttachmentErrorAction.refreshList:
        unawaited(_load());
      case AttachmentErrorAction.discardOperation:
        setState(() => _pendingUpload = null);
      case AttachmentErrorAction.disableAttachments:
        setState(() {
          _attachmentsDisabled = true;
          _pendingUpload = null;
        });
        unawaited(_load());
      case AttachmentErrorAction.showMessageOnly:
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
    if (_statusPollInFlight || _closing) return;
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
          idempotencyKey: pending.idempotencyKey,
        );
      } on CaleeHubException catch (e) {
        if (!mounted || generation != _pollGeneration) return;
        _applyStatusCheckFailure(pending, e);
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
        setState(() {
          _attachments = [...?_attachments, status.attachment!];
          pending.state = AttachmentUploadState.completed;
          _pendingUpload = null;
        });
        // Re-read the list so ordering and any server-side normalization are
        // reflected, but the COMPLETION itself is already decided.
        unawaited(_load());
        return;
      }

      if (status.kind.isFinalFailure) {
        setState(() => pending.state = AttachmentUploadState.failedFinal);
        _showMessage(
          status.kind == AttachmentUploadStatusKind.expired
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

  void _applyStatusCheckFailure(
    PendingAttachmentUpload pending,
    CaleeHubException e,
  ) {
    // Hub does not know this key. That is NOT success -- and it is not a
    // reason to re-upload silently either, since the operation may have been
    // deliberately detached. Require an explicit decision from the user.
    if (e.statusCode == 404 || e.statusCode == 410) {
      setState(() => pending.state = AttachmentUploadState.failedFinal);
      _showMessage(
        'That upload could not be confirmed. Please choose the file again.',
      );
      return;
    }
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
  void _discardPendingUpload() {
    _pollGeneration++;
    _uploadCancelToken?.cancel();
    if (mounted) {
      setState(() => _pendingUpload = null);
    } else {
      _pendingUpload = null;
    }
    _notifyOperationState();
  }

  void _cancelUpload() {
    _uploadCancelToken?.cancel();
  }

  // ── Remove ───────────────────────────────────────────────────────────────

  Future<void> _removeAttachment(CalendarAttachment attachment) async {
    final confirmed = await CaleeDestructiveDialog.show(
      context: context,
      title: 'Remove attachment?',
      body:
          '"${attachment.filename}" will be removed from this event. '
          'The original file is not deleted.',
      confirmLabel: 'Remove',
    );
    if (!confirmed || !mounted) return;

    // A detach request that has left cannot be recalled, so the editor is
    // told an action is running for exactly as long as it is in flight.
    _markAttachmentBusy(attachment.id);
    try {
      final updated = await widget.hubClient.detachAttachment(
        accessToken: widget.accessToken,
        eventId: widget.eventId,
        attachmentId: attachment.id,
      );
      if (!mounted) return;
      setState(() => _attachments = updated);
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
    if (_closing) return null;

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
        _closing) {
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
        _closing) {
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

  String _friendlyErrorMessage(
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
    final attachments = _attachments;
    final hasNothingToShow =
        attachments != null &&
        attachments.isEmpty &&
        !_effectiveCanAdd &&
        _loadError == null;

    if (hasNothingToShow) return const SizedBox.shrink();

    return CaleeSection(
      title: 'Attachments',
      footer: widget.isSeriesScoped
          ? 'Applies to all events in this series'
          : null,
      children: [
        if (attachments == null && _loadError == null)
          const CaleeListRow(
            title: 'Loading attachments…',
            leading: SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ),
        if (_loadError != null)
          CaleeListRow(
            title: 'Could not load attachments',
            subtitle: 'Tap to try again',
            leading: const Icon(
              Icons.error_outline,
              color: CaleeColors.destructive,
            ),
            onTap: _load,
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
        if (_effectiveCanAdd && !_isUploading && _pendingUploadNeedsAction)
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
                  onPressed: _retryPendingUpload,
                  child: const Text('Retry'),
                ),
                TextButton(
                  key: const Key('discard_pending_upload'),
                  onPressed: _discardPendingUpload,
                  child: const Text('Discard'),
                ),
              ],
            ),
          ),
        if (_effectiveCanAdd)
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
                : const Icon(Icons.add, color: CaleeColors.primary),
            titleStyle: TextStyle(
              color: _isUploading
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
            onTap: (_isUploading || _pendingUploadNeedsAction)
                ? null
                : _addAttachment,
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
