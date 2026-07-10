// ignore_for_file: prefer_initializing_formals
import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:flutter/foundation.dart';

import 'display_setup_intent.dart';

const _tokenPattern = r'^[A-Za-z0-9_\-]{32,256}$';

/// Delivers native-login deep-link URIs to [DisplaySetupLinkController]
/// without exposing platform channels directly — tests substitute a fake
/// implementation so the controller's init lifecycle can be exercised
/// without platform channels.
abstract interface class DisplaySetupLinkSource {
  Future<Uri?> getInitialLink();
  Stream<Uri> get uriLinkStream;
}

/// Production [DisplaySetupLinkSource], backed by the `app_links` plugin.
class AppLinksDisplaySetupLinkSource implements DisplaySetupLinkSource {
  AppLinksDisplaySetupLinkSource() : _appLinks = AppLinks();

  final AppLinks _appLinks;

  @override
  Future<Uri?> getInitialLink() => _appLinks.getInitialLink();

  @override
  Stream<Uri> get uriLinkStream => _appLinks.uriLinkStream;
}

/// Short, non-reversible fingerprint for debug logging — never logs the
/// full tablet token.
String _fingerprint(String token) {
  if (token.length <= 8) return 'len=${token.length}';
  return '${token.substring(0, 4)}…${token.substring(token.length - 4)}'
      '(len=${token.length})';
}

class DisplaySetupLinkController extends ChangeNotifier {
  DisplaySetupLinkController({
    DisplaySetupLinkSource? linkSource,
    DateTime Function()? clock,
  }) : _linkSource = linkSource ?? AppLinksDisplaySetupLinkSource(),
       _clock = clock ?? DateTime.now;

  final DisplaySetupLinkSource _linkSource;

  /// Clock used for the redelivery dedup window. Injectable so tests can
  /// advance time without waiting out the real window.
  final DateTime Function() _clock;

  /// How long a just-accepted token suppresses redeliveries of itself.
  ///
  /// The same tablet token can arrive more than once in quick succession:
  /// the initial-link lookup and the link stream may both report a
  /// cold-start link, and the HTTPS and calee:// forms of the same QR code
  /// carry the same token.
  @visibleForTesting
  static const dedupWindow = Duration(seconds: 5);

  String? _lastAcceptedToken;
  DateTime? _lastAcceptedAt;

  DisplaySetupIntent? pendingIntent;
  String? pendingError;

  bool _initialized = false;
  bool _disposed = false;
  StreamSubscription<Uri>? _linkSubscription;

  /// Idempotent: safe to call more than once (e.g. from multiple owners) —
  /// only the first call attaches the stream listener and looks up the
  /// initial link.
  ///
  /// The stream listener is attached *before* the initial-link lookup is
  /// awaited so a link delivered while that lookup is in flight is never
  /// lost. Both sources funnel through [_handleUri]/[_acceptIntent], which
  /// dedups by token, so the same cold-start link reported by both the
  /// initial-link lookup and the stream still results in exactly one
  /// accepted intent.
  Future<void> init() async {
    if (_initialized || _disposed) return;
    _initialized = true;

    if (kDebugMode) debugPrint('[DisplaySetupLinkController] init starting');

    _linkSubscription = _linkSource.uriLinkStream.listen(
      (uri) {
        if (kDebugMode) {
          debugPrint('[DisplaySetupLinkController] stream link received');
        }
        _handleUri(uri);
      },
      onError: (error) {
        if (kDebugMode) {
          debugPrint('[DisplaySetupLinkController] stream error: $error');
        }
      },
    );
    if (kDebugMode) {
      debugPrint('[DisplaySetupLinkController] stream subscription attached');
    }

    try {
      final initialUri = await _linkSource.getInitialLink();
      if (kDebugMode) {
        debugPrint(
          initialUri != null
              ? '[DisplaySetupLinkController] initial link received'
              : '[DisplaySetupLinkController] initial link absent',
        );
      }
      if (initialUri != null) {
        _handleUri(initialUri);
      }
    } catch (error) {
      // Platform may not provide an initial link — this is expected on some platforms.
      if (kDebugMode) {
        debugPrint('[DisplaySetupLinkController] getInitialLink error: $error');
      }
    }
  }

  void _handleUri(Uri uri) {
    final intent = parseDisplaySetupUri(uri);
    if (intent == null) return;
    _acceptIntent(intent);
  }

  /// Single entry point for every incoming intent (initial link and link
  /// stream) so all sources share identical dedup logic.
  ///
  /// Dedup is keyed by token — not by source URI — because the HTTPS and
  /// calee:// links for one QR code carry the same tablet token. A different
  /// token is never suppressed, and the same token becomes acceptable again
  /// once [dedupWindow] elapses or the flow completes/cancels (via
  /// [clearPending], which resets the window).
  void _acceptIntent(DisplaySetupIntent intent) {
    if (_disposed) return;

    final fp = _fingerprint(intent.token);
    final now = _clock();
    final lastAt = _lastAcceptedAt;
    if (intent.token == _lastAcceptedToken &&
        lastAt != null &&
        now.difference(lastAt) < dedupWindow) {
      if (kDebugMode) {
        debugPrint('[DisplaySetupLinkController] URI deduplicated: $fp');
      }
      return;
    }
    _lastAcceptedToken = intent.token;
    _lastAcceptedAt = now;

    pendingIntent = intent;
    pendingError = null;
    if (kDebugMode) {
      debugPrint('[DisplaySetupLinkController] URI accepted: $fp');
    }
    notifyListeners();
  }

  static DisplaySetupIntent? parseDisplaySetupUri(Uri uri) {
    final tokenRe = RegExp(_tokenPattern);
    String token;

    if (uri.scheme == 'https') {
      if (uri.host != 'hub.calee.com.au') return null;
      if (uri.pathSegments.length != 2) return null;
      if (uri.pathSegments[0] != 'native-login') return null;
      token = uri.pathSegments[1];
    } else if (uri.scheme == 'calee') {
      if (uri.host != 'native-login') return null;
      if (uri.pathSegments.length != 1) return null;
      token = uri.pathSegments[0];
    } else {
      return null;
    }

    if (!tokenRe.hasMatch(token)) return null;
    return DisplaySetupIntent(token: token, sourceUri: uri);
  }

  static DisplaySetupIntent? parseDisplaySetupRouteName(String? routeName) {
    if (routeName == null || routeName.isEmpty) return null;
    final tokenRe = RegExp(_tokenPattern);

    if (routeName.startsWith('/native-login/')) {
      final token = routeName.substring('/native-login/'.length);
      if (token.isEmpty || token.contains('/')) return null;
      if (!tokenRe.hasMatch(token)) return null;
      final sourceUri = Uri.parse(
        'https://hub.calee.com.au/native-login/$token',
      );
      return DisplaySetupIntent(token: token, sourceUri: sourceUri);
    }

    if (routeName.startsWith('/')) {
      final token = routeName.substring(1);
      if (token.isEmpty || token.contains('/')) return null;
      if (!tokenRe.hasMatch(token)) return null;
      final sourceUri = Uri.parse('calee://native-login/$token');
      return DisplaySetupIntent(token: token, sourceUri: sourceUri);
    }

    return null;
  }

  void handleDisplaySetupIntent(DisplaySetupIntent intent) {
    _acceptIntent(intent);
  }

  void clearPending() {
    pendingIntent = null;
    pendingError = null;
    // The flow completed or was cancelled — reset the dedup window so the
    // same tablet link can be scanned again straight away.
    _lastAcceptedToken = null;
    _lastAcceptedAt = null;
    notifyListeners();
  }

  void clearError() {
    pendingError = null;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _linkSubscription?.cancel();
    super.dispose();
  }
}
