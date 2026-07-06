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
}
