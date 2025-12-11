import 'dart:async';
import 'package:flutter/services.dart';

/// Device calendar platform bridge via MethodChannel.
///
/// Channel name must match native side.
const _channel = MethodChannel('com.nextcloud.caleesync/calendar');

class DeviceCalendar {
  final String id;
  final String title;
  final String? accountName;
  final String? timeZone;
  final bool isPrimary;
  final String? accessRole;

  DeviceCalendar({
    required this.id,
    required this.title,
    this.accountName,
    this.timeZone,
    this.isPrimary = false,
    this.accessRole,
  });

  factory DeviceCalendar.fromMap(Map<dynamic, dynamic> map) {
    return DeviceCalendar(
      id: map['id']?.toString() ?? '',
      title: map['title']?.toString() ?? '',
      accountName: map['accountName'] as String?,
      timeZone: map['timeZone'] as String?,
      isPrimary: map['isPrimary'] == true,
      accessRole: map['accessRole'] as String?,
    );
  }
}

class DeviceEvent {
  final String id;
  final String calendarId;
  final String title;
  final int startMillis;
  final int endMillis;
  final bool allDay;
  final String? location;
  final String? timeZone;
  final String? description;

  DeviceEvent({
    required this.id,
    required this.calendarId,
    required this.title,
    required this.startMillis,
    required this.endMillis,
    this.allDay = false,
    this.location,
    this.timeZone,
    this.description,
  });

  factory DeviceEvent.fromMap(Map<dynamic, dynamic> map) {
    return DeviceEvent(
      id: map['id']?.toString() ?? '',
      calendarId: map['calendarId']?.toString() ?? '',
      title: map['title']?.toString() ?? '',
      startMillis: (map['startMillis'] as num?)?.toInt() ?? 0,
      endMillis: (map['endMillis'] as num?)?.toInt() ?? 0,
      allDay: map['allDay'] == true,
      location: map['location'] as String?,
      timeZone: map['timeZone'] as String?,
      description: map['description'] as String?,
    );
  }
}

class DeviceCalendarPlatform {
  Future<List<DeviceCalendar>> listCalendars() async {
    final raw = await _channel.invokeMethod<List<dynamic>>('listCalendars') ?? [];
    return raw.map((e) => DeviceCalendar.fromMap(e as Map<dynamic, dynamic>)).toList();
  }

  Future<List<DeviceEvent>> listEvents({
    required int startMillis,
    required int endMillis,
    List<String>? calendarIds,
  }) async {
    final raw = await _channel.invokeMethod<List<dynamic>>(
      'listEvents',
      {
        'startMillis': startMillis,
        'endMillis': endMillis,
        'calendarIds': calendarIds,
      },
    ) ??
        [];
    return raw.map((e) => DeviceEvent.fromMap(e as Map<dynamic, dynamic>)).toList();
  }
}

