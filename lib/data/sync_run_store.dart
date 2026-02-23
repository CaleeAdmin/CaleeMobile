import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../entity/sync_run_record.dart';

class SyncRunStore {
  static const int retentionLimit = 20;

  Future<Directory> _runDir() async {
    final base = await getApplicationDocumentsDirectory();
    final dir = Directory('${base.path}/sync_runs');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  Future<void> persistCompletedRun(SyncRunRecord run) async {
    final dir = await _runDir();
    final ts = run.startTime.toUtc().toIso8601String().replaceAll(':', '-');
    final finalPath = '${dir.path}/${ts}_${run.runId}.json';
    final tmpPath = '$finalPath.tmp';

    final tmp = File(tmpPath);
    await tmp.writeAsString(const JsonEncoder.withIndent('  ').convert(run.toJson()), flush: true);
    await tmp.rename(finalPath);
    await _enforceRetention(dir);
    await _cleanupDanglingTmp(dir);
  }

  Future<List<SyncRunRecord>> loadRuns({int? limit}) async {
    final dir = await _runDir();
    final files = dir
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.json'))
        .toList()
      ..sort((a, b) => b.path.compareTo(a.path));

    final List<SyncRunRecord> records = [];
    for (final file in files) {
      try {
        final map = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
        records.add(SyncRunRecord.fromJson(map));
      } catch (_) {
        // ignore bad record
      }
      if (limit != null && records.length >= limit) break;
    }
    records.sort((a, b) => b.startTime.compareTo(a.startTime));
    return records;
  }

  Future<void> _enforceRetention(Directory dir) async {
    final files = dir
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.json'))
        .toList()
      ..sort((a, b) => b.path.compareTo(a.path));
    if (files.length <= retentionLimit) return;
    for (final file in files.skip(retentionLimit)) {
      await file.delete();
    }
  }

  Future<void> _cleanupDanglingTmp(Directory dir) async {
    final now = DateTime.now();
    for (final entity in dir.listSync()) {
      if (entity is! File || !entity.path.endsWith('.tmp')) continue;
      final stat = await entity.stat();
      if (now.difference(stat.modified).inHours >= 1) {
        await entity.delete();
      }
    }
  }
}
