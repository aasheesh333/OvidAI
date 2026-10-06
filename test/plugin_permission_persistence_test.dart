import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
// ignore: depend_on_referenced_packages
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:ovid_ai/core/plugin_manifest.dart';
import 'package:ovid_ai/core/plugin_permissions.dart';
import 'package:ovid_ai/core/plugin_registry.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:ovid_ai/ui/plugins_screen.dart';
import 'package:ovid_ai/ui/plugin_permission_sheet.dart';

class _ControlledPreferences extends InMemorySharedPreferencesStore {
  _ControlledPreferences() : super.empty();

  Future<bool> Function()? write;
  bool mutateBeforeResult = false;

  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    if (mutateBeforeResult) await super.setValue(valueType, key, value);
    if (write != null && !await write!()) return false;
    return super.setValue(valueType, key, value);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _ControlledPreferences backend;
  final store = PluginPermissionStore();
  final manifest = NormalizedPluginManifest(
    id: 'test/permission',
    name: 'Permission fixture',
    version: '1',
    format: PluginFormat.claudeCode,
    rootPath: '/fixture',
  );
  PluginPermissionGrant grant(String id, String digest) =>
      PluginPermissionGrant(
        pluginId: id,
        manifestDigest: digest,
        capabilities: const {},
        environmentReadNames: const {},
        approvedAt: DateTime.utc(2026),
      );

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
    backend = _ControlledPreferences();
    SharedPreferencesStorePlatform.instance = backend;
  });

  tearDown(() {
    PluginContributionRegistry.I.unregisterPlugin(manifest.id);
    AppState.resetTestInstance();
  });

  PluginItem activePlugin() {
    final app = AppState.createForTest();
    app.plugins.clear();
    app.mcpServers.clear();
    final row = PluginItem(
      name: 'Permission fixture',
      author: 'test',
      description: 'fixture',
      version: '1',
      category: 'Tool',
      installed: true,
      enabled: true,
      runtimeId: manifest.id,
      activation: PluginActivation.globalActive,
    );
    app.plugins.add(row);
    PluginContributionRegistry.I.register(
      manifest,
      activation: PluginActivation.globalActive,
    );
    return row;
  }

  test(
    'revocation stops active contributions before a failed durable write',
    () async {
      final row = activePlugin();
      await store.save(grant(manifest.id, pluginManifestDigest(manifest)));
      final pending = Completer<bool>();
      backend.write = () => pending.future;
      final revoking = AppState.I.revokePluginGrant(row);
      final failure = expectLater(revoking, throwsStateError);
      final activeWhilePending = PluginContributionRegistry.I
          .isPluginActiveForSession(manifest.id, 'session');
      pending.complete(false);
      await failure;
      expect(activeWhilePending, isFalse);
      expect(row.enabled, isFalse);
      expect(PluginContributionRegistry.I.isRegistered(manifest.id), isFalse);
    },
  );

  testWidgets(
    'failed permission revoke displays retry and keeps plugin disabled',
    (tester) async {
      final row = activePlugin();
      await store.save(grant(manifest.id, pluginManifestDigest(manifest)));
      await tester.binding.setSurfaceSize(const Size(1000, 1600));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(home: PluginDetailScreen(plugin: row)),
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byTooltip('Edit permissions'));
      await tester.tap(find.byTooltip('Edit permissions'));
      await tester.pumpAndSettle();
      backend.write = () async => false;
      await tester.tap(find.text('Revoke permissions'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(row.enabled, isFalse);
      expect(find.textContaining('Could not save revocation'), findsOneWidget);
      backend.write = null;
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(await store.loadAny(manifest.id), isNull);
    },
  );

  test(
    'revoke removes every owned secret and preserves sibling secrets',
    () async {
      const secure = FlutterSecureStorage();
      const prefix = 'ovid_plugin_secret_test/permission/';
      await secure.write(key: '${prefix}one', value: 'fixture');
      await secure.write(key: '${prefix}two', value: 'fixture');
      await secure.write(
        key: 'ovid_plugin_secret_test/sibling/one',
        value: 'fixture',
      );
      await store.revoke(manifest.id);
      expect(await secure.read(key: '${prefix}one'), isNull);
      expect(await secure.read(key: '${prefix}two'), isNull);
      expect(
        await secure.containsKey(key: 'ovid_plugin_secret_test/sibling/one'),
        isTrue,
      );
    },
  );

  for (final throwsError in [false, true]) {
    test(
      'failed revoke denies immediately and survives unrelated writes ($throwsError)',
      () async {
        final digest = pluginManifestDigest(manifest);
        await store.save(grant(manifest.id, digest));
        final pending = Completer<bool>();
        backend.mutateBeforeResult = true;
        backend.write = () => pending.future;
        final revoking = store.revoke(manifest.id);
        final failure = expectLater(revoking, throwsStateError);
        await Future<void>.delayed(Duration.zero);
        expect(
          await PluginPermissionStore().effectiveRuntimeGrant(
            pluginId: manifest.id,
            manifest: manifest,
          ),
          isNull,
        );
        backend.write = () async {
          if (throwsError) throw StateError('revoke commit failed');
          return false;
        };
        if (throwsError) {
          pending.completeError(StateError('revoke commit failed'));
        } else {
          pending.complete(false);
        }
        await failure;
        final prefs = await SharedPreferences.getInstance();
        await prefs.reload();
        expect(await store.loadAny(manifest.id), isNull);
        backend.write = null;
        await prefs.setBool('unrelated', true);
        await store.save(grant('test/sibling', 'sibling'));
        expect(await store.load(manifest.id, digest), isNull);
        expect(prefs.getString(kPluginGrantsPrefKey), isNot(contains(digest)));
        await store.revoke(manifest.id); // retry persists the tombstone
        expect(await store.loadAny(manifest.id), isNull);
        await store.save(grant(manifest.id, digest)); // explicit new approval
        expect(await store.load(manifest.id, digest), isNotNull);
      },
    );
  }

  for (final throwsError in [false, true]) {
    test(
      'native cache mutation before failed commit is never approval ($throwsError)',
      () async {
        final digest = pluginManifestDigest(manifest);
        await store.save(grant(manifest.id, 'old'));
        backend.mutateBeforeResult = true;
        backend.write = () async {
          if (throwsError) throw StateError('commit failed');
          return false;
        };
        await expectLater(
          store.save(grant(manifest.id, digest)),
          throwsStateError,
        );
        final prefs = await SharedPreferences.getInstance();
        await prefs.reload();
        final freshStore = PluginPermissionStore();
        expect(
          await freshStore.effectiveGrant(
            pluginId: manifest.id,
            manifest: manifest,
          ),
          isNull,
        );
        expect(
          await freshStore.effectiveRuntimeGrant(
            pluginId: manifest.id,
            manifest: manifest,
          ),
          isNull,
        );
        expect((await freshStore.loadAny(manifest.id))?.manifestDigest, 'old');
        // Another preferences write must not flush a failed native-cache grant.
        backend.write = null;
        await prefs.setBool('unrelated', true);
        await prefs.reload();
        expect(prefs.getString(kPluginGrantsPrefKey), isNot(contains(digest)));
        await freshStore.save(grant('test/sibling', 'sibling'));
        expect(await freshStore.load(manifest.id, digest), isNull);
        await freshStore.save(grant(manifest.id, digest));
        expect(
          await freshStore.effectiveRuntimeGrant(
            pluginId: manifest.id,
            manifest: manifest,
          ),
          isNotNull,
        );
      },
    );
  }

  test(
    'native pending snapshot stays quarantined until commit succeeds',
    () async {
      final digest = pluginManifestDigest(manifest);
      final pending = Completer<bool>();
      backend.mutateBeforeResult = true;
      backend.write = () => pending.future;
      final saving = store.save(grant(manifest.id, digest));
      // Let setValue mutate native memory while its commit is unresolved.
      await Future<void>.delayed(Duration.zero);
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      expect(await PluginPermissionStore().load(manifest.id, digest), isNull);
      expect(await store.loadAny(manifest.id), isNull);
      pending.complete(true);
      await saving;
      expect(
        await store.effectiveRuntimeGrant(
          pluginId: manifest.id,
          manifest: manifest,
        ),
        isNotNull,
      );
    },
  );

  for (final throwsError in [false, true]) {
    test(
      'failed write (${throwsError ? 'error' : 'false'}) never grants access',
      () async {
        await store.save(grant('test/permission', 'old'));
        backend.write = () async {
          if (throwsError) throw StateError('storage unavailable');
          return false;
        };
        await expectLater(
          store.save(grant('test/permission', 'new')),
          throwsA(isA<StateError>()),
        );
        expect(await store.load('test/permission', 'new'), isNull);
        expect((await store.loadAny('test/permission'))?.manifestDigest, 'old');

        // A later successful write must not commit the failed optimistic cache.
        backend.write = null;
        await store.save(grant('test/other', 'other'));
        final prefs = await SharedPreferences.getInstance();
        await prefs.reload();
        expect((await store.loadAny('test/permission'))?.manifestDigest, 'old');
        expect(await store.load('test/other', 'other'), isNotNull);
      },
    );
  }

  testWidgets(
    'pending approval blocks cancel/back; failed save permits retry',
    (tester) async {
      final pending = Completer<bool>();
      backend.write = () => pending.future;
      bool? result;
      var returned = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) {
              return Scaffold(
                body: TextButton(
                  onPressed: () async {
                    result = await showPluginPermissionSheet(
                      context,
                      manifest: manifest,
                    );
                    returned = true;
                  },
                  child: const Text('Open'),
                ),
              );
            },
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Accept'));
      await tester.pump();
      expect(
        tester
            .widget<TextButton>(
              find.widgetWithText(TextButton, 'Cancel'),
            )
            .onPressed,
        isNull,
      );
      await tester.binding.handlePopRoute();
      await tester.pump();
      expect(returned, isFalse);
      expect(find.text('Grant plugin access'), findsOneWidget);

      pending.complete(false);
      await tester.pumpAndSettle();
      expect(returned, isFalse);
      expect(find.textContaining('Could not save'), findsOneWidget);
      expect(
        tester
            .widget<TextButton>(find.widgetWithText(TextButton, 'Cancel'))
            .onPressed,
        isNotNull,
      );
      expect(
        await store.load(manifest.id, pluginManifestDigest(manifest)),
        isNull,
      );
      backend.write = null;
      await tester.tap(find.text('Accept'));
      await tester.pumpAndSettle();
      expect(result, isTrue);
      expect(
        await store.load(manifest.id, pluginManifestDigest(manifest)),
        isNotNull,
      );
    },
  );
}
