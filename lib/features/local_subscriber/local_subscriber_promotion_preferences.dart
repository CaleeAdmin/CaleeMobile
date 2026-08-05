import 'package:shared_preferences/shared_preferences.dart';

/// Persists whether the local-calendar page's inline Calee-for-home
/// promotion has been dismissed on this installation.
///
/// Deliberately stored under its own versioned key, separate from the
/// calendar-subscription payload: dismissing the promotion must never touch
/// stored subscriptions, and removing a subscription must never resurrect a
/// dismissed promotion.
class LocalSubscriberPromotionPreferences {
  const LocalSubscriberPromotionPreferences();

  static const String inlineHomePromoDismissedKey =
      'local_calendar_inline_home_promo_dismissed_v1';

  /// Whether the inline promotion was dismissed on this installation.
  ///
  /// Defaults to false (promotion visible). A read failure also reports
  /// false: a preferences problem may re-show the promotion but must never
  /// crash the page.
  Future<bool> isInlineHomePromotionDismissed() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getBool(inlineHomePromoDismissedKey) ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Records the dismissal for future launches. Best-effort: a failed write
  /// is swallowed — the promotion stays hidden for the current session and
  /// may reappear on the next launch, which is preferable to crashing.
  Future<void> dismissInlineHomePromotion() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(inlineHomePromoDismissedKey, true);
    } catch (_) {
      // Persistence is best-effort; never crash on a failed write.
    }
  }
}
