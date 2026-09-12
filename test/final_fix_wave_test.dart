import 'dart:async';
import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/agent_notification_service.dart';
import 'package:ovid_ai/core/agent_service.dart';
import 'package:ovid_ai/core/presets.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqlite3/open.dart' show open, OperatingSystem;

// Final review wave: P4 user-zoom control (browser_desktop `zoom`) +
// overlay lifecycle wiring (show on Control run start, hide on run end /
// mode exit / panic-stop). Runtime hookup only — no source-string checks.
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

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AgentService.I.debugPauseScheduleTimerForTest(true);
    AgentService.I.clearBrowserTabsForTest();
    BrowserTab.devW = 360;
    BrowserTab.devH = 720;
  });

  tearDown(() {
    AgentService.I.clearBrowserTabsForTest();
    AgentService.setRunSessionForTest('');
    AgentService.setOverlayChannelForTest(null);
    AgentService.I.debugPauseScheduleTimerForTest(false);
    AgentNotificationService.I.resetForTest();
    BrowserTab.devW = 360;
    BrowserTab.devH = 720;
  });

  ChatSession newSession(
    String id, {
    String mode = 'auto',
    String model = 'm',
    String? providerId,
  }) {
    final s = ChatSession(
      id: id,
      title: 'S',
      model: model,
      mode: mode,
      providerId: providerId,
    );
    app.sessions.insert(0, s);
    app.activeSessionId = s.id;
    addTearDown(() {
      AgentService.setRunSessionForTest('');
      app.activeSessionId = null;
      app.sessions.removeWhere((x) => x.id == s.id);
    });
    return s;
  }

  List<MethodCall> mockOverlayChannel() {
    final calls = <MethodCall>[];
    const channel = MethodChannel('ovid/final-wave-overlay');
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
    return calls;
  }

  Future<void> waitForCall(List<MethodCall> calls, String method) async {
    for (var i = 0; i < 200 && !calls.any((c) => c.method == method); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(
      calls.any((c) => c.method == method),
      isTrue,
      reason: 'timed out waiting for channel call $method',
    );
  }

  group('wave: browser_desktop zoom schema', () {
    test('schema exposes optional zoom 0.5-2.0; mode still required', () {
      final tools = AgentService.I.toolsForTest();
      final tool = tools.firstWhere(
        (t) => (t['function'] as Map)['name'] == 'browser_desktop',
      );
      final fn = tool['function'] as Map;
      final params = fn['parameters'] as Map;
      final props = params['properties'] as Map;
      expect(props.containsKey('zoom'), isTrue, reason: 'missing zoom arg');
      final zoom = props['zoom'] as Map;
      expect(zoom['minimum'], 0.5);
      expect(zoom['maximum'], 2.0);
      expect(params['required'], ['mode']);
    });
  });

  group('wave: browser_desktop zoom validation (no WebView needed)', () {
    test('non-numeric zoom is rejected before any platform touch', () async {
      final s = newSession('wave-zoom-nonnumeric');
      AgentService.setRunSessionForTest(s.id);
      final res = await AgentService.I.dispatchForTest('browser_desktop', {
        'mode': 'desktop',
        'zoom': 'big',
      });
      expect(res.toLowerCase(), contains('invalid zoom'));
    });

    test('out-of-range zoom is rejected before any platform touch', () async {
      final s = newSession('wave-zoom-range');
      AgentService.setRunSessionForTest(s.id);
      final res = await AgentService.I.dispatchForTest('browser_desktop', {
        'mode': 'desktop',
        'zoom': 9.0,
      });
      expect(res, contains('out of range'));
      expect(res, contains('0.5'));
      expect(res, contains('2.0'));
    });

    test('invalid mode still rejected (existing gate unchanged)', () async {
      final s = newSession('wave-zoom-badmode');
      AgentService.setRunSessionForTest(s.id);
      expect(
        await AgentService.I.dispatchForTest('browser_desktop', {
          'mode': 'wide',
        }),
        contains('invalid mode'),
      );
    });

    test('read-only and plan gates unchanged (zoom or not)', () async {
      final s = newSession('wave-zoom-gates', mode: 'safe');
      AgentService.setRunSessionForTest(s.id);
      expect(
        await AgentService.I.dispatchForTest('browser_desktop', {
          'mode': 'desktop',
          'zoom': 1.5,
        }),
        contains('READ-ONLY MODE'),
      );
      s.mode = AgentMode.auto.name;
      s.planMode = true;
      expect(
        await AgentService.I.dispatchForTest('browser_desktop', {
          'mode': 'desktop',
          'zoom': 1.5,
        }),
        contains('PLAN MODE'),
      );
      s.planMode = false;
    });
  });

  group('wave: userZoom clamp (existing setter)', () {
    test('clamps to the 0.5-2.0 readable range', () {
      final tab = BrowserTab(url: 'https://example.com', desktopMode: false);
      tab.userZoom = 9.0;
      expect(tab.userZoom, 2.0);
      tab.userZoom = 0.1;
      expect(tab.userZoom, 0.5);
      tab.userZoom = 1.5;
      expect(tab.userZoom, 1.5);
    });

    test('zoom applied + persisted round-trip + reports value', () async {
      final s = newSession('wave-zoom-roundtrip');
      AgentService.setRunSessionForTest(s.id);
      final tab = BrowserTab(
        url: 'https://zoom.test',
        desktopMode: false,
      );
      AgentService.I.browserTabs.add(tab);

      final frag = await AgentService.I.applyBrowserZoomForTest(tab, 1.5);
      expect(tab.userZoom, 1.5);
      expect(frag, 'userZoom=1.50');

      AgentService.I.clearBrowserTabsForTest();
      AgentService.setRunSessionForTest(s.id);
      expect(await AgentService.I.restoreBrowserTabsForTest(), isTrue);
      expect(AgentService.I.browserTabs, hasLength(1));
      expect(AgentService.I.browserTabs.single.userZoom, 1.5);
    });
  });

  group('wave: overlay lifecycle runtime hookup', () {
    test('stopRequested hides the overlay (panic-stop path)', () async {
      final calls = mockOverlayChannel();
      final s = newSession('wave-stop-hide', mode: 'control');
      AgentService.I.runBucketForTest(s.id)
        ..queue.clear()
        ..activeRunId = null
        ..cancelRequested = false;
      AgentService.I.stopRequested(sessionId: s.id);
      await waitForCall(calls, 'deviceOverlayHide');
    });

    test('cancelAllRuns hides the overlay (panic-stop path)', () async {
      final calls = mockOverlayChannel();
      newSession('wave-cancel-hide', mode: 'control');
      AgentService.I.cancelAllRuns();
      await waitForCall(calls, 'deviceOverlayHide');
    });

    test('leaving Control mode hides the overlay; entering does not', () async {
      final calls = mockOverlayChannel();
      final s = newSession('wave-mode-hide', mode: 'control');
      AgentService.I.setMode(AgentMode.auto);
      await waitForCall(calls, 'deviceOverlayHide');
      expect(s.mode, AgentMode.auto.name);

      calls.clear();
      AgentService.I.setMode(AgentMode.control);
      await pumpEventQueue();
      expect(
        calls.any((c) => c.method == 'deviceOverlayHide'),
        isFalse,
        reason: 'entering Control must not hide',
      );
    });

    test('leaving Control via the plan preset hides the overlay', () async {
      final calls = mockOverlayChannel();
      newSession('wave-preset-hide', mode: 'control');
      await AgentService.I.applyPreset(PresetRegistry.byId('plan'));
      await waitForCall(calls, 'deviceOverlayHide');
    });

    test('Control run shows the overlay at start and hides at end', () async {
      final calls = mockOverlayChannel();
      final provider = app.providerById('ollama-local')!;
      final originals = ({
        'baseUrl': provider.baseUrl,
        'models': List<String>.of(provider.models),
        'selectedModel': provider.selectedModel,
      });
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      provider
        ..baseUrl = 'http://${server.address.host}:${server.port}/v1'
        ..models = ['test-model']
        ..selectedModel = 'test-model';
      final serve = () async {
        await for (final request in server) {
          try {
            request.response.headers.chunkedTransferEncoding = true;
            request.response.add(
              utf8.encode(
                'data: ${jsonEncode({
                  'choices': [
                    {
                      'delta': {'content': 'done '},
                      'finish_reason': 'stop',
                    },
                  ],
                })}\n\n',
              ),
            );
            await request.response.flush();
            await request.response.close();
          } catch (_) {}
        }
      }();
      unawaited(serve);
      final s = ChatSession(
        id: 'wave-ctl-run',
        title: 'S',
        providerId: provider.id,
        model: 'test-model',
        mode: 'control',
      );
      app.sessions.insert(0, s);
      app.activeSessionId = s.id;
      try {
        await AgentService.I
            .runTask('wave hello', sessionId: s.id)
            .timeout(const Duration(seconds: 20));
        await pumpEventQueue();
        await waitForCall(calls, 'deviceOverlayShow');
        await waitForCall(calls, 'deviceOverlayHide');
      } finally {
        provider
          ..baseUrl = originals['baseUrl'] as String
          ..models = originals['models'] as List<String>
          ..selectedModel = originals['selectedModel'] as String?;
        await server.close(force: true);
        app.activeSessionId = null;
        app.sessions.removeWhere((x) => x.id == s.id);
      }
    });

    test('non-Control run never shows the overlay', () async {
      final calls = mockOverlayChannel();
      final provider = app.providerById('ollama-local')!;
      final originals = ({
        'baseUrl': provider.baseUrl,
        'models': List<String>.of(provider.models),
        'selectedModel': provider.selectedModel,
      });
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      provider
        ..baseUrl = 'http://${server.address.host}:${server.port}/v1'
        ..models = ['test-model']
        ..selectedModel = 'test-model';
      final serve = () async {
        await for (final request in server) {
          try {
            request.response.headers.chunkedTransferEncoding = true;
            request.response.add(
              utf8.encode(
                'data: ${jsonEncode({
                  'choices': [
                    {
                      'delta': {'content': 'done '},
                      'finish_reason': 'stop',
                    },
                  ],
                })}\n\n',
              ),
            );
            await request.response.flush();
            await request.response.close();
          } catch (_) {}
        }
      }();
      unawaited(serve);
      final s = ChatSession(
        id: 'wave-auto-run',
        title: 'S',
        providerId: provider.id,
        model: 'test-model',
        mode: 'auto',
      );
      app.sessions.insert(0, s);
      app.activeSessionId = s.id;
      try {
        await AgentService.I
            .runTask('wave hello', sessionId: s.id)
            .timeout(const Duration(seconds: 20));
        await pumpEventQueue();
        expect(
          calls.any((c) => c.method == 'deviceOverlayShow'),
          isFalse,
          reason: 'non-Control runs must never show the overlay',
        );
      } finally {
        provider
          ..baseUrl = originals['baseUrl'] as String
          ..models = originals['models'] as List<String>
          ..selectedModel = originals['selectedModel'] as String?;
        await server.close(force: true);
        app.activeSessionId = null;
        app.sessions.removeWhere((x) => x.id == s.id);
      }
    });
  });
}
