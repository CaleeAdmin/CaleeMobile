import 'package:permission_handler/permission_handler.dart';

/// Helper for calendar permission handling using permission_handler.
///
/// Usage:
/// ```dart
/// final helper = CalendarPermissionHelper();
/// if (await helper.requestPermission()) {
///   // Permission granted, proceed with calendar operations
/// } else {
///   // Permission denied, show error or open settings
/// }
/// ```
class CalendarPermissionHelper {
  /// Check if calendar permission is granted.
  Future<bool> isGranted() async {
    final status = await Permission.calendar.status;
    return status.isGranted;
  }

  /// Request calendar permission.
  ///
  /// Returns true if granted, false otherwise.
  /// On Android: requests READ_CALENDAR and WRITE_CALENDAR.
  /// On iOS: requests EventKit access.
  Future<bool> requestPermission() async {
    final status = await Permission.calendar.request();
    return status.isGranted;
  }

  /// Check if permission is permanently denied (user selected "Don't ask again").
  Future<bool> isPermanentlyDenied() async {
    final status = await Permission.calendar.status;
    return status.isPermanentlyDenied;
  }

  /// Open app settings so user can manually grant permission.
  Future<bool> openSettings() async {
    return await openAppSettings();
  }
}

