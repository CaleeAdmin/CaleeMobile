import 'dart:convert';

class LocalCalendarSubscription {
  LocalCalendarSubscription({
    required this.id,
    required this.title,
    required this.url,
    required this.source,
    required this.createdAt,
    this.lastFetchedAt,
    this.enabled = true,
  });

  final String id;
  final String title;
  final String url;
  final String source;
  final DateTime createdAt;
  final DateTime? lastFetchedAt;
  final bool enabled;

  LocalCalendarSubscription copyWith({DateTime? lastFetchedAt}) {
    return LocalCalendarSubscription(
      id: id,
      title: title,
      url: url,
      source: source,
      createdAt: createdAt,
      lastFetchedAt: lastFetchedAt ?? this.lastFetchedAt,
      enabled: enabled,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'url': url,
    'source': source,
    'createdAt': createdAt.toIso8601String(),
    'lastFetchedAt': lastFetchedAt?.toIso8601String(),
    'enabled': enabled,
  };

  factory LocalCalendarSubscription.fromJson(Map<String, dynamic> json) {
    return LocalCalendarSubscription(
      id: json['id'] as String,
      title: json['title'] as String,
      url: json['url'] as String,
      source: json['source'] as String? ?? '',
      createdAt: DateTime.parse(json['createdAt'] as String),
      lastFetchedAt: json['lastFetchedAt'] != null
          ? DateTime.parse(json['lastFetchedAt'] as String)
          : null,
      enabled: json['enabled'] as bool? ?? true,
    );
  }

  static List<LocalCalendarSubscription> listFromJsonString(String raw) {
    try {
      final list = jsonDecode(raw) as List<dynamic>;
      return list
          .map((e) => LocalCalendarSubscription.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return [];
    }
  }

  static String listToJsonString(List<LocalCalendarSubscription> items) {
    return jsonEncode(items.map((e) => e.toJson()).toList());
  }
}
