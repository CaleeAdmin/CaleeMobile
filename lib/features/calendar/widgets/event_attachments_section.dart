import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../../data/api/calee_hub_client.dart';
import '../../../data/models/client_calendar.dart';
import '../../../ui/calee_design.dart';

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

String generateAttachmentIdempotencyKey() {
  final random = Random.secure();
  final bytes = List<int>.generate(16, (_) => random.nextInt(256));
  return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}

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
  final Map<String, String> _downloadedPaths = {};

  bool get _effectiveCanAdd => widget.canAdd && !widget.isSeriesScoped;
  bool get _effectiveCanRemove => widget.canRemove && !widget.isSeriesScoped;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    // The cache this section builds up is only meant to live as long as the
    // editor screen itself -- clear it out rather than letting downloaded
    // copies accumulate in the cache directory across sessions.
    final paths = _downloadedPaths.values.toList();
    _downloadedPaths.clear();
    unawaited(
      Future.wait(
        paths.map((path) async {
          final file = File(path);
          if (await file.exists()) {
            await file.delete();
          }
        }),
      ),
    );
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
      originalName = picked.name;
    } else {
      final xFile = await ImagePicker().pickImage(
        source: source == _AttachmentSource.camera
            ? ImageSource.camera
            : ImageSource.gallery,
      );
      if (xFile == null || !mounted) return;
      file = File(xFile.path);
      originalName = xFile.name;
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

    final cancelToken = AttachmentTransferCancelToken();
    setState(() {
      _isUploading = true;
      _uploadProgress = 0;
      _uploadCancelToken = cancelToken;
    });

    try {
      final attachment = await widget.hubClient.uploadAttachment(
        accessToken: widget.accessToken,
        eventId: widget.eventId,
        file: file,
        idempotencyKey: generateAttachmentIdempotencyKey(),
        cancelToken: cancelToken,
        onProgress: (sent, total) {
          if (!mounted) return;
          setState(() => _uploadProgress = total > 0 ? sent / total : null);
        },
      );
      if (!mounted) return;
      setState(() {
        _attachments = [...?_attachments, attachment];
      });
    } on CaleeHubException catch (e) {
      if (!mounted) return;
      if (e.code == 'CANCELLED') {
        // User-initiated cancellation; no error to show.
      } else if (e.statusCode == 409) {
        _showMessage('This event changed elsewhere. Refreshing attachments.');
        unawaited(_load());
      } else if (e.code == 'TIMEOUT') {
        // A timeout means the outcome is genuinely unknown -- Hub may have
        // received and completed the upload even though this client gave up
        // waiting for the response. Reconcile against the source of truth
        // instead of assuming failure. This never mints a new idempotency
        // key itself; if the user taps "Add attachment" again, that's a
        // deliberate new attempt with its own fresh key.
        _showMessage('Upload status unknown. Checking for the attachment…');
        unawaited(_load());
      } else {
        _showMessage(
          _friendlyErrorMessage(
            e,
            fallback: 'Could not upload this attachment. Please try again.',
          ),
        );
      }
    } catch (error) {
      if (!mounted) return;
      if (kDebugMode) {
        debugPrint('EventAttachmentsSection: upload error=$error');
      }
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
      unawaited(_forgetCachedFile(attachment.id));
    } on CaleeHubException catch (e) {
      if (!mounted) return;
      if (e.statusCode == 409 || e.code == 'ATTACHMENT_NOT_FOUND') {
        _showMessage('This event changed elsewhere. Refreshing attachments.');
        await _load();
        unawaited(_forgetCachedFile(attachment.id));
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

  /// Deletes and forgets any cached local copy of [attachmentId], if one
  /// exists. Safe to call whether or not a copy was ever downloaded.
  Future<void> _forgetCachedFile(String attachmentId) async {
    final path = _downloadedPaths.remove(attachmentId);
    if (path == null) return;
    final file = File(path);
    if (await file.exists()) {
      await file.delete();
    }
  }

  /// Downloads [attachment] fresh to a new cache file with an unpredictable
  /// name (never the attachment ID or its original filename, so a cache
  /// directory listing can't be used to enumerate or guess at another
  /// event's attachments). path_provider's application-cache directory maps
  /// to NSCachesDirectory on iOS and Context.getCacheDir() on Android, both
  /// of which are already excluded from OS-level cloud/auto backups by
  /// platform convention -- no separate exclusion API is needed here.
  Future<File> _downloadToFreshCacheFile(CalendarAttachment attachment) async {
    final cacheDir = await getApplicationCacheDirectory();
    final random = Random.secure();
    final token = List<int>.generate(
      16,
      (_) => random.nextInt(256),
    ).map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    final rawExtension = attachment.filename.contains('.')
        ? attachment.filename.split('.').last.toLowerCase()
        : '';
    // Kept only so OS "open with" file-type detection still works; never
    // carries the original filename or the attachment ID.
    final safeExtension = rawExtension.replaceAll(RegExp(r'[^a-z0-9]'), '');
    final suffix = safeExtension.isEmpty ? '' : '.$safeExtension';
    final destination = File('${cacheDir.path}/att_cache_$token$suffix');

    await widget.hubClient.downloadAttachment(
      accessToken: widget.accessToken,
      eventId: widget.eventId,
      attachmentId: attachment.id,
      destinationFile: destination,
    );
    return destination;
  }

  /// Always re-downloads rather than trusting a previously cached copy: the
  /// attachment API exposes no content-version/ETag signal an attachment ID
  /// alone can be checked against, so treating an ID as a permanently-valid
  /// cache key risks silently serving stale bytes. The old copy (if any) is
  /// deleted first, bounding on-disk cache growth to at most one file per
  /// currently-open attachment.
  Future<String?> _ensureDownloaded(CalendarAttachment attachment) async {
    await _forgetCachedFile(attachment.id);
    final destination = await _downloadToFreshCacheFile(attachment);
    _downloadedPaths[attachment.id] = destination.path;
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
      final result = await OpenFilex.open(path);
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
            onTap: _isUploading ? null : _addAttachment,
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
