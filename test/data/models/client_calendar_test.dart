// Unit tests for CalendarCapabilities and the ClientCalendar constructor
// defaults for appearanceMode/capabilities. JSON round-trip coverage for
// ClientCalendar.fromJson (including the old-server fallback) lives in
// test/data/api/calee_hub_client_calendar_test.dart, exercised through
// CaleeHubClient.updateCalendarAppearance()'s response parsing.

import 'package:calee_mobile/data/models/client_calendar.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('CalendarCapabilities.fromJson', () {
    test('parses all fields when present', () {
      final capabilities = CalendarCapabilities.fromJson({
        'canEditAppearance': true,
        'canEditEvents': true,
        'canEditSourceMetadata': true,
        'canRemoveFromCalee': false,
        'canDeleteSource': true,
      });

      expect(capabilities.canEditAppearance, isTrue);
      expect(capabilities.canEditEvents, isTrue);
      expect(capabilities.canEditSourceMetadata, isTrue);
      expect(capabilities.canRemoveFromCalee, isFalse);
      expect(capabilities.canDeleteSource, isTrue);
    });

    test('defaults every field to false when the map is empty', () {
      final capabilities = CalendarCapabilities.fromJson(const {});

      expect(capabilities.canEditAppearance, isFalse);
      expect(capabilities.canEditEvents, isFalse);
      expect(capabilities.canEditSourceMetadata, isFalse);
      expect(capabilities.canRemoveFromCalee, isFalse);
      expect(capabilities.canDeleteSource, isFalse);
    });
  });

  group('CalendarCapabilities.fallback', () {
    test('writable, non-subscription calendar can edit appearance only', () {
      final capabilities = CalendarCapabilities.fallback(
        readOnly: false,
        isSubscription: false,
      );

      expect(capabilities.canEditAppearance, isTrue);
      expect(capabilities.canEditEvents, isFalse);
      expect(capabilities.canEditSourceMetadata, isFalse);
      expect(capabilities.canRemoveFromCalee, isFalse);
      expect(capabilities.canDeleteSource, isFalse);
    });

    test('read-only calendar cannot edit appearance', () {
      final capabilities = CalendarCapabilities.fallback(
        readOnly: true,
        isSubscription: false,
      );

      expect(capabilities.canEditAppearance, isFalse);
    });

    test(
      'subscription calendar cannot edit appearance even if not read-only',
      () {
        final capabilities = CalendarCapabilities.fallback(
          readOnly: false,
          isSubscription: true,
        );

        expect(capabilities.canEditAppearance, isFalse);
      },
    );

    test('read-only subscription cannot edit appearance', () {
      final capabilities = CalendarCapabilities.fallback(
        readOnly: true,
        isSubscription: true,
      );

      expect(capabilities.canEditAppearance, isFalse);
    });

    test(
      'every non-appearance capability fails closed regardless of inputs',
      () {
        for (final readOnly in [true, false]) {
          for (final isSubscription in [true, false]) {
            final capabilities = CalendarCapabilities.fallback(
              readOnly: readOnly,
              isSubscription: isSubscription,
            );
            expect(capabilities.canEditEvents, isFalse);
            expect(capabilities.canEditSourceMetadata, isFalse);
            expect(capabilities.canRemoveFromCalee, isFalse);
            expect(capabilities.canDeleteSource, isFalse);
          }
        }
      },
    );
  });

  group('ClientCalendar direct construction (no fromJson)', () {
    // Mirrors the plain-constructor fixture style used throughout this
    // test suite (e.g. test/features/settings/calendar_collections_business_ux_test.dart),
    // confirming the class stays const-constructible and that omitting the
    // new fields doesn't crash or require call-site changes.
    const calendar = ClientCalendar(
      id: 'cal1',
      serviceId: 'svc1',
      serviceName: 'Service',
      name: 'Family',
      components: [],
      primaryKind: 'calendar',
      supportsEvents: true,
      supportsTasks: false,
      supportsChores: false,
      readOnly: false,
      isSubscription: false,
      source: 'calee',
    );

    test('appearanceMode defaults to source_metadata', () {
      expect(calendar.appearanceMode, 'source_metadata');
    });

    test('capabilities defaults to appearance-editable', () {
      expect(calendar.capabilities.canEditAppearance, isTrue);
    });

    test('sourceName/sourceColor default to null', () {
      expect(calendar.sourceName, isNull);
      expect(calendar.sourceColor, isNull);
    });

    test('explicit capabilities/appearanceMode override the defaults', () {
      const overridden = ClientCalendar(
        id: 'cal2',
        serviceId: 'svc1',
        serviceName: 'Service',
        name: 'Shared',
        components: [],
        primaryKind: 'calendar',
        supportsEvents: true,
        supportsTasks: false,
        supportsChores: false,
        readOnly: true,
        isSubscription: false,
        source: 'calee',
        appearanceMode: 'unsupported',
        capabilities: CalendarCapabilities(
          canEditAppearance: false,
          canEditEvents: false,
          canEditSourceMetadata: false,
          canRemoveFromCalee: true,
          canDeleteSource: false,
        ),
      );

      expect(overridden.appearanceMode, 'unsupported');
      expect(overridden.capabilities.canEditAppearance, isFalse);
      expect(overridden.capabilities.canRemoveFromCalee, isTrue);
    });
  });
}
