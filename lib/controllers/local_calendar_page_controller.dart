import 'dart:async';

import 'package:caleesync/common/app_constant.dart';
import 'package:caleesync/common/utils/mmkv_utils.dart';
import 'package:caleesync/core/platform/pigeon/calendar_api.g.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:sqflite/sqflite.dart';

import '../data/database_helper.dart';
import '../services/calee_server_service.dart';
import '../sync/SyncEnum.dart';
import '../sync/ios_mirror_identity.dart';
import '../sync/relink_verifier.dart';
import '../sync/sync_gate_reason.dart';
import 'CalendarPageController.dart';

enum LocalCalendarsPageMode { normal, relinkReview }

class LocalCalendarGroup {
  final String accountName;
  final List<LocalCalendarItem> calendars;

  LocalCalendarGroup({required this.accountName, required this.calendars});
}

class LocalCalendarItem {
  final String id;
  final String name;
  final String accountName;
  final String? accountType;
  final String? ownerAccount;
  final String? calSync1;
  final String color;
  final bool isReadOnly;
  int eventCount;
  final bool isSubscription;
  final String? subscriptionUrl;
  bool isConnected;
  bool canRelink;
  int relinkConfidence;

  LocalCalendarItem({
    required this.id,
    required this.name,
    required this.accountName,
    required this.accountType,
    required this.ownerAccount,
    required this.calSync1,
    required this.color,
    required this.isReadOnly,
    required this.eventCount,
    required this.isSubscription,
    required this.subscriptionUrl,
    required this.isConnected,
    required this.canRelink,
    required this.relinkConfidence,
  });
}

class LocalCalendarPageController extends GetxController {
  final NativeCalendarApi _nativeApi = NativeCalendarApi();
  final CaleeServerService _caleeService = CaleeServerService();
  final RelinkVerifier _relinkVerifier = RelinkVerifier();

  final calendarGroups = <LocalCalendarGroup>[].obs;
  final isLoading = false.obs;
  final connectingCalendarIds = <String>{}.obs;
  final currentMode = LocalCalendarsPageMode.normal.obs;
  final reviewRemoteCollectionId = RxnInt();
  final reviewRemoteDisplayName = RxnString();
  final reviewRemotePath = RxnString();
  final reviewCandidates = <LocalCalendarItem>[].obs;
  static const int _highConfidenceRelinkThreshold = 70;
  static const int _metadataBatchSize = 4;
  int _refreshVersion = 0;

  bool get isReviewMode => currentMode.value == LocalCalendarsPageMode.relinkReview;
  bool get hasReviewCandidates => reviewCandidates.isNotEmpty;

  Future<void> enterNormalMode() async {
    currentMode.value = LocalCalendarsPageMode.normal;
    reviewRemoteCollectionId.value = null;
    reviewRemoteDisplayName.value = null;
    reviewRemotePath.value = null;
    reviewCandidates.clear();
    await refreshLocalCalendars();
  }

  Future<void> loadRelinkReviewCandidates({
    required int remoteCollectionId,
    required String remoteDisplayName,
    required String remotePath,
  }) async {
    currentMode.value = LocalCalendarsPageMode.relinkReview;
    reviewRemoteCollectionId.value = remoteCollectionId;
    reviewRemoteDisplayName.value = remoteDisplayName;
    reviewRemotePath.value = remotePath;
    reviewCandidates.clear();

    try {
      isLoading.value = true;
      final List<LocalCalendarItem> candidates = await _findPossibleRelinkCandidatesForRemote(
        remoteCollectionId: remoteCollectionId,
        remoteDisplayName: remoteDisplayName,
        remotePath: remotePath,
        requestPermission: true,
        silentOnPermissionFailure: false,
      );
      final List<LocalCalendarItem> verifiedCandidates = <LocalCalendarItem>[];
      for (final LocalCalendarItem candidate in candidates) {
        final _ResolvedRelinkTarget? resolvedTarget = await _resolveVerifiedRelinkTargetForLocal(
          candidate,
          preferredRemoteCollectionId: remoteCollectionId,
          preferredRemotePath: remotePath,
          allowFallback: false,
          minimumProviderHintScore: 0,
        );
        if (resolvedTarget != null) {
          verifiedCandidates.add(candidate);
        }
      }
      reviewCandidates.assignAll(verifiedCandidates);
    } catch (e) {
      debugPrint('[ERROR] Failed to load relink review candidates: $e');
      final String errorMessage = e.toString();
      if (errorMessage.contains('Calendar access is required')) {
        Get.snackbar('Permission required', 'Calendar access is required to load local calendars.');
      } else {
        Get.snackbar('Error', 'Failed to load local calendars');
      }
    } finally {
      isLoading.value = false;
    }
  }

  Future<int> getHighConfidenceRelinkCandidateCountForRemote({
    required int remoteCollectionId,
    required String remoteDisplayName,
    required String remotePath,
  }) async {
    final List<LocalCalendarItem> candidates = await _findHighConfidenceRelinkCandidatesForRemote(
      remoteCollectionId: remoteCollectionId,
      remoteDisplayName: remoteDisplayName,
      remotePath: remotePath,
      requestPermission: false,
      silentOnPermissionFailure: true,
    );
    int verifiedCount = 0;
    for (final LocalCalendarItem candidate in candidates) {
      final _ResolvedRelinkTarget? resolvedTarget = await _resolveVerifiedRelinkTargetForLocal(
        candidate,
        preferredRemoteCollectionId: remoteCollectionId,
        preferredRemotePath: remotePath,
        allowFallback: false,
      );
      if (resolvedTarget != null) {
        verifiedCount += 1;
      }
    }
    return verifiedCount;
  }

  Future<int> getReviewableRelinkCandidateCountForRemote({
    required int remoteCollectionId,
    required String remoteDisplayName,
    required String remotePath,
  }) async {
    final List<LocalCalendarItem> candidates = await _findPossibleRelinkCandidatesForRemote(
      remoteCollectionId: remoteCollectionId,
      remoteDisplayName: remoteDisplayName,
      remotePath: remotePath,
      requestPermission: false,
      silentOnPermissionFailure: true,
    );
    int verifiedCount = 0;
    for (final LocalCalendarItem candidate in candidates) {
      final _ResolvedRelinkTarget? resolvedTarget = await _resolveVerifiedRelinkTargetForLocal(
        candidate,
        preferredRemoteCollectionId: remoteCollectionId,
        preferredRemotePath: remotePath,
        allowFallback: false,
        minimumProviderHintScore: 0,
      );
      if (resolvedTarget != null) {
        verifiedCount += 1;
      }
    }
    return verifiedCount;
  }

  Future<List<LocalCalendarItem>> _findPossibleRelinkCandidatesForRemote({
    required int remoteCollectionId,
    required String remoteDisplayName,
    required String remotePath,
    bool requestPermission = true,
    bool silentOnPermissionFailure = false,
  }) async {
    final bool hasPermission = await _nativeApi.requestPermission(false);
    if (!hasPermission) {
      if (!requestPermission || silentOnPermissionFailure) {
        return <LocalCalendarItem>[];
      }
      throw Exception('Calendar access is required to load local calendars.');
    }

    final db = await DatabaseHelper.instance.database;
    final List<PlatformCalendar?> rawCalendars = await _nativeApi.getCalendars();
    final Set<String> nativeCalendarIds = {
      for (final calendar in rawCalendars.whereType<PlatformCalendar>())
        _normalizeLocalCollectionId(calendar.id),
    }..remove('');

    final List<Map<String, dynamic>> remoteRows = await db.query(
      'remote_collections',
      columns: ['id', 'display_name', 'remote_path', 'origin_key', 'account_name'],
      where: 'id = ? AND collection_type = ? AND origin_kind = ?',
      whereArgs: [remoteCollectionId, 'calendar', 0],
      limit: 1,
    );
    if (remoteRows.isEmpty) {
      return <LocalCalendarItem>[];
    }

    final Map<String, dynamic> remoteRow = remoteRows.first;
    final String normalizedRequestedRemotePath = CaleeServerService.normalizeRemotePath(remotePath);
    final String normalizedStoredRemotePath =
        CaleeServerService.normalizeRemotePath(remoteRow['remote_path']?.toString() ?? '');
    if (normalizedRequestedRemotePath.isNotEmpty &&
        normalizedStoredRemotePath.isNotEmpty &&
        normalizedRequestedRemotePath != normalizedStoredRemotePath) {
      return <LocalCalendarItem>[];
    }

    final String requestedDisplayName = remoteDisplayName.trim();
    final String storedDisplayName = (remoteRow['display_name']?.toString() ?? '').trim();
    if (requestedDisplayName.isNotEmpty &&
        storedDisplayName.isNotEmpty &&
        requestedDisplayName != storedDisplayName) {
      return <LocalCalendarItem>[];
    }

    final List<Map<String, dynamic>> existingBindingRows = await db.query(
      'local_bindings',
      columns: ['local_collection_id'],
      where: 'remote_collection_id = ?',
      whereArgs: [remoteCollectionId],
    );
    for (final row in existingBindingRows) {
      final String boundLocalId = _normalizeLocalCollectionId(row['local_collection_id']);
      if (boundLocalId.isNotEmpty && nativeCalendarIds.contains(boundLocalId)) {
        return <LocalCalendarItem>[];
      }
    }

    final String loginName = (MMKVUtils.instance.getString(AppConstant.loginNameKey) ?? '').trim();
    if (loginName.isEmpty) {
      return <LocalCalendarItem>[];
    }

    final String remoteAccountName = _normalizeAccountName(remoteRow['account_name']);
    if (remoteAccountName.trim() != loginName) {
      return <LocalCalendarItem>[];
    }

    final List<Map<String, dynamic>> connectedRows = await db.rawQuery('''
      SELECT lb.local_collection_id
      FROM local_bindings lb
      WHERE lb.local_collection_id IS NOT NULL
        AND lb.local_collection_id != ''
    ''');
    final Set<String> connectedLocalIds = {
      for (final row in connectedRows) _normalizeLocalCollectionId(row['local_collection_id'])
    }..remove('');

    final List<Map<String, dynamic>> remoteProvisionedRows = await db.rawQuery('''
      SELECT lb.local_collection_id
      FROM local_bindings lb
      WHERE lb.binding_role = ?
        AND lb.local_collection_id IS NOT NULL
        AND lb.local_collection_id != ''
    ''', [SyncBindingRole.mirror]);
    final Set<String> remoteProvisionedLocalIds = {
      for (final row in remoteProvisionedRows) _normalizeLocalCollectionId(row['local_collection_id'])
    }..remove('');

    final List<LocalCalendarItem> sortedCandidates = rawCalendars
        .whereType<PlatformCalendar>()
        .where((calendar) => calendar.supportsEvents != false)
        .map((calendar) {
          final String id = _normalizeLocalCollectionId(calendar.id);
          if (id.isEmpty) {
            return null;
          }
          if (connectedLocalIds.contains(id) || remoteProvisionedLocalIds.contains(id)) {
            return null;
          }

          final String normalizedAccountType = (calendar.accountType ?? '').trim().toLowerCase();
          if (normalizedAccountType == AppConstant.calendarAccountType) {
            return null;
          }
          if (calendar.isSubscription == true) {
            return null;
          }
          if (calendar.isReadOnly == true) {
            return null;
          }

          final String accountName = _normalizeAccountName(calendar.accountName);
          final String name =
              (calendar.name != null && calendar.name!.isNotEmpty) ? calendar.name! : 'Untitled calendar';
          final LocalCalendarItem item = _asScoringItem(id, name, accountName, calendar);
          item.relinkConfidence = _scoreCandidateProviderHint(remoteRow, item);
          return item;
        })
        .whereType<LocalCalendarItem>()
        .toList()
      ..sort((a, b) {
        final int confidenceCompare = b.relinkConfidence.compareTo(a.relinkConfidence);
        if (confidenceCompare != 0) {
          return confidenceCompare;
        }
        return a.name.toLowerCase().compareTo(b.name.toLowerCase());
      });

    return sortedCandidates;
  }

  Future<List<LocalCalendarItem>> _findHighConfidenceRelinkCandidatesForRemote({
    required int remoteCollectionId,
    required String remoteDisplayName,
    required String remotePath,
    bool requestPermission = true,
    bool silentOnPermissionFailure = false,
  }) async {
    final List<LocalCalendarItem> candidates = await _findPossibleRelinkCandidatesForRemote(
      remoteCollectionId: remoteCollectionId,
      remoteDisplayName: remoteDisplayName,
      remotePath: remotePath,
      requestPermission: requestPermission,
      silentOnPermissionFailure: silentOnPermissionFailure,
    );

    return candidates
        .where((candidate) => candidate.relinkConfidence >= _highConfidenceRelinkThreshold)
        .toList();
  }

  Future<List<Map<String, dynamic>>> _queryReusableRemoteCandidatesForLocal(
    LocalCalendarItem item,
  ) async {
    final String? loginName = MMKVUtils.instance.getString(AppConstant.loginNameKey);
    if (loginName == null || loginName.trim().isEmpty) {
      throw Exception('Not logged in to Calee');
    }

    final db = await DatabaseHelper.instance.database;
    final String localOriginKey = _buildLocalOriginKey(item);
    return db.rawQuery('''
      SELECT
        rc.id,
        rc.remote_path,
        rc.display_name,
        rc.origin_key,
        rc.is_subscription,
        rc.subscription_url,
        COALESCE(NULLIF(TRIM(rc.account_name), ''), 'Local') AS account_name
      FROM remote_collections rc
      LEFT JOIN local_bindings lb
        ON lb.remote_collection_id = rc.id
       AND lb.local_collection_id IS NOT NULL
       AND lb.local_collection_id != ''
      WHERE rc.collection_type = 'calendar'
        AND rc.origin_kind = 0
        AND rc.origin_key = ?
        AND lb.id IS NULL
        AND COALESCE(NULLIF(TRIM(rc.account_name), ''), '') = ?
    ''', [localOriginKey, loginName.trim()]);
  }

  Future<_ResolvedRelinkTarget?> _resolveVerifiedRelinkTargetForLocal(
    LocalCalendarItem item, {
    int? preferredRemoteCollectionId,
    String? preferredRemotePath,
    bool allowFallback = true,
    int minimumProviderHintScore = _highConfidenceRelinkThreshold,
  }) async {
    final List<Map<String, dynamic>> reuseCandidates = await _queryReusableRemoteCandidatesForLocal(item);
    if (reuseCandidates.isEmpty) {
      return null;
    }

    final String normalizedPreferredRemotePath = CaleeServerService.normalizeRemotePath(preferredRemotePath ?? '');
    final bool hasPreferredRemote =
        preferredRemoteCollectionId != null || normalizedPreferredRemotePath.isNotEmpty;
    final List<_RankedReuseCandidate> rankedCandidates = reuseCandidates
        .map((candidate) => _RankedReuseCandidate(
              raw: candidate,
              providerHintScore: _scoreCandidateProviderHint(candidate, item),
            ))
        .toList()
      ..sort((a, b) => b.providerHintScore.compareTo(a.providerHintScore));

    _RankedReuseCandidate? preferredCandidate;
    for (final _RankedReuseCandidate ranked in rankedCandidates) {
      final Map<String, dynamic> candidate = ranked.raw;
      final int? candidateId = candidate['id'] as int?;
      final String normalizedCandidatePath =
          CaleeServerService.normalizeRemotePath(candidate['remote_path']?.toString() ?? '');
      final bool matchesPreferred =
          (preferredRemoteCollectionId != null && candidateId == preferredRemoteCollectionId) ||
          (normalizedPreferredRemotePath.isNotEmpty &&
              normalizedCandidatePath.isNotEmpty &&
              normalizedCandidatePath == normalizedPreferredRemotePath);
      if (matchesPreferred) {
        preferredCandidate = ranked;
        break;
      }
    }

    if (hasPreferredRemote && preferredCandidate == null) {
      return null;
    }
    if (preferredCandidate != null) {
      rankedCandidates.remove(preferredCandidate);
      rankedCandidates.insert(0, preferredCandidate);
    }

    bool preferredCheckedAndFailed = false;
    for (final _RankedReuseCandidate ranked in rankedCandidates) {
      final Map<String, dynamic> candidate = ranked.raw;
      final String candidatePath = (candidate['remote_path'] ?? '').toString();
      if (candidatePath.isEmpty) {
        if (identical(ranked, preferredCandidate)) {
          preferredCheckedAndFailed = true;
          if (!allowFallback) {
            return null;
          }
        }
        continue;
      }
      if (ranked.providerHintScore < minimumProviderHintScore) {
        if (identical(ranked, preferredCandidate)) {
          preferredCheckedAndFailed = true;
          if (!allowFallback) {
            return null;
          }
        }
        continue;
      }

      final bool candidateIsSubscription =
          candidate['is_subscription'] == 1 || candidate['is_subscription'] == true;
      final RelinkVerificationResult verifyResult = await _relinkVerifier.verify(
        remotePath: candidatePath,
        localCalendarId: item.id,
        isSubscription: candidateIsSubscription,
      );
      if (verifyResult.outcome == RelinkVerificationOutcome.passed) {
        final String remoteDisplayName = (candidate['display_name'] ?? '').toString().trim().isNotEmpty
            ? (candidate['display_name'] ?? '').toString().trim()
            : candidatePath;
        return _ResolvedRelinkTarget(
          remoteCollectionId: candidate['id'] as int,
          remotePath: candidatePath,
          remoteDisplayName: remoteDisplayName,
          providerHintScore: ranked.providerHintScore,
          verificationOutcome: verifyResult.outcome,
          verificationConfidenceScore: verifyResult.confidenceScore,
        );
      }

      if (identical(ranked, preferredCandidate)) {
        preferredCheckedAndFailed = true;
        if (!allowFallback) {
          return null;
        }
      }
    }

    if (preferredCheckedAndFailed && !allowFallback) {
      return null;
    }
    return null;
  }

  Future<void> refreshLocalCalendars() async {
    final int refreshVersion = ++_refreshVersion;
    try {
      isLoading.value = true;

      final bool hasPermission = await _nativeApi.requestPermission(false);
      if (!hasPermission) {
        calendarGroups.clear();
        Get.snackbar('Permission required', 'Calendar access is required to load local calendars.');
        return;
      }

      final db = await DatabaseHelper.instance.database;
      final List<Map<String, dynamic>> rows = await db.rawQuery('''
        SELECT lb.local_collection_id
        FROM local_bindings lb
        WHERE lb.local_collection_id IS NOT NULL
          AND lb.local_collection_id != ''
      ''');
      final Set<String> connectedLocalIds = {
        for (final row in rows) _normalizeLocalCollectionId(row['local_collection_id'])
      }..remove('');

      final String? loginName = MMKVUtils.instance.getString(AppConstant.loginNameKey);
      final List<Map<String, dynamic>> relinkCandidates =
          (loginName == null || loginName.trim().isEmpty)
          ? <Map<String, dynamic>>[]
          : await db.rawQuery('''
              SELECT
                rc.id,
                rc.remote_path,
                rc.display_name,
                rc.origin_key,
                rc.is_subscription,
                rc.subscription_url,
                COALESCE(NULLIF(TRIM(rc.account_name), ''), 'Local') AS account_name
              FROM remote_collections rc
              LEFT JOIN local_bindings lb
                ON lb.remote_collection_id = rc.id
               AND lb.local_collection_id IS NOT NULL
               AND lb.local_collection_id != ''
              WHERE rc.collection_type = 'calendar'
                AND rc.origin_kind = 0
                AND lb.id IS NULL
                AND COALESCE(NULLIF(TRIM(rc.account_name), ''), '') = ?
            ''', [loginName.trim()]);

      final List<Map<String, dynamic>> remoteProvisionedRows = await db.rawQuery('''
        SELECT lb.local_collection_id
        FROM local_bindings lb
        WHERE lb.binding_role = ?
          AND lb.local_collection_id IS NOT NULL
          AND lb.local_collection_id != ''
      ''', [SyncBindingRole.mirror]);
      final Set<String> remoteProvisionedLocalIds = {
        for (final row in remoteProvisionedRows) _normalizeLocalCollectionId(row['local_collection_id'])
      }..remove('');

      final List<PlatformCalendar?> rawCalendars = await _nativeApi.getCalendars();
      final Map<String, List<LocalCalendarItem>> grouped = {};
      final Set<String> seenIds = <String>{};
      final Map<String, LocalCalendarItem> dedupedByFingerprint = <String, LocalCalendarItem>{};

      for (final PlatformCalendar calendar in rawCalendars.whereType<PlatformCalendar>()) {
        if (calendar.supportsEvents == false) {
          continue;
        }

        final String normalizedAccountType = (calendar.accountType ?? '').trim().toLowerCase();
        if (normalizedAccountType == AppConstant.calendarAccountType) {
          continue;
        }

        final String id = _normalizeLocalCollectionId(calendar.id);
        if (id.isEmpty) {
          continue;
        }

        if (remoteProvisionedLocalIds.contains(id)) {
          continue;
        }

        final String accountName = _normalizeAccountName(calendar.accountName);

        final String normalizedName =
            (calendar.name != null && calendar.name!.isNotEmpty) ? calendar.name! : 'Untitled calendar';
        final bool isConnected = connectedLocalIds.contains(id);
        final item = LocalCalendarItem(
          id: id,
          name: normalizedName,
          accountName: accountName,
          accountType: calendar.accountType,
          ownerAccount: calendar.ownerAccount,
          calSync1: calendar.calSync1,
          color: calendar.color ?? '#808080',
          isReadOnly: calendar.isReadOnly ?? false,
          eventCount: 0,
          isSubscription: calendar.isSubscription ?? false,
          subscriptionUrl: calendar.subscriptionUrl,
          isConnected: isConnected,
          canRelink: false,
          relinkConfidence: 0,
        );

        if (!seenIds.add(id)) {
          continue;
        }

        final String fingerprint = _calendarFingerprint(item);
        final LocalCalendarItem? existing = dedupedByFingerprint[fingerprint];
        if (existing == null) {
          dedupedByFingerprint[fingerprint] = item;
          continue;
        }

        if (!existing.isConnected && item.isConnected) {
          dedupedByFingerprint[fingerprint] = item;
          continue;
        }

        if (existing.isConnected == item.isConnected && item.eventCount > existing.eventCount) {
          dedupedByFingerprint[fingerprint] = item;
        }
      }

      for (final item in dedupedByFingerprint.values) {
        grouped.putIfAbsent(item.accountName, () => []).add(item);
      }

      final List<LocalCalendarGroup> nextGroups = grouped.entries
          .map((entry) => LocalCalendarGroup(accountName: entry.key, calendars: entry.value))
          .toList()
        ..sort((a, b) => a.accountName.toLowerCase().compareTo(b.accountName.toLowerCase()));

      final List<LocalCalendarItem> allItems = [
        for (final group in nextGroups) ...group.calendars,
      ];
      await _primeRelinkPreviewConfidence(
        refreshVersion: refreshVersion,
        calendars: allItems,
        relinkCandidates: relinkCandidates,
      );

      calendarGroups.assignAll(nextGroups);
      unawaited(
        _populateCalendarMetadata(
          refreshVersion: refreshVersion,
          calendars: allItems,
          relinkCandidates: relinkCandidates,
        ),
      );
    } catch (e) {
      debugPrint('[ERROR] Failed to load local calendars: $e');
      Get.snackbar('Error', 'Failed to load local calendars');
    } finally {
      isLoading.value = false;
    }
  }

  Future<void> _populateCalendarMetadata({
    required int refreshVersion,
    required List<LocalCalendarItem> calendars,
    required List<Map<String, dynamic>> relinkCandidates,
  }) async {
    final DateTime now = DateTime.now();
    final int rangeStart = now.subtract(const Duration(days: 365)).millisecondsSinceEpoch;
    final int rangeEnd = now.add(const Duration(days: 365)).millisecondsSinceEpoch;

    for (int start = 0; start < calendars.length; start += _metadataBatchSize) {
      if (refreshVersion != _refreshVersion || isClosed) {
        return;
      }

      final int end = (start + _metadataBatchSize < calendars.length)
          ? start + _metadataBatchSize
          : calendars.length;
      final List<LocalCalendarItem> batch = calendars.sublist(start, end);

      await Future.wait(
        batch.map(
          (item) => _populateCalendarItemMetadata(
            item: item,
            rangeStart: rangeStart,
            rangeEnd: rangeEnd,
            relinkCandidates: relinkCandidates,
          ),
        ),
      );

      if (refreshVersion != _refreshVersion || isClosed) {
        return;
      }

      calendarGroups.refresh();
    }
  }

  Future<void> _primeRelinkPreviewConfidence({
    required int refreshVersion,
    required List<LocalCalendarItem> calendars,
    required List<Map<String, dynamic>> relinkCandidates,
  }) async {
    if (relinkCandidates.isEmpty) {
      for (final item in calendars) {
        item.relinkConfidence = 0;
        item.canRelink = false;
      }
      return;
    }

    for (int start = 0; start < calendars.length; start += _metadataBatchSize) {
      if (refreshVersion != _refreshVersion || isClosed) {
        return;
      }

      final int end = (start + _metadataBatchSize < calendars.length)
          ? start + _metadataBatchSize
          : calendars.length;
      final List<LocalCalendarItem> batch = calendars.sublist(start, end);

      await Future.wait(
        batch.map((item) => _applyRelinkPreviewConfidence(item, relinkCandidates)),
      );
    }
  }

  Future<void> _populateCalendarItemMetadata({
    required LocalCalendarItem item,
    required int rangeStart,
    required int rangeEnd,
    required List<Map<String, dynamic>> relinkCandidates,
  }) async {
    try {
      final List<PlatformItem?> events = await _nativeApi.getEvents(item.id, rangeStart, rangeEnd);
      item.eventCount = events.whereType<PlatformItem>().where((event) => event.isTask != true).length;
    } catch (_) {
      item.eventCount = 0;
    }

    await _applyRelinkPreviewConfidence(item, relinkCandidates);
  }

  Future<void> _applyRelinkPreviewConfidence(
    LocalCalendarItem item,
    List<Map<String, dynamic>> relinkCandidates,
  ) {
    if (relinkCandidates.isEmpty) {
      item.relinkConfidence = 0;
      item.canRelink = false;
      return Future<void>.value();
    }

    final int relinkConfidence = _computeRelinkPreviewConfidence(
      item: item,
      relinkCandidates: relinkCandidates,
    );
    item.relinkConfidence = relinkConfidence;
    item.canRelink = !item.isConnected && relinkConfidence >= _highConfidenceRelinkThreshold;
    return Future<void>.value();
  }

  Future<void> relinkRemoteToSelectedLocal(LocalCalendarItem item) async {
    final String? reviewPath = reviewRemotePath.value;
    if (!isReviewMode ||
        reviewRemoteCollectionId.value == null ||
        reviewPath == null ||
        reviewPath.trim().isEmpty ||
        reviewRemoteDisplayName.value == null) {
      Get.snackbar('Error', 'Re-link review context is unavailable');
      return;
    }

    if (connectingCalendarIds.contains(item.id)) {
      return;
    }

    connectingCalendarIds.add(item.id);
    calendarGroups.refresh();
    reviewCandidates.refresh();

    try {
      final int currentReviewRemoteCollectionId = reviewRemoteCollectionId.value!;
      final String currentReviewPath = reviewPath.trim();
      final String currentReviewRemoteDisplayName = (reviewRemoteDisplayName.value ?? '').trim();

      final _ResolvedRelinkTarget? resolvedTarget = await _resolveVerifiedRelinkTargetForLocal(
        item,
        preferredRemoteCollectionId: currentReviewRemoteCollectionId,
        preferredRemotePath: currentReviewPath,
        allowFallback: true,
      );
      if (resolvedTarget == null) {
        Get.snackbar(
          'Unable to re-link',
          'No verified Calee calendar match was found for this device calendar.',
        );
        return;
      }

      final bool matchesCurrentReviewRemote =
          resolvedTarget.remoteCollectionId == currentReviewRemoteCollectionId ||
          CaleeServerService.normalizeRemotePath(resolvedTarget.remotePath) ==
              CaleeServerService.normalizeRemotePath(currentReviewPath);

      if (!matchesCurrentReviewRemote) {
        final bool redirected = await _confirmReviewModeRedirectedRelinkTarget(
          item,
          currentReviewRemoteDisplayName: currentReviewRemoteDisplayName,
          resolvedRemoteDisplayName: resolvedTarget.remoteDisplayName,
        );
        if (!redirected) {
          return;
        }
      }

      final bool confirmed = await _confirmReviewModeRelinkTarget(
        item,
        remoteDisplayName: resolvedTarget.remoteDisplayName,
      );
      if (!confirmed) {
        return;
      }

      final db = await DatabaseHelper.instance.database;
      await db.transaction((txn) async {
        final String localOriginKey = _buildLocalOriginKey(item);
        final String storedAccountName =
            MMKVUtils.instance.getString(AppConstant.calendarAccountNameKey) ?? '';
        final String loginName = MMKVUtils.instance.getString(AppConstant.loginNameKey) ?? '';
        final String accountName = storedAccountName.isNotEmpty ? storedAccountName : loginName;
        final int now = DateTime.now().millisecondsSinceEpoch;

        await txn.update(
          'remote_collections',
          {
            'account_name': accountName,
            'origin_key': localOriginKey,
            'remote_path': resolvedTarget.remotePath,
            'display_name': resolvedTarget.remoteDisplayName,
          },
          where: 'id = ?',
          whereArgs: [resolvedTarget.remoteCollectionId],
        );

        await txn.insert(
          'collection_states',
          {
            'remote_collection_id': resolvedTarget.remoteCollectionId,
            'sync_gate_reason': SyncGateReason.safeFirstSync,
            'updated_at': now,
          },
          conflictAlgorithm: ConflictAlgorithm.ignore,
        );
        await txn.update(
          'collection_states',
          {
            'remote_collection_id': resolvedTarget.remoteCollectionId,
            'sync_gate_reason': SyncGateReason.safeFirstSync,
            'updated_at': now,
          },
          where: 'remote_collection_id = ?',
          whereArgs: [resolvedTarget.remoteCollectionId],
        );

        await txn.insert(
          'local_bindings',
          {
            'remote_collection_id': resolvedTarget.remoteCollectionId,
            'local_collection_id': item.id.trim(),
            'binding_role': SyncBindingRole.ownerLink,
            'created_at': now,
            'updated_at': now,
          },
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      });

      await _refreshMainCalendarList();
      if (Get.isOverlaysOpen == true) {
        Get.closeAllSnackbars();
      }
      if (Get.key.currentState?.canPop() == true) {
        Get.back<void>();
      }
    } catch (e) {
      debugPrint('[ERROR] Failed to relink selected local calendar to remote: $e');
      Get.snackbar('Error', 'Unable to re-link this calendar');
    } finally {
      connectingCalendarIds.remove(item.id);
      calendarGroups.refresh();
      reviewCandidates.refresh();
    }
  }

  Future<void> linkCalendar(
    LocalCalendarItem item,
    bool linkRequested, {
    bool returnToCalendarListAfterConnect = false,
  }) async {
    if (connectingCalendarIds.contains(item.id)) {
      return;
    }

    connectingCalendarIds.add(item.id);
    final bool previousConnectionState = item.isConnected;
    if (linkRequested) {
      item.isConnected = true;
    }
    calendarGroups.refresh();

    try {
      final db = await DatabaseHelper.instance.database;

      String? remotePath;
      String? newRemoteOriginKey;
      final String localOriginKey = _buildLocalOriginKey(item);
      bool relinkConfirmationDeclined = false;
      if (linkRequested) {
        final List<Map<String, dynamic>> existingRows = await db.rawQuery('''
          SELECT rc.origin_key, rc.remote_path
          FROM local_bindings lb
          INNER JOIN remote_collections rc ON rc.id = lb.remote_collection_id
          WHERE lb.local_collection_id = ?
          LIMIT 1
        ''', [item.id]);

        final String existingOriginKey = existingRows.isNotEmpty
            ? (existingRows.first['origin_key']?.toString() ?? '')
            : '';
        final String existingRemotePath = existingRows.isNotEmpty
            ? (existingRows.first['remote_path']?.toString() ?? '')
            : '';
        if (existingRemotePath.isNotEmpty &&
            existingOriginKey.isNotEmpty &&
            existingOriginKey == localOriginKey &&
            !item.canRelink) {
          remotePath = existingRemotePath;
        } else {
          final String? loginName = MMKVUtils.instance.getString(AppConstant.loginNameKey);
          if (loginName == null || loginName.trim().isEmpty) {
            throw Exception('Not logged in to Calee');
          }

          try {
            final _ResolvedRelinkTarget? resolvedTarget = await _resolveVerifiedRelinkTargetForLocal(item);
            if (resolvedTarget != null) {
              final _RelinkDecision relinkDecision = await _confirmRelinkTarget(
                item,
                remoteDisplayName: resolvedTarget.remoteDisplayName,
                remotePath: resolvedTarget.remotePath,
                verifyConfidenceScore: resolvedTarget.verificationConfidenceScore,
                providerHintScore: resolvedTarget.providerHintScore,
                verificationOutcome: resolvedTarget.verificationOutcome,
              );

              if (relinkDecision == _RelinkDecision.cancel) {
                relinkConfirmationDeclined = true;
              } else if (relinkDecision == _RelinkDecision.linkCandidate) {
                remotePath = resolvedTarget.remotePath;
                await db.update(
                  'collection_states',
                  {
                    'sync_gate_reason': SyncGateReason.safeFirstSync,
                    'updated_at': DateTime.now().millisecondsSinceEpoch,
                  },
                  where: 'remote_collection_id = ?',
                  whereArgs: [resolvedTarget.remoteCollectionId],
                );
              }
            }
          } catch (e) {
            debugPrint('[RelinkVerifier] resolve_failed_transient for local=${item.id}: $e');
          }

          if (relinkConfirmationDeclined) {
            throw Exception('Relink cancelled by user');
          }

          if (remotePath == null || remotePath.isEmpty) {
            if (item.isSubscription) {
              final String? sourceUrl = item.subscriptionUrl?.trim();
              if (sourceUrl == null || sourceUrl.isEmpty) {
                throw Exception('Subscription URL is unavailable for this local calendar');
              }

              newRemoteOriginKey = localOriginKey;
              final String subscriptionCalendarId =
                  'sub_${item.id}_${DateTime.now().millisecondsSinceEpoch}';
              remotePath = await _caleeService.subscribeRemotePublicIcs(
                userId: loginName,
                calendarName: item.name,
                calendarId: subscriptionCalendarId,
                icsUrl: sourceUrl,
                originKey: newRemoteOriginKey,
              );
            } else {
              newRemoteOriginKey = localOriginKey;
              final String cloudCalendarId =
                  'local_${item.id}_${DateTime.now().millisecondsSinceEpoch}';
              remotePath = await _caleeService.createRemoteCalendar(
                userId: loginName,
                calendarName: item.name,
                calendarId: cloudCalendarId,
                color: item.color,
                origin: 'local',
                originKey: newRemoteOriginKey,
              );
            }

            if (remotePath == null || remotePath.isEmpty) {
              throw Exception(
                item.isSubscription
                    ? 'Failed to create remote subscription'
                    : 'Failed to create remote calendar',
              );
            }
          }
        }
      }

      final String storedAccountName =
          MMKVUtils.instance.getString(AppConstant.calendarAccountNameKey) ?? '';
      final String loginName = MMKVUtils.instance.getString(AppConstant.loginNameKey) ?? '';
      final String accountName = storedAccountName.isNotEmpty ? storedAccountName : loginName;
      int? remoteCollectionId;

      if (linkRequested) {
        if (remotePath == null || remotePath.isEmpty) {
          throw Exception('Missing remote path while linking calendar');
        }

        final String localCollectionId = (item.id ?? '').trim();
        if (localCollectionId.isEmpty || localCollectionId.toLowerCase() == 'null') {
          throw Exception('Invalid local calendar id while linking calendar');
        }

        await db.transaction((txn) async {
          final List<Map<String, dynamic>> remoteRows = await txn.query(
            'remote_collections',
            columns: ['id'],
            where: 'collection_type = ? AND origin_key = ?',
            whereArgs: ['calendar', localOriginKey],
            limit: 1,
          );

          if (remoteRows.isNotEmpty) {
            remoteCollectionId = remoteRows.first['id'] as int;
            final Map<String, dynamic> remoteCollectionUpdates = {
              'display_name': item.name,
              'account_name': accountName,
              'color': item.color,
              'sync_mode': 0,
              'origin_kind': item.isSubscription ? 1 : 0,
              'is_subscription': item.isSubscription ? 1 : 0,
              'subscription_url': item.subscriptionUrl,
              'remote_path': remotePath,
              'origin_key': localOriginKey,
            };
            await txn.update(
              'remote_collections',
              remoteCollectionUpdates,
              where: 'id = ?',
              whereArgs: [remoteCollectionId],
            );
          } else {
            remoteCollectionId = await txn.insert('remote_collections', {
              'account_name': accountName,
              'collection_type': 'calendar',
              'display_name': item.name,
              'color': item.color,
              'sync_mode': 0,
              'origin_kind': item.isSubscription ? 1 : 0,
              'is_subscription': item.isSubscription ? 1 : 0,
              'subscription_url': item.subscriptionUrl,
              'remote_path': remotePath,
              'origin_key': localOriginKey,
            });
          }

          final int now = DateTime.now().millisecondsSinceEpoch;
          await txn.insert(
            'collection_states',
            {
              'remote_collection_id': remoteCollectionId,
              'sync_gate_reason': SyncGateReason.safeFirstSync,
              'updated_at': now,
            },
            conflictAlgorithm: ConflictAlgorithm.ignore,
          );
          await txn.update(
            'collection_states',
            {
              'sync_gate_reason': SyncGateReason.safeFirstSync,
              'updated_at': now,
            },
            where: 'remote_collection_id = ?',
            whereArgs: [remoteCollectionId],
          );

          await txn.insert(
            'local_bindings',
            {
              'remote_collection_id': remoteCollectionId,
              'local_collection_id': localCollectionId,
              'binding_role': SyncBindingRole.ownerLink,
              'created_at': now,
              'updated_at': now,
            },
            conflictAlgorithm: ConflictAlgorithm.replace,
          );
        });
      } else {
        await db.update(
          'remote_collections',
          {
            'display_name': item.name,
            'account_name': accountName,
            'color': item.color,
            'sync_mode': 0,
            'is_subscription': item.isSubscription ? 1 : 0,
            'subscription_url': item.subscriptionUrl,
          },
          where: 'id IN (SELECT remote_collection_id FROM local_bindings WHERE local_collection_id = ?)',
          whereArgs: [item.id],
        );
      }

      if (linkRequested && returnToCalendarListAfterConnect) {
        await _refreshMainCalendarList();
        if (Get.isOverlaysOpen == true) {
          Get.closeAllSnackbars();
        }
        if (Get.key.currentState?.canPop() == true) {
          Get.back<void>();
        }
      }
    } catch (e) {
      item.isConnected = previousConnectionState;
      calendarGroups.refresh();
      debugPrint('[ERROR] Failed to update local calendar switch: $e');
      Get.snackbar('Error', 'Unable to update calendar link state');
    } finally {
      connectingCalendarIds.remove(item.id);
    }
  }


  int _scoreCandidateProviderHint(Map<String, dynamic> candidate, LocalCalendarItem item) {
    const int displayNameExactMatchWeight = 40;
    const int displayNamePartialMatchWeight = 25;
    const int originKeyMatchWeight = 40;
    const int accountNameMatchWeight = 20;

    int score = 0;

    final String displayName = (candidate['display_name'] ?? '').toString().trim().toLowerCase();
    final String localName = item.name.trim().toLowerCase();
    if (displayName.isNotEmpty && localName.isNotEmpty) {
      if (displayName == localName) {
        score += displayNameExactMatchWeight;
      } else if (displayName.contains(localName) || localName.contains(displayName)) {
        score += displayNamePartialMatchWeight;
      }
    }

    final String originKey = (candidate['origin_key'] ?? '').toString().trim().toLowerCase();
    final String localOriginKey = _buildLocalOriginKey(item).trim().toLowerCase();
    if (originKey.isNotEmpty && localOriginKey.isNotEmpty && originKey == localOriginKey) {
      score += originKeyMatchWeight;
    }

    if (_normalizeAccountName(candidate['account_name']) == _normalizeAccountName(item.accountName)) {
      score += accountNameMatchWeight;
    }

    return score.clamp(0, 100);
  }

  int _computeRelinkPreviewConfidence({
    required LocalCalendarItem item,
    required List<Map<String, dynamic>> relinkCandidates,
  }) {
    int bestConfidence = 0;
    final List<_RankedReuseCandidate> rankedCandidates = relinkCandidates
        .map((candidate) => _RankedReuseCandidate(
              raw: candidate,
              providerHintScore: _scoreCandidateProviderHint(candidate, item),
            ))
        .toList()
      ..sort((a, b) => b.providerHintScore.compareTo(a.providerHintScore));

    for (final _RankedReuseCandidate ranked in rankedCandidates.take(3)) {
      final int providerScore = ranked.providerHintScore;
      if (providerScore > bestConfidence) {
        bestConfidence = providerScore;
      }
    }

    return bestConfidence.clamp(0, 100);
  }

  String _normalizeAccountName(Object? rawAccountName) {
    final String normalized = (rawAccountName ?? '').toString().trim();
    return normalized.isEmpty ? 'Local' : normalized;
  }

  String _normalizeLocalCollectionId(Object? rawId) {
    final String normalized = (rawId ?? '').toString().trim();
    if (normalized.isEmpty || normalized.toLowerCase() == 'null') {
      return '';
    }
    return normalized;
  }



  String _normalizeOriginKeyPart(String? value) {
    final String rawValue = (value ?? '').trim();
    final String normalizedSource = looksLikeIosMirrorTitle(rawValue)
        ? (parseIosMirrorTitle(rawValue)?.baseName ?? rawValue)
        : rawValue;
    return normalizedSource.toLowerCase().replaceAll(RegExp(r'\s+'), ' ');
  }

  String _buildLocalOriginKey(LocalCalendarItem item) {
    final String accountType = _normalizeOriginKeyPart(item.accountType);
    final String accountName = _normalizeOriginKeyPart(item.accountName);
    final String ownerAccount = _normalizeOriginKeyPart(item.ownerAccount);
    final String calSync1 = _normalizeOriginKeyPart(item.calSync1);
    final String displayName = _normalizeOriginKeyPart(item.name);

    if (ownerAccount.isNotEmpty) {
      return '$accountType|$accountName|$ownerAccount';
    }
    if (calSync1.isNotEmpty) {
      return '$accountType|$accountName|$calSync1';
    }
    return '$accountType|$accountName|$displayName';
  }

  String _calendarFingerprint(LocalCalendarItem item) {
    return [
      item.accountName.trim().toLowerCase(),
      (item.accountType ?? '').trim().toLowerCase(),
      item.name.trim().toLowerCase(),
      item.color.trim().toLowerCase(),
      item.isReadOnly ? 'ro' : 'rw',
      item.isSubscription ? 'sub' : 'normal',
      (item.subscriptionUrl ?? '').trim().toLowerCase(),
    ].join('|');
  }

  LocalCalendarItem _asScoringItem(
    String id,
    String name,
    String accountName,
    PlatformCalendar calendar,
  ) {
    return LocalCalendarItem(
      id: id,
      name: name,
      accountName: accountName,
      accountType: calendar.accountType,
      ownerAccount: calendar.ownerAccount,
      calSync1: calendar.calSync1,
      color: calendar.color ?? '#808080',
      isReadOnly: calendar.isReadOnly ?? false,
      eventCount: 0,
      isSubscription: calendar.isSubscription ?? false,
      subscriptionUrl: calendar.subscriptionUrl,
      isConnected: false,
      canRelink: false,
      relinkConfidence: 0,
    );
  }

  Future<_RelinkDecision> _confirmRelinkTarget(
    LocalCalendarItem item, {
    required String remoteDisplayName,
    required String remotePath,
    required int? verifyConfidenceScore,
    required int providerHintScore,
    required RelinkVerificationOutcome verificationOutcome,
  }) async {
    final bool canRelink = verificationOutcome == RelinkVerificationOutcome.passed;
    final _RelinkDecision? decision = await Get.dialog<_RelinkDecision>(
      AlertDialog(
        title: Text(
          switch (verificationOutcome) {
            RelinkVerificationOutcome.unavailable => 'Verification unavailable',
            RelinkVerificationOutcome.passed => 'Confirm relink',
            RelinkVerificationOutcome.failed => 'Possible mismatch',
          },
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Relink "${item.name}" to "$remoteDisplayName"?'),
            const SizedBox(height: 12),
            Text(
              verifyConfidenceScore == null
                  ? 'Event verification confidence (recent window): Unavailable'
                  : 'Event verification confidence (recent window): ${verifyConfidenceScore.clamp(0, 100)}%',
            ),
            Text(
              _verificationConfidenceExplanation(verifyConfidenceScore),
              style: const TextStyle(color: Color(0xFF4B5563), fontSize: 12),
            ),
            Text('Collection/provider match confidence: ${providerHintScore.clamp(0, 100)}%'),
            Text(
              _providerHintConfidenceExplanation(providerHintScore),
              style: const TextStyle(color: Color(0xFF4B5563), fontSize: 12),
            ),
            const Text('Verification scope: bounded to the most recent 60 days of events'),
            Text('Account: ${item.accountName}'),
            Text('Remote path: $remotePath'),
            const SizedBox(height: 8),
            Text(
              verificationOutcome == RelinkVerificationOutcome.passed
                  ? 'Verification passed, so relinking can proceed. You can still create a new remote instead.'
                  : verificationOutcome == RelinkVerificationOutcome.unavailable
                  ? 'Relinking cannot proceed because event verification did not complete. Create a new remote calendar instead.'
                  : 'Relinking cannot proceed because verification did not pass. Create a new remote calendar instead.',
              style: const TextStyle(color: Color(0xFF4B5563), fontSize: 12),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Get.back<_RelinkDecision>(result: _RelinkDecision.cancel),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Get.back<_RelinkDecision>(result: _RelinkDecision.createNewRemote),
            child: const Text('Create new remote'),
          ),
          if (canRelink)
            ElevatedButton(
              onPressed: () => Get.back<_RelinkDecision>(result: _RelinkDecision.linkCandidate),
              child: const Text('Link this remote'),
            ),
        ],
      ),
      barrierDismissible: false,
    );
    return decision ?? _RelinkDecision.cancel;
  }

  Future<bool> _confirmReviewModeRelinkTarget(
    LocalCalendarItem item, {
    required String remoteDisplayName,
  }) async {
    final bool? confirmed = await Get.dialog<bool>(
      AlertDialog(
        title: const Text('Confirm re-link'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Re-link "${item.name}" to "$remoteDisplayName"?'),
            const SizedBox(height: 12),
            Text('Device calendar: ${item.name}'),
            Text('Calee calendar: $remoteDisplayName'),
            Text('Account: ${item.accountName}'),
            const SizedBox(height: 12),
            const Text(
              'Verification passed for this device calendar.',
              style: TextStyle(color: Color(0xFF4B5563), fontSize: 12),
            ),
            const SizedBox(height: 4),
            const Text(
              'This looks like the strongest match on this device.',
              style: TextStyle(color: Color(0xFF4B5563), fontSize: 12),
            ),
            const SizedBox(height: 4),
            const Text(
              'This will reconnect the selected device calendar to the existing Calee calendar.',
              style: TextStyle(color: Color(0xFF4B5563), fontSize: 12),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Get.back<bool>(result: false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Get.back<bool>(result: true),
            child: const Text('Re-link this calendar'),
          ),
        ],
      ),
      barrierDismissible: false,
    );
    return confirmed == true;
  }

  Future<bool> _confirmReviewModeRedirectedRelinkTarget(
    LocalCalendarItem item, {
    required String currentReviewRemoteDisplayName,
    required String resolvedRemoteDisplayName,
  }) async {
    final bool? confirmed = await Get.dialog<bool>(
      AlertDialog(
        title: const Text('Use verified calendar?'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('This device calendar did not verify against "$currentReviewRemoteDisplayName".'),
            const SizedBox(height: 8),
            Text('It did verify against "$resolvedRemoteDisplayName".'),
            const SizedBox(height: 8),
            const Text('Re-link to the verified Calee calendar instead?'),
            const SizedBox(height: 12),
            Text('Device calendar: ${item.name}'),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Get.back<bool>(result: false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Get.back<bool>(result: true),
            child: const Text('Re-link to verified calendar'),
          ),
        ],
      ),
      barrierDismissible: false,
    );
    return confirmed == true;
  }

  Future<void> _refreshMainCalendarList() async {
    if (!Get.isRegistered<CalendarPageController>()) {
      return;
    }

    final CalendarPageController dashboardController = Get.find<CalendarPageController>();
    await dashboardController.reloadCalendars();
  }

  String _verificationConfidenceExplanation(int? confidenceScore) {
    if (confidenceScore == null) {
      return 'Unavailable: verification could not derive confidence from comparable events in the recent 60-day window.';
    }
    final int score = confidenceScore.clamp(0, 100);
    if (score < 50) {
      return 'Low score: only a small portion of event titles/times match.';
    }
    if (score < 90) {
      return 'Medium score: some events match, but there are notable differences.';
    }
    return 'High score: most recent events match closely.';
  }

  String _providerHintConfidenceExplanation(int confidenceScore) {
    final int score = confidenceScore.clamp(0, 100);
    if (score < 40) {
      return 'Weak match: collection metadata alignment is low.';
    }
    if (score < 80) {
      return 'Moderate match: collection metadata is partially aligned.';
    }
    return 'Strong match: collection metadata aligns well.';
  }
}

class _ResolvedRelinkTarget {
  final int remoteCollectionId;
  final String remotePath;
  final String remoteDisplayName;
  final int providerHintScore;
  final RelinkVerificationOutcome verificationOutcome;
  final int? verificationConfidenceScore;

  const _ResolvedRelinkTarget({
    required this.remoteCollectionId,
    required this.remotePath,
    required this.remoteDisplayName,
    required this.providerHintScore,
    required this.verificationOutcome,
    required this.verificationConfidenceScore,
  });
}

class _RankedReuseCandidate {
  final Map<String, dynamic> raw;
  final int providerHintScore;

  const _RankedReuseCandidate({required this.raw, required this.providerHintScore});
}

enum _RelinkDecision {
  linkCandidate,
  createNewRemote,
  cancel,
}
