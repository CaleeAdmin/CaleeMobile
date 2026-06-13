import 'package:shared_preferences/shared_preferences.dart';

import 'local_calendar_subscription.dart';

class LocalCalendarSubscriptionRepository {
  static const _storageKey = 'local_calendar_subscriptions_v1';

  Future<List<LocalCalendarSubscription>> list() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_storageKey);
    if (raw == null || raw.isEmpty) return [];
    return LocalCalendarSubscription.listFromJsonString(raw);
  }

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
