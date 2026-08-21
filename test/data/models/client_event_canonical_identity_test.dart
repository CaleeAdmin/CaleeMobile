// ClientEvent's canonical Event Link identity fields
// (CaleeAdmin/CaleeMobile#559).
//
// `sourceUid` and `canonicalRecurrenceId` are ADDITIVE fields Hub Core added
// under CaleeAdmin/calee-hub-core#424. They are the only Event Link inputs;
// `id`, `seriesId`, `recurrenceId` and `occurrenceId` are Hub-local composite
// keys the occurrence-identity contract declares non-normative and must never
// substitute for them.
//
// What these tests defend is TRANSPORT FIDELITY. A UID is opaque source
// identity — the whole value, whitespace and case included — so any
// normalisation on the way in would mint a link naming a different source
// event, silently, on a client that cannot tell it happened.

import 'package:calee_mobile/data/models/client_calendar.dart';
import 'package:flutter_test/flutter_test.dart';

/// A minimal current-Hub event payload, plus whatever the test overrides.
Map<String, dynamic> _payload([Map<String, dynamic> extra = const {}]) => {
  'id': 'portal:cal-1:event-1',
  'calendarId': 'cal-1',
  'serviceId': 'portal',
  'serviceName': 'Portal',
  'title': 'Training',
  'startsAt': '2026-08-18T07:30:00Z',
  'endsAt': '2026-08-18T08:30:00Z',
  'allDay': false,
  'source': 'portal',
  'recurring': false,
  ...extra,
};

void main() {
  group('ClientEvent.fromJson canonical identity fields', () {
    test('parses sourceUid and canonicalRecurrenceId exactly as sent', () {
      final event = ClientEvent.fromJson(
        _payload({
          'sourceUid': ' uid ',
          'canonicalRecurrenceId': '20260818T073000Z',
        }),
      );

      // Byte for byte. Boundary whitespace IS identity: ` uid ` and `uid` are
      // two different source events, so a trim here would share the wrong one.
      expect(event.sourceUid, ' uid ');
      expect(event.canonicalRecurrenceId, '20260818T073000Z');
    });

    test('preserves the literal UID "0" rather than treating it as absent', () {
      final event = ClientEvent.fromJson(_payload({'sourceUid': '0'}));

      expect(event.sourceUid, '0');
    });

    test('preserves a UID that is only whitespace', () {
      // Presence is a question for the share-eligibility gate, not for the
      // parser. The parser's only job is not to change the value.
      final event = ClientEvent.fromJson(_payload({'sourceUid': '   '}));

      expect(event.sourceUid, '   ');
    });

    test('preserves non-ASCII and Unicode UIDs unchanged', () {
      const uid = 'événement-日本語-🎉-Ünïcøde';
      final event = ClientEvent.fromJson(_payload({'sourceUid': uid}));

      expect(event.sourceUid, uid);
    });

    test('preserves internal whitespace and case in a UID', () {
      const uid = 'A  b\tC';
      final event = ClientEvent.fromJson(_payload({'sourceUid': uid}));

      expect(event.sourceUid, uid);
      expect(event.sourceUid, isNot('A b\tC'));
      expect(event.sourceUid, isNot(uid.toLowerCase()));
    });

    test('preserves an all-day canonical recurrence identity (Ymd)', () {
      final event = ClientEvent.fromJson(
        _payload({
          'allDay': true,
          'recurring': true,
          'sourceUid': 'series-1',
          'canonicalRecurrenceId': '20260818',
        }),
      );

      expect(event.canonicalRecurrenceId, '20260818');
    });

    test('an old Hub payload carrying neither field parses to null', () {
      final event = ClientEvent.fromJson(_payload());

      expect(event.sourceUid, isNull);
      expect(event.canonicalRecurrenceId, isNull);
      // And the rest of the payload is untouched by their absence.
      expect(event.id, 'portal:cal-1:event-1');
      expect(event.title, 'Training');
    });

    test('an explicit null for either field parses to null', () {
      final event = ClientEvent.fromJson(
        _payload({'sourceUid': null, 'canonicalRecurrenceId': null}),
      );

      expect(event.sourceUid, isNull);
      expect(event.canonicalRecurrenceId, isNull);
    });

    test('the legacy composite ids keep their existing semantics', () {
      // These stay load-bearing for edit/delete and the UI. #559 changes what
      // Event Links are built from, not what these mean.
      final event = ClientEvent.fromJson(
        _payload({
          'recurring': true,
          'seriesId': 'portal:cal-1:series-1',
          'recurrenceId': '20260818T153000',
          'occurrenceId': 'portal:cal-1:series-1:20260818T153000',
          'sourceUid': 'series-1',
          'canonicalRecurrenceId': '20260818T073000Z',
        }),
      );

      expect(event.seriesId, 'portal:cal-1:series-1');
      expect(event.recurrenceId, '20260818T153000');
      expect(event.occurrenceId, 'portal:cal-1:series-1:20260818T153000');
      // And they are NOT the canonical identity: the display recurrence id is
      // a source wall clock, the canonical one is the true UTC instant.
      expect(event.canonicalRecurrenceId, isNot(event.recurrenceId));
      expect(event.sourceUid, isNot(event.id));
    });
  });

  group('ClientEvent construction', () {
    test('both fields are optional, so existing call sites still compile', () {
      const event = ClientEvent(
        id: 'e1',
        calendarId: 'c1',
        serviceId: 'portal',
        serviceName: 'Portal',
        title: 'Training',
        startsAt: '2026-08-18T07:30:00Z',
        endsAt: '2026-08-18T08:30:00Z',
        allDay: false,
        source: 'portal',
        recurring: false,
      );

      expect(event.sourceUid, isNull);
      expect(event.canonicalRecurrenceId, isNull);
    });
  });
}
