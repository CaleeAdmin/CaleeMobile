// The capability contract for one signed-in event (CaleeAdmin/CaleeMobile#566).
//
// These tests exist to state, in one place, that three questions about an
// event are INDEPENDENT:
//
//   * may Calee change it       (a permission on its calendar)
//   * may it be shared publicly (a publication fact about its source)
//   * what should the user be told about where it came from
//
// The widget tests prove the user can see the result; these prove the rule
// itself, including the combinations that are awkward to stage on screen.

import 'package:calee_mobile/data/models/client_calendar.dart';
import 'package:calee_mobile/features/calendar/event_capabilities.dart';
import 'package:calee_mobile/features/calendar/shared/event_share_action.dart';
import 'package:flutter_test/flutter_test.dart';

const String _kPublicUrl =
    'https://portal.calee.com.au/remote.php/dav/public-calendars/abcdefgh?export';

ClientCalendar _calendar({
  String id = 'portal:cal',
  bool readOnly = false,
  bool isSubscription = false,
  String? subscriptionUrl,
  String source = 'nextcloud',
  String serviceId = 'portal',
  String? providerKey,
}) => ClientCalendar(
  id: id,
  serviceId: serviceId,
  serviceName: 'Portal',
  name: 'A Calendar',
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
  String calendarId = 'portal:cal',
  bool readOnly = false,
  bool recurring = false,
  String? sourceUid = 'uid-1',
  String? canonicalRecurrenceId,
  String source = 'nextcloud',
  String serviceId = 'portal',
  String? providerKey,
}) => ClientEvent(
  id: 'evt-1',
  calendarId: calendarId,
  serviceId: serviceId,
  serviceName: 'Portal',
  title: 'An Event',
  startsAt: '2026-08-21T13:00:00',
  endsAt: '2026-08-21T14:00:00',
  allDay: false,
  source: source,
  recurring: recurring,
  sourceUid: sourceUid,
  canonicalRecurrenceId: canonicalRecurrenceId,
  providerKey: providerKey,
  readOnly: readOnly,
);

void main() {
  group('mutation eligibility keeps its existing meaning', () {
    test('a writable private calendar can be edited and deleted', () {
      final capabilities = resolveEventCapabilities(
        event: _event(),
        calendar: _calendar(),
      );

      expect(capabilities.canEdit, isTrue);
      expect(capabilities.canDelete, isTrue);
      expect(capabilities.isReadOnlyInCalee, isFalse);
      expect(capabilities.readOnlyNote, isNull);
    });

    test('a read-only calendar cannot', () {
      final capabilities = resolveEventCapabilities(
        event: _event(),
        calendar: _calendar(readOnly: true),
      );

      expect(capabilities.canEdit, isFalse);
      expect(capabilities.canDelete, isFalse);
    });

    test('a read-only EVENT on a writable calendar cannot', () {
      final capabilities = resolveEventCapabilities(
        event: _event(readOnly: true),
        calendar: _calendar(),
      );

      expect(capabilities.canEdit, isFalse);
    });

    test('an external calendar cannot', () {
      final capabilities = resolveEventCapabilities(
        event: _event(calendarId: 'external:g', source: 'external'),
        calendar: _calendar(id: 'external:g', source: 'external'),
      );

      expect(capabilities.canEdit, isFalse);
    });

    test('a writable calendar whose backend sent no capabilities object is '
        'still editable', () {
      // CalendarCapabilities.fallback() intentionally fails canEditEvents
      // closed on an old Hub. Mutation must NOT be rederived from it, or
      // every legacy writable calendar silently loses Edit.
      final legacy = ClientCalendar.fromJson(const {
        'id': 'portal:cal',
        'name': 'Family',
        'readOnly': false,
        'isSubscription': false,
        'source': 'nextcloud',
      });

      expect(legacy.capabilities.canEditEvents, isFalse);
      expect(
        resolveEventCapabilities(event: _event(), calendar: legacy).canEdit,
        isTrue,
      );
    });
  });

  group('share eligibility is not derived from anything else', () {
    test('a PUBLIC WRITABLE calendar is both editable and shareable', () {
      final capabilities = resolveEventCapabilities(
        event: _event(),
        calendar: _calendar(isSubscription: true, subscriptionUrl: _kPublicUrl),
      );

      expect(capabilities.canEdit, isTrue);
      expect(capabilities.canDelete, isTrue);
      expect(capabilities.canShare, isTrue);
      expect(capabilities.shareState.target, isNotNull);
      expect(capabilities.shareState.target!.uid, 'uid-1');
    });

    test('a PUBLIC READ-ONLY subscription is shareable and not editable', () {
      final capabilities = resolveEventCapabilities(
        event: _event(readOnly: true),
        calendar: _calendar(
          readOnly: true,
          isSubscription: true,
          subscriptionUrl: _kPublicUrl,
        ),
      );

      expect(capabilities.canEdit, isFalse);
      expect(capabilities.canShare, isTrue);
    });

    test('read-only alone never implies shareable', () {
      final capabilities = resolveEventCapabilities(
        event: _event(readOnly: true),
        calendar: _calendar(readOnly: true),
      );

      expect(capabilities.isReadOnlyInCalee, isTrue);
      expect(capabilities.canShare, isFalse);
      expect(
        capabilities.shareState.availability,
        LocalEventShareAvailability.unsupportedSource,
      );
    });

    test('writable alone never implies unshareable', () {
      // The inverse of the bug: the previous routing returned as soon as it
      // found an event writable, so a published calendar the user could also
      // edit lost Share entirely.
      final writablePublic = resolveEventCapabilities(
        event: _event(),
        calendar: _calendar(isSubscription: true, subscriptionUrl: _kPublicUrl),
      );
      final readOnlyPublic = resolveEventCapabilities(
        event: _event(readOnly: true),
        calendar: _calendar(
          readOnly: true,
          isSubscription: true,
          subscriptionUrl: _kPublicUrl,
        ),
      );

      expect(writablePublic.canShare, readOnlyPublic.canShare);
      expect(
        writablePublic.shareState.target!.uid,
        readOnlyPublic.shareState.target!.uid,
      );
    });

    test('a recurring occurrence with no canonical identity is refused', () {
      final capabilities = resolveEventCapabilities(
        event: _event(recurring: true, canonicalRecurrenceId: null),
        calendar: _calendar(
          readOnly: true,
          isSubscription: true,
          subscriptionUrl: _kPublicUrl,
        ),
      );

      expect(capabilities.canShare, isFalse);
      expect(
        capabilities.shareState.availability,
        LocalEventShareAvailability.unavailableForEvent,
      );
    });

    test('an arbitrary private ICS subscription is refused', () {
      final capabilities = resolveEventCapabilities(
        event: _event(readOnly: true),
        calendar: _calendar(
          readOnly: true,
          isSubscription: true,
          subscriptionUrl: 'https://school.example.com/private/feed.ics',
        ),
      );

      expect(capabilities.canShare, isFalse);
    });

    test('Google is refused', () {
      final capabilities = resolveEventCapabilities(
        event: _event(
          calendarId: 'external:g',
          source: 'external',
          providerKey: 'google_calendar',
          readOnly: true,
        ),
        calendar: _calendar(
          id: 'external:g',
          source: 'external',
          readOnly: true,
          providerKey: 'google_calendar',
        ),
      );

      expect(capabilities.canShare, isFalse);
    });
  });

  group('an unresolvable calendar fails closed', () {
    test('no edit, no delete, no share', () {
      final capabilities = resolveEventCapabilities(
        event: _event(),
        calendar: null,
      );

      expect(capabilities.canEdit, isFalse);
      expect(capabilities.canDelete, isFalse);
      expect(capabilities.canShare, isFalse);
      expect(capabilities.isReadOnlyInCalee, isTrue);
    });

    test('and invents no provider', () {
      final capabilities = resolveEventCapabilities(
        event: _event(),
        calendar: null,
      );

      expect(capabilities.readOnlyNote, kReadOnlyInCaleeNote);
      expect(capabilities.readOnlyNote, isNot(contains('Google')));
    });
  });

  group('read-only wording is truthful', () {
    test('Google says read-only in Calee and offers nothing further', () {
      final capabilities = resolveEventCapabilities(
        event: _event(
          calendarId: 'external:g',
          source: 'external',
          providerKey: 'google_calendar',
          readOnly: true,
        ),
        calendar: _calendar(
          id: 'external:g',
          source: 'external',
          readOnly: true,
          providerKey: 'google_calendar',
        ),
      );

      expect(capabilities.readOnlyNote, kGoogleReadOnlyNote);
      expect(capabilities.readOnlyNote, isNot(contains('Edit it in Google')));
    });

    test('a Google event on an unlabelled calendar is still recognised', () {
      final capabilities = resolveEventCapabilities(
        event: _event(
          calendarId: 'external:g',
          source: 'external',
          providerKey: 'google_calendar',
          readOnly: true,
        ),
        calendar: _calendar(id: 'external:g', source: 'external'),
      );

      expect(capabilities.readOnlyNote, kGoogleReadOnlyNote);
    });

    test('any other read-only source gets source-neutral wording', () {
      final capabilities = resolveEventCapabilities(
        event: _event(readOnly: true),
        calendar: _calendar(readOnly: true),
      );

      expect(capabilities.readOnlyNote, kReadOnlyInCaleeNote);
      expect(capabilities.readOnlyNote, isNot(contains('Google')));
    });

    test('no read-only note tells the user to change the event somewhere '
        'else', () {
      // Calee cannot know whether the person reading this may edit the source
      // calendar. Most people following a club fixture list or a school feed
      // cannot, so an instruction to "make changes in the original calendar"
      // is advice that fails for the majority of its readers.
      final notes = <String?>[
        resolveEventCapabilities(
          event: _event(readOnly: true),
          calendar: _calendar(readOnly: true),
        ).readOnlyNote,
        resolveEventCapabilities(event: _event(), calendar: null).readOnlyNote,
        resolveEventCapabilities(
          event: _event(
            calendarId: 'external:g',
            source: 'external',
            providerKey: 'google_calendar',
            readOnly: true,
          ),
          calendar: _calendar(
            id: 'external:g',
            source: 'external',
            readOnly: true,
            providerKey: 'google_calendar',
          ),
        ).readOnlyNote,
      ];

      for (final note in notes) {
        expect(note, isNotNull);
        expect(note, isNot(contains('original calendar')));
        expect(note, isNot(contains('must be made')));
        expect(note, isNot(contains('Edit it in')));
        expect(note, contains('read-only in Calee'));
      }
    });

    test('an unresolvable calendar and a known external source say the same '
        'source-neutral thing', () {
      expect(
        resolveEventCapabilities(event: _event(), calendar: null).readOnlyNote,
        resolveEventCapabilities(
          event: _event(readOnly: true),
          calendar: _calendar(readOnly: true),
        ).readOnlyNote,
      );
    });

    test('an editable event has no read-only note at all', () {
      expect(
        resolveEventCapabilities(
          event: _event(),
          calendar: _calendar(),
        ).readOnlyNote,
        isNull,
      );
    });
  });
}
