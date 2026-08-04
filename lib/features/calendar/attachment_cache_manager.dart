import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:path_provider/path_provider.dart';

/// Thrown by [AttachmentCacheManager.prepareDownloadTarget] when the manager
/// has already been closed. A closed manager never hands out a new path, so
/// a download started during teardown fails fast instead of writing a file
/// nothing will ever delete.
class AttachmentCacheClosedException implements Exception {
  const AttachmentCacheClosedException();

  @override
  String toString() => 'AttachmentCacheManager is closed.';
}

/// Resolves the directory cached attachment copies live in. Injected so
/// tests can point at a real temp directory instead of driving
/// path_provider's platform channel.
typedef AttachmentCacheDirectoryProvider = Future<Directory> Function();

Future<Directory> _defaultCacheDirectoryProvider() =>
    getApplicationCacheDirectory();

/// Owns the on-disk lifecycle of downloaded attachment copies.
///
/// Extracted from the attachments widget so the rules below are testable
/// directly, without pumping a widget tree (Part J).
///
/// The rules, and why:
///
///  * **Unpredictable basenames.** A cache filename never contains the
///    attachment ID or the user's filename. Both leak: a directory listing
///    would otherwise enumerate which documents a family holds, and an
///    attachment ID is guessable enough to probe for. Only a random token
///    and a sanitized extension survive.
///  * **Extension preserved, nothing else.** The OS picks a viewer by
///    extension, so it has to stay -- but it is reduced to `[a-z0-9]` and
///    length-capped, which also makes traversal (`../`, absolute paths,
///    NUL) structurally impossible rather than merely filtered.
///  * **Re-download every time.** The attachment API exposes no
///    content-version/ETag an ID could be validated against, so a cached
///    copy can never be proven current. The previous copy is deleted
///    before the new download starts, bounding the cache at one file per
///    open attachment.
///  * **Deleted on detach, on failure, and at session end.** Confidential
///    family documents must not outlive the screen that opened them.
///  * **Closed, not merely cleared.** [clear] alone could not keep that last
///    promise: a download that finished a moment after the screen was gone
///    would call back into the manager and re-register its file, leaving a
///    confidential document in the cache directory with nobody left to
///    delete it. [close] makes the manager permanently refuse new work --
///    [prepareDownloadTarget] throws and [finalizeDownload] deletes what it
///    is handed instead of committing it -- so a late completion cleans up
///    after itself rather than repopulating a cache that is already gone.
class AttachmentCacheManager {
  AttachmentCacheManager({
    AttachmentCacheDirectoryProvider? cacheDirectoryProvider,
    Random? random,
  }) : _cacheDirectoryProvider =
           cacheDirectoryProvider ?? _defaultCacheDirectoryProvider,
       _random = random ?? Random.secure();

  final AttachmentCacheDirectoryProvider _cacheDirectoryProvider;
  final Random _random;

  /// attachmentId -> the one path currently cached for it.
  final Map<String, String> _activePaths = {};

  bool _closed = false;

  /// True once [close] has run. A closed manager never retains a new active
  /// path again, for the lifetime of the object.
  bool get isClosed => _closed;

  /// The cache paths currently tracked, for assertions and cleanup.
  Map<String, String> get activePaths => Map.unmodifiable(_activePaths);

  /// Reduces [filename]'s extension to something safe to append to a
  /// generated basename. Returns '' when there is nothing usable, so the
  /// cache file simply has no extension rather than a dangerous one.
  ///
  /// Traversal safety comes from CONSTRUCTION, not filtering: only
  /// `[a-z0-9]` characters survive, so `/`, `\`, `..` and NUL cannot appear
  /// in the result no matter what the input was.
  static String sanitizedExtension(String filename) {
    final lastDot = filename.lastIndexOf('.');
    if (lastDot < 0 || lastDot == filename.length - 1) return '';
    final raw = filename.substring(lastDot + 1).toLowerCase();
    final cleaned = raw.replaceAll(RegExp(r'[^a-z0-9]'), '');
    if (cleaned.isEmpty) return '';
    // Long "extensions" are not real extensions; cap rather than trust.
    return cleaned.length > 10 ? cleaned.substring(0, 10) : cleaned;
  }

  String _newToken() {
    final bytes = List<int>.generate(16, (_) => _random.nextInt(256));
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  /// Builds a fresh, unpredictable cache file for [attachmentId], deleting
  /// any previously cached copy first. The returned file does not exist
  /// yet -- the caller downloads into it.
  ///
  /// Throws [AttachmentCacheClosedException] once [close] has run, including
  /// when the close lands while this call is awaiting the cache directory:
  /// the state is re-checked after every await, so a path is never handed
  /// out that no later [clear] would cover.
  Future<File> prepareDownloadTarget({
    required String attachmentId,
    required String originalFilename,
  }) async {
    if (_closed) throw const AttachmentCacheClosedException();

    await evict(attachmentId);

    final cacheDir = await _cacheDirectoryProvider();
    if (_closed) throw const AttachmentCacheClosedException();

    final extension = sanitizedExtension(originalFilename);
    final suffix = extension.isEmpty ? '' : '.$extension';
    final file = File('${cacheDir.path}/att_cache_${_newToken()}$suffix');

    _activePaths[attachmentId] = file.path;
    return file;
  }

  /// Marks the download into [file] as complete and usable, and reports
  /// whether the copy was actually kept.
  ///
  /// Returns false -- after deleting [file] -- when the manager was closed
  /// while the bytes were still arriving. This is the awaited half of the
  /// close contract: the caller learns the file is gone (so it never opens
  /// or shares it) and the deletion has already happened by the time the
  /// future completes, rather than being left to a callback that may never
  /// run.
  Future<bool> finalizeDownload({
    required String attachmentId,
    required File file,
  }) async {
    if (_closed) {
      _activePaths.remove(attachmentId);
      await _deleteIfExists(file);
      return false;
    }
    _activePaths[attachmentId] = file.path;
    return true;
  }

  /// Synchronous finalisation, kept for callers that cannot await.
  /// [finalizeDownload] is the one to prefer: after [close] only the awaited
  /// form can promise the late file is deleted before the caller continues.
  void commit({required String attachmentId, required File file}) {
    unawaited(finalizeDownload(attachmentId: attachmentId, file: file));
  }

  /// Deletes and forgets the cached copy for [attachmentId], if any. Safe
  /// to call for an attachment that was never downloaded, and safe to call
  /// twice.
  Future<void> evict(String attachmentId) async {
    final path = _activePaths.remove(attachmentId);
    if (path == null) return;
    await _deleteIfExists(File(path));
  }

  /// Drops a partially-written file after a failed or cancelled download.
  /// Identical to [evict] in effect, named separately because the call
  /// sites mean different things.
  Future<void> discardPartial(String attachmentId) => evict(attachmentId);

  /// Drops a failed or cancelled download by its own [file] rather than by
  /// lookup, and forgets [attachmentId].
  ///
  /// [evict] can only delete what is still tracked, and a [clear] or [close]
  /// that lands mid-download untracks the target while the transfer is
  /// still writing to it -- so the bytes that arrive after that would have
  /// no owner left to delete them. Deleting the caller's own handle needs no
  /// lookup and works either way.
  Future<void> discardDownload({
    required String attachmentId,
    required File file,
  }) async {
    _activePaths.remove(attachmentId);
    await _deleteIfExists(file);
  }

  /// Removes every cached copy this manager created. Leaves the manager
  /// usable; see [close] for the end-of-screen teardown.
  Future<void> clear() async {
    final paths = _activePaths.values.toList();
    _activePaths.clear();
    for (final path in paths) {
      await _deleteIfExists(File(path));
    }
  }

  /// Permanently retires the manager: deletes everything cached so far and
  /// refuses to cache anything again.
  ///
  /// Idempotent -- a second call is a no-op, so disposal paths that overlap
  /// (an explicit close-and-cancel followed by `dispose`) are safe. The
  /// closed flag is set BEFORE the deletions, so a download completing
  /// during the awaits below is already refused rather than racing the
  /// clear it just missed.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await clear();
  }

  static Future<void> _deleteIfExists(File file) async {
    try {
      if (await file.exists()) {
        await file.delete();
      }
    } on FileSystemException {
      // A cache file we cannot delete is not worth failing a user action
      // over; it is inside the OS-managed cache directory and will be
      // reclaimed under storage pressure.
    } catch (_) {
      // Same reasoning for any other platform-level failure: teardown must
      // never throw on the way out of a screen.
    }
  }
}
