import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ovid_ai/core/agent_service.dart';
import 'package:ovid_ai/core/hook_service.dart';
import 'package:ovid_ai/core/mcp_service.dart';
import 'package:ovid_ai/core/plugin_manifest.dart';
import 'package:ovid_ai/core/plugin_permissions.dart';
import 'package:ovid_ai/core/plugin_registry.dart';
import 'package:ovid_ai/core/plugin_runtime.dart';
import 'package:ovid_ai/core/plugin_source_resolver.dart';
import 'package:ovid_ai/core/skills.dart';
import 'package:ovid_ai/core/state.dart';

// Post-install bootstrap: a plugin installed by the agent must be usable in
// the installing session immediately — its skills mount AND its
// session_start hooks fire for that session (the generic session_start is
// exactly-once per boot and already ran). Plus: .cmd entrypoint rewrite,
// install-message naming, row version sync, and loud missing-command.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory staging;
  late Directory runtime;
  late Directory fixture;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    staging = Directory.systemTemp.createTempSync('boot-staging-');
    runtime = Directory.systemTemp.createTempSync('boot-runtime-');
    fixture = Directory.systemTemp.createTempSync('boot-fixture-');
    PluginRuntimeManager.stagingRootOverrideForTest = staging;
    PluginRuntimeManager.runtimeRootOverrideForTest = runtime;
    AppState.resetTestInstance();
    AppState.createForTest();
    HookService.I.resetForTest();
    SkillService.I.invalidateAllSessions();
  });

  tearDown(() async {
    AgentService.setRunSessionForTest('');
    HookService.I.resetForTest();
    SkillService.I.invalidateAllSessions();
    PluginRuntimeManager.stagingRootOverrideForTest = null;
    PluginRuntimeManager.runtimeRootOverrideForTest = null;
    AppState.resetTestInstance();
    for (final d in [staging, runtime, fixture]) {
      try {
        d.deleteSync(recursive: true);
      } catch (_) {}
    }
    SharedPreferences.setMockInitialValues({});
  });

  void writeFixture() {
    File('${fixture.path}/.claude-plugin/plugin.json')
      ..createSync(recursive: true)
      ..writeAsStringSync(jsonEncode({
        'name': 'bootkit',
        'version': '9.9.9',
        'author': {'name': 'acme'},
        'description': 'bootstrap fixture',
      }));
    File('${fixture.path}/skills/foo/SKILL.md')
      ..createSync(recursive: true)
      ..writeAsStringSync(
        '---\nname: foo\ndescription: Foo skill\n---\n\nFoo body.\n',
      );
    File('${fixture.path}/hooks/hooks.json')
      ..createSync(recursive: true)
      ..writeAsStringSync(jsonEncode({
        'hooks': {
          'SessionStart': [
            {
              'matcher': 'startup',
              'hooks': [
                {'type': 'command', 'command': 'echo hi'},
              ],
            },
          ],
        },
      }));
  }

  Future<PluginItem> installFixture(String sessionId) async {
    writeFixture();
    final app = AppState.I;
    final inspection = await PluginRuntimeManager.I.inspect(
      LocalFolderPluginSource(fixture.path),
    );
    final manifest = inspection.manifest;
    await AppState.pluginPermissions.save(
      PluginPermissionGrant(
        pluginId: manifest.id,
        manifestDigest: pluginManifestDigest(manifest),
        capabilities: manifest.requestedCapabilities,
        approvedAt: DateTime.now(),
      ),
    );
    final row = PluginItem(
      name: 'bootkit',
      author: 'acme',
      description: 'bootstrap fixture',
      version: '1.0.0',
      category: 'Tool',
    );
    app.plugins.add(row);
    AgentService.setRunSessionForTest(sessionId);
    HookService.I.executorForTest = (cmd, env) async => jsonEncode({
      'hookSpecificOutput': {
        'hookEventName': 'SessionStart',
        'additionalContext': 'BOOTSTRAP-CTX',
      },
    });
    final res = await AgentService.I.dispatchForTest('agent_install_plugin', {
      'plugin_name': 'bootkit',
      'local_path': fixture.path,
    });
    expect(res, contains('installed'));
    return row;
  }

  test(
    'agent install mounts skills, syncs version, and fires session_start '
    'for the installing session',
    () async {
      final app = AppState.I;
      final s = ChatSession(id: 'boot-1', title: 'T', model: 'm');
      app.sessions.add(s);
      app.activeSessionId = s.id;

      final row = await installFixture(s.id);

      // Row version follows the manifest, not the transient placeholder.
      expect(row.version, '9.9.9');
      // Skill resolves with the frontmatter-stripped body.
      final skill = SkillService.I.resolveForSession(s.id, 'foo').unique;
      expect(skill, isNotNull);
      expect(skill!.content, contains('Foo body.'));
      expect(skill.content, isNot(startsWith('---')));
      // This session received the plugin bootstrap context.
      expect(
        HookService.I.sessionContextFor(s.id),
        contains('BOOTSTRAP-CTX'),
      );
    },
  );

  test('.cmd hook entrypoint prefers the extensionless sibling', () async {
    final dir = Directory('${fixture.path}/hooks')..createSync(recursive: true);
    File('${dir.path}/run-hook.cmd').writeAsStringSync('@echo off\n');
    File('${dir.path}/run-hook').writeAsStringSync('#!/bin/sh\nexit 0\n');
    const pid = 'acme/cmdkit';
    PluginContributionRegistry.I.register(
      NormalizedPluginManifest(
        id: pid,
        name: 'cmdkit',
        version: '1.0.0',
        format: PluginFormat.claudeCode,
        rootPath: fixture.path,
        hooks: const [],
      ),
      activation: PluginActivation.sessionActive,
      immediateSessionId: 'cmd-1',
    );
    addTearDown(() => PluginContributionRegistry.I.unregisterPlugin(pid));
    final hook = PluginHook(
      pluginId: pid,
      event: 'session_start',
      ordinal: 0,
      type: 'command',
      payload: '"\${CLAUDE_PLUGIN_ROOT}/hooks/run-hook.cmd" session-start',
    );
    final resolved = HookService.I.resolveHookPayload(hook);
    expect(resolved, contains('/hooks/run-hook"'));
    expect(resolved, contains('session-start'));
    expect(resolved, isNot(contains('.cmd')));
  });

  test('.cmd without a sibling is left untouched (fail-open)', () {
    const pid = 'acme/cmdsolo';
    PluginContributionRegistry.I.register(
      NormalizedPluginManifest(
        id: pid,
        name: 'cmdsolo',
        version: '1.0.0',
        format: PluginFormat.claudeCode,
        rootPath: fixture.path,
        hooks: const [],
      ),
      activation: PluginActivation.sessionActive,
      immediateSessionId: 'cmd-2',
    );
    addTearDown(() => PluginContributionRegistry.I.unregisterPlugin(pid));
    const payload = '"\${CLAUDE_PLUGIN_ROOT}/hooks/only.cmd" go';
    final hook = PluginHook(
      pluginId: pid,
      event: 'session_start',
      ordinal: 0,
      type: 'command',
      payload: payload,
    );
    expect(HookService.I.resolveHookPayload(hook), payload);
  });

  test('stdio connect with no command fails loudly, never spawns npx',
      () async {
    final server = McpServer(
      name: 'no-cmd',
      author: 't',
      description: 'missing command',
      category: 'Custom',
      command: '',
      custom: true,
      transport: 'stdio',
    );
    AppState.I.mcpServers.add(server);
    final msg = await McpService.I.connect(server);
    expect(msg, contains('declares no command'));
    expect(McpService.I.isConnected(server.canonicalId), isFalse);
  });
}
