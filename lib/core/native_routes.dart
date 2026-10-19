import 'package:flutter/services.dart';

import 'diag.dart';

/// Dart half of the `ovid/native` routing methods (CT-009).
///
/// MainActivity.kt calls `onOpenRoute(<path>)` / `onSelectSession(<id>)` when
/// a local notification (or a foreground FCM re-post) is tapped while the app
/// is running, and parks the launch route of a cold start for
/// [takePendingRoute] (Dart is not listening yet during `onCreate`).
class NativeRouteChannel {
  NativeRouteChannel._();

  static const MethodChannel channel = MethodChannel('ovid/native');

  /// Installs the handler. [open] receives an absolute in-app path
  /// (`/c/<id>`, `/schedule/<id>`, `/settings`, …). Only the two routing
  /// methods are answered; every other method stays Dart→Kotlin only.
  static void install(void Function(String route) open) {
    channel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'onOpenRoute':
          final route = validRoute(call.arguments);
          if (route != null) open(route);
        case 'onSelectSession':
          final id = call.arguments;
          if (id is String && id.trim().isNotEmpty && id.length <= 128) {
            open('/c/${id.trim()}');
          }
      }
      return null;
    });
  }

  /// The route a notification tap launched the app with, if any (consumed).
  static Future<String?> takePendingRoute() async {
    try {
      return validRoute(await channel.invokeMethod<String>('takePendingRoute'));
    } on MissingPluginException {
      return null; // not Android / no host activity (tests, desktop)
    } catch (e) {
      Diag.swallow('native_routes.pending', e);
      return null;
    }
  }

  /// Same bound as Kotlin's `routeNotificationIntent`: absolute, ≤ 200 chars.
  static String? validRoute(Object? raw) {
    if (raw is! String) return null;
    final route = raw.trim();
    if (route.isEmpty || route.length > 200 || !route.startsWith('/')) {
      return null;
    }
    return route;
  }
}
