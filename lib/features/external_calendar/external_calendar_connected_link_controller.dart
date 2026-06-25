import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:flutter/foundation.dart';

import 'external_calendar_connected_intent.dart';

class ExternalCalendarConnectedLinkController extends ChangeNotifier {
  ExternalCalendarConnectedLinkController();

  final _appLinks = AppLinks();

  ExternalCalendarConnectedIntent? pendingIntent;

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
    final intent = parseUri(uri);
    if (intent == null) return;
    if (_disposed) return;

    debugPrint(
      '[ExternalCalendarLink] deep link received: '
      'providerKey=${intent.providerKey}, '
      'connectionId=${intent.connectionId}, '
      'status=${intent.status}',
    );

    pendingIntent = intent;
    notifyListeners();
  }

  static ExternalCalendarConnectedIntent? parseUri(Uri uri) {
    if (uri.scheme != 'calee') return null;
    if (uri.host != 'external-calendar-connected') return null;

    final params = uri.queryParameters;
    return ExternalCalendarConnectedIntent(
      providerKey: params['providerKey'],
      connectionId: params['connectionId'],
      status: params['status'],
      reason: params['reason'],
    );
  }

  void clearPending() {
    pendingIntent = null;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _linkSubscription?.cancel();
    super.dispose();
  }
}
