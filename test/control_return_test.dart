import 'dart:async';
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
  final ownedSessionIds = <String>{};

  Future<void> until(bool Function() condition) async {
    final deadline = DateTime.now().add(const Duration(seconds: 20));
    while (!condition()) {
      if (DateTime.now().isAfter(deadline)) fail('Control fixture did not settle');
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

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
    await AgentService.I.setAppForegrounded(true);
  });

  tearDown(() async {
    await until(() => ownedSessionIds.every((id) => !AgentService.I.busyFor(id)));
    for (final id in ownedSessionIds) {
      AgentService.I.dropSessionRun(id);
      await SessionLedger.I.close(id);
    }
    ownedSessionIds.clear();
    AgentService.I.onControlTaskCompleted = null;
    AgentService.llmOnceForTest = null;
    AgentService.setRunSessionForTest('');
    // Keep the fixture channels installed until owned runs and their cleanup
    // have drained. addTearDown runs before this tearDown and resets too early.
    await AgentService.I.setAppForegrounded(true);
    await AgentService.I.setOverlayLive(false);
    await AgentService.I.setOverlayState(AgentService.overlayStateIdle);
    DeviceControlService.setMethodChannelForTest(null);
    AgentService.setOverlayChannelForTest(null);
    for (final name in [
      'ovid/device-return-test', 'ovid/overlay-return-test',
      'ovid/overlapping-return', 'ovid/device-blocked-test',
    ]) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(MethodChannel(name), null);
    }
  });

  ChatSession controlSession(String id) {
    ownedSessionIds.add(id);
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
    final generation = DeviceControlService.I.generation;
    succeed('done');

    await AgentService.I
        .runTask('hi', sessionId: s.id)
        .timeout(const Duration(seconds: 20));

    expect(openedOvid(), isTrue);
    expect(DeviceControlService.I.generation, greaterThan(generation));
    expect(deviceCalls.any((c) => c.method == 'deviceBeginActions'), isTrue);
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

  test('interim completion stays working and final return targets origin', () async {
    final origin = controlSession('origin');
    final other = controlSession('foreground');
    String? interimState;
    bool? interimLaunch;
    final revealed = <String>[];
    AgentService.I.onControlTaskCompleted = revealed.add;
    AgentService.llmOnceForTest = (p, msgs, session, includeTools) async {
      app.selectSession(other.id);
      AgentService.I.emitForTest('done', 'installed a tool');
      interimLaunch = openedOvid();
      interimState = AgentService.I.overlayStateForTest;
      AgentService.I.streamToBubbleForTest(session, 'done');
      return {'role': 'assistant', 'content': 'done'};
    };
    await AgentService.I.runTask('hi', sessionId: origin.id);
    expect(interimLaunch, isFalse);
    expect(interimState, 'running');
    expect(revealed, [origin.id]);
    expect(app.activeSessionId, origin.id);
    final launches = deviceCalls.where((c) => c.method == 'deviceOpenApp');
    expect(launches, hasLength(1));
    expect((launches.single.arguments as Map)['sessionId'], origin.id);
  });

  test('failed Control task cleans up without a completion focus jump', () async {
    final s = controlSession('error');
    final revealed = <String>[];
    AgentService.I.onControlTaskCompleted = revealed.add;
    AgentService.llmOnceForTest = (p, msgs, session, includeTools) async {
      throw StateError('terminal failure');
    };
    await AgentService.I.runTask('hi', sessionId: s.id);
    expect(openedOvid(), isFalse);
    expect(revealed, isEmpty);
    expect(AgentService.I.overlayLiveForTest, isFalse);
    expect(overlayCalls.any((c) => c.method == 'deviceOverlayHide'), isTrue);
  });

  test('Control Stop clears queued device prompts synchronously', () async {
    final s = controlSession('stop-queue');
    final run = AgentService.I.runBucketForTest(s.id);
    AgentService.llmOnceForTest = (p, msgs, session, includeTools) async {
      run.queue.add('tap again');
      AgentService.I.hardStopAll();
      expect(run.activeRunId, isNull);
      expect(run.queue, isEmpty);
      return {'role': 'assistant', 'content': 'late'};
    };
    await AgentService.I.runTask('hi', sessionId: s.id);
    expect(s.messages.any((m) => m.content == 'tap again'), isFalse);
    expect(openedOvid(), isFalse);
  });

  test('approval transitions belong to Control and survive other chat events', () async {
    final origin = controlSession('approval-origin');
    final other = controlSession('approval-other')..mode = 'auto';
    final states = <String>[];
    AgentService.llmOnceForTest = (p, msgs, session, includeTools) async {
      AgentService.I.pendingApproval = ApprovalRequest(
        tool: 'device_tap', summary: 'Approve tap', detail: 'Tap button',
      );
      states.add(AgentService.I.overlayStateForTest);
      app.selectSession(other.id);
      final otherRun = AgentService.I.runBucketForTest(other.id)
        ..activeRunId = 'other-run';
      AgentService.I.emitToRunForTest(otherRun, 'done', 'interim step');
      states.add(AgentService.I.overlayStateForTest);
      AgentService.I.approve(true);
      states.add(AgentService.I.overlayStateForTest);
      AgentService.I.emitForTest('err', 'recoverable tool error');
      states.add(AgentService.I.overlayStateForTest);
      otherRun.activeRunId = null;
      return {'role': 'assistant', 'content': 'done'};
    };
    await AgentService.I.runTask('hi', sessionId: origin.id);
    expect(states, ['permission', 'permission', 'running', 'error']);
    expect(AgentService.I.overlayStateForTest, 'idle');
  });

  test('background steering follows Control owner while foreground chat differs', () async {
    final origin = controlSession('steering-origin');
    final other = controlSession('steering-other')..mode = 'auto';
    var turn = 0;
    final queued = <String>[];
    AgentService.llmOnceForTest = (p, msgs, session, includeTools) async {
      if (turn++ == 0) {
        app.selectSession(other.id);
        await AgentService.I.setAppForegrounded(false);
        await AgentService.I.handleDeviceOverlayText('use the next button');
        queued.addAll(AgentService.I.queuedMessagesFor(origin.id));
      }
      return {'role': 'assistant', 'content': 'done'};
    };
    await AgentService.I.runTask('hi', sessionId: origin.id);
    await until(() => turn >= 2 && !AgentService.I.busyFor(origin.id));
    expect(queued, ['use the next button']);
    expect(other.messages, isEmpty);
    expect(overlayCalls.any((c) => c.method == 'deviceOverlayShow'), isTrue);
    await AgentService.I.setAppForegrounded(true);
  });

  test('background Control admission shows steering when another chat is selected', () async {
    final origin = controlSession('background-admission');
    controlSession('selected-auto').mode = 'auto';
    await AgentService.I.setAppForegrounded(false);
    succeed('done');
    try {
      await AgentService.I.runTask('hi', sessionId: origin.id);
      expect(overlayCalls.any((c) => c.method == 'deviceOverlayShow'), isTrue);
    } finally {
      await AgentService.I.setAppForegrounded(true);
    }
  });

  test('removed Control owner cannot mask the next live session', () async {
    final removed = controlSession('removed-control');
    final stale = AgentService.I.runBucketForTest(removed.id)
      ..controlRun = true
      ..activeRunId = 'removed-run';
    app.sessions.remove(removed);
    final origin = controlSession('surviving-control');
    final other = controlSession('selected-non-control')..mode = 'auto';
    final question = ApprovalRequest(
      tool: 'ask_user_question', summary: 'Which item?', detail: '',
      questions: [UserQuestion(id: 'item', question: 'Which item?')],
    );
    AgentService.llmOnceForTest = (p, msgs, session, includeTools) async {
      AgentService.I.pendingApproval = question;
      await AgentService.I.handleDeviceOverlayText('surviving answer');
      return {'role': 'assistant', 'content': 'done'};
    };
    try {
      await AgentService.I.setAppForegrounded(false);
      await AgentService.I.runTask('hi', sessionId: origin.id);
      expect(overlayCalls.any((c) => c.method == 'deviceOverlayShow'), isTrue);
      expect(question.answers, {'item': 'surviving answer'});
      expect(other.messages, isEmpty);
    } finally {
      stale.activeRunId = null;
      await AgentService.I.setAppForegrounded(true);
    }
  });

  test('late return cleanup cannot cancel a newer Control task', () async {
    final origin = controlSession('old-return');
    final next = controlSession('new-control');
    final nextEntered = Completer<void>();
    final finishNext = Completer<void>();
    Future<void>? nextTask;
    int? nextGeneration;
    AgentService.llmOnceForTest = (p, msgs, session, includeTools) async {
      if (session.id == next.id) {
        nextEntered.complete();
        await finishNext.future;
      }
      return {'role': 'assistant', 'content': 'done'};
    };
    const channel = MethodChannel('ovid/overlapping-return');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          deviceCalls.add(call);
          if (call.method == 'deviceOpenApp' &&
              (call.arguments as Map)['sessionId'] == origin.id) {
            nextTask = AgentService.I.runTask('next', sessionId: next.id);
            nextGeneration = DeviceControlService.I.generation;
          }
          return true;
        });
    DeviceControlService.setMethodChannelForTest(channel);
    try {
      await AgentService.I.runTask('first', sessionId: origin.id);
      await nextEntered.future.timeout(const Duration(seconds: 20));
      expect(DeviceControlService.I.generation, nextGeneration);
      expect(AgentService.I.overlayStateForTest, 'running');
    } finally {
      finishNext.complete();
      await nextTask;
    }
  });

  test('native lifecycle cancellation stops Control despite displayed chat', () async {
    final origin = controlSession('notification-control');
    final other = controlSession('notification-other')..mode = 'auto';
    AgentService.llmOnceForTest = (p, msgs, session, includeTools) async {
      app.selectSession(other.id);
      AgentService.I.enqueueMessage('tap more', sessionId: origin.id);
      await AgentService.I.handleDeviceOverlayMethodCall(
        const MethodCall('deviceControlStopped'),
      );
      return {'role': 'assistant', 'content': 'late response'};
    };
    await AgentService.I.runTask('hi', sessionId: origin.id);
    expect(AgentService.I.busyFor(origin.id), isFalse);
    expect(AgentService.I.queuedMessagesFor(origin.id), isEmpty);
    expect(openedOvid(), isFalse);
  });

  test('overlay answer resolves only the originating Control question', () async {
    final origin = controlSession('question-origin');
    final other = controlSession('question-other')..mode = 'auto';
    final question = ApprovalRequest(
      tool: 'ask_user_question', summary: 'Which item?', detail: '',
      questions: [UserQuestion(id: 'item', question: 'Which item?')],
    );
    final otherQuestion = ApprovalRequest(
      tool: 'ask_user_question', summary: 'Other question', detail: '',
    );
    AgentService.I.runBucketForTest(other.id).pendingApproval = otherQuestion;
    AgentService.llmOnceForTest = (p, msgs, session, includeTools) async {
      AgentService.I.pendingApproval = question;
      app.selectSession(other.id);
      await AgentService.I.handleDeviceOverlayText('second item');
      return {'role': 'assistant', 'content': 'done'};
    };
    await AgentService.I.runTask('hi', sessionId: origin.id);
    expect(await question.completer.future, isTrue);
    expect(question.answers, {'item': 'second item'});
    expect(otherQuestion.completer.isCompleted, isFalse);
    AgentService.I.runBucketForTest(other.id).pendingApproval = null;
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
