import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:flutter/foundation.dart';

import 'display_setup_intent.dart';

const _tokenPattern = r'^[A-Za-z0-9_\-]{32,256}$';

class DisplaySetupLinkController extends ChangeNotifier {
  DisplaySetupLinkController();

  final _appLinks = AppLinks();

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
    } catch (_) {}

    _linkSubscription = _appLinks.uriLinkStream.listen(
      _handleUri,
      onError: (_) {},
    );
  }

  void _handleUri(Uri uri) {
    final intent = parseDisplaySetupUri(uri);
    if (intent == null) return;
    if (_disposed) return;

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
    pendingIntent = intent;
    pendingError = null;
    notifyListeners();
  }

  void clearPending() {
    pendingIntent = null;
    pendingError = null;
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
