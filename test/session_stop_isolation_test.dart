import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/agent_notification_service.dart';
import 'package:ovid_ai/core/agent_service.dart';
import 'package:ovid_ai/core/pty_service.dart';
import 'package:ovid_ai/core/sandbox_service.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:ovid_ai/core/theme.dart';
import 'package:ovid_ai/ui/chat_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final agent = AgentService.I;
  final app = AppState.I;
  final sandbox = SandboxService.I;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    app.sessions.clear();
    app.activeSessionId = null;
    sandbox.liveProcessesForTest.clear();
    sandbox.runProcessesForTest.clear();
    AgentNotificationService.I.resetForTest();
  });

  tearDown(() async {
    for (final sessionId in const [
      'stop-isolation-a',
      'stop-isolation-b',
      'stop-tree-root',
      'stop-tree-parent',
      'stop-tree-child',
      'stop-tree-unrelated',
    ]) {
      agent.dropSessionRun(sessionId);
    }
    sandbox.killAllProcesses();
    await PtyPool.I.discardAll();
    AgentNotificationService.I.resetForTest();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('ovid/native'), null);
    app.sessions.clear();
    app.activeSessionId = null;
  });

  test('Stop with an empty queue cancels only the requested session', () async {
    final sessionA = ChatSession(
      id: 'stop-isolation-a',
      title: 'A',
      model: 'm',
      mode: 'auto',
    );
    final sessionB = ChatSession(
      id: 'stop-isolation-b',
      title: 'B',
      model: 'm',
      mode: 'auto',
      parentId: sessionA.id,
    );
    app.sessions.addAll([sessionA, sessionB]);
    app.activeSessionId = sessionA.id;

    final runA = agent.runBucketForTest(sessionA.id)..activeRunId = 'run-a';
    final runB = agent.runBucketForTest(sessionB.id)
      ..activeRunId = 'run-b'
      ..queue.add('keep working in B');

    final processA = await Process.start('sleep', ['30']);
    final processB = await Process.start('sleep', ['30']);
    final jobProcessA = await Process.start('sleep', ['30']);
    final jobProcessB = await Process.start('sleep', ['30']);
    addTearDown(() async {
      jobProcessA.kill(ProcessSignal.sigkill);
      jobProcessB.kill(ProcessSignal.sigkill);
      await jobProcessA.exitCode.timeout(const Duration(seconds: 3));
      await jobProcessB.exitCode.timeout(const Duration(seconds: 3));
    });
    sandbox.liveProcessesForTest.addAll([processA, processB]);
    sandbox.runProcessesForTest[sessionA.id] = [processA];
    sandbox.runProcessesForTest[sessionB.id] = [processB];
    runA.jobs[1] = BgJob(id: 1, name: 'job-a', command: 'sleep 30')
      ..process = jobProcessA
      ..started = true;
    runB.jobs[2] = BgJob(id: 2, name: 'job-b', command: 'sleep 30')
      ..process = jobProcessB
      ..started = true;
    final clientA = _FakeHttpClient();
    final requestA = _FakeHttpRequest();
    runA.activeClient = clientA;
    runA.activeRequest = requestA;
    late final Process ptyProcessA;
    late final Process ptyProcessB;
    final ptyA = await PtyPool.I.getOrCreate(
      sessionA.id,
      () async => ptyProcessA = await Process.start('sh', const []),
    );
    final ptyB = await PtyPool.I.getOrCreate(
      sessionB.id,
      () async => ptyProcessB = await Process.start('sh', const []),
    );
    expect(ptyA, isNotNull);
    expect(ptyB, isNotNull);

    final queuePreserved = agent.stopRequested(sessionId: sessionA.id);
    await Future<void>.delayed(const Duration(milliseconds: 100));

    expect(queuePreserved, isFalse);
    expect(runA.activeRunId, isNull);
    expect(runA.cancelRequested, isTrue);
    expect(runA.queue, isEmpty);
    expect(runA.jobs[1]!.killed, isTrue);
    expect(clientA.closedWithForce, isTrue);
    expect(requestA.aborted, isTrue);
    expect(runA.runEvents.last.text, 'stopped — all commands and jobs killed');
    expect(runA.statusLine, 'stopped — all commands and jobs killed');
    expect(sandbox.runProcessesForTest, isNot(contains(sessionA.id)));
    expect(
      await processA.exitCode.timeout(const Duration(seconds: 3)),
      isNot(0),
    );
    expect(
      await jobProcessA.exitCode.timeout(const Duration(seconds: 3)),
      isNot(0),
    );
    expect(
      await ptyProcessA.exitCode.timeout(const Duration(seconds: 3)),
      isNot(0),
    );

    expect(runB.activeRunId, 'run-b');
    expect(runB.cancelRequested, isFalse);
    expect(runB.queue, ['keep working in B']);
    expect(runB.jobs[2]!.killed, isFalse);
    expect(sandbox.runProcessesForTest[sessionB.id], contains(processB));
    expect(sandbox.liveProcessesForTest, contains(processB));
    var replacementSpawned = false;
    final samePtyB = await PtyPool.I.getOrCreate(sessionB.id, () async {
      replacementSpawned = true;
      return Process.start('sh', const []);
    });
    expect(samePtyB, same(ptyB));
    expect(replacementSpawned, isFalse);
    var replacementASpawned = false;
    final replacementPtyA = await PtyPool.I.getOrCreate(sessionA.id, () async {
      replacementASpawned = true;
      return Process.start('sh', const []);
    });
    expect(replacementASpawned, isTrue);
    expect(replacementPtyA, isNot(same(ptyA)));

    expect(ptyProcessB.pid, greaterThan(0));
  });

  test(
    'Stop explicitly targets a non-active session and preserves its queue',
    () {
      final sessionA = ChatSession(
        id: 'stop-isolation-a',
        title: 'A',
        model: 'm',
        mode: 'auto',
      );
      final sessionB = ChatSession(
        id: 'stop-isolation-b',
        title: 'B',
        model: 'm',
        mode: 'auto',
      );
      app.sessions.addAll([sessionA, sessionB]);
      app.activeSessionId = sessionB.id;

      final runA = agent.runBucketForTest(sessionA.id)
        ..activeRunId = 'run-a'
        ..queue.add('resume A');
      final runB = agent.runBucketForTest(sessionB.id)
        ..activeRunId = 'run-b'
        ..queue.add('keep B queued')
        ..statusLine = 'B still working';

      final queuePreserved = agent.stopRequested(sessionId: sessionA.id);

      expect(queuePreserved, isTrue);
      expect(runA.activeRunId, isNull);
      expect(runA.cancelRequested, isTrue);
      expect(runA.queue, ['resume A']);
      expect(runB.activeRunId, 'run-b');
      expect(runB.cancelRequested, isFalse);
      expect(runB.queue, ['keep B queued']);
      expect(runB.statusLine, 'B still working');
    },
  );

  test(
    'notification Stop cancels the session represented by its progress',
    () async {
      final sessionA = ChatSession(
        id: 'stop-isolation-a',
        title: 'A',
        model: 'm',
        mode: 'auto',
      );
      final sessionB = ChatSession(
        id: 'stop-isolation-b',
        title: 'B',
        model: 'm',
        mode: 'auto',
      );
      app.sessions.addAll([sessionA, sessionB]);
      app.activeSessionId = sessionB.id;

      final runA = agent.runBucketForTest(sessionA.id)..activeRunId = 'run-a';
      final runB = agent.runBucketForTest(sessionB.id)..activeRunId = 'run-b';

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
      await notification.agentWorking(
        'session A is working',
        sessionId: sessionA.id,
      );
      await displayed.future.timeout(const Duration(seconds: 2));
      await Future<void>.delayed(Duration.zero);

      await _sendNativeAction('onAgentStop');

      expect(runA.activeRunId, isNull);
      expect(runA.cancelRequested, isTrue);
      expect(runB.activeRunId, 'run-b');
      expect(runB.cancelRequested, isFalse);
    },
  );

  test(
    'failed pending notification update keeps Stop on displayed session',
    () async {
      final sessionA = ChatSession(
        id: 'stop-isolation-a',
        title: 'A',
        model: 'm',
        mode: 'auto',
      );
      final sessionB = ChatSession(
        id: 'stop-isolation-b',
        title: 'B',
        model: 'm',
        mode: 'auto',
      );
      app.sessions.addAll([sessionA, sessionB]);

      final runA = agent.runBucketForTest(sessionA.id)..activeRunId = 'run-a';
      final runB = agent.runBucketForTest(sessionB.id)..activeRunId = 'run-b';
      final displayedA = Completer<void>();
      final pendingB = Completer<bool>();
      final invokedB = Completer<void>();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel('ovid/native'), (
            call,
          ) async {
            final args = (call.arguments as Map?)?.cast<Object?, Object?>();
            final text = args?['text'] as String? ?? '';
            if (text.contains('display A')) {
              if (!displayedA.isCompleted) displayedA.complete();
              return true;
            }
            if (text.contains('pending B')) {
              if (!invokedB.isCompleted) invokedB.complete();
              return pendingB.future;
            }
            return true;
          });

      final notification = AgentNotificationService.I;
      await notification.init();
      await notification.agentWorking('display A', sessionId: sessionA.id);
      await displayedA.future.timeout(const Duration(seconds: 2));
      await notification.agentWorking('pending B', sessionId: sessionB.id);
      await invokedB.future.timeout(const Duration(seconds: 2));

      await _sendNativeAction('onAgentStop');
      pendingB.complete(false);
      await Future<void>.delayed(Duration.zero);

      expect(runA.activeRunId, isNull);
      expect(runA.cancelRequested, isTrue);
      expect(runB.activeRunId, 'run-b');
      expect(runB.cancelRequested, isFalse);
    },
  );

  test('successful notification update switches Stop ownership', () async {
    final sessionA = ChatSession(
      id: 'stop-isolation-a',
      title: 'A',
      model: 'm',
      mode: 'auto',
    );
    final sessionB = ChatSession(
      id: 'stop-isolation-b',
      title: 'B',
      model: 'm',
      mode: 'auto',
    );
    app.sessions.addAll([sessionA, sessionB]);

    final runA = agent.runBucketForTest(sessionA.id)..activeRunId = 'run-a';
    final runB = agent.runBucketForTest(sessionB.id)..activeRunId = 'run-b';
    final displayedA = Completer<void>();
    final displayedB = Completer<void>();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('ovid/native'), (
          call,
        ) async {
          final args = (call.arguments as Map?)?.cast<Object?, Object?>();
          final text = args?['text'] as String? ?? '';
          if (text.contains('display A') && !displayedA.isCompleted) {
            displayedA.complete();
          }
          if (text.contains('display B') && !displayedB.isCompleted) {
            displayedB.complete();
          }
          return true;
        });

    final notification = AgentNotificationService.I;
    await notification.init();
    await notification.agentWorking('display A', sessionId: sessionA.id);
    await displayedA.future.timeout(const Duration(seconds: 2));
    await Future<void>.delayed(Duration.zero);
    await notification.agentWorking('display B', sessionId: sessionB.id);
    await displayedB.future.timeout(const Duration(seconds: 2));
    await Future<void>.delayed(Duration.zero);
    await _sendNativeAction('onAgentStop');

    expect(runA.cancelRequested, isFalse);
    expect(runA.activeRunId, 'run-a');
    expect(runB.activeRunId, isNull);
    expect(runB.cancelRequested, isTrue);
  });

  test(
    'finished displayed run refreshes notification to a remaining run',
    () async {
      final sessionA = ChatSession(
        id: 'stop-isolation-a',
        title: 'A',
        model: 'm',
        mode: 'auto',
      );
      final sessionB = ChatSession(
        id: 'stop-isolation-b',
        title: 'B',
        model: 'm',
        mode: 'auto',
      );
      app.sessions.addAll([sessionA, sessionB]);
      final runA = agent.runBucketForTest(sessionA.id)..activeRunId = 'run-a';
      final runB = agent.runBucketForTest(sessionB.id)
        ..activeRunId = 'run-b'
        ..statusLine = 'B remains active';
      final displayedA = Completer<void>();
      final refreshedB = Completer<void>();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel('ovid/native'), (
            call,
          ) async {
            final args = (call.arguments as Map?)?.cast<Object?, Object?>();
            final text = args?['text'] as String? ?? '';
            if (text.contains('display A') && !displayedA.isCompleted) {
              displayedA.complete();
            }
            if (text.contains('B remains active') && !refreshedB.isCompleted) {
              refreshedB.complete();
            }
            return true;
          });
      final notification = AgentNotificationService.I;
      await notification.init();
      await notification.agentWorking('display A', sessionId: sessionA.id);
      await displayedA.future.timeout(const Duration(seconds: 2));
      await Future<void>.delayed(Duration.zero);

      runA.activeRunId = null;
      notification.agentIdle(sessionId: sessionA.id);
      await refreshedB.future.timeout(const Duration(seconds: 2));
      await Future<void>.delayed(Duration.zero);
      await _sendNativeAction('onAgentStop');

      expect(runA.cancelRequested, isFalse);
      expect(runB.activeRunId, isNull);
      expect(runB.cancelRequested, isTrue);
    },
  );

  test('cancelAllRuns clears queues before cancelling every session', () async {
    final sessionA = ChatSession(
      id: 'stop-isolation-a',
      title: 'A',
      model: 'm',
      mode: 'auto',
    );
    final sessionB = ChatSession(
      id: 'stop-isolation-b',
      title: 'B',
      model: 'm',
      mode: 'auto',
    );
    app.sessions.addAll([sessionA, sessionB]);

    final runA = agent.runBucketForTest(sessionA.id)
      ..activeRunId = 'run-a'
      ..queue.add('must not restart A');
    final runB = agent.runBucketForTest(sessionB.id)
      ..activeRunId = 'run-b'
      ..queue.add('must not restart B');
    final processA = await Process.start('sleep', ['30']);
    final processB = await Process.start('sleep', ['30']);
    sandbox.liveProcessesForTest.addAll([processA, processB]);
    sandbox.runProcessesForTest[sessionA.id] = [processA];
    sandbox.runProcessesForTest[sessionB.id] = [processB];

    agent.cancelAllRuns();
    await Future<void>.delayed(const Duration(milliseconds: 100));

    expect(runA.activeRunId, isNull);
    expect(runA.cancelRequested, isTrue);
    expect(runA.queue, isEmpty);
    expect(runB.activeRunId, isNull);
    expect(runB.cancelRequested, isTrue);
    expect(runB.queue, isEmpty);
    expect(sandbox.liveProcessesForTest, isEmpty);
    expect(sandbox.runProcessesForTest, isEmpty);
    expect(
      await processA.exitCode.timeout(const Duration(seconds: 3)),
      isNot(0),
    );
    expect(
      await processB.exitCode.timeout(const Duration(seconds: 3)),
      isNot(0),
    );
  });

  test('notification Exit clears queues and cancels every session', () async {
    final sessionA = ChatSession(
      id: 'stop-isolation-a',
      title: 'A',
      model: 'm',
      mode: 'auto',
    );
    final sessionB = ChatSession(
      id: 'stop-isolation-b',
      title: 'B',
      model: 'm',
      mode: 'auto',
    );
    app.sessions.addAll([sessionA, sessionB]);
    final runA = agent.runBucketForTest(sessionA.id)
      ..activeRunId = 'run-a'
      ..queue.add('queued A');
    final runB = agent.runBucketForTest(sessionB.id)
      ..activeRunId = 'run-b'
      ..queue.add('queued B');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('ovid/native'),
          (_) async => true,
        );
    await AgentNotificationService.I.init();

    await _sendNativeAction('onAgentExit');

    expect(runA.activeRunId, isNull);
    expect(runA.cancelRequested, isTrue);
    expect(runA.queue, isEmpty);
    expect(runB.activeRunId, isNull);
    expect(runB.cancelRequested, isTrue);
    expect(runB.queue, isEmpty);
  });

  test('interrupting a subagent cancels its descendants only', () {
    final root = ChatSession(
      id: 'stop-tree-root',
      title: 'Root',
      model: 'm',
      mode: 'auto',
    );
    final parent = ChatSession(
      id: 'stop-tree-parent',
      title: 'Parent subagent',
      model: 'm',
      mode: 'auto',
      parentId: root.id,
      agentState: 'running',
    );
    final child = ChatSession(
      id: 'stop-tree-child',
      title: 'Child subagent',
      model: 'm',
      mode: 'auto',
      parentId: parent.id,
      agentState: 'running',
    );
    final unrelated = ChatSession(
      id: 'stop-tree-unrelated',
      title: 'Unrelated',
      model: 'm',
      mode: 'auto',
    );
    app.sessions.addAll([root, parent, child, unrelated]);
    final parentRun = agent.runBucketForTest(parent.id)
      ..activeRunId = 'run-parent';
    final childRun = agent.runBucketForTest(child.id)
      ..activeRunId = 'run-child';
    final unrelatedRun = agent.runBucketForTest(unrelated.id)
      ..activeRunId = 'run-unrelated';

    agent.interruptSubagent(parent.id);

    expect(parentRun.activeRunId, isNull);
    expect(parentRun.cancelRequested, isTrue);
    expect(childRun.activeRunId, isNull);
    expect(childRun.cancelRequested, isTrue);
    expect(unrelatedRun.activeRunId, 'run-unrelated');
    expect(unrelatedRun.cancelRequested, isFalse);
    expect(parent.agentState, 'stopped');
    expect(child.agentState, 'stopped');
  });

  test('targeted stop keeps the run event log capped', () {
    final session = ChatSession(
      id: 'stop-isolation-a',
      title: 'A',
      model: 'm',
      mode: 'auto',
    );
    app.sessions.add(session);
    final run = agent.runBucketForTest(session.id)..activeRunId = 'run-a';
    for (var i = 0; i < 120; i++) {
      run.runEvents.add(AgentEvent('think', 'event-$i'));
    }
    AgentNotificationService.I.supportedForTest = false;

    agent.stopRequested(sessionId: session.id);

    expect(run.runEvents, hasLength(120));
    expect(run.runEvents.first.text, 'event-1');
    expect(run.runEvents.last.text, 'stopped — all commands and jobs killed');
  });

  testWidgets('rendered chat Stop keeps another session running', (
    tester,
  ) async {
    final sessionA = ChatSession(
      id: 'stop-isolation-a',
      title: 'A',
      model: 'm',
      mode: 'auto',
    );
    final sessionB = ChatSession(
      id: 'stop-isolation-b',
      title: 'B',
      model: 'm',
      mode: 'auto',
    );
    app.sessions.addAll([sessionA, sessionB]);
    app.activeSessionId = sessionA.id;
    final runA = agent.runBucketForTest(sessionA.id)..activeRunId = 'run-a';
    final runB = agent.runBucketForTest(sessionB.id)..activeRunId = 'run-b';

    await tester.pumpWidget(
      MaterialApp(theme: Aether.theme(), home: const ChatScreen()),
    );
    await tester.pump();

    await tester.tap(find.byIcon(Icons.stop_rounded));
    await tester.pump();

    expect(runA.activeRunId, isNull);
    expect(runA.cancelRequested, isTrue);
    expect(runB.activeRunId, 'run-b');
    expect(runB.cancelRequested, isFalse);
  });
}

Future<void> _sendNativeAction(String method) async {
  final handled = Completer<void>();
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .handlePlatformMessage(
        'ovid/native',
        const StandardMethodCodec().encodeMethodCall(MethodCall(method)),
        (_) => handled.complete(),
      );
  await handled.future.timeout(const Duration(seconds: 2));
}

class _FakeHttpClient implements HttpClient {
  bool closedWithForce = false;

  @override
  void close({bool force = false}) {
    closedWithForce = force;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeHttpRequest implements HttpClientRequest {
  bool aborted = false;

  @override
  void abort([Object? exception, StackTrace? stackTrace]) {
    aborted = true;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
