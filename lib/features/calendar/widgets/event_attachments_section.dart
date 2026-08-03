import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
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
    _load();
  }

  @override
  void dispose() {
    // Stops any in-flight status poll from continuing past this screen: the
    // generation check runs before every attempt and before every setState.
    _pollGeneration++;
    // Cached copies are only meant to live as long as the editor screen --
    // confidential family documents must not accumulate in the cache
    // directory across sessions.
    unawaited(_cache.clear());
    super.dispose();
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

  Future<_AttachmentSource?> _pickSource() async {
    final result = Completer<_AttachmentSource?>();
    await CaleeActionSheet.show(
      context: context,
      title: 'Add attachment',
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

  Future<void> _addAttachment() async {
    final source = await _pickSource();
    if (source == null || !mounted) return;

    File file;
    String originalName;
    if (source == _AttachmentSource.file) {
      final result = await FilePicker.pickFiles();
      final picked = result?.files.single;
      if (picked == null || picked.path == null || !mounted) return;
      file = File(picked.path!);
      // The picker's displayed name, NOT the (often cache/temp) path -- see
      // CaleeHubClient.uploadAttachment's originalFilename.
      originalName = picked.name;
    } else {
      final xFile = await ImagePicker().pickImage(
        source: source == _AttachmentSource.camera
            ? ImageSource.camera
            : ImageSource.gallery,
      );
      if (xFile == null || !mounted) return;
      file = File(xFile.path);
      originalName = xFile.name.trim().isEmpty
          ? 'photo.jpg' // camera captures can arrive unnamed
          : xFile.name;
    }

    final size = await file.length();
    if (size <= 0) {
      _showMessage('This file is empty and cannot be attached.');
      return;
    }
    if (size > kAttachmentMaxBytes) {
      _showMessage('This file is too large to attach (max 10 MB).');
      return;
    }
    final extension = originalName.contains('.')
        ? originalName.split('.').last.toLowerCase()
        : '';
    if (!kAttachmentAllowedExtensions.contains(extension)) {
      _showMessage('This file type cannot be attached.');
      return;
    }
    if (!mounted) return;

    // One logical operation begins here -- and with it, ONE idempotency
    // key that will survive every timeout and retry below.
    final pending = PendingAttachmentUpload(
      file: file,
      originalFilename: originalName,
      size: size,
    );
    setState(() => _pendingUpload = pending);
    await _sendPendingUpload();
  }

  /// Sends (or re-sends) [_pendingUpload], always with its original
  /// idempotency key. Retrying via this method is what makes a retry the
  /// SAME operation to Hub rather than a new one that could duplicate.
  Future<void> _sendPendingUpload() async {
    final pending = _pendingUpload;
    if (pending == null || !mounted) return;

    final cancelToken = AttachmentTransferCancelToken();
    var bytesLeftTheApp = false;
    pending.state = AttachmentUploadState.uploading;
    setState(() {
      _isUploading = true;
      _uploadProgress = 0;
      _uploadCancelToken = cancelToken;
    });

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
        _pendingUpload = null;
      });
    } on CaleeHubException catch (e) {
      if (!mounted) return;
      await _handleUploadFailure(e, pending, bytesLeftTheApp);
    } catch (error) {
      if (!mounted) return;
      if (kDebugMode) {
        debugPrint('EventAttachmentsSection: upload error=$error');
      }
      pending.state = AttachmentUploadState.retryable;
      _showMessage('Could not upload this attachment. Please try again.');
    } finally {
      if (mounted) {
        setState(() {
          _isUploading = false;
          _uploadProgress = null;
          _uploadCancelToken = null;
        });
      }
    }
  }

  /// Applies the per-code policy (Part I) to a failed upload. Every branch
  /// here decides three things explicitly: what the user is told, what the
  /// UI does next, and what happens to the pending operation's key.
  Future<void> _handleUploadFailure(
    CaleeHubException e,
    PendingAttachmentUpload pending,
    bool bytesLeftTheApp,
  ) async {
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
    if (_statusPollInFlight) return;
    _statusPollInFlight = true;
    final generation = _pollGeneration;
    try {
      await _pollUploadStatus(generation);
    } finally {
      _statusPollInFlight = false;
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

  /// Explicit user action: abandon the operation. Only after this does a
  /// subsequent pick mint a new idempotency key. Bumping the generation
  /// stops any in-flight status poll from writing back a result for an
  /// operation the user has already dismissed.
  void _discardPendingUpload() {
    _pollGeneration++;
    setState(() => _pendingUpload = null);
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

    setState(() => _busyAttachmentIds.add(attachment.id));
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
      if (kDebugMode) {
        debugPrint('EventAttachmentsSection: remove error=$error');
      }
      _showMessage('Could not remove this attachment. Please try again.');
    } finally {
      if (mounted) {
        setState(() => _busyAttachmentIds.remove(attachment.id));
      }
    }
  }

  // ── Download / open / share ─────────────────────────────────────────────

  /// Always re-downloads rather than trusting a previously cached copy: the
  /// attachment API exposes no content-version/ETag an attachment ID could
  /// be validated against, so a cached file can never be proven current.
  /// [AttachmentCacheManager] deletes the previous copy first and hands
  /// back a fresh, unpredictably-named target.
  Future<String?> _ensureDownloaded(CalendarAttachment attachment) async {
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
      );
    } catch (_) {
      // Never leave a partial (or truncated -- see Part E) file behind for
      // the user to open or share.
      await _cache.discardPartial(attachment.id);
      rethrow;
    }
    _cache.commit(attachmentId: attachment.id, file: destination);
    return destination.path;
  }

  Future<void> _openAttachment(CalendarAttachment attachment) async {
    if (!attachment.downloadAvailable ||
        _busyAttachmentIds.contains(attachment.id)) {
      return;
    }
    setState(() => _busyAttachmentIds.add(attachment.id));
    try {
      final path = await _ensureDownloaded(attachment);
      if (path == null || !mounted) return;
      final result = await widget.openFile(path);
      if (result.type != ResultType.done && mounted) {
        _showMessage('Could not open this attachment.');
      }
    } on CaleeHubException catch (e) {
      if (!mounted) return;
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
      if (!mounted) return;
      if (kDebugMode) debugPrint('EventAttachmentsSection: open error=$error');
      _showMessage('Could not open this attachment. Please try again.');
    } finally {
      if (mounted) {
        setState(() => _busyAttachmentIds.remove(attachment.id));
      }
    }
  }

  Future<void> _shareAttachment(CalendarAttachment attachment) async {
    if (!attachment.downloadAvailable ||
        _busyAttachmentIds.contains(attachment.id)) {
      return;
    }
    setState(() => _busyAttachmentIds.add(attachment.id));
    try {
      final path = await _ensureDownloaded(attachment);
      if (path == null || !mounted) return;
      await SharePlus.instance.share(ShareParams(files: [XFile(path)]));
    } on CaleeHubException catch (e) {
      if (!mounted) return;
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
      if (!mounted) return;
      if (kDebugMode) debugPrint('EventAttachmentsSection: share error=$error');
      _showMessage('Could not share this attachment. Please try again.');
    } finally {
      if (mounted) {
        setState(() => _busyAttachmentIds.remove(attachment.id));
      }
    }
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
              onShare: () => _shareAttachment(attachment),
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

  final CalendarAttachment attachment;
  final bool busy;
  final bool canRemove;
  final VoidCallback onOpen;
  final VoidCallback onShare;
  final VoidCallback onRemove;

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
                      child: IconButton(
                        icon: const Icon(Icons.ios_share, size: 20),
                        onPressed: onShare,
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(),
                      ),
                    ),
                  if (canRemove) ...[
                    const SizedBox(width: CaleeSpacing.sm),
                    Tooltip(
                      message: 'Remove ${attachment.filename} from event',
                      child: IconButton(
                        icon: const Icon(
                          Icons.close,
                          size: 20,
                          color: CaleeColors.destructive,
                        ),
                        onPressed: onRemove,
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(),
                      ),
                    ),
                  ],
                ],
              ),
      ),
    );
  }
}
