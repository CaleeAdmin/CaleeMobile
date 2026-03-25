import 'package:caleesync/common/app_constant.dart';
import 'package:caleesync/common/utils/mmkv_utils.dart';
import 'package:caleesync/services/ios_caldav_setup_service.dart';
import 'package:caleesync/test_bootstrap.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late IosCalDavSetupService service;

  setUp(() async {
    await bootstrapTestStorage(loginName: 'ios-user@example.com');
    MMKVUtils.instance.clear();
    service = IosCalDavSetupService();
  });

  test('default server fallback when no server is stored', () {
    MMKVUtils.instance.setString(AppConstant.loginNameKey, 'ios-user@example.com');
    MMKVUtils.instance.setString(AppConstant.appPasswordKey, 'secret');

    final info = service.loadSetupInfo();

    expect(info.server, 'https://${AppConstant.caleeServer}');
  });

  test('trailing slash normalization removes ending slash', () {
    MMKVUtils.instance.setString(AppConstant.serverKey, 'https://portal.calee.com.au/');
    MMKVUtils.instance.setString(AppConstant.loginNameKey, 'ios-user@example.com');
    MMKVUtils.instance.setString(AppConstant.appPasswordKey, 'secret');

    final info = service.loadSetupInfo();

    expect(info.server, 'https://portal.calee.com.au');
  });

  test('custom path is preserved while normalizing', () {
    MMKVUtils.instance.setString(AppConstant.serverKey, 'portal.calee.com.au/dav/team/');
    MMKVUtils.instance.setString(AppConstant.loginNameKey, 'ios-user@example.com');
    MMKVUtils.instance.setString(AppConstant.appPasswordKey, 'secret');

    final info = service.loadSetupInfo();

    expect(info.server, 'https://portal.calee.com.au/dav/team');
  });

  test('description falls back to Calee when account name is missing', () {
    MMKVUtils.instance.setString(AppConstant.loginNameKey, 'ios-user@example.com');
    MMKVUtils.instance.setString(AppConstant.appPasswordKey, 'secret');

    final info = service.loadSetupInfo();

    expect(info.description, 'Calee');
  });

  test('missing credentials marks setup as blocked', () {
    final info = service.loadSetupInfo();

    expect(info.isReady, isFalse);
    expect(info.missingReason, contains('Missing'));
  });
}
