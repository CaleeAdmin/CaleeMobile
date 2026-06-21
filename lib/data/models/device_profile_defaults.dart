class DeviceProfileDefaults {
  const DeviceProfileDefaults({
    this.timeZone,
    this.locale,
    this.countryCode,
  });

  final String? timeZone;
  final String? locale;
  final String? countryCode;

  bool get hasAnyValue =>
      timeZone != null || locale != null || countryCode != null;

  Map<String, dynamic> toProfilePatchBody() {
    return <String, dynamic>{
      if (timeZone != null) 'timeZone': timeZone,
      if (locale != null) 'locale': locale,
      if (countryCode != null) 'countryCode': countryCode,
    };
  }
}
