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
    AppState.pluginCacheRootOverrideForTest = null;
    AppState.resetTestInstance();
    if (runtimeRoot.existsSync()) runtimeRoot.deleteSync(recursive: true);
    if (cacheRoot.existsSync()) cacheRoot.deleteSync(recursive: true);
    SharedPreferences.setMockInitialValues({});
  });

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

      for (final row in [hookRow, cacheRow, externalRow]) {
        expect(row.enabled, isFalse);
        expect(row.activation, PluginActivation.disabled);
        expect(row.migrationRequired, isTrue);
        expect(row.runtimeReason, contains('Re-approve'));
      }
      expect(
        statuses.where(
          (status) => status.state == StartupItemState.migrationRequired,
        ),
        hasLength(3),
      );
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
