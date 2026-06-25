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

  String? _lastIntentKey;
  DateTime? _lastIntentAt;

  // Overridable in tests to control the current time for dedup checks.
  @visibleForTesting
  DateTime Function() clockForTesting = DateTime.now;

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
    if (_isDuplicate(intent)) return;

    debugPrint(
      '[ExternalCalendarLink] deep link received: '
      'providerKey=${intent.providerKey}, '
      'connectionId=${intent.connectionId}, '
      'status=${intent.status}',
    );

    pendingIntent = intent;
    notifyListeners();
  }

  bool _isDuplicate(ExternalCalendarConnectedIntent intent) {
    final key = [
      intent.providerKey ?? '',
      intent.connectionId ?? '',
      intent.status ?? '',
      intent.reason ?? '',
    ].join('|');

    final now = clockForTesting();
    final lastAt = _lastIntentAt;

    if (_lastIntentKey == key &&
        lastAt != null &&
        now.difference(lastAt) < const Duration(seconds: 3)) {
      return true;
    }

    _lastIntentKey = key;
    _lastIntentAt = now;
    return false;
  }

  /// Exposes [_handleUri] for unit tests without needing app_links platform channels.
  @visibleForTesting
  void handleUri(Uri uri) => _handleUri(uri);

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
    if (_disposed) return;
    _disposed = true;
    _linkSubscription?.cancel();
    super.dispose();
  }
}
