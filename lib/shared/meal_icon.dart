/// Shared meal → emoji mapping, mirroring the Calee tablet's MealIconEmoji.
///
/// Templates (family favourites, quick dinner ideas) carry an explicit
/// [icon] slug from the backend. Plain planned meals (`ClientMeal`) don't
/// store an icon, so [mealIconEmoji] falls back to matching keywords in the
/// meal's title, then to a sensible default for the meal type.
const Map<String, String> kMealIconSlugs = {
  'pasta': '🍝',
  'rice': '🍚',
  'taco': '🌮',
  'curry': '🍛',
  'pizza': '🍕',
  'bbq': '🍖',
  'chicken': '🍗',
  'soup': '🍲',
  'fish': '🐟',
  'burger': '🍔',
  'leftovers': '🍴',
  'takeaway': '🥡',
  'sandwich': '🥪',
  'lunchbox': '🍱',
  'breakfast': '🍳',
  'egg': '🥚',
  'fruit': '🍎',
  'fallback': '🍴',
};

const List<(List<String>, String)> _kTitleKeywordRules = [
  (['spaghetti', 'pasta'], '🍝'),
  (['curry'], '🍛'),
  (['rice'], '🍚'),
  (['chicken'], '🍗'),
  (['pizza'], '🍕'),
  (['taco'], '🌮'),
];

/// Resolves the emoji for a meal. Prefers an explicit [icon] slug (from a
/// meal template); otherwise matches keywords in [title]; otherwise falls
/// back to a default for [mealType] ('breakfast' -> 🍳, 'lunch' -> 🍱, else
/// the generic fallback).
String mealIconEmoji({
  String? icon,
  required String title,
  String mealType = '',
}) {
  final normalizedIcon = icon?.trim().toLowerCase();
  if (normalizedIcon != null && kMealIconSlugs.containsKey(normalizedIcon)) {
    return kMealIconSlugs[normalizedIcon]!;
  }

  final lowerTitle = title.toLowerCase();
  for (final rule in _kTitleKeywordRules) {
    final (keywords, emoji) = rule;
    if (keywords.any(lowerTitle.contains)) return emoji;
  }

  switch (mealType) {
    case 'breakfast':
      return kMealIconSlugs['breakfast']!;
    case 'lunch':
      return kMealIconSlugs['lunchbox']!;
    default:
      return kMealIconSlugs['fallback']!;
  }
}
