// Unit tests: the five-calendar Guest/local allowance enforced in the
// domain/repository layer.
//
// The allowance is a property of LocalCalendarSubscriptionRepository.add(),
// not of any screen, so every calendar-follow ingress path inherits the same
// behaviour. These tests pin the required ordering — normalize, load,
// de-duplicate, *then* measure a genuinely new calendar against the limit —
// and the non-destructive guarantee that a rejected sixth attempt leaves the
// stored five exactly as they were.

import 'package:calee_mobile/features/local_subscriber/local_calendar_subscription_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

String _url(int n) => 'https://example.com/cal$n.ics';

/// Fills [repo] to the allowance with distinct calendars.
Future<void> _fillToLimit(LocalCalendarSubscriptionRepository repo) async {
  for (var i = 1; i <= kMaxLocalCalendarSubscriptions; i++) {
    await repo.add(title: 'Calendar $i', url: _url(i), source: 'test');
  }
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('LocalCalendarSubscriptionRepository — local allowance', () {
    test('the allowance is five calendars', () {
      expect(kMaxLocalCalendarSubscriptions, 5);
    });

    test('adds five unique calendars successfully', () async {
      final repo = LocalCalendarSubscriptionRepository();

      for (var i = 1; i <= 5; i++) {
        final added = await repo.add(
          title: 'Calendar $i',
          url: _url(i),
          source: 'test',
        );
        expect(added.url, _url(i));
        expect((await repo.list()).length, i);
      }

      final all = await repo.list();
      expect(all.map((s) => s.url), [
        _url(1),
        _url(2),
        _url(3),
        _url(4),
        _url(5),
      ]);
    });

    test(
      'a sixth unique calendar is rejected with the typed limit condition and '
      'changes nothing',
      () async {
        final repo = LocalCalendarSubscriptionRepository();
        await _fillToLimit(repo);
        final before = await repo.list();

        await expectLater(
          repo.add(
            title: 'Sixth Calendar',
            url: _url(6),
            source: 'sixth.example.com',
          ),
          throwsA(isA<LocalCalendarSubscriptionLimitException>()),
        );

        // Non-destructive: the existing five are untouched — same URLs, same
        // ids, same order — and the sixth was never stored.
        final after = await repo.list();
        expect(after.length, 5);
        expect(after.map((s) => s.url), before.map((s) => s.url));
        expect(after.map((s) => s.id), before.map((s) => s.id));
        expect(await repo.containsUrl(_url(6)), isFalse);
      },
    );

    test('the typed limit condition carries the attempted calendar', () async {
      final repo = LocalCalendarSubscriptionRepository();
      await _fillToLimit(repo);

      try {
        await repo.add(
          title: '  Sixth Calendar  ',
          url: 'webcal://example.com/cal6.ics',
          source: 'sixth.example.com',
        );
        fail('expected LocalCalendarSubscriptionLimitException');
      } on LocalCalendarSubscriptionLimitException catch (e) {
        // Context the conversion screen needs, with the URL already
        // normalized and the title trimmed.
        expect(e.attemptedTitle, 'Sixth Calendar');
        expect(e.attemptedUrl, _url(6));
        expect(e.currentCount, 5);
        expect(e.limit, kMaxLocalCalendarSubscriptions);
        expect(e.toString(), contains('Sixth Calendar'));
      }
    });

    test(
      'the limit condition is distinguishable from other repository failures',
      () async {
        final repo = LocalCalendarSubscriptionRepository();
        await _fillToLimit(repo);

        Object? caught;
        try {
          await repo.add(title: 'Sixth', url: _url(6), source: 'test');
        } catch (e) {
          caught = e;
        }

        // Its own type — a `catch` on the limit never swallows a genuine
        // storage/parser/network failure, and vice versa.
        expect(caught, isA<LocalCalendarSubscriptionLimitException>());
        expect(caught, isNot(isA<StateError>()));
        expect(caught, isNot(isA<FormatException>()));
        expect(caught, isA<Exception>());
      },
    );

    test('reopening an already-followed calendar at the limit returns the '
        'existing subscription instead of the limit condition', () async {
      final repo = LocalCalendarSubscriptionRepository();
      await _fillToLimit(repo);
      final existing = (await repo.list()).firstWhere((s) => s.url == _url(3));

      // Duplicate detection runs before the limit check, so a full
      // allowance can never block a calendar the user already follows.
      final reopened = await repo.add(
        title: 'Calendar 3 renamed',
        url: _url(3),
        source: 'test',
      );

      expect(reopened.id, existing.id);
      expect(reopened.url, _url(3));
      // Idempotent: still five, and the stored title was not overwritten.
      final all = await repo.list();
      expect(all.length, 5);
      expect(all.firstWhere((s) => s.url == _url(3)).title, 'Calendar 3');
    });

    test(
      'a webcal:// form of an already-followed calendar de-duplicates at the '
      'limit rather than being rejected',
      () async {
        final repo = LocalCalendarSubscriptionRepository();
        await _fillToLimit(repo);

        final reopened = await repo.add(
          title: 'Calendar 2',
          url: 'webcal://example.com/cal2.ics',
          source: 'test',
        );

        expect(reopened.url, _url(2));
        expect((await repo.list()).length, 5);
      },
    );

    test('webcal:// and https:// forms of a new calendar consume one slot, not '
        'two', () async {
      final repo = LocalCalendarSubscriptionRepository();
      for (var i = 1; i <= 4; i++) {
        await repo.add(title: 'Calendar $i', url: _url(i), source: 'test');
      }

      await repo.add(
        title: 'Fifth',
        url: 'webcal://example.com/cal5.ics',
        source: 'test',
      );
      await repo.add(title: 'Fifth again', url: _url(5), source: 'test');

      final all = await repo.list();
      expect(all.length, 5);
      expect(all.last.url, _url(5));

      // Only now is the allowance actually full.
      await expectLater(
        repo.add(title: 'Sixth', url: _url(6), source: 'test'),
        throwsA(isA<LocalCalendarSubscriptionLimitException>()),
      );
    });

    test(
      'removing a calendar at the limit restores capacity for another',
      () async {
        final repo = LocalCalendarSubscriptionRepository();
        await _fillToLimit(repo);
        await expectLater(
          repo.add(title: 'Sixth', url: _url(6), source: 'test'),
          throwsA(isA<LocalCalendarSubscriptionLimitException>()),
        );

        final removed = (await repo.list()).firstWhere((s) => s.url == _url(2));
        await repo.remove(removed.id);
        expect((await repo.list()).length, 4);

        final added = await repo.add(
          title: 'Sixth',
          url: _url(6),
          source: 'test',
        );

        expect(added.url, _url(6));
        final all = await repo.list();
        expect(all.length, 5);
        expect(all.map((s) => s.url), contains(_url(6)));
        expect(all.map((s) => s.url), isNot(contains(_url(2))));
      },
    );

    test(
      'the limit persists across repository instances over the same storage',
      () async {
        await _fillToLimit(LocalCalendarSubscriptionRepository());

        // A fresh instance reads the same shared preferences, so the
        // allowance is a property of the installation, not of one object.
        final other = LocalCalendarSubscriptionRepository();
        expect((await other.list()).length, 5);
        await expectLater(
          other.add(title: 'Sixth', url: _url(6), source: 'test'),
          throwsA(isA<LocalCalendarSubscriptionLimitException>()),
        );
      },
    );
  });
}
