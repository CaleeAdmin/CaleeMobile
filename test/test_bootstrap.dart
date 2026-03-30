import 'package:caleesync/common/app_constant.dart';
import 'package:caleesync/common/utils/mmkv_utils.dart';
import 'package:flutter_test/flutter_test.dart';

bool _bootstrapped = false;

Future<void> bootstrapTestStorage({String loginName = 'tester'}) async {
  if (_bootstrapped) {
    MMKVUtils.instance.setString(AppConstant.loginNameKey, loginName);
    return;
  }

  TestWidgetsFlutterBinding.ensureInitialized();
  try {
    await MMKVUtils.instance.init(id: 'test-mmkv');
  } catch (error) {
    throw StateError('MMKV platform plugin is unavailable in this test environment: $error');
  }
  MMKVUtils.instance.setString(AppConstant.loginNameKey, loginName);
  _bootstrapped = true;
}
