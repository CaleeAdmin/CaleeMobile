import 'dart:io' show Platform;

class GlobalConfig {
  GlobalConfig._();

  static bool get enableAppSync => Platform.isAndroid;
}
