import 'SyncEnum.dart';

class BindingRoleResolver {
  static int resolveBindingRole(Map<String, dynamic> row) {
    final Object? rawValue = row['binding_role'];
    if (rawValue is int) return rawValue;
    if (rawValue is String) {
      return int.tryParse(rawValue) ?? SyncBindingRole.mirror;
    }
    return SyncBindingRole.mirror;
  }

  static bool hasUsableBinding(Map<String, dynamic> row) {
    final int bindingId = row['binding_id'] is int
        ? row['binding_id'] as int
        : int.tryParse(row['binding_id']?.toString() ?? '') ?? 0;
    final String localCollectionId = row['local_collection_id']?.toString() ?? '';
    return bindingId > 0 && localCollectionId.isNotEmpty;
  }

  static bool isMirror(Map<String, dynamic> row) {
    return resolveBindingRole(row) == SyncBindingRole.mirror;
  }

  static bool isOwnerLink(Map<String, dynamic> row) {
    return resolveBindingRole(row) == SyncBindingRole.ownerLink;
  }
}
