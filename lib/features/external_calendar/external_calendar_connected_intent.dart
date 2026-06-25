class ExternalCalendarConnectedIntent {
  const ExternalCalendarConnectedIntent({
    this.providerKey,
    this.connectionId,
    this.status,
    this.reason,
  });

  final String? providerKey;
  final String? connectionId;

  /// 'error' when OAuth failed; null on success.
  final String? status;
  final String? reason;

  bool get isError => status == 'error';
  bool get isGoogle => providerKey == 'google_calendar';
}
