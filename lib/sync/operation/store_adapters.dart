import 'package:caleesync/core/platform/pigeon/calendar_api.g.dart';
import 'package:caleesync/services/calee_server_service.dart';

class AdapterMutationResult {
  final String stableKey;
  final String? remoteHref;
  final String? token;
  final String? localId;

  const AdapterMutationResult({
    required this.stableKey,
    this.remoteHref,
    this.token,
    this.localId,
  });
}

class AdapterItemSnapshot {
  final String stableKey;
  final String? remoteHref;
  final String? token;
  final String? localId;
  final Map<String, dynamic> raw;

  const AdapterItemSnapshot({
    required this.stableKey,
    required this.raw,
    this.remoteHref,
    this.token,
    this.localId,
  });
}

class AdapterSnapshot {
  final Map<String, AdapterItemSnapshot> byStableKey;
  final bool fetchSucceeded;
  final int statusCode;
  final bool parseProducedZeroEvents;

  const AdapterSnapshot({
    required this.byStableKey,
    this.fetchSucceeded = true,
    this.statusCode = 200,
    this.parseProducedZeroEvents = false,
  });
}

class LocalStoreAdapter {
  LocalStoreAdapter({
    required this.nativeApi,
    required this.localCalendarId,
  });

  final NativeCalendarApi nativeApi;
  final String localCalendarId;

  String _stableKeyFromUidOrLocalId(String? uid, String? localId) {
    final normalizedUid = (uid ?? '').trim();
    if (normalizedUid.isNotEmpty) return normalizedUid;
    return 'local_${localId ?? ''}';
  }

  Future<AdapterSnapshot> getSnapshot({
    int? startMs,
    int? endMs,
  }) async {
    final int start = startMs ?? DateTime.now().subtract(const Duration(days: 365)).millisecondsSinceEpoch;
    final int end = endMs ?? DateTime.now().add(const Duration(days: 730)).millisecondsSinceEpoch;
    final List<PlatformItem?> events = await nativeApi.getEvents(localCalendarId, start, end);
    final Map<String, AdapterItemSnapshot> byStableKey = {};

    for (final item in events.whereType<PlatformItem>()) {
      final stableKey = _stableKeyFromUidOrLocalId(item.uid, item.localId);
      byStableKey[stableKey] = AdapterItemSnapshot(
        stableKey: stableKey,
        localId: item.localId,
        token: (item.lastModified ?? 0).toString(),
        raw: {
          'uid': item.uid,
          'title': item.title,
          'notes': item.notes,
          'startTime': item.startTime,
          'endTime': item.endTime,
          'lastModified': item.lastModified,
          'localId': item.localId,
          'item': item,
        },
      );
    }

    return AdapterSnapshot(byStableKey: byStableKey);
  }

  Future<AdapterMutationResult?> create(Map<String, dynamic> item) async {
    return _upsert(item: item, token: null);
  }

  Future<AdapterMutationResult?> update(Map<String, dynamic> item, String? token) async {
    return _upsert(item: item, token: token);
  }

  Future<AdapterMutationResult?> _upsert({
    required Map<String, dynamic> item,
    String? token,
  }) async {
    final String? eventId = await nativeApi.createOrUpdateEvent(
      CalendarEventRequest(
        calendarId: localCalendarId,
        eventId: item['localId']?.toString(),
        uid: item['uid']?.toString(),
        title: item['title']?.toString() ?? 'Untitled',
        start: (item['startTime'] as int?) ?? 0,
        end: (item['endTime'] as int?) ?? 0,
        notes: item['notes']?.toString(),
      ),
    );

    if (eventId == null) return null;
    final String stableKey = _stableKeyFromUidOrLocalId(item['uid']?.toString(), eventId);
    return AdapterMutationResult(
      stableKey: stableKey,
      localId: eventId,
      token: token ?? DateTime.now().millisecondsSinceEpoch.toString(),
    );
  }

  Future<bool> delete(String idOrHref, [String? token]) async {
    if (idOrHref.isEmpty) return false;
    return nativeApi.deleteEvent(idOrHref);
  }
}

class RemoteStoreAdapter {
  RemoteStoreAdapter({
    required this.nc,
    required this.loginName,
    required this.remotePath,
    required this.isSubscription,
  });

  final CaleeServerService nc;
  final String loginName;
  final String remotePath;
  final bool isSubscription;

  String _normalizeToken(dynamic value) => (value ?? '').toString().replaceAll('"', '');

  String _stableKey(Map<String, dynamic> event) {
    final String uid = (event['remote_uid'] ?? event['uid'] ?? '').toString().trim();
    if (uid.isNotEmpty) return uid;
    final String href = (event['href'] ?? '').toString();
    return href.isNotEmpty ? href : 'remote_unknown';
  }

  Future<AdapterSnapshot> getSnapshot() async {
    final UnifiedEventsSnapshot snapshot = await nc.fetchUnifiedEventsSnapshot(
      calendarPath: remotePath,
      isSubscription: isSubscription,
    );

    final Map<String, AdapterItemSnapshot> byStableKey = {};
    for (final event in snapshot.events) {
      final String stableKey = _stableKey(event);
      byStableKey[stableKey] = AdapterItemSnapshot(
        stableKey: stableKey,
        remoteHref: event['href']?.toString(),
        token: _normalizeToken(event['etag']),
        raw: event,
      );
    }
    return AdapterSnapshot(
      byStableKey: byStableKey,
      fetchSucceeded: snapshot.fetchSucceeded,
      statusCode: snapshot.statusCode,
      parseProducedZeroEvents: snapshot.parseProducedZeroEvents,
    );
  }

  Future<AdapterMutationResult?> create(Map<String, dynamic> item) async {
    return _put(item: item, token: null);
  }

  Future<AdapterMutationResult?> update(Map<String, dynamic> item, String? token) async {
    return _put(item: item, token: token);
  }

  Future<AdapterMutationResult?> _put({
    required Map<String, dynamic> item,
    String? token,
  }) async {
    final String uid = (item['uid'] ?? '').toString().trim();
    if (uid.isEmpty) return null;

    final String? etag = await nc.uploadEventData(
      userId: loginName,
      calendarPath: remotePath,
      uid: uid,
      title: item['title']?.toString() ?? 'Untitled',
      start: DateTime.fromMillisecondsSinceEpoch((item['startTime'] as int?) ?? 0),
      end: DateTime.fromMillisecondsSinceEpoch((item['endTime'] as int?) ?? 0),
    );

    if (etag == null) return null;
    final String normalizedPath = remotePath.endsWith('/') ? remotePath : '$remotePath/';
    return AdapterMutationResult(
      stableKey: uid,
      token: _normalizeToken(etag),
      remoteHref: '${normalizedPath}$uid.ics',
      localId: item['localId']?.toString(),
    );
  }

  Future<bool> delete(String idOrHref, [String? token]) async {
    if (idOrHref.isEmpty) return false;
    return nc.deleteEvent(eventPath: idOrHref);
  }
}
