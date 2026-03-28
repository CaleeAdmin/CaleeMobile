import 'package:uuid/uuid.dart';

class CaleeUid {
  static const _uuid = Uuid();
  static const int _maxRemoteUidLength = 255;
  static final RegExp _safeUidPattern = RegExp(r'^[A-Za-z0-9._@-]{1,255}$');
  static final RegExp _uuidPattern = RegExp(
    r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$',
  );

  /// 生成符合 CalDAV 标准的 UUID
  /// 例如: AE6C35CC-3203-44D8-A56C-973D48D7E289
  static String generate() {
    return _uuid.v4().toUpperCase();
  }

  static bool needsRemoteRepair(String? uid) {
    final String candidate = (uid ?? '').trim();
    if (candidate.isEmpty) return true;
    if (candidate.length > _maxRemoteUidLength) return true;
    return !_safeUidPattern.hasMatch(candidate);
  }

  static String normalizeForRemoteWrite(String? uid) {
    final String candidate = (uid ?? '').trim();
    if (!needsRemoteRepair(candidate)) {
      return candidate;
    }
    return buildDeterministicRepairedUid(candidate);
  }

  static String buildDeterministicRepairedUid(String rawUid) {
    final String seed = rawUid.trim().isEmpty ? '<EMPTY_UID>' : rawUid;
    final String deterministicUuid = _uuid.v5(Uuid.NAMESPACE_URL, seed).toUpperCase();
    if (_uuidPattern.hasMatch(seed)) {
      return seed.toUpperCase();
    }
    return 'CALEE-REPAIRED-$deterministicUuid';
  }
}
