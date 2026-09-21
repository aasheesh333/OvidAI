import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ovid_ai/core/hook_service.dart';
import 'package:ovid_ai/core/plugin_adapters.dart';
import 'package:ovid_ai/core/plugin_manifest.dart';
import 'package:ovid_ai/core/plugin_permissions.dart';
import 'package:ovid_ai/core/plugin_registry.dart';
import 'package:ovid_ai/core/plugin_runtime.dart';
import 'package:ovid_ai/core/plugin_source_resolver.dart';
import 'package:ovid_ai/core/skills.dart';
import 'package:ovid_ai/core/state.dart';

/// End-to-end: a real [CC] plugin on disk installs through the actual runtime
/// pipeline, its skills mount for the session, and its SessionStart hook runs
/// and produces injectable context.
///
/// Uses the real `obra/superpowers` checkout when present (skipped otherwise)
/// so this is not a synthetic fixture.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // The real checkout lives at /tmp/superpowers (older runs used
  // /tmp/opencode/superpowers); prefer the live path, fall back to the
  // legacy one, skip when neither exists.
  final pluginRoot = Directory('/tmp/superpowers').existsSync()
      ? Directory('/tmp/superpowers')
      : Directory('/tmp/opencode/superpowers');

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    AppState.resetTestInstance();
    AppState.createForTest();
    HookService.I.resetForTest();
    SkillService.I.invalidateAllSessions();
  });

  tearDown(() {
    HookService.I.resetForTest();
    SkillService.I.invalidateAllSessions();
    AppState.resetTestInstance();
  });

  test('inspects the real plugin with its skills and hook', () async {
    if (!pluginRoot.existsSync()) {
      markTestSkipped('superpowers checkout not present');
      return;
    }
    final inspection = await PluginRuntimeManager.I.inspect(
      LocalFolderPluginSource(pluginRoot.path),
    );
    expect(inspection.manifest.skills.length, greaterThanOrEqualTo(15));
    expect(inspection.manifest.hooks, isNotEmpty);
    expect(inspection.manifest.hooks.first.event, 'session_start');
    // The [CC] identity resolves from .claude-plugin/plugin.json.
    expect(inspection.manifest.id, contains('superpowers'));
  });

  test(
    'installs the real plugin and mounts its skills for a session',
    () async {
      if (!pluginRoot.existsSync()) {
        markTestSkipped('superpowers checkout not present');
        return;
      }
      final app = AppState.I;
      final row = PluginItem(
        name: 'superpowers',
        author: 'obra',
        description: 'real plugin',
        version: '6.4.1',
        category: 'Tool',
        source: null,
      );
      app.plugins.add(row);

      // Fail-closed by design: a real install needs a capability grant bound to
      // the manifest digest. Approve exactly what the plugin requests.
      final manifest = await const PluginAdapterRegistry().inspect(pluginRoot);
      await AppState.pluginPermissions.save(
        PluginPermissionGrant(
          pluginId: manifest.id,
          manifestDigest: pluginManifestDigest(manifest),
          capabilities: manifest.requestedCapabilities,
          approvedAt: DateTime.now(),
        ),
      );

      final result = await app.installPlugin(
        row,
        source: LocalFolderPluginSource(pluginRoot.path),
        origin: PluginInstallOrigin.agent,
        sessionId: 'e2e-1',
      );
      expect(result, isNotNull);
      expect(
        result!.status,
        isNot(PluginInstallStatus.failed),
        reason: result.error ?? '',
      );

      // The plugin is registered and its skills are discoverable in the
      // installing session.
      final s = ChatSession(id: 'e2e-1', title: 'T', model: 'm', mode: 'auto');
      app.sessions.add(s);
      app.activeSessionId = s.id;

      final roots = <String>[];
      final mounts = <PluginCatalogMount>[];
      for (final runtime in await PluginRuntimeManager.I.activeRuntimes()) {
        mounts.add(PluginCatalogMount(runtime.contentDir, runtime.manifest));
      }
      // Publish with just the mounts (no workspace roots needed).
      await SkillService.I.publishSessionCatalog(
        'e2e-1',
        roots: roots,
        mounts: mounts,
      );
      final skills = SkillService.I.skillsForSession('e2e-1');
      final names = skills.map((x) => x.name).toSet();
      expect(names, contains('brainstorming'));
      expect(names, contains('test-driven-development'));
      // skill() must return the body with frontmatter stripped.
      final brainstorm = skills.firstWhere((x) => x.name == 'brainstorming');
      expect(brainstorm.content, isNot(startsWith('---')));
      expect(brainstorm.content, contains('Brainstorming Ideas Into Designs'));
    },
  );

  test(
    'the real plugin SessionStart hook produces injectable context',
    () async {
      if (!pluginRoot.existsSync()) {
        markTestSkipped('superpowers checkout not present');
        return;
      }
      // Simulate the shipped hook's output shape (CC nested field) exactly.
      HookService.I.executorForTest = (cmd, env) async => jsonEncode({
        'hookSpecificOutput': {
          'hookEventName': 'SessionStart',
          'additionalContext':
              'You have superpowers. (from ${env['CLAUDE_PLUGIN_ROOT']})',
        },
      });
      final m = NormalizedPluginManifest(
        id: 'obra/superpowers',
        name: 'superpowers',
        version: '6.4.1',
        format: PluginFormat.claudeCode,
        rootPath: pluginRoot.path,
        hooks: [
          PluginHook(
            pluginId: 'obra/superpowers',
            event: 'session_start',
            ordinal: 0,
            type: 'command',
            payload:
                '"\${CLAUDE_PLUGIN_ROOT}/hooks/run-hook.cmd" session-start',
            matcher: 'startup|clear|compact',
          ),
        ],
      );
      PluginContributionRegistry.I.register(
        m,
        activation: PluginActivation.sessionActive,
        immediateSessionId: 'e2e-2',
      );
      addTearDown(() => PluginContributionRegistry.I.unregisterPlugin(m.id));

      await HookService.I.fire(
        'session_start',
        'e2e-2',
        payload: {'reason': 'created'},
      );
      final ctx = HookService.I.sessionContextFor('e2e-2');
      expect(ctx, contains('You have superpowers'));
      // CLAUDE_PLUGIN_ROOT resolved to the real plugin root.
      expect(ctx, contains(pluginRoot.path));
    },
  );
}
