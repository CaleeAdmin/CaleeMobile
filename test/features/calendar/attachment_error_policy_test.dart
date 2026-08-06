// Unit tests for the per-error-code attachment policy (Part I).
//
// The bug this guards against: treating every 409 as "this event changed
// elsewhere". A 409 from Hub can mean a stale event, an upload still in
// progress, a reused idempotency key, an unconfirmable combined size, an
// unsupported calendar, an occurrence-scoped request, or a reached limit --
// seven different situations needing different messages, different UI
// actions, and (critically) three different fates for the in-flight upload's
// idempotency key.
import 'dart:io';

import 'package:calee_mobile/data/api/calee_hub_client.dart';
import 'package:calee_mobile/features/calendar/attachment_error_policy.dart';
import 'package:calee_mobile/features/calendar/attachment_upload_staging_manager.dart';
import 'package:calee_mobile/features/calendar/pending_attachment_upload.dart';
import 'package:flutter_test/flutter_test.dart';

/// [code] is nullable so a response that carried no stable code -- the case
/// the status-class rules exist for -- can be expressed.
CaleeHubException error(String? code, {int statusCode = 409}) =>
    CaleeHubException(statusCode: statusCode, code: code, message: 'x');

/// A PendingAttachmentUpload now owns its staged copy rather than a bare
/// File; these key-stability tests never touch the filesystem, so the record
/// is built directly. No path is read or written by anything below.
StagedAttachmentFile stagedStub() => StagedAttachmentFile(
  file: File('/tmp/x.pdf'),
  originalFilename: 'x.pdf',
  size: 10,
);

void main() {
  group('every documented code gets a distinct, deliberate decision', () {
    test('CALENDAR_OBJECT_CONFLICT refreshes and keeps the key', () {
      final d = decideAttachmentError(error('CALENDAR_OBJECT_CONFLICT'));
      expect(d.action, AttachmentErrorAction.refreshList);
      expect(d.nextUploadState, AttachmentUploadState.retryable);
      expect(d.keepsIdempotencyKey, isTrue);
      expect(d.message, contains('changed elsewhere'));
    });

    test('ATTACHMENT_UPLOAD_IN_PROGRESS reconciles and keeps the key', () {
      final d = decideAttachmentError(error('ATTACHMENT_UPLOAD_IN_PROGRESS'));
      expect(d.action, AttachmentErrorAction.reconcile);
      expect(d.nextUploadState, AttachmentUploadState.reconciling);
      expect(d.keepsIdempotencyKey, isTrue);
      expect(
        d.autoRetryAllowed,
        isTrue,
        reason: 'a bounded reconciliation poll is the whole point here',
      );
    });

    test('TIMEOUT reconciles and keeps the key', () {
      final d = decideAttachmentError(error('TIMEOUT', statusCode: 0));
      expect(d.action, AttachmentErrorAction.reconcile);
      expect(d.nextUploadState, AttachmentUploadState.reconciling);
      expect(d.keepsIdempotencyKey, isTrue);
    });

    test('IDEMPOTENCY_KEY_REUSED discards, never auto-retries', () {
      final d = decideAttachmentError(error('IDEMPOTENCY_KEY_REUSED'));
      expect(d.action, AttachmentErrorAction.discardOperation);
      expect(d.nextUploadState, AttachmentUploadState.failedFinal);
      expect(
        d.keepsIdempotencyKey,
        isFalse,
        reason: 'the key is the thing that is wrong -- reusing it cannot help',
      );
      expect(d.autoRetryAllowed, isFalse);
      expect(d.message, contains('choose the file again'));
    });

    test('ATTACHMENT_STORAGE_COLLISION discards the operation', () {
      final d = decideAttachmentError(error('ATTACHMENT_STORAGE_COLLISION'));
      expect(d.action, AttachmentErrorAction.discardOperation);
      expect(d.nextUploadState, AttachmentUploadState.failedFinal);
      expect(d.autoRetryAllowed, isFalse);
    });

    test('ATTACHMENT_SIZE_UNAVAILABLE stays retryable with the same key', () {
      final d = decideAttachmentError(error('ATTACHMENT_SIZE_UNAVAILABLE'));
      expect(d.action, AttachmentErrorAction.showMessageOnly);
      expect(d.nextUploadState, AttachmentUploadState.retryable);
      expect(d.keepsIdempotencyKey, isTrue);
    });

    test('ATTACHMENT_UPLOAD_RETRY_LATER stays retryable with the same key', () {
      final d = decideAttachmentError(
        error('ATTACHMENT_UPLOAD_RETRY_LATER', statusCode: 503),
      );
      expect(d.nextUploadState, AttachmentUploadState.retryable);
      expect(d.keepsIdempotencyKey, isTrue);
    });

    test('ATTACHMENTS_NOT_SUPPORTED_FOR_CALENDAR disables attachments', () {
      final d = decideAttachmentError(
        error('ATTACHMENTS_NOT_SUPPORTED_FOR_CALENDAR'),
      );
      expect(d.action, AttachmentErrorAction.disableAttachments);
      expect(d.nextUploadState, AttachmentUploadState.failedFinal);
    });

    test('ATTACHMENT_OCCURRENCE_NOT_SUPPORTED explains series scope', () {
      final d = decideAttachmentError(
        error('ATTACHMENT_OCCURRENCE_NOT_SUPPORTED'),
      );
      expect(d.action, AttachmentErrorAction.showMessageOnly);
      expect(d.message, contains('whole series'));
      expect(d.nextUploadState, AttachmentUploadState.failedFinal);
    });

    test('ATTACHMENT_LIMIT_REACHED never auto-retries', () {
      final d = decideAttachmentError(error('ATTACHMENT_LIMIT_REACHED'));
      expect(d.action, AttachmentErrorAction.showMessageOnly);
      expect(d.autoRetryAllowed, isFalse);
      expect(d.nextUploadState, AttachmentUploadState.failedFinal);
    });

    test('ATTACHMENT_FILE_UNAVAILABLE refreshes the list', () {
      final d = decideAttachmentError(error('ATTACHMENT_FILE_UNAVAILABLE'));
      expect(d.action, AttachmentErrorAction.refreshList);
      expect(d.nextUploadState, isNull);
    });

    test('ATTACHMENT_DOWNLOAD_FAILED reports a failed download', () {
      final d = decideAttachmentError(
        error('ATTACHMENT_DOWNLOAD_FAILED', statusCode: 0),
      );
      expect(d.action, AttachmentErrorAction.showMessageOnly);
      expect(d.message, contains('did not download completely'));
    });
  });

  group('the 409 family is genuinely differentiated', () {
    test('no two 409 codes share both message and action', () {
      const codes = [
        'CALENDAR_OBJECT_CONFLICT',
        'ATTACHMENT_UPLOAD_IN_PROGRESS',
        'IDEMPOTENCY_KEY_REUSED',
        'ATTACHMENT_STORAGE_COLLISION',
        'ATTACHMENT_SIZE_UNAVAILABLE',
        'ATTACHMENTS_NOT_SUPPORTED_FOR_CALENDAR',
        'ATTACHMENT_OCCURRENCE_NOT_SUPPORTED',
        'ATTACHMENT_LIMIT_REACHED',
      ];

      final seen = <String>{};
      for (final code in codes) {
        final d = decideAttachmentError(error(code));
        final signature = '${d.action}|${d.message}';
        expect(
          seen.contains(signature),
          isFalse,
          reason:
              '$code produced the same message+action as an earlier 409 code, '
              'which is exactly the collapsing this policy exists to prevent',
        );
        seen.add(signature);
      }
      expect(seen, hasLength(codes.length));
    });

    test(
      'none of the 409 codes fall through to the generic stale-event message',
      () {
        const genericMessage =
            'This event could not be updated right now. Refreshing.';
        for (final code in [
          'ATTACHMENT_UPLOAD_IN_PROGRESS',
          'IDEMPOTENCY_KEY_REUSED',
          'ATTACHMENT_SIZE_UNAVAILABLE',
          'ATTACHMENTS_NOT_SUPPORTED_FOR_CALENDAR',
          'ATTACHMENT_OCCURRENCE_NOT_SUPPORTED',
          'ATTACHMENT_LIMIT_REACHED',
        ]) {
          expect(
            decideAttachmentError(error(code)).message,
            isNot(genericMessage),
            reason: '$code must not be reported as a generic event conflict',
          );
        }
      },
    );
  });

  group('fallbacks', () {
    test('an unknown code with a 409 falls back without over-claiming', () {
      final d = decideAttachmentError(error('SOMETHING_NEW_FROM_A_NEWER_HUB'));
      expect(d.action, AttachmentErrorAction.refreshList);
      expect(
        d.message,
        isNot(contains('changed elsewhere')),
        reason: 'an unrecognised 409 is not known to be a stale-event conflict',
      );
    });

    test('an unknown code with no status is retryable, not fatal', () {
      final d = decideAttachmentError(error('MYSTERY', statusCode: 500));
      expect(d.nextUploadState, AttachmentUploadState.retryable);
      expect(d.keepsIdempotencyKey, isTrue);
    });

    test('a null code is handled without throwing', () {
      const e = CaleeHubException(statusCode: 500, message: 'boom');
      final d = decideAttachmentError(e);
      expect(d.message, isNotEmpty);
    });
  });

  group('PendingAttachmentUpload key stability', () {
    test('the key is minted once and survives state changes', () {
      final upload = PendingAttachmentUpload(staged: stagedStub());
      final original = upload.idempotencyKey;

      final reconciling = upload.copyWith(
        state: AttachmentUploadState.reconciling,
      );
      final retryable = reconciling.copyWith(
        state: AttachmentUploadState.retryable,
      );

      expect(reconciling.idempotencyKey, original);
      expect(retryable.idempotencyKey, original);
    });

    test('a separate operation gets a different key', () {
      final a = PendingAttachmentUpload(staged: stagedStub());
      final b = PendingAttachmentUpload(staged: stagedStub());
      expect(a.idempotencyKey, isNot(b.idempotencyKey));
    });

    test('uncertain states are the ones that must be reconciled', () {
      for (final state in [
        AttachmentUploadState.reconciling,
        AttachmentUploadState.cancelledUncertain,
      ]) {
        final upload = PendingAttachmentUpload(
          staged: stagedStub(),
          state: state,
        );
        expect(upload.isUncertain, isTrue, reason: '$state must be uncertain');
        expect(upload.canRetryWithSameKey, isTrue);
      }
    });

    test('a cancel before send is NOT uncertain and needs no reconcile', () {
      final upload = PendingAttachmentUpload(
        staged: stagedStub(),
        state: AttachmentUploadState.cancelledBeforeSend,
      );
      expect(upload.isUncertain, isFalse);
      expect(upload.canRetryWithSameKey, isFalse);
      expect(upload.isActive, isFalse);
    });

    test('a conclusively failed operation cannot be silently retried', () {
      final upload = PendingAttachmentUpload(
        staged: stagedStub(),
        state: AttachmentUploadState.failedFinal,
      );
      expect(upload.canRetryWithSameKey, isFalse);
      expect(upload.isActive, isFalse);
    });
  });

  // ── Upload-failure classes ────────────────────────────────────────────────
  //
  // ATTACHMENT_UPLOAD_FAILED and UPSTREAM_ERROR used to fall through to one
  // generic tail that made every one of them "please try again" with the
  // operation kept. That is right for a service that is briefly down, wrong
  // for a full disk (the same wording tells the user nothing about what to
  // do), and outright harmful for a rejected request, which fails
  // identically however many times it is re-sent.
  group('upload failure classes are told apart by status', () {
    test('507 says storage, and keeps the file and the key', () {
      final d = decideAttachmentError(
        error('ATTACHMENT_UPLOAD_FAILED', statusCode: 507),
      );
      expect(
        d.message,
        'There is not enough storage available for this attachment.',
      );
      expect(d.nextUploadState, AttachmentUploadState.retryable);
      expect(
        d.keepsIdempotencyKey,
        isTrue,
        reason: 'a retry after freeing space is the SAME upload',
      );
      expect(
        d.autoRetryAllowed,
        isFalse,
        reason: 'nothing may re-send this on its own -- the disk is still full',
      );
      expect(d.action, AttachmentErrorAction.showMessageOnly);
    });

    for (final status in [502, 503, 504]) {
      test(
        '$status is a retryable service failure that keeps file and key',
        () {
          for (final code in ['ATTACHMENT_UPLOAD_FAILED', 'UPSTREAM_ERROR']) {
            final d = decideAttachmentError(error(code, statusCode: status));
            expect(
              d.message,
              'The calendar service could not store this file. Try again '
              'shortly.',
              reason: '$code/$status',
            );
            expect(d.nextUploadState, AttachmentUploadState.retryable);
            expect(d.keepsIdempotencyKey, isTrue, reason: '$code/$status');
            expect(
              d.autoRetryAllowed,
              isFalse,
              reason: 'the retry is the user\'s to make: $code/$status',
            );
          }
        },
      );
    }

    test('an unknown 5xx stays retryable and keeps the operation whole', () {
      final d = decideAttachmentError(error('SOMETHING_NEW', statusCode: 500));
      expect(d.nextUploadState, AttachmentUploadState.retryable);
      expect(d.keepsIdempotencyKey, isTrue);
      expect(d.autoRetryAllowed, isFalse);
    });

    test('an unknown 4xx is TERMINAL, not an endless retry', () {
      final d = decideAttachmentError(error('SOMETHING_NEW', statusCode: 400));
      expect(
        d.nextUploadState,
        AttachmentUploadState.failedFinal,
        reason:
            're-sending the same rejected request produces the same rejection',
      );
      expect(d.action, AttachmentErrorAction.discardOperation);
      expect(
        d.keepsIdempotencyKey,
        isFalse,
        reason: 'the operation is over; there is no retry to recognise',
      );
    });

    test('a bare 409 is still the stale-event refresh, not the 4xx tail', () {
      final d = decideAttachmentError(error(null, statusCode: 409));
      expect(d.action, AttachmentErrorAction.refreshList);
      expect(d.nextUploadState, AttachmentUploadState.retryable);
      expect(d.keepsIdempotencyKey, isTrue);
    });

    test('every explicit 4xx code keeps its own decision', () {
      // The unknown-4xx rule must be the DEFAULT, never an override: these
      // all carry 4xx statuses and must still answer as themselves.
      expect(
        decideAttachmentError(error('ATTACHMENT_LIMIT_REACHED')).message,
        'This event has reached its attachment limit.',
      );
      expect(
        decideAttachmentError(
          error('ATTACHMENT_TOO_LARGE', statusCode: 413),
        ).message,
        'This file is too large to attach.',
      );
      expect(
        decideAttachmentError(
          error('ATTACHMENT_TYPE_NOT_ALLOWED', statusCode: 415),
        ).message,
        'This file type cannot be attached.',
      );
      expect(
        decideAttachmentError(
          error('EVENT_NOT_FOUND', statusCode: 404),
        ).message,
        'This event is no longer available.',
      );
      expect(
        decideAttachmentError(error('ATTACHMENT_UPLOAD_IN_PROGRESS')).action,
        AttachmentErrorAction.reconcile,
      );
      expect(
        decideAttachmentError(
          error('ATTACHMENTS_NOT_SUPPORTED_FOR_CALENDAR'),
        ).action,
        AttachmentErrorAction.disableAttachments,
      );
    });

    test('a transport failure (status 0) is not treated as a 4xx', () {
      final d = decideAttachmentError(error('NETWORK_ERROR', statusCode: 0));
      expect(d.nextUploadState, AttachmentUploadState.retryable);
      expect(d.keepsIdempotencyKey, isTrue);
    });
  });

  // ── Support reference ─────────────────────────────────────────────────────

  group('support reference', () {
    test('a request id becomes a reference on its own line', () {
      final decorated = attachmentErrorMessageWithReference(
        'The calendar service could not store this file. Try again shortly.',
        error(
          'ATTACHMENT_UPLOAD_FAILED',
          statusCode: 502,
        ).withRequestId('A1B2C3D4'),
      );
      expect(
        decorated,
        'The calendar service could not store this file. Try again shortly.\n'
        'Reference: A1B2C3D4',
      );
    });

    test('no request id means no reference line at all', () {
      final decorated = attachmentErrorMessageWithReference(
        'Something went wrong.',
        error('ATTACHMENT_UPLOAD_FAILED', statusCode: 502),
      );
      expect(decorated, 'Something went wrong.');
      expect(decorated, isNot(contains('Reference')));
      expect(decorated, isNot(contains('null')));
    });

    test('an empty request id is treated as absent', () {
      expect(
        attachmentSupportReference(
          error('X', statusCode: 500).withRequestId('   '),
        ),
        isNull,
      );
    });

    test('a deliberately empty message stays empty', () {
      // Cancellation says nothing to the user, and must not start saying
      // something just because Hub attached a trace id.
      expect(
        attachmentErrorMessageWithReference(
          '',
          error('CANCELLED', statusCode: 0).withRequestId('A1B2C3D4'),
        ),
        '',
      );
    });

    test('a non-Hub failure carries no reference', () {
      expect(
        attachmentErrorMessageWithReference('Local trouble.', StateError('x')),
        'Local trouble.',
      );
    });

    test('the reference never exposes the endpoint or Hub\'s raw message', () {
      const e = CaleeHubException(
        statusCode: 502,
        code: 'ATTACHMENT_UPLOAD_FAILED',
        message: 'upstream said something internal',
        requestId: 'A1B2C3D4',
        endpoint: '/client/v1/events/portal%3Aevt-1/attachments',
      );
      final decorated = attachmentErrorMessageWithReference('Try again.', e);
      expect(decorated, 'Try again.\nReference: A1B2C3D4');
      expect(decorated, isNot(contains('/client/v1')));
      expect(decorated, isNot(contains('upstream said')));
      // The full detail still exists for the debug log, just not on screen.
      expect(e.debugSummary, contains('/client/v1'));
    });
  });
}

extension on CaleeHubException {
  CaleeHubException withRequestId(String requestId) => CaleeHubException(
    statusCode: statusCode,
    message: message,
    code: code,
    requestId: requestId,
    endpoint: endpoint,
  );
}
