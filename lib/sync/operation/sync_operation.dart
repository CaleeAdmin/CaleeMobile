enum CanonicalSyncOperation {
  localCreate,
  localUpdate,
  localDelete,
  remoteCreate,
  remoteUpdate,
  remoteDelete,
  skip,
}

enum TrackingOperation {
  mappingUpsert,
  mappingDelete,
  markSynced,
}

enum SyncReconcileMode {
  pull,
  push,
  bidi,
}

class PlannedItemOperation {
  PlannedItemOperation({
    required this.uid,
    required this.operation,
    required this.reason,
    this.tracking = const [],
  });

  final String uid;
  final CanonicalSyncOperation operation;
  final String reason;
  final List<TrackingOperation> tracking;
}
