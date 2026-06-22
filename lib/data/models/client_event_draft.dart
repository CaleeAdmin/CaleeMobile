class ClientEventDraft {
  const ClientEventDraft({
    this.title,
    this.startsAt,
    this.endsAt,
    this.allDay,
    this.location,
    this.description,
  });

  final String? title;
  final String? startsAt;
  final String? endsAt;
  final bool? allDay;
  final String? location;
  final String? description;

  factory ClientEventDraft.fromJson(Map<String, dynamic> json) {
    return ClientEventDraft(
      title: json['title'] as String?,
      startsAt: json['startsAt'] as String?,
      endsAt: json['endsAt'] as String?,
      allDay: json['allDay'] as bool?,
      location: json['location'] as String?,
      description: json['description'] as String?,
    );
  }
}
