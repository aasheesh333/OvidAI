import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/plugin_manifest.dart';
import 'package:ovid_ai/core/plugin_permissions.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Regression coverage for the post-update cascade.
///
/// A single change to how manifests are NORMALIZED used to invalidate every
/// stored plugin grant, because the grant key was a sha256 over the whole
/// manifest JSON — including `unknownFields` (verbatim unrecognized source
/// fields, carried at every nesting level) and `compatibility` (advisory
/// findings from the current parser). Neither is enforcing, but both move
/// whenever an adapter changes. The miss then cascaded: plugin disabled with
/// `migrationRequired` → owned MCP servers failed with "Owning plugin is not
/// active" → hooks skipped → tool roster emptied. One representation change
/// silently switched off four subsystems, and the user was told to re-approve
/// plugins whose content had not changed at all.
///
/// The digest now hashes only the enforcing projection and is stamped with
/// [kManifestDigestSchemaVersion]; [PluginPermissionStore.migrateLegacyGrant]
/// re-keys a v1 grant for byte-identical content, and refuses whenever the
/// re-key could widen what was approved.
void main() {
  const id = 'acme/grant-kit';

  NormalizedPluginManifest build({
    String version = '1.0.0',
    List<PluginCommand> commands = const [
      PluginCommand(pluginId: id, name: 'review', path: 'commands/review.md'),
    ],
    List<PluginSkill> skills = const [],
    Map<String, dynamic> unknownFields = const {},
    List<CompatibilityIssue> compatibility = const [],
    Set<String> envNames = const {},
    Set<PluginCapability>? requested,
    String rootPath = '/tmp/$id',
  }) {
    final base = NormalizedPluginManifest(
      id: id,
      name: 'Grant Kit',
      version: version,
      format: PluginFormat.claudeCode,
      rootPath: rootPath,
      commands: commands,
      skills: skills,
      unknownFields: unknownFields,
      compatibility: compatibility,
      environmentReadNames: envNames,
      requestedCapabilities: requested ?? const {},
    );
    if (requested != null) return base;
    // Mirror the adapter path: capabilities are inferred when not declared.
    return NormalizedPluginManifest(
      id: base.id,
      name: base.name,
      version: base.version,
      format: base.format,
      rootPath: base.rootPath,
      commands: base.commands,
      skills: base.skills,
      agents: base.agents,
      hooks: base.hooks,
      mcpServers: base.mcpServers,
      dependencies: base.dependencies,
      requestedCapabilities: inferRequestedCapabilities(base),
      environmentReadNames: base.environmentReadNames,
      unknownFields: base.unknownFields,
      compatibility: base.compatibility,
    );
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
  });

  group('digest binds enforcing content only', () {
    test('top-level unknownFields churn does not change the digest', () {
      final a = build();
      final b = build(unknownFields: const {'publisherExtra': {'k': 'v'}});
      expect(a.unknownFields, isNot(b.unknownFields));
      expect(pluginManifestDigest(b), pluginManifestDigest(a));
    });

    test('NESTED unknownFields churn does not change the digest', () {
      // The volatile buckets live on every contribution, not just the root —
      // stripping only the top level would have left the drift engine intact.
      final a = build();
      final b = build(
        commands: const [
          PluginCommand(
            pluginId: id,
            name: 'review',
            path: 'commands/review.md',
            unknownFields: {'model': 'some-future-field'},
          ),
        ],
      );
      expect(pluginManifestDigest(b), pluginManifestDigest(a));
    });

    test('compatibility findings do not change the digest', () {
      final a = build();
      final b = build(
        compatibility: const [
          CompatibilityIssue(
            severity: CompatibilitySeverity.optional,
            message: 'advisory note added by a newer parser',
            fields: ['skills[0]'],
          ),
        ],
      );
      expect(pluginManifestDigest(b), pluginManifestDigest(a));
    });

    test('a real content change still changes the digest', () {
      final digest = pluginManifestDigest(build());
      expect(pluginManifestDigest(build(version: '1.0.1')), isNot(digest));
      expect(
        pluginManifestDigest(
          build(
            commands: const [
              PluginCommand(
                pluginId: id,
                name: 'review',
                path: 'commands/OTHER.md',
              ),
            ],
          ),
        ),
        isNot(digest),
      );
    });

    test('the digest stays location-independent', () {
      expect(
        pluginManifestDigest(build(rootPath: '/opt/ovid/elsewhere/$id')),
        pluginManifestDigest(build()),
      );
    });

    test('wire format is preserved: sha256: + 64 hex', () {
      final digest = pluginManifestDigest(build());
      expect(digest, startsWith('sha256:'));
      expect(digest.length, 'sha256:'.length + 64);
    });

    test('the digest is schema-versioned and differs from v1', () {
      final m = build();
      expect(kManifestDigestSchemaVersion, greaterThan(1));
      // v1 hashed the full JSON; v2 hashes the projection + version stamp, so
      // the two can never collide. That is exactly why the migration below is
      // required rather than optional.
      expect(pluginManifestDigest(m), isNot(legacyPluginManifestDigest(m)));
      expect(legacyPluginManifestDigest(m), startsWith('sha256:'));
    });
  });

  group('migrateLegacyGrant', () {
    test('re-keys a v1 grant so an unchanged plugin keeps working', () async {
      final m = build();
      final store = PluginPermissionStore();
      final approvedAt = DateTime.utc(2026, 1, 1);

      // The pre-fix stored record: keyed by the v1 digest.
      await store.save(
        PluginPermissionGrant(
          pluginId: id,
          manifestDigest: legacyPluginManifestDigest(m),
          capabilities: m.requestedCapabilities,
          environmentReadNames: m.environmentReadNames,
          approvedAt: approvedAt,
        ),
      );
      // Sanity: a plain digest-keyed load misses — this is the cascade.
      expect(
        await store.load(id, pluginManifestDigest(m)),
        isNull,
        reason: 'the v1 record must not satisfy a v2 digest lookup directly',
      );

      final migrated = await store.effectiveRuntimeGrant(
        pluginId: id,
        manifest: m,
      );
      expect(migrated, isNotNull);
      expect(migrated!.manifestDigest, pluginManifestDigest(m));
      // Persisted, not just returned: the next boot must not redo the work.
      expect(await store.load(id, pluginManifestDigest(m)), isNotNull);
      expect(migrated.approvedAt, approvedAt);
    });

    test('preserves the original approvedAt (a re-key is not a re-approval)', () async {
      final m = build();
      final store = PluginPermissionStore();
      final approvedAt = DateTime.utc(2025, 6, 15, 9, 30);
      await store.save(
        PluginPermissionGrant(
          pluginId: id,
          manifestDigest: legacyPluginManifestDigest(m),
          capabilities: m.requestedCapabilities,
          approvedAt: approvedAt,
        ),
      );

      final migrated = await store.migrateLegacyGrant(
        pluginId: id,
        manifest: m,
      );
      expect(migrated!.approvedAt, approvedAt);
    });

    test('refuses when the plugin content genuinely changed', () async {
      final store = PluginPermissionStore();
      final old = build(version: '1.0.0');
      await store.save(
        PluginPermissionGrant(
          pluginId: id,
          manifestDigest: legacyPluginManifestDigest(old),
          capabilities: old.requestedCapabilities,
          approvedAt: DateTime.utc(2026),
        ),
      );

      // A real update changes the v1 digest too, so the migration must NOT
      // carry the old approval forward — this is what keeps "changed manifest
      // → re-approval required" intact.
      final updated = build(version: '1.0.1');
      expect(
        await store.migrateLegacyGrant(pluginId: id, manifest: updated),
        isNull,
      );
      expect(
        await store.effectiveRuntimeGrant(pluginId: id, manifest: updated),
        isNull,
      );
    });

    test('refuses rather than widen when the stored approval is too narrow', () async {
      final m = build();
      final store = PluginPermissionStore();
      expect(m.requestedCapabilities, isNotEmpty);

      // Simulates an app update whose capability INFERENCE grew: same content
      // (so the v1 digest matches) but the stored approval no longer covers
      // everything now requested. Carrying it forward would silently grant
      // capabilities the user never approved.
      await store.save(
        PluginPermissionGrant(
          pluginId: id,
          manifestDigest: legacyPluginManifestDigest(m),
          capabilities: const {},
          approvedAt: DateTime.utc(2026),
        ),
      );

      expect(
        await store.migrateLegacyGrant(pluginId: id, manifest: m),
        isNull,
      );
      expect(
        await store.effectiveRuntimeGrant(pluginId: id, manifest: m),
        isNull,
      );
      // The over-narrow record is left as stored, never rewritten.
      final stored = await store.loadAny(id);
      expect(stored!.manifestDigest, legacyPluginManifestDigest(m));
    });

    test('refuses when an approved environment variable name is missing', () async {
      final m = build(envNames: const {'ACME_TOKEN'});
      final store = PluginPermissionStore();
      await store.save(
        PluginPermissionGrant(
          pluginId: id,
          manifestDigest: legacyPluginManifestDigest(m),
          capabilities: m.requestedCapabilities,
          // Approved before the manifest started reading ACME_TOKEN.
          environmentReadNames: const {},
          approvedAt: DateTime.utc(2026),
        ),
      );

      expect(
        await store.migrateLegacyGrant(pluginId: id, manifest: m),
        isNull,
      );
    });

    test('is a no-op when a current-digest grant already exists', () async {
      final m = build();
      final store = PluginPermissionStore();
      final current = PluginPermissionGrant(
        pluginId: id,
        manifestDigest: pluginManifestDigest(m),
        capabilities: m.requestedCapabilities,
        approvedAt: DateTime.utc(2026, 3, 3),
      );
      await store.save(current);

      final again = await store.migrateLegacyGrant(pluginId: id, manifest: m);
      expect(again!.manifestDigest, current.manifestDigest);
      expect(again.approvedAt, current.approvedAt);
    });

    test('returns null when nothing was ever approved', () async {
      final store = PluginPermissionStore();
      expect(await store.loadAny(id), isNull);
      expect(await store.migrateLegacyGrant(pluginId: id, manifest: build()), isNull);
    });

    test('never migrates across plugin ids', () async {
      final m = build();
      final store = PluginPermissionStore();
      await store.save(
        PluginPermissionGrant(
          pluginId: id,
          manifestDigest: legacyPluginManifestDigest(m),
          capabilities: m.requestedCapabilities,
          approvedAt: DateTime.utc(2026),
        ),
      );

      // Same content shape, different canonical id → a different plugin.
      final other = build(
        commands: const [
          PluginCommand(
            pluginId: 'other/kit',
            name: 'review',
            path: 'commands/review.md',
          ),
        ],
      );
      final rebuilt = NormalizedPluginManifest(
        id: 'other/kit',
        name: other.name,
        version: other.version,
        format: other.format,
        rootPath: other.rootPath,
        commands: other.commands,
        requestedCapabilities: other.requestedCapabilities,
      );
      expect(
        await store.migrateLegacyGrant(pluginId: 'other/kit', manifest: rebuilt),
        isNull,
      );
      expect(
        await store.effectiveRuntimeGrant(
          pluginId: 'other/kit',
          manifest: rebuilt,
        ),
        isNull,
      );
    });
  });
}
