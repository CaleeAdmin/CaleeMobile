import '../../common/app_constant.dart';
import '../../common/utils/mmkv_utils.dart';
import '../../core/platform/pigeon/calendar_api.g.dart';
import '../../data/database_helper.dart';
import '../../data/sync_repository.dart';
import '../../entity/SyncContext.dart';
import '../../entity/SyncSummary.dart';
import '../../services/calee_auth_service.dart';
import '../../services/calee_server_service.dart';

abstract class SyncStrategy {
  static const int massDeletionAbsoluteThreshold = 10;

  // 共用服务组件
  final SyncRepository repo = SyncRepository();
  final CaleeServerService nc = CaleeServerService();
  final NativeCalendarApi nativeApi = NativeCalendarApi();
  final CaleeAuthService authService = CaleeAuthService(serverBaseUrl: AppConstant.caleeServer);
  final DatabaseHelper dbHelper = DatabaseHelper.instance;
  final String? loginName = MMKVUtils.instance.getString(AppConstant.loginNameKey);
  final String? password = MMKVUtils.instance.getString(AppConstant.appPasswordKey);

  // 核心执行接口
  Future<void> execute(SyncContext ctx, SyncSummary summary);

  String massDeletionKeyForBinding(int bindingId) =>
      '${AppConstant.allowMassDeletionByBindingKeyPrefix}$bindingId';

  bool isMassDeletionOverrideEnabled(int bindingId) {
    if (bindingId <= 0) return false;
    return MMKVUtils.instance.getBool(massDeletionKeyForBinding(bindingId), defaultValue: false) ?? false;
  }
}
