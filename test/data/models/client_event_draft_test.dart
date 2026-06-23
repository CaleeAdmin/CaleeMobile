import 'package:calee_mobile/data/models/client_event_draft.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ClientEventDraft.fromJson', () {
    test('parses snake_case response', () {
      final draft = ClientEventDraft.fromJson({
        'title': 'Perfect Alibi at The Whippet Club',
        'starts_at': '2026-06-27T21:00:00.000Z',
        'ends_at': '2026-06-27T23:00:00.000Z',
        'all_day': false,
        'timezone': 'Australia/Perth',
        'location': 'The Whippet Club, Leederville',
        'description': 'Free entry.',
        'confidence': 0.9,
        'missing_fields': <String>[],
        'warnings': <String>['No year on flyer'],
      });

      expect(draft.title, 'Perfect Alibi at The Whippet Club');
      expect(draft.startsAt, isNotNull);
      expect(draft.endsAt, isNotNull);
      expect(draft.allDay, false);
      expect(draft.timezone, 'Australia/Perth');
      expect(draft.location, 'The Whippet Club, Leederville');
      expect(draft.description, 'Free entry.');
      expect(draft.confidence, closeTo(0.9, 0.001));
      expect(draft.missingFields, isEmpty);
      expect(draft.warnings, ['No year on flyer']);
    });

    test('parses camelCase response defensively', () {
      final draft = ClientEventDraft.fromJson({
        'title': 'Event A',
        'startsAt': '2026-06-27T21:00:00.000Z',
        'endsAt': '2026-06-27T23:00:00.000Z',
        'allDay': true,
        'missingFields': <String>['time'],
        'warnings': <String>[],
      });

      expect(draft.title, 'Event A');
      expect(draft.startsAt, isNotNull);
      expect(draft.endsAt, isNotNull);
      expect(draft.allDay, true);
      expect(draft.missingFields, ['time']);
      expect(draft.warnings, isEmpty);
    });

    test('missing optional fields do not crash', () {
      final draft = ClientEventDraft.fromJson({'title': 'Minimal'});

      expect(draft.title, 'Minimal');
      expect(draft.startsAt, isNull);
      expect(draft.endsAt, isNull);
      expect(draft.allDay, false);
      expect(draft.timezone, isNull);
      expect(draft.location, isNull);
      expect(draft.description, isNull);
      expect(draft.confidence, 0.0);
      expect(draft.missingFields, isEmpty);
      expect(draft.warnings, isEmpty);
    });

    test('completely empty json does not crash', () {
      final draft = ClientEventDraft.fromJson({});
      expect(draft.title, '');
      expect(draft.allDay, false);
      expect(draft.confidence, 0.0);
      expect(draft.missingFields, isEmpty);
      expect(draft.warnings, isEmpty);
    });

    test('invalid dates become null', () {
      final draft = ClientEventDraft.fromJson({
        'title': 'Bad dates',
        'starts_at': 'not-a-date',
        'ends_at': '99999-99-99',
      });

      expect(draft.startsAt, isNull);
      expect(draft.endsAt, isNull);
    });

    test('snake_case takes precedence over camelCase when both present', () {
      final draft = ClientEventDraft.fromJson({
        'title': 'Priority test',
        'starts_at': '2026-01-01T10:00:00.000Z',
        'startsAt': '2026-06-01T10:00:00.000Z',
        'all_day': true,
        'allDay': false,
      });

      expect(draft.startsAt, DateTime.tryParse('2026-01-01T10:00:00.000Z'));
      expect(draft.allDay, true);
    });
  });

  group('EventDraftsFromImageResponse.fromJson', () {
    test('parses empty drafts list', () {
      final response = EventDraftsFromImageResponse.fromJson({
        'drafts': <dynamic>[],
        'source_type': 'image',
        'timezone': 'Australia/Perth',
        'reference_date': '2026-06-23',
      });

      expect(response.drafts, isEmpty);
      expect(response.sourceType, 'image');
      expect(response.timezone, 'Australia/Perth');
      expect(response.referenceDate, '2026-06-23');
    });

    test('parses multiple drafts', () {
      final response = EventDraftsFromImageResponse.fromJson({
        'drafts': [
          {'title': 'Event A', 'all_day': false},
          {'title': 'Event B', 'all_day': true},
        ],
      });

      expect(response.drafts.length, 2);
      expect(response.drafts[0].title, 'Event A');
      expect(response.drafts[1].title, 'Event B');
      expect(response.drafts[1].allDay, true);
    });

    test('missing drafts key returns empty list', () {
      final response = EventDraftsFromImageResponse.fromJson({});
      expect(response.drafts, isEmpty);
    });

    test('malformed draft entries are skipped', () {
      final response = EventDraftsFromImageResponse.fromJson({
        'drafts': ['not-a-map', {'title': 'Valid'}, 42],
      });

      expect(response.drafts.length, 1);
      expect(response.drafts[0].title, 'Valid');
    });
  });
}
