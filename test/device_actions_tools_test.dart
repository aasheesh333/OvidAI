import 'dart:ffi' as ffi;
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/agent_service.dart';
import 'package:ovid_ai/core/device_control_service.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqlite3/open.dart' show open, OperatingSystem;

// Task 2: Key events + new tools surface — device_key, device_long_press,
// device_scroll. Native key behavior is source-pinned (no hardware); the
// Dart side runs against a fake channel.

String readServiceSource() => File(
  'android/app/src/main/kotlin/com/dhanuk/ovidai/OvidAccessibilityService.kt',
).readAsStringSync();

String readMainActivitySource() => File(
  'android/app/src/main/kotlin/com/dhanuk/ovidai/MainActivity.kt',
).readAsStringSync();

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

  group('Task 2: native key dispatch surface', () {
    test('service exposes a closed-vocabulary pressKey entry point', () {
      final src = readServiceSource();
      expect(src, contains('fun pressKey('));
      for (final key in <String>[
        '"enter"',
        '"volume_up"',
        '"volume_down"',
        '"volume_mute"',
        '"media_play_pause"',
        '"media_next"',
        '"media_previous"',
      ]) {
        expect(src, contains(key), reason: 'missing key $key');
      }
    });

    test('volume keys use AudioManager stream volume, media keys dispatch', () {
      final src = readServiceSource();
      expect(src, contains('adjustStreamVolume'));
      expect(src, contains('STREAM_MUSIC'));
      expect(src, contains('dispatchMediaKeyEvent'));
    });

    test('unknown keys are refused as BAD_KEY naming the Android limit', () {
      final src = readServiceSource();
      expect(src, contains('BAD_KEY'));
      expect(src.toLowerCase(), contains('inject'));
    });

    test('enter reuses the IME submit path with honest focus/editable errors',
        () {
      final src = readServiceSource();
      expect(src, contains('Api30Actions.submit'));
      expect(src, contains('NO_FOCUS'));
      expect(src, contains('NOT_EDITABLE'));
    });

    test('channel routes deviceKey in camelCase following the arg pattern',
        () {
      final src = readMainActivitySource();
      expect(src, contains('"deviceKey"'));
      expect(src, contains('service.pressKey('));
      expect(src, contains('completeDeviceAction'));
      expect(src, contains('BAD_ARGS'));
      expect(src, isNot(contains('device_key"')));
    });

    test('long-press clamp agrees in Dart and native (600 default, 200-3000)',
        () {
      final native = readServiceSource();
      expect(native, contains('coerceIn'));
      final dart = File(
        'lib/core/device_control_service.dart',
      ).readAsStringSync();
      expect(dart, contains('600'));
      expect(dart, contains('200'));
      expect(dart, contains('3000'));
      expect(dart, contains('clamp'));
    });
  });

  group('Task 2: tool schemas', () {
    test('new tools are advertised with closed shapes', () {
      final schemas = <String, Map>{};
      for (final tool in AgentService.I.toolsForTest()) {
        final fn = tool['function'] as Map;
        final name = fn['name'] as String;
        if (name == 'device_key' ||
            name == 'device_long_press' ||
            name == 'device_scroll') {
          schemas[name] = fn['parameters'] as Map;
        }
      }
      expect(schemas.keys.toSet(), {
        'device_key',
        'device_long_press',
        'device_scroll',
      });
      for (final schema in schemas.values) {
        expect(schema['additionalProperties'], isFalse);
      }
      expect(schemas['device_key']!['required'], ['key']);
      expect(
        (schemas['device_key']!['properties'] as Map)['key']['enum'],
        [
          'enter',
          'volume_up',
          'volume_down',
          'volume_mute',
          'media_play_pause',
          'media_next',
          'media_previous',
        ],
      );
      expect(
        (schemas['device_long_press']!['properties'] as Map).keys,
        containsAll(['node', 'x', 'y', 'duration_ms']),
      );
      expect(schemas['device_long_press']!['anyOf'], [
        {
          'required': ['node'],
        },
        {
          'required': ['x', 'y'],
        },
      ]);
      expect(schemas['device_scroll']!['required'], ['node', 'direction']);
      expect(
        (schemas['device_scroll']!['properties'] as Map)['direction']['enum'],
        ['forward', 'backward', 'up', 'down', 'left', 'right'],
      );
    });
  });

  group('Task 2: gates', () {
    for (final name in const [
      'device_key',
      'device_long_press',
      'device_scroll',
    ]) {
      test('$name is control-mode-only and gated', () async {
        final s = ChatSession(id: 't2-$name', title: 'S', model: 'm');
        app.sessions.insert(0, s);
        app.activeSessionId = s.id;
        AgentService.setRunSessionForTest(s.id);
        addTearDown(() {
          AgentService.setRunSessionForTest('');
          app.activeSessionId = null;
          app.sessions.removeWhere((x) => x.id == s.id);
        });
        // Read-only gate first.
        s.mode = 'safe';
        expect(
          await AgentService.I.dispatchForTest(name, const {}),
          contains('READ-ONLY MODE'),
        );
        // Control-mode gate.
        s.mode = 'auto';
        expect(
          await AgentService.I.dispatchForTest(name, const {}),
          contains('requires Control mode'),
        );
        // Plan gate.
        s
          ..mode = 'control'
          ..planMode = true;
        expect(
          await AgentService.I.dispatchForTest(name, const {}),
          contains('PLAN MODE ACTIVE'),
        );
        // Subagent gate.
        s
          ..planMode = false
          ..parentId = 'parent';
        expect(
          await AgentService.I.dispatchForTest(name, const {}),
          contains('Subagents cannot control the device'),
        );
      });
    }
  });

  group('Task 2: validation, clamps, and honest results', () {
    late ChatSession s;
    late List<MethodCall> calls;
    late String packageName;
    late Object? Function(MethodCall call)? stub;

    setUp(() {
      s = ChatSession(id: 't2-live', title: 'S', model: 'm', mode: 'control');
      app.sessions.insert(0, s);
      app.activeSessionId = s.id;
      AgentService.setRunSessionForTest(s.id);
      calls = <MethodCall>[];
      packageName = 'com.example.notes';
      stub = null;
      const channel = MethodChannel('ovid/device-actions-test-task2');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call);
            if (call.method == 'deviceRead') {
              return {
                'status': 'ok',
                'full': false,
                'package': packageName,
                'added': <dynamic>[],
                'changed': <dynamic>[],
                'removed': <dynamic>[],
              };
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

    test('device_key refuses unknown keys without touching the channel',
        () async {
      final result = await AgentService.I.dispatchForTest('device_key', {
        'key': 'f5',
      });
      expect(result, contains('BAD_KEY'));
      expect(result.toLowerCase(), contains('inject'));
      expect(calls.where((c) => c.method == 'deviceKey'), isEmpty);
    });

    test('device_key requires a key', () async {
      expect(
        await AgentService.I.dispatchForTest('device_key', const {}),
        contains('device_key requires key'),
      );
      expect(calls.where((c) => c.method == 'deviceKey'), isEmpty);
    });

    test('device_key dispatches the closed vocabulary', () async {
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
        expect(result, contains(key), reason: key);
        final dispatched = calls.where((c) => c.method == 'deviceKey');
        expect(dispatched, hasLength(1), reason: key);
        expect(
          (dispatched.single.arguments as Map)['key'],
          key,
          reason: key,
        );
      }
    });

    test('device_key surfaces the native BAD_KEY and API-floor messages',
        () async {
      stub = (call) {
        if (call.method == 'deviceKey') {
          throw PlatformException(
            code: 'BAD_KEY',
            message:
                'Unknown key. Android does not allow apps to inject arbitrary keycodes.',
          );
        }
        return true;
      };
      expect(
        await AgentService.I.dispatchForTest('device_key', {'key': 'enter'}),
        contains('inject'),
      );
      stub = (call) {
        if (call.method == 'deviceKey') {
          throw PlatformException(
            code: 'UNSUPPORTED',
            message: 'IME Enter requires Android 11 or newer.',
          );
        }
        return true;
      };
      expect(
        await AgentService.I.dispatchForTest('device_key', {'key': 'enter'}),
        contains('Android 11'),
      );
    });

    test('device_long_press requires a node or x/y', () async {
      expect(
        await AgentService.I.dispatchForTest('device_long_press', const {}),
        contains('device_long_press requires node or both x and y'),
      );
      expect(calls.where((c) => c.method == 'deviceLongPress'), isEmpty);
    });

    test('device_long_press clamps duration to 200-3000ms (default 600)',
        () async {
      Future<num?> dispatchedDuration(Map<String, dynamic> args) async {
        calls.clear();
        await AgentService.I.dispatchForTest('device_long_press', args);
        final dispatched = calls.where((c) => c.method == 'deviceLongPress');
        expect(dispatched, hasLength(1));
        return ((dispatched.single.arguments as Map)['duration_ms'] as num?);
      }

      expect(
        await dispatchedDuration({'x': 10, 'y': 20}),
        600,
      );
      expect(
        await dispatchedDuration({'x': 10, 'y': 20, 'duration_ms': 5000}),
        3000,
      );
      expect(
        await dispatchedDuration({'x': 10, 'y': 20, 'duration_ms': 50}),
        200,
      );
      expect(
        await dispatchedDuration({'node': 7, 'duration_ms': 1200}),
        1200,
      );
    });

    test('device_long_press reports node and coordinate presses honestly',
        () async {
      expect(
        await AgentService.I.dispatchForTest('device_long_press', {'node': 7}),
        contains('long-pressed node 7'),
      );
      expect(
        await AgentService.I.dispatchForTest('device_long_press', {
          'x': 10,
          'y': 20,
        }),
        contains('long-pressed (10, 20)'),
      );
      stub = (_) => 'held 800ms via gesture';
      expect(
        await AgentService.I.dispatchForTest('device_long_press', {'node': 7}),
        contains('held 800ms via gesture'),
      );
    });

    test('device_scroll requires a node and a known direction', () async {
      expect(
        await AgentService.I.dispatchForTest('device_scroll', const {}),
        contains('device_scroll requires node'),
      );
      expect(
        await AgentService.I.dispatchForTest('device_scroll', {
          'node': 5,
          'direction': 'diagonal',
        }),
        contains('device_scroll requires direction'),
      );
      expect(calls.where((c) => c.method == 'deviceScroll'), isEmpty);
    });

    test('device_scroll dispatches and names the native fallback', () async {
      calls.clear();
      expect(
        await AgentService.I.dispatchForTest('device_scroll', {
          'node': 5,
          'direction': 'up',
        }),
        contains('scrolled node 5 up'),
      );
      final dispatched = calls.where((c) => c.method == 'deviceScroll');
      expect(dispatched, hasLength(1));
      expect((dispatched.single.arguments as Map)['direction'], 'up');
      stub = (_) => 'Scrolled up via backward fallback (below API 23).';
      expect(
        await AgentService.I.dispatchForTest('device_scroll', {
          'node': 5,
          'direction': 'up',
        }),
        contains('fallback'),
      );
    });

    test('device_scroll surfaces NOT_SCROLLABLE honestly', () async {
      stub = (call) {
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
    });

    test('new tools are denied on sensitive foreground like the old ones',
        () async {
      packageName = 'com.paypal.android.p2pmobile';
      expect(
        await AgentService.I.dispatchForTest('device_key', {'key': 'enter'}),
        contains('sensitive'),
      );
      expect(
        await AgentService.I.dispatchForTest('device_long_press', {'node': 1}),
        contains('sensitive'),
      );
      expect(
        await AgentService.I.dispatchForTest('device_scroll', {
          'node': 1,
          'direction': 'forward',
        }),
        contains('sensitive'),
      );
      expect(
        calls.where(
          (c) =>
              c.method == 'deviceKey' ||
              c.method == 'deviceLongPress' ||
              c.method == 'deviceScroll',
        ),
        isEmpty,
      );
    });
  });
}
