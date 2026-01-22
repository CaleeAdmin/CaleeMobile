import 'package:flutter/material.dart';


/// Public subscription calendar model used across the app.
class PublicSubscriptionCalendar {
  final String title;
  final String description;
  final String ownerUid;
  final String subscribers;
  final Color color;
  final String? icsUrl;

  const PublicSubscriptionCalendar({
    required this.title,
    required this.description,
    required this.ownerUid,
    required this.subscribers,
    required this.color,
    this.icsUrl,
  });

  factory PublicSubscriptionCalendar.fromJson(Map<String, dynamic> json) {
    final title = (json['calendar_name'] ?? json['title'] ?? json['name'] ?? '').toString();
    final description = (json['description'] ?? json['desc'] ?? json['summary'] ?? '').toString();
    final owner = (json['owner_uid'] ?? json['owner'] ?? json['by'] ?? '').toString();
    final subscribers = (json['subscribers']?.toString() ?? json['subscriber_count']?.toString() ?? '').toString();

    Color color = Colors.blue;
    // color: optional parsing (hex or int) - keep default if absent
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
      ownerUid: owner,
      subscribers: subscribers.isEmpty ? '0' : subscribers,
      color: color,
      icsUrl: (json['ics_url'] ?? json['icsUrl'] ?? json['url'] ?? json['href'])?.toString(),
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


