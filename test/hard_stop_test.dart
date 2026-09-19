import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/agent_service.dart';
import 'package:ovid_ai/core/sandbox_service.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Hard force-stop: the in-app Stop (and overlay X / notification Stop)
/// must stop the agent EVERYWHERE it runs — every session, subagent, job
/// and spawned process — right where it is. Queues are preserved (unlike
/// the Exit path) so an already-queued message still sends next.
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
    for (final sessionId in const ['hard-a', 'hard-b']) {
      agent.dropSessionRun(sessionId);
    }
    sandbox.killAllProcesses();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('ovid/native'), null);
    app.sessions.clear();
    app.activeSessionId = null;
  });

  test('hardStopAll stops every session run and promotes its queued next',
      () async {
    final sessionA = ChatSession(
      id: 'hard-a',
      title: 'A',
      model: 'm',
      mode: 'auto',
    );
    final sessionB = ChatSession(
      id: 'hard-b',
      title: 'B',
      model: 'm',
      mode: 'auto',
    );
    app.sessions.addAll([sessionA, sessionB]);
    app.activeSessionId = sessionA.id;

    final runA = agent.runBucketForTest(sessionA.id)
      ..activeRunId = 'run-a'
      ..queue.add('next in A');
    final runB = agent.runBucketForTest(sessionB.id)
      ..activeRunId = 'run-b';

    final processA = await Process.start('sleep', ['30']);
    final processB = await Process.start('sleep', ['30']);
    addTearDown(() async {
      processA.kill(ProcessSignal.sigkill);
      processB.kill(ProcessSignal.sigkill);
      await processA.exitCode.timeout(const Duration(seconds: 3));
      await processB.exitCode.timeout(const Duration(seconds: 3));
    });
    sandbox.liveProcessesForTest.addAll([processA, processB]);
    sandbox.runProcessesForTest[sessionA.id] = [processA];
    sandbox.runProcessesForTest[sessionB.id] = [processB];

    agent.hardStopAll();
    await Future<void>.delayed(const Duration(milliseconds: 100));

    // Both runs stop immediately, wherever they were.
    expect(runA.activeRunId, isNull);
    expect(runB.activeRunId, isNull);
    expect(runA.cancelRequested, isTrue);
    expect(runB.cancelRequested, isTrue);
    // Stop with queued work starts the next message immediately: A's queued
    // message is promoted out of the queue (and lands in the transcript);
    // B had nothing queued.
    expect(runA.queue, isEmpty);
    expect(runB.queue, isEmpty);
    expect(
      sessionA.messages.map((m) => m.content),
      contains('next in A'),
      reason: 'the promoted message becomes a real user row',
    );
    // Run-scoped processes were killed in both sessions.
    await expectLater(
      processA.exitCode.timeout(const Duration(seconds: 3)),
      completes,
    );
    await expectLater(
      processB.exitCode.timeout(const Duration(seconds: 3)),
      completes,
    );
    expect(sandbox.runProcessesForTest, isNot(contains(sessionA.id)));
    expect(sandbox.runProcessesForTest, isNot(contains(sessionB.id)));
  });

  test('hardStopAll on idle sessions is a no-op that keeps queues', () {
    final sessionA = ChatSession(
      id: 'hard-a',
      title: 'A',
      model: 'm',
      mode: 'auto',
    );
    app.sessions.add(sessionA);
    app.activeSessionId = sessionA.id;

    final runA = agent.runBucketForTest(sessionA.id)
      ..queue.add('later');

    agent.hardStopAll();

    expect(runA.queue, ['later']);
  });
}
