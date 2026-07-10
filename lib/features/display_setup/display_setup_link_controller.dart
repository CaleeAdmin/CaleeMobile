import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:flutter/foundation.dart';

import 'display_setup_intent.dart';

const _tokenPattern = r'^[A-Za-z0-9_\-]{32,256}$';

class DisplaySetupLinkController extends ChangeNotifier {
  DisplaySetupLinkController({DateTime Function()? clock})
    : _clock = clock ?? DateTime.now;

  final _appLinks = AppLinks();

  /// Clock used for the redelivery dedup window. Injectable so tests can
  /// advance time without waiting out the real window.
  final DateTime Function() _clock;

  /// How long a just-accepted token suppresses redeliveries of itself.
  ///
  /// The same tablet token can arrive more than once in quick succession:
  /// [AppLinks.getInitialLink] and [AppLinks.uriLinkStream] may both report
  /// a cold-start link, the HTTPS and calee:// forms of the same QR code
  /// carry the same token, and the Flutter route fallback
  /// ([handleDisplaySetupIntent]) can parse the same route again.
  @visibleForTesting
  static const dedupWindow = Duration(seconds: 5);

  String? _lastAcceptedToken;
  DateTime? _lastAcceptedAt;

  DisplaySetupIntent? pendingIntent;
  String? pendingError;

  bool _disposed = false;
  StreamSubscription<Uri>? _linkSubscription;

  Future<void> init() async {
    try {
      final initialUri = await _appLinks.getInitialLink();
      if (initialUri != null) {
        _handleUri(initialUri);
      }
    } catch (_) {
      // Platform may not provide an initial link — this is expected on some platforms.
    }

    _linkSubscription = _appLinks.uriLinkStream.listen(
      _handleUri,
      onError: (_) {},
    );
  }

  void _handleUri(Uri uri) {
    final intent = parseDisplaySetupUri(uri);
    if (intent == null) return;
    _acceptIntent(intent);
  }

  /// Single entry point for every incoming intent (initial link, link
  /// stream, and Flutter route fallback) so all sources share identical
  /// dedup logic.
  ///
  /// Dedup is keyed by token — not by source URI — because the HTTPS and
  /// calee:// links for one QR code carry the same tablet token. A different
  /// token is never suppressed, and the same token becomes acceptable again
  /// once [dedupWindow] elapses or the flow completes/cancels (via
  /// [clearPending], which resets the window).
  void _acceptIntent(DisplaySetupIntent intent) {
    if (_disposed) return;

    final now = _clock();
    final lastAt = _lastAcceptedAt;
    if (intent.token == _lastAcceptedToken &&
        lastAt != null &&
        now.difference(lastAt) < dedupWindow) {
      return;
    }
    _lastAcceptedToken = intent.token;
    _lastAcceptedAt = now;

    pendingIntent = intent;
    pendingError = null;
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
