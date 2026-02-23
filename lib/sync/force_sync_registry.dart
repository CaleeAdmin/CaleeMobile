import 'dart:collection';

class ForceSyncRegistry {
  static final Set<int> _pendingForceSyncCollectionIds = HashSet<int>();

  static void requestForceSyncForCollection(int remoteCollectionId) {
    if (remoteCollectionId > 0) {
      _pendingForceSyncCollectionIds.add(remoteCollectionId);
    }
  }

  static bool consumeForceSyncForCollection(int remoteCollectionId) {
    if (remoteCollectionId <= 0) return false;
    return _pendingForceSyncCollectionIds.remove(remoteCollectionId);
  }
}
