import 'dart:convert';
import 'dart:async';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ovid_ai/core/hook_service.dart';
import 'package:ovid_ai/core/plugin_manifest.dart';
import 'package:ovid_ai/core/plugin_registry.dart';
import 'package:ovid_ai/core/sandbox_service.dart';
import 'package:ovid_ai/core/secure_store.dart';
import 'package:ovid_ai/core/session_ledger.dart';
import 'package:ovid_ai/core/session_lifecycle_service.dart';
import 'package:ovid_ai/core/state.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temp;
  late ChatSession session;
  final manifests = <NormalizedPluginManifest>[];

  NormalizedPluginManifest register(
    String name, {
    String version = '1',
    String matcher = 'startup',
    String command = 'context',
  }) {
    final manifest = NormalizedPluginManifest(
      id: 'restart/$name',
      name: name,
      version: version,
      format: PluginFormat.claudeCode,
      rootPath: '${temp.path}/plugin-runtime/restart/$name/$version/content',
      hooks: [
        PluginHook(
          pluginId: 'restart/$name',
          event: 'session_start',
          ordinal: 0,
          type: 'command',
          payload: command,
          matcher: matcher,
        ),
      ],
    );
    PluginContributionRegistry.I.register(
      manifest,
      activation: PluginActivation.globalActive,
    );
    manifests.removeWhere((m) => m.id == manifest.id);
    manifests.add(manifest);
    return manifest;
  }

  void wireLifecycle() {
    SessionLifecycleService.I.activationWaiterForTest = (_) async {};
    SessionLifecycleService.I.skillRefresherForTest = (_) async {};
  }

  void coldRestart() {
    final savedSession = session.toJson();
    final savedManifests = manifests.map((m) => m.toJson()).toList();
    HookService.I.resetForTest();
    SessionLifecycleService.I.resetForTest();
    for (final manifest in manifests) {
      PluginContributionRegistry.I.unregisterPlugin(manifest.id);
    }
    AppState.resetTestInstance();
    final app = AppState.createForTest(pluginBootActivator: (_, _) async {});
    session = ChatSession.fromJson(savedSession);
    app.sessions.add(session);
    for (final json in savedManifests) {
      PluginContributionRegistry.I.register(
        NormalizedPluginManifest.fromJson(json),
        activation: PluginActivation.globalActive,
      );
    }
    wireLifecycle();
  }

  Future<void> start(SessionStartReason reason) =>
      SessionLifecycleService.I.sessionStarted(session, reason: reason);

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    HookService.I.resetForTest();
    HookService.I.enabled = true;
    SessionLifecycleService.I.resetForTest();
    AppState.resetTestInstance();
    final app = AppState.createForTest(pluginBootActivator: (_, _) async {});
    temp = Directory.systemTemp.createTempSync('hook-restart-');
    final workspace = Directory('${temp.path}/workspace')..createSync();
    session = ChatSession(
      id: 'persisted-session',
      title: 'test',
      model: 'test',
      workspaceFolder: workspace.path,
    );
    app.sessions.add(session);
    SessionLedger.rootOverrideForTest = Directory('${temp.path}/ledger');
    wireLifecycle();
  });

  tearDown(() async {
    await SessionLifecycleService.I.drainForTest();
    for (final manifest in manifests) {
      PluginContributionRegistry.I.unregisterPlugin(manifest.id);
    }
    manifests.clear();
    HookService.I.resetForTest();
    SessionLifecycleService.I.resetForTest();
    SandboxService.I.resetCheckExistingForTest();
    SessionLedger.rootOverrideForTest = null;
    AppState.resetTestInstance();
    await temp.delete(recursive: true);
  });

  test(
    'cold restart restores startup-only context through production spawn',
    () async {
      final prefix = Directory('${temp.path}/sandbox');
      Directory('${prefix.path}/bin').createSync(recursive: true);
      Directory('${prefix.path}/home').createSync();
      Link('${prefix.path}/bin/bash').createSync('/bin/bash');
      SandboxService.I.sandboxPrefixForTest = prefix;
      final manifest = register(
        'production',
        command: r'bash "$PLUGIN_ROOT/start.sh"',
      );
      final script = File('${manifest.rootPath}/start.sh');
      script.parent.createSync(recursive: true);
      script.writeAsStringSync('''
read -r input
[[ "\$input" == *'"reason":"created"'* ]] || exit 3
printf '%s' '{"hookSpecificOutput":{"additionalContext":"durable startup instructions"}}'
printf 'diagnostics stay out' >&2
''');
      await start(SessionStartReason.created);
      expect(
        HookService.I.sessionContextFor(session.id),
        'durable startup instructions',
      );
      coldRestart();
      // A replay would fail: restore must use durable context, not run startup.
      script.writeAsStringSync('exit 4');
      await start(SessionStartReason.restored);
      expect(
        HookService.I.sessionContextFor(session.id),
        'durable startup instructions',
      );
      expect(HookService.I.fired, 0);
    },
  );

  test(
    'cold restart retains two plugins and adds real resume contribution',
    () async {
      register('first');
      register('second');
      register('resume', matcher: 'resume');
      HookService.I.executorForTest = (_, env) async => jsonEncode({
        'hookSpecificOutput': {'additionalContext': env['PLUGIN_ID']},
      });
      await start(SessionStartReason.created);
      coldRestart();
      final calls = <String>[];
      HookService.I.executorForTest = (_, env) async {
        calls.add(env['PLUGIN_ID']!);
        return '{"additionalContext":"real resume instructions"}';
      };
      await start(SessionStartReason.restored);
      expect(calls, ['restart/resume']);
      expect(
        HookService.I.sessionContextFor(session.id),
        'restart/first\nrestart/second\nreal resume instructions',
      );
    },
  );

  test('disabled and changed manifests are removed durably on resume', () async {
    register('keep');
    final disabled = register('disabled');
    register('version');
    register('digest');
    HookService.I.executorForTest = (_, env) async =>
        jsonEncode({'additionalContext': env['PLUGIN_ID']});
    await start(SessionStartReason.created);
    coldRestart();
    PluginContributionRegistry.I.register(
      disabled,
      activation: PluginActivation.disabled,
    );
    register('version', version: '2');
    register('digest', command: 'changed-at-same-version');
    await start(SessionStartReason.restored);
    expect(HookService.I.sessionContextFor(session.id), 'restart/keep');
    // Reinstating the old descriptor must not resurrect discarded instructions.
    register('disabled');
    register('version');
    register('digest');
    coldRestart();
    await start(SessionStartReason.restored);
    expect(HookService.I.sessionContextFor(session.id), 'restart/keep');
  });

  test('raw stdout and non-context JSON are never persisted', () async {
    register('plain');
    register('json');
    register('explicit');
    HookService
        .I
        .executorForTest = (_, env) async => switch (env['PLUGIN_ID']) {
      'restart/plain' => 'ephemeral plain output',
      'restart/json' => '{"diagnostic":"ephemeral diagnostic"}',
      _ =>
        '{"additionalContext":"retained instructions","diagnostic":"ignored diagnostic"}',
    };
    await start(SessionStartReason.created);
    final stored = (await ovidSecureStorage().readAll()).values.join();
    expect(stored.contains('ephemeral'), isFalse);
    expect(stored.contains('ignored diagnostic'), isFalse);
    final prefs = await SharedPreferences.getInstance();
    expect(
      prefs.getKeys().any(
        (key) => '${prefs.get(key)}'.contains('retained instructions'),
      ),
      isFalse,
    );
    coldRestart();
    await start(SessionStartReason.restored);
    expect(
      HookService.I.sessionContextFor(session.id),
      'retained instructions',
    );
  });

  test(
    'session end deletes durable context; unrelated sessions never inherit',
    () async {
      register('only');
      HookService.I.executorForTest = (_, _) async =>
          '{"additionalContext":"session instructions"}';
      await start(SessionStartReason.created);
      await HookService.I.fire(
        'session_start',
        'another-session',
        payload: {'reason': 'restored'},
      );
      expect(HookService.I.sessionContextFor('another-session'), isEmpty);
      await HookService.I.fire('session_end', session.id);
      coldRestart();
      await start(SessionStartReason.restored);
      expect(HookService.I.sessionContextFor(session.id), isEmpty);
    },
  );

  test(
    'disable at context read removes contribution before re-enable and restart',
    () async {
      final manifest = register('disabled-live');
      HookService.I.executorForTest = (_, _) async =>
          '{"additionalContext":"discard instructions"}';
      await start(SessionStartReason.created);
      PluginContributionRegistry.I.register(
        manifest,
        activation: PluginActivation.disabled,
      );
      expect(HookService.I.sessionContextFor(session.id), isEmpty);
      PluginContributionRegistry.I.register(
        manifest,
        activation: PluginActivation.globalActive,
      );
      expect(HookService.I.sessionContextFor(session.id), isEmpty);
      coldRestart();
      await start(SessionStartReason.restored);
      expect(HookService.I.sessionContextFor(session.id), isEmpty);
    },
  );

  test(
    'session end during execution cannot persist late instructions',
    () async {
      register('late');
      final entered = Completer<void>();
      final released = Completer<String>();
      HookService.I.executorForTest = (_, _) {
        entered.complete();
        return released.future;
      };
      final pending = start(SessionStartReason.created);
      await entered.future;
      await HookService.I.fire('session_end', session.id);
      released.complete('{"additionalContext":"late instructions"}');
      await pending;
      coldRestart();
      await start(SessionStartReason.restored);
      expect(HookService.I.sessionContextFor(session.id), isEmpty);
    },
  );

  test(
    'explicit instructions are bounded after restart and metadata stays excluded',
    () async {
      register('bounded');
      HookService.I.executorForTest = (_, _) async => jsonEncode({
        'additionalContext': 'a' * 10000,
        'env': {'private_value': 'not instruction material'},
        'diagnostic': 'not instruction material',
      });
      await start(SessionStartReason.created);
      coldRestart();
      await start(SessionStartReason.restored);
      final context = HookService.I.sessionContextFor(session.id);
      expect(context.length, 8192);
      expect(context, startsWith('aaaa'));
      expect(context.contains('not instruction material'), isFalse);
      final values = (await ovidSecureStorage().readAll()).values.join();
      expect(values.contains('not instruction material'), isFalse);
    },
  );

  test(
    'unknown secret-like instruction text never enters ordinary preferences',
    () async {
      register('sensitive');
      // Synthetic fixture only. Treat arbitrary instruction text as sensitive;
      // encryption avoids a false promise of complete regex-based scrubbing.
      const instruction = 'Use password=synthetic-fixture-only when testing.';
      HookService.I.executorForTest = (_, _) async =>
          jsonEncode({'additionalContext': instruction});
      await start(SessionStartReason.created);
      final prefs = await SharedPreferences.getInstance();
      expect(
        prefs.getKeys().any((key) => '${prefs.get(key)}'.contains(instruction)),
        isFalse,
      );
      expect(
        (await ovidSecureStorage().readAll()).values.any(
          (value) => value.contains(instruction),
        ),
        isTrue,
      );
      coldRestart();
      await start(SessionStartReason.restored);
      expect(
        HookService.I.sessionContextFor(session.id) == instruction,
        isTrue,
      );
    },
  );
}
