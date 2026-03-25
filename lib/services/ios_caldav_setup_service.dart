import 'package:caleesync/common/app_constant.dart';
import 'package:caleesync/common/utils/mmkv_utils.dart';
import 'package:caleesync/models/ios_caldav_setup_info.dart';

class IosCalDavSetupService {
  IosCaldavSetupInfo loadSetupInfo() {
    final rawServer = _safeGetString(AppConstant.serverKey);
    final rawUsername = _safeGetString(AppConstant.loginNameKey);
    final rawPassword = _safeGetString(AppConstant.appPasswordKey);

    final server = _normalizeServerForAppleAccount(rawServer ?? AppConstant.caleeServer);
    final username = (rawUsername ?? '').trim();
    final password = (rawPassword ?? '').trim();
    final description = _resolveDescription();

    final missing = <String>[];
    if (username.isEmpty) {
      missing.add('username');
    }
    if (password.isEmpty) {
      missing.add('app password');
    }

    return IosCaldavSetupInfo(
      server: server,
      username: username,
      password: password,
      description: description,
      isReady: missing.isEmpty,
      missingReason: missing.isEmpty ? null : 'Missing ${missing.join(' and ')}. Please reconnect and sign in again.',
    );
  }

  String _normalizeServerForAppleAccount(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) {
      return 'https://${AppConstant.caleeServer}';
    }

    final withScheme = trimmed.contains('://') ? trimmed : 'https://$trimmed';
    final uri = Uri.tryParse(withScheme);
    if (uri == null || uri.host.isEmpty) {
      return withScheme.replaceAll(RegExp(r'/+$'), '');
    }

    final normalized = uri.replace(
      path: uri.path.replaceAll(RegExp(r'/+$'), ''),
      query: uri.hasQuery ? uri.query : null,
      fragment: null,
    );

    return normalized.toString().replaceAll(RegExp(r'/+$'), '');
  }

  String? _safeGetString(String key) {
    try {
      return MMKVUtils.instance.getString(key);
    } catch (_) {
      return null;
    }
  }

  String _resolveDescription() {
    final stored = _safeGetString(AppConstant.calendarAccountNameKey)?.trim();
    if (stored != null && stored.isNotEmpty) {
      return stored;
    }
    return 'Calee';
  }
}
