// Unit tests for buildCalendarAppearancePatch(), the shared changed-fields
// calculator behind both appearance-editing surfaces (CalendarDetailSheet
// and CalendarCollectionsPage). The patch must contain exactly the fields
// the user changed: an unchanged field sent to the /appearance endpoint
// would become a permanent local override on the backend.

import 'package:calee_mobile/features/calendar/widgets/calendar_widget_helpers.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('buildCalendarAppearancePatch', () {
    test('name-only change yields a name-only patch', () {
      final patch = buildCalendarAppearancePatch(
        originalName: 'Family',
        originalColor: '#FF9500',
        nextName: 'School',
        nextColor: '#FF9500',
      );

      expect(patch, isNotNull);
      expect(patch!.name, 'School');
      expect(patch.color, isNull);
    });

    test('colour-only change yields a colour-only patch', () {
      final patch = buildCalendarAppearancePatch(
        originalName: 'Family',
        originalColor: '#FF9500',
        nextName: 'Family',
        nextColor: '#007AFF',
      );

      expect(patch, isNotNull);
      expect(patch!.name, isNull);
      expect(patch.color, '#007AFF');
    });

    test('changing both yields both fields', () {
      final patch = buildCalendarAppearancePatch(
        originalName: 'Family',
        originalColor: '#FF9500',
        nextName: 'School',
        nextColor: '#007AFF',
      );

      expect(patch, (name: 'School', color: '#007AFF'));
    });

    test('no change yields null (no request)', () {
      final patch = buildCalendarAppearancePatch(
        originalName: 'Family',
        originalColor: '#FF9500',
        nextName: 'Family',
        nextColor: '#FF9500',
      );

      expect(patch, isNull);
    });

    test('hex colour comparison is case-insensitive', () {
      final patch = buildCalendarAppearancePatch(
        originalName: 'Family',
        originalColor: '#ff9500',
        nextName: 'Family',
        nextColor: '#FF9500',
      );

      expect(patch, isNull);
    });

    test('a missing leading # does not fake a colour change', () {
      final patch = buildCalendarAppearancePatch(
        originalName: 'Family',
        originalColor: '#FF9500',
        nextName: 'Family',
        nextColor: 'ff9500',
      );

      expect(patch, isNull);
    });

    test('surrounding whitespace does not fake a change', () {
      final patch = buildCalendarAppearancePatch(
        originalName: 'Family',
        originalColor: '#FF9500',
        nextName: '  Family ',
        nextColor: ' #FF9500 ',
      );

      expect(patch, isNull);
    });

    test('null original colour with blank next colour is not a change', () {
      final patch = buildCalendarAppearancePatch(
        originalName: 'Family',
        originalColor: null,
        nextName: 'Family',
        nextColor: '',
      );

      expect(patch, isNull);
    });

    test(
      'clearing a colour is treated as unchanged, not as a reset request',
      () {
        final patch = buildCalendarAppearancePatch(
          originalName: 'Family',
          originalColor: '#FF9500',
          nextName: 'School',
          nextColor: null,
        );

        expect(patch, isNotNull);
        expect(patch!.name, 'School');
        expect(patch.color, isNull);
      },
    );

    test('setting a colour where none existed is a colour change', () {
      final patch = buildCalendarAppearancePatch(
        originalName: 'Family',
        originalColor: null,
        nextName: 'Family',
        nextColor: '#007AFF',
      );

      expect(patch, isNotNull);
      expect(patch!.name, isNull);
      expect(patch.color, '#007AFF');
    });
  });
}
