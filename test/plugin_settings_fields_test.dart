import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ovid_ai/core/plugin_adapters.dart';
import 'package:ovid_ai/core/plugin_manifest.dart';
import 'package:ovid_ai/core/plugin_permissions.dart';
import 'package:ovid_ai/core/plugin_registry.dart';

/// Declarative plugin settings fields (audit 2026-09-25): the plugin system
/// had NO way for a plugin to contribute UI — five non-visual contribution
/// kinds and a `NativePluginConfigField` model nothing ever rendered. These
/// tests pin the data-only settings-field contribution:
///
///  * Claude `plugin.json` declares fields under `configFields`, `settings`,
///    or `settingsFields` (a list of `{key, label, secret, hint}` objects);
///  * the normalized manifest carries them with a canonicalId-consistent
///    identity (`plugin:<id>/setting:<key>`);
///  * unknown source fields are preserved verbatim, but an inline VALUE for
///    a secret field is dropped (spec §5.1: declarations carry names/labels,
///    never values — values live in secure storage only);
///  * the §5.1 grant digest stays byte-stable for manifests WITHOUT fields
///    (no migrationRequired cascade) while declaring fields is a content
///    change that re-enters the approval path;
///  * the registry exposes fields under the SAME §7 session-visibility rules
///    as [PluginContributionRegistry.toolsForSession], staying metadata-only.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
  });

  const pluginId = 'acme/settings-kit';

  Directory tree() {
    final r = Directory.systemTemp.createTempSync('ovid-settings-');
    addTearDown(() {
      if (r.existsSync()) r.deleteSync(recursive: true);
    });
    Directory('${r.path}/.claude-plugin').createSync(recursive: true);
    return r;
  }

  void manifest(Directory r, Map<String, dynamic> j) {
    File('${r.path}/.claude-plugin/plugin.json').writeAsStringSync(
      jsonEncode({
        'name': 'settings-kit',
        'version': '1.0.0',
        'author': {'name': 'Acme'},
        ...j,
      }),
    );
  }

  NormalizedPluginManifest normalized({
    List<PluginSettingsField> fields = const [],
    String id = pluginId,
  }) => NormalizedPluginManifest(
    id: id,
    name: 'Settings Kit',
    version: '1.0.0',
    format: PluginFormat.claudeCode,
    rootPath: '/tmp/$id',
    commands: [
      PluginCommand(pluginId: id, name: 'review', path: 'commands/review.md'),
    ],
    settingsFields: fields,
  );

  const secretField = PluginSettingsField(
    pluginId: pluginId,
    key: 'api_token',
    label: 'API Token',
    secret: true,
    hint: 'From the dashboard',
  );

  group('Claude adapter parses declarative settings fields', () {
    test('"configFields" list becomes normalized settingsFields', () async {
      final r = tree();
      manifest(r, {
        'configFields': [
          {
            'key': 'api_token',
            'label': 'API Token',
            'secret': true,
            'hint': 'From the dashboard',
          },
          {'key': 'endpoint', 'label': 'Endpoint'},
        ],
      });

      final m = await const ClaudePluginAdapter().inspect(r);

      expect(m.settingsFields.length, 2);
      final f = m.settingsFields.first;
      expect(f.pluginId, pluginId);
      expect(f.key, 'api_token');
      expect(f.label, 'API Token');
      expect(f.secret, isTrue);
      expect(f.hint, 'From the dashboard');
      expect(f.canonicalId, 'plugin:$pluginId/setting:api_token');
      expect(m.settingsFields[1].key, 'endpoint');
      expect(m.settingsFields[1].secret, isFalse);
      // The declaration is consumed by the normalized model — it must not
      // ALSO sit in unknownFields.
      expect(m.unknownFields.containsKey('configFields'), isFalse);
    });

    test('"settings" and "settingsFields" spellings parse too', () async {
      final r = tree();
      manifest(r, {
        'settings': [
          {'key': 'workspace', 'label': 'Workspace'},
        ],
        'settingsFields': [
          {'key': 'api_token', 'label': 'API Token', 'secret': true},
        ],
      });

      final m = await const ClaudePluginAdapter().inspect(r);

      expect(m.settingsFields.map((f) => f.key), [
        'workspace',
        'api_token',
      ]);
      expect(m.settingsFields.last.secret, isTrue);
      expect(m.unknownFields.containsKey('settings'), isFalse);
      expect(m.unknownFields.containsKey('settingsFields'), isFalse);
    });

    test('duplicate keys across spellings: first declaration wins', () async {
      final r = tree();
      manifest(r, {
        'configFields': [
          {'key': 'tok', 'label': 'First'},
        ],
        'settings': [
          {'key': 'tok', 'label': 'Second'},
        ],
      });

      final m = await const ClaudePluginAdapter().inspect(r);

      expect(m.settingsFields.length, 1);
      expect(m.settingsFields.single.label, 'First');
      expect(
        m.compatibility.any(
          (c) =>
              c.severity == CompatibilitySeverity.optional &&
              c.message.toLowerCase().contains('duplicate'),
        ),
        isTrue,
        reason: 'a shadowed declaration is reported, never silent',
      );
    });

    test('field-level unknown keys are preserved verbatim', () async {
      final r = tree();
      manifest(r, {
        'configFields': [
          {'key': 'limit', 'label': 'Limit', 'type': 'number', 'max': 10},
        ],
      });

      final m = await const ClaudePluginAdapter().inspect(r);

      expect(m.settingsFields.single.unknownFields, {
        'type': 'number',
        'max': 10,
      });
    });

    test('an inline VALUE for a secret field is dropped, with a finding', () async {
      final r = tree();
      manifest(r, {
        'configFields': [
          {'key': 'tok', 'label': 'Tok', 'secret': true, 'default': 'sk-123'},
        ],
      });

      final m = await const ClaudePluginAdapter().inspect(r);

      expect(m.settingsFields.single.key, 'tok');
      expect(m.settingsFields.single.unknownFields.containsKey('default'), isFalse);
      // Spec §5.1: a secret value can never round-trip into persisted
      // plugin metadata through the manifest JSON.
      expect(jsonEncode(m.toJson()), isNot(contains('sk-123')));
      expect(
        m.compatibility.any(
          (c) =>
              c.severity == CompatibilitySeverity.optional &&
              c.fields.contains('configFields[0]'),
        ),
        isTrue,
        reason: 'the drop is a visible finding, not silent',
      );
    });

    test('a non-secret inline default is preserved verbatim', () async {
      final r = tree();
      manifest(r, {
        'configFields': [
          {'key': 'endpoint', 'label': 'Endpoint', 'default': 'https://x'},
        ],
      });

      final m = await const ClaudePluginAdapter().inspect(r);

      expect(m.settingsFields.single.unknownFields['default'], 'https://x');
      expect(m.compatibility, isEmpty);
    });

    test('a non-list declaration is preserved in unknownFields', () async {
      final r = tree();
      manifest(r, {
        'settings': {'token': 'shape-from-a-newer-format'},
      });

      final m = await const ClaudePluginAdapter().inspect(r);

      expect(m.settingsFields, isEmpty);
      expect(m.unknownFields['settings'], {'token': 'shape-from-a-newer-format'});
      expect(
        m.compatibility.any(
          (c) =>
              c.severity == CompatibilitySeverity.optional &&
              c.fields.contains('settings'),
        ),
        isTrue,
      );
    });

    test('malformed entries are skipped with optional findings', () async {
      final r = tree();
      manifest(r, {
        'configFields': [
          'junk',
          {'label': 'no key'},
          {'key': 'ok', 'label': 'Ok'},
        ],
      });

      final m = await const ClaudePluginAdapter().inspect(r);

      expect(m.settingsFields.map((f) => f.key), ['ok']);
      expect(
        m.compatibility
            .where((c) => c.severity == CompatibilitySeverity.optional)
            .length,
        greaterThanOrEqualTo(2),
      );
    });

    test('no declaration yields no fields and no digest-relevant JSON key', () async {
      final r = tree();
      manifest(r, {});

      final m = await const ClaudePluginAdapter().inspect(r);

      expect(m.settingsFields, isEmpty);
      expect(m.toJson().containsKey('settingsFields'), isFalse);
    });
  });

  group('PluginSettingsField model', () {
    test('canonicalId extends the §4.4 scheme', () {
      expect(secretField.canonicalId, 'plugin:$pluginId/setting:api_token');
    });

    test('manifest JSON round-trip preserves fields', () {
      final m = normalized(fields: const [
        secretField,
        PluginSettingsField(
          pluginId: pluginId,
          key: 'endpoint',
          label: 'Endpoint',
          unknownFields: {'type': 'url'},
        ),
      ]);

      final back = NormalizedPluginManifest.fromJson(
        jsonDecode(jsonEncode(m.toJson())) as Map<String, dynamic>,
      );

      expect(back.settingsFields.length, 2);
      expect(back.settingsFields[0].key, 'api_token');
      expect(back.settingsFields[0].secret, isTrue);
      expect(back.settingsFields[0].hint, 'From the dashboard');
      expect(back.settingsFields[1].unknownFields, {'type': 'url'});
    });

    test('empty settingsFields omit the JSON key (digest stability)', () {
      // The §5.1 grant digest hashes the manifest JSON: an always-present
      // (usually empty) key would re-digest EVERY installed plugin on app
      // update and trigger the migrationRequired cascade pinned by
      // test/plugin_digest_stability_test.dart.
      final plain = normalized();
      expect(plain.toJson().containsKey('settingsFields'), isFalse);
      expect(
        pluginManifestDigest(plain),
        pluginManifestDigest(
          NormalizedPluginManifest.fromJson(plain.toJson()),
        ),
      );
    });

    test('legacy persisted manifest JSON parses with no settingsFields key', () {
      final legacy = jsonDecode(jsonEncode(normalized().toJson()))
          as Map<String, dynamic>;
      expect(legacy.containsKey('settingsFields'), isFalse);
      expect(NormalizedPluginManifest.fromJson(legacy).settingsFields, isEmpty);
    });

    test('fromJson re-drops a smuggled inline secret value', () {
      final hostile = PluginSettingsField.fromJson(const {
        'pluginId': pluginId,
        'key': 'tok',
        'secret': true,
        'unknownFields': {'default': 'sk-9', 'type': 'string'},
      });
      expect(hostile.unknownFields.containsKey('default'), isFalse);
      expect(hostile.unknownFields['type'], 'string');
    });
  });

  group('approval path is not weakened (§5.1)', () {
    test('declaring settings fields changes the digest → re-approval', () {
      final before = normalized();
      final after = normalized(fields: const [secretField]);
      expect(pluginManifestDigest(after), isNot(pluginManifestDigest(before)));
    });

    test('settings fields add no capabilities to the inferred set', () {
      final before = normalized();
      final after = normalized(fields: const [secretField]);
      expect(
        inferRequestedCapabilities(after),
        inferRequestedCapabilities(before),
      );
    });

    test('a stored grant does not cover a later secret-field declaration', () async {
      final store = PluginPermissionStore();
      final before = normalized();
      await store.save(
        PluginPermissionGrant(
          pluginId: pluginId,
          manifestDigest: pluginManifestDigest(before),
          capabilities: inferRequestedCapabilities(before),
          approvedAt: DateTime.utc(2026),
        ),
      );

      final after = normalized(fields: const [secretField]);
      expect(
        await store.effectiveGrant(pluginId: pluginId, manifest: before),
        isNotNull,
      );
      expect(
        await store.effectiveGrant(pluginId: pluginId, manifest: after),
        isNull,
        reason: 'new declared content must re-enter the approval path',
      );
    });
  });

  group('registry §7 session scoping', () {
    PluginSettingsField field(String id, String key) => PluginSettingsField(
      pluginId: id,
      key: key,
      label: key,
    );

    void register(
      String id,
      PluginActivation activation, {
      String? immediateSessionId,
    }) {
      PluginContributionRegistry.I.register(
        normalized(fields: [field(id, 'tok')], id: id),
        activation: activation,
        immediateSessionId: immediateSessionId,
      );
      addTearDown(
        () => PluginContributionRegistry.I.unregisterPlugin(id),
      );
    }

    test('settingsFieldsForSession mirrors the toolsForSession rules', () {
      register('acme/global', PluginActivation.globalActive);
      register('acme/degraded', PluginActivation.degraded);
      register(
        'acme/session',
        PluginActivation.sessionActive,
        immediateSessionId: 's1',
      );
      register('acme/pending', PluginActivation.pendingGlobal);
      register('acme/off', PluginActivation.disabled);
      final reg = PluginContributionRegistry.I;

      List<String> keys(String session) => reg
          .settingsFieldsForSession(session)
          .map((f) => f.pluginId)
          .toList();

      expect(keys('s1'), ['acme/global', 'acme/degraded', 'acme/session']);
      expect(keys('s2'), ['acme/global', 'acme/degraded']);
      // Fail-closed: an empty session id never matches sessionActive.
      expect(keys(''), ['acme/global', 'acme/degraded']);
    });

    test('sessionActive with no session id is visible in no session', () {
      register('acme/orphan', PluginActivation.sessionActive);
      expect(
        PluginContributionRegistry.I.settingsFieldsForSession('s1'),
        isEmpty,
      );
    });

    test('settingsFieldsForPlugin ignores activation; unregistered is empty', () {
      register('acme/pending2', PluginActivation.pendingGlobal);
      final reg = PluginContributionRegistry.I;
      expect(reg.settingsFieldsForPlugin('acme/pending2').single.key, 'tok');
      expect(reg.settingsFieldsForPlugin('acme/unknown'), isEmpty);
    });

    test('unregister removes the fields', () {
      register('acme/gone', PluginActivation.globalActive);
      final reg = PluginContributionRegistry.I;
      expect(reg.settingsFieldsForSession('s1'), isNotEmpty);
      reg.unregisterPlugin('acme/gone');
      expect(reg.settingsFieldsForSession('s1'), isEmpty);
    });
  });
}
