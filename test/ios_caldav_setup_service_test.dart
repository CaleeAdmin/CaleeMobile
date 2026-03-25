import 'package:caleesync/common/app_constant.dart';
import 'package:caleesync/common/utils/mmkv_utils.dart';
import 'package:caleesync/services/ios_caldav_setup_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'test_bootstrap.dart';

void main() {
  late IosCalDavSetupService service;
  bool mmkvReady = false;

  setUpAll(() async {
    try {
      await bootstrapTestStorage(loginName: 'ios-user@example.com');
      mmkvReady = true;
    } catch (_) {
      mmkvReady = false;
    }
  });

  Future<void> requireMmkv() async {
    if (!mmkvReady) {
      markTestSkipped('MMKV platform plugin is unavailable in this test environment.');
    }
  }

  setUp(() async {
    await requireMmkv();
    if (!mmkvReady) return;
    MMKVUtils.instance.clear();
    service = IosCalDavSetupService();
  });

  test('default server fallback when no server is stored', () async {
    await requireMmkv();
    if (!mmkvReady) return;
    MMKVUtils.instance.setString(AppConstant.loginNameKey, 'ios-user@example.com');
    MMKVUtils.instance.setString(AppConstant.appPasswordKey, 'secret');

    final info = service.loadSetupInfo();

    expect(info.server, 'https://${AppConstant.caleeServer}');
  });

  test('trailing slash normalization removes ending slash', () async {
    await requireMmkv();
    if (!mmkvReady) return;
    MMKVUtils.instance.setString(AppConstant.serverKey, 'https://portal.calee.com.au/');
    MMKVUtils.instance.setString(AppConstant.loginNameKey, 'ios-user@example.com');
    MMKVUtils.instance.setString(AppConstant.appPasswordKey, 'secret');

    final info = service.loadSetupInfo();

    expect(info.server, 'https://portal.calee.com.au');
  });

  test('custom path is preserved while normalizing', () async {
    await requireMmkv();
    if (!mmkvReady) return;
    MMKVUtils.instance.setString(AppConstant.serverKey, 'portal.calee.com.au/dav/team/');
    MMKVUtils.instance.setString(AppConstant.loginNameKey, 'ios-user@example.com');
    MMKVUtils.instance.setString(AppConstant.appPasswordKey, 'secret');

    final info = service.loadSetupInfo();

    expect(info.server, 'https://portal.calee.com.au/dav/team');
  });

  test('description falls back to Calee when account name is missing', () async {
    await requireMmkv();
    if (!mmkvReady) return;
    MMKVUtils.instance.setString(AppConstant.loginNameKey, 'ios-user@example.com');
    MMKVUtils.instance.setString(AppConstant.appPasswordKey, 'secret');

    final info = service.loadSetupInfo();

    expect(info.description, 'Calee');
  });

  test('missing credentials marks setup as blocked', () async {
    await requireMmkv();
    if (!mmkvReady) return;
    final info = service.loadSetupInfo();

    expect(info.isReady, isFalse);
    expect(info.missingReason, contains('Missing'));
  });
}
