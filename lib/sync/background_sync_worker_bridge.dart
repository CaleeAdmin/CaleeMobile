import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:caleesync/common/app_constant.dart';
import 'package:caleesync/common/utils/mmkv_utils.dart';
import 'package:caleesync/data/database_helper.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'SyncEngine.dart';
import '../entity/sync_run_record.dart';

class BackgroundSyncWorkerBridge {
  static const MethodChannel _channel = MethodChannel('caleesync/background_sync');
  static Future<void>? _initFuture;

  static Future<void> start() async {
    await _ensureInitialized();
    _channel.setMethodCallHandler((call) async {
      if (call.method != 'runBackgroundSync') return <String, dynamic>{'state': 'failure', 'reason': 'unknown_method'};
      final String trigger = (call.arguments as Map?)?['trigger']?.toString() ?? 'unknown';
      return _run(trigger);
    });
  }

  static Future<void> _ensureInitialized() async {
    _initFuture ??= () async {
      WidgetsFlutterBinding.ensureInitialized();
      DartPluginRegistrant.ensureInitialized();
      await MMKVUtils.instance.init();
      await DatabaseHelper.instance.init();
    }();
    await _initFuture;
  }

  static Future<Map<String, dynamic>> _run(String trigger) async {
    final String? loginName = MMKVUtils.instance.getString(AppConstant.loginNameKey);
    if (loginName == null || loginName.isEmpty) {
      return {'state': 'failure', 'reason': 'no_account'};
    }

    try {
      final summary = await SyncEngine().executeFullSync(trigger: _mapTrigger(trigger));
      if (summary.failed == 0) {
        return {'state': 'success', 'reason': trigger};
      }
      final String details = summary.errorLog.join(';').toLowerCase();
      if (_isTransient(details)) {
        return {'state': 'retry', 'reason': details};
      }
      return {'state': 'failure', 'reason': details.isEmpty ? 'sync_failed' : details};
    } on SocketException catch (e) {
      return {'state': 'retry', 'reason': e.message};
    } on TimeoutException catch (e) {
      return {'state': 'retry', 'reason': e.message ?? 'timeout'};
    } catch (e) {
      final reason = e.toString().toLowerCase();
      if (_isTransient(reason)) {
        return {'state': 'retry', 'reason': reason};
      }
      return {'state': 'failure', 'reason': reason};
    }
  }


  static SyncRunTrigger _mapTrigger(String trigger) {
    final normalized = trigger.toLowerCase();
    if (normalized.contains('periodic')) return SyncRunTrigger.periodic;
    if (normalized.contains('force')) return SyncRunTrigger.force;
    if (normalized.contains('auto')) return SyncRunTrigger.autoForeground;
    return SyncRunTrigger.manual;
  }

  static bool _isTransient(String message) {
    return message.contains('timeout') ||
        message.contains('socket') ||
        message.contains('network') ||
        message.contains('temporar') ||
        message.contains(' 5');
  }
}
