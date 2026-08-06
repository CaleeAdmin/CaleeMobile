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

CaleeHubException error(String code, {int statusCode = 409}) =>
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
}
