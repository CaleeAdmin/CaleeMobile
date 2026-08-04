// The backend is authoritative for chore state. ChoreSyncOverlay exists only
// to bridge a list response that has not yet caught up with a mutation the
// backend already accepted — so these tests pin down exactly when it holds a
// row and, more importantly, when it must let go.

import 'package:calee_mobile/data/models/client_chore.dart';
import 'package:calee_mobile/features/chores/chore_sync_state.dart';
import 'package:flutter_test/flutter_test.dart';

// ── Builders ─────────────────────────────────────────────────────────────────

const _account = 'account-1';
const _household = 'household-1';
const _today = '2026-08-04';
const _from = '2026-07-05';
const _to = '2026-09-04';

ClientChore _chore({
  required bool completed,
  String uid = 'uid-1',
  String serviceId = 'portal',
  String calendarId = 'cal-1',
  String date = _today,
}) => ClientChore(
  id: completed ? '$serviceId:log-$uid-$date' : '$serviceId:$uid:$date',
  calendarId: calendarId,
  serviceId: serviceId,
  serviceName: 'Portal',
  title: 'Take out bins',
  scheduledAt: date,
  scheduledDate: date,
  description: null,
  source: 'nextcloud_portal',
  kind: completed ? 'completionLog' : 'baseChore',
  choreUid: uid,
  parentChoreUid: completed ? uid : null,
  baseChoreId: '$serviceId:$uid',
  occurrenceDate: date,
  completionLogId: completed ? '$serviceId:log-$uid-$date' : null,
  completedToday: completed,
  section: completed ? 'doneToday' : 'todoToday',
  recurrence: null,
  points: 1,
  metadataPoints: null,
  assigneePersonId: null,
  assigneeName: null,
  assigneeAvatarColor: null,
  approvalState: 'none',
);

ChoreOccurrenceKey _key(ClientChore chore) => ChoreOccurrenceKey.forChore(
  chore,
  accountId: _account,
  householdId: _household,
)!;

ChoreSyncReconciliation _reconcile(
  ChoreSyncOverlay overlay,
  List<ClientChore> chores, {
  DateTime? now,
}) => overlay.reconcile(
  chores: chores,
  accountId: _account,
  householdId: _household,
  fromDate: _from,
  toDate: _to,
  now: now ?? DateTime(2026, 8, 4, 12),
);

/// An overlay holding one accepted mutation, recorded at a fixed instant so
/// expiry can be driven by advancing `now` rather than by clearing state.
final _acceptedAt = DateTime(2026, 8, 4, 12);

ChoreSyncOverlay _overlayWith({required bool completing}) {
  final overlay = ChoreSyncOverlay();
  final accepted = _chore(completed: completing);
  if (completing) {
    overlay.markCompletionPending(
      key: _key(accepted),
      chore: accepted,
      now: _acceptedAt,
    );
  } else {
    overlay.markUndoPending(
      key: _key(accepted),
      chore: accepted,
      now: _acceptedAt,
    );
  }
  return overlay;
}

void main() {
  group('ChoreOccurrenceKey scoping', () {
    final base = _chore(completed: false);

    test('distinguishes service and occurrence date', () {
      final variants = {
        'other service': _chore(completed: false, serviceId: 'business'),
        'other date': _chore(completed: false, date: '2026-08-05'),
      };

      for (final entry in variants.entries) {
        expect(
          _key(entry.value),
          isNot(equals(_key(base))),
          reason: '${entry.key} must not share a key with the base occurrence',
        );
      }
    });

    test('ignores the calendar, which the backend id does not carry', () {
      // "serviceId:choreUid" has no calendar component, so the backend can
      // report one chore under a different calendar on the mutation response
      // and the following list. Keying on the calendar would strand the
      // overlay entry and replay a duplicate row.
      expect(
        _key(_chore(completed: false, calendarId: 'cal-2')),
        equals(_key(base)),
      );
    });

    test('is null without a stable completion action id', () {
      expect(
        ChoreOccurrenceKey.forChore(
          ClientChore.fromJson(const {'id': '', 'kind': 'completionLog'}),
          accountId: _account,
          householdId: _household,
        ),
        isNull,
      );
    });
  });

  group('ChoreSyncOverlay.reconcile', () {
    // The backend reported the occurrence, and it matches what the mutation
    // asked for: nothing left to bridge.
    test('backend confirming the mutation drops the overlay', () {
      for (final completing in [true, false]) {
        final overlay = _overlayWith(completing: completing);
        final backendRow = _chore(completed: completing);

        final result = _reconcile(overlay, [backendRow]);

        expect(overlay.pendingCount, 0, reason: 'completing=$completing');
        expect(result.chores, [backendRow]);
        expect(result.warning, isNull);
      }
    });

    // One service can hold the same UID in two calendars. The backend resolves
    // that to a single id but may report it under either calendar, so a row
    // whose calendar differs from the accepted mutation's is still the same
    // occurrence — not an omission to paper over with a duplicate.
    test(
      'backend reporting a different calendar still resolves the overlay',
      () {
        final overlay = _overlayWith(completing: true);
        final backendRow = _chore(completed: true, calendarId: 'cal-2');

        final result = _reconcile(overlay, [backendRow]);

        expect(overlay.pendingCount, 0);
        expect(result.chores, [backendRow]);
        expect(result.warning, isNull);
      },
    );

    // The occurrence is missing from this response only. This is the single
    // case the overlay exists for.
    test('backend omitting the occurrence replays the accepted row', () {
      for (final completing in [true, false]) {
        final overlay = _overlayWith(completing: completing);

        final result = _reconcile(overlay, const []);

        expect(overlay.pendingCount, 1, reason: 'completing=$completing');
        expect(result.chores, hasLength(1));
        expect(result.chores.single.isCompleted, completing);
        expect(result.warning, isNull);
      }
    });

    // The regression this file was rewritten for: the overlay used to suppress
    // the backend row and keep showing the local one for the whole window.
    test('backend contradicting the mutation wins immediately', () {
      for (final completing in [true, false]) {
        final overlay = _overlayWith(completing: completing);
        final contradiction = _chore(completed: !completing);

        final result = _reconcile(overlay, [contradiction]);

        expect(
          overlay.pendingCount,
          0,
          reason:
              'completing=$completing: the overlay must not survive a '
              'contradiction, not even briefly',
        );
        expect(
          result.chores,
          [contradiction],
          reason: 'the backend row must be used verbatim, not suppressed',
        );
        expect(result.warning, isNotNull);
      }
    });

    test('a contradicted mutation cannot reappear on a later refresh', () {
      final overlay = _overlayWith(completing: true);
      final active = _chore(completed: false);

      _reconcile(overlay, [active]);

      // The backend now omits it entirely. Without the entry there is nothing
      // to replay, so the stale completed row must stay gone.
      final later = _reconcile(overlay, const []);

      expect(overlay.pendingCount, 0);
      expect(later.chores, isEmpty);
      expect(later.warning, isNull);
    });

    test('an omitted mutation expires once the window elapses', () {
      final overlay = _overlayWith(completing: true);
      final window = overlay.omissionWindow;

      // Still inside the window: held.
      final held = _reconcile(
        overlay,
        const [],
        now: _acceptedAt.add(window - const Duration(seconds: 1)),
      );
      expect(held.chores, hasLength(1));
      expect(overlay.pendingCount, 1);

      // Past the window: dropped, and the user is told.
      final lapsed = _reconcile(
        overlay,
        const [],
        now: _acceptedAt.add(window + const Duration(seconds: 1)),
      );
      expect(overlay.pendingCount, 0);
      expect(lapsed.chores, isEmpty);
      expect(lapsed.warning, isNotNull);
    });

    test(
      'an occurrence outside the loaded range is dropped without warning',
      () {
        final overlay = ChoreSyncOverlay();
        final outOfRange = _chore(completed: true, date: '2020-01-01');
        overlay.markCompletionPending(
          key: _key(outOfRange),
          chore: outOfRange,
          now: _acceptedAt,
        );

        final result = _reconcile(overlay, const []);

        expect(overlay.pendingCount, 0);
        expect(result.chores, isEmpty);
        expect(result.warning, isNull);
      },
    );

    test('a mutation in one service leaves another service untouched', () {
      final overlay = _overlayWith(completing: true);
      final otherService = _chore(completed: false, serviceId: 'business');

      final result = _reconcile(overlay, [otherService]);

      expect(
        overlay.pendingCount,
        1,
        reason: 'the other service says nothing about this occurrence',
      );
      expect(result.chores, hasLength(2));
      expect(result.warning, isNull);
    });
  });

  group('ChoreSyncOverlay.retainScope', () {
    ChoreSyncOverlay pending() => _overlayWith(completing: true);

    void retain(
      ChoreSyncOverlay overlay, {
      String account = _account,
      String household = _household,
      Set<String> services = const {'portal'},
      bool servicesAuthoritative = true,
      Set<String> calendars = const {'cal-1'},
      bool calendarsAuthoritative = true,
    }) => overlay.retainScope(
      accountId: account,
      householdId: household,
      serviceIds: services,
      servicesAuthoritative: servicesAuthoritative,
      calendarIds: calendars,
      calendarsAuthoritative: calendarsAuthoritative,
    );

    test('an unchanged authoritative scope keeps the entry', () {
      final overlay = pending();
      retain(overlay);
      expect(overlay.pendingCount, 1);
    });

    // The empty-authoritative-set case: "there are none left" must clear
    // pending state, and used to be indistinguishable from "lookup failed".
    test('removing the last service clears service-scoped entries', () {
      final overlay = pending();
      retain(overlay, services: const {});
      expect(overlay.pendingCount, 0);
    });

    test('removing the last calendar clears calendar-scoped entries', () {
      final overlay = pending();
      retain(overlay, calendars: const {});
      expect(overlay.pendingCount, 0);
    });

    test('a removed service clears its entries', () {
      final overlay = pending();
      retain(overlay, services: const {'business'});
      expect(overlay.pendingCount, 0);
    });

    test('a removed calendar clears its entries', () {
      final overlay = pending();
      retain(overlay, calendars: const {'cal-99'});
      expect(overlay.pendingCount, 0);
    });

    // Failed enumeration is not evidence of deletion.
    test('a failed calendar request does not clear entries', () {
      final overlay = pending();
      retain(overlay, calendars: const {}, calendarsAuthoritative: false);
      expect(overlay.pendingCount, 1);
    });

    test('unavailable service enumeration does not clear entries', () {
      final overlay = pending();
      retain(overlay, services: const {}, servicesAuthoritative: false);
      expect(overlay.pendingCount, 1);
    });

    test('an account switch always clears', () {
      final overlay = pending();
      retain(overlay, account: 'account-2');
      expect(overlay.pendingCount, 0);
    });

    test('a household switch always clears', () {
      final overlay = pending();
      retain(overlay, household: 'household-2');
      expect(overlay.pendingCount, 0);
    });

    test('clear() drops everything', () {
      final overlay = pending();
      overlay.clear();
      expect(overlay.pendingCount, 0);
    });
  });
}
