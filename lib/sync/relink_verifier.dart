import '../core/platform/pigeon/calendar_api.g.dart';
import '../services/calee_server_service.dart';

class RelinkVerificationResult {
  final bool passed;
  final int confidenceScore;

  const RelinkVerificationResult({required this.passed, required this.confidenceScore});
}

class RelinkVerifier {
  RelinkVerifier({
    CaleeServerService? serverService,
    NativeCalendarApi? nativeApi,
  })  : _server = serverService ?? CaleeServerService(),
        _native = nativeApi ?? NativeCalendarApi();

  final CaleeServerService _server;
  final NativeCalendarApi _native;

  Future<RelinkVerificationResult> verify({
    required String remotePath,
    required String localCalendarId,
    int lookbackDays = 60,
  }) async {
    final int now = DateTime.now().millisecondsSinceEpoch;
    final int start = now - Duration(days: lookbackDays).inMilliseconds;

    final snapshot = await _server.fetchUnifiedEventsSnapshot(
      calendarPath: remotePath,
      isSubscription: false,
    );
    final List<PlatformItem?> localItems = await _native.getEvents(localCalendarId, start, now);

    final Set<String> remoteUids = snapshot.events
        .map((event) => (event['uid'] ?? event['remote_uid'] ?? '').toString())
        .where((uid) => uid.isNotEmpty)
        .toSet();
    final Set<String> localUids = localItems
        .whereType<PlatformItem>()
        .map((item) => (item.uid ?? '').trim())
        .where((uid) => uid.isNotEmpty)
        .toSet();

    if (remoteUids.isEmpty && localUids.isEmpty) {
      return const RelinkVerificationResult(passed: true, confidenceScore: 100);
    }

    final int overlap = remoteUids.intersection(localUids).length;
    final int baseline = remoteUids.length > localUids.length ? remoteUids.length : localUids.length;
    final int score = baseline == 0 ? 0 : ((overlap * 100) / baseline).round();
    return RelinkVerificationResult(passed: score >= 70, confidenceScore: score);
  }
}
