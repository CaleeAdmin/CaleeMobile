import 'dart:async';

class SyncCompletedEvent {
  SyncCompletedEvent({required this.runId, required this.completedAt});

  final String runId;
  final DateTime completedAt;
}

class SyncCompletedEventBus {
  SyncCompletedEventBus._();

  static final StreamController<SyncCompletedEvent> _controller =
      StreamController<SyncCompletedEvent>.broadcast();

  static Stream<SyncCompletedEvent> get stream => _controller.stream;

  static void publish(SyncCompletedEvent event) {
    if (!_controller.isClosed) {
      _controller.add(event);
    }
  }
}
