import 'dart:ffi' as ffi;
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/agent_notification_service.dart';
import 'package:ovid_ai/core/agent_service.dart';
import 'package:ovid_ai/core/session_ledger.dart';
import 'package:ovid_ai/core/session_search.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:ovid_ai/core/theme.dart';
import 'package:ovid_ai/core/voice_input_service.dart';
import 'package:ovid_ai/ui/chat_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqlite3/open.dart' show open, OperatingSystem;

/// Press-to-talk mic: press mic → listens (stop button shows) → silence
/// auto-stop or manual stop → transcript → AUTO-SEND. No more
/// dictate-then-tap-send.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory ledgerDir;
  late AppState app;
  final voice = VoiceInputService.I;

  setUpAll(() async {
    HttpOverrides.global = null;
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    ledgerDir = Directory.systemTemp.createTempSync('mic-ptt-');
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
    AgentNotificationService.I.resetForTest();
    AgentService.I.debugPauseScheduleTimerForTest(true);
    voice.availabilityOverrideForTest = null;
    voice.startOverrideForTest = null;
    voice.stopOverrideForTest = null;
    voice.ensureMicrophonePermissionForTest = () async => true;
  });

  tearDown(() {
    voice.availabilityOverrideForTest = null;
    voice.startOverrideForTest = null;
    voice.stopOverrideForTest = null;
    voice.ensureMicrophonePermissionForTest = null;
    AgentService.llmOnceForTest = null;
    AgentService.I.overlayRunStarterForTest = null;
    AgentService.setRunSessionForTest('');
    AgentNotificationService.I.resetForTest();
    AppState.resetTestInstance();
  });

  test('listen options silence-stop and cap the session', () {
    final o = voice.listenOptionsForTest();
    expect(o.pauseFor, const Duration(seconds: 4));
    expect(o.listenFor, const Duration(seconds: 60));
    expect(o.partialResults, isTrue);
  });

  testWidgets('composer mic final transcript auto-sends', (tester) async {
    final provider = app.providerById('ollama-local')!;
    provider
      ..baseUrl = 'http://127.0.0.1:1/v1'
      ..models = ['test-model']
      ..selectedModel = 'test-model';
    final s = ChatSession(
      id: 'mic-ptt-1',
      title: 'Custom title',
      providerId: provider.id,
      model: 'test-model',
      mode: 'auto',
    );
    app.sessions.add(s);
    app.activeSessionId = s.id;
    voice.availabilityOverrideForTest = true;
    voice.startOverrideForTest = (onResult) {
      onResult('hello world', true);
    };
    AgentService.llmOnceForTest = (p, msgs, session, includeTools) async {
      AgentService.I.streamToBubbleForTest(session, 'ok');
      return {'role': 'assistant', 'content': 'ok', 'finish_reason': 'stop'};
    };

    await tester.pumpWidget(
      MaterialApp(theme: Aether.theme(), home: const ChatScreen()),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));

    await tester.tap(find.byTooltip('Voice'));
    // Fixed pumps only: ChatScreen owns live timers, so pumpAndSettle
    // never settles. Long enough to flush the notification debounce and
    // the instant-LLM run to completion.
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();

    expect(
      s.messages.any(
        (m) => m.role == 'user' && m.content.contains('hello world'),
      ),
      isTrue,
      reason: 'final mic transcript must send, not just fill the composer',
    );
  });

  test('overlay mic final transcript auto-sends', () async {
    final s = ChatSession(
      id: 'mic-ptt-overlay',
      title: 'S',
      model: 'm',
      mode: 'auto',
    );
    app.sessions.add(s);
    app.activeSessionId = s.id;
    voice.availabilityOverrideForTest = true;
    voice.startOverrideForTest = (onResult) {
      onResult('partial', false);
      onResult('do the thing', true);
    };
    String? sentText;
    AgentService.I.overlayRunStarterForTest = (text, session) async {
      sentText = text;
    };

    await AgentService.I.handleDeviceOverlayMic();

    expect(
      sentText,
      'do the thing',
      reason: 'overlay final transcript must send via the overlay send path',
    );
  });
}
