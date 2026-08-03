import '../../data/api/calee_hub_client.dart';
import 'pending_attachment_upload.dart';

/// What the UI should do about a failed attachment operation.
enum AttachmentErrorAction {
  /// Show the message; nothing else changes.
  showMessageOnly,

  /// Refresh the attachment list (and event state) before the user acts.
  refreshList,

  /// The outcome is unknown -- reconcile against Hub, keeping the same
  /// idempotency key, before offering a retry.
  reconcile,

  /// The pending operation is unusable; the user must discard it and pick
  /// the file again.
  discardOperation,

  /// Attachments are not available on this calendar at all -- disable the
  /// mutation affordances.
  disableAttachments,
}

/// The decision for one attachment error: what to tell the user, what the
/// UI should do, and what happens to the in-flight upload operation.
class AttachmentErrorDecision {
  const AttachmentErrorDecision({
    required this.message,
    required this.action,
    required this.nextUploadState,
    this.keepsIdempotencyKey = false,
    this.autoRetryAllowed = false,
  });

  final String message;
  final AttachmentErrorAction action;

  /// Null when the error does not concern an in-flight upload.
  final AttachmentUploadState? nextUploadState;

  /// Whether a subsequent retry must reuse the SAME idempotency key.
  final bool keepsIdempotencyKey;

  /// Whether the app may retry without the user asking. Deliberately false
  /// for everything except the bounded reconciliation poll.
  final bool autoRetryAllowed;
}

/// Maps Hub's stable machine-readable attachment error codes to concrete UI
/// behavior (Part I).
///
/// Branching on the HTTP status alone was wrong: 409 alone covers a stale
/// event, an upload still in progress, a reused idempotency key, an
/// unconfirmable size, an unsupported calendar, an occurrence-scoped
/// request and a reached limit -- which need six different responses, and
/// three different fates for the pending upload. The stable `code` is
/// always preferred; the status is only a fallback for a response that
/// somehow carries no code.
AttachmentErrorDecision decideAttachmentError(CaleeHubException e) {
  switch (e.code) {
    case 'CALENDAR_OBJECT_CONFLICT':
      // The event moved under us. The upload itself is still valid and
      // must keep its key so a retry is recognised as the same operation.
      return const AttachmentErrorDecision(
        message:
            'This event changed elsewhere. Refreshing, then you can try '
            'attaching again.',
        action: AttachmentErrorAction.refreshList,
        nextUploadState: AttachmentUploadState.retryable,
        keepsIdempotencyKey: true,
      );

    case 'ATTACHMENT_UPLOAD_IN_PROGRESS':
      // Hub is still working on THIS operation. Never start a second one.
      return const AttachmentErrorDecision(
        message: 'This attachment is still being processed…',
        action: AttachmentErrorAction.reconcile,
        nextUploadState: AttachmentUploadState.reconciling,
        keepsIdempotencyKey: true,
        autoRetryAllowed: true,
      );

    case 'TIMEOUT':
      // Unknown outcome: Hub may have completed the upload after we gave
      // up waiting. Reconcile rather than assume either way.
      return const AttachmentErrorDecision(
        message: 'Upload status unknown. Checking whether it completed…',
        action: AttachmentErrorAction.reconcile,
        nextUploadState: AttachmentUploadState.reconciling,
        keepsIdempotencyKey: true,
        autoRetryAllowed: true,
      );

    case 'IDEMPOTENCY_KEY_REUSED':
      // The key is bound to a different payload -- the local operation and
      // Hub's record of it have diverged. Retrying cannot reconcile that.
      return const AttachmentErrorDecision(
        message:
            'This upload could not be matched to your file. Please '
            'choose the file again.',
        action: AttachmentErrorAction.discardOperation,
        nextUploadState: AttachmentUploadState.failedFinal,
      );

    case 'ATTACHMENT_STORAGE_COLLISION':
      // Server-side storage inconsistency for this operation's own path.
      // A fresh operation (new key) is the correct recovery.
      return const AttachmentErrorDecision(
        message:
            'Could not store this attachment because of a conflicting '
            'file. Please choose the file again.',
        action: AttachmentErrorAction.discardOperation,
        nextUploadState: AttachmentUploadState.failedFinal,
      );

    case 'ATTACHMENT_SIZE_UNAVAILABLE':
      return const AttachmentErrorDecision(
        message:
            'Could not confirm this event\'s existing attachments right '
            'now. Please try again.',
        action: AttachmentErrorAction.showMessageOnly,
        nextUploadState: AttachmentUploadState.retryable,
        keepsIdempotencyKey: true,
      );

    case 'ATTACHMENT_UPLOAD_RETRY_LATER':
      return const AttachmentErrorDecision(
        message: 'Could not finish this upload yet. Please try again shortly.',
        action: AttachmentErrorAction.showMessageOnly,
        nextUploadState: AttachmentUploadState.retryable,
        keepsIdempotencyKey: true,
      );

    case 'ATTACHMENTS_NOT_SUPPORTED_FOR_CALENDAR':
      return const AttachmentErrorDecision(
        message: 'Attachments are not supported for this calendar.',
        action: AttachmentErrorAction.disableAttachments,
        nextUploadState: AttachmentUploadState.failedFinal,
      );

    case 'ATTACHMENT_OCCURRENCE_NOT_SUPPORTED':
      return const AttachmentErrorDecision(
        message:
            'Attachments apply to the whole series. Edit the series to '
            'change them.',
        action: AttachmentErrorAction.showMessageOnly,
        nextUploadState: AttachmentUploadState.failedFinal,
      );

    case 'ATTACHMENT_LIMIT_REACHED':
      return const AttachmentErrorDecision(
        message: 'This event has reached its attachment limit.',
        action: AttachmentErrorAction.showMessageOnly,
        nextUploadState: AttachmentUploadState.failedFinal,
      );

    case 'ATTACHMENT_FILE_UNAVAILABLE':
      return const AttachmentErrorDecision(
        message: 'This file is no longer available.',
        action: AttachmentErrorAction.refreshList,
        nextUploadState: null,
      );

    case 'ATTACHMENT_NOT_FOUND':
      return const AttachmentErrorDecision(
        message: 'This attachment is no longer on this event.',
        action: AttachmentErrorAction.refreshList,
        nextUploadState: null,
      );

    case 'ATTACHMENT_DOWNLOAD_FAILED':
      return const AttachmentErrorDecision(
        message:
            'This attachment did not download completely. Please try '
            'again.',
        action: AttachmentErrorAction.showMessageOnly,
        nextUploadState: null,
      );

    case 'ATTACHMENT_TOO_LARGE':
      return const AttachmentErrorDecision(
        message: 'This file is too large to attach.',
        action: AttachmentErrorAction.discardOperation,
        nextUploadState: AttachmentUploadState.failedFinal,
      );

    case 'ATTACHMENT_TYPE_NOT_ALLOWED':
      return const AttachmentErrorDecision(
        message: 'This file type cannot be attached.',
        action: AttachmentErrorAction.discardOperation,
        nextUploadState: AttachmentUploadState.failedFinal,
      );

    case 'NETWORK_ERROR':
      return const AttachmentErrorDecision(
        message: 'Check your connection and try again.',
        action: AttachmentErrorAction.showMessageOnly,
        nextUploadState: AttachmentUploadState.retryable,
        keepsIdempotencyKey: true,
      );

    case 'CANCELLED':
      // The caller decides between cancelledBeforeSend and
      // cancelledUncertain -- it knows whether bytes reached the wire.
      return const AttachmentErrorDecision(
        message: '',
        action: AttachmentErrorAction.showMessageOnly,
        nextUploadState: null,
      );
  }

  // No recognised code. Fall back on the status, but never pretend a
  // bare 409 is specifically a stale-event conflict.
  if (e.statusCode == 409) {
    return const AttachmentErrorDecision(
      message: 'This event could not be updated right now. Refreshing.',
      action: AttachmentErrorAction.refreshList,
      nextUploadState: AttachmentUploadState.retryable,
      keepsIdempotencyKey: true,
    );
  }

  return const AttachmentErrorDecision(
    message: 'Could not complete this attachment action. Please try again.',
    action: AttachmentErrorAction.showMessageOnly,
    nextUploadState: AttachmentUploadState.retryable,
    keepsIdempotencyKey: true,
  );
}
