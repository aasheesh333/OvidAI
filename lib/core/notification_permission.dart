import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

/// Seam over the OS notification permission (POST_NOTIFICATIONS on API 33+)
/// so the Settings row and the first-run step can be exercised in tests
/// without the platform channel.
///
/// Legacy screens (`settings_screen.dart`, `first_run_steps.dart`) use this
/// injectable form; new code should prefer [NotificationPermission].
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

/// Reads and opens the Android notification permission through the app's
/// `ovid/native` channel.
///
/// Methods:
/// - `notificationsEnabled` → `bool`: whether POST_NOTIFICATIONS is granted.
/// - `openNotificationSettings` → `bool`: opens the app's notification
///   settings page.
///
/// On non-Android platforms (and in tests, which run on the host) both
/// operations are no-ops that report notifications as allowed. When the
/// installed shell does not implement a method yet, the call falls back to
/// the existing `notifyOpenAppSettings` handler / `permission_handler`, so a
/// missing native method degrades to a working app instead of a crash.
class NotificationPermission {
  NotificationPermission._();

  static const MethodChannel channel = MethodChannel('ovid/native');

  /// Forces the Android path in host tests. `null` uses the real platform.
  @visibleForTesting
  static bool? androidOverrideForTest;

  /// Replaces the channel call in tests that do not want a mock messenger.
  @visibleForTesting
  static Future<Object?> Function(String method)? invokeOverrideForTest;

  @visibleForTesting
  static void resetForTest() {
    androidOverrideForTest = null;
    invokeOverrideForTest = null;
  }

  static bool get _isAndroid => androidOverrideForTest ?? Platform.isAndroid;

  /// Whether the app may post notifications.
  static Future<bool> isEnabled() async {
    if (!_isAndroid) return true;
    try {
      final value = await _invoke('notificationsEnabled');
      if (value is bool) return value;
      if (value != null) return true;
    } on MissingPluginException {
      return _permissionHandlerStatus();
    } on PlatformException {
      return _permissionHandlerStatus();
    }
    return true;
  }

  /// Opens the app's notification settings. Returns whether a settings screen
  /// was opened; on non-Android there is nothing to open.
  static Future<bool> openSettings() async {
    if (!_isAndroid) return false;
    if (await _tryInvoke('openNotificationSettings')) return true;
    // Older shells only expose the app-notification settings intent.
    if (await _tryInvoke('notifyOpenAppSettings')) return true;
    try {
      return await openAppSettings();
    } catch (_) {
      return false;
    }
  }

  static Future<Object?> _invoke(String method) {
    final override = invokeOverrideForTest;
    if (override != null) return override(method);
    return channel.invokeMethod<Object?>(method);
  }

  static Future<bool> _tryInvoke(String method) async {
    try {
      final value = await _invoke(method);
      if (value is bool) return value;
      return value != null;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  /// Fallback for shells without the `notificationsEnabled` handler. The
  /// plugin is already a dependency (voice input uses it), so this keeps the
  /// banner honest without a new package.
  static Future<bool> _permissionHandlerStatus() async {
    try {
      final status = await Permission.notification.status;
      return status.isGranted || status.isLimited || status.isProvisional;
    } catch (_) {
      // No plugin on this platform/test: assume allowed rather than nag.
      return true;
    }
  }
}
