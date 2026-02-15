import '../../common/app_constant.dart';
import '../../common/utils/mmkv_utils.dart';
import '../../core/platform/pigeon/calendar_api.g.dart';
import '../../data/database_helper.dart';
import '../../data/sync_repository.dart';
import '../../entity/SyncContext.dart';
import '../../entity/SyncSummary.dart';
import '../../services/nextcloud_auth_service.dart';
import '../../services/nextcloud_service.dart';

abstract class SyncStrategy {
  // 共用服务组件
  final SyncRepository repo = SyncRepository();
  final NextcloudService nc = NextcloudService();
  final NativeCalendarApi nativeApi = NativeCalendarApi();
  final NextcloudAuthService authService = NextcloudAuthService(serverBaseUrl: AppConstant.nextcloudServer);
  final DatabaseHelper dbHelper = DatabaseHelper.instance;
  final String? loginName = MMKVUtils.instance.getString(AppConstant.loginName);
  final String? password = MMKVUtils.instance.getString(AppConstant.password);

  // 核心执行接口
  Future<void> execute(SyncContext ctx, SyncSummary summary);
}