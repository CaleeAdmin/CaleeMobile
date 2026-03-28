import 'UidGenerator.dart';

class CaleeUidSanitizer {
  static final RegExp _safeTokenRegex = RegExp(r'^[A-Za-z0-9._@-]+$');

  static bool isSafeForRemotePut(String? uid) {
    final String trimmed = (uid ?? '').trim();
    if (trimmed.isEmpty) return false;
    if (trimmed.length > 190) return false;
    if (trimmed.contains('\r') || trimmed.contains('\n')) return false;

    final String upper = trimmed.toUpperCase();
    if (upper.startsWith('BEGIN:') || upper.startsWith('END:') || upper.startsWith('UID:')) {
      return false;
    }

    if (trimmed.contains(';') || trimmed.contains(':')) return false;

    return _safeTokenRegex.hasMatch(trimmed);
  }

  static String normalizeForRemotePut(String? uid, {String? fallbackUid}) {
    final String trimmed = (uid ?? '').trim();
    if (isSafeForRemotePut(trimmed)) return trimmed;

    final String fallbackTrimmed = (fallbackUid ?? '').trim();
    if (isSafeForRemotePut(fallbackTrimmed)) return fallbackTrimmed;

    return CaleeUid.generate();
  }
}
