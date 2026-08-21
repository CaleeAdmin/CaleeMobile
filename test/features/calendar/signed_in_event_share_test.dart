// Signed-in Event Link eligibility (CaleeAdmin/CaleeMobile#559).
//
// Pure tests over `signedInEventShareState()`: no widgets, no sockets, no
// share sheet. The question here is only ever "may this event be shared, and
// with exactly which three values" — and the answer must match what the
// signed-out path produces for the SAME logical occurrence.
//
// Two properties are load-bearing throughout:
//
//  * publication is decided by the stored subscription URL, never by
//    `readOnly`. A private Google feed is read-only too;
//  * the values sent are Hub's canonical fields, byte for byte. Never
//    `event.id`, `seriesId`, `recurrenceId`, `occurrenceId`, or anything
//    derived from `startsAt`.

import 'package:calee_mobile/data/models/client_calendar.dart';
import 'package:calee_mobile/features/calendar/signed_in_event_share.dart';
import 'package:calee_mobile/features/local_subscriber/local_event_details_sheet.dart';
import 'package:flutter_test/flutter_test.dart';

// ── Fixtures ────────────────────────────────────────────────────────────────

const String _portalUrl =
    'https://portal.calee.com.au/remote.php/dav/public-calendars/abcdefgh?export';
const String _businessUrl =
    'https://business.calee.com.au/remote.php/dav/public-calendars/tok12345?export';
const String _cewaUrl =
    'https://cewa.calee.com.au/remote.php/dav/public-calendars/cewatok1?export';

ClientCalendar _calendar({
  bool isSubscription = true,
  bool readOnly = true,
  String? subscriptionUrl = _portalUrl,
  String source = 'portal',
  String serviceId = 'portal',
  String? providerKey,
}) => ClientCalendar(
  id: 'portal:public-1',
  serviceId: serviceId,
  serviceName: 'Portal',
  name: 'Lazers (Morley Eagles)',
  components: const [],
  primaryKind: 'calendar',
  supportsEvents: true,
  supportsTasks: false,
  supportsChores: false,
  readOnly: readOnly,
  isSubscription: isSubscription,
  subscriptionUrl: subscriptionUrl,
  source: source,
  providerKey: providerKey,
);

ClientEvent _event({
  String? sourceUid = 'event-uid-1',
  String? canonicalRecurrenceId,
  bool recurring = false,
  bool allDay = false,
  String startsAt = '2026-08-18T07:30:00Z',
  String id = 'portal:public-1:event-1',
  String? seriesId,
  String? recurrenceId,
  String? occurrenceId,
}) => ClientEvent(
  id: id,
  calendarId: 'portal:public-1',
  serviceId: 'portal',
  serviceName: 'Portal',
  title: 'Training',
  startsAt: startsAt,
  endsAt: '2026-08-18T08:30:00Z',
  allDay: allDay,
  source: 'portal',
  recurring: recurring,
  seriesId: seriesId,
  recurrenceId: recurrenceId,
  occurrenceId: occurrenceId,
  sourceUid: sourceUid,
  canonicalRecurrenceId: canonicalRecurrenceId,
  readOnly: true,
);

void main() {
  group('supported public sources', () {
    test('A · portal subscription with a one-off UID is shareable', () {
      final state = signedInEventShareState(_event(), _calendar());

      expect(state.availability, LocalEventShareAvailability.available);
      expect(state.target!.uid, 'event-uid-1');
      // A one-off carries NO occurrence id, so the mint request omits the key
      // entirely — contract §1: moving a one-off must not change its identity.
      expect(state.target!.occurrenceId, isNull);
      expect(state.target!.source.base, 'portal');
      expect(state.target!.source.canonicalUrl, _portalUrl);
    });

    test('B · business subscription is shareable', () {
      final state = signedInEventShareState(
        _event(),
        _calendar(subscriptionUrl: _businessUrl),
      );

      expect(state.availability, LocalEventShareAvailability.available);
      expect(state.target!.source.base, 'business');
      expect(state.target!.source.canonicalUrl, _businessUrl);
    });

    test('C · cewa subscription is shareable', () {
      final state = signedInEventShareState(
        _event(),
        _calendar(subscriptionUrl: _cewaUrl),
      );

      expect(state.availability, LocalEventShareAvailability.available);
      expect(state.target!.source.base, 'cewa');
      expect(state.target!.source.canonicalUrl, _cewaUrl);
    });
  });

  group('identity sent to the mint endpoint', () {
    test('D · a recurring occurrence sends canonicalRecurrenceId exactly', () {
      final state = signedInEventShareState(
        _event(
          recurring: true,
          canonicalRecurrenceId: '20260818T073000Z',
          // Every one of these is a Hub-local composite key, present and
          // deliberately different, so picking one up by mistake would show.
          id: 'portal:public-1:series-1:20260818T153000',
          seriesId: 'portal:public-1:series-1',
          recurrenceId: '20260818T153000',
          occurrenceId: 'portal:public-1:series-1:20260818T153000',
        ),
        _calendar(),
      );

      expect(state.availability, LocalEventShareAvailability.available);
      expect(state.target!.occurrenceId, '20260818T073000Z');
      // Not the display wall clock, not the composite, not the series.
      expect(state.target!.occurrenceId, isNot('20260818T153000'));
      expect(
        state.target!.occurrenceId,
        isNot('portal:public-1:series-1:20260818T153000'),
      );
      expect(state.target!.uid, isNot('portal:public-1:series-1'));
    });

    test('D2 · an all-day recurring occurrence sends the Ymd identity', () {
      final state = signedInEventShareState(
        _event(
          recurring: true,
          allDay: true,
          startsAt: '2026-08-18T00:00:00Z',
          canonicalRecurrenceId: '20260818',
        ),
        _calendar(),
      );

      expect(state.target!.occurrenceId, '20260818');
    });

    test('E · a DETACHED moved occurrence keeps its ORIGINAL identity', () {
      // Hub moved the display time to 09:00 local and renumbered its local
      // recurrence id, but canonicalRecurrenceId still names the ORIGINAL
      // slot. A link shared before the move must keep resolving after it, so
      // the moved startsAt must not reach the request.
      final state = signedInEventShareState(
        _event(
          recurring: true,
          startsAt: '2026-08-20T01:00:00Z',
          canonicalRecurrenceId: '20260818T073000Z',
          recurrenceId: '20260820T090000',
          occurrenceId: 'portal:public-1:series-1:20260820T090000',
          seriesId: 'portal:public-1:series-1',
        ),
        _calendar(),
      );

      expect(state.availability, LocalEventShareAvailability.available);
      expect(state.target!.occurrenceId, '20260818T073000Z');
      // The moved instant appears nowhere in what is sent.
      expect(state.target!.occurrenceId, isNot(contains('20260820')));
    });

    test('F · the literal UID "0" is shareable and sent as "0"', () {
      final state = signedInEventShareState(
        _event(sourceUid: '0'),
        _calendar(),
      );

      expect(state.availability, LocalEventShareAvailability.available);
      expect(state.target!.uid, '0');
    });

    test('G · a UID with boundary whitespace is sent untrimmed', () {
      final state = signedInEventShareState(
        _event(sourceUid: '  spaced-uid  '),
        _calendar(),
      );

      expect(state.availability, LocalEventShareAvailability.available);
      expect(state.target!.uid, '  spaced-uid  ');
      expect(state.target!.uid, isNot('spaced-uid'));
    });

    test('G2 · a UID keeps its case and internal whitespace', () {
      final state = signedInEventShareState(
        _event(sourceUid: 'Mixed  Case\tUID'),
        _calendar(),
      );

      expect(state.target!.uid, 'Mixed  Case\tUID');
    });

    test('K · a one-off ignores canonicalRecurrenceId and stays shareable', () {
      // Hub sends null here for a one-off, but even if a value arrived it is
      // irrelevant: a non-recurring event has no recurrence identity at all.
      final state = signedInEventShareState(
        _event(canonicalRecurrenceId: '20260818T073000Z'),
        _calendar(),
      );

      expect(state.availability, LocalEventShareAvailability.available);
      expect(state.target!.occurrenceId, isNull);
    });

    test('K2 · a one-off is shareable with no startsAt to speak of', () {
      // Shareability must not depend on startsAt or timeZone for a one-off.
      final state = signedInEventShareState(
        _event(startsAt: 'not-a-date'),
        _calendar(),
      );

      expect(state.availability, LocalEventShareAvailability.available);
      expect(state.target!.uid, 'event-uid-1');
    });
  });

  group('events on a public source that cannot be named', () {
    test('H · a missing sourceUid is not shareable', () {
      final state = signedInEventShareState(
        _event(sourceUid: null),
        _calendar(),
      );

      expect(
        state.availability,
        LocalEventShareAvailability.unavailableForEvent,
      );
      expect(state.target, isNull);
    });

    test('I · a whitespace-only sourceUid is not shareable', () {
      final state = signedInEventShareState(
        _event(sourceUid: '   '),
        _calendar(),
      );

      expect(
        state.availability,
        LocalEventShareAvailability.unavailableForEvent,
      );
      expect(state.target, isNull);
    });

    test('I2 · an empty sourceUid is not shareable', () {
      final state = signedInEventShareState(_event(sourceUid: ''), _calendar());

      expect(
        state.availability,
        LocalEventShareAvailability.unavailableForEvent,
      );
    });

    test('J · a recurring event with no canonicalRecurrenceId is not '
        'shareable', () {
      final state = signedInEventShareState(
        _event(
          recurring: true,
          canonicalRecurrenceId: null,
          // A perfectly usable LOCAL recurrence id is present. It must not be
          // promoted into the canonical slot to rescue the mint.
          recurrenceId: '20260818T153000',
          occurrenceId: 'portal:public-1:series-1:20260818T153000',
        ),
        _calendar(),
      );

      expect(
        state.availability,
        LocalEventShareAvailability.unavailableForEvent,
      );
      expect(state.target, isNull);
    });

    test('J2 · a blank canonicalRecurrenceId is not shareable', () {
      final state = signedInEventShareState(
        _event(recurring: true, canonicalRecurrenceId: '  '),
        _calendar(),
      );

      expect(
        state.availability,
        LocalEventShareAvailability.unavailableForEvent,
      );
    });
  });

  group('unsupported sources', () {
    test('L · a private writable family calendar is unsupported', () {
      final state = signedInEventShareState(
        _event(),
        _calendar(
          isSubscription: false,
          readOnly: false,
          subscriptionUrl: null,
          source: 'nextcloud',
          serviceId: 'svc1',
        ),
      );

      expect(state.availability, LocalEventShareAvailability.unsupportedSource);
      expect(state.target, isNull);
    });

    test('M · a read-only Google calendar is unsupported', () {
      final state = signedInEventShareState(
        _event(),
        _calendar(
          isSubscription: false,
          subscriptionUrl: null,
          source: 'external',
          serviceId: 'external',
          providerKey: 'google_calendar',
        ),
      );

      expect(state.availability, LocalEventShareAvailability.unsupportedSource);
    });

    test('M2 · a Google calendar modelled as a subscription is still '
        'unsupported', () {
      // readOnly is true and isSubscription is true; only the URL says no.
      final state = signedInEventShareState(
        _event(),
        _calendar(
          subscriptionUrl:
              'https://calendar.google.com/calendar/ical/x%40group.calendar.google.com/private-abc/basic.ics',
          providerKey: 'google_calendar',
        ),
      );

      expect(state.availability, LocalEventShareAvailability.unsupportedSource);
    });

    test('N · an Outlook / arbitrary external HTTPS ICS is unsupported', () {
      for (final url in const [
        'https://outlook.office365.com/owa/calendar/abc/reachcalendar.ics',
        'https://example.com/feed.ics',
        'webcal://portal.calee.com.au/remote.php/dav/public-calendars/abcdefgh?export',
      ]) {
        final state = signedInEventShareState(
          _event(),
          _calendar(subscriptionUrl: url),
        );

        expect(
          state.availability,
          LocalEventShareAvailability.unsupportedSource,
          reason: 'must not be shareable: $url',
        );
      }
    });

    test('O · Calee-lookalike hosts and paths are refused by the validator', () {
      for (final url in const [
        // Host suffix / subdomain attacks.
        'https://portal.calee.com.au.attacker.example/remote.php/dav/public-calendars/abcdefgh?export',
        'https://foo.portal.calee.com.au/remote.php/dav/public-calendars/abcdefgh?export',
        'https://notportal.calee.com.au/remote.php/dav/public-calendars/abcdefgh?export',
        // Userinfo smuggling the real host into the authority.
        'https://portal.calee.com.au@attacker.example/remote.php/dav/public-calendars/abcdefgh?export',
        // Explicit port.
        'https://portal.calee.com.au:443/remote.php/dav/public-calendars/abcdefgh?export',
        // Path and query tampering.
        'https://portal.calee.com.au/remoteXphp/dav/public-calendars/abcdefgh?export',
        'https://portal.calee.com.au/remote.php/dav/public-calendars/abcdefgh/extra?export',
        'https://portal.calee.com.au/remote.php/dav/public-calendars/abcdefgh?export=1',
        'https://portal.calee.com.au/remote.php/dav/public-calendars/abcdefgh?export&foo=bar',
        'https://portal.calee.com.au/remote.php/dav/public-calendars/abcdefgh?export#frag',
        // Plaintext, and a trailing slash.
        'http://portal.calee.com.au/remote.php/dav/public-calendars/abcdefgh?export',
        'https://portal.calee.com.au/remote.php/dav/public-calendars/abcdefgh?export/',
        // Token too short for the strict grammar.
        'https://portal.calee.com.au/remote.php/dav/public-calendars/short?export',
        // Surrounding whitespace.
        ' https://portal.calee.com.au/remote.php/dav/public-calendars/abcdefgh?export',
      ]) {
        final state = signedInEventShareState(
          _event(),
          _calendar(subscriptionUrl: url),
        );

        expect(
          state.availability,
          LocalEventShareAvailability.unsupportedSource,
          reason: 'must not be shareable: $url',
        );
      }
    });

    test('P · a valid public URL on a NON-subscription is unsupported', () {
      final state = signedInEventShareState(
        _event(),
        _calendar(isSubscription: false),
      );

      expect(state.availability, LocalEventShareAvailability.unsupportedSource);
      expect(state.target, isNull);
    });

    test('a null subscriptionUrl is unsupported', () {
      final state = signedInEventShareState(
        _event(),
        _calendar(subscriptionUrl: null),
      );

      expect(state.availability, LocalEventShareAvailability.unsupportedSource);
    });

    test('an unresolvable calendar is unsupported, never assumed public', () {
      final state = signedInEventShareState(_event(), null);

      expect(state.availability, LocalEventShareAvailability.unsupportedSource);
      expect(state.target, isNull);
    });
  });

  group('readOnly is not the publication boundary', () {
    test('a read-only private feed is NOT shareable', () {
      final state = signedInEventShareState(
        _event(),
        _calendar(readOnly: true, subscriptionUrl: 'https://example.com/x.ics'),
      );

      expect(state.availability, LocalEventShareAvailability.unsupportedSource);
    });

    test('a WRITABLE public Calee subscription is still shareable', () {
      // Publication is a property of the URL, so eligibility must not flip
      // just because the calendar happens to be writable. (Whether the UI
      // offers Share for such an odd row is CalendarPage's routing decision,
      // not this gate's.)
      final state = signedInEventShareState(
        _event(),
        _calendar(readOnly: false),
      );

      expect(state.availability, LocalEventShareAvailability.available);
      expect(state.target!.uid, 'event-uid-1');
    });
  });

  group('same-occurrence parity with signed-out sharing', () {
    test('sends the identical triple the signed-out path sends', () {
      // The SAME logical public occurrence, described the two different ways
      // the two clients see it. Signed-out reads the ICS itself; signed-in
      // reads Hub's already-resolved canonical fields. The three values that
      // reach `LocalEventLinkService.mint()` must be identical, because the
      // one shared service turns them into one request against one endpoint.
      const uid = 'series-one@calee.com.au';
      const canonicalRecurrenceId = '20260818T073000Z';

      final state = signedInEventShareState(
        _event(
          recurring: true,
          sourceUid: uid,
          canonicalRecurrenceId: canonicalRecurrenceId,
          // Hub-local composites that the signed-out client never even sees.
          id: 'portal:public-1:series-1:20260818T153000',
          seriesId: 'portal:public-1:series-1',
          recurrenceId: '20260818T153000',
          occurrenceId: 'portal:public-1:series-1:20260818T153000',
        ),
        _calendar(),
      );

      expect(state.availability, LocalEventShareAvailability.available);
      expect(state.target!.source.canonicalUrl, _portalUrl);
      expect(state.target!.uid, uid);
      expect(state.target!.occurrenceId, canonicalRecurrenceId);
    });
  });
}
