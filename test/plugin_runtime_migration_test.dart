import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ovid_ai/core/agent_service.dart';
import 'package:ovid_ai/core/hook_service.dart';
import 'package:ovid_ai/core/plugin_manifest.dart';
import 'package:ovid_ai/core/plugin_permissions.dart';
import 'package:ovid_ai/core/plugin_registry.dart';
import 'package:ovid_ai/core/plugin_runtime.dart';
import 'package:ovid_ai/core/skills.dart';
import 'package:ovid_ai/core/startup_coordinator.dart';
import 'package:ovid_ai/core/state.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory runtimeRoot;
  late Directory cacheRoot;
  late AppState app;
  final registeredIds = <String>{};

  String contentPath(String id, [String version = '1.0.0']) =>
      '${runtimeRoot.path}/plugin-runtime/$id/$version/content';

  NormalizedPluginManifest manifest(
    String id, {
    String name = 'Shared Tools',
    String version = '1.0.0',
    Set<PluginCapability> capabilities = const {PluginCapability.workspaceRead},
    Set<String> environmentNames = const {},
  }) => NormalizedPluginManifest(
    id: id,
    name: name,
    version: version,
    format: PluginFormat.claudeCode,
    rootPath: contentPath(id, version),
    requestedCapabilities: capabilities,
    environmentReadNames: environmentNames,
  );

  PluginInstallEntry entryFor(
    NormalizedPluginManifest manifest, {
    PluginActivation activation = PluginActivation.globalActive,
    bool disabled = false,
  }) => PluginInstallEntry(
    activation: PluginActivationRecord(
      pluginId: manifest.id,
      state: activation,
      installedBootEpoch: 0,
    ),
    manifest: manifest,
    contentDir: manifest.rootPath,
    version: manifest.version,
    disabled: disabled,
  );

  Future<void> seedEntries(Map<String, PluginInstallEntry> entries) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      kPluginActivationPrefKey,
      jsonEncode({
        for (final item in entries.entries)
          item.key: jsonEncode(item.value.toJson()),
      }),
    );
  }

  Future<void> approve(
    NormalizedPluginManifest manifest, {
    String? storedPluginId,
    Set<PluginCapability>? capabilities,
    Set<String>? environmentNames,
  }) => PluginPermissionStore().save(
    PluginPermissionGrant(
      pluginId: storedPluginId ?? manifest.id,
      manifestDigest: pluginManifestDigest(manifest),
      capabilities: capabilities ?? manifest.requestedCapabilities,
      environmentReadNames: environmentNames ?? manifest.environmentReadNames,
      approvedAt: DateTime.utc(2026, 9, 10),
    ),
  );

  Map<String, dynamic> decodeRows(String raw) =>
      (jsonDecode(raw) as Map).cast<String, dynamic>();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    AppState.resetTestInstance();
    runtimeRoot = Directory.systemTemp.createTempSync('ovid-runtime-v2-');
    cacheRoot = Directory.systemTemp.createTempSync('ovid-legacy-cache-');
    PluginRuntimeManager.runtimeRootOverrideForTest = runtimeRoot;
    PluginRuntimeManager.failMigrationMarkerWriteForTest = false;
    PluginRuntimeManager.failCanonicalRowsWriteForTest = false;
    AppState.pluginCacheRootOverrideForTest = cacheRoot;
    app = AppState.createForTest();
    HookService.I.enabled = true;
    SkillService.I.clearRoots();
  });

  tearDown(() async {
    for (final id in registeredIds) {
      PluginContributionRegistry.I.unregisterPlugin(id);
    }
    registeredIds.clear();
    HookService.I.executorForTest = null;
    SkillService.I.clearRoots();
    PluginRuntimeManager.runtimeRootOverrideForTest = null;
    PluginRuntimeManager.failMigrationMarkerWriteForTest = false;
    PluginRuntimeManager.failCanonicalRowsWriteForTest = false;
    AppState.pluginCacheRootOverrideForTest = null;
    AppState.resetTestInstance();
    if (runtimeRoot.existsSync()) runtimeRoot.deleteSync(recursive: true);
    if (cacheRoot.existsSync()) cacheRoot.deleteSync(recursive: true);
    SharedPreferences.setMockInitialValues({});
  });

  test(
    'AgentService constructor does not mount plugin roots before safety reconciliation',
    () async {
      final row = PluginItem(
        name: 'Pre-reconcile cache',
        author: 'legacy',
        description: '',
        version: '1',
        category: 'Tool',
        installed: true,
        enabled: true,
        source: 'legacy/pre-reconcile',
      );
      app.plugins.add(row);
      final cache = await app.pluginCacheDirFor(row.source!);
      Directory('${cache.path}/skills/unsafe').createSync(recursive: true);
      File(
        '${cache.path}/skills/unsafe/SKILL.md',
      ).writeAsStringSync('---\nname: pre-reconcile-unsafe\n---\nUnsafe.');

      AgentService.I;
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(
        SkillService.I.skills.any(
          (skill) => skill.name == 'pre-reconcile-unsafe',
        ),
        isFalse,
      );
    },
  );

  test(
    'legacy hooks and skill caches cannot execute before safety reconciliation',
    () async {
      final row = PluginItem(
        name: 'Unreconciled Legacy',
        author: 'legacy',
        description: '',
        version: '1',
        category: 'Tool',
        installed: true,
        enabled: true,
        source: 'legacy/unreconciled',
        hooks: const {'on_turn_start': 'echo unsafe'},
      );
      app.plugins.add(row);
      final cache = await app.pluginCacheDirFor(row.source!);
      Directory('${cache.path}/skills/unsafe').createSync(recursive: true);
      File(
        '${cache.path}/skills/unsafe/SKILL.md',
      ).writeAsStringSync('---\nname: unreconciled-unsafe\n---\nUnsafe.');
      var hookCalls = 0;
      HookService.I.executorForTest = (_, _) async {
        hookCalls++;
        return '';
      };

      await HookService.I.fire('on_turn_start', 'migration-session');
      await AgentService.I.refreshSkills();

      expect(hookCalls, 0);
      expect(
        SkillService.I.skills.any(
          (skill) => skill.name == 'unreconciled-unsafe',
        ),
        isFalse,
      );
    },
  );

  test(
    'reconciliation reconstructs missing rows by canonical runtime id',
    () async {
      final runtime = manifest('acme/reviewer', name: 'Reviewer');
      Directory(runtime.rootPath).createSync(recursive: true);
      await seedEntries({runtime.id: entryFor(runtime)});
      await approve(runtime);

      final statuses = await PluginRuntimeManager.I.reconcileRowsAndGrants();

      final row = app.plugins.singleWhere(
        (item) => item.runtimeId == runtime.id,
      );
      expect(row.name, 'Reviewer');
      expect(row.installed, isTrue);
      expect(row.enabled, isTrue);
      expect(row.activation, PluginActivation.globalActive);
      expect(row.manifestDigest, pluginManifestDigest(runtime));
      expect(statuses.single.id, runtime.id);
      expect(statuses.single.state, StartupItemState.ready);
      final prefs = await SharedPreferences.getInstance();
      expect(decodeRows(prefs.getString(kPluginRowsV2PrefKey)!).keys, [
        runtime.id,
      ]);
    },
  );

  test(
    'same display name runtimes remain independent canonical rows',
    () async {
      final alpha = manifest('alpha/shared');
      final beta = manifest('beta/shared');
      Directory(alpha.rootPath).createSync(recursive: true);
      Directory(beta.rootPath).createSync(recursive: true);
      await seedEntries({beta.id: entryFor(beta), alpha.id: entryFor(alpha)});
      await approve(alpha);
      await approve(beta);

      await PluginRuntimeManager.I.reconcileRowsAndGrants();

      final rows = app.plugins
          .where((row) => row.name == 'Shared Tools')
          .toList();
      expect(rows.map((row) => row.runtimeId).toSet(), {
        'alpha/shared',
        'beta/shared',
      });
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(kPluginRowsV2PrefKey)!;
      expect(decodeRows(raw).keys.toList(), ['alpha/shared', 'beta/shared']);
    },
  );

  test(
    'runtime grant requires matching inner id and complete approval',
    () async {
      final runtime = manifest(
        'acme/strict',
        capabilities: const {
          PluginCapability.workspaceRead,
          PluginCapability.environmentRead,
        },
        environmentNames: const {'API_TOKEN'},
      );
      final store = PluginPermissionStore();

      await approve(runtime, storedPluginId: 'other/plugin');
      expect(
        await store.effectiveRuntimeGrant(
          pluginId: runtime.id,
          manifest: runtime,
        ),
        isNull,
      );

      SharedPreferences.setMockInitialValues({});
      await approve(
        runtime,
        capabilities: const {PluginCapability.workspaceRead},
        environmentNames: const {},
      );
      expect(
        await store.effectiveRuntimeGrant(
          pluginId: runtime.id,
          manifest: runtime,
        ),
        isNull,
      );

      SharedPreferences.setMockInitialValues({});
      await approve(runtime);
      expect(
        await store.effectiveRuntimeGrant(
          pluginId: runtime.id,
          manifest: runtime,
        ),
        isNotNull,
      );
    },
  );

  test('missing grant disables row and unregisters contributions', () async {
    final runtime = manifest('acme/unapproved');
    Directory(runtime.rootPath).createSync(recursive: true);
    await seedEntries({runtime.id: entryFor(runtime)});
    PluginContributionRegistry.I.register(
      runtime,
      activation: PluginActivation.globalActive,
    );
    registeredIds.add(runtime.id);

    final statuses = await PluginRuntimeManager.I.reconcileRowsAndGrants();

    expect(statuses.single.state, StartupItemState.migrationRequired);
    expect(PluginContributionRegistry.I.isRegistered(runtime.id), isFalse);
    final row = app.plugins.singleWhere((item) => item.runtimeId == runtime.id);
    expect(row.enabled, isFalse);
    expect(row.activation, PluginActivation.disabled);
    expect(row.migrationRequired, isTrue);
    expect(row.runtimeReason, contains('Re-approve'));
    expect(
      (await PluginRuntimeManager.I.recordFor(runtime.id))!.state,
      PluginActivation.disabled,
    );
  });

  test(
    'boot retry and enable never bypass a missing effective grant',
    () async {
      for (final operation in ['boot', 'retry', 'enable']) {
        SharedPreferences.setMockInitialValues({});
        final runtime = manifest('acme/$operation');
        Directory(runtime.rootPath).createSync(recursive: true);
        await seedEntries({runtime.id: entryFor(runtime)});
        registeredIds.add(runtime.id);

        switch (operation) {
          case 'boot':
            await PluginRuntimeManager.I.activateForBoot(connectMcp: false);
          case 'retry':
            await PluginRuntimeManager.I.retry(runtime.id);
          case 'enable':
            await PluginRuntimeManager.I.enable(runtime.id);
        }

        expect(
          PluginContributionRegistry.I.isRegistered(runtime.id),
          isFalse,
          reason: operation,
        );
        final stored = await PluginRuntimeManager.I.recordFor(runtime.id);
        expect(stored!.state, PluginActivation.disabled, reason: operation);
      }
    },
  );

  test(
    'missing committed content is failed without requiring migration',
    () async {
      final runtime = manifest('acme/missing-content');
      await seedEntries({runtime.id: entryFor(runtime)});
      await approve(runtime);

      final statuses = await PluginRuntimeManager.I.reconcileRowsAndGrants();

      expect(statuses.single.state, StartupItemState.failed);
      final row = app.plugins.singleWhere(
        (item) => item.runtimeId == runtime.id,
      );
      expect(row.activation, PluginActivation.failed);
      expect(row.enabled, isFalse);
      expect(row.migrationRequired, isFalse);
      expect(row.runtimeReason, 'Installed content is missing');
    },
  );

  test('persisted failed activation remains failed and disabled', () async {
    final runtime = manifest('acme/failed-state');
    Directory(runtime.rootPath).createSync(recursive: true);
    await seedEntries({
      runtime.id: entryFor(runtime, activation: PluginActivation.failed),
    });
    await approve(runtime);

    final statuses = await PluginRuntimeManager.I.reconcileRowsAndGrants();

    expect(statuses.single.state, StartupItemState.failed);
    final row = app.plugins.singleWhere((item) => item.runtimeId == runtime.id);
    expect(row.enabled, isFalse);
    expect(row.activation, PluginActivation.failed);
  });

  test(
    'executable legacy rows require migration while native rows stay enabled',
    () async {
      final native = app.plugins.singleWhere((row) => row.name == 'Web Search');
      final hookRow = PluginItem(
        name: 'Old Hooks',
        author: 'legacy',
        description: '',
        version: '1',
        category: 'Tool',
        installed: true,
        enabled: true,
        hooks: const {'on_turn_start': 'echo old'},
      );
      final cacheRow = PluginItem(
        name: 'Old Cache',
        author: 'legacy',
        description: '',
        version: '1',
        category: 'External',
        installed: true,
        enabled: true,
        source: 'legacy/cache',
      );
      final externalRow = PluginItem(
        name: 'Old External',
        author: 'legacy',
        description: '',
        version: '1',
        category: 'External',
        installed: true,
        enabled: true,
      );
      app.plugins.addAll([hookRow, cacheRow, externalRow]);

      final statuses = await PluginRuntimeManager.I.reconcileRowsAndGrants();

      for (final row in [hookRow, cacheRow]) {
        expect(row.enabled, isFalse);
        expect(row.activation, PluginActivation.disabled);
        expect(row.migrationRequired, isTrue);
        expect(row.runtimeReason, contains('Re-approve'));
      }
      expect(
        statuses.where(
          (status) => status.state == StartupItemState.migrationRequired,
        ),
        hasLength(2),
      );
      expect(externalRow.enabled, isTrue);
      expect(externalRow.migrationRequired, isFalse);
      expect(native.installed, isTrue);
      expect(native.enabled, isTrue);
      expect(native.migrationRequired, isFalse);
    },
  );

  test(
    'identity-corrupt entry is disabled without blocking valid siblings',
    () async {
      final valid = manifest('acme/valid');
      final corruptManifest = manifest('other/identity');
      Directory(valid.rootPath).createSync(recursive: true);
      Directory(corruptManifest.rootPath).createSync(recursive: true);
      await seedEntries({
        valid.id: entryFor(valid),
        'acme/corrupt': entryFor(corruptManifest),
      });
      await approve(valid);

      final statuses = await PluginRuntimeManager.I.reconcileRowsAndGrants();

      expect(app.plugins.any((row) => row.runtimeId == valid.id), isTrue);
      expect(
        app.plugins.any((row) => row.runtimeId == 'acme/corrupt'),
        isFalse,
      );
      expect(statuses.any((status) => status.id == valid.id), isTrue);
      final prefs = await SharedPreferences.getInstance();
      final activation =
          jsonDecode(
                decodeRows(
                      prefs.getString(kPluginActivationPrefKey)!,
                    )['acme/corrupt']
                    as String,
              )
              as Map<String, dynamic>;
      expect(activation['disabled'], isTrue);
      expect(
        (activation['activation'] as Map<String, dynamic>)['state'],
        PluginActivation.disabled.name,
      );
    },
  );

  test(
    'migration-required legacy hooks and skill caches cannot execute',
    () async {
      final hookRow = PluginItem(
        name: 'Unsafe Legacy',
        author: 'legacy',
        description: '',
        version: '1',
        category: 'External',
        installed: true,
        enabled: true,
        source: 'legacy/unsafe',
        hooks: const {'on_turn_start': 'echo unsafe'},
        migrationRequired: true,
      );
      app.plugins.add(hookRow);
      var hookCalls = 0;
      HookService.I.executorForTest = (_, _) async {
        hookCalls++;
        return '';
      };
      final cache = await app.pluginCacheDirFor(hookRow.source!);
      Directory('${cache.path}/skills/unsafe').createSync(recursive: true);
      File('${cache.path}/skills/unsafe/SKILL.md').writeAsStringSync(
        '---\nname: unsafe-legacy\nuser-invocable: true\n---\nDo unsafe work.',
      );

      await HookService.I.fire('on_turn_start', 'migration-session');
      await AgentService.I.refreshSkills();

      expect(hookCalls, 0);
      expect(HookService.I.hasLegacyMapHookListeners('on_turn_start'), isFalse);
      expect(
        SkillService.I.skills.any((skill) => skill.name == 'unsafe-legacy'),
        isFalse,
      );
    },
  );

  test(
    'persisted enabled legacy row is reconciled before hooks and skills run',
    () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList('ovid_custom_plugins_v1', [
        jsonEncode({
          'name': 'Persisted Unsafe',
          'description': '',
          'category': 'Tool',
          'installed': true,
          'enabled': true,
          'hooks': {'on_turn_start': 'echo unsafe'},
        }),
      ]);
      await prefs.setString(
        'ovid_plugin_state_v1',
        jsonEncode({
          'Persisted Unsafe': jsonEncode({
            'installed': true,
            'enabled': true,
            'source': 'legacy/persisted',
            'hooks': {'on_turn_start': 'echo unsafe'},
          }),
        }),
      );
      AppState.resetTestInstance();
      app = AppState.createForTest();
      final tasks = await app.buildReadinessTasks();
      await tasks.singleWhere((task) => task.id == 'local.hydrate').run();
      final safety = await tasks
          .singleWhere((task) => task.id == 'localSafety.migrate')
          .run();
      final row = app.plugins.singleWhere(
        (item) => item.name == 'Persisted Unsafe',
      );
      final cache = await app.pluginCacheDirFor(row.source!);
      Directory('${cache.path}/skills/unsafe').createSync(recursive: true);
      File(
        '${cache.path}/skills/unsafe/SKILL.md',
      ).writeAsStringSync('---\nname: persisted-unsafe\n---\nUnsafe.');
      var hookCalls = 0;
      HookService.I.executorForTest = (_, _) async {
        hookCalls++;
        return '';
      };

      await HookService.I.fire('on_turn_start', 'migration-session');
      await AgentService.I.refreshSkills();

      expect(safety.state, StartupItemState.migrationRequired);
      expect(app.pluginSafetyStatuses.single.label, 'Persisted Unsafe');
      expect(row.enabled, isFalse);
      expect(row.migrationRequired, isTrue);
      expect(hookCalls, 0);
      expect(
        SkillService.I.skills.any((skill) => skill.name == 'persisted-unsafe'),
        isFalse,
      );
      final custom =
          jsonDecode(prefs.getStringList('ovid_custom_plugins_v1')!.single)
              as Map<String, dynamic>;
      expect(custom['enabled'], isFalse);
      expect(custom['migrationRequired'], isTrue);
    },
  );

  test(
    'corrupt and orphan normalized rows are removed from the live projection',
    () async {
      final valid = manifest('acme/valid-orphan-test');
      Directory(valid.rootPath).createSync(recursive: true);
      await seedEntries({valid.id: entryFor(valid)});
      await approve(valid);
      final orphan = PluginItem(
        name: 'Orphan',
        author: 'old',
        description: '',
        version: '1',
        category: 'Tool',
        installed: true,
        enabled: true,
        runtimeId: 'orphan/runtime',
        activation: PluginActivation.globalActive,
      );
      app.plugins.add(orphan);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        kPluginRowsV2PrefKey,
        jsonEncode({
          'orphan/runtime': jsonEncode(orphan.toJson()),
          'mismatch/runtime': jsonEncode({
            ...orphan.toJson(),
            'runtimeId': 'other/runtime',
          }),
          'malformed': jsonEncode({
            ...orphan.toJson(),
            'runtimeId': 'malformed',
          }),
        }),
      );
      PluginContributionRegistry.I.register(
        manifest('orphan/runtime'),
        activation: PluginActivation.globalActive,
      );
      registeredIds.add('orphan/runtime');

      await PluginRuntimeManager.I.reconcileRowsAndGrants();

      expect(
        app.plugins
            .where((row) => row.runtimeId != null)
            .map((row) => row.runtimeId),
        [valid.id],
      );
      expect(
        PluginContributionRegistry.I.isRegistered('orphan/runtime'),
        isFalse,
      );
      expect(decodeRows(prefs.getString(kPluginRowsV2PrefKey)!).keys, [
        valid.id,
      ]);
    },
  );

  test(
    'corrupt activation rows unregister stale runtime contributions',
    () async {
      final runtime = manifest('acme/corrupt-activation');
      PluginContributionRegistry.I.register(
        runtime,
        activation: PluginActivation.globalActive,
      );
      registeredIds.add(runtime.id);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        kPluginActivationPrefKey,
        jsonEncode({runtime.id: '{not-json'}),
      );

      await PluginRuntimeManager.I.reconcileRowsAndGrants();

      expect(PluginContributionRegistry.I.isRegistered(runtime.id), isFalse);
    },
  );

  test(
    'malformed canonical activation ids fail closed without blocking siblings',
    () async {
      final valid = manifest('acme/valid-id');
      Directory(valid.rootPath).createSync(recursive: true);
      await approve(valid);
      final malformed = manifest('Acme/Bad');
      await seedEntries({
        valid.id: entryFor(valid),
        malformed.id: entryFor(malformed),
      });

      final statuses = await PluginRuntimeManager.I.reconcileRowsAndGrants();

      expect(
        statuses.singleWhere((status) => status.id == malformed.id).state,
        StartupItemState.failed,
      );
      expect(app.plugins.any((row) => row.runtimeId == malformed.id), isFalse);
      expect(app.plugins.any((row) => row.runtimeId == valid.id), isTrue);
    },
  );

  test(
    'disabled migration rows report deterministically after restart',
    () async {
      final runtime = manifest('acme/restart-migration');
      Directory(runtime.rootPath).createSync(recursive: true);
      await seedEntries({runtime.id: entryFor(runtime)});

      final first = await PluginRuntimeManager.I.reconcileRowsAndGrants();
      AppState.resetTestInstance();
      app = AppState.createForTest();
      final second = await PluginRuntimeManager.I.reconcileRowsAndGrants();

      expect(first.single.state, StartupItemState.migrationRequired);
      expect(second.single.state, StartupItemState.migrationRequired);
      expect(second.single.reason, first.single.reason);
      expect(
        app.plugins
            .singleWhere((row) => row.runtimeId == runtime.id)
            .migrationRequired,
        isTrue,
      );
    },
  );

  test(
    'migration marker write failure is reported after durable stores',
    () async {
      final runtime = manifest('acme/marker-failure');
      Directory(runtime.rootPath).createSync(recursive: true);
      await seedEntries({runtime.id: entryFor(runtime)});
      await approve(runtime);
      PluginRuntimeManager.failMigrationMarkerWriteForTest = true;

      await expectLater(
        PluginRuntimeManager.I.reconcileRowsAndGrants(),
        throwsA(isA<StateError>()),
      );

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(kPluginRowsV2PrefKey), isNotNull);
      expect(prefs.getBool('ovid_plugin_rows_v2_migrated'), isNot(true));
    },
  );

  test('canonical row write failure prevents migration completion', () async {
    final runtime = manifest('acme/row-write-failure');
    Directory(runtime.rootPath).createSync(recursive: true);
    await seedEntries({runtime.id: entryFor(runtime)});
    await approve(runtime);
    PluginRuntimeManager.failCanonicalRowsWriteForTest = true;

    await expectLater(
      PluginRuntimeManager.I.reconcileRowsAndGrants(),
      throwsA(isA<StateError>()),
    );

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('ovid_plugin_rows_v2_migrated'), isNot(true));
  });

  test('completed migration does not rewrite its marker', () async {
    final runtime = manifest('acme/marker-idempotent');
    Directory(runtime.rootPath).createSync(recursive: true);
    await seedEntries({runtime.id: entryFor(runtime)});
    await approve(runtime);

    await PluginRuntimeManager.I.reconcileRowsAndGrants();
    PluginRuntimeManager.failMigrationMarkerWriteForTest = true;

    await PluginRuntimeManager.I.reconcileRowsAndGrants();
  });

  test('v1 stores persist only runtimeId-null rows', () async {
    final legacy = PluginItem(
      name: 'Legacy Custom',
      author: 'you',
      description: 'legacy metadata',
      version: '1',
      category: 'Tool',
      installed: true,
      enabled: false,
      source: 'legacy/custom',
      migrationRequired: true,
      runtimeReason: 'Re-approve this legacy plugin before it can run',
    );
    final runtime = PluginItem(
      name: 'Runtime Custom',
      author: 'you',
      description: 'canonical metadata',
      version: '1',
      category: 'Tool',
      installed: true,
      enabled: true,
      source: 'runtime/custom',
      runtimeId: 'acme/runtime-custom',
      activation: PluginActivation.globalActive,
    );
    app.plugins.addAll([legacy, runtime]);

    await app.persistLegacyPluginMigrationState();

    final prefs = await SharedPreferences.getInstance();
    final state = decodeRows(prefs.getString('ovid_plugin_state_v1')!);
    expect(state, contains(legacy.name));
    expect(state, isNot(contains(runtime.name)));
    final customs = prefs
        .getStringList('ovid_custom_plugins_v1')!
        .map((raw) => jsonDecode(raw) as Map<String, dynamic>)
        .toList();
    expect(customs.map((row) => row['name']), contains(legacy.name));
    expect(customs.map((row) => row['name']), isNot(contains(runtime.name)));
    final marketplace =
        jsonDecode(prefs.getString('ovid_marketplace_merged_v1')!) as List;
    expect(
      marketplace.whereType<Map>().map((row) => row['name']),
      contains(legacy.name),
    );
    expect(
      marketplace.whereType<Map>().map((row) => row['name']),
      isNot(contains(runtime.name)),
    );
  });

  test('v1 display-name state never mutates a normalized sibling', () async {
    final runtime = manifest('acme/collision', name: 'Collision');
    Directory(runtime.rootPath).createSync(recursive: true);
    await seedEntries({runtime.id: entryFor(runtime)});
    await approve(runtime);
    app.plugins.add(
      PluginItem(
        name: 'Collision',
        author: 'legacy',
        description: '',
        version: '1',
        category: 'Tool',
        runtimeId: runtime.id,
      ),
    );
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      'ovid_plugin_state_v1',
      jsonEncode({
        'Collision': jsonEncode({'installed': false, 'enabled': false}),
      }),
    );
    final hydrate = (await app.buildReadinessTasks()).singleWhere(
      (task) => task.id == 'local.hydrate',
    );

    await hydrate.run();
    await PluginRuntimeManager.I.reconcileRowsAndGrants();

    final row = app.plugins.singleWhere((item) => item.runtimeId == runtime.id);
    expect(row.installed, isTrue);
    expect(row.enabled, isTrue);
  });

  test('runtime metadata merges field-by-field by canonical id', () async {
    final runtime = manifest('acme/metadata', name: 'Manifest Name');
    Directory(runtime.rootPath).createSync(recursive: true);
    await seedEntries({runtime.id: entryFor(runtime)});
    await approve(runtime);
    final stored = PluginItem(
      name: 'Stored Name',
      author: '',
      description: '',
      version: 'old',
      category: 'Stored Category',
      installs: 7,
      installsKnown: true,
      runtimeId: runtime.id,
    );
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      kPluginRowsV2PrefKey,
      jsonEncode({runtime.id: jsonEncode(stored.toJson())}),
    );
    app.plugins.add(
      PluginItem(
        name: 'Catalog Name',
        author: 'Catalog Author',
        description: 'Catalog Description',
        version: 'catalog',
        category: 'Catalog Category',
        source: 'catalog/source',
        marketplace: 'catalog/marketplace',
        runtimeId: runtime.id,
      ),
    );

    await PluginRuntimeManager.I.reconcileRowsAndGrants();

    final row = app.plugins.singleWhere((item) => item.runtimeId == runtime.id);
    expect(row.name, 'Stored Name');
    expect(row.author, 'Catalog Author');
    expect(row.description, 'Catalog Description');
    expect(row.category, 'Stored Category');
    expect(row.source, 'catalog/source');
    expect(row.marketplace, 'catalog/marketplace');
    expect(row.installs, 7);
    expect(row.version, runtime.version);
    expect(row.activation, PluginActivation.globalActive);
  });

  test('marketplace name merge never mutates a runtime row', () {
    final runtime = PluginItem(
      name: 'Shared Listing',
      author: 'runtime',
      description: 'runtime description',
      version: '1',
      category: 'Tool',
      installed: true,
      enabled: true,
      runtimeId: 'acme/shared-listing',
    );
    app.plugins.add(runtime);

    app.mergeMarketplaceCatalogForTest(
      {
        'plugins': [
          {
            'name': 'Shared Listing',
            'description': 'marketplace description',
            'source': 'other/listing',
          },
        ],
      },
      'market',
      'catalog',
    );

    expect(runtime.description, 'runtime description');
    expect(runtime.source, isNull);
    expect(
      app.plugins.where(
        (row) => row.name == 'Shared Listing' && row.runtimeId == null,
      ),
      hasLength(1),
    );
  });

  test(
    'local hydration reconstructs canonical rows before marketplace merge',
    () async {
      final runtime = manifest('acme/hydrated', name: 'Hydrated Runtime');
      Directory(runtime.rootPath).createSync(recursive: true);
      await seedEntries({runtime.id: entryFor(runtime)});
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        'ovid_marketplace_merged_v1',
        jsonEncode([
          PluginItem(
            name: 'Hydrated Runtime',
            author: 'catalog',
            description: 'catalog description',
            version: 'old',
            category: 'Catalog',
            source: 'catalog/hydrated',
            marketplace: 'catalog/source',
            runtimeId: runtime.id,
          ).toJson(),
          PluginItem(
            name: 'Orphan Runtime',
            author: 'catalog',
            description: '',
            version: '1',
            category: 'Catalog',
            source: 'catalog/orphan',
            runtimeId: 'orphan/runtime',
          ).toJson(),
        ]),
      );

      final hydrate = (await app.buildReadinessTasks()).singleWhere(
        (task) => task.id == 'local.hydrate',
      );
      await hydrate.run();

      final row = app.plugins.singleWhere(
        (item) => item.runtimeId == runtime.id,
      );
      expect(row.description, 'catalog description');
      expect(row.source, 'catalog/hydrated');
      expect(row.version, runtime.version);
      expect(
        app.plugins.any((item) => item.runtimeId == 'orphan/runtime'),
        isFalse,
      );
    },
  );

  test('canonical plugin ids require exactly two normalized segments', () {
    expect(isCanonicalPluginId('acme/reviewer'), isTrue);
    expect(isCanonicalPluginId('acme/review-tools'), isTrue);
    for (final invalid in [
      '',
      'reviewer',
      'acme/reviewer/extra',
      'Acme/reviewer',
      'acme/reviewer_tools',
      'acme/reviewer.tools',
      'acme/-reviewer',
    ]) {
      expect(isCanonicalPluginId(invalid), isFalse, reason: invalid);
    }
  });

  test('startup safety reconciliation precedes plugin activation', () async {
    final ids = (await app.buildReadinessTasks())
        .map((task) => task.id)
        .toList();

    expect(
      ids.indexOf('localSafety.migrate'),
      lessThan(ids.indexOf('plugin.activate')),
    );
  });

  test(
    'active runtimes are sorted and include only valid active grants',
    () async {
      final validB = manifest('beta/valid');
      final validA = manifest('alpha/valid');
      final pending = manifest('gamma/pending');
      final missingGrant = manifest('delta/no-grant');
      for (final runtime in [validA, validB, pending, missingGrant]) {
        Directory(runtime.rootPath).createSync(recursive: true);
      }
      await seedEntries({
        validB.id: entryFor(validB),
        pending.id: entryFor(
          pending,
          activation: PluginActivation.pendingGlobal,
        ),
        missingGrant.id: entryFor(missingGrant),
        validA.id: entryFor(validA),
      });
      await approve(validA);
      await approve(validB);
      await approve(pending);

      final runtimes = await PluginRuntimeManager.I.activeRuntimes();

      expect(runtimes.map((runtime) => runtime.pluginId), [
        'alpha/valid',
        'beta/valid',
      ]);
      expect(runtimes.first.contentDir, validA.rootPath);
      expect(runtimes.first.manifest.id, 'alpha/valid');
    },
  );

  test(
    'reconciliation is byte-idempotent and persists no secret values',
    () async {
      const secret = 'sk-TASK3-SECRET-CANARY-9012';
      final runtime = manifest(
        'acme/idempotent',
        capabilities: const {
          PluginCapability.workspaceRead,
          PluginCapability.environmentRead,
        },
        environmentNames: const {'API_TOKEN'},
      );
      Directory(runtime.rootPath).createSync(recursive: true);
      await seedEntries({runtime.id: entryFor(runtime)});
      await approve(runtime);
      await const FlutterSecureStorage().write(
        key: 'ovid_plugin_secret_${runtime.id}/env/API_TOKEN',
        value: secret,
      );

      await PluginRuntimeManager.I.reconcileRowsAndGrants();
      final prefs = await SharedPreferences.getInstance();
      final first = {for (final key in prefs.getKeys()) key: prefs.get(key)};
      await PluginRuntimeManager.I.reconcileRowsAndGrants();
      final second = {for (final key in prefs.getKeys()) key: prefs.get(key)};

      expect(second, first);
      for (final entry in second.entries) {
        expect(
          jsonEncode(entry.value),
          isNot(contains(secret)),
          reason: entry.key,
        );
      }
      expect(
        await const FlutterSecureStorage().read(
          key: 'ovid_plugin_secret_${runtime.id}/env/API_TOKEN',
        ),
        secret,
      );
    },
  );

  test('PluginItem migration fields are optional and backward readable', () {
    final old = PluginItem.fromJson(const {
      'name': 'Old',
      'author': 'legacy',
      'description': '',
      'version': '1',
      'category': 'Tool',
      'installed': true,
      'enabled': true,
    });
    expect(old.migrationRequired, isFalse);
    expect(old.runtimeReason, isNull);
    expect(old.toJson(), isNot(contains('migrationRequired')));
    expect(old.toJson(), isNot(contains('runtimeReason')));

    final migrated = PluginItem.fromJson({
      ...old.toJson(),
      'migrationRequired': true,
      'runtimeReason': 'Re-approve this legacy plugin before it can run',
    });
    expect(migrated.migrationRequired, isTrue);
    expect(migrated.runtimeReason, contains('Re-approve'));
    expect(migrated.toJson()['migrationRequired'], isTrue);
  });
}
