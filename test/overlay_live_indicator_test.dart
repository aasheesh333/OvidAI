import 'dart:ffi' as ffi;
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/agent_service.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqlite3/open.dart' show open, OperatingSystem;

// Overlay live indicator (2026-09-13): while a Control-mode run is active,
// the floating overlay shows a subtle always-on pulse (status dot + light
// X pop) so the user can tell Ovid is live. Runtime behavior runs against
// a fake overlay channel; the no-hardware native window stays source-pinned.

String agentSource() => File('lib/core/agent_service.dart').readAsStringSync();

String kotlinServiceSource() => File(
  'android/app/src/main/kotlin/com/dhanuk/ovidai/OvidAccessibilityService.kt',
).readAsStringSync();

String kotlinActivitySource() => File(
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

  group('overlay live channel contract', () {
    late List<MethodCall> calls;

    setUp(() {
      calls = <MethodCall>[];
      const channel = MethodChannel('ovid/live-overlay-guard');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call);
            return true;
          });
      AgentService.setOverlayChannelForTest(channel);
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null);
        AgentService.setOverlayChannelForTest(null);
      });
    });

    test('setOverlayLive(true/false) emits deviceOverlayLive with the flag',
        () async {
      await AgentService.I.setOverlayLive(true);
      expect(
        calls
            .where(
              (c) =>
                  c.method == 'deviceOverlayLive' &&
                  (c.arguments as Map)['live'] == true,
            )
            .length,
        1,
      );
      await AgentService.I.setOverlayLive(false);
      expect(
        calls
            .where(
              (c) =>
                  c.method == 'deviceOverlayLive' &&
                  (c.arguments as Map)['live'] == false,
            )
            .length,
        1,
      );
    });

    test('show re-applies the live state while a run is active', () async {
      final s = ChatSession(id: 'live-reapply', title: 'S', model: 'm');
      app.sessions.insert(0, s);
      app.activeSessionId = s.id;
      s.mode = 'control';
      await AgentService.I.setAppForegrounded(false);
      calls.clear();
      try {
        await AgentService.I.setOverlayLive(true);
        calls.clear();
        // Re-showing (e.g. background again mid-run) must restore the pop.
        await AgentService.I.showDeviceOverlay();
        expect(
          calls.any(
            (c) =>
                c.method == 'deviceOverlayLive' &&
                (c.arguments as Map)['live'] == true,
          ),
          isTrue,
        );
      } finally {
        await AgentService.I.setOverlayLive(false);
        await AgentService.I.setAppForegrounded(true);
        app.activeSessionId = null;
        app.sessions.removeWhere((x) => x.id == s.id);
      }
    });

    test('stopRequested clears the live state with the run', () async {
      final s = ChatSession(id: 'live-stop', title: 'S', model: 'm');
      app.sessions.insert(0, s);
      app.activeSessionId = s.id;
      s.mode = 'control';
      AgentService.setRunSessionForTest(s.id);
      AgentService.I.runBucketForTest(s.id)
        ..queue.clear()
        ..activeRunId = null
        ..cancelRequested = false;
      try {
        await AgentService.I.setOverlayLive(true);
        calls.clear();
        AgentService.I.stopRequested(sessionId: s.id);
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(
          calls.any(
            (c) =>
                c.method == 'deviceOverlayLive' &&
                (c.arguments as Map)['live'] == false,
          ),
          isTrue,
        );
      } finally {
        AgentService.setRunSessionForTest('');
        app.activeSessionId = null;
        app.sessions.removeWhere((x) => x.id == s.id);
      }
    });

    test('cancelAllRuns clears the live state', () async {
      await AgentService.I.setOverlayLive(true);
      calls.clear();
      AgentService.I.cancelAllRuns();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(
        calls.any(
          (c) =>
              c.method == 'deviceOverlayLive' &&
              (c.arguments as Map)['live'] == false,
        ),
        isTrue,
      );
      await AgentService.I.setOverlayLive(false);
    });

    test('leaving Control mode clears the live state', () async {
      final s = ChatSession(id: 'live-mode-exit', title: 'S', model: 'm');
      app.sessions.insert(0, s);
      app.activeSessionId = s.id;
      s.mode = 'control';
      try {
        await AgentService.I.setOverlayLive(true);
        calls.clear();
        AgentService.I.mode = AgentMode.auto;
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(
          calls.any(
            (c) =>
                c.method == 'deviceOverlayLive' &&
                (c.arguments as Map)['live'] == false,
          ),
          isTrue,
        );
      } finally {
        app.activeSessionId = null;
        app.sessions.removeWhere((x) => x.id == s.id);
      }
    });
  });

  group('overlay live run wiring (source pins, no live provider in tests)',
      () {
    test('control run start marks the overlay live', () {
      final src = agentSource();
      final idx = src.indexOf('if (s.mode == AgentMode.control.name) {');
      expect(idx, greaterThanOrEqualTo(0));
      final window = src.substring(idx, idx + 400);
      expect(window, contains('showDeviceOverlay'));
      expect(window, contains('setOverlayLive(true)'));
    });

    test('run-end finally clears the live state', () {
      final src = agentSource();
      // The run-end finally: activeRunId cleared, checkpoint flushed.
      final idx = src.indexOf('unawaited(checkpointRunEnd(s.id));');
      expect(idx, greaterThanOrEqualTo(0));
      final window = src.substring(idx - 200, idx + 100);
      expect(window, contains('setOverlayLive(false)'));
    });
  });

  group('overlay live native pins (no hardware)', () {
    test('service exposes setOverlayLive with pulse animator', () {
      final src = kotlinServiceSource();
      expect(src, contains('fun setOverlayLive('));
      expect(src, contains('overlayLiveAnimator'));
      expect(src, contains('overlayLiveDot'));
    });

    test('live pulse is subtle and cancellable, never leaks', () {
      final src = kotlinServiceSource();
      // Subtle: small scale/alpha band, ~1.4s loop, dot 8dp.
      expect(src, contains('1.08f'));
      expect(src, contains('1400'));
      expect(src, contains('cancel()'));
    });

    test('touch targets meet the 44dp minimum', () {
      final src = kotlinServiceSource();
      expect(src, isNot(contains('(32 * density)')));
      expect(src, isNot(contains('(36 * density)')));
      expect(src, contains('(44 * density)'));
    });

    test('MainActivity routes deviceOverlayLive', () {
      final src = kotlinActivitySource();
      expect(src, contains('"deviceOverlayLive"'));
      expect(src, contains('setOverlayLive('));
    });
  });
}
