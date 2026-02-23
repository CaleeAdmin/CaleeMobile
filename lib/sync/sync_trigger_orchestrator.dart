import 'dart:async';
import 'dart:io';

import 'package:caleesync/common/app_constant.dart';
import 'package:caleesync/common/utils/mmkv_utils.dart';
import 'package:flutter/widgets.dart';
import 'package:get/get.dart';

import '../entity/SyncSummary.dart';
import 'SyncEngine.dart';

enum SyncTriggerType {
  manual,
  autoForeground,
  periodicBackground,
  force,
}

class SyncTriggerOrchestrator extends GetxService with WidgetsBindingObserver {
  SyncTriggerOrchestrator({SyncEngine? engine}) : _engine = engine ?? SyncEngine();

  final SyncEngine _engine;

  bool _appActive = true;
  Timer? _autoDebounceTimer;
  Timer? _periodicTimer;
  Duration _periodicBackoff = Duration.zero;

  Future<SyncSummary>? _activeRun;
  _QueuedRequest? _queuedRequest;

  static const Duration _foregroundDebounce = Duration(seconds: 2);
  static const Duration _initialPeriodicDelay = Duration(minutes: 1);
  static const Duration _maxBackoff = Duration(minutes: 30);

  @override
  void onInit() {
    super.onInit();
    WidgetsBinding.instance.addObserver(this);
    _schedulePeriodicTimer(_initialPeriodicDelay);
  }

  @override
  void onClose() {
    WidgetsBinding.instance.removeObserver(this);
    _autoDebounceTimer?.cancel();
    _periodicTimer?.cancel();
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

  void _schedulePeriodicTimer(Duration delay) {
    _periodicTimer?.cancel();
    _periodicTimer = Timer(delay, _onPeriodicTick);
  }

  Future<void> _onPeriodicTick() async {
    final int configuredMinutes = MMKVUtils.instance.getInt(AppConstant.syncIntervalCalendarKey) ?? 15;
    final Duration interval = Duration(minutes: configuredMinutes <= 0 ? 15 : configuredMinutes);
    final bool periodicEnabled = MMKVUtils.instance.getBool(AppConstant.periodicSyncEnabledKey, defaultValue: false) ?? false;

    if (!periodicEnabled) {
      _periodicBackoff = Duration.zero;
      _schedulePeriodicTimer(interval);
      return;
    }

    final bool hasNetwork = await _hasNetwork();
    if (!hasNetwork) {
      _periodicBackoff = _nextBackoff(_periodicBackoff);
      _schedulePeriodicTimer(_periodicBackoff);
      return;
    }

    try {
      final SyncSummary summary = await _scheduleRun(SyncTriggerType.periodicBackground);
      if (summary.failed > 0) {
        _periodicBackoff = _nextBackoff(_periodicBackoff);
        _schedulePeriodicTimer(_periodicBackoff);
        return;
      }

      _periodicBackoff = Duration.zero;
      _schedulePeriodicTimer(interval);
    } catch (error, stackTrace) {
      debugPrint('[SYNC_TRIGGER] periodic run failed: $error');
      debugPrintStack(label: '[SYNC_TRIGGER] periodic run stack', stackTrace: stackTrace);
      _periodicBackoff = _nextBackoff(_periodicBackoff);
      _schedulePeriodicTimer(_periodicBackoff);
    }
  }

  Duration _nextBackoff(Duration current) {
    if (current == Duration.zero) {
      return const Duration(minutes: 1);
    }
    final int doubledSeconds = current.inSeconds * 2;
    if (doubledSeconds >= _maxBackoff.inSeconds) {
      return _maxBackoff;
    }
    return Duration(seconds: doubledSeconds);
  }

  Future<bool> _hasNetwork() async {
    try {
      final List<InternetAddress> result = await InternetAddress.lookup('example.com');
      return result.isNotEmpty;
    } catch (_) {
      return false;
    }
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
    final Future<SyncSummary> run = _engine.executeFullSync(onProgress: onProgress);
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
