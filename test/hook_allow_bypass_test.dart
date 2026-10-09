import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:ovid_ai/core/hook_service.dart';
import 'package:ovid_ai/core/plugin_manifest.dart';
import 'package:ovid_ai/core/plugin_registry.dart';

/// Claude Code hook decision parity (audit 2026-09-25).
///
/// `hookSpecificOutput.permissionDecision: "allow"` means the plugin has
/// ALREADY decided, so Claude Code skips the user permission prompt for that
/// tool call. Ovid treated `allow` as merely "not deny and not ask" and still
/// prompted, so a hook that decided could never actually decide. The gate now
/// reports it and the approval path honours it — narrowly: only the ordinary
/// prompt is skipped.
const _bypassCheck = 'if (_permissionDispatchCtx?.hookAllowBypass ?? false)';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(HookService.I.resetForTest);
  tearDown(() {
    HookService.I.resetForTest();
    PluginContributionRegistry.I.unregisterPlugin('acme/gate');
  });

  void registerPreToolHook() {
    final m = NormalizedPluginManifest(
      id: 'acme/gate',
      name: 'gate',
      version: '1.0.0',
      format: PluginFormat.claudeCode,
      rootPath: '/plugin',
      hooks: [
        PluginHook(
          pluginId: 'acme/gate',
          event: 'pre_tool',
          ordinal: 0,
          type: 'command',
          payload: 'decide',
          matcher: 'run_shell',
          timeoutS: 5,
        ),
      ],
    );
    PluginContributionRegistry.I.register(
      m,
      activation: PluginActivation.sessionActive,
      immediateSessionId: 's1',
    );
  }

  Map<String, dynamic> payload() => {'tool': 'run_shell', 'args': {}};

  test('permissionDecision allow is reported as a bypass', () async {
    registerPreToolHook();
    HookService.I.executorForTest = (cmd, env) async => jsonEncode({
      'hookSpecificOutput': {
        'hookEventName': 'PreToolUse',
        'permissionDecision': 'allow',
        'permissionDecisionReason': 'policy says this is fine',
      },
    });

    final gate = await HookService.I.fireGate('pre_tool', 's1',
        payload: payload());

    expect(gate.decision, HookDecision.allow);
    expect(gate.bypassPermission, isTrue,
        reason: 'the caller must know a hook already approved this call');
  });

  test('no permissionDecision means no bypass', () async {
    registerPreToolHook();
    HookService.I.executorForTest = (cmd, env) async => '';

    final gate = await HookService.I.fireGate('pre_tool', 's1',
        payload: payload());

    expect(gate.decision, HookDecision.allow);
    expect(gate.bypassPermission, isFalse);
  });

  test('deny and ask still win over any bypass', () async {
    registerPreToolHook();
    HookService.I.executorForTest = (cmd, env) async => jsonEncode({
      'hookSpecificOutput': {'permissionDecision': 'deny'},
    });
    final denied = await HookService.I.fireGate('pre_tool', 's1',
        payload: payload());
    expect(denied.decision, HookDecision.deny);
    expect(denied.bypassPermission, isFalse);

    HookService.I.executorForTest = (cmd, env) async => jsonEncode({
      'hookSpecificOutput': {'permissionDecision': 'ask'},
    });
    final asked = await HookService.I.fireGate('pre_tool', 's1',
        payload: payload());
    expect(asked.decision, HookDecision.ask);
    expect(asked.bypassPermission, isFalse);
  });

  group('the approval path honours the bypass narrowly', () {
    final src = File('lib/core/agent_service.dart').readAsStringSync();

    test('_maybeApprove returns early on a hook allow', () {
      final i = src.indexOf('Future<bool> _maybeApprove(');
      expect(i, greaterThanOrEqualTo(0));
      final body = src.substring(i, i + 9000);
      expect(body, contains(_bypassCheck));
    });

    test('the bypass sits AFTER the plan-mode and destructive gates', () {
      final i = src.indexOf('Future<bool> _maybeApprove(');
      final body = src.substring(i, i + 9000);
      final bypassAt = body.indexOf(_bypassCheck);
      final planAt = body.indexOf('if (planMode)');
      final destructiveAt = body.indexOf('_isDestructiveCommand(summary)');
      expect(bypassAt, greaterThanOrEqualTo(0));
      expect(planAt, greaterThanOrEqualTo(0));
      expect(destructiveAt, greaterThanOrEqualTo(0));
      expect(bypassAt, greaterThan(planAt),
          reason: 'plan mode must still ask nothing / refuse destructive');
      expect(bypassAt, greaterThan(destructiveAt),
          reason: 'a hook allow must not skip the destructive confirmation');
    });

    test('the flag is per-call: set from the gate, cleared in finally', () {
      expect(src, contains('if (gate.bypassPermission)'));
      expect(src, contains('_permissionDispatchCtx?.hookAllowBypass = true;'));
      expect(src, contains('_permissionDispatchCtx?.hookAllowBypass = false;'));
      // Never on the shared run bucket: overlapping calls must not share it.
      expect(src, isNot(contains('_runResolved.hookAllowBypass')));

      // The flag lives on a per-dispatch context, created fresh for every
      // `_dispatch` (both the direct and the queued path).
      final ctxAt = src.indexOf('class _PermissionDispatchContext {');
      expect(ctxAt, greaterThanOrEqualTo(0));
      final ctxBody = src.substring(ctxAt, src.indexOf('\n}', ctxAt));
      expect(ctxBody, contains('bool hookAllowBypass = false;'));
      final dispatchAt = src.indexOf('Future<String> _dispatch(String name');
      expect(dispatchAt, greaterThanOrEqualTo(0));
      final dispatchEnd = src.indexOf('bool _dispatchNeedsPermissionQueue()');
      final dispatchBody = src.substring(dispatchAt, dispatchEnd);
      expect(
        RegExp(r'_PermissionDispatchContext\(').allMatches(dispatchBody).length,
        2,
        reason: 'each dispatch path must build its own context',
      );

      // Cleared in the dispatch's `finally`, after it was set from the gate.
      final setAt = src.indexOf('_permissionDispatchCtx?.hookAllowBypass = true;');
      final clearAt =
          src.indexOf('_permissionDispatchCtx?.hookAllowBypass = false;');
      final finallyAt = src.lastIndexOf('} finally {', clearAt);
      expect(clearAt, greaterThan(setAt));
      expect(finallyAt, greaterThan(setAt));
    });
  });
}
