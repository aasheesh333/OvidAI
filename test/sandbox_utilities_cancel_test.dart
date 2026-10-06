import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/native_plugins/sandbox_utilities.dart';
import 'package:ovid_ai/core/native_plugins/utility_limits.dart';
import 'package:ovid_ai/core/sandbox_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('null cancellation preserves the unmodified runner path', () async {
    var calls = 0;
    final cap = ShellHistoryCapability(
      runner: (List<String> args, {String? cwd, Duration? timeout}) async {
        calls++;
        if (args.join(' ').contains('HISTFILE')) return '/sandbox/home/.bash_history\n';
        return 'git status';
      },
      isSandboxInstalled: () => true,
    );
    expect(await cap.callTool('recent', {}), 'git status');
    expect(calls, 2);
  });

  test('cancelling a long call aborts and the runner observes the stop',
      () async {
    final started = Completer<void>();
    final observed = Completer<void>();
    Future<String> runner(
      List<String> args, {
      String? cwd,
      Duration? timeout,
      UtilityCancellation? cancellation,
    }) async {
      started.complete();
      await cancellation!.whenCancelled;
      observed.complete();
      throw const FormatException('Utility operation cancelled.');
    }

    final cap = ShellHistoryCapability(
      runner: runner,
      isSandboxInstalled: () => true,
    );
    final token = UtilityCancellation();
    final pending = cap.callTool('recent', {}, cancellation: token);
    await started.future;
    final clock = Stopwatch()..start();
    token.cancel();
    await expectLater(
      pending,
      throwsA(
        isA<FormatException>().having(
          (e) => e.message,
          'reason',
          contains('cancelled'),
        ),
      ),
    );
    // The underlying runner was signalled to stop, not merely abandoned.
    await observed.future;
    expect(clock.elapsed, lessThan(const Duration(seconds: 5)));
  });

  test('cancelling a sandbox call kills the underlying process tree', () async {
    SharedPreferences.setMockInitialValues({});
    final tmp = Directory.systemTemp.createTempSync('ovid-sandbox-cancel');
    addTearDown(() {
      SandboxService.I.sandboxPrefixForTest = null;
      try {
        tmp.deleteSync(recursive: true);
      } catch (_) {}
    });
    Directory('${tmp.path}/bin').createSync(recursive: true);
    Directory('${tmp.path}/home').createSync(recursive: true);
    // Stand-in for the sandbox `git` binary: blocks long enough to cancel.
    final git = File('${tmp.path}/bin/git')
      ..writeAsStringSync('#!/bin/sh\n/bin/sleep 30\n');
    Process.runSync('chmod', ['+x', git.path]);
    SandboxService.I.sandboxPrefixForTest = tmp;

    final cap = GitWorkbenchCapability(isSandboxInstalled: () => true);
    final token = UtilityCancellation();
    final pending = cap.callTool(
      'clone',
      {'url': 'https://example.com/r.git'},
      cancellation: token,
    );
    // Wait until the child process actually spawns before cancelling.
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (SandboxService.I.liveProcessesForTest.isEmpty &&
        DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(SandboxService.I.liveProcessesForTest, isNotEmpty);

    token.cancel();
    await expectLater(
      pending,
      throwsA(
        isA<FormatException>().having(
          (e) => e.message,
          'reason',
          contains('cancelled'),
        ),
      ),
    );
    expect(SandboxService.I.liveProcessesForTest, isEmpty);
  });
}
