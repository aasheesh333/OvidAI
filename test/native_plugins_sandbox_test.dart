import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/native_plugin.dart';
import 'package:ovid_ai/core/native_plugins/sandbox_utilities.dart';
import 'package:shared_preferences/shared_preferences.dart';

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
  TestWidgetsFlutterBinding.ensureInitialized();
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

  test('shell history recent ignores the trailing newline from tail',
      () async {
    final lines = [for (var i = 0; i < 100; i++) 'cmd-$i'];
    final cap = ShellHistoryCapability(
      // Real `tail` output ends with `\n`.
      runner: fakeHistoryRunner(tailOutput: '${lines.join('\n')}\n'),
      isSandboxInstalled: () => true,
    );
    final out = await cap.callTool('recent', {'limit': 5});
    expect(
      out.split('\n'),
      ['cmd-99', 'cmd-98', 'cmd-97', 'cmd-96', 'cmd-95'],
    );
  });

  test('shell history parses limit tolerantly', () async {
    const lines = ['git status', 'git log', 'git diff'];
    final cap = ShellHistoryCapability(
      runner: fakeHistoryRunner(tailOutput: lines.join('\n')),
      isSandboxInstalled: () => true,
    );
    // Numeric strings are accepted like ints.
    expect(
      (await cap.callTool('search', {'query': 'git', 'limit': '2'}))
          .split('\n'),
      ['git diff', 'git log'],
    );
    // Garbage is a user-input error.
    await expectLater(
      cap.callTool('search', {'query': 'git', 'limit': 'abc'}),
      throwsA(isA<FormatException>()),
    );
    // Out-of-range clamps to 1..500.
    expect(
      (await cap.callTool('search', {'query': 'git', 'limit': 0}))
          .split('\n'),
      ['git diff'],
    );
  });

  test('shell history truncates oversized output with omission notice',
      () async {
    final lines = [for (var i = 0; i < 300; i++) 'cmd-$i ${'x' * 40}'];
    final cap = ShellHistoryCapability(
      runner: fakeHistoryRunner(tailOutput: lines.join('\n')),
      isSandboxInstalled: () => true,
    );
    final out = await cap.callTool('recent', {'limit': 300});
    expect(out, contains('characters omitted'));
    expect(out.length, lessThan(lines.join('\n').length));
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

  test('git workbench presence gate returns the exact Studio message',
      () async {
    var called = false;
    final cap = GitWorkbenchCapability(
      runner: (_, {cwd, timeout}) async {
        called = true;
        return 'unused';
      },
      isSandboxInstalled: () => false,
    );
    expect(
      await cap.callTool('status', {'path': '/sandbox/home/proj'}),
      'Sandbox is not installed — open Studio once to install it, then retry.',
    );
    expect(called, isFalse);

    registerSandboxUtilities();
    expect(NativePluginRegistry.I.has('Git Workbench'), isTrue);
    expect(
      NativePluginRegistry.I.capabilityForSlug('git_workbench'),
      isA<GitWorkbenchCapability>(),
    );
  });

  test('git status/log/branch happy paths', () async {
    SharedPreferences.setMockInitialValues({});
    final seenArgs = <List<String>>[];
    final seenCwd = <String?>[];
    final seenTimeouts = <Duration?>[];
    final cap = GitWorkbenchCapability(
      runner: (List<String> args, {String? cwd, Duration? timeout}) async {
        seenArgs.add(args);
        seenCwd.add(cwd);
        seenTimeouts.add(timeout);
        final cmd = args.join(' ');
        if (cmd.contains('status')) {
          return '## main...origin/main\n M foo.dart\n';
        }
        if (cmd.contains('branch')) {
          return '* main\n  dev\n  remotes/origin/main\n';
        }
        if (cmd.contains('log')) return 'abc1234 first\ndef5678 second\n';
        throw ArgumentError('unexpected sandbox command: $cmd');
      },
      isSandboxInstalled: () => true,
    );
    const dir = '/sandbox/home/proj';

    final statusOut = await cap.callTool('status', {'path': dir});
    expect(seenArgs[0], ['git', '-C', dir, 'status', '--short', '--branch']);
    expect(seenCwd[0], dir);
    expect(seenTimeouts[0], const Duration(seconds: 60));
    expect(statusOut, contains('## main'));

    final logOut = await cap.callTool('log', {'path': dir});
    expect(seenArgs[1], ['git', '-C', dir, 'log', '--oneline', '-n', '20']);
    expect(logOut, contains('abc1234'));

    // Limit is tolerant-parsed like Task 1 (numeric strings accepted).
    await cap.callTool('log', {'path': dir, 'limit': '5'});
    expect(seenArgs[2], ['git', '-C', dir, 'log', '--oneline', '-n', '5']);
    await expectLater(
      cap.callTool('log', {'path': dir, 'limit': 'abc'}),
      throwsA(isA<FormatException>()),
    );

    final branchOut = await cap.callTool('branch', {'path': dir});
    expect(seenArgs[3], ['git', '-C', dir, 'branch', '-a']);
    expect(branchOut, contains('* main'));
    expect(branchOut, contains('current: main'));

    // Unparseable branch output (no `* ` line) passes through raw.
    final capRaw = GitWorkbenchCapability(
      runner: (_, {cwd, timeout}) async => '  main\n  dev\n',
      isSandboxInstalled: () => true,
    );
    expect(
      await capRaw.callTool('branch', {'path': dir}),
      isNot(contains('current:')),
    );
  });

  test('git clone/commit/push validate args', () async {
    SharedPreferences.setMockInitialValues({});
    final seenArgs = <List<String>>[];
    final seenTimeouts = <Duration?>[];
    final cap = GitWorkbenchCapability(
      runner: (List<String> args, {String? cwd, Duration? timeout}) async {
        seenArgs.add(args);
        seenTimeouts.add(timeout);
        final cmd = args.join(' ');
        if (cmd.contains('clone')) return 'Cloned into ...';
        if (args.contains('add')) return 'add-ok';
        if (cmd.contains('commit')) return '[main abc1234] hello';
        if (cmd.contains('push')) return 'pushed to origin';
        throw ArgumentError('unexpected sandbox command: $cmd');
      },
      isSandboxInstalled: () => true,
    );

    await expectLater(
      cap.callTool('clone', {}),
      throwsA(isA<ArgumentError>()),
    );
    await expectLater(
      cap.callTool('clone', {'url': '  '}),
      throwsA(isA<ArgumentError>()),
    );
    await expectLater(
      cap.callTool('commit', {'path': '/sandbox/home/r'}),
      throwsA(isA<ArgumentError>()),
    );
    await expectLater(
      cap.callTool(
        'commit',
        {'path': '/sandbox/home/r', 'message': '  '},
      ),
      throwsA(isA<ArgumentError>()),
    );
    await expectLater(
      cap.callTool('nope', {}),
      throwsA(isA<ArgumentError>()),
    );

    await cap.callTool('clone', {'url': 'https://example.com/r.git'});
    expect(seenArgs.last, ['git', 'clone', 'https://example.com/r.git']);
    expect(seenTimeouts.last, const Duration(seconds: 300));

    await cap.callTool('clone', {
      'url': 'https://example.com/r.git',
      'path': '/sandbox/home/r',
    });
    expect(seenArgs.last, [
      'git',
      'clone',
      'https://example.com/r.git',
      '/sandbox/home/r',
    ]);

    seenArgs.clear();
    final commitOut = await cap.callTool('commit', {
      'path': '/sandbox/home/r',
      'message': 'hello',
    });
    expect(seenArgs.length, 2);
    expect(seenArgs[0], ['git', '-C', '/sandbox/home/r', 'add', '-A']);
    expect(seenArgs[1], [
      'git',
      '-C',
      '/sandbox/home/r',
      'commit',
      '-m',
      'hello',
    ]);
    expect(commitOut, contains('add-ok'));
    expect(commitOut, contains('hello'));

    await cap.callTool('push', {'path': '/sandbox/home/r'});
    expect(seenArgs.last, ['git', '-C', '/sandbox/home/r', 'push', 'origin']);
    expect(seenTimeouts.last, const Duration(seconds: 300));

    await cap.callTool('push', {
      'path': '/sandbox/home/r',
      'remote': 'upstream',
      'branch': 'main',
    });
    expect(seenArgs.last, [
      'git',
      '-C',
      '/sandbox/home/r',
      'push',
      'upstream',
      'main',
    ]);
  });

  test('git surfaces backend errors verbatim', () async {
    SharedPreferences.setMockInitialValues({});
    final cap = GitWorkbenchCapability(
      runner: (_, {cwd, timeout}) async =>
          'fatal: not a git repository\n(exit code 128)',
      isSandboxInstalled: () => true,
    );
    final out = await cap.callTool('status', {'path': '/sandbox/home/proj'});
    expect(out, contains('fatal: not a git repository'));
    expect(out, contains('(exit code 128)'));
  });

  test('git default_path falls back and overrides', () async {
    SharedPreferences.setMockInitialValues({});
    List<String>? seenArgs;
    String? seenCwd;
    final cap = GitWorkbenchCapability(
      runner: (List<String> args, {String? cwd, Duration? timeout}) async {
        seenArgs = args;
        seenCwd = cwd;
        return 'ok';
      },
      isSandboxInstalled: () => true,
    );

    // No path arg and no configured default → no cwd (sandbox home).
    await cap.callTool('status', {});
    expect(seenCwd, isNull);
    expect(seenArgs, ['git', 'status', '--short', '--branch']);

    // Configured default_path becomes the working dir.
    await cap.configure({'default_path': '/sandbox/home/work'});
    await cap.callTool('status', {});
    expect(seenCwd, '/sandbox/home/work');
    expect(seenArgs, [
      'git',
      '-C',
      '/sandbox/home/work',
      'status',
      '--short',
      '--branch',
    ]);

    // Explicit path arg wins over the configured default.
    await cap.callTool('status', {'path': '/sandbox/home/other'});
    expect(seenCwd, '/sandbox/home/other');
    expect(seenArgs, [
      'git',
      '-C',
      '/sandbox/home/other',
      'status',
      '--short',
      '--branch',
    ]);
  });

  test('pdf tools presence gate returns the exact Studio message', () async {
    var called = false;
    final cap = PdfToolsCapability(
      runner: (_, {cwd, timeout}) async {
        called = true;
        return 'unused';
      },
      isSandboxInstalled: () => false,
    );
    expect(
      await cap.callTool('merge', {
        'inputs': ['/sandbox/home/a.pdf', '/sandbox/home/b.pdf'],
        'output': '/sandbox/home/out.pdf',
      }),
      'Sandbox is not installed — open Studio once to install it, then retry.',
    );
    expect(called, isFalse);

    registerSandboxUtilities();
    expect(NativePluginRegistry.I.has('PDF Tools'), isTrue);
    expect(
      NativePluginRegistry.I.capabilityForSlug('pdf_tools'),
      isA<PdfToolsCapability>(),
    );
  });

  test('pdf tools route pypdf-present and qpdf-missing', () async {
    final seenArgs = <List<String>>[];
    final seenTimeouts = <Duration?>[];
    final cap = PdfToolsCapability(
      runner: (List<String> args, {String? cwd, Duration? timeout}) async {
        seenArgs.add(args);
        seenTimeouts.add(timeout);
        final cmd = args.join(' ');
        if (cmd.contains('command -v python3')) return '/usr/bin/python3\n';
        if (cmd.contains('command -v qpdf')) {
          throw Exception('qpdf: command not found');
        }
        if (args.isNotEmpty && args.first == 'python3') return 'merged-ok';
        throw ArgumentError('unexpected sandbox command: $cmd');
      },
      isSandboxInstalled: () => true,
    );
    final out = await cap.callTool('merge', {
      'inputs': ['/sandbox/home/a.pdf', '/sandbox/home/b.pdf'],
      'output': '/sandbox/home/out.pdf',
    });
    expect(out, contains('/sandbox/home/out.pdf'));
    // pypdf short-circuits: the qpdf probe never runs.
    expect(
      seenArgs.any((a) => a.join(' ').contains('command -v qpdf')),
      isFalse,
    );
    // Merge invokes python3, never the qpdf binary.
    final pythonCalls =
        seenArgs.where((a) => a.isNotEmpty && a.first == 'python3');
    expect(pythonCalls, isNotEmpty);
    expect(
      seenArgs.where((a) => a.isNotEmpty && a.first == 'qpdf'),
      isEmpty,
    );
    // Merge defaults to a 300s timeout.
    expect(pythonCalls.first, contains('/sandbox/home/a.pdf'));
    expect(pythonCalls.first, contains('/sandbox/home/out.pdf'));
    expect(
      seenTimeouts[seenArgs.indexOf(pythonCalls.first)],
      const Duration(seconds: 300),
    );
  });

  test('pdf tools report honestly when no backend exists', () async {
    final cap = PdfToolsCapability(
      runner: (List<String> args, {String? cwd, Duration? timeout}) async {
        final cmd = args.join(' ');
        if (cmd.contains('command -v python3')) {
          return '(command exited with exit code 1 and produced no output)';
        }
        if (cmd.contains('command -v qpdf')) {
          throw Exception('qpdf: command not found');
        }
        throw ArgumentError('unexpected sandbox command: $cmd');
      },
      isSandboxInstalled: () => true,
    );
    expect(
      await cap.callTool('info', {'input': '/sandbox/home/a.pdf'}),
      'No PDF backend in the sandbox (needs python3+pypdf or qpdf) — install one, then retry.',
    );
  });

  test('pdf split rejects malformed ranges', () async {
    final seenArgs = <List<String>>[];
    final cap = PdfToolsCapability(
      runner: (List<String> args, {String? cwd, Duration? timeout}) async {
        seenArgs.add(args);
        final cmd = args.join(' ');
        if (cmd.contains('command -v python3')) return '/usr/bin/python3\n';
        if (args.isNotEmpty && args.first == 'python3') return 'split-ok';
        throw ArgumentError('unexpected sandbox command: $cmd');
      },
      isSandboxInstalled: () => true,
    );
    for (final bad in ['a-b', '0', '5-2']) {
      await expectLater(
        cap.callTool('split', {'input': '/sandbox/home/a.pdf', 'ranges': bad}),
        throwsA(isA<FormatException>()),
      );
    }
    final out = await cap.callTool('split', {
      'input': '/sandbox/home/a.pdf',
      'ranges': '1,3-4',
    });
    expect(out, contains('a-1.pdf'));
    expect(out, contains('a-2.pdf'));
  });

  test('pdf merge requires two or more inputs', () async {
    var pythonCalls = 0;
    final cap = PdfToolsCapability(
      runner: (List<String> args, {String? cwd, Duration? timeout}) async {
        final cmd = args.join(' ');
        if (cmd.contains('command -v python3')) return '/usr/bin/python3\n';
        if (args.isNotEmpty && args.first == 'python3') {
          pythonCalls++;
          return 'merged-ok';
        }
        throw ArgumentError('unexpected sandbox command: $cmd');
      },
      isSandboxInstalled: () => true,
    );
    await expectLater(
      cap.callTool('merge', {
        'inputs': ['/sandbox/home/only.pdf'],
        'output': '/sandbox/home/out.pdf',
      }),
      throwsA(isA<ArgumentError>()),
    );
    await expectLater(
      cap.callTool('merge', {
        'inputs': <String>[],
        'output': '/sandbox/home/out.pdf',
      }),
      throwsA(isA<ArgumentError>()),
    );
    expect(pythonCalls, 0);
  });

  test('pdf compress reports sizes honestly', () async {
    Duration? compressTimeout;
    final cap = PdfToolsCapability(
      runner: (List<String> args, {String? cwd, Duration? timeout}) async {
        final cmd = args.join(' ');
        if (cmd.contains('command -v python3')) return '/usr/bin/python3\n';
        if (args.isNotEmpty && args.first == 'python3') {
          compressTimeout = timeout;
          return 'rewrite-ok';
        }
        if (cmd.contains('stat -c%s')) {
          if (cmd.contains('in.pdf')) return '12345\n';
          if (cmd.contains('out.pdf')) return '6789\n';
        }
        throw ArgumentError('unexpected sandbox command: $cmd');
      },
      isSandboxInstalled: () => true,
    );
    final out = await cap.callTool('compress', {
      'input': '/sandbox/home/in.pdf',
      'output': '/sandbox/home/out.pdf',
    });
    expect(out, contains('12345'));
    expect(out, contains('6789'));
    expect(compressTimeout, const Duration(seconds: 300));
  });
}
