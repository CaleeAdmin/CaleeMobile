import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:flutter/foundation.dart';

import 'shopping_link_intent.dart';

class ShoppingLinkController extends ChangeNotifier {
  ShoppingLinkController();

  final _appLinks = AppLinks();

  ShoppingLinkIntent? pendingIntent;

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

  /// Matches `calee://shopping?weekStart=YYYY-MM-DD` and
  /// `https://hub.calee.com.au/mobile/shopping?weekStart=YYYY-MM-DD`. A
  /// missing or invalid `weekStart` still produces an intent (with a null
  /// [ShoppingLinkIntent.weekStart]) rather than rejecting the link — only
  /// the scheme/host/path are used to decide whether this is a shopping link
  /// at all.
  static ShoppingLinkIntent? parseUri(Uri uri) {
    final isCustomScheme = uri.scheme == 'calee' && uri.host == 'shopping';
    final isHttpsLink =
        uri.scheme == 'https' &&
        uri.host == 'hub.calee.com.au' &&
        uri.path == '/mobile/shopping';

    if (!isCustomScheme && !isHttpsLink) return null;

    return ShoppingLinkIntent(
      weekStart: _parseWeekStart(uri.queryParameters['weekStart']),
      sourceUri: uri,
    );
  }

  /// Parses a strict `YYYY-MM-DD` calendar date, returning null for a
  /// missing, malformed, or out-of-range (e.g. Feb 30) value so callers fall
  /// back to the current week.
  static DateTime? _parseWeekStart(String? raw) {
    if (raw == null) return null;
    final match = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$').firstMatch(raw);
    if (match == null) return null;

    final year = int.parse(match.group(1)!);
    final month = int.parse(match.group(2)!);
    final day = int.parse(match.group(3)!);
    if (month < 1 || month > 12) return null;

    final date = DateTime(year, month, day);
    if (date.year != year || date.month != month || date.day != day) {
      // DateTime's constructor normalizes overflow (e.g. Feb 30 -> Mar 2)
      // instead of throwing, so a mismatch here means the input wasn't a
      // real calendar date.
      return null;
    }
    return date;
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
