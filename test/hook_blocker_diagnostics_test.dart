import 'package:flutter_test/flutter_test.dart';

import 'package:ovid_ai/core/hook_service.dart';
import 'package:ovid_ai/core/plugin_manifest.dart';
import 'package:ovid_ai/core/plugin_registry.dart';

/// "The hook never fires" used to be completely silent (audit 2026-09-29).
///
/// Four different causes produce the identical symptom, and none of them left
/// any evidence a user could see:
///   1. a Plugins-screen install is `pendingGlobal` — spec §7 deliberately does
///      NOT inject it into already-running sessions, so it needs a restart;
///   2. a `sessionActive` install is scoped to the installing session only;
///   3. hook commands execute inside the Studio sandbox, which installs on
///      first Studio open — without it every hook fails;
///   4. three consecutive failures trip the circuit breaker for that session.
///
/// Each now records a human reason on HookService.hookBlockers so the Plugins
/// screen can say WHY, instead of the owner guessing.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(HookService.I.resetForTest);
  tearDown(() {
    HookService.I.resetForTest();
    PluginContributionRegistry.I.unregisterPlugin('acme/hooky');
  });

  void register(PluginActivation activation, {String? sessionId}) {
    final m = NormalizedPluginManifest(
      id: 'acme/hooky',
      name: 'hooky',
      version: '1.0.0',
      format: PluginFormat.claudeCode,
      rootPath: '/plugin',
      hooks: [
        PluginHook(
          pluginId: 'acme/hooky',
          event: 'pre_tool',
          ordinal: 0,
          type: 'command',
          payload: 'do-thing',
          timeoutS: 5,
        ),
      ],
    );
    PluginContributionRegistry.I.register(
      m,
      activation: activation,
      immediateSessionId: sessionId,
    );
  }

  test('a pendingGlobal install says it needs a restart', () {
    register(PluginActivation.pendingGlobal);

    // Any resolution attempt records why the hook was skipped.
    expect(HookService.I.hasHookListeners('pre_tool', sessionId: 's1'), isFalse);

    final reason = HookService.I.hookBlockerFor('acme/hooky');
    expect(reason, isNotNull);
    expect(reason, contains('RESTART'));
    expect(reason, contains('not activated yet'));
  });

  test('a sessionActive install in ANOTHER session says so', () {
    register(PluginActivation.sessionActive, sessionId: 'owner');

    expect(HookService.I.hasHookListeners('pre_tool', sessionId: 'other'),
        isFalse);

    final reason = HookService.I.hookBlockerFor('acme/hooky');
    expect(reason, isNotNull);
    expect(reason, contains('not active in this session'));
  });

  test('its OWN session resolves the hook and records no blocker', () {
    register(PluginActivation.sessionActive, sessionId: 'owner');
    HookService.I.executorForTest = (cmd, env) async => '';

    expect(
      HookService.I.hasHookListeners('pre_tool', sessionId: 'owner'),
      isTrue,
    );
    expect(HookService.I.hookBlockerFor('acme/hooky'), isNull);
  });

  test('a globally active plugin records no blocker', () {
    register(PluginActivation.globalActive);
    HookService.I.executorForTest = (cmd, env) async => '';

    expect(HookService.I.hasHookListeners('pre_tool', sessionId: 'any'), isTrue);
    expect(HookService.I.hookBlockerFor('acme/hooky'), isNull);
  });

  test('the circuit breaker records why the plugin went quiet', () async {
    register(PluginActivation.globalActive);
    // Every execution fails; after breakerThreshold the plugin is tripped.
    HookService.I.executorForTest = (cmd, env) async => throw StateError('boom');

    for (var i = 0; i < HookService.breakerThreshold + 1; i++) {
      await HookService.I.fire('pre_tool', 's1', payload: {'tool': 'file_read'});
    }

    expect(HookService.I.isPluginTripped('acme/hooky', 's1'), isTrue);
    final reason = HookService.I.hookBlockerFor('acme/hooky');
    expect(reason, isNotNull);
    expect(reason, contains('circuit breaker'));
  });

  test('a later success clears a stale blocker', () async {
    register(PluginActivation.globalActive);
    HookService.I.executorForTest = (cmd, env) async => throw StateError('boom');
    for (var i = 0; i < HookService.breakerThreshold + 1; i++) {
      await HookService.I.fire('pre_tool', 's1', payload: {'tool': 'file_read'});
    }
    expect(HookService.I.hookBlockerFor('acme/hooky'), isNotNull);

    // Recover: a fresh session (breaker is per plugin|session) that succeeds.
    HookService.I.executorForTest = (cmd, env) async => 'ok';
    await HookService.I.fire('pre_tool', 's2', payload: {'tool': 'file_read'});

    expect(HookService.I.hookBlockerFor('acme/hooky'), isNull,
        reason: 'a plugin whose hooks run again must not keep a stale warning');
  });

  test('hookBlockers is a snapshot, not a live mutable map', () {
    register(PluginActivation.pendingGlobal);
    HookService.I.hasHookListeners('pre_tool', sessionId: 's1');
    final snapshot = HookService.I.hookBlockers;
    expect(snapshot, contains('acme/hooky'));
    expect(() => snapshot.clear(), throwsUnsupportedError);
  });

  test('the sandbox requirement is named when a command hook cannot run',
      () async {
    register(PluginActivation.globalActive);
    // No executor override: the real path reaches the sandbox guard, which is
    // not installed in a unit test — exactly the owner's "never opened Studio"
    // device state.
    HookService.I.executorForTest = null;

    await HookService.I.fire('pre_tool', 's1', payload: {'tool': 'file_read'});

    final reason = HookService.I.hookBlockerFor('acme/hooky');
    expect(reason, isNotNull);
    expect(reason, contains('sandbox'));
    expect(reason, contains('open Studio once'));
  });
}
