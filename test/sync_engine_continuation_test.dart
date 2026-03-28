import 'dart:io';

import 'package:caleesync/common/app_constant.dart';
import 'package:caleesync/common/utils/mmkv_utils.dart';
import 'package:caleesync/core/platform/pigeon/background_sync_api.g.dart';
import 'package:caleesync/data/sync_repository.dart';
import 'package:caleesync/entity/SyncContext.dart';
import 'package:caleesync/entity/SyncSummary.dart';
import 'package:caleesync/entity/sync_run_record.dart';
import 'package:caleesync/services/calee_auth_service.dart';
import 'package:caleesync/services/calee_server_service.dart';
import 'package:caleesync/sync/SyncEngine.dart';
import 'package:caleesync/sync/SyncEnum.dart';
import 'package:caleesync/sync/sync_item_executor.dart';
import 'package:caleesync/sync/sync_item_planner.dart';
import 'package:caleesync/sync/sync_run_recorder.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'test_bootstrap.dart';

class _FakeRepo extends SyncRepository {
  @override
  Future<void> scanLocalCalendars(String authUserId) async {}

  @override
  Future<int> countEnabledCalendarBindings(String accountName) async => 1;
}

class _FakeServer extends CaleeServerService {
  @override
  Future<List<Map<String, dynamic>>> scanRemoteCalendars({
    required String serverUrl,
    required String authUserId,
    required String accountName,
  }) async {
    return <Map<String, dynamic>>[];
  }
}

class _FakePlanner extends SyncItemPlanner {
  @override
  Future<List<SyncContext>> generateSyncItems(
    String accountName,
    List<Map<String, dynamic>> remoteResults,
  ) async {
    return <SyncContext>[
      SyncContext(
        remoteCollectionId: 1,
        localCalendarId: 'local-1',
        remotePath: '/cal/test/',
        accountName: accountName,
        displayName: 'cal',
        color: '#fff',
        syncMode: SyncBindingMode.twoWay,
        action: SyncAction.fullSyncBidi,
      ),
    ];
  }
}

class _FakeExecutor extends SyncItemExecutor {
  _FakeExecutor({required this.queueContinuation});

  final bool queueContinuation;

  @override
  Future<void> execute(SyncContext ctx, SyncSummary summary) async {
    summary.success++;
    if (queueContinuation) {
      summary.continuationQueued = true;
    }
  }
}

class _FakeRunRecorder extends SyncRunRecorder {
  SyncRunResult? finalizedResult;

  @override
  bool get hasSafetyAbort => false;

  @override
  Future<void> startRun({required SyncRunMode mode, required SyncRunTrigger trigger}) async {}

  @override
  void onBindingStart(SyncContext ctx) {}

  @override
  Future<void> finalizeAndPersist(SyncRunResult result) async {
    finalizedResult = result;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const String enqueueChannel = 'dev.flutter.pigeon.caleesync.BackgroundSyncControlApi.enqueueOneOff';

  setUpAll(() async {
    await bootstrapTestStorage();
    MMKVUtils.instance.setString(AppConstant.calendarAccountNameKey, 'tester-account');
  });

  Future<List<Object?>> _runEngineAndCaptureScheduleCalls({required bool queueContinuation}) async {
    final List<Object?> calls = <Object?>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockDecodedMessageHandler<Object?>(
      enqueueChannel,
      (Object? message) async {
        calls.add(message);
        return <Object?>[null];
      },
    );

    final recorder = _FakeRunRecorder();
    final engine = SyncEngine(
      repo: _FakeRepo(),
      serverService: _FakeServer(),
      authService: CaleeAuthService(serverBaseUrl: 'https://example.com/'),
      planner: _FakePlanner(),
      executor: _FakeExecutor(queueContinuation: queueContinuation),
      runRecorder: recorder,
    );

    await engine.executeFullSync(trigger: SyncRunTrigger.force);

    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockDecodedMessageHandler<Object?>(
      enqueueChannel,
      null,
    );

    return calls;
  }

  test('queues repair_scheduler one-off with replace when continuation is queued (non-iOS)', () async {
    if (Platform.isIOS) {
      markTestSkipped('non-iOS assertion');
      return;
    }

    final calls = await _runEngineAndCaptureScheduleCalls(queueContinuation: true);

    expect(calls, hasLength(1));
    final payload = calls.first as List<Object?>;
    expect(payload[0], 'repair_scheduler');
    expect(payload[1], isFalse);
    expect(payload[2], OneOffEnqueuePolicy.replace.index);
  });

  test('does not schedule continuation when flag is false', () async {
    final calls = await _runEngineAndCaptureScheduleCalls(queueContinuation: false);

    expect(calls, isEmpty);
  });

  test('iOS does not schedule continuation even when queued', () async {
    if (!Platform.isIOS) {
      markTestSkipped('iOS-only behavior');
      return;
    }

    final calls = await _runEngineAndCaptureScheduleCalls(queueContinuation: true);

    expect(calls, isEmpty);
  });
}
