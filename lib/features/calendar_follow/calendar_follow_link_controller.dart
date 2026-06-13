import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:flutter/foundation.dart';

import 'calendar_follow_intent.dart';
import 'calendar_follow_intent_resolver.dart';

class CalendarFollowLinkController extends ChangeNotifier {
  CalendarFollowLinkController({CalendarFollowIntentResolver? resolver})
    : _resolver = resolver ?? CalendarFollowIntentResolver();

  final CalendarFollowIntentResolver _resolver;
  final _appLinks = AppLinks();

  ResolvedCalendarFollowIntent? pendingIntent;
  String? pendingError;

  bool _disposed = false;
  StreamSubscription<Uri>? _linkSubscription;

  Future<void> init() async {
    try {
      final initialUri = await _appLinks.getInitialLink();
      if (initialUri != null) {
        await _handleUri(initialUri);
      }
    } catch (_) {
      // ignore initial link errors
    }

    _linkSubscription = _appLinks.uriLinkStream.listen(
      (uri) => _handleUri(uri),
      onError: (_) {},
    );
  }

  Future<void> _handleUri(Uri uri) async {
    if (!_isCalendarFollowLink(uri)) return;

    final token = uri.queryParameters['t'] ?? '';
    if (token.isEmpty) return;

    final intent = CalendarFollowIntent(token: token, sourceUri: uri);

    try {
      final resolved = await _resolver.resolve(intent);
      if (_disposed) return;
      pendingIntent = resolved;
      pendingError = null;
    } on CalendarFollowIntentResolverException catch (e) {
      if (_disposed) return;
      pendingIntent = null;
      pendingError = e.message;
    } catch (_) {
      if (_disposed) return;
      pendingIntent = null;
      pendingError = 'Unable to open this calendar link. Please try again.';
    }

    notifyListeners();
  }

  bool _isCalendarFollowLink(Uri uri) {
    return uri.scheme == 'https' &&
        uri.host == 'calembed.calee.com.au' &&
        uri.path == '/follow' &&
        (uri.queryParameters['t'] ?? '').isNotEmpty;
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
    _resolver.dispose();
    super.dispose();
  }
}
