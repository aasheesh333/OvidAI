import 'dart:async';
import 'dart:ffi' as ffi;
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/agent_service.dart';
import 'package:ovid_ai/core/device_control_service.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqlite3/open.dart' show open, OperatingSystem;

// Task 3: Cancellation + honest submit contract.
//
// - DeviceControlService carries a monotonic device generation bumped by
//   beginDeviceGeneration (run start) and cancelDeviceActions (Stop).
//   In-flight device_* calls superseded by a bump report
//   `cancelled: superseded by a newer run/stop` instead of the native result.
// - Already-dispatched gestures run to completion (Android limit); only
//   Dart-awaited/queued work is cancellable.
// - device_type surfaces the native typed/submitted/message split verbatim:
//   typed=true only if SET_TEXT accepted, submitted=true only if IME
//   accepted, API<30 submit -> typed=true, submitted=false + API-floor msg.
//
// No hardware here: fake channel + seams only.

const String kCancelledCopy = 'cancelled: superseded by a newer run/stop';

String readAgentServiceSource() =>
    File('lib/core/agent_service.dart').readAsStringSync();

Map<String, dynamic> okRead(String packageName) => {
  'status': 'ok',
  'full': false,
  'package': packageName,
  'added': <dynamic>[],
  'changed': <dynamic>[],
  'removed': <dynamic>[],
};

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

  setUp(() async {
    app.sessions.clear();
    app.activeSessionId = null;
  });

  group('Task 3: generation tokens (DeviceControlService)', () {
    late List<MethodCall> calls;
    Completer<Object?>? gate;
    Object? Function(MethodCall call)? stub;

    setUp(() {
      calls = <MethodCall>[];
      gate = null;
      stub = null;
      const channel = MethodChannel('ovid/device-actions-test-task3');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call);
            final override = stub;
            if (override != null) return override(call);
            final pending = gate;
            if (pending != null &&
                call.method != 'deviceRead' &&
                call.method != 'deviceServiceEnabled') {
              return pending.future;
            }
            return true;
          });
      DeviceControlService.setMethodChannelForTest(channel);
      addTearDown(() {
        DeviceControlService.setMethodChannelForTest(null);
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null);
      });
    });

    test('cancelled copy is the exact contracted string', () {
      expect(
        DeviceControlService.cancelledSupersededMessage,
        kCancelledCopy,
      );
    });

    test('beginDeviceGeneration supersedes an in-flight tap', () async {
      gate = Completer<Object?>();
      final future = DeviceControlService.I.tap(node: 1);
      await waitForChannelCall(calls, 'deviceTap');
      DeviceControlService.I.beginDeviceGeneration();
      gate!.complete(true);
      expect(await future, kCancelledCopy);
    });

    test('cancelDeviceActions supersedes every device_* call uniformly',
        () async {
      final cases = <({String name, String channel, Future<Object?> Function() call})>[
        (
          name: 'tap',
          channel: 'deviceTap',
          call: () => DeviceControlService.I.tap(node: 1),
        ),
        (
          name: 'type',
          channel: 'deviceType',
          call: () => DeviceControlService.I.type(node: 1, text: 'hi'),
        ),
        (
          name: 'swipe',
          channel: 'deviceSwipe',
          call: () => DeviceControlService.I.swipe(
            fromX: 0,
            fromY: 0,
            toX: 1,
            toY: 1,
          ),
        ),
        (
          name: 'systemNav',
          channel: 'deviceSystemNav',
          call: () => DeviceControlService.I.systemNav('back'),
        ),
        (
          name: 'key',
          channel: 'deviceKey',
          call: () => DeviceControlService.I.key('enter'),
        ),
        (
          name: 'longPress',
          channel: 'deviceLongPress',
          call: () => DeviceControlService.I.longPress(node: 1),
        ),
        (
          name: 'scroll',
          channel: 'deviceScroll',
          call: () =>
              DeviceControlService.I.scroll(node: 1, direction: 'forward'),
        ),
        (
          name: 'screenshot',
          channel: 'deviceScreenshot',
          call: () => DeviceControlService.I.screenshot(),
        ),
      ];
      for (final c in cases) {
        calls.clear();
        gate = Completer<Object?>();
        final future = c.call();
        await waitForChannelCall(calls, c.channel);
        DeviceControlService.I.cancelDeviceActions();
        gate!.complete(true);
        expect(await future, kCancelledCopy, reason: c.name);
        expect(
          DeviceControlService.isCancelledResult(await future),
          isTrue,
          reason: c.name,
        );
      }
    });

    test('non-superseded calls return the native result untouched', () async {
      stub = (call) {
        if (call.method == 'deviceTap') return 'tapped-ok';
        if (call.method == 'deviceType') {
          return {'typed': true, 'submitted': false, 'message': ''};
        }
        if (call.method == 'deviceScreenshot') return '/tmp/shot.png';
        return true;
      };
      expect(await DeviceControlService.I.tap(node: 1), 'tapped-ok');
      expect(
        await DeviceControlService.I.type(node: 1, text: 'hi'),
        {'typed': true, 'submitted': false, 'message': ''},
      );
      expect(await DeviceControlService.I.screenshot(), '/tmp/shot.png');
      expect(
        DeviceControlService.isCancelledResult('tapped-ok'),
        isFalse,
      );
    });

    test('native errors still surface when not superseded', () async {
      stub = (call) {
        if (call.method == 'deviceTap') {
          throw PlatformException(
            code: 'NOT_CLICKABLE',
            message: 'Node 1 refused the click.',
          );
        }
        return true;
      };
      await expectLater(
        DeviceControlService.I.tap(node: 1),
        throwsA(isA<PlatformException>()),
      );
    });

    test('native errors landing after a bump report cancellation', () async {
      gate = Completer<Object?>();
      stub = (call) {
        if (call.method == 'deviceTap') return gate!.future;
        return true;
      };
      final future = DeviceControlService.I.tap(node: 1);
      await waitForChannelCall(calls, 'deviceTap');
      DeviceControlService.I.cancelDeviceActions();
      gate!.completeError(
        PlatformException(code: 'ACTION_FAILED', message: 'late failure'),
      );
      expect(await future, kCancelledCopy);
    });

    test('device reads stay unguarded (live-foreground verification)', () async {
      stub = (call) {
        if (call.method == 'deviceRead') return okRead('com.example.notes');
        return true;
      };
      DeviceControlService.I.beginDeviceGeneration();
      final raw = await DeviceControlService.I.readRaw();
      expect(raw['status'], 'ok');
      expect(raw['package'], 'com.example.notes');
    });
  });

  group('Task 3: Stop bumps generation', () {
    late ChatSession s;
    late List<MethodCall> calls;
    Completer<Object?>? gate;

    setUp(() {
      s = ChatSession(id: 't3-stop', title: 'S', model: 'm', mode: 'control');
      app.sessions.insert(0, s);
      app.activeSessionId = s.id;
      AgentService.setRunSessionForTest(s.id);
      AgentService.I.runBucketForTest(s.id);
      calls = <MethodCall>[];
      gate = null;
      const channel = MethodChannel('ovid/device-actions-test-task3');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call);
            if (call.method == 'deviceRead') {
              return okRead('com.example.notes');
            }
            final pending = gate;
            if (pending != null) return pending.future;
            return true;
          });
      DeviceControlService.setMethodChannelForTest(channel);
      addTearDown(() {
        DeviceControlService.setMethodChannelForTest(null);
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null);
        AgentService.setRunSessionForTest('');
        app.activeSessionId = null;
        app.sessions.removeWhere((x) => x.id == s.id);
      });
    });

    test('stopRequested aborts in-flight work (queue-empty branch)', () async {
      gate = Completer<Object?>();
      final future = AgentService.I.dispatchForTest('device_tap', {'node': 1});
      await waitForChannelCall(calls, 'deviceTap');
      final queuePreserved = AgentService.I.stopRequested(sessionId: s.id);
      expect(queuePreserved, isFalse);
      gate!.complete(true);
      expect(await future, kCancelledCopy);
    });

    test('stopRequested aborts in-flight work (queue-preserved branch)',
        () async {
      AgentService.I.queueMessageForTest('follow-up correction');
      gate = Completer<Object?>();
      final future = AgentService.I.dispatchForTest('device_tap', {'node': 1});
      await waitForChannelCall(calls, 'deviceTap');
      final queuePreserved = AgentService.I.stopRequested(sessionId: s.id);
      expect(queuePreserved, isTrue);
      gate!.complete(true);
      expect(await future, kCancelledCopy);
    });

    test('stopRequested on an unknown session stops nothing', () {
      final before = DeviceControlService.I.deviceGenerationForTest;
      expect(
        AgentService.I.stopRequested(sessionId: 'no-such-session'),
        isFalse,
      );
      expect(DeviceControlService.I.deviceGenerationForTest, before);
    });

    test('cancelAllRuns aborts in-flight work', () async {
      gate = Completer<Object?>();
      final future = AgentService.I.dispatchForTest('device_tap', {'node': 1});
      await waitForChannelCall(calls, 'deviceTap');
      AgentService.I.cancelAllRuns();
      gate!.complete(true);
      expect(await future, kCancelledCopy);
    });

    test('run entry and Stop paths are wired to the generation API', () {
      final src = readAgentServiceSource();
      final runTaskIdx = src.indexOf('Future<void> runTask(');
      expect(runTaskIdx, greaterThanOrEqualTo(0));
      expect(
        src.substring(runTaskIdx, runTaskIdx + 3000),
        contains('beginDeviceGeneration'),
        reason: 'runTask entry must open a fresh device generation',
      );
      final stopIdx = src.indexOf('bool stopRequested(');
      expect(stopIdx, greaterThanOrEqualTo(0));
      expect(
        src.substring(stopIdx, stopIdx + 1500),
        contains('cancelDeviceActions'),
        reason: 'stopRequested must route Stop through cancelDeviceActions',
      );
      final panicIdx = src.indexOf('void cancelAllRuns()');
      expect(panicIdx, greaterThanOrEqualTo(0));
      expect(
        src.substring(panicIdx, panicIdx + 1500),
        contains('cancelDeviceActions'),
        reason: 'cancelAllRuns must route panic Stop through cancelDeviceActions',
      );
    });
  });

  group('Task 3: honest submit contract', () {
    late ChatSession s;
    late Object? Function(MethodCall call)? stub;

    setUp(() {
      s = ChatSession(id: 't3-submit', title: 'S', model: 'm', mode: 'control');
      app.sessions.insert(0, s);
      app.activeSessionId = s.id;
      AgentService.setRunSessionForTest(s.id);
      stub = null;
      const channel = MethodChannel('ovid/device-actions-test-task3');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            if (call.method == 'deviceRead') {
              return okRead('com.example.notes');
            }
            final override = stub;
            if (override != null) return override(call);
            return true;
          });
      DeviceControlService.setMethodChannelForTest(channel);
      addTearDown(() {
        DeviceControlService.setMethodChannelForTest(null);
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null);
        AgentService.setRunSessionForTest('');
        app.activeSessionId = null;
        app.sessions.removeWhere((x) => x.id == s.id);
      });
    });

    test('submit matrix surfaces typed/submitted/message verbatim', () async {
      // No submit requested: typed only, never claims submitted.
      stub = (_) => {'typed': true, 'submitted': false, 'message': ''};
      var result = await AgentService.I.dispatchForTest('device_type', {
        'node': 3,
        'text': 'hello',
      });
      expect(result, 'typed 5 characters into node 3 (typed=true, submitted=false)');
      expect(result, isNot(contains('submitted=true')));
      expect(result, isNot(contains(' and submitted')));

      // Submit accepted by IME.
      stub = (_) => {'typed': true, 'submitted': true, 'message': ''};
      result = await AgentService.I.dispatchForTest('device_type', {
        'node': 3,
        'text': 'hello',
        'submit': true,
      });
      expect(
        result,
        'typed 5 characters into node 3 (typed=true, submitted=true)',
      );
      expect(result, isNot(contains(' and submitted')));

      // Submit refused by IME: honest split + native message verbatim.
      stub = (_) => {
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
      expect(
        result,
        contains('Text was entered, but the input did not accept IME Enter.'),
      );
      expect(result, isNot(contains(' and submitted')));

      // API floor: typed kept, submitted false, floor message verbatim.
      stub = (_) => {
        'typed': true,
        'submitted': false,
        'message': 'Text was entered, but IME Enter requires Android 11 or newer.',
      };
      result = await AgentService.I.dispatchForTest('device_type', {
        'node': 3,
        'text': 'hello',
        'submit': true,
      });
      expect(result, contains('(typed=true, submitted=false)'));
      expect(result, contains('Android 11'));
      expect(result, isNot(contains(' and submitted')));
    });

    test('failed type claims nothing about typed text', () async {
      stub = (_) {
        throw PlatformException(
          code: 'NOT_EDITABLE',
          message: 'The selected node is not editable.',
        );
      };
      final result = await AgentService.I.dispatchForTest('device_type', {
        'node': 3,
        'text': 'hello',
        'submit': true,
      });
      expect(result, contains('device_type failed'));
      expect(result, isNot(contains('typed=true')));
      expect(result, isNot(contains(' and submitted')));
    });

    test('superseded type reports cancellation, not typed text', () async {
      final pending = Completer<Object?>();
      stub = (call) {
        if (call.method == 'deviceType') return pending.future;
        return true;
      };
      final future = AgentService.I.dispatchForTest('device_type', {
        'node': 3,
        'text': 'hello',
        'submit': true,
      });
      // Let the deviceType invoke land on the channel before superseding.
      for (var i = 0; i < 200; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      DeviceControlService.I.cancelDeviceActions();
      pending.complete({'typed': true, 'submitted': true, 'message': ''});
      expect(await future, kCancelledCopy);
    });

    test('formatter pins the verbatim contract incl. API floor', () {
      String fmt(Object? native, {bool submit = true}) =>
          AgentService.formatDeviceTypeResultForTest(
            text: 'hello',
            node: 3,
            result: native,
          );
      expect(
        fmt({'typed': true, 'submitted': false, 'message': ''}, submit: false),
        'typed 5 characters into node 3 (typed=true, submitted=false)',
      );
      expect(
        fmt({'typed': true, 'submitted': true, 'message': ''}),
        'typed 5 characters into node 3 (typed=true, submitted=true)',
      );
      expect(
        fmt({
          'typed': true,
          'submitted': false,
          'message':
              'Text was entered, but IME Enter requires Android 11 or newer.',
        }),
        'typed 5 characters into node 3 (typed=true, submitted=false): '
        'Text was entered, but IME Enter requires Android 11 or newer.',
      );
      // Coordinate-targeted type (no node) keeps the same split.
      expect(
        AgentService.formatDeviceTypeResultForTest(
          text: 'hi',
          node: null,
          result: {'typed': true, 'submitted': false, 'message': ''},
        ),
        'typed 2 characters (typed=true, submitted=false)',
      );
      // Opaque truthy (legacy mocks): typed accepted, submit unconfirmed.
      expect(
        fmt(true),
        'typed 5 characters into node 3 (typed=true, submitted=false)',
      );
    });
  });
}
