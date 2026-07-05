import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:flutter/foundation.dart';

import 'shopping_list_intent.dart';

/// Handles the universal link shown in the tablet's "Open shopping list on
/// phone" QR code: `https://hub.calee.com.au/app/shopping-list/{listId}`.
class ShoppingListLinkController extends ChangeNotifier {
  ShoppingListLinkController();

  final _appLinks = AppLinks();

  ShoppingListIntent? pendingIntent;

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
    final intent = parseUri(uri);
    if (intent == null) return;
    if (_disposed) return;

    pendingIntent = intent;
    notifyListeners();
  }

  /// Exposes [_handleUri] for unit tests without needing app_links platform channels.
  @visibleForTesting
  void handleUri(Uri uri) => _handleUri(uri);

  static ShoppingListIntent? parseUri(Uri uri) {
    if (uri.scheme != 'https') return null;
    if (uri.host != 'hub.calee.com.au') return null;
    if (uri.pathSegments.length != 3) return null;
    if (uri.pathSegments[0] != 'app') return null;
    if (uri.pathSegments[1] != 'shopping-list') return null;

    final listId = int.tryParse(uri.pathSegments[2]);
    if (listId == null) return null;

    return ShoppingListIntent(listId: listId, sourceUri: uri);
  }

  void clearPending() {
    pendingIntent = null;
    notifyListeners();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _linkSubscription?.cancel();
    super.dispose();
  }
}
