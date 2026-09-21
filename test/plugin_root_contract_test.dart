import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/agent_service.dart';
import 'package:ovid_ai/core/hook_service.dart';
import 'package:ovid_ai/core/plugin_manifest.dart';
import 'package:ovid_ai/core/plugin_registry.dart';
import 'package:ovid_ai/core/sandbox_service.dart';

/// Regression tests for the [CC]/Codex plugin host contract.
///
/// Three independent defects made EVERY plugin fail — not one in
/// particular — and all three were invisible to the existing suite because
/// its seams sat ABOVE the defects.
///
///  1. `HookService._exec` built the full plugin env map
///     (`CLAUDE_PLUGIN_ROOT`, `PLUGIN_ROOT`, `PLUGIN_PAYLOAD`, ...) and then
///     never handed it to `execChecked`. Hooks therefore ran with every
///     variable unset, so `"${CLAUDE_PLUGIN_ROOT}/hooks/run-hook.cmd"`
///     expanded to `/hooks/run-hook.cmd` and died with exit 127. The
///     existing tests used `executorForTest`, which is consulted ABOVE the
///     sandbox call: it saw the env map and could never observe that the map
///     never reached the process. This test therefore asserts at the
///     `execChecked` boundary — the exact seam where the map was dropped.
///
///  2. `AgentService.isSkillAvailableForSession` compared
///     `File(x).absolute.path` on both sides. That getter keeps whichever
///     spelling it was handed and never resolves links, while Android
///     exposes the app directory as both `/data/user/0/<pkg>` and
///     `/data/data/<pkg>`. Every contribution was rejected with "not active
///     in the current manifest for this session".
///
///  3. Plugin-declared MCP servers interpolate `${CLAUDE_PLUGIN_ROOT}` into
///     `command`/`args`/`cwd`, but stdio servers are spawned as a raw argv
///     list with NO shell — an unexpanded literal can never start.
void main() {
  const root = '/data/data/com.example.app/files/plugin-runtime'
      '/acme/toolkit/1.0.0/content';

  group('expandPluginRoot', () {
    test('expands every supported root alias', () {
      for (final v in kPluginRootVariables) {
        expect(
          expandPluginRoot('$v/server.js', root),
          '$root/server.js',
          reason: 'alias $v must resolve against the installed root',
        );
      }
    });

    test('expands an alias embedded in a longer argument', () {
      expect(
        expandPluginRoot(r'--root=${CLAUDE_PLUGIN_ROOT} --mode=stdio', root),
        '--root=$root --mode=stdio',
      );
    });

    test('leaves values without a variable untouched', () {
      expect(expandPluginRoot('/usr/bin/node', root), '/usr/bin/node');
      expect(expandPluginRoot('', root), '');
    });

    test('never substitutes when the root is unknown', () {
      // An unknown root must not turn `${CLAUDE_PLUGIN_ROOT}/x` into `/x`:
      // a half-expanded path would point at the filesystem root.
      expect(
        expandPluginRoot(r'${CLAUDE_PLUGIN_ROOT}/x', ''),
        r'${CLAUDE_PLUGIN_ROOT}/x',
      );
    });
  });

  group('hook env contract', () {
    setUp(() => HookService.I.resetForTest());
    tearDown(() {
      HookService.I.resetForTest();
      SandboxService.execCheckedOverrideForTest = null;
      // The contribution registry is a process-wide singleton: without
      // this the second test would also observe the first test's plugin,
      // and `captured.first` could be the wrong manifest.
      PluginContributionRegistry.I.unregisterPlugin('acme/toolkit');
      PluginContributionRegistry.I.unregisterPlugin('acme/codex-toolkit');
    });

    test('hook commands run with the plugin root env set', () async {
      final captured = <Map<String, String>>[];
      SandboxService.execCheckedOverrideForTest = (args, env) async {
        captured.add(env);
        return (0, '');
      };

      // A manifest whose hook interpolates the [CC] root variable — the
      // exact shape `obra/superpowers` and most published bundles ship.
      final manifest = NormalizedPluginManifest.fromJson({
        'id': 'acme/toolkit',
        'name': 'toolkit',
        'version': '1.0.0',
        'format': 'claudeCode',
        'rootPath': root,
        'hooks': [
          {
            'pluginId': 'acme/toolkit',
            'event': 'session_start',
            'ordinal': 0,
            'type': 'command',
            'payload': r'"${CLAUDE_PLUGIN_ROOT}/hooks/run-hook.cmd" start',
          },
        ],
      });
      PluginContributionRegistry.I.register(
        manifest,
        activation: PluginActivation.globalActive,
      );

      await HookService.I.fire('session_start', 'sess-1');

      expect(
        captured,
        isNotEmpty,
        reason: 'the hook must actually reach the sandbox exec boundary',
      );
      final env = captured.first;
      expect(
        env['CLAUDE_PLUGIN_ROOT'],
        root,
        reason: 'unset here the command expands to /hooks/run-hook.cmd '
            '(exit 127) for every [CC] plugin',
      );
      expect(env['PLUGIN_ROOT'], root);
      expect(env['OVID_PLUGIN_ROOT'], root);
      expect(env['PLUGIN_SESSION'], 'sess-1');
      expect(env['PLUGIN_EVENT'], 'session_start');
      expect(env['PLUGIN_ID'], isNotNull);
    });

    test('a codex-format manifest gets the same env contract', () async {
      final captured = <Map<String, String>>[];
      SandboxService.execCheckedOverrideForTest = (args, env) async {
        captured.add(env);
        return (0, '');
      };

      final manifest = NormalizedPluginManifest.fromJson({
        'id': 'acme/codex-toolkit',
        'name': 'codex-toolkit',
        'version': '1.0.0',
        'format': 'codex',
        'rootPath': root,
        'hooks': [
          {
            'pluginId': 'acme/codex-toolkit',
            'event': 'session_start',
            'ordinal': 0,
            'type': 'command',
            'payload': r'"${CLAUDE_PLUGIN_ROOT}/hooks/run-hook" start',
          },
        ],
      });
      PluginContributionRegistry.I.register(
        manifest,
        activation: PluginActivation.globalActive,
      );

      await HookService.I.fire('session_start', 'sess-2');

      expect(captured, isNotEmpty);
      expect(
        captured.first['CLAUDE_PLUGIN_ROOT'],
        root,
        reason: 'the fix is keyed on manifest.rootPath, so Codex bundles '
            'must resolve exactly like [CC] ones',
      );
    });
  });

  group('contribution path identity', () {
    test('a symlinked spelling and its target canonicalise equal', () {
      // The device-level shape of defect 2: one directory reachable by two
      // spellings. `/data/user/0` is a symlink to `/data/data` on Android.
      final real = Directory.systemTemp.createTempSync('ovid-canon-real');
      addTearDown(() {
        if (real.existsSync()) real.deleteSync(recursive: true);
      });
      final link = Link('${real.parent.path}/ovid-canon-link.lnk');
      if (link.existsSync()) link.deleteSync();
      link.createSync(real.path);
      addTearDown(() {
        if (link.existsSync()) link.deleteSync();
      });

      expect(
        AgentService.canonicalFilePath(link.path),
        AgentService.canonicalFilePath(real.path),
        reason: 'a contribution reached by either spelling is the SAME '
            'contribution; comparing File.absolute.path rejects it',
      );
    });

    test('canonicalisation is idempotent and never mangles a path', () {
      final dir = Directory.systemTemp.createTempSync('ovid-canon');
      addTearDown(() => dir.deleteSync(recursive: true));
      final once = AgentService.canonicalFilePath(dir.path);
      expect(AgentService.canonicalFilePath(once), once);
      expect(once, dir.path);
    });

    test('an unresolvable path degrades to its absolute form', () {
      final missing = '${Directory.systemTemp.path}/ovid-does-not-exist-xyz';
      expect(AgentService.canonicalFilePath(missing), missing);
    });
  });
}
