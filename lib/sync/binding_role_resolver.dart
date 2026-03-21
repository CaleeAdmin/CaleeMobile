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
}
