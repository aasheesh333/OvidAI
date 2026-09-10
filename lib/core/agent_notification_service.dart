import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

import 'agent_service.dart';
import 'state.dart';

/// Foreground-service notification manager (the agent keep-alive "always-on assistant"
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
  int _failCount = 0; // 3 native failures → feature off for the session
  int _lastEventHash = 0;
  Timer? _debounce;
  String? _displayedStopTargetSessionId;
  int _issuedGeneration = 0;
  int _committedGeneration = 0;

  @visibleForTesting
  static bool? keepAliveOverrideForTest;

  bool get _isKeepAlive =>
      keepAliveOverrideForTest ?? AppState.I.keepAliveEnabled;

  @visibleForTesting
  static bool Function()? anyRunActiveOverrideForTest;

  @visibleForTesting
  static bool serviceStopRequestedForTestFlag = false;

  @visibleForTesting
  bool get activeForTest => _active;

  @visibleForTesting
  set activeForTest(bool v) => _active = v;

  @visibleForTesting
  bool get supportedForTest => _supported;

  @visibleForTesting
  set supportedForTest(bool v) => _supported = v;

  @visibleForTesting
  int get failCountForTest => _failCount;

  @visibleForTesting
  String? get displayedStopTargetForTest => _displayedStopTargetSessionId;

  @visibleForTesting
  void resetForTest() {
    _debounce?.cancel();
    _active = false;
    _supported = true;
    _failCount = 0;
    _lastEventHash = 0;
    _displayedStopTargetSessionId = null;
    _issuedGeneration = 0;
    _committedGeneration = 0;
  }

  void Function()? _onExitCallback;

  @visibleForTesting
  void Function()? get onExitCallbackForTest => _onExitCallback;

  /// Register a callback to run when the notification EXIT action is received.
  void registerExitHandler(void Function() handler) {
    _onExitCallback = handler;
  }

  @visibleForTesting
  Future<bool> invokeForTest(String method, Map<String, String> args) =>
      _invoke(method, args);

  bool _isAnyRunActive() => anyRunActiveOverrideForTest != null
      ? anyRunActiveOverrideForTest!()
      : AgentService.I.anyRunActive;

  /// Wire the notification Stop button → agent cancel. Called once at
  /// app startup (main.dart).
  Future<void> init() async {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'onAgentStop') {
        final sessionId = AgentService.I.runningSessionIdForNotification(
          _displayedStopTargetSessionId,
        );
        if (sessionId != null) {
          AgentService.I.stopRequested(sessionId: sessionId);
        }
      } else if (call.method == 'onAgentExit') {
        AgentService.I.cancelAllRuns();
        if (_onExitCallback != null) {
          _onExitCallback!();
        }
      }
      return null;
    });
    try {
      await _channel.invokeMethod('agentStopHandler');
      await _channel.invokeMethod('agentExitHandler');
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
  /// NEVER blocks or throws into the agent event stream — all failures
  /// are swallowed and after 3 consecutive native failures the feature
  /// disables itself for the session.
  Future<void> agentWorking(String text, {String? sessionId}) async {
    if (!_supported) return;
    unawaited(_ensurePermission());
    final clean = _clean(text);
    final h = Object.hash(clean, sessionId);
    if (_active && h == _lastEventHash) return;
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 600), () {
      final generation = ++_issuedGeneration;
      unawaited(
        _invoke(_active ? 'agentServiceUpdate' : 'agentServiceStart', {
          'title': 'Ovid AI',
          'text': 'Agent: $clean',
        }).then((ok) {
          if (!ok || generation <= _committedGeneration) return;
          _committedGeneration = generation;
          _active = true;
          _lastEventHash = h;
          if (sessionId != null) {
            _displayedStopTargetSessionId = sessionId;
          }
        }),
      );
    });
  }

  /// Run finished / idle → notification either updates to Ready & Listening
  /// (if keep-alive enabled) or stops the foreground service.
  void agentIdle({String? sessionId}) {
    if (!_supported) return;
    if (_isAnyRunActive()) {
      if (_active &&
          sessionId != null &&
          sessionId == _displayedStopTargetSessionId) {
        final replacement = AgentService.I.nextRunningSessionForNotification(
          excludingSessionId: sessionId,
        );
        if (replacement != null) {
          unawaited(
            agentWorking(
              AgentService.I.statusFor(replacement) ??
                  'working in another session…',
              sessionId: replacement,
            ),
          );
        }
      }
      return;
    }
    final hadNotificationWork =
        _active ||
        _issuedGeneration > _committedGeneration ||
        (_debounce?.isActive ?? false);
    final barrier = ++_issuedGeneration;
    _committedGeneration = barrier;
    _lastEventHash = 0;
    _debounce?.cancel();
    _active = _isKeepAlive;
    _displayedStopTargetSessionId = null;

    if (_isKeepAlive) {
      // Keep foreground service active so scheduled tasks and message queue fire
      unawaited(
        _invoke('agentServiceUpdate', {
          'title': 'Ovid AI',
          'text': 'Ready & Listening',
        }).then((ok) {
          if (ok && _committedGeneration == barrier && !_isAnyRunActive()) {
            _active = true;
          }
        }),
      );
      return;
    }

    serviceStopRequestedForTestFlag = true;
    if (hadNotificationWork) {
      unawaited(_invoke('agentServiceStop', {}));
    }
  }

  Future<bool> _invoke(String method, Map<String, String> args) async {
    try {
      final r = await _channel.invokeMethod(method, args);
      if (r == true) {
        _failCount = 0;
        return true;
      }
      return false;
    } on MissingPluginException {
      _supported = false;
      return false;
    } on PlatformException catch (e) {
      // Native side refused (permission/service policy). The native
      // service ALSO catches startForeground failures and stops itself —
      // so a failure here must never repeat forever or touch the run.
      final isBgDenied =
          e.code == 'FGS_BACKGROUND_DENIED' ||
          (e.message?.contains('ForegroundServiceStartNotAllowed') ?? false) ||
          (e.message?.contains('Background') ?? false);
      if (!isBgDenied) {
        _failCount++;
        if (_failCount >= 3 || e.code.contains('SECURITY')) {
          _supported = false; // feature off for this app session
        }
      }
      return false;
    } catch (_) {
      _failCount++;
      if (_failCount >= 3) _supported = false;
      return false;
    }
  }

  /// One readable line out of an event string (strip newlines, clamp).
  String _clean(String s) {
    final one = s.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (one.length <= 90) return one.isEmpty ? 'working…' : one;
    final cut = one.substring(0, 90);
    return '$cut…';
  }
}

@visibleForTesting
void setAnyRunActiveForTest(bool active) {
  AgentNotificationService.anyRunActiveOverrideForTest = () => active;
}

@visibleForTesting
Future<void> agentIdleForTest() async {
  AgentNotificationService.I.agentIdle();
  await Future<void>.delayed(Duration.zero);
}

@visibleForTesting
bool serviceStopRequestedForTest() {
  return AgentNotificationService.serviceStopRequestedForTestFlag;
}
