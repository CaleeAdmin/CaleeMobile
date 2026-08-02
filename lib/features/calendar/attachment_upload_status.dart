// The authoritative answer to "what happened to the upload I started with
// this idempotency key?".
//
// This type exists to replace an inference. When an upload timed out or was
// cancelled after bytes had left the device, the app used to decide whether
// it had landed by scanning the event's attachment list for one whose
// FILENAME AND SIZE matched what it had sent. Neither of those identifies
// anything: two genuinely different files can share a name and a byte count,
// and families really do attach `scan.pdf` more than once. A pre-existing
// same-name, same-size attachment would be reported as this upload's
// success, and the user's document would silently never be attached.
//
// The idempotency key identifies the logical operation. It is the only thing
// that may resolve it, so the client asks Hub about the key and believes the
// answer.
import 'package:calee_mobile/data/models/client_calendar.dart';

/// The closed set of statuses Hub reports for one upload operation.
///
/// Deliberately coarse: the client needs to know what to DO, not how Hub's
/// ledger is organized. Anything Hub adds later that this build does not
/// recognise arrives as [unknown], which is treated as "not established" --
/// never as success.
enum AttachmentUploadStatusKind {
  /// Someone is actively driving this operation right now. Keep the key,
  /// keep waiting, do not start a second upload.
  inProgress,

  /// Hub cannot yet establish what happened. Keep the key.
  reconciliationRequired,

  /// It failed in a way a same-key retry can fix.
  retryable,

  /// Done. [AttachmentUploadStatus.attachment] carries the real attachment.
  completed,

  /// Final failure. A new operation (and a new key) is required.
  failed,

  /// The key's window has closed. Final; a new key is required.
  expired,

  /// A status this build does not know. Treated as not-yet-established.
  unknown;

  static AttachmentUploadStatusKind fromWire(String? value) {
    switch (value) {
      case 'in_progress':
        return AttachmentUploadStatusKind.inProgress;
      case 'reconciliation_required':
        return AttachmentUploadStatusKind.reconciliationRequired;
      case 'retryable':
        return AttachmentUploadStatusKind.retryable;
      case 'completed':
        return AttachmentUploadStatusKind.completed;
      case 'failed':
        return AttachmentUploadStatusKind.failed;
      case 'expired':
        return AttachmentUploadStatusKind.expired;
      default:
        return AttachmentUploadStatusKind.unknown;
    }
  }

  /// True while the operation may still change on its own, so polling again
  /// can produce a different answer. [completed], [failed] and [expired] are
  /// final; [unknown] is not polled because this build cannot interpret it.
  bool get isSettling =>
      this == AttachmentUploadStatusKind.inProgress ||
      this == AttachmentUploadStatusKind.reconciliationRequired;

  /// True when the operation reached a permanent answer and the pending
  /// operation must be discarded rather than retried with the same key.
  bool get isFinalFailure =>
      this == AttachmentUploadStatusKind.failed ||
      this == AttachmentUploadStatusKind.expired;
}

class AttachmentUploadStatus {
  const AttachmentUploadStatus({
    required this.kind,
    required this.retryable,
    this.attachment,
  });

  final AttachmentUploadStatusKind kind;

  /// Hub's own view of whether a same-key retry could still help. The client
  /// respects it, but never lets it override a [completed] answer.
  final bool retryable;

  /// Present only for [AttachmentUploadStatusKind.completed].
  final CalendarAttachment? attachment;

  factory AttachmentUploadStatus.fromJson(Map<String, dynamic> json) {
    final upload = json['upload'];
    final map = upload is Map<String, dynamic> ? upload : json;
    final rawAttachment = map['attachment'];
    return AttachmentUploadStatus(
      kind: AttachmentUploadStatusKind.fromWire(map['status'] as String?),
      retryable: map['retryable'] as bool? ?? true,
      attachment: rawAttachment is Map<String, dynamic>
          ? CalendarAttachment.fromJson(rawAttachment)
          : null,
    );
  }

  /// A completed status whose attachment payload is missing is NOT treated
  /// as completed -- claiming success without the thing that succeeded is
  /// exactly the failure mode this whole type replaces.
  bool get isUsableCompletion =>
      kind == AttachmentUploadStatusKind.completed && attachment != null;
}
