import 'dart:async';

import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

import 'agent_service.dart';

/// Foreground-service notification manager (DSH "always-on assistant"
/// parity): while an agent run is active, an ongoing low-importance
/// notification keeps the process alive (Android won't kill a foreground
/// service under normal memory pressure), so the agent keeps working
/// with the screen off / app backgrounded until the task completes.
///
/// The notification carries a **Stop** action that cancels the active
/// run — identical to tapping Stop in the chat UI.
///
/// Pure MethodChannel — no new Dart dependencies.
class AgentNotificationService {
  AgentNotificationService._();
  static final AgentNotificationService I = AgentNotificationService._();

  static const _channel = MethodChannel('ovid/native');

  bool _supported = true; // desktop/test → channel MissingPluginException
  bool _active = false;
  bool _permAsked = false;
  int _lastEventHash = 0;
  Timer? _debounce;

  /// Wire the notification Stop button → agent cancel. Called once at
  /// app startup (main.dart).
  Future<void> init() async {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'onAgentStop') {
        AgentService.I.cancelRun();
      }
      return null;
    });
    try {
      await _channel.invokeMethod('agentStopHandler');
    } on MissingPluginException {
      _supported = false;
    } on PlatformException {
      // Channel exists but native side not built yet — fine.
    } catch (_) {
      _supported = false;
    }
  }

  /// Android 13+ needs POST_NOTIFICATIONS granted at runtime before the
  /// foreground service can show its notification. Asked lazily on the
  /// first agent run (once), never on app open.
  Future<void> _ensurePermission() async {
    if (_permAsked) return;
    _permAsked = true;
    try {
      final st = await Permission.notification.status;
      if (st.isDenied || st.isPermanentlyDenied) {
        await Permission.notification.request();
      }
    } catch (_) {}
  }

  /// Start/update the foreground notification. Debounced + content-hashed
  /// so streaming `think` events don't spam notification updates.
  Future<void> agentWorking(String text) async {
    if (!_supported) return;
    await _ensurePermission();
    final clean = _clean(text);
    final h = clean.hashCode;
    if (_active && h == _lastEventHash) return;
    _lastEventHash = h;
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 600), () {
      unawaited(
        _invoke(
          _active ? 'agentServiceUpdate' : 'agentServiceStart',
          {'title': 'Ovid AI', 'text': 'Agent: $clean'},
        ).then((ok) {
          if (ok) _active = true;
        }),
      );
    });
  }

  /// Run finished / idle → notification goes away.
  void agentIdle() {
    if (!_supported || !_active) return;
    _active = false;
    _lastEventHash = 0;
    _debounce?.cancel();
    unawaited(_invoke('agentServiceStop', {}));
  }

  Future<bool> _invoke(String method, Map<String, String> args) async {
    try {
      final r = await _channel.invokeMethod(method, args);
      return r == true;
    } on MissingPluginException {
      _supported = false;
      return false;
    } on PlatformException {
      return false;
    } catch (_) {
      return false;
    }
  }

  /// One readable line out of an event string (strip newlines, clamp).
  String _clean(String s) {
    final one = s.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (one.length <= 90) return one.isEmpty ? 'working…' : one;
    return '${one.substring(0, 90)}…';
  }
}
