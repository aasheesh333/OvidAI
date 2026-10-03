import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/agent_service.dart';
import 'package:ovid_ai/core/sandbox_service.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    root = await Directory.systemTemp.createTemp('agent-code-fixture-');
    await Directory('${root.path}/bin').create();
    await Link('${root.path}/bin/python3').create('/usr/bin/python3');
    final node = await Process.run('which', ['node']);
    await Link('${root.path}/bin/node').create((node.stdout as String).trim());
    SandboxService.I.sandboxPrefixForTest = root;
    final app = AppState.createForTest();
    app.sessions.add(ChatSession(id: 'code-fixture', title: 'Test',
        model: 'm', mode: 'drive')..workspaceFolder = root.path);
    app.activeSessionId = 'code-fixture';
  });
  tearDown(() async {
    AgentService.I.dropSessionRun('code-fixture');
    SandboxService.I.sandboxPrefixForTest = null;
    await root.delete(recursive: true);
    AppState.resetTestInstance();
  });

  test('default Python run_code executes multiline code with -c', () async {
    final output = await AgentService.I.dispatchForTest('run_code',
        {'code': 'value = "quoted \\"雪\\""\nprint(value)'});
    // Host fixture has no Android LD_PRELOAD library; only that loader
    // diagnostic is incidental. Interpreter output and exit status are real.
    expect(output.split('\n'), contains('quoted "雪"'));
    expect(output, isNot(contains('(exit code')));
  });
  test('JavaScript run_code keeps Node inline execution', () async {
    final output = await AgentService.I.dispatchForTest('run_code',
        {'lang': 'javascript', 'code': 'console.log(6 * 7)'});
    expect(output.split('\n'), contains('42'));
    expect(output, isNot(contains('(exit code')));
  });
  test('unknown run_code language never executes as JavaScript', () async {
    final output = await AgentService.I.dispatchForTest('run_code',
        {'lang': 'ruby', 'code': 'console.log("executed")'});
    expect(output.toLowerCase(), contains('unsupported language'));
    expect(output, isNot(contains('executed')));
  });
}
