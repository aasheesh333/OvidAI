import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:ovid_ai/core/sandbox_service.dart';

/// A tool timeout must CANCEL the work, not merely abandon it (2026-09-24).
///
/// `Future.timeout` leaves the future's work running, and the old message told
/// the model to "narrow the request and retry" — so it re-issued a slow
/// `run_shell` and two copies of a mutating command (npm install, git push, file
/// writes) ran concurrently against one workspace: duplicated commits, corrupted
/// builds, interleaved writes.
///
/// Killing by RUN key was too coarse — background `job_start` work is tagged to
/// the same run and is meant to outlive the call. Processes are now grouped by
/// TOOL INVOCATION, so a timeout kills exactly what it started.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final svc = SandboxService.I;

  Future<Process> sleepy() => Process.start('/bin/sh', ['-c', 'sleep 30']);

  tearDown(() {
    svc.killAllProcesses();
    svc.tagCall(null);
  });

  group('killCallProcesses is scoped to one invocation', () {
    test('it kills that call\'s process and leaves other calls alone', () async {
      final a = await sleepy();
      final b = await sleepy();
      svc.trackCallProcessForTest('call-a', a);
      svc.trackCallProcessForTest('call-b', b);

      var aExited = false;
      unawaited(a.exitCode.then((_) => aExited = true));

      svc.killCallProcesses('call-a');
      await a.exitCode;

      expect(aExited, isTrue, reason: 'the timed-out call must be killed');
      expect(
        svc.callProcessesForTest.containsKey('call-a'),
        isFalse,
        reason: 'and forgotten, so it is never killed twice',
      );
      // b is untouched: it belongs to a different invocation.
      expect(b.kill(ProcessSignal.sigterm), isTrue);
      await b.exitCode;
    });

    test('it does not touch processes only tagged to a run', () async {
      // This is the background-job case: a job is run-tagged but was NOT started
      // during the invocation that timed out, so killing the call must not
      // reach it.
      final job = await sleepy();
      svc.tagRun('run-1');
      // Register under the run bucket only (as a background job would be).
      svc.runProcessesForTest.putIfAbsent('run-1', () => []).add(job);
      svc.liveProcessesForTest.add(job);

      final doomed = await sleepy();
      svc.trackCallProcessForTest('call-x', doomed);
      svc.killCallProcesses('call-x');
      await doomed.exitCode;

      // The run-tagged job survives.
      expect(
        svc.liveProcessesForTest.contains(job),
        isTrue,
        reason: 'background jobs must outlive an unrelated tool timeout',
      );
      expect(svc.runProcessesForTest['run-1'], contains(job));

      job.kill(ProcessSignal.sigterm);
      await job.exitCode;
      svc.tagRun(null);
    });

    test('killing an unknown key is a no-op', () {
      svc.killCallProcesses('never-used');
    });
  });

  group('the dispatch timeout kills its invocation', () {
    test('the message says KILLED and the call is killed by key', () {
      final src = File('lib/core/agent_service.dart').readAsStringSync();
      final i = src.indexOf('final budget = _toolTimeoutFor(name);');
      expect(i, greaterThan(-1));
      final region = src.substring(i, i + 2200);

      expect(region, contains('SandboxService.callZoneKey'));
      expect(region, contains('killCallProcesses(callKey)'));
      expect(region, contains('were KILLED'));
      expect(
        region,
        isNot(contains('was NOT cancelled')),
        reason: 'it is cancelled now',
      );
    });
  });
}
