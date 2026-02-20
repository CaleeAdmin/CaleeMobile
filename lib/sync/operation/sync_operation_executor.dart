import 'sync_operation.dart';

typedef OperationCallback = Future<bool> Function();

class SyncOperationExecutor {
  const SyncOperationExecutor();

  Future<bool> execute({
    required PlannedItemOperation plan,
    OperationCallback? onLocalCreate,
    OperationCallback? onLocalUpdate,
    OperationCallback? onLocalDelete,
    OperationCallback? onRemoteCreate,
    OperationCallback? onRemoteUpdate,
    OperationCallback? onRemoteDelete,
    OperationCallback? onMappingUpsert,
    OperationCallback? onMappingDelete,
    OperationCallback? onMarkSynced,
  }) async {
    final bool primaryDone = await _runPrimary(
      plan.operation,
      onLocalCreate: onLocalCreate,
      onLocalUpdate: onLocalUpdate,
      onLocalDelete: onLocalDelete,
      onRemoteCreate: onRemoteCreate,
      onRemoteUpdate: onRemoteUpdate,
      onRemoteDelete: onRemoteDelete,
    );

    if (!primaryDone) {
      return false;
    }

    for (final tracking in plan.tracking) {
      final bool ok = switch (tracking) {
        TrackingOperation.mappingUpsert =>
          await (onMappingUpsert?.call() ?? Future.value(true)),
        TrackingOperation.mappingDelete =>
          await (onMappingDelete?.call() ?? Future.value(true)),
        TrackingOperation.markSynced =>
          await (onMarkSynced?.call() ?? Future.value(true)),
      };
      if (!ok) {
        return false;
      }
    }

    return true;
  }

  Future<bool> _runPrimary(
    CanonicalSyncOperation operation, {
    OperationCallback? onLocalCreate,
    OperationCallback? onLocalUpdate,
    OperationCallback? onLocalDelete,
    OperationCallback? onRemoteCreate,
    OperationCallback? onRemoteUpdate,
    OperationCallback? onRemoteDelete,
  }) async {
    return switch (operation) {
      CanonicalSyncOperation.localCreate =>
        await (onLocalCreate?.call() ?? Future.value(false)),
      CanonicalSyncOperation.localUpdate =>
        await (onLocalUpdate?.call() ?? Future.value(false)),
      CanonicalSyncOperation.localDelete =>
        await (onLocalDelete?.call() ?? Future.value(false)),
      CanonicalSyncOperation.remoteCreate =>
        await (onRemoteCreate?.call() ?? Future.value(false)),
      CanonicalSyncOperation.remoteUpdate =>
        await (onRemoteUpdate?.call() ?? Future.value(false)),
      CanonicalSyncOperation.remoteDelete =>
        await (onRemoteDelete?.call() ?? Future.value(false)),
      CanonicalSyncOperation.skip => true,
    };
  }
}
