import 'dart:io';
import 'dart:math';

/// Where a single logical "attach this file" operation currently stands.
///
/// The states exist to separate outcomes that are genuinely different but
/// look alike from inside a `catch` block -- above all, "we know this did
/// not happen" from "we do not know whether this happened".
enum AttachmentUploadState {
  /// The user picked a file; nothing has been sent.
  selected,

  /// Bytes are on the wire.
  uploading,

  /// The outcome is UNKNOWN (timeout, or Hub reported the upload still in
  /// progress). The attachment list is being re-checked to find out.
  reconciling,

  /// Failed in a way that a retry of the SAME operation could fix.
  retryable,

  /// Hub confirmed the attachment exists.
  completed,

  /// Cancelled before any request could have reached Hub -- safe to drop.
  cancelledBeforeSend,

  /// Cancelled after the request may already have reached Hub, so the
  /// server-side outcome is unknown until reconciled.
  cancelledUncertain,

  /// Failed conclusively; retrying the same operation cannot help.
  failedFinal,
}

String generateAttachmentIdempotencyKey() {
  final random = Random.secure();
  final bytes = List<int>.generate(16, (_) => random.nextInt(256));
  return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}

/// One logical upload operation, from file selection to a confirmed
/// outcome.
///
/// The point of this object is [idempotencyKey]. It is minted ONCE, when
/// the user selects the file, and then survives every timeout, retry and
/// uncertain cancellation for that same file. Previously the key was
/// generated inside the upload call, so a retry after a timeout was a
/// brand-new key -- and therefore, to Hub, a brand-new upload. If the
/// timed-out attempt had actually succeeded server-side, that retry
/// silently produced a duplicate attachment. Keeping the key stable is
/// what lets Hub recognise the retry as the same operation and return the
/// original attachment instead.
///
/// A new key is minted only by constructing a NEW instance, which happens
/// exactly when the user selects a different file or deliberately discards
/// this operation.
class PendingAttachmentUpload {
  PendingAttachmentUpload({
    required this.file,
    required this.originalFilename,
    required this.size,
    String? idempotencyKey,
    DateTime? createdAt,
    this.state = AttachmentUploadState.selected,
  }) : idempotencyKey = idempotencyKey ?? generateAttachmentIdempotencyKey(),
       createdAt = createdAt ?? DateTime.now();

  final File file;

  /// The name the user knows this document by (from the platform picker),
  /// never derived from [file]'s cache/temp path.
  final String originalFilename;

  final int size;

  /// Stable for the lifetime of this operation -- see the class doc.
  final String idempotencyKey;

  final DateTime createdAt;

  AttachmentUploadState state;

  /// True while the operation is still worth acting on -- i.e. the user
  /// could still retry it, or the app still owes them a reconciliation.
  bool get isActive =>
      state == AttachmentUploadState.selected ||
      state == AttachmentUploadState.uploading ||
      state == AttachmentUploadState.reconciling ||
      state == AttachmentUploadState.retryable ||
      state == AttachmentUploadState.cancelledUncertain;

  /// True when the same key may be re-sent for this same file.
  bool get canRetryWithSameKey =>
      state == AttachmentUploadState.retryable ||
      state == AttachmentUploadState.cancelledUncertain ||
      state == AttachmentUploadState.reconciling;

  /// True when the outcome is genuinely unknown and must be reconciled
  /// against Hub rather than assumed either way.
  bool get isUncertain =>
      state == AttachmentUploadState.reconciling ||
      state == AttachmentUploadState.cancelledUncertain;

  PendingAttachmentUpload copyWith({AttachmentUploadState? state}) {
    return PendingAttachmentUpload(
      file: file,
      originalFilename: originalFilename,
      size: size,
      // Deliberately carried over: a state change is never a new operation.
      idempotencyKey: idempotencyKey,
      createdAt: createdAt,
      state: state ?? this.state,
    );
  }
}
