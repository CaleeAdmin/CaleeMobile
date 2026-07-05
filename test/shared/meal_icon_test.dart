import 'package:calee_mobile/shared/meal_icon.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('mealIconEmoji — icon slug', () {
    test('uses the icon slug when it matches the known map', () {
      expect(mealIconEmoji(icon: 'pasta', title: 'Anything'), '🍝');
      expect(mealIconEmoji(icon: 'taco', title: 'Anything'), '🌮');
      expect(mealIconEmoji(icon: 'lunchbox', title: 'Anything'), '🍱');
    });

    test('falls through to title/mealType when the icon slug is unknown', () {
      expect(
        mealIconEmoji(icon: 'not-a-real-slug', title: 'Chicken Curry'),
        '🍛',
      );
    });
  });

  group('mealIconEmoji — title fallback', () {
    test('matches spaghetti/pasta, curry, rice, chicken, pizza, taco', () {
      expect(mealIconEmoji(title: 'Spaghetti Bolognese'), '🍝');
      expect(mealIconEmoji(title: 'Fried Rice'), '🍚');
      expect(mealIconEmoji(title: 'Pizza Night'), '🍕');
      expect(mealIconEmoji(title: 'Taco Tuesday'), '🌮');
      expect(mealIconEmoji(title: 'Grilled Chicken'), '🍗');
    });

    test('prefers curry over chicken when both appear in the title', () {
      expect(mealIconEmoji(title: 'Chicken Curry'), '🍛');
    });
  });

  group('mealIconEmoji — mealType default', () {
    test('defaults unmatched breakfast titles to the breakfast icon', () {
      expect(mealIconEmoji(title: 'Cereal', mealType: 'breakfast'), '🍳');
    });

    test('defaults unmatched dinner titles to the fallback icon', () {
      expect(mealIconEmoji(title: 'ABC', mealType: 'dinner'), '🍴');
      expect(mealIconEmoji(title: 'paster', mealType: 'dinner'), '🍴');
    });
  });
}
