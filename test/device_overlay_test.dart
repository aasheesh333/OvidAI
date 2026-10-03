import 'dart:async';
import 'dart:ffi' as ffi;
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/agent_notification_service.dart';
import 'package:ovid_ai/core/agent_service.dart';
import 'package:ovid_ai/core/device_control_service.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqlite3/open.dart' show open, OperatingSystem;

// Task 4: Floating control overlay (native window + queue/stop wiring).
//
// - Channel contract: Dart->native deviceOverlayShow/deviceOverlayHide;
//   native->Dart deviceOverlayText(text) + deviceOverlayStop().
// - Send == composer send: idle starts a run, busy joins the per-session
//   queue. Stop Ovid globally stops background work and invalidates device work,
//   including when no session is selected.
// - Show-guard: Dart shows only with an active control session.
// - Native gestures, minimize/restore, send-state and window removal run in
//   OverlayInteractionTest (Robolectric). The checks here cover channel behavior
//   and method-scoped native wiring, not Android touch behavior.
//
// No hardware here: fake channel + seams + source pins only.

const String kCancelledCopy = 'cancelled: superseded by a newer run/stop';

String readAgentServiceSource() =>
    File('lib/core/agent_service.dart').readAsStringSync();

String readOverlayServiceSource() => File(
  'android/app/src/main/kotlin/com/dhanuk/ovidai/OvidAccessibilityService.kt',
).readAsStringSync();

String readMainActivitySource() => File(
  'android/app/src/main/kotlin/com/dhanuk/ovidai/MainActivity.kt',
).readAsStringSync();

String readManifest() =>
    File('android/app/src/main/AndroidManifest.xml').readAsStringSync();

/// Source window of the Dart method starting at [marker] (brace-counted, so
/// file-level names like cancelRun elsewhere cannot leak into the pin).
/// The body open-brace is the first `{` at paren depth zero, so named
/// parameters (`{required ...}`) cannot truncate the window.
String methodWindow(String src, String marker) {
  final start = src.indexOf(marker);
  expect(start, greaterThanOrEqualTo(0), reason: 'missing $marker');
  var parens = 0;
  var body = -1;
  for (var i = start; i < src.length; i++) {
    final c = src[i];
    if (c == '(') parens++;
    if (c == ')') parens--;
    if (c == '{' && parens == 0) {
      body = i;
      break;
    }
  }
  expect(body, greaterThanOrEqualTo(0), reason: 'no body for $marker');
  var depth = 0;
  for (var i = body; i < src.length; i++) {
    if (src[i] == '{') depth++;
    if (src[i] == '}') {
      depth--;
      if (depth == 0) return src.substring(start, i + 1);
    }
  }
  fail('unbalanced braces after $marker');
}

Future<void> waitForChannelCall(
  List<MethodCall> calls,
  String method,
) async {
  for (var i = 0; i < 200 && !calls.any((c) => c.method == method); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  expect(
    calls.any((c) => c.method == method),
    isTrue,
    reason: 'timed out waiting for channel call $method',
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppState app;

  setUpAll(() async {
    HttpOverrides.global = null;
    SharedPreferences.setMockInitialValues({});
    if (Platform.isLinux) {
      open.overrideFor(OperatingSystem.linux, () {
        try {
          return ffi.DynamicLibrary.open('libsqlite3.so.0');
        } catch (_) {
          return ffi.DynamicLibrary.open(
            '/usr/lib/x86_64-linux-gnu/libsqlite3.so.0',
          );
        }
      });
    }
    app = AppState.I;
    await app.initialize();
  });

  group('Task 4: overlay channel contract', () {
    late ChatSession s;
    late List<MethodCall> calls;

    setUp(() {
      s = ChatSession(
        id: 't4-overlay',
        title: 'S',
        model: 'm',
        mode: 'control',
      );
      app.sessions.insert(0, s);
      app.activeSessionId = s.id;
      AgentService.I.runBucketForTest(s.id);
      calls = <MethodCall>[];
      const channel = MethodChannel('ovid/device-overlay-test-task4');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call);
            final pending = _gate;
            if (pending != null) return pending.future;
            return true;
          });
      AgentService.setOverlayChannelForTest(channel);
      addTearDown(() async {
        await AgentService.I.setAppForegrounded(true);
        AgentService.setOverlayChannelForTest(null);
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null);
        AgentService.setRunSessionForTest('');
        AgentService.I.overlayRunStarterForTest = null;
        _gate = null;
        app.activeSessionId = null;
        app.sessions.removeWhere((x) => x.id == s.id);
      });
    });

    test('method names are the exact contracted strings', () {
      expect(AgentService.deviceOverlayShowMethod, 'deviceOverlayShow');
      expect(AgentService.deviceOverlayHideMethod, 'deviceOverlayHide');
      expect(AgentService.deviceOverlayTextMethod, 'deviceOverlayText');
      expect(AgentService.deviceOverlayStopMethod, 'deviceOverlayStop');
    });

    test('Dart show/hide go over ovid/native (source pin)', () {
      final src = readAgentServiceSource();
      expect(
        src,
        contains("_overlayNativeChannel = MethodChannel('ovid/native')"),
        reason: 'overlay channel must be ovid/native',
      );
    });

    test('MainActivity routes deviceOverlayShow/Hide (source pin)', () {
      final src = readMainActivitySource();
      expect(src, contains('"deviceOverlayShow"'));
      expect(src, contains('"deviceOverlayHide"'));
      expect(src, contains('showOverlay()'));
      expect(src, contains('hideOverlay()'));
    });

    test('show invokes deviceOverlayShow with an active control session',
        () async {
      // Overlay shows only while the app is backgrounded.
      await AgentService.I.setAppForegrounded(false);
      expect(
        calls.any((c) => c.method == 'deviceOverlayShow'),
        isTrue,
      );
    });

    test('hide invokes deviceOverlayHide', () async {
      await AgentService.I.hideDeviceOverlay();
      expect(
        calls.any((c) => c.method == 'deviceOverlayHide'),
        isTrue,
      );
    });

    test('show-guard: no channel call without an active session', () async {
      app.activeSessionId = null;
      app.sessions.removeWhere((x) => x.id == s.id);
      await AgentService.I.showDeviceOverlay();
      expect(calls, isEmpty);
    });

    test('show-guard: no channel call when the active session is not Control',
        () async {
      s.mode = 'auto';
      await AgentService.I.showDeviceOverlay();
      expect(calls, isEmpty);
    });

    test('show-guard source pin: show checks the Control mode', () {
      final src = readAgentServiceSource();
      final window = methodWindow(src, 'Future<void> showDeviceOverlay(');
      expect(window, contains('AgentMode.control'));
      expect(window, contains('deviceOverlayShow'));
    });

    test('hide has no guard: it always removes the window', () async {
      app.activeSessionId = null;
      app.sessions.removeWhere((x) => x.id == s.id);
      await AgentService.I.hideDeviceOverlay();
      expect(
        calls.any((c) => c.method == 'deviceOverlayHide'),
        isTrue,
      );
    });
  });

  group('Task 4: overlay send == composer send', () {
    late ChatSession s;
    late List<MethodCall> calls;
    late List<({String text, String sessionId})> startedRuns;

    setUp(() {
      s = ChatSession(
        id: 't4-send',
        title: 'S',
        model: 'm',
        mode: 'control',
      );
      app.sessions.insert(0, s);
      app.activeSessionId = s.id;
      AgentService.I.runBucketForTest(s.id);
      calls = <MethodCall>[];
      startedRuns = <({String text, String sessionId})>[];
      // Fresh bucket: session ids are reused across tests, but AgentRun
      // buckets persist in the singleton.
      AgentService.I.runBucketForTest(s.id)
        ..queue.clear()
        ..activeRunId = null
        ..cancelRequested = false;
      const channel = MethodChannel('ovid/device-overlay-test-task4');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call);
            return true;
          });
      AgentService.setOverlayChannelForTest(channel);
      AgentService.I.overlayRunStarterForTest =
          (String text, ChatSession session) async {
        startedRuns.add((text: text, sessionId: session.id));
      };
      addTearDown(() {
        AgentService.setOverlayChannelForTest(null);
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null);
        AgentService.setRunSessionForTest('');
        AgentService.I.overlayRunStarterForTest = null;
        app.activeSessionId = null;
        app.sessions.removeWhere((x) => x.id == s.id);
      });
    });

    test('busy session: overlay text joins the queue (never starts a run)',
        () async {
      AgentService.I.setActiveRunForTest(s.id, 'run-overlay-busy');
      final before = s.messages.length;
      await AgentService.I.handleDeviceOverlayText('steer left');
      expect(AgentService.I.queuedMessages, contains('steer left'));
      expect(startedRuns, isEmpty);
      expect(s.messages.length, before);
      AgentService.I.setActiveRunForTest(s.id, null);
    });

    test('idle session: overlay text is sent exactly like a composer send',
        () async {
      await AgentService.I.handleDeviceOverlayText('open notes');
      expect(s.messages.isNotEmpty, isTrue);
      final last = s.messages.last;
      expect(last.role, 'user');
      expect(last.content, 'open notes');
      expect(startedRuns, hasLength(1));
      expect(startedRuns.single.text, 'open notes');
      expect(startedRuns.single.sessionId, s.id);
    });

    test('blank overlay text is ignored', () async {
      final before = s.messages.length;
      await AgentService.I.handleDeviceOverlayText('   ');
      expect(s.messages.length, before);
      expect(AgentService.I.queuedMessages, isEmpty);
      expect(startedRuns, isEmpty);
    });

    test('native->Dart dispatcher routes deviceOverlayText', () async {
      await AgentService.I.handleDeviceOverlayMethodCall(
        const MethodCall('deviceOverlayText', 'hello overlay'),
      );
      expect(s.messages.isNotEmpty, isTrue);
      expect(s.messages.last.content, 'hello overlay');
      expect(startedRuns.single.text, 'hello overlay');
    });

    test('send==composer source pin: queue path, message path, run path', () {
      final src = readAgentServiceSource();
      final window = methodWindow(src, 'handleDeviceOverlayText(');
      expect(window, contains('enqueueMessage'));
      expect(window, contains('sendMessage'));
      expect(window, contains('runTask'));
    });
  });

  group('Task 4: overlay Stop Ovid globally stops background work', () {
    late ChatSession s;
    late List<MethodCall> calls;

    setUp(() {
      s = ChatSession(
        id: 't4-stop',
        title: 'S',
        model: 'm',
        mode: 'control',
      );
      app.sessions.insert(0, s);
      app.activeSessionId = s.id;
      AgentService.I.runBucketForTest(s.id);
      calls = <MethodCall>[];
      _gate = null;
      // Fresh bucket: session ids are reused across tests, but AgentRun
      // buckets persist in the singleton.
      AgentService.I.runBucketForTest(s.id)
        ..queue.clear()
        ..activeRunId = null
        ..cancelRequested = false;
      const channel = MethodChannel('ovid/device-overlay-test-task4');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call);
            final pending = _gate;
            if (pending != null) return pending.future;
            return true;
          });
      AgentService.setOverlayChannelForTest(channel);
      DeviceControlService.setMethodChannelForTest(channel);
      addTearDown(() {
        AgentService.setOverlayChannelForTest(null);
        DeviceControlService.setMethodChannelForTest(null);
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null);
        AgentService.setRunSessionForTest('');
        _gate = null;
        app.activeSessionId = null;
        app.sessions.removeWhere((x) => x.id == s.id);
      });
    });

    test('Stop Ovid aborts in-flight device work (queue-empty branch)', () async {
      _gate = Completer<Object?>();
      final future = DeviceControlService.I.tap(node: 7);
      await waitForChannelCall(calls, 'deviceTap');
      final queuePreserved = await AgentService.I.handleDeviceOverlayStop();
      expect(queuePreserved, isFalse);
      _gate!.complete(true);
      expect(await future, kCancelledCopy);
    });

    test('Stop Ovid aborts device work and clears queued Control instructions', () async {
      AgentService.I.queueMessageForTest('follow-up correction');
      _gate = Completer<Object?>();
      final future = DeviceControlService.I.tap(node: 7);
      await waitForChannelCall(calls, 'deviceTap');
      final queuePreserved = await AgentService.I.handleDeviceOverlayStop();
      expect(queuePreserved, isFalse);
      _gate!.complete(true);
      expect(await future, kCancelledCopy);
      expect(
        AgentService.I.queuedMessages,
        isEmpty,
      );
    });

    test('native->Dart dispatcher routes deviceOverlayStop', () async {
      _gate = Completer<Object?>();
      final future = DeviceControlService.I.tap(node: 7);
      await waitForChannelCall(calls, 'deviceTap');
      await AgentService.I.handleDeviceOverlayMethodCall(
        const MethodCall('deviceOverlayStop'),
      );
      _gate!.complete(true);
      expect(await future, kCancelledCopy);
    });

    test('Stop Ovid with no session invalidates device work',
        () async {
      app.activeSessionId = null;
      app.sessions.removeWhere((x) => x.id == s.id);
      final before = DeviceControlService.I.deviceGenerationForTest;
      expect(await AgentService.I.handleDeviceOverlayStop(), isFalse);
      expect(DeviceControlService.I.deviceGenerationForTest, greaterThan(before));
    });

    test('Stop Ovid cancels an in-flight device action without an active session', () async {
      app.activeSessionId = null;
      app.sessions.removeWhere((x) => x.id == s.id);
      _gate = Completer<Object?>();
      final future = DeviceControlService.I.tap(node: 7);
      await waitForChannelCall(calls, 'deviceTap');
      await AgentService.I.handleDeviceOverlayStop();
      _gate!.complete(true);
      expect(await future, kCancelledCopy);
    });
  });

  group('Task 4: native overlay method wiring (backed by Robolectric)', () {
    test('window type is TYPE_ACCESSIBILITY_OVERLAY', () {
      final show = methodWindow(readOverlayServiceSource(), 'fun showOverlay(');
      expect(show, contains('WindowManager.LayoutParams.TYPE_ACCESSIBILITY_OVERLAY'));
    });

    test('no SYSTEM_ALERT_WINDOW permission anywhere', () {
      expect(readManifest(), isNot(contains('SYSTEM_ALERT_WINDOW')));
      expect(readOverlayServiceSource(), isNot(contains('SYSTEM_ALERT_WINDOW')));
      expect(readMainActivitySource(), isNot(contains('SYSTEM_ALERT_WINDOW')));
    });

    test('hidden removes the window (no invisible touch target)', () {
      final hide = methodWindow(readOverlayServiceSource(), 'fun hideOverlay(');
      expect(hide, contains('removeView(view)'));
      expect(hide, contains('clearOverlayRefs()'));
    });

    test('native stop cancels device work before emitting the Dart event', () {
      final src = readOverlayServiceSource();
      final stop = methodWindow(src, 'fun onOverlayStop(');
      expect(stop, contains('stopControlNow()'));
      expect(stop, contains('overlayEventListener?.invoke("deviceOverlayStop", null)'));
      expect(stop.indexOf('stopControlNow()'), lessThan(stop.indexOf('overlayEventListener')));
      final cancel = methodWindow(src, 'fun stopControlNow(');
      expect(cancel, contains('deviceActions.cancel()'));
      expect(cancel, contains('hideOverlay()'));
    });

    test('refused overlay attachment returns an unavailable result', () {
      final show = methodWindow(readOverlayServiceSource(), 'fun showOverlay(');
      expect(show, contains('catch (error: WindowManager.BadTokenException)'));
      expect(show, contains('DeviceActionResult(false, "UNAVAILABLE"'));
    });
  });

  group('Task 4 fix: production ovid/native handler routes overlay events', () {
    late ChatSession s;
    late List<MethodCall> calls;
    late List<({String text, String sessionId})> startedRuns;

    setUp(() {
      s = ChatSession(
        id: 't4-prod-handler',
        title: 'S',
        model: 'm',
        mode: 'control',
      );
      app.sessions.insert(0, s);
      app.activeSessionId = s.id;
      AgentService.I.runBucketForTest(s.id)
        ..queue.clear()
        ..activeRunId = null
        ..cancelRequested = false;
      calls = <MethodCall>[];
      startedRuns = <({String text, String sessionId})>[];
      _gate = null;
      AgentService.I.overlayRunStarterForTest =
          (String text, ChatSession session) async {
        startedRuns.add((text: text, sessionId: session.id));
      };
      // Outgoing Dart->native calls resolve immediately (deviceTap gates on
      // _gate); incoming native->Dart events drive the production handler via
      // _sendProductionNativeCall below.
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel('ovid/native'), (
            call,
          ) async {
            calls.add(call);
            if (call.method == 'deviceTap') {
              final pending = _gate;
              if (pending != null) return pending.future;
            }
            return true;
          });
      AgentNotificationService.I.resetForTest();
      addTearDown(() {
        AgentService.I.overlayRunStarterForTest = null;
        AgentService.setRunSessionForTest('');
        AgentNotificationService.I.resetForTest();
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(const MethodChannel('ovid/native'), null);
        _gate = null;
        app.activeSessionId = null;
        app.sessions.removeWhere((x) => x.id == s.id);
        AgentService.I.runBucketForTest(s.id)
          ..queue.clear()
          ..activeRunId = null
          ..cancelRequested = false;
      });
    });

    test('deviceOverlayText via production handler sends like composer',
        () async {
      await AgentNotificationService.I.init();
      await _sendProductionNativeCall(
        const MethodCall('deviceOverlayText', 'hello overlay'),
      );
      expect(s.messages.isNotEmpty, isTrue);
      expect(s.messages.last.content, 'hello overlay');
      expect(startedRuns, hasLength(1));
      expect(startedRuns.single.text, 'hello overlay');
    });

    test('deviceOverlayStop via production handler aborts in-flight work',
        () async {
      await AgentNotificationService.I.init();
      _gate = Completer<Object?>();
      final future = DeviceControlService.I.tap(node: 7);
      await waitForChannelCall(calls, 'deviceTap');
      await _sendProductionNativeCall(const MethodCall('deviceOverlayStop'));
      _gate!.complete(true);
      expect(await future, kCancelledCopy);
    });

    test('fall-through: onAgentStop still stops the displayed session',
        () async {
      final run = AgentService.I.runBucketForTest(s.id)
        ..activeRunId = 'run-prod-fallthrough';
      final displayed = Completer<void>();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel('ovid/native'), (
            call,
          ) async {
            if (call.method == 'agentServiceStart' ||
                call.method == 'agentServiceUpdate') {
              if (!displayed.isCompleted) displayed.complete();
            }
            return true;
          });
      final notification = AgentNotificationService.I;
      notification.supportedForTest = true;
      await notification.init();
      await notification.agentWorking('working', sessionId: s.id);
      await displayed.future.timeout(const Duration(seconds: 90));
      await _sendProductionNativeCall(const MethodCall('onAgentStop'));
      expect(run.activeRunId, isNull);
      expect(run.cancelRequested, isTrue);
    });

    test('init delegates to the overlay dispatcher first (source pin)', () {
      final src = File(
        'lib/core/agent_notification_service.dart',
      ).readAsStringSync();
      final window = methodWindow(src, 'Future<void> init()');
      expect(window, contains('handleDeviceOverlayMethodCall'));
      expect(
        window.indexOf('handleDeviceOverlayMethodCall'),
        lessThan(window.indexOf('onAgentStop')),
      );
    });
  });
}

Future<void> _sendProductionNativeCall(MethodCall call) async {
  final handled = Completer<void>();
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .handlePlatformMessage(
        'ovid/native',
        const StandardMethodCodec().encodeMethodCall(call),
        (_) => handled.complete(),
      );
  await handled.future.timeout(const Duration(seconds: 2));
}

Completer<Object?>? _gate;
