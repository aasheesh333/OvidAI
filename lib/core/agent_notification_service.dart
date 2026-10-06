import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'agent_service.dart';
import 'state.dart';
import 'diag.dart';

/// Foreground-service notification manager (the agent keep-alive "always-on assistant"
/// parity): while an agent run is active, an ongoing low-importance
/// notification improves process priority so work can continue with the screen
/// off / app backgrounded. Android can still restrict or terminate the runtime.
///
/// The notification carries a **Stop** action that cancels the active
/// runs and pauses schedules until explicit background Resume.
///
/// Pure MethodChannel — no new Dart dependencies.
class AgentNotificationService {
  AgentNotificationService._();
  static final AgentNotificationService I = AgentNotificationService._();

  static const _channel = MethodChannel('ovid/native');

  bool _supported = true; // desktop/test → channel MissingPluginException
  bool _active = false;
  bool _permAsked = false;
  int _failCount = 0; // 3 native failures → feature off until the cooldown
  DateTime? _disabledAt;
  int _lastEventHash = 0;
  bool backgroundStopped = false;
  String? backgroundConstraint;
  int _backgroundGeneration = 0;
  bool _localStopPending = false;
  static const _stopKey = 'ovid_background_stopped';

  Future<void> refreshBackgroundState() async {
    final generation = _backgroundGeneration;
    if (_localStopPending) return;
    try {
      final state = await _channel.invokeMapMethod<String, dynamic>(
        'backgroundState',
      );
      if (generation != _backgroundGeneration) return;
      if (state != null) {
        backgroundStopped = state['stopped'] == true;
        backgroundConstraint = state['constraint'] as String?;
        return;
      }
    } on MissingPluginException {
      if (generation != _backgroundGeneration) return;
      backgroundConstraint =
          'Background alarms require Android; keep the app running.';
    } catch (e) {
      if (generation != _backgroundGeneration) return;
      backgroundConstraint = 'Background service unavailable: $e';
    }
    final prefs = await SharedPreferences.getInstance();
    if (generation != _backgroundGeneration) return;
    backgroundStopped = prefs.getBool(_stopKey) ?? false;
  }

  Future<void> resumeBackground() async {
    final generation = ++_backgroundGeneration;
    await _backgroundWrite;
    if (generation != _backgroundGeneration) return;
    try {
      await _channel.invokeMethod('backgroundResume');
    } on MissingPluginException {
      // Foreground-only desktop runtime.
    }
    if (generation != _backgroundGeneration) return;
    await _serializeBackgroundWrite(() async {
      if (generation != _backgroundGeneration) return;
      final prefs = await SharedPreferences.getInstance();
      if (generation != _backgroundGeneration) return;
      if (!await prefs.setBool(_stopKey, false)) {
        throw StateError('Could not persist background Resume');
      }
      if (generation != _backgroundGeneration) return;
      backgroundStopped = false;
      _localStopPending = false;
      backgroundConstraint = null;
      agentIdle();
    });
  }

  Future<void> _backgroundWrite = Future<void>.value();

  Future<void> _serializeBackgroundWrite(Future<void> Function() write) {
    final next = _backgroundWrite.then((_) => write());
    _backgroundWrite = next.catchError((Object e) {
      Diag.swallow('background.write', e);
    });
    return next;
  }

  Future<void> stopBackground() async {
    final generation = ++_backgroundGeneration;
    backgroundStopped = true;
    _localStopPending = true;
    _debounce?.cancel();
    _committedGeneration = ++_issuedGeneration;
    _active = false;
    // Pause synchronously before awaiting native or session storage.
    final paused = AgentService.I.stopScheduledBackground();
    AgentService.I.cancelAllRuns();
    final persisted = _persistBackgroundStop();
    try {
      await Future.wait([paused, persisted]);
    } finally {
      if (generation == _backgroundGeneration) _localStopPending = false;
    }
  }

  Future<void> _persistBackgroundStop() =>
    // Queue the native operation as well as preferences. Otherwise a delayed
    // native Stop can enqueue its preferences write after a newer Resume.
    _serializeBackgroundWrite(() async {
      try {
        await _channel.invokeMethod('backgroundStop');
      } on MissingPluginException {
        // Also persist for non-Android runtimes.
      } catch (e) {
        Diag.swallow('background.stop', e);
      }
      final prefs = await SharedPreferences.getInstance();
      if (!await prefs.setBool(_stopKey, true)) {
        throw StateError('Could not persist background Stop');
      }
    });

  /// Cooldown before a failure-disabled notifier re-arms itself. A permanent
  /// session-long disable meant one bad burst (e.g. transient native errors)
  /// silently killed background keep-alive for the rest of the session.
  @visibleForTesting
  static Duration supportCooldownForTest = const Duration(minutes: 5);

  void _disableSupport() {
    _supported = false;
    _disabledAt = DateTime.now();
  }

  /// Re-arm after the cooldown so keep-alive can never die silently for a
  /// whole session. Returns whether the notifier may proceed.
  bool _maybeRearmSupport() {
    if (_supported) return true;
    final disabledAt = _disabledAt;
    if (disabledAt == null) {
      _supported = true;
      return true;
    }
    if (DateTime.now().difference(disabledAt) >= supportCooldownForTest) {
      _supported = true;
      _failCount = 0;
      _disabledAt = null;
      return true;
    }
    return false;
  }

  Timer? _debounce;
  String? _displayedStopTargetSessionId;
  int _issuedGeneration = 0;
  int _committedGeneration = 0;

  @visibleForTesting
  static bool? keepAliveOverrideForTest;

  bool get _isKeepAlive =>
      keepAliveOverrideForTest ?? AppState.I.keepAliveEnabled;

  /// True while any session sits in control mode — the user's explicit
  /// "stay present" intent, independent of the keep-alive toggle.
  bool _isControlModeActive() {
    try {
      return AppState.I.sessions.any((s) => s.mode == AgentMode.control.name);
    } catch (_) {
      return false;
    }
  }

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
    _disabledAt = null;
    supportCooldownForTest = const Duration(minutes: 5);
    _failCount = 0;
    _lastEventHash = 0;
    _displayedStopTargetSessionId = null;
    _issuedGeneration = 0;
    _committedGeneration = 0;
    backgroundStopped = false;
    backgroundConstraint = null;
    _backgroundGeneration = 0;
    _localStopPending = false;
    _backgroundWrite = Future<void>.value();
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
      if (await AgentService.I.handleDeviceOverlayMethodCall(call)) {
        return null;
      }
      if (call.method == 'onAgentStop') {
        await stopBackground();
      } else if (call.method == 'onAgentExit') {
        await stopBackground();
        if (_onExitCallback != null) {
          _onExitCallback!();
        }
      } else if (call.method == 'onScheduleWake') {
        if (!backgroundStopped) await AgentService.I.wakeSchedules();
      } else if (call.method == 'onBackgroundConstraint') {
        backgroundConstraint = call.arguments as String?;
        AppState.I.refresh();
      } else if (call.method == 'onSelectSession') {
        final sid = call.arguments as String?;
        if (sid != null && sid.isNotEmpty) {
          AppState.I.selectSession(sid);
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
    } catch (e) {
      Diag.swallow('agent_notification_service', e);
    }
  }

  /// Start/update the foreground notification. Debounced + content-hashed
  /// so streaming `think` events don't spam notification updates.
  /// NEVER blocks or throws into the agent event stream — all failures
  /// are swallowed and after 3 consecutive native failures the feature
  /// disables itself for the session.
  Future<void> agentWorking(String text, {String? sessionId}) async {
    if (backgroundStopped) return;
    if (!AppState.I.notificationsEnabled) return;
    if (!_maybeRearmSupport()) return;
    unawaited(_ensurePermission());
    final clean = _clean(text);
    final h = Object.hash(clean, sessionId);
    if (_active && h == _lastEventHash) return;
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 600), () {
      if (backgroundStopped) return;
      final generation = ++_issuedGeneration;
      unawaited(
        _invoke(_active ? 'agentServiceUpdate' : 'agentServiceStart', {
          'title': 'Ovid AI',
          'text': 'Agent: $clean',
          // A run IS in flight → the service may hold the partial wake lock.
          'wake': 'true',
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
    if (backgroundStopped) return;
    if (!_maybeRearmSupport()) return;
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

    // Master notification switch OFF: no notification at all — drop any
    // posted one instead of idling into "Ready & Listening".
    if (!AppState.I.notificationsEnabled) {
      _active = false;
      serviceStopRequestedForTestFlag = true;
      if (hadNotificationWork) {
        unawaited(_invoke('agentServiceStop', {}));
      }
      return;
    }

    // Control-mode presence lock: an explicit control session means the
    // user wants Ovid permanently present — idle gaps between runs must
    // never stop the service. Only explicit Exit, control-mode off, or the
    // master notification switch off ends presence.
    if (_isControlModeActive()) {
      unawaited(
        _invoke('agentServiceUpdate', {
          'title': 'Ovid AI',
          'text': 'Control mode active',
          // Presence only — no run in flight, so no wake lock. The next
          // agentWorking() re-acquires it.
          'wake': 'false',
        }).then((ok) {
          if (ok && _committedGeneration == barrier && !_isAnyRunActive()) {
            _active = true;
          }
        }),
      );
      return;
    }

    if (_isKeepAlive) {
      // Keep foreground service active so scheduled tasks and message queue fire
      unawaited(
        _invoke('agentServiceUpdate', {
          'title': 'Ovid AI',
          'text': 'Ready & Listening',
          // Idle presence: keep the notification, release the wake lock. An
          // idle service holding a 6h PARTIAL_WAKE_LOCK drains battery all
          // night with no agent work happening.
          'wake': 'false',
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

  /// 24/7: stop the foreground service completely — same effect as the
  /// notification's Exit action. Cancels any in-flight runs first.
  Future<void> agentExit() async {
    await stopBackground();
    _active = false;
    _displayedStopTargetSessionId = null;
    serviceStopRequestedForTestFlag = true;
    await _invoke('agentServiceStop', {});
  }

  Future<bool> _invoke(String method, Map<String, String> args) async {
    if (backgroundStopped &&
        (method == 'agentServiceStart' || method == 'agentServiceUpdate')) {
      return false;
    }
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
      backgroundConstraint = e.message ?? e.code;
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
          _disableSupport(); // re-arms after the cooldown (never silent forever)
        }
      }
      return false;
    } catch (_) {
      _failCount++;
      if (_failCount >= 3) _disableSupport();
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
