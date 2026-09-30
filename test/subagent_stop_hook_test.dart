import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:ovid_ai/core/hook_service.dart';
import 'package:ovid_ai/core/plugin_manifest.dart';
import 'package:ovid_ai/core/plugin_registry.dart';

/// Claude Code SubagentStop parity (audit 2026-09-25).
///
/// A SubagentStop hook exiting 2 BLOCKS the stop: the subagent is sent back to
/// work with the hook's stderr as its instruction. Ovid fired `subagent_end`
/// observe-only, so exit 2 was swallowed as a generic hook failure and the
/// child settled anyway.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(HookService.I.resetForTest);
  tearDown(() {
    HookService.I.resetForTest();
    PluginContributionRegistry.I.unregisterPlugin('acme/stop-gate');
  });

  void register(String event) {
    final m = NormalizedPluginManifest(
      id: 'acme/stop-gate',
      name: 'stop-gate',
      version: '1.0.0',
      format: PluginFormat.claudeCode,
      rootPath: '/plugin',
      hooks: [
        PluginHook(
          pluginId: 'acme/stop-gate',
          event: event,
          ordinal: 0,
          type: 'command',
          payload: 'decide',
          timeoutS: 5,
        ),
      ],
    );
    PluginContributionRegistry.I.register(
      m,
      activation: PluginActivation.sessionActive,
      immediateSessionId: 'child-1',
    );
  }

  test('subagent_end exit 2 is reported as a block, with stderr as the reason',
      () async {
    register('subagent_end');
    HookService.I.stdinExecutorForTest =
        (cmd, env, stdin) async => (2, 'you have not written the tests yet');

    final res = await HookService.I.fireDetailed(
      'subagent_end',
      'child-1',
      payload: {'subagentId': 'a1'},
    );

    expect(res.blockedReason, contains('not written the tests'));
  });

  test('subagent_end exit 0 does not block', () async {
    register('subagent_end');
    HookService.I.stdinExecutorForTest = (cmd, env, stdin) async => (0, '');

    final res = await HookService.I.fireDetailed(
      'subagent_end',
      'child-1',
      payload: {'subagentId': 'a1'},
    );

    expect(res.blockedReason, isNull);
  });

  test('exit 2 on an ordinary observe event still fails open', () async {
    register('post_tool');
    HookService.I.stdinExecutorForTest =
        (cmd, env, stdin) async => (2, 'broken hook');

    final res = await HookService.I.fireDetailed(
      'post_tool',
      'child-1',
      payload: {'tool': 'file_read'},
    );

    expect(res.blockedReason, isNull,
        reason: 'only the two CC blocking events may block; a broken hook '
            'must never wedge a run');
  });

  test('exactly the two Claude Code blocking events are listed', () {
    expect(HookService.kExit2BlockingEvents, {
      'user_prompt_submit',
      'subagent_end',
    });
  });

  group('the subagent loop honours the block', () {
    final src = File('lib/core/agent_service.dart').readAsStringSync();

    test('the stop point consults the hook and is bounded', () {
      final i = src.indexOf('Future<void> _runSubagentSession(');
      expect(i, greaterThanOrEqualTo(0));
      final body = src.substring(i, i + 4000);
      expect(body, contains('_subagentStopBlockReason(child, sub)'));
      expect(body, contains('stopBlocks < _maxSubagentStopBlocks'),
          reason: 'a hook that always blocks must not spin the child forever');
    });

    test('a natural stop does not fire subagent_end twice', () {
      final i = src.indexOf('Future<void> _runSubagentSession(');
      final body = src.substring(i, i + 9000);
      expect(body, contains('if (!endHookFired &&'),
          reason: 'the settlement fire must be skipped when the stop-point '
              'gate already fired the same event');
    });

    test('the blocking check fails open', () {
      final i = src.indexOf('Future<String?> _subagentStopBlockReason(');
      expect(i, greaterThanOrEqualTo(0));
      final body = src.substring(i, src.indexOf('\n  }', i));
      expect(body, contains('return res.blockedReason;'));
      expect(body, contains("Diag.swallow('agent_service.subagentStopHook'"));
    });
  });
}
