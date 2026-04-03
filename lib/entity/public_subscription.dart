import 'package:flutter/material.dart';

/// Public subscription calendar model used across the app.
class PublicSubscriptionCalendar {
  final String title;
  final String description;
  final String ownerUid;
  final String ownerDisplayName;
  final Color color;
  final String? icsUrl;

  const PublicSubscriptionCalendar({
    required this.title,
    required this.description,
    required this.ownerUid,
    required this.ownerDisplayName,
    required this.color,
    this.icsUrl,
  });

  factory PublicSubscriptionCalendar.fromJson(Map<String, dynamic> json) {
    final title = (json['calendar_name'] ?? json['title'] ?? '').toString();
    final description = (json['description'] ?? '').toString();
    final ownerUid = (json['owner_uid'] ?? '').toString();
    final ownerDisplayName = (json['owner_display_name'] ?? '').toString();

    Color color = Colors.lightGreen;
    try {
      if (json.containsKey('color') && json['color'] != null) {
        final c = json['color'];
        if (c is int) color = Color(c);
        else if (c is String) {
          final trimmed = c.replaceAll('#', '');
          final parsed = int.tryParse(trimmed, radix: 16);
          if (parsed != null) color = Color(0xFF000000 | parsed);
        }
      }
    } catch (_) {}

    return PublicSubscriptionCalendar(
      title: title.isEmpty ? 'Untitled' : title,
      description: description,
      ownerUid: ownerUid,
      ownerDisplayName: ownerDisplayName,
      color: color,
      icsUrl: json['ics_url']?.toString(),
    );
  }
}

/// Category grouping for public subscriptions.
class PublicSubscriptionCategory {
  final String title;
  final List<PublicSubscriptionCalendar> calendars;

  const PublicSubscriptionCategory({
    required this.title,
    required this.calendars,
  });
}
