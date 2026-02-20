import '../../core/platform/pigeon/calendar_api.g.dart';
import 'store_adapters.dart';
import 'sync_operation.dart';

class UnifiedStoreExecutionResult {
  final bool success;
  final AdapterMutationResult? mutation;

  const UnifiedStoreExecutionResult({
    required this.success,
    this.mutation,
  });
}

class UnifiedStoreExecutor {
  UnifiedStoreExecutor({
    required this.localAdapter,
    required this.remoteAdapter,
  });

  final LocalStoreAdapter localAdapter;
  final RemoteStoreAdapter remoteAdapter;

  Future<UnifiedStoreExecutionResult> execute({
    required CanonicalSyncOperation operation,
    required String uid,
    Map<String, dynamic>? remote,
    PlatformItem? local,
    Map<String, dynamic>? mapping,
    required String remoteToken,
    bool allowDelete = true,
  }) async {
    switch (operation) {
      case CanonicalSyncOperation.localCreate:
      case CanonicalSyncOperation.localUpdate:
        return _applyRemoteToLocal(
          uid: uid,
          remote: remote,
          mapping: mapping,
          remoteToken: remoteToken,
          isCreate: operation == CanonicalSyncOperation.localCreate,
        );
      case CanonicalSyncOperation.remoteCreate:
      case CanonicalSyncOperation.remoteUpdate:
        return _applyLocalToRemote(
          uid: uid,
          local: local,
          isCreate: operation == CanonicalSyncOperation.remoteCreate,
        );
      case CanonicalSyncOperation.localDelete:
        if (!allowDelete) return const UnifiedStoreExecutionResult(success: false);
        final String localId =
            mapping?['local_item_id']?.toString() ?? local?.localId?.toString() ?? '';
        if (localId.isEmpty) return const UnifiedStoreExecutionResult(success: true);
        final bool deleted = await localAdapter.delete(localId);
        return UnifiedStoreExecutionResult(success: deleted);
      case CanonicalSyncOperation.remoteDelete:
        if (!allowDelete) return const UnifiedStoreExecutionResult(success: false);
        final String href =
            mapping?['remote_href']?.toString() ?? remote?['href']?.toString() ?? '';
        if (href.isEmpty) return const UnifiedStoreExecutionResult(success: true);
        final bool deleted = await remoteAdapter.delete(href);
        return UnifiedStoreExecutionResult(success: deleted);
      case CanonicalSyncOperation.skip:
        return const UnifiedStoreExecutionResult(success: true);
    }
  }

  Future<UnifiedStoreExecutionResult> _applyRemoteToLocal({
    required String uid,
    required Map<String, dynamic>? remote,
    required Map<String, dynamic>? mapping,
    required String remoteToken,
    required bool isCreate,
  }) async {
    if (remote == null) return const UnifiedStoreExecutionResult(success: false);

    final payload = {
      'uid': uid,
      'title': remote['summary']?.toString() ?? 'Untitled',
      'notes': remote['description']?.toString(),
      'startTime': (remote['dtstart'] as int?) ?? 0,
      'endTime': (remote['dtend'] as int?) ?? 0,
      'localId': mapping?['local_item_id']?.toString(),
    };

    final AdapterMutationResult? result = isCreate
        ? await localAdapter.create(payload)
        : await localAdapter.update(payload, remoteToken);

    if (result == null || (result.localId ?? '').isEmpty) {
      return const UnifiedStoreExecutionResult(success: false);
    }
    return UnifiedStoreExecutionResult(success: true, mutation: result);
  }

  Future<UnifiedStoreExecutionResult> _applyLocalToRemote({
    required String uid,
    required PlatformItem? local,
    required bool isCreate,
  }) async {
    if (local == null) return const UnifiedStoreExecutionResult(success: false);

    final String? localId = local.localId;
    if (localId == null || localId.isEmpty) {
      return const UnifiedStoreExecutionResult(success: false);
    }

    final payload = {
      'uid': uid,
      'title': local.title ?? 'Untitled',
      'startTime': local.startTime ?? 0,
      'endTime': local.endTime ?? 0,
      'localId': localId,
    };

    final AdapterMutationResult? result = isCreate
        ? await remoteAdapter.create(payload)
        : await remoteAdapter.update(payload, (local.lastModified ?? 0).toString());

    if (result == null || (result.token ?? '').isEmpty || (result.remoteHref ?? '').isEmpty) {
      return const UnifiedStoreExecutionResult(success: false);
    }

    return UnifiedStoreExecutionResult(success: true, mutation: result);
  }
}
