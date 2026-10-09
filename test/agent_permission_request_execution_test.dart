import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/agent_service.dart';
import 'package:ovid_ai/core/hook_service.dart';
import 'package:ovid_ai/core/plugin_manifest.dart';
import 'package:ovid_ai/core/plugin_registry.dart';
import 'package:ovid_ai/core/sandbox_service.dart';
import 'package:ovid_ai/core/state.dart';
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _TestPaths extends PathProviderPlatform {
  _TestPaths(this.directory);

  final Directory directory;

  @override
  Future<String?> getApplicationDocumentsPath() async => directory.path;

  @override
  Future<String?> getApplicationSupportPath() async => directory.path;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory workspace;
  late PathProviderPlatform originalPaths;
  const pluginId = 'execution/permission-request';
  const sessionId = 'permission-execution';

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    workspace = await Directory.systemTemp.createTemp('permission-execution-');
    originalPaths = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _TestPaths(workspace);
    AppState.usageRootOverrideForTest = null;
    AppState.resetTestInstance();
    final app = AppState.createForTest(pluginBootActivator: (_, _) async {});
    app.sessions.add(
      ChatSession(
        id: sessionId,
        title: 'permission execution',
        model: 'test',
        mode: 'auto',
        workspaceFolder: workspace.path,
      ),
    );
    app.activeSessionId = sessionId;
    AgentService.setRunSessionForTest(sessionId);
    AgentService.planModeRootForTest = workspace.path;
    HookService.I.resetForTest();
    HookService.I.enabled = true;
    // The production phone-terminal executable is Android-only. Keep the
    // process boundary real in this host-side execution test while mapping
    // that executable to the host shell.
    SandboxService.processStartForTest =
        (executable, arguments, workingDirectory, environment) => Process.start(
          '/bin/sh',
          arguments,
          workingDirectory: workingDirectory,
          environment: environment,
        );
    PluginContributionRegistry.I.register(
      NormalizedPluginManifest(
        id: pluginId,
        name: 'permission execution',
        version: '1',
        format: PluginFormat.claudeCode,
        rootPath: workspace.path,
        hooks: [
          PluginHook(
            pluginId: pluginId,
            event: 'permission_request',
            ordinal: 0,
            type: 'command',
            payload: 'permission decision',
            matcher: 'run_shell',
          ),
        ],
      ),
      activation: PluginActivation.sessionActive,
      immediateSessionId: sessionId,
    );
  });

  tearDown(() async {
    PluginContributionRegistry.I.unregisterPlugin(pluginId);
    PathProviderPlatform.instance = originalPaths;
    HookService.I.resetForTest();
    SandboxService.processStartForTest = null;
    AgentService.setRunSessionForTest('');
    AgentService.I.clearRunCtxForTest();
    AgentService.planModeRootForTest = null;
    AppState.usageRootOverrideForTest = null;
    AppState.resetTestInstance();
    await workspace.delete(recursive: true);
  });

  String permissionResponse(String behavior, {String? command}) => jsonEncode({
    'hookSpecificOutput': {
      'hookEventName': 'PermissionRequest',
      'decision': {
        'behavior': behavior,
        if (behavior == 'deny') 'message': 'blocked by execution policy',
        if (command != null) 'updatedInput': {'command': command},
      },
    },
  });

  test('permission allow rewrite reaches the real tool executor', () async {
    var hookCalls = 0;
    HookService.I.executorForTest = (_, _) async {
      hookCalls++;
      return permissionResponse('allow', command: 'printf rewritten');
    };

    final result = await AgentService.I.dispatchForTest('run_shell', {
      'command': 'printf original',
    });

    expect(result.trim(), 'rewritten');
    expect(hookCalls, 1, reason: 'the permission hook must not run on replay');
  });

  test('permission deny prevents the real tool executor', () async {
    HookService.I.executorForTest = (_, _) async {
      return permissionResponse('deny');
    };

    final result = await AgentService.I.dispatchForTest('run_shell', {
      'command': 'printf must-not-run > ${workspace.path}/denied-marker',
    });

    expect(result, 'DENIED by user');
    expect(File('${workspace.path}/denied-marker').existsSync(), isFalse);
  });

  test(
    'permission rewrite replay state is isolated between concurrent dispatches',
    () async {
      var hookCalls = 0;
      final firstHook = Completer<void>();
      HookService.I.executorForTest = (event, _) async {
        hookCalls++;
        if (hookCalls == 1) await firstHook.future;
        final command = hookCalls == 2 ? 'printf second' : 'printf first';
        return permissionResponse('allow', command: command);
      };

      final first = AgentService.I.dispatchForTest('run_shell', {
        'command': 'printf first',
      });
      await Future<void>.delayed(Duration.zero);
      final second = AgentService.I.dispatchForTest('run_shell', {
        'command': 'printf second',
      });
      firstHook.complete();

      expect((await first).trim(), 'first');
      expect((await second).trim(), 'second');
      expect(hookCalls, 2);
    },
  );

  test(
    'account change immediately before execution cancels the side effect',
    () async {
      Future<void>? accountChange;
      HookService.I.executorForTest = (_, _) async {
        // transitionSessionAccount invalidates the dispatch token synchronously.
        accountChange = AppState.I.transitionSessionAccount(
          'permission-test-account',
        );
        return permissionResponse('allow', command: 'printf should-not-run');
      };

      final marker = '${workspace.path}/account-change-marker';
      final result = await AgentService.I.dispatchForTest('run_shell', {
        'command': 'printf ran > $marker',
      });

      expect(result, isNot(contains('should-not-run')));
      expect(File(marker).existsSync(), isFalse);
      await accountChange;
    },
  );

  test(
    'destructive, plan-mode, read-only, and path guards run before execution',
    () async {
      final session = AppState.I.sessionById(sessionId)!;

      session.mode = 'safe';
      session.planMode = false;
      expect(
        await AgentService.I.dispatchForTest('run_shell', {
          'command': 'touch x',
        }),
        contains('READ-ONLY MODE'),
      );

      session.mode = 'auto';
      session.planMode = true;
      expect(
        await AgentService.I.dispatchForTest('run_shell', {
          'command': 'rm -f x',
        }),
        contains('PLAN MODE'),
      );
      expect(
        await AgentService.I.dispatchForTest('file_write', {
          'path': '../outside.txt',
          'content': 'must not write',
        }),
        contains('PLAN MODE'),
      );
      expect(
        await AgentService.I.dispatchForTest('file_read', {
          'path': '../outside.txt',
        }),
        contains('PLAN MODE'),
      );
    },
  );
}
