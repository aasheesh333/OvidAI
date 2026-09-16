import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/native_plugin.dart';
import 'package:ovid_ai/core/native_plugins/sandbox_utilities.dart';

/// Fake [SandboxRunner] keyed on command signature:
/// - commands containing `HISTFILE` answer the `$HISTFILE` probe
/// - commands containing `tail` answer the history-file read
SandboxRunner fakeHistoryRunner({
  String histProbe = '/sandbox/home/.bash_history\n',
  required String tailOutput,
  void Function(Duration? timeout)? onTimeout,
}) {
  return (List<String> args, {String? cwd, Duration? timeout}) async {
    onTimeout?.call(timeout);
    final cmd = args.join(' ');
    if (cmd.contains('HISTFILE')) return histProbe;
    if (cmd.contains('tail')) return tailOutput;
    throw ArgumentError('unexpected sandbox command: $cmd');
  };
}

void main() {
  tearDown(() {
    NativePluginRegistry.I.clearForTest();
  });

  test('shell history presence gate returns the exact Studio message',
      () async {
    var called = false;
    final cap = ShellHistoryCapability(
      runner: (_, {cwd, timeout}) async {
        called = true;
        return 'unused';
      },
      isSandboxInstalled: () => false,
    );
    expect(
      await cap.callTool('search', {'query': 'git'}),
      'Sandbox is not installed — open Studio once to install it, then retry.',
    );
    expect(called, isFalse);
  });

  test('shell history search filters newest-first with limit', () async {
    const lines = [
      'cd /tmp',
      'git status',
      'ls -la',
      'git commit -m foo',
      'echo hi',
      'GIT LOG --oneline',
      'pwd',
      'git push origin main',
      'whoami',
      'git diff HEAD',
    ];
    final cap = ShellHistoryCapability(
      runner: fakeHistoryRunner(tailOutput: lines.join('\n')),
      isSandboxInstalled: () => true,
    );
    final out = await cap.callTool('search', {'query': 'git', 'limit': 2});
    expect(out.split('\n'), ['git diff HEAD', 'git push origin main']);
  });

  test('shell history reports honestly when no history file exists',
      () async {
    final cap = ShellHistoryCapability(
      runner: fakeHistoryRunner(histProbe: '\n', tailOutput: ''),
      isSandboxInstalled: () => true,
    );
    expect(
      await cap.callTool('search', {'query': 'git'}),
      'No shell history file found in the sandbox yet — run some commands in Studio terminal first.',
    );
    expect(
      await cap.callTool('recent', {}),
      'No shell history file found in the sandbox yet — run some commands in Studio terminal first.',
    );
  });

  test('shell history rejects an empty query', () async {
    final cap = ShellHistoryCapability(
      runner: fakeHistoryRunner(tailOutput: 'git status\n'),
      isSandboxInstalled: () => true,
    );
    await expectLater(
      cap.callTool('search', {'query': '  '}),
      throwsA(isA<ArgumentError>()),
    );
  });

  test('shell history recent returns the tail', () async {
    final lines = [for (var i = 0; i < 100; i++) 'cmd-$i'];
    final cap = ShellHistoryCapability(
      runner: fakeHistoryRunner(tailOutput: lines.join('\n')),
      isSandboxInstalled: () => true,
    );
    final out = await cap.callTool('recent', {'limit': 5});
    expect(
      out.split('\n'),
      ['cmd-99', 'cmd-98', 'cmd-97', 'cmd-96', 'cmd-95'],
    );
  });

  test('shell history unknown tool throws ArgumentError', () async {
    final cap = ShellHistoryCapability(
      runner: fakeHistoryRunner(tailOutput: ''),
      isSandboxInstalled: () => true,
    );
    await expectLater(
      cap.callTool('nope', {}),
      throwsA(isA<ArgumentError>()),
    );
  });

  test('registerSandboxUtilities registers Shell History', () {
    registerSandboxUtilities();
    expect(NativePluginRegistry.I.has('Shell History'), isTrue);
    expect(
      NativePluginRegistry.I.capabilityForSlug('shell_history'),
      isA<ShellHistoryCapability>(),
    );
  });
}
