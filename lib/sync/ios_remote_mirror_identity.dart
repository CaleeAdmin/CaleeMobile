import 'dart:convert';

import '../core/platform/pigeon/calendar_api.g.dart';
import '../services/calee_server_service.dart';

class IosRemoteMirrorIdentity {
  IosRemoteMirrorIdentity._();

  static const String _titlePrefix = 'Calee - ';

  static String markerForRemotePath(String remotePath) {
    final String normalizedPath = CaleeServerService.normalizeRemotePath(remotePath);
    final int hash = _fnv1a32(utf8.encode(normalizedPath));
    return hash.toRadixString(16).padLeft(8, '0').toUpperCase();
  }

  static String expectedTitle(String displayName, String remotePath) {
    final String normalizedName = displayName.trim().isEmpty ? 'Untitled calendar' : displayName.trim();
    return '$_titlePrefix$normalizedName [${markerForRemotePath(remotePath)}]';
  }

  static bool isExactMatch(PlatformCalendar calendar, String displayName, String remotePath) {
    return (calendar.name ?? '').trim() == expectedTitle(displayName, remotePath);
  }

  static bool isLooseCaleeCandidate(PlatformCalendar calendar, String displayName) {
    final String title = (calendar.name ?? '').trim().toLowerCase();
    final String normalizedName = displayName.trim().toLowerCase();
    if (title.isEmpty) return false;
    if (title.startsWith(_titlePrefix.toLowerCase())) return true;
    if (normalizedName.isEmpty) return false;
    return title.contains('calee') && title.contains(normalizedName);
  }

  static int _fnv1a32(List<int> bytes) {
    int hash = 0x811C9DC5;
    for (final int byte in bytes) {
      hash ^= byte;
      hash = (hash * 0x01000193) & 0xFFFFFFFF;
    }
    return hash;
  }
}
