import 'dart:ffi' as ffi;
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/agent_service.dart';
import 'package:ovid_ai/core/device_control_service.dart';
import 'package:ovid_ai/core/session_ledger.dart';
import 'package:ovid_ai/core/session_search.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqlite3/open.dart' show open, OperatingSystem;

/// Control-mode return-to-Ovid: when a Control run completes, Ovid must
/// come back to the foreground. Failures must be visible (never swallowed),
/// a mid-run mode flip must not cancel the return owed to Control work,
/// and a user-cancelled run must NOT yank the user back.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory ledgerDir;
  late AppState app;
  late List<MethodCall> deviceCalls;
  late List<MethodCall> overlayCalls;

  setUpAll(() async {
    HttpOverrides.global = null;
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    ledgerDir = Directory.systemTemp.createTempSync('control-return-');
    SessionLedger.rootOverrideForTest = ledgerDir;
    SessionSearch.dbPathOverrideForTest = '${ledgerDir.path}/search.db';
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
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    app.sessions.clear();
    app.activeSessionId = null;
    deviceCalls = [];
    overlayCalls = [];
    const deviceChannel = MethodChannel('ovid/device-return-test');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(deviceChannel, (call) async {
          deviceCalls.add(call);
          return true;
        });
    DeviceControlService.setMethodChannelForTest(deviceChannel);
    const overlayChannel = MethodChannel('ovid/overlay-return-test');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(overlayChannel, (call) async {
          overlayCalls.add(call);
          return null;
        });
    AgentService.setOverlayChannelForTest(overlayChannel);
    addTearDown(() {
      DeviceControlService.setMethodChannelForTest(null);
      AgentService.setOverlayChannelForTest(null);
    });
  });

  tearDown(() {
    AgentService.llmOnceForTest = null;
    AgentService.setRunSessionForTest('');
  });

  ChatSession controlSession(String id) {
    final provider = app.providerById('ollama-local')!;
    provider
      ..baseUrl = 'http://127.0.0.1:1/v1'
      ..models = ['test-model']
      ..selectedModel = 'test-model';
    final s = ChatSession(
      id: id,
      title: 'Custom title', // prevents the fire-and-forget title LLM call
      providerId: provider.id,
      model: 'test-model',
      mode: 'control',
    );
    app.sessions.add(s);
    app.activeSessionId = s.id;
    return s;
  }

  void succeed(String text) {
    AgentService.llmOnceForTest = (p, msgs, session, includeTools) async {
      AgentService.I.streamToBubbleForTest(session, text);
      return {'role': 'assistant', 'content': text, 'finish_reason': 'stop'};
    };
  }

  bool openedOvid() => deviceCalls.any(
    (c) =>
        c.method == 'deviceOpenApp' &&
        (c.arguments as Map)['package'] == 'com.dhanuk.ovidai',
  );

  test('completed Control run returns to Ovid', () async {
    final s = controlSession('return-ok');
    succeed('done');

    await AgentService.I
        .runTask('hi', sessionId: s.id)
        .timeout(const Duration(seconds: 20));

    expect(openedOvid(), isTrue);
  });

  test('mid-run mode flip does not cancel the owed return', () async {
    final s = controlSession('return-flip');
    AgentService.llmOnceForTest = (p, msgs, session, includeTools) async {
      session.mode = 'auto'; // user flips mid-run; work was Control work
      AgentService.I.streamToBubbleForTest(session, 'done');
      return {'role': 'assistant', 'content': 'done', 'finish_reason': 'stop'};
    };

    await AgentService.I
        .runTask('hi', sessionId: s.id)
        .timeout(const Duration(seconds: 20));

    expect(openedOvid(), isTrue);
  });

  test('deviceOpenApp carries the running session id', () async {
    final s = controlSession('return-session-id');
    succeed('done');

    await AgentService.I
        .runTask('hi', sessionId: s.id)
        .timeout(const Duration(seconds: 20));

    final openCall = deviceCalls.firstWhere((c) => c.method == 'deviceOpenApp');
    expect((openCall.arguments as Map)['sessionId'], s.id);
  });

  test('blocked launch surfaces a tap-notification hint, overlay still hides',
      () async {
    final s = controlSession('return-blocked');
    succeed('done');
    const deviceChannel = MethodChannel('ovid/device-blocked-test');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(deviceChannel, (call) async {
      deviceCalls.add(call);
      if (call.method == 'deviceOpenApp') {
        throw PlatformException(
          code: 'LAUNCH_BLOCKED',
          message: 'Ovid could not come to the foreground.',
        );
      }
      return true;
    });
    DeviceControlService.setMethodChannelForTest(deviceChannel);

    await AgentService.I
        .runTask('hi', sessionId: s.id)
        .timeout(const Duration(seconds: 20));

    final thinks = AgentService.I
        .runBucketForTest(s.id)
        .runEvents
        .where((e) => e.kind == 'think')
        .map((e) => e.text)
        .join('\n');
    expect(thinks, contains('Tap the Ovid notification'));
    expect(
      overlayCalls.any((c) => c.method == 'deviceOverlayHide'),
      isTrue,
    );
  });

  test('user-cancelled run does not yank the user back', () async {
    final s = controlSession('return-stop');
    AgentService.llmOnceForTest = (p, msgs, session, includeTools) async {
      // User hits Stop mid-turn: hard-stop, then answer arrives.
      AgentService.I.hardStopAll();
      AgentService.I.streamToBubbleForTest(session, 'done');
      return {'role': 'assistant', 'content': 'done', 'finish_reason': 'stop'};
    };

    await AgentService.I
        .runTask('hi', sessionId: s.id)
        .timeout(const Duration(seconds: 20));

    expect(openedOvid(), isFalse);
  });
}
