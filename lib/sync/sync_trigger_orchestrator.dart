import 'dart:async';

import 'package:caleesync/common/app_constant.dart';
import 'package:caleesync/common/utils/mmkv_utils.dart';
import 'package:flutter/widgets.dart';
import 'package:get/get.dart';

import '../entity/SyncSummary.dart';
import '../entity/sync_run_record.dart';
import 'SyncEngine.dart';

enum SyncTriggerType {
  manual,
  autoForeground,
  force,
}

class SyncTriggerOrchestrator extends GetxService with WidgetsBindingObserver {
  SyncTriggerOrchestrator({SyncEngine? engine}) : _engine = engine ?? SyncEngine();

  final SyncEngine _engine;

  bool _appActive = true;
  Timer? _autoDebounceTimer;

  Future<SyncSummary>? _activeRun;
  _QueuedRequest? _queuedRequest;

  static const Duration _foregroundDebounce = Duration(seconds: 2);

  @override
  void onInit() {
    super.onInit();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void onClose() {
    WidgetsBinding.instance.removeObserver(this);
    _autoDebounceTimer?.cancel();
    super.onClose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _appActive = state == AppLifecycleState.resumed;
  }

  Future<SyncSummary> triggerManual({Function(SyncSummary)? onProgress}) {
    return _scheduleRun(SyncTriggerType.manual, onProgress: onProgress);
  }

  Future<SyncSummary> triggerForce(int remoteCollectionId, {Function(SyncSummary)? onProgress}) {
    SyncEngine.requestForceSyncForCollection(remoteCollectionId);
    return _scheduleRun(SyncTriggerType.force, onProgress: onProgress);
  }

  void notifyMeaningfulForegroundChange() {
    final bool autoSyncEnabled = MMKVUtils.instance.getBool(AppConstant.autoSyncEnabledKey, defaultValue: true) ?? true;
    if (!autoSyncEnabled || !_appActive) {
      return;
    }
    _autoDebounceTimer?.cancel();
    _autoDebounceTimer = Timer(_foregroundDebounce, () {
      _scheduleRun(SyncTriggerType.autoForeground);
    });
  }

  Future<SyncSummary> _scheduleRun(
    SyncTriggerType trigger, {
    Function(SyncSummary)? onProgress,
  }) {
    final completer = Completer<SyncSummary>();

    if (_activeRun == null) {
      _startRun(trigger, completer, onProgress: onProgress);
      return completer.future;
    }

    if (_queuedRequest == null) {
      _queuedRequest = _QueuedRequest(trigger: trigger);
    }
    _queuedRequest!.promises.add(_QueuedPromise(completer: completer, onProgress: onProgress));
    return completer.future;
  }

  void _startRun(
    SyncTriggerType trigger,
    Completer<SyncSummary> rootCompleter, {
    Function(SyncSummary)? onProgress,
  }) {
    debugPrint('[SYNC_TRIGGER] start trigger=$trigger');
    final Future<SyncSummary> run = _engine.executeFullSync(
      onProgress: onProgress,
      trigger: _mapRunTrigger(trigger),
    );
    _activeRun = run;

    run.then((summary) {
      if (!rootCompleter.isCompleted) {
        rootCompleter.complete(summary);
      }
      final queued = _queuedRequest;
      _queuedRequest = null;
      _activeRun = null;

      if (queued == null) {
        return;
      }
      final first = queued.promises.isNotEmpty ? queued.promises.first : null;
      final Completer<SyncSummary> queuedRoot = first?.completer ?? Completer<SyncSummary>();
      _startRun(queued.trigger, queuedRoot, onProgress: first?.onProgress);
      if (first == null) {
        return;
      }
      queuedRoot.future.then((value) {
        for (int i = 1; i < queued.promises.length; i++) {
          final next = queued.promises[i];
          next.onProgress?.call(value);
          if (!next.completer.isCompleted) {
            next.completer.complete(value);
          }
        }
      }).catchError((error, stackTrace) {
        for (int i = 1; i < queued.promises.length; i++) {
          final next = queued.promises[i];
          if (!next.completer.isCompleted) {
            next.completer.completeError(error, stackTrace);
          }
        }
      });
    }).catchError((error, stackTrace) {
      if (!rootCompleter.isCompleted) {
        rootCompleter.completeError(error, stackTrace);
      }
      final queued = _queuedRequest;
      _queuedRequest = null;
      _activeRun = null;
      if (queued == null) {
        return;
      }
      final first = queued.promises.isNotEmpty ? queued.promises.first : null;
      final Completer<SyncSummary> queuedRoot = first?.completer ?? Completer<SyncSummary>();
      _startRun(queued.trigger, queuedRoot, onProgress: first?.onProgress);
      if (first == null) {
        return;
      }
      queuedRoot.future.then((value) {
        for (int i = 1; i < queued.promises.length; i++) {
          final next = queued.promises[i];
          next.onProgress?.call(value);
          if (!next.completer.isCompleted) {
            next.completer.complete(value);
          }
        }
      }).catchError((queuedError, queuedStack) {
        for (int i = 1; i < queued.promises.length; i++) {
          final next = queued.promises[i];
          if (!next.completer.isCompleted) {
            next.completer.completeError(queuedError, queuedStack);
          }
        }
      });
    });
  }
  SyncRunTrigger _mapRunTrigger(SyncTriggerType trigger) {
    return switch (trigger) {
      SyncTriggerType.manual => SyncRunTrigger.manual,
      SyncTriggerType.autoForeground => SyncRunTrigger.autoForeground,
      SyncTriggerType.force => SyncRunTrigger.force,
    };
  }

}

class _QueuedRequest {
  _QueuedRequest({required this.trigger});

  final SyncTriggerType trigger;
  final List<_QueuedPromise> promises = [];
}

class _QueuedPromise {
  _QueuedPromise({required this.completer, this.onProgress});

  final Completer<SyncSummary> completer;
  final Function(SyncSummary)? onProgress;
}
