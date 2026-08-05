import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// Conservative client-side pre-check mirroring calee-hub-core's default
/// allowlist (core_attachments_cfg.php). Server-side content inspection
/// remains authoritative for every upload; these only give fast feedback
/// before a network round trip (Phase 6: "show validation failures before
/// network upload where possible").
///
/// They live here, with the staging manager, because staging is where they
/// are ENFORCED: nothing becomes a pending upload without passing them on
/// the way into Calee-owned storage.
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

/// A picker selection after it has been copied into storage Calee owns.
///
/// [file] is the ONLY file an upload or a retry may read. The picker's own
/// path is not kept: `image_picker` and `file_picker` both hand back a copy
/// in an OS-managed temporary directory, which the platform may reclaim at
/// any moment, and on Android may not survive the app being killed and
/// restarted behind the camera. [originalFilename] is carried separately and
/// unchanged, because it is the only name the user recognises -- the staging
/// basename is deliberately meaningless and must never be shown or sent.
@immutable
class StagedAttachmentFile {
  const StagedAttachmentFile({
    required this.file,
    required this.originalFilename,
    required this.size,
  });

  /// The Calee-owned copy. Verified to exist, be readable, and be exactly
  /// [size] bytes at the moment it was created.
  final File file;

  /// The name the user knows this document by, straight from the platform
  /// picker. Never derived from [file]'s path.
  final String originalFilename;

  /// The verified byte count of [file], and of the source it was copied
  /// from. Re-checked before every send -- see
  /// [AttachmentUploadStagingManager.isIntact].
  final int size;
}

/// Thrown when a selection cannot be staged. [message] is already Calee
/// wording, safe to show; [reason] is a stable slug for debug logging and is
/// never shown to anyone.
class AttachmentStagingException implements Exception {
  const AttachmentStagingException(this.message, {required this.reason});

  final String message;
  final String reason;

  @override
  String toString() => 'AttachmentStagingException($reason)';
}

/// Thrown by [AttachmentUploadStagingManager.stage] once the manager has
/// been closed. Mirrors `AttachmentCacheClosedException`: a selection that
/// arrives during teardown is dropped quietly rather than reported to a user
/// whose screen is already going away.
class AttachmentStagingClosedException implements Exception {
  const AttachmentStagingClosedException();

  @override
  String toString() => 'AttachmentUploadStagingManager is closed.';
}

/// Resolves the directory staged uploads live in. Injected so tests can
/// point at a real temp directory instead of driving path_provider's
/// platform channel.
typedef AttachmentStagingDirectoryProvider = Future<Directory> Function();

Future<Directory> _defaultStagingDirectoryProvider() =>
    getApplicationCacheDirectory();

/// Owns the on-disk lifecycle of a picker selection that is waiting to be
/// uploaded.
///
/// Deliberately NOT `AttachmentCacheManager`. That one owns copies coming
/// DOWN from Hub: it is keyed by attachment ID, re-downloads every time
/// because no attachment ETag exists to validate a cached copy against, and
/// evicts the previous copy before each download. None of that is true of a
/// file going UP, which has no attachment ID yet, must not be re-fetched
/// from anywhere, and must survive exactly as long as the operation that
/// owns it -- across a timeout, a reconciliation and any number of retries.
///
/// The rules, and why:
///
///  * **Copy before anything else.** The picker's path is borrowed; the
///    staged path is owned. Validation, upload and every retry read the
///    staged copy, so a temporary file the OS reclaims a second later cannot
///    turn a queued upload into a permanent failure.
///  * **Unpredictable basenames, extension only.** A staging filename never
///    contains the user's filename -- a directory listing would otherwise
///    enumerate which documents a family holds. The extension survives
///    reduced to `[a-z0-9]` and length-capped, which makes traversal
///    (`../`, absolute paths, NUL) structurally impossible rather than
///    merely filtered.
///  * **Verified after the copy, not before.** Existence, readability and an
///    exact size match are checked on the staged file itself. A short or
///    unreadable copy is deleted and reported, never uploaded.
///  * **Deleted on a decided outcome, kept on an undecided one.** See
///    [discard] and [close]. A file whose upload merely timed out is still
///    owed to the user.
///
/// Recovering a staged file across a process restart is deliberately out of
/// scope, as is sweeping up files orphaned by a kill -- both belong to
/// CaleeMobile#523.
class AttachmentUploadStagingManager {
  AttachmentUploadStagingManager({
    AttachmentStagingDirectoryProvider? stagingDirectoryProvider,
    Random? random,
  }) : _stagingDirectoryProvider =
           stagingDirectoryProvider ?? _defaultStagingDirectoryProvider,
       _random = random ?? Random.secure();

  /// Subdirectory of the app cache directory that holds staged uploads. Kept
  /// apart from the downloaded-attachment copies so neither manager's
  /// cleanup can reach the other's files.
  static const String directoryName = 'attachment_staging';

  final AttachmentStagingDirectoryProvider _stagingDirectoryProvider;
  final Random _random;

  /// Every staged path this manager created and has not deleted.
  final Set<String> _stagedPaths = {};

  bool _closed = false;

  /// True once [close] has run. A closed manager never stages again.
  bool get isClosed => _closed;

  /// The staged paths currently held, for assertions and cleanup.
  Set<String> get stagedPaths => Set.unmodifiable(_stagedPaths);

  /// Validates [source] and copies it into a fresh Calee-owned staging file.
  ///
  /// Throws [AttachmentStagingException] with user-facing wording when the
  /// selection cannot be used, and [AttachmentStagingClosedException] when
  /// the screen tore down while this was running. Never leaves a partial
  /// staged file behind on either path.
  Future<StagedAttachmentFile> stage({
    required File source,
    required String originalFilename,
  }) async {
    if (_closed) throw const AttachmentStagingClosedException();

    // Reading the length answers "does it still exist" and "how big is it"
    // in one filesystem call, so there is no window between the two in which
    // the source could vanish. This is also the size the staged copy is
    // required to match, so both halves of that comparison come from the
    // same moment.
    final int sourceSize;
    try {
      sourceSize = await source.length();
    } on PathNotFoundException {
      throw const AttachmentStagingException(
        'That file is no longer available. Please choose it again.',
        reason: 'source_missing',
      );
    } on FileSystemException {
      throw const AttachmentStagingException(
        'That file could not be read. Please choose it again.',
        reason: 'source_unreadable',
      );
    }

    if (sourceSize <= 0) {
      throw const AttachmentStagingException(
        'This file is empty and cannot be attached.',
        reason: 'source_empty',
      );
    }
    if (sourceSize > kAttachmentMaxBytes) {
      throw const AttachmentStagingException(
        'This file is too large to attach (max 10 MB).',
        reason: 'source_too_large',
      );
    }

    final extension = sanitizedExtension(originalFilename);
    if (!kAttachmentAllowedExtensions.contains(extension)) {
      throw const AttachmentStagingException(
        'This file type cannot be attached.',
        reason: 'source_type_not_allowed',
      );
    }

    final Directory stagingDirectory;
    try {
      final base = await _stagingDirectoryProvider();
      stagingDirectory = await Directory(
        '${base.path}/$directoryName',
      ).create(recursive: true);
    } on FileSystemException {
      throw const AttachmentStagingException(
        'Could not prepare this file for upload. Please try again.',
        reason: 'staging_directory_unavailable',
      );
    }
    if (_closed) throw const AttachmentStagingClosedException();

    final target = File(
      '${stagingDirectory.path}/att_upload_${_newToken()}.$extension',
    );

    try {
      await source.copy(target.path);
    } on FileSystemException {
      await _deleteIfExists(target);
      throw const AttachmentStagingException(
        'Could not prepare this file for upload. Please try again.',
        reason: 'staging_copy_failed',
      );
    }

    if (!await _verify(target, sourceSize)) {
      await _deleteIfExists(target);
      throw const AttachmentStagingException(
        'Could not prepare this file for upload. Please try again.',
        reason: 'staging_verification_failed',
      );
    }

    // A close that landed while the bytes were being copied has already run
    // its cleanup, so this file would have no owner left to delete it.
    if (_closed) {
      await _deleteIfExists(target);
      throw const AttachmentStagingClosedException();
    }

    _stagedPaths.add(target.path);
    return StagedAttachmentFile(
      file: target,
      originalFilename: originalFilename,
      size: sourceSize,
    );
  }

  /// Whether [staged] is still exactly what was staged: present, readable,
  /// and the same size. Checked before every send and every retry, so a file
  /// the OS reclaimed underneath a queued operation is caught before a
  /// request is built rather than halfway through streaming one.
  ///
  /// Never throws: any failure to establish that is reported as false.
  Future<bool> isIntact(StagedAttachmentFile staged) =>
      _verify(staged.file, staged.size);

  /// Deletes [staged] and forgets it. Safe to call twice, safe after
  /// [close], and never throws -- cleanup must not be able to fail a user
  /// action or a teardown.
  Future<void> discard(StagedAttachmentFile staged) async {
    _stagedPaths.remove(staged.file.path);
    await _deleteIfExists(staged.file);
  }

  /// Permanently retires the manager: deletes every file it still holds and
  /// refuses to stage again.
  ///
  /// Idempotent. The closed flag is set BEFORE the deletions, so a [stage]
  /// completing during the awaits below is already refused rather than
  /// racing the cleanup it just missed. The staging directory itself is
  /// removed only when it is empty, so a second editor's staged file is
  /// never taken with it.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;

    final paths = _stagedPaths.toList();
    _stagedPaths.clear();
    for (final path in paths) {
      await _deleteIfExists(File(path));
    }

    if (paths.isEmpty) return;
    try {
      await Directory(File(paths.first).parent.path).delete();
    } on FileSystemException {
      // Non-empty (another section still owns a staged file) or already
      // gone. Either way there is nothing to do and nothing to report.
    } catch (_) {
      // Teardown must never throw on the way out of a screen.
    }
  }

  /// Reduces [filename]'s extension to something safe to append to a
  /// generated basename. Returns '' when there is nothing usable.
  ///
  /// Traversal safety comes from CONSTRUCTION, not filtering: only
  /// `[a-z0-9]` characters survive, so `/`, `\`, `..` and NUL cannot appear
  /// in the result no matter what the input was.
  static String sanitizedExtension(String filename) {
    final lastDot = filename.lastIndexOf('.');
    if (lastDot < 0 || lastDot == filename.length - 1) return '';
    final cleaned = filename
        .substring(lastDot + 1)
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]'), '');
    if (cleaned.isEmpty) return '';
    // Long "extensions" are not real extensions; cap rather than trust.
    return cleaned.length > 10 ? cleaned.substring(0, 10) : cleaned;
  }

  String _newToken() {
    final bytes = List<int>.generate(16, (_) => _random.nextInt(256));
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  /// Exists, is genuinely readable, and is exactly [expectedSize] bytes.
  ///
  /// The read is a real one-byte read rather than a stat: a path can survive
  /// a permission change or a revoked scoped-storage grant that makes the
  /// bytes unreachable, and an upload must not discover that halfway
  /// through. It goes through `openRead` specifically because that is the
  /// API `CaleeHubClient.uploadAttachment` streams the body with, so this
  /// proves the exact access the upload is about to attempt rather than an
  /// adjacent one.
  static Future<bool> _verify(File file, int expectedSize) async {
    try {
      if (await file.length() != expectedSize) return false;
      return (await file.openRead(0, 1).first).isNotEmpty;
    } on FileSystemException {
      return false;
    } catch (_) {
      // Includes the empty-stream StateError a zero-byte file would raise --
      // which the length check above has already ruled out, since a staged
      // file is never zero bytes.
      return false;
    }
  }

  static Future<void> _deleteIfExists(File file) async {
    try {
      if (await file.exists()) {
        await file.delete();
      }
    } on FileSystemException {
      // A staged file we cannot delete is not worth failing a user action
      // over; it is inside the OS-managed cache directory and will be
      // reclaimed under storage pressure.
    } catch (_) {
      // Same reasoning for any other platform-level failure.
    }
  }
}
