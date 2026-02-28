import 'dart:math' as math;

import '../core/platform/pigeon/calendar_api.g.dart';
import '../services/calee_server_service.dart';

class RelinkVerificationResult {
  final bool passed;
  final int confidenceScore;
  final bool isIndeterminate;

  const RelinkVerificationResult({
    required this.passed,
    required this.confidenceScore,
    this.isIndeterminate = false,
  });
}

class RelinkVerifier {
  RelinkVerifier({
    CaleeServerService? serverService,
    NativeCalendarApi? nativeApi,
    Future<UnifiedEventsSnapshot> Function(String remotePath, bool isSubscription)? fetchRemoteSnapshot,
    Future<List<PlatformItem?>> Function(String localCalendarId, int startMs, int endMs)? fetchLocalEvents,
  })  : _server = serverService ?? CaleeServerService(),
        _native = nativeApi ?? NativeCalendarApi(),
        _fetchRemoteSnapshot = fetchRemoteSnapshot,
        _fetchLocalEvents = fetchLocalEvents;

  final CaleeServerService _server;
  final NativeCalendarApi _native;
  final Future<UnifiedEventsSnapshot> Function(String remotePath, bool isSubscription)? _fetchRemoteSnapshot;
  final Future<List<PlatformItem?>> Function(String localCalendarId, int startMs, int endMs)? _fetchLocalEvents;

  Future<RelinkVerificationResult> verify({
    required String remotePath,
    required String localCalendarId,
    bool isSubscription = false,
    int lookbackDays = 60,
  }) async {
    final int boundedLookbackDays = lookbackDays.clamp(30, 90);
    final DateTime now = DateTime.now().toUtc();
    final DateTime startDt = now.subtract(Duration(days: boundedLookbackDays));
    final int startMs = startDt.millisecondsSinceEpoch;
    final int endMs = now.millisecondsSinceEpoch;

    final UnifiedEventsSnapshot snapshot =
        await (_fetchRemoteSnapshot?.call(remotePath, isSubscription) ??
            _server.fetchUnifiedEventsSnapshot(
              calendarPath: remotePath,
              isSubscription: isSubscription,
            ));

    final bool remoteFetchSucceeded =
        snapshot.fetchSucceeded && (snapshot.statusCode == 200 || snapshot.statusCode == 207);
    if (!remoteFetchSucceeded) {
      return RelinkVerificationResult(
        passed: false,
        confidenceScore: 0,
        isIndeterminate: true,
      );
    }

    final List<PlatformItem?> localItems =
        await (_fetchLocalEvents?.call(localCalendarId, startMs, endMs) ??
            _native.getEvents(localCalendarId, startMs, endMs));

    final List<_RemoteEvent> remoteEvents = _parseRemoteEvents(snapshot.events);
    final List<_LocalEvent> localEvents = _parseLocalEvents(localItems);

    if (remoteEvents.isEmpty && localEvents.isEmpty) {
      return const RelinkVerificationResult(
        passed: false,
        confidenceScore: 0,
        isIndeterminate: true,
      );
    }

    final int baseline = math.max(remoteEvents.length, localEvents.length);
    if (baseline == 0) {
      return const RelinkVerificationResult(passed: false, confidenceScore: 0);
    }

    final int matched = _countMatchedEvents(remoteEvents, localEvents);

    final int confidence = ((matched * 100) / baseline).round().clamp(0, 100);

    if (remoteEvents.length < 5 && localEvents.length < 5 && confidence < 98) {
      return RelinkVerificationResult(
        passed: false,
        confidenceScore: confidence,
        isIndeterminate: true,
      );
    }

    return RelinkVerificationResult(passed: confidence >= 90, confidenceScore: confidence);
  }

  Future<int> previewConfidence({
    required String remotePath,
    required String localCalendarId,
    bool isSubscription = false,
    int lookbackDays = 30,
    int maxEvents = 20,
  }) async {
    final int boundedLookbackDays = lookbackDays.clamp(14, 60);
    final int boundedMaxEvents = maxEvents.clamp(5, 50);
    final DateTime now = DateTime.now().toUtc();
    final DateTime startDt = now.subtract(Duration(days: boundedLookbackDays));
    final int startMs = startDt.millisecondsSinceEpoch;
    final int endMs = now.millisecondsSinceEpoch;

    final UnifiedEventsSnapshot snapshot =
        await (_fetchRemoteSnapshot?.call(remotePath, isSubscription) ??
            _server.fetchUnifiedEventsSnapshot(
              calendarPath: remotePath,
              isSubscription: isSubscription,
            ));

    final bool remoteFetchSucceeded =
        snapshot.fetchSucceeded && (snapshot.statusCode == 200 || snapshot.statusCode == 207);
    if (!remoteFetchSucceeded) {
      return 0;
    }

    final List<PlatformItem?> localItems =
        await (_fetchLocalEvents?.call(localCalendarId, startMs, endMs) ??
            _native.getEvents(localCalendarId, startMs, endMs));
    final List<_RemoteEvent> remoteEvents = _parseRemoteEvents(snapshot.events)
      ..sort((a, b) => b.startMs.compareTo(a.startMs));
    final List<_LocalEvent> localEvents = _parseLocalEvents(localItems)
      ..sort((a, b) => b.startMs.compareTo(a.startMs));

    final List<_RemoteEvent> sampledRemote = remoteEvents.take(boundedMaxEvents).toList();
    final List<_LocalEvent> sampledLocal = localEvents.take(boundedMaxEvents).toList();
    if (sampledRemote.isEmpty || sampledLocal.isEmpty) {
      return 0;
    }

    final int baseline = math.max(sampledRemote.length, sampledLocal.length);
    if (baseline == 0) {
      return 0;
    }

    final int matched = _countMatchedEvents(sampledRemote, sampledLocal);
    return ((matched * 100) / baseline).round().clamp(0, 100);
  }

  List<_RemoteEvent> _parseRemoteEvents(List<Map<String, dynamic>> events) {
    return events.map((event) => _RemoteEvent.fromMap(event)).whereType<_RemoteEvent>().toList();
  }

  List<_LocalEvent> _parseLocalEvents(List<PlatformItem?> localItems) {
    return localItems
        .whereType<PlatformItem>()
        .map((item) => _LocalEvent.fromPlatformItem(item))
        .whereType<_LocalEvent>()
        .toList();
  }

  int _countMatchedEvents(List<_RemoteEvent> remoteEvents, List<_LocalEvent> localEvents) {
    int matched = 0;
    final Set<int> usedLocalIndices = <int>{};
    for (final _RemoteEvent remote in remoteEvents) {
      int? bestIdx;
      int bestScore = 0;
      for (int idx = 0; idx < localEvents.length; idx++) {
        if (usedLocalIndices.contains(idx)) continue;
        final int score = _matchScore(remote, localEvents[idx]);
        if (score > bestScore) {
          bestScore = score;
          bestIdx = idx;
        }
      }
      if (bestIdx != null && bestScore >= 75) {
        usedLocalIndices.add(bestIdx);
        matched++;
      }
    }
    return matched;
  }

  int _matchScore(_RemoteEvent remote, _LocalEvent local) {
    int score = 0;

    if (remote.title.isNotEmpty && local.title.isNotEmpty) {
      final String r = _normalizeTitle(remote.title);
      final String l = _normalizeTitle(local.title);
      if (r == l) {
        score += 65;
      } else if (r.contains(l) || l.contains(r)) {
        score += 50;
      }
    }

    final int startDeltaMin = ((remote.startMs - local.startMs).abs() / 60000).round();
    if (startDeltaMin <= 5) {
      score += 25;
    } else if (startDeltaMin <= 30) {
      score += 15;
    }

    if (remote.endMs != null && local.endMs != null) {
      final int endDeltaMin = (((remote.endMs! - local.endMs!).abs()) / 60000).round();
      if (endDeltaMin <= 5) {
        score += 10;
      } else if (endDeltaMin <= 30) {
        score += 5;
      }
    }

    return score.clamp(0, 100);
  }

  String _normalizeTitle(String input) {
    return input.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');
  }
}

class _RemoteEvent {
  final String title;
  final int startMs;
  final int? endMs;

  const _RemoteEvent({required this.title, required this.startMs, required this.endMs});

  static _RemoteEvent? fromMap(Map<String, dynamic> map) {
    final int? start = _coerceToEpoch(map['dtstart'] ?? map['start']);
    if (start == null) return null;
    return _RemoteEvent(
      title: (map['summary'] ?? '').toString(),
      startMs: start,
      endMs: _coerceToEpoch(map['dtend'] ?? map['end']),
    );
  }
}

class _LocalEvent {
  final String title;
  final int startMs;
  final int? endMs;

  const _LocalEvent({required this.title, required this.startMs, required this.endMs});

  static _LocalEvent? fromPlatformItem(PlatformItem item) {
    final int? start = item.startTime;
    if (start == null) return null;
    return _LocalEvent(
      title: (item.title ?? '').trim(),
      startMs: start,
      endMs: item.endTime,
    );
  }
}

int? _coerceToEpoch(dynamic value) {
  if (value is int) return value;
  if (value == null) return null;
  final String text = value.toString().trim();
  if (text.isEmpty) return null;

  final int? asInt = int.tryParse(text);
  if (asInt != null) {
    return asInt > 1000000000000 ? asInt : asInt * 1000;
  }

  final DateTime? asDate = DateTime.tryParse(text);
  return asDate?.toUtc().millisecondsSinceEpoch;
}
