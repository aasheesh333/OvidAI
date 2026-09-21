import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:ovid_ai/core/hook_service.dart';
import 'package:ovid_ai/core/plugin_adapters.dart';
import 'package:ovid_ai/core/plugin_manifest.dart';
import 'package:ovid_ai/core/plugin_registry.dart';

/// REAL hook-chain E2E against the actual `obra/superpowers` checkout
/// (cloned 2026-09-21 @ 5bf4e78, v6.4.1 — the tree the adapter E2E
/// mirrors synthetically).
///
/// The chain is genuine end to end: the REAL Claude adapter inspects the
/// REAL repo → the REAL session_start hook (matcher `startup|clear|compact`,
/// payload `"${CLAUDE_PLUGIN_ROOT}/hooks/run-hook.cmd" session-start`) is
/// registered → `HookService.fire('session_start', …)` resolves the
/// payload, sets `CLAUDE_PLUGIN_ROOT` in the env, and runs the REAL
/// polyglot `run-hook.cmd` + the REAL `session-start` bash script on the
/// host (the executor seam stands in for the Android sandbox, which does
/// not exist on host CI) → Ovid's `extractHookContext` parses the
/// `hookSpecificOutput.additionalContext` JSON the script emits.
///
/// Skipped automatically when the checkout is absent (ephemeral /tmp).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const repoPath = '/tmp/superpowers';

  setUp(() => HookService.I.resetForTest());
  tearDown(() {
    HookService.I.resetForTest();
    PluginContributionRegistry.I.unregisterPlugin('jesse-vincent/superpowers');
  });

  test('session_start injects the using-superpowers skill context', () async {
    if (!Directory(repoPath).existsSync()) {
      markTestSkipped('no /tmp/superpowers checkout on this machine');
      return;
    }

    // 1. Real adapter inspect of the real repo.
    final manifest = await const ClaudePluginAdapter().inspect(
      Directory(repoPath),
    );
    expect(manifest.id, 'jesse-vincent/superpowers');
    final hook = manifest.hooks.singleWhere((h) => h.event == 'session_start');
    expect(hook.matcher, 'startup|clear|compact');
    expect(hook.payload, contains('run-hook.cmd'));

    PluginContributionRegistry.I.register(
      manifest,
      activation: PluginActivation.globalActive,
    );

    // 2. Run the hook's REAL command through the host shell with the REAL
    // env Ovid builds (CLAUDE_PLUGIN_ROOT=<repo>). The sandbox seam is the
    // only substitution — everything else is production code.
    HookService.I.executorForTest = (cmd, env) async {
      final result = await Process.run('bash', ['-c', cmd], environment: env);
      expect(
        result.exitCode,
        0,
        reason: 'real session-start script failed: ${result.stderr}',
      );
      return result.stdout as String;
    };

    // 3. Fire exactly like production does (reason `created` → source
    // `startup`, which is what the `startup|clear|compact` matcher matches)
    // and verify the extracted session context.
    final raw = await HookService.I.fire(
      'session_start',
      'sess-e2e',
      payload: {'reason': 'created'},
    );
    expect(
      raw,
      contains('hookSpecificOutput'),
      reason: 'the real script emits the Claude-format JSON envelope',
    );
    final context = HookService.I.sessionContextFor('sess-e2e');

    expect(
      context,
      contains('using-superpowers'),
      reason: 'the skill content must reach the session context',
    );
    expect(context, contains('You have superpowers'));
    // The raw JSON envelope must NOT leak into the context.
    expect(context, isNot(contains('hookSpecificOutput')));
  }, timeout: const Timeout(Duration(minutes: 2)));
}
