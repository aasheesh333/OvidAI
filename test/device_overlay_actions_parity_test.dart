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

// Task 5: project-wide parity gate for the Device Overlay + Human-Equivalent
// Actions project (Tasks 1-4 composition).
//
// Each test below crosses at least two tasks' surfaces (overlay contract +
// key/long-press/scroll tools + generation cancellation + submit honesty +
// native revalidation codes) instead of re-pinning one task's unit. Runtime
// behavior runs against fake channels and the public test seams; only the
// no-hardware native window (overlay type, drag, morph) stays source-pinned.

const String kSuperseded = 'cancelled: superseded by a newer run/stop';

Map<String, dynamic> liveRead(String packageName) => {
  'status': 'ok',
  'full': false,
  'package': packageName,
  'added': <dynamic>[],
  'changed': <dynamic>[],
  'removed': <dynamic>[],
};

String dartAgentSource() =>
    File('lib/core/agent_service.dart').readAsStringSync();

String kotlinServiceSource() => File(
  'android/app/src/main/kotlin/com/dhanuk/ovidai/OvidAccessibilityService.kt',
).readAsStringSync();

String kotlinActivitySource() => File(
  'android/app/src/main/kotlin/com/dhanuk/ovidai/MainActivity.kt',
).readAsStringSync();

Future<void> awaitChannelCall(List<MethodCall> calls, String method) async {
  for (var i = 0; i < 200 && !calls.any((c) => c.method == method); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  expect(
    calls.any((c) => c.method == method),
    isTrue,
    reason: 'timed out waiting for $method',
  );
}

Future<void> driveProductionNativeCall(MethodCall call) async {
  final done = Completer<void>();
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .handlePlatformMessage(
        'ovid/native',
        const StandardMethodCodec().encodeMethodCall(call),
        (_) => done.complete(),
      );
  await done.future.timeout(const Duration(seconds: 2));
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

  setUp(() async {
    app.sessions.clear();
    app.activeSessionId = null;
  });

  test('overlay show-guard: Control-only show, unconditional hide', () async {
    final s = ChatSession(id: 'parity-guard', title: 'S', model: 'm');
    app.sessions.insert(0, s);
    app.activeSessionId = s.id;
    final calls = <MethodCall>[];
    const channel = MethodChannel('ovid/parity-overlay-guard');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return true;
        });
    AgentService.setOverlayChannelForTest(channel);
    try {
      // No mode match (default auto): show stays silent.
      await AgentService.I.showDeviceOverlay();
      expect(calls, isEmpty);

      // Control session: show goes out on the contracted name.
      s.mode = 'control';
      await AgentService.I.showDeviceOverlay();
      expect(
        calls.where((c) => c.method == 'deviceOverlayShow'),
        hasLength(1),
      );

      // No active session at all: show stays silent again.
      calls.clear();
      app.activeSessionId = null;
      app.sessions.removeWhere((x) => x.id == s.id);
      await AgentService.I.showDeviceOverlay();
      expect(calls, isEmpty);

      // Hide is unguarded by design: the window must never linger invisibly.
      await AgentService.I.hideDeviceOverlay();
      expect(
        calls.where((c) => c.method == 'deviceOverlayHide'),
        hasLength(1),
      );
    } finally {
      AgentService.setOverlayChannelForTest(null);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
      app.activeSessionId = null;
      app.sessions.removeWhere((x) => x.id == s.id);
    }
  });

  test('overlay send composes with composer; X stops like composer Stop',
      () async {
    final s = ChatSession(
      id: 'parity-send-stop',
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
    final started = <String>[];
    AgentService.I.overlayRunStarterForTest =
        (String text, ChatSession session) async {
      started.add('${session.id}:$text');
    };
    final calls = <MethodCall>[];
    Completer<Object?>? gate;
    const channel = MethodChannel('ovid/parity-overlay-stop');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          final pending = gate;
          if (pending != null) return pending.future;
          return true;
        });
    DeviceControlService.setMethodChannelForTest(channel);
    try {
      // Busy session: overlay text joins the run queue, starts nothing.
      AgentService.I.setActiveRunForTest(s.id, 'run-parity-busy');
      await AgentService.I.handleDeviceOverlayText('steer left');
      expect(AgentService.I.queuedMessages, contains('steer left'));
      expect(started, isEmpty);
      AgentService.I.setActiveRunForTest(s.id, null);
      AgentService.I.runBucketForTest(s.id).queue.clear();

      // Idle session: overlay text lands as a user message and starts a run.
      await AgentService.I.handleDeviceOverlayText('open notes');
      expect(s.messages.last.content, 'open notes');
      expect(started, ['parity-send-stop:open notes']);

      // X while a tap is in flight: the tap reports superseded, queue kept.
      AgentService.I.queueMessageForTest('follow-up');
      gate = Completer<Object?>();
      final tap = DeviceControlService.I.tap(node: 7);
      await awaitChannelCall(calls, 'deviceTap');
      expect(await AgentService.I.handleDeviceOverlayStop(), isTrue);
      gate.complete(true);
      expect(await tap, kSuperseded);
      expect(AgentService.I.queuedMessages, contains('follow-up'));
    } finally {
      DeviceControlService.setMethodChannelForTest(null);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
      AgentService.setRunSessionForTest('');
      AgentService.I.overlayRunStarterForTest = null;
      AgentService.I.runBucketForTest(s.id)
        ..queue.clear()
        ..activeRunId = null
        ..cancelRequested = false;
      app.activeSessionId = null;
      app.sessions.removeWhere((x) => x.id == s.id);
    }
  });

  test('production ovid/native handler delivers overlay send and Stop',
      () async {
    final s = ChatSession(
      id: 'parity-prod',
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
    final started = <String>[];
    AgentService.I.overlayRunStarterForTest =
        (String text, ChatSession session) async {
      started.add(text);
    };
    final calls = <MethodCall>[];
    Completer<Object?>? gate;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('ovid/native'), (
          call,
        ) async {
          calls.add(call);
          if (call.method == 'deviceTap' && gate != null) {
            return gate.future;
          }
          return true;
        });
    AgentNotificationService.I.resetForTest();
    try {
      await AgentNotificationService.I.init();

      // Send arriving through the production handler acts like composer send.
      await driveProductionNativeCall(
        const MethodCall('deviceOverlayText', 'hello overlay'),
      );
      expect(s.messages.last.content, 'hello overlay');
      expect(started, ['hello overlay']);

      // Stop arriving through the production handler cancels device work.
      gate = Completer<Object?>();
      final tap = DeviceControlService.I.tap(node: 7);
      await awaitChannelCall(calls, 'deviceTap');
      await driveProductionNativeCall(const MethodCall('deviceOverlayStop'));
      gate.complete(true);
      expect(await tap, kSuperseded);

      // The delegation sits before the legacy stop/exit arms (source pin).
      final src = File(
        'lib/core/agent_notification_service.dart',
      ).readAsStringSync();
      final initBody = src.substring(src.indexOf('Future<void> init()'));
      expect(initBody, contains('handleDeviceOverlayMethodCall'));
      expect(
        initBody.indexOf('handleDeviceOverlayMethodCall'),
        lessThan(initBody.indexOf('onAgentStop')),
      );
    } finally {
      AgentService.I.overlayRunStarterForTest = null;
      AgentService.setRunSessionForTest('');
      AgentNotificationService.I.resetForTest();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel('ovid/native'), null);
      AgentService.I.runBucketForTest(s.id)
        ..queue.clear()
        ..activeRunId = null
        ..cancelRequested = false;
      app.activeSessionId = null;
      app.sessions.removeWhere((x) => x.id == s.id);
    }
  });

  test('key vocabulary: closed set dispatches, anything else refused',
      () async {
    final s = ChatSession(
      id: 'parity-key',
      title: 'S',
      model: 'm',
      mode: 'control',
    );
    app.sessions.insert(0, s);
    app.activeSessionId = s.id;
    AgentService.setRunSessionForTest(s.id);
    final calls = <MethodCall>[];
    const channel = MethodChannel('ovid/parity-key');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          if (call.method == 'deviceRead') return liveRead('com.example.notes');
          return true;
        });
    DeviceControlService.setMethodChannelForTest(channel);
    try {
      // Outside the vocabulary: honest refusal, channel untouched.
      final refused = await AgentService.I.dispatchForTest('device_key', {
        'key': 'f5',
      });
      expect(refused, contains('BAD_KEY'));
      expect(refused.toLowerCase(), contains('inject'));
      expect(calls.where((c) => c.method == 'deviceKey'), isEmpty);

      // Inside the vocabulary: every key reaches native exactly once.
      for (final key in const [
        'enter',
        'volume_up',
        'volume_down',
        'volume_mute',
        'media_play_pause',
        'media_next',
        'media_previous',
      ]) {
        calls.clear();
        final result = await AgentService.I.dispatchForTest('device_key', {
          'key': key,
        });
        expect(result, contains(key));
        final sent = calls.where((c) => c.method == 'deviceKey');
        expect(sent, hasLength(1));
        expect((sent.single.arguments as Map)['key'], key);
      }
    } finally {
      DeviceControlService.setMethodChannelForTest(null);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
      AgentService.setRunSessionForTest('');
      app.activeSessionId = null;
      app.sessions.removeWhere((x) => x.id == s.id);
    }
  });

  test('long-press clamp and scroll honesty compose over one channel',
      () async {
    final s = ChatSession(
      id: 'parity-press-scroll',
      title: 'S',
      model: 'm',
      mode: 'control',
    );
    app.sessions.insert(0, s);
    app.activeSessionId = s.id;
    AgentService.setRunSessionForTest(s.id);
    final calls = <MethodCall>[];
    Object? Function(MethodCall call)? override;
    const channel = MethodChannel('ovid/parity-press-scroll');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          if (call.method == 'deviceRead') return liveRead('com.example.notes');
          final fn = override;
          if (fn != null) return fn(call);
          return true;
        });
    DeviceControlService.setMethodChannelForTest(channel);
    try {
      Future<Object?> pressedDuration(Map<String, dynamic> args) async {
        calls.clear();
        await AgentService.I.dispatchForTest('device_long_press', args);
        final sent = calls.where((c) => c.method == 'deviceLongPress');
        expect(sent, hasLength(1));
        return (sent.single.arguments as Map)['duration_ms'];
      }

      expect(await pressedDuration({'x': 10, 'y': 20}), 600);
      expect(
        await pressedDuration({'x': 10, 'y': 20, 'duration_ms': 5000}),
        3000,
      );
      expect(await pressedDuration({'x': 10, 'y': 20, 'duration_ms': 50}), 200);
      expect(
        await AgentService.I.dispatchForTest('device_long_press', {'node': 7}),
        contains('long-pressed node 7'),
      );

      // Scroll dispatches the requested direction verbatim ...
      calls.clear();
      expect(
        await AgentService.I.dispatchForTest('device_scroll', {
          'node': 5,
          'direction': 'up',
        }),
        contains('scrolled node 5 up'),
      );
      expect(
        (calls.singleWhere((c) => c.method == 'deviceScroll').arguments
                as Map)['direction'],
        'up',
      );

      // ... names the native API-floor fallback instead of hiding it ...
      override = (_) => 'Scrolled up via backward fallback (below API 23).';
      expect(
        await AgentService.I.dispatchForTest('device_scroll', {
          'node': 5,
          'direction': 'up',
        }),
        contains('fallback'),
      );

      // ... and surfaces a non-scrollable node honestly.
      override = (call) {
        if (call.method == 'deviceScroll') {
          throw PlatformException(
            code: 'NOT_SCROLLABLE',
            message: 'Node 5 is not scrollable.',
          );
        }
        return true;
      };
      expect(
        await AgentService.I.dispatchForTest('device_scroll', {
          'node': 5,
          'direction': 'forward',
        }),
        contains('not scrollable'),
      );
    } finally {
      DeviceControlService.setMethodChannelForTest(null);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
      AgentService.setRunSessionForTest('');
      app.activeSessionId = null;
      app.sessions.removeWhere((x) => x.id == s.id);
    }
  });

  test('cancellation: run-start and Stop supersede in-flight device work',
      () async {
    final s = ChatSession(
      id: 'parity-cancel',
      title: 'S',
      model: 'm',
      mode: 'control',
    );
    app.sessions.insert(0, s);
    app.activeSessionId = s.id;
    AgentService.setRunSessionForTest(s.id);
    AgentService.I.runBucketForTest(s.id);
    final calls = <MethodCall>[];
    Completer<Object?>? gate;
    const channel = MethodChannel('ovid/parity-cancel');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          if (call.method == 'deviceRead') return liveRead('com.example.notes');
          final pending = gate;
          if (pending != null) return pending.future;
          return true;
        });
    DeviceControlService.setMethodChannelForTest(channel);
    try {
      // A fresh run generation supersedes a tap dispatched before it.
      gate = Completer<Object?>();
      final first = DeviceControlService.I.tap(node: 1);
      await awaitChannelCall(calls, 'deviceTap');
      DeviceControlService.I.beginDeviceGeneration();
      gate.complete(true);
      expect(await first, kSuperseded);
      expect(
        DeviceControlService.isCancelledResult(kSuperseded),
        isTrue,
      );

      // Composer Stop supersedes a dispatched tool call end to end.
      gate = Completer<Object?>();
      final viaTool = AgentService.I.dispatchForTest('device_tap', {'node': 1});
      await awaitChannelCall(calls, 'deviceTap');
      expect(AgentService.I.stopRequested(sessionId: s.id), isFalse);
      gate.complete(true);
      expect(await viaTool, kSuperseded);

      // Untouched calls still return the native result verbatim.
      gate = null;
      calls.clear();
      expect(await DeviceControlService.I.key('enter'), true);
      expect(
        calls.where((c) => c.method == 'deviceKey'),
        hasLength(1),
      );
    } finally {
      DeviceControlService.setMethodChannelForTest(null);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
      AgentService.setRunSessionForTest('');
      app.activeSessionId = null;
      app.sessions.removeWhere((x) => x.id == s.id);
    }
  });

  test('submit honesty: typed/submitted split, never overclaimed', () async {
    final s = ChatSession(
      id: 'parity-submit',
      title: 'S',
      model: 'm',
      mode: 'control',
    );
    app.sessions.insert(0, s);
    app.activeSessionId = s.id;
    AgentService.setRunSessionForTest(s.id);
    Object? Function(MethodCall call)? override;
    const channel = MethodChannel('ovid/parity-submit');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'deviceRead') return liveRead('com.example.notes');
          final fn = override;
          if (fn != null) return fn(call);
          return true;
        });
    DeviceControlService.setMethodChannelForTest(channel);
    try {
      // Typed without submit: submitted stays false, never implied.
      override = (_) => {'typed': true, 'submitted': false, 'message': ''};
      var result = await AgentService.I.dispatchForTest('device_type', {
        'node': 3,
        'text': 'hello',
      });
      expect(result, contains('(typed=true, submitted=false)'));
      expect(result, isNot(contains(' and submitted')));

      // IME-accepted submit: both flags true.
      override = (_) => {'typed': true, 'submitted': true, 'message': ''};
      result = await AgentService.I.dispatchForTest('device_type', {
        'node': 3,
        'text': 'hello',
        'submit': true,
      });
      expect(result, contains('(typed=true, submitted=true)'));

      // IME-refused submit: the split plus the native reason, verbatim.
      override = (_) => {
        'typed': true,
        'submitted': false,
        'message': 'Text was entered, but the input did not accept IME Enter.',
      };
      result = await AgentService.I.dispatchForTest('device_type', {
        'node': 3,
        'text': 'hello',
        'submit': true,
      });
      expect(result, contains('(typed=true, submitted=false)'));
      expect(result, contains('did not accept IME Enter'));

      // A superseded type reports cancellation, not typed text.
      final pending = Completer<Object?>();
      override = (call) {
        if (call.method == 'deviceType') return pending.future;
        return true;
      };
      final future = AgentService.I.dispatchForTest('device_type', {
        'node': 3,
        'text': 'hello',
        'submit': true,
      });
      await Future<void>.delayed(const Duration(milliseconds: 100));
      DeviceControlService.I.cancelDeviceActions();
      pending.complete({'typed': true, 'submitted': true, 'message': ''});
      expect(await future, kSuperseded);
    } finally {
      DeviceControlService.setMethodChannelForTest(null);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
      AgentService.setRunSessionForTest('');
      app.activeSessionId = null;
      app.sessions.removeWhere((x) => x.id == s.id);
    }
  });

  test('native pins: ancestor fallback, revalidation codes, overlay window',
      () {
    final service = kotlinServiceSource();
    final activity = kotlinActivitySource();
    final manifest = File(
      'android/app/src/main/AndroidManifest.xml',
    ).readAsStringSync();

    // Task 1: stubborn rows click through up to 3 ancestors ...
    expect(service.toLowerCase(), contains('ancestor'));
    expect(service, contains('ACTION_CLICK'));
    expect(service, contains('.parent'));
    // ... every node action revalidates the handle first ...
    expect(
      RegExp(r'\.refresh\(\)').allMatches(service).length,
      greaterThanOrEqualTo(4),
    );
    expect(service, contains('INVALID_NODE'));
    expect(service.toLowerCase(), contains('re-read'));
    // ... and type rechecks the sensitive/editable gates on the live node.
    expect(service, contains('PASSWORD_FIELD'));
    expect(service, contains('NOT_EDITABLE'));
    expect(service, contains('isPassword'));
    expect(service, contains('isEditable'));

    // Tasks 1-2: the new native surface keeps its contracted shapes.
    expect(service, contains('fun longPress('));
    expect(service, contains('ACTION_LONG_CLICK'));
    expect(service, contains('fun scrollNode('));
    expect(service, contains('isScrollable'));
    expect(service, contains('NOT_SCROLLABLE'));
    expect(service.toLowerCase(), contains('fallback'));
    expect(service, contains('fun pressKey('));
    expect(service, contains('BAD_KEY'));
    expect(service.toLowerCase(), contains('inject'));
    for (final route in [
      '"deviceLongPress"',
      '"deviceScroll"',
      '"deviceKey"',
      '"deviceOverlayShow"',
      '"deviceOverlayHide"',
    ]) {
      expect(activity, contains(route));
    }

    // Task 4: accessibility overlay, draggable, morphing — no new permission.
    expect(service, contains('TYPE_ACCESSIBILITY_OVERLAY'));
    expect(manifest, isNot(contains('SYSTEM_ALERT_WINDOW')));
    expect(service, isNot(contains('SYSTEM_ALERT_WINDOW')));
    expect(activity, isNot(contains('SYSTEM_ALERT_WINDOW')));
    expect(service, contains('fun showOverlay('));
    expect(service, contains('fun hideOverlay('));
    expect(service, contains('removeView'));
    expect(service, contains('updateViewLayout'));
    expect(service, contains('ACTION_MOVE'));
    expect(service, contains('TextWatcher'));
    expect(service, contains('isNullOrBlank'));
    expect(service, contains('deviceOverlayText'));
    expect(service, contains('deviceOverlayStop'));
    expect(service, contains('cornerRadius'));
  });
}
