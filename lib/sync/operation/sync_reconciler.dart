import '../SyncEnum.dart';
import 'sync_operation.dart';

class SyncReconciler {
  const SyncReconciler();

  PlannedItemOperation plan({
    required String uid,
    required SyncReconcileMode mode,
    required bool remoteExists,
    required bool localExists,
    required bool remoteChanged,
    required bool localChanged,
    required bool hasMapping,
    required int bindingOrigin,
    required int deletionPolicy,
  }) {
    if (!remoteExists && !localExists) {
      return PlannedItemOperation(
        uid: uid,
        operation: CanonicalSyncOperation.skip,
        reason: 'both_missing',
      );
    }

    if (remoteExists && !localExists) {
      if (mode == SyncReconcileMode.push) {
        if (!hasMapping) {
          return PlannedItemOperation(
            uid: uid,
            operation: CanonicalSyncOperation.skip,
            reason: 'push_mode_ignores_unmapped_remote_only_item',
          );
        }
        return PlannedItemOperation(
          uid: uid,
          operation: CanonicalSyncOperation.remoteDelete,
          reason: 'push_mode_local_missing',
          tracking: const [TrackingOperation.mappingDelete],
        );
      }
      return PlannedItemOperation(
        uid: uid,
        operation: CanonicalSyncOperation.localCreate,
        reason: 'remote_exists_local_missing',
        tracking: const [TrackingOperation.mappingUpsert],
      );
    }

    if (!remoteExists && localExists) {
      if (mode == SyncReconcileMode.pull) {
        return PlannedItemOperation(
          uid: uid,
          operation: CanonicalSyncOperation.localDelete,
          reason: 'remote_missing',
          tracking: const [TrackingOperation.mappingDelete],
        );
      }

      if (mode == SyncReconcileMode.push) {
        return PlannedItemOperation(
          uid: uid,
          operation: hasMapping
              ? CanonicalSyncOperation.remoteUpdate
              : CanonicalSyncOperation.remoteCreate,
          reason: hasMapping
              ? 'push_mode_recreate_remote_missing_mapped_item'
              : 'push_mode_create_remote_for_local_item',
          tracking: const [TrackingOperation.mappingUpsert],
        );
      }

      if (deletionPolicy == SyncDeletionPolicy.remoteDeleteWins) {
        return PlannedItemOperation(
          uid: uid,
          operation: CanonicalSyncOperation.localDelete,
          reason: 'remote_delete_wins',
          tracking: const [TrackingOperation.mappingDelete],
        );
      }

      return PlannedItemOperation(
        uid: uid,
        operation: CanonicalSyncOperation.remoteDelete,
        reason: 'local_delete_wins',
        tracking: const [TrackingOperation.mappingDelete],
      );
    }

    final bool noChanges = !remoteChanged && !localChanged;
    if (noChanges) {
      return PlannedItemOperation(
        uid: uid,
        operation: CanonicalSyncOperation.skip,
        reason: 'no_change',
        tracking: const [TrackingOperation.markSynced],
      );
    }

    final _Winner winner = _resolveWinner(
      mode: mode,
      remoteChanged: remoteChanged,
      localChanged: localChanged,
      bindingOrigin: bindingOrigin,
    );

    if (winner == _Winner.remote) {
      return PlannedItemOperation(
        uid: uid,
        operation: CanonicalSyncOperation.localUpdate,
        reason: _reasonForWinner(remoteChanged, localChanged, winner, bindingOrigin),
        tracking: const [TrackingOperation.mappingUpsert],
      );
    }

    return PlannedItemOperation(
      uid: uid,
      operation: hasMapping
          ? CanonicalSyncOperation.remoteUpdate
          : CanonicalSyncOperation.remoteCreate,
      reason: _reasonForWinner(remoteChanged, localChanged, winner, bindingOrigin),
      tracking: const [TrackingOperation.mappingUpsert],
    );
  }

  _Winner _resolveWinner({
    required SyncReconcileMode mode,
    required bool remoteChanged,
    required bool localChanged,
    required int bindingOrigin,
  }) {
    if (mode == SyncReconcileMode.pull) {
      return _Winner.remote;
    }
    if (mode == SyncReconcileMode.push) {
      return _Winner.local;
    }

    if (remoteChanged && !localChanged) {
      return _Winner.remote;
    }
    if (!remoteChanged && localChanged) {
      return _Winner.local;
    }

    return bindingOrigin == SyncBindingOrigin.local
        ? _Winner.local
        : _Winner.remote;
  }

  String _reasonForWinner(
    bool remoteChanged,
    bool localChanged,
    _Winner winner,
    int bindingOrigin,
  ) {
    if (remoteChanged && !localChanged) {
      return winner == _Winner.remote
          ? 'remote_changed'
          : 'remote_changed_local_wins';
    }
    if (!remoteChanged && localChanged) {
      return winner == _Winner.local
          ? 'local_changed'
          : 'local_changed_remote_wins';
    }
    return bindingOrigin == SyncBindingOrigin.local
        ? 'conflict_local_origin_wins'
        : 'conflict_remote_origin_wins';
  }
}

enum _Winner { remote, local }
