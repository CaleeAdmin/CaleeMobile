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

    case 'EVENT_NOT_FOUND':
      // The event this upload belongs to is gone -- deleted elsewhere, or
      // this editor is holding a stale ID. Retrying cannot conjure it back,
      // and the same file re-sent against the same missing event fails
      // identically every time, so this is terminal rather than retryable.
      // Without this branch it fell through to the generic tail below and
      // came back as "please try again" with a Retry button that could never
      // succeed.
      return const AttachmentErrorDecision(
        message: 'This event is no longer available.',
        action: AttachmentErrorAction.discardOperation,
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

    case 'ATTACHMENT_UPLOAD_FAILED':
    case 'UPSTREAM_ERROR':
      // Hub reached the calendar service and the calendar service would not
      // take the file. WHY decides everything about what happens next, and
      // the status is the only thing that says why -- so these two codes
      // are split by status rather than sharing the generic tail, where
      // both used to land as one indistinguishable "please try again".
      if (e.statusCode == 507) {
        // Insufficient Storage. The account is out of room, so this will
        // fail identically until somebody frees some -- but that is a thing
        // the user can actually go and do, and the file must still be there
        // when they come back. Kept, with its key, retryable ONLY by an
        // explicit tap: an automatic retry would hammer a full disk.
        return const AttachmentErrorDecision(
          message: 'There is not enough storage available for this attachment.',
          action: AttachmentErrorAction.showMessageOnly,
          nextUploadState: AttachmentUploadState.retryable,
          keepsIdempotencyKey: true,
        );
      }
      if (e.statusCode == 502 || e.statusCode == 503 || e.statusCode == 504) {
        // The calendar service is down, overloaded or timing out upstream.
        // Nothing about the file or the event is wrong, so the operation
        // survives intact -- same staged file, same key, so a retry that
        // lands after the service recovers is recognised as this same
        // upload and cannot duplicate it.
        return const AttachmentErrorDecision(
          message:
              'The calendar service could not store this file. Try again '
              'shortly.',
          action: AttachmentErrorAction.showMessageOnly,
          nextUploadState: AttachmentUploadState.retryable,
          keepsIdempotencyKey: true,
        );
      }
      // Any other status under these codes falls through to the
      // status-class rules below, which already tell 5xx from 4xx.
      break;
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

  // An unrecognised SERVER error. The request was presumably fine and the
  // server had the problem, so the operation is kept whole -- staged file,
  // idempotency key and all -- and offered as a retry.
  if (e.statusCode >= 500 && e.statusCode < 600) {
    return const AttachmentErrorDecision(
      message: 'The calendar service could not complete this right now.',
      action: AttachmentErrorAction.showMessageOnly,
      nextUploadState: AttachmentUploadState.retryable,
      keepsIdempotencyKey: true,
    );
  }

  // An unrecognised CLIENT error, and the reason this is not one generic
  // tail with the 5xx case above.
  //
  // A 4xx says the request itself was refused. Re-sending the same bytes,
  // for the same event, under the same key produces the same refusal --
  // every time, forever. Treating these as retryable (which the old shared
  // tail did) gave the user a Retry button that could not work, and left
  // their staged file on disk indefinitely behind it. So this is terminal:
  // the operation ends, the staged file is released through the normal
  // terminal-finalization path, and the user is told plainly rather than
  // invited to keep tapping.
  //
  // This is the DEFAULT for unrecognised 4xx only. Every 4xx this build
  // knows how to act on -- 409 above, and the whole stable-code table
  // before it (limit reached, occurrence-scoped, too large, wrong type,
  // idempotency conflict, missing event, unsupported calendar) -- has
  // already returned its own decision and never reaches here.
  if (e.statusCode >= 400 && e.statusCode < 500) {
    return const AttachmentErrorDecision(
      message: 'This attachment could not be added to this event.',
      action: AttachmentErrorAction.discardOperation,
      nextUploadState: AttachmentUploadState.failedFinal,
    );
  }

  // Status 0 (transport) and anything else unclassifiable: nothing here
  // proves the request was rejected, so the forgiving answer is right.
  return const AttachmentErrorDecision(
    message: 'Could not complete this attachment action. Please try again.',
    action: AttachmentErrorAction.showMessageOnly,
    nextUploadState: AttachmentUploadState.retryable,
    keepsIdempotencyKey: true,
  );
}

/// The support reference for [e] -- Hub's own request ID -- or null when the
/// response carried none.
///
/// Deliberately nothing but the ID. [CaleeHubException] also holds the
/// endpoint and Hub's raw message, and [CaleeHubException.debugSummary]
/// exists precisely so those can go to a debug log; none of them belongs on
/// a user's screen. The ID is server-generated, opaque, and derived from no
/// account, event or file, so it is the one diagnostic that is safe to show
/// and safe for someone to paste into a support conversation.
String? attachmentSupportReference(CaleeHubException e) {
  final requestId = e.requestId?.trim();
  if (requestId == null || requestId.isEmpty) return null;
  return requestId;
}

/// [message] with a support reference appended, when there is one to append.
///
/// Two things this must never produce, both of which are why it is a
/// function rather than string interpolation at each call site: a dangling
/// "Reference: null" when Hub sent no ID (older Hub builds, and every
/// purely local failure), and a reference attached to a message that is
/// deliberately empty -- a user-initiated cancellation says nothing at all,
/// and must not suddenly start saying something.
///
/// The reference goes on its own line so the sentence the user actually
/// needs to read stays first and stays whole.
String attachmentErrorMessageWithReference(String message, Object error) {
  if (message.isEmpty || error is! CaleeHubException) return message;

  final reference = attachmentSupportReference(error);
  if (reference == null) return message;

  return '$message\nReference: $reference';
}
