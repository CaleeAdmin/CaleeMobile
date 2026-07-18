import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:flutter/foundation.dart';

import 'calendar_follow_intent.dart';
import 'calendar_follow_intent_resolver.dart';

/// Delivers calendar-follow deep-link URIs to [CalendarFollowLinkController]
/// without exposing platform channels directly — tests substitute a fake
/// implementation so the controller's init lifecycle (cold start and warm
/// start) can be exercised without platform channels.
abstract interface class CalendarFollowLinkSource {
  Future<Uri?> getInitialLink();
  Stream<Uri> get uriLinkStream;
}

/// Production [CalendarFollowLinkSource], backed by the `app_links` plugin.
class AppLinksCalendarFollowLinkSource implements CalendarFollowLinkSource {
  AppLinksCalendarFollowLinkSource() : _appLinks = AppLinks();

  final AppLinks _appLinks;

  @override
  Future<Uri?> getInitialLink() => _appLinks.getInitialLink();

  @override
  Stream<Uri> get uriLinkStream => _appLinks.uriLinkStream;
}

class CalendarFollowLinkController extends ChangeNotifier {
  CalendarFollowLinkController({
    CalendarFollowIntentResolver? resolver,
    CalendarFollowLinkSource? linkSource,
    DateTime Function()? clock,
  }) : _resolver = resolver ?? CalendarFollowIntentResolver(),
       _linkSource = linkSource ?? AppLinksCalendarFollowLinkSource(),
       _clock = clock ?? DateTime.now;

  final CalendarFollowIntentResolver _resolver;
  final CalendarFollowLinkSource _linkSource;

  /// Clock used for the redelivery dedup window. Injectable so tests can
  /// advance time without waiting out the real window.
  final DateTime Function() _clock;

  /// How long a just-handled token suppresses redeliveries of itself.
  ///
  /// The same signed intent can arrive more than once in quick succession: the
  /// initial-link lookup and the link stream may both report a cold-start
  /// link, and the HTTPS App Link and the `calee://` fallback for one button
  /// carry the same token. Deduping by token keeps a duplicate delivery from
  /// resolving twice and opening two follow screens.
  @visibleForTesting
  static const dedupWindow = Duration(seconds: 5);

  ResolvedCalendarFollowIntent? pendingIntent;
  String? pendingError;

  String? _lastHandledToken;
  DateTime? _lastHandledAt;

  bool _initialized = false;
  bool _disposed = false;
  StreamSubscription<Uri>? _linkSubscription;

  /// Idempotent: safe to call more than once — only the first call attaches
  /// the stream listener and looks up the initial link.
  ///
  /// The stream listener is attached *before* the initial-link lookup is
  /// awaited so a link delivered while that lookup is in flight is never lost.
  /// Both sources funnel through [_handleUri], which dedups by token, so the
  /// same cold-start link reported by both the initial-link lookup and the
  /// stream still resolves to exactly one accepted intent.
  Future<void> init() async {
    if (_initialized || _disposed) return;
    _initialized = true;

    _linkSubscription = _linkSource.uriLinkStream.listen(
      (uri) => _handleUri(uri),
      onError: (_) {},
    );

    try {
      final initialUri = await _linkSource.getInitialLink();
      if (initialUri != null) {
        await _handleUri(initialUri);
      }
    } catch (_) {
      // Platform may not provide an initial link — expected on some platforms.
    }
  }

  Future<void> _handleUri(Uri uri) async {
    final intent = parseFollowUri(uri);
    if (intent == null) return;
    if (_disposed) return;

    // Dedup by token, keyed on the signed token rather than the source URI, so
    // a link delivered by both getInitialLink and the stream — or via both the
    // HTTPS and calee:// forms of one button — is resolved only once and never
    // opens two follow screens. A different token is never suppressed, and the
    // same token becomes acceptable again once the flow completes/cancels (via
    // [clearPending], which resets the window).
    final now = _clock();
    final lastAt = _lastHandledAt;
    if (intent.token == _lastHandledToken &&
        lastAt != null &&
        now.difference(lastAt) < dedupWindow) {
      return;
    }
    _lastHandledToken = intent.token;
    _lastHandledAt = now;

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

  /// Matches the signed calendar-follow deep links this app handles:
  ///
  ///   * `https://calembed.calee.com.au/follow?t=<signed-token>` (App Link)
  ///   * `calee://follow?t=<signed-token>` (explicit custom-scheme fallback)
  ///
  /// Both forms produce the same [CalendarFollowIntent] and must carry a
  /// non-empty signed `t` token. A raw calendar URL passed through `?url=` is
  /// intentionally NOT accepted here — only the signed intent is trusted, so a
  /// custom-scheme link can never smuggle an untrusted subscription URL into
  /// the app.
  @visibleForTesting
  static CalendarFollowIntent? parseFollowUri(Uri uri) {
    final isHttpsFollow =
        uri.scheme == 'https' &&
        uri.host == 'calembed.calee.com.au' &&
        uri.path == '/follow';
    final isCustomSchemeFollow = uri.scheme == 'calee' && uri.host == 'follow';

    if (!isHttpsFollow && !isCustomSchemeFollow) return null;

    final token = uri.queryParameters['t'] ?? '';
    if (token.isEmpty) return null;

    return CalendarFollowIntent(token: token, sourceUri: uri);
  }

  void clearPending() {
    pendingIntent = null;
    pendingError = null;
    // The flow completed or was cancelled — reset the dedup window so the same
    // calendar link can be opened again straight away.
    _lastHandledToken = null;
    _lastHandledAt = null;
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
