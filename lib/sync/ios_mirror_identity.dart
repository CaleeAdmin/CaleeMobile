import '../services/calee_server_service.dart';

String deriveIosMirrorMarker({required String remotePath, String? originKey}) {
  final String trimmedOriginKey = (originKey ?? '').trim();
  final String normalizedRemotePath =
      CaleeServerService.normalizeRemotePath(remotePath).trim();
  final String seed = trimmedOriginKey.isNotEmpty ? trimmedOriginKey : normalizedRemotePath;
  if (seed.isEmpty) return '';

  int hash = 0x811C9DC5;
  for (final int codeUnit in seed.codeUnits) {
    hash ^= codeUnit;
    hash = (hash * 0x01000193) & 0xFFFFFFFF;
  }

  final String marker = hash
      .toUnsigned(32)
      .toRadixString(16)
      .toUpperCase()
      .padLeft(8, '0')
      .substring(0, 5);
  return marker.replaceAll(RegExp(r'[^A-Z0-9]'), '');
}

String buildIosMirrorTitle({required String displayName, required String marker}) {
  final String trimmedMarker = marker.trim();
  if (trimmedMarker.isEmpty) return displayName;

  final String suffix = '[$trimmedMarker]';
  final String trimmedTitle = displayName.trimRight();
  if (trimmedTitle.endsWith(' $suffix') || trimmedTitle.endsWith(suffix)) {
    return trimmedTitle;
  }
  return '$displayName $suffix';
}

({String baseName, String marker})? parseIosMirrorTitle(String title) {
  final String trimmedTitle = title.trim();
  final RegExpMatch? match = RegExp(r'^(.*) \[([A-Z0-9]{5})\]$').firstMatch(
    trimmedTitle,
  );
  if (match == null) {
    return null;
  }

  final String baseName = (match.group(1) ?? '').trim();
  final String marker = (match.group(2) ?? '').trim();
  if (baseName.isEmpty || marker.isEmpty) {
    return null;
  }

  return (baseName: baseName, marker: marker);
}

bool looksLikeIosMirrorTitle(String title) {
  return parseIosMirrorTitle(title) != null;
}

bool matchesExpectedIosMirrorTitle({
  required String title,
  required String displayName,
  required String remotePath,
  String? originKey,
}) {
  final ({String baseName, String marker})? parsedTitle = parseIosMirrorTitle(title);
  if (parsedTitle == null) {
    return false;
  }

  final String expectedBaseName = displayName.trim();
  final String expectedMarker = deriveIosMirrorMarker(
    remotePath: remotePath,
    originKey: originKey,
  ).trim();
  if (expectedBaseName.isEmpty || expectedMarker.isEmpty) {
    return false;
  }

  return parsedTitle.baseName == expectedBaseName &&
      parsedTitle.marker == expectedMarker;
}
