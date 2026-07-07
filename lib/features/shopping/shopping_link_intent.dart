// Future: Calee tablet can show a QR to
// https://hub.calee.com.au/mobile/shopping?weekStart=YYYY-MM-DD after this
// app-link configuration is verified on device.
class ShoppingLinkIntent {
  const ShoppingLinkIntent({required this.weekStart, required this.sourceUri});

  /// Requested week-start date, already validated as a real calendar date.
  /// Null means the link omitted `weekStart` or it wasn't a valid
  /// `YYYY-MM-DD` date — [ShoppingController] already defaults a null
  /// `initialWeekStart` to the current week, so callers can pass this
  /// straight through without any extra fallback logic.
  final DateTime? weekStart;
  final Uri sourceUri;

  /// Identifies the shopping target this intent resolves to, independent of
  /// which scheme/host delivered it — the HTTPS app-link and the
  /// `calee://shopping` custom scheme for the same `weekStart` produce the
  /// same key, so they're recognised as the same navigation target for
  /// dedup purposes rather than compared by [sourceUri] equality.
  String get canonicalKey {
    final w = weekStart;
    if (w == null) return 'shopping:current';
    final y = w.year.toString().padLeft(4, '0');
    final m = w.month.toString().padLeft(2, '0');
    final d = w.day.toString().padLeft(2, '0');
    return 'shopping:$y-$m-$d';
  }
}
