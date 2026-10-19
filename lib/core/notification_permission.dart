import 'package:flutter/foundation.dart';
import 'package:permission_handler/permission_handler.dart';

/// Seam over the OS notification permission (POST_NOTIFICATIONS on API 33+)
/// so the Settings row and the first-run step can be exercised in tests
/// without the platform channel.
class NotificationPermissionAccess {
  NotificationPermissionAccess._();

  static Future<PermissionStatus> Function() status = () =>
      Permission.notification.status;
  static Future<PermissionStatus> Function() request = () =>
      Permission.notification.request();
  static Future<bool> Function() openSettings = openAppSettings;

  @visibleForTesting
  static void reset() {
    status = () => Permission.notification.status;
    request = () => Permission.notification.request();
    openSettings = openAppSettings;
  }
}
