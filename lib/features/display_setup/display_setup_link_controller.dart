import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:flutter/foundation.dart';

import 'display_setup_intent.dart';

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
    if (!_isDisplaySetupLink(uri)) return;
    if (_disposed) return;

    final token = uri.pathSegments.last;
    pendingIntent = DisplaySetupIntent(token: token, sourceUri: uri);
    pendingError = null;
    notifyListeners();
  }

  bool _isDisplaySetupLink(Uri uri) {
    return uri.scheme == 'https' &&
        uri.host == 'hub.calee.com.au' &&
        uri.pathSegments.length == 2 &&
        uri.pathSegments.first == 'native-login' &&
        uri.pathSegments.last.isNotEmpty;
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
