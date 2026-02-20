import '../entity/SyncContext.dart';
import '../entity/sync_run_record.dart';

enum SyncOperationTarget { local, remote }
enum SyncOperationType { created, updated, deleted }

abstract class SyncRunTelemetry {
  void onBindingStart(SyncContext ctx);

  void onBindingEnd({
    required SyncContext ctx,
    required SyncBindingResultStatus status,
    required SnapshotTrustStatus snapshotTrustStatus,
    required bool safetyTriggered,
    SyncErrorCode? errorCode,
    String? errorMessage,
    String? technicalDetail,
  });

  void onOperation({
    required SyncContext ctx,
    required SyncOperationTarget target,
    required SyncOperationType type,
  });

  void onError({
    required SyncContext ctx,
    required SyncErrorCode code,
    required String message,
    String? technicalDetail,
  });

  void onSafetyTriggered({required SyncContext ctx, String? detail});
}
