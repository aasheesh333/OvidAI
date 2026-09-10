import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/agent_notification_service.dart';
import 'package:ovid_ai/core/agent_service.dart';
import 'package:ovid_ai/core/pty_service.dart';
import 'package:ovid_ai/core/sandbox_service.dart';
import 'package:ovid_ai/core/state.dart';
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
  });

  tearDown(() async {
    agent.dropSessionRun('stop-isolation-a');
    agent.dropSessionRun('stop-isolation-b');
    sandbox.killAllProcesses();
    await PtyPool.I.discardAll();
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
    sandbox.liveProcessesForTest.addAll([processA, processB]);
    sandbox.runProcessesForTest[sessionA.id] = [processA];
    sandbox.runProcessesForTest[sessionB.id] = [processB];
    runA.jobs[1] = BgJob(id: 1, name: 'job-a', command: 'sleep 30')
      ..process = processA
      ..started = true;
    runB.jobs[2] = BgJob(id: 2, name: 'job-b', command: 'sleep 30')
      ..process = processB
      ..started = true;
    final ptyA = await PtyPool.I.getOrCreate(
      sessionA.id,
      () => Process.start('sh', const []),
    );
    final ptyB = await PtyPool.I.getOrCreate(
      sessionB.id,
      () => Process.start('sh', const []),
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
    expect(runA.runEvents.last.text, 'stopped — all commands and jobs killed');
    expect(runA.statusLine, 'stopped — all commands and jobs killed');
    expect(sandbox.runProcessesForTest, isNot(contains(sessionA.id)));

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

      const channel = MethodChannel('ovid/native');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (_) async => true);
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null);
      });

      final notification = AgentNotificationService.I;
      notification.supportedForTest = true;
      await notification.init();
      await notification.agentWorking(
        'session A is working',
        sessionId: sessionA.id,
      );

      final handled = Completer<void>();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .handlePlatformMessage(
            'ovid/native',
            const StandardMethodCodec().encodeMethodCall(
              const MethodCall('onAgentStop'),
            ),
            (_) => handled.complete(),
          );
      await handled.future;

      expect(runA.activeRunId, isNull);
      expect(runA.cancelRequested, isTrue);
      expect(runB.activeRunId, 'run-b');
      expect(runB.cancelRequested, isFalse);
      await Future<void>.delayed(const Duration(milliseconds: 700));
    },
  );

  test('stale notification progress never stops another running session', () async {
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

    const channel = MethodChannel('ovid/native');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async => true);
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    final notification = AgentNotificationService.I;
    notification.supportedForTest = true;
    await notification.init();
    await notification.agentWorking(
      'session A is working',
      sessionId: sessionA.id,
    );
    runA.activeRunId = null;

    final handled = Completer<void>();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
          'ovid/native',
          const StandardMethodCodec().encodeMethodCall(
            const MethodCall('onAgentStop'),
          ),
          (_) => handled.complete(),
        );
    await handled.future;

    expect(runA.cancelRequested, isFalse);
    expect(runB.activeRunId, 'run-b');
    expect(runB.cancelRequested, isFalse);
    await Future<void>.delayed(const Duration(milliseconds: 700));
  });

  test('cancelAllRuns remains an explicit global panic stop', () async {
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
    final processA = await Process.start('sleep', ['30']);
    final processB = await Process.start('sleep', ['30']);
    sandbox.liveProcessesForTest.addAll([processA, processB]);
    sandbox.runProcessesForTest[sessionA.id] = [processA];
    sandbox.runProcessesForTest[sessionB.id] = [processB];

    agent.cancelAllRuns();
    await Future<void>.delayed(const Duration(milliseconds: 100));

    expect(runA.activeRunId, isNull);
    expect(runA.cancelRequested, isTrue);
    expect(runB.activeRunId, isNull);
    expect(runB.cancelRequested, isTrue);
    expect(sandbox.liveProcessesForTest, isEmpty);
    expect(sandbox.runProcessesForTest, isEmpty);
  });
}
