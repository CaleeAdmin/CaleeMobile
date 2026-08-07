import 'package:shared_preferences/shared_preferences.dart';

import 'local_calendar_subscription.dart';

/// How many *unique* calendars a signed-out (Guest) installation may follow
/// locally on one phone without a Calee account.
///
/// The allowance is counted per unique normalized subscription URL, so
/// reopening a calendar that is already followed never consumes capacity and
/// removing a calendar immediately frees a slot.
const int kMaxLocalCalendarSubscriptions = 5;

/// Typed domain condition raised by
/// [LocalCalendarSubscriptionRepository.add] when storing a **new unique**
/// calendar would exceed [kMaxLocalCalendarSubscriptions].
///
/// It is deliberately its own type — every calendar-follow ingress path can
/// then distinguish "the local allowance is full" from a genuine parser,
/// storage or network failure, and show the conversion experience instead of
/// an error. Raising it never modifies the calendars already stored.
class LocalCalendarSubscriptionLimitException implements Exception {
  const LocalCalendarSubscriptionLimitException({
    required this.attemptedTitle,
    required this.attemptedUrl,
    required this.currentCount,
    this.limit = kMaxLocalCalendarSubscriptions,
  });

  /// Display title of the calendar the user tried to follow, retained so the
  /// limit UI can keep the attempt's context.
  final String attemptedTitle;

  /// Normalized URL of the calendar the user tried to follow.
  ///
  /// Subscription URLs can carry a private access token, so this is structured
  /// state for callers that genuinely need the target — it is deliberately
  /// **not** included in [toString], which is what ends up in crash reports
  /// and log sinks.
  final String attemptedUrl;

  /// How many calendars were already stored when the attempt was rejected.
  final int currentCount;

  /// The allowance that was reached.
  final int limit;

  /// Diagnostic description.
  ///
  /// Carries only what is useful for diagnosing the limit condition. The
  /// subscription URL is never rendered here — an uncaught throw, a
  /// `debugPrint`, or any future logging of this exception must not be able to
  /// leak a tokenised calendar URL. Read [attemptedUrl] directly if a caller
  /// really needs it.
  @override
  String toString() =>
      'LocalCalendarSubscriptionLimitException('
      'attemptedTitle: $attemptedTitle, '
      'currentCount: $currentCount, limit: $limit)';
}

class LocalCalendarSubscriptionRepository {
  static const _storageKey = 'local_calendar_subscriptions_v1';

  Future<List<LocalCalendarSubscription>> list() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_storageKey);
    if (raw == null || raw.isEmpty) return [];
    return LocalCalendarSubscription.listFromJsonString(raw);
  }

  /// Follows [url] locally on this phone.
  ///
  /// Order is deliberate and load-bearing:
  ///
  /// 1. normalize the requested URL (`webcal://` → `https://`);
  /// 2. load the calendars already stored;
  /// 3. look for a duplicate of the normalized URL;
  /// 4. a duplicate returns the **existing** subscription successfully, so
  ///    reopening an already-followed calendar can never be blocked — not
  ///    even when the allowance is already full;
  /// 5. only a genuinely new calendar is measured against
  ///    [kMaxLocalCalendarSubscriptions];
  /// 6. at or above the allowance, throw
  ///    [LocalCalendarSubscriptionLimitException] without writing anything —
  ///    the stored calendars are left exactly as they were;
  /// 7. otherwise create and save the new subscription.
  ///
  /// Enforcing the allowance here rather than in a UI layer means every
  /// calendar-follow ingress path gets identical behaviour.
  Future<LocalCalendarSubscription> add({
    required String title,
    required String url,
    required String source,
  }) async {
    final normalizedUrl = _normalizeUrl(url.trim());
    final normalizedTitle = title.trim().isEmpty ? 'Calendar' : title.trim();

    final prefs = await SharedPreferences.getInstance();
    final existing = await _load(prefs);

    final duplicate = _findByUrl(existing, normalizedUrl);
    if (duplicate != null) return duplicate;

    if (existing.length >= kMaxLocalCalendarSubscriptions) {
      throw LocalCalendarSubscriptionLimitException(
        attemptedTitle: normalizedTitle,
        attemptedUrl: normalizedUrl,
        currentCount: existing.length,
      );
    }

    final subscription = LocalCalendarSubscription(
      id: _idFromUrl(normalizedUrl),
      title: normalizedTitle,
      url: normalizedUrl,
      source: source,
      createdAt: DateTime.now(),
    );

    existing.add(subscription);
    await _save(prefs, existing);
    return subscription;
  }

  Future<void> remove(String id) async {
    final prefs = await SharedPreferences.getInstance();
    final items = await _load(prefs);
    items.removeWhere((s) => s.id == id);
    await _save(prefs, items);
  }

  Future<void> updateLastFetchedAt(String id, DateTime value) async {
    final prefs = await SharedPreferences.getInstance();
    final items = await _load(prefs);
    final idx = items.indexWhere((s) => s.id == id);
    if (idx == -1) return;
    items[idx] = items[idx].copyWith(lastFetchedAt: value);
    await _save(prefs, items);
  }

  Future<bool> containsUrl(String url) async {
    final normalizedUrl = _normalizeUrl(url.trim());
    final items = await list();
    return _findByUrl(items, normalizedUrl) != null;
  }

  // ── Helpers ───────────────────────────────────────────────────────────────

  Future<List<LocalCalendarSubscription>> _load(SharedPreferences prefs) {
    final raw = prefs.getString(_storageKey);
    if (raw == null || raw.isEmpty) return Future.value([]);
    return Future.value(LocalCalendarSubscription.listFromJsonString(raw));
  }

  Future<void> _save(
    SharedPreferences prefs,
    List<LocalCalendarSubscription> items,
  ) async {
    await prefs.setString(
      _storageKey,
      LocalCalendarSubscription.listToJsonString(items),
    );
  }

  LocalCalendarSubscription? _findByUrl(
    List<LocalCalendarSubscription> items,
    String normalizedUrl,
  ) {
    for (final item in items) {
      if (item.url == normalizedUrl) return item;
    }
    return null;
  }

  String _normalizeUrl(String url) {
    if (url.startsWith('webcal://')) {
      return 'https://${url.substring('webcal://'.length)}';
    }
    return url;
  }

  String _idFromUrl(String url) {
    // Stable ID derived from the URL so duplicate checks are consistent.
    var hash = 0;
    for (final unit in url.codeUnits) {
      hash = (hash * 31 + unit) & 0x7fffffff;
    }
    return 'local_$hash';
  }
}
