import 'dart:async';

import '../data/sync_run_store.dart';

class SyncCompletedEvent {
  SyncCompletedEvent({required this.runId, required this.completedAt});

  final String runId;
  final DateTime completedAt;
}

class SyncCompletedEventBus {
  SyncCompletedEventBus._();

  static final SyncRunStore _runStore = SyncRunStore();
  static Timer? _pollTimer;
  static String? _lastObservedRunId;

  static final StreamController<SyncCompletedEvent> _controller =
      StreamController<SyncCompletedEvent>.broadcast(
        onListen: _ensurePolling,
        onCancel: _stopPollingIfIdle,
      );

  static Stream<SyncCompletedEvent> get stream => _controller.stream;

  static void publish(SyncCompletedEvent event) {
    if (!_controller.isClosed) {
      _controller.add(event);
      _lastObservedRunId = event.runId;
    }
  }

  static void _ensurePolling() {
    _pollTimer ??= Timer.periodic(const Duration(seconds: 2), (_) {
      unawaited(_emitLatestRunIfChanged());
    });
    unawaited(_emitLatestRunIfChanged());
  }

  static void _stopPollingIfIdle() {
    if (_controller.hasListener) {
      return;
    }
    _pollTimer?.cancel();
    _pollTimer = null;
  }

  static Future<void> _emitLatestRunIfChanged() async {
    if (_controller.isClosed) {
      return;
    }
    final runs = await _runStore.loadRuns(limit: 1);
    if (runs.isEmpty) {
      return;
    }
    final latestRun = runs.first;
    if (latestRun.endTime == null || latestRun.runId == _lastObservedRunId) {
      return;
    }
    publish(
      SyncCompletedEvent(
        runId: latestRun.runId,
        completedAt: latestRun.endTime!,
      ),
    );
  }
}
