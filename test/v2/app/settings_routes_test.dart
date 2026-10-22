import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:permission_handler/permission_handler.dart' hide ServiceStatus;
import 'package:shared_preferences/shared_preferences.dart';
// ignore: depend_on_referenced_packages
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

import 'package:ovid_ai/core/cloud/account_settings_client.dart';
import 'package:ovid_ai/core/cloud/cloud_rest.dart';
import 'package:ovid_ai/core/cloud_usage_store.dart';
import 'package:ovid_ai/core/presets.dart';
import 'package:ovid_ai/core/state.dart' hide ServiceStatus;
import 'package:ovid_ai/ui/design/o_theme.dart';
import 'package:ovid_ai/ui/v2/app/v2_settings_actions.dart';
import 'package:ovid_ai/ui/v2/app/v2_settings_routes.dart';
import 'package:ovid_ai/ui/v2/settings/memory_page.dart';
import 'package:ovid_ai/ui/v2/settings_extra/about_page.dart';
import 'package:ovid_ai/ui/v2/settings_extra/agent_presets_page.dart';
import 'package:ovid_ai/ui/v2/settings_extra/permissions_page.dart';

/// A prefs store that can refuse one key, so the failure path is real.
class _RefusingPrefs extends InMemorySharedPreferencesStore {
  _RefusingPrefs() : super.empty();

  String? refuseKey;

  @override
  Future<bool> setValue(String type, String key, Object value) async {
    final refuse = refuseKey;
    if (refuse != null && key.endsWith(refuse)) {
      throw PlatformException(code: 'disk_full', message: 'write refused');
    }
    return super.setValue(type, key, value);
  }
}

/// Counts `/health/status` reads: the About screen must make none.
class _CountingAccountClient extends AccountSettingsClient {
  _CountingAccountClient() : super(rest: CloudRestClient());

  int statusCalls = 0;

  @override
  Future<ServiceStatus> serviceStatus() async {
    statusCalls++;
    return ServiceStatus.fromJson(const {});
  }
}

/// A memory API that behaves like the gateway: chat-scope by default, the
/// shared scope when [shared] is true, revision-checked writes and 404-style
/// deletes.
class _FakeMemoryClient extends AccountSettingsClient {
  _FakeMemoryClient({this.shared = false, Map<String, String>? files})
    : files = files ?? <String, String>{},
      super(rest: CloudRestClient());

  bool shared;
  final Map<String, String> files;
  final Map<String, String> revisions = <String, String>{};
  final List<String> deleted = <String>[];
  int writes = 0;

  @override
  Future<MemoryListing> memoryFiles(String sessionId) async => MemoryListing([
    for (final entry in files.entries)
      MemoryFileSummary(name: entry.key, sizeBytes: entry.value.length),
  ], shared: shared);

  @override
  Future<MemoryFile> readMemory(String sessionId, String name) async =>
      MemoryFile(
        name: name,
        content: files[name] ?? '',
        revision: revisions[name] ?? 'r1',
      );

  @override
  Future<MemoryFile> writeMemory(
    String sessionId,
    String name,
    String content, {
    String? ifRevision,
  }) async {
    writes++;
    files[name] = content;
    revisions[name] = 'r${writes + 1}';
    return MemoryFile(name: name, content: content, revision: revisions[name]!);
  }

  @override
  Future<void> deleteMemory(String sessionId, String name) async {
    deleted.add(name);
    files.remove(name);
  }
}

/// A client whose writes always fail, to prove the source never invents rows.
class _FailingWriteMemoryClient extends _FakeMemoryClient {
  _FailingWriteMemoryClient({super.shared});

  @override
  Future<MemoryFile> writeMemory(
    String sessionId,
    String name,
    String content, {
    String? ifRevision,
  }) async {
    throw StateError('write refused');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(const <String, Object>{});
    AppState.resetTestInstance();
    AppState.createForTest();
    PresetRegistry.clearCustom();
  });

  tearDown(() {
    AccountSettingsClient.installForTest(null);
    AppState.resetTestInstance();
  });

  group('memory facts', () {
    test('bullets become facts and headings/fences are skipped', () {
      final facts = memoryFactsFrom(
        'MEMORY.md',
        '# Memory\n\n- Prefers plain English.\n* Works as a designer.\n'
            '```\n- not a fact\n```\n1. Ships on Fridays.\n',
      );

      expect(facts.map((fact) => fact.text), [
        'Prefers plain English.',
        'Works as a designer.',
        'Ships on Fridays.',
      ]);
      expect(facts.first.fileName, 'MEMORY.md');
      expect(facts.first.id, 'MEMORY.md#2');
    });

    test('removing a fact deletes only its line', () {
      const content = '# Memory\n- One\n- Two\n- Three\n';
      final fact = memoryFactsFrom('MEMORY.md', content)[1];

      final next = removeMemoryFact(content, fact);

      expect(next, '# Memory\n- One\n- Three\n');
    });

    test('a changed file refuses to delete the wrong line', () {
      const content = '- One\n- Two\n';
      final fact = memoryFactsFrom('MEMORY.md', content)[1];

      expect(removeMemoryFact('- Two changed\n- One\n', fact), isNull);
    });
  });

  group('memory source', () {
    test('a chat-scope listing keeps files and has no global facts', () async {
      final client = _FakeMemoryClient(
        files: {'MEMORY.md': '- Likes short answers.'},
      );
      final snapshot = await V2MemorySource(client: client).load('s1');

      expect(snapshot.shared, isFalse);
      expect(snapshot.files, hasLength(1));
      expect(snapshot.facts, isEmpty);
    });

    test('a shared listing turns file lines into global facts', () async {
      final client = _FakeMemoryClient(
        shared: true,
        files: {
          'MEMORY.md': '- Likes short answers.\n- Timezone IST.',
          'notes.md': '# Notes\n- Uses Flutter.',
        },
      );
      final snapshot = await V2MemorySource(client: client).load('s1');

      expect(snapshot.shared, isTrue);
      expect(snapshot.facts.map((fact) => fact.text), [
        'Likes short answers.',
        'Timezone IST.',
        'Uses Flutter.',
      ]);
    });

    test(
      'forgetting a global fact rewrites the file without that line',
      () async {
        final client = _FakeMemoryClient(
          shared: true,
          files: {'MEMORY.md': '- One\n- Two\n- Three\n'},
        );
        final source = V2MemorySource(client: client);
        final snapshot = await source.load('s1');

        await source.forget(
          sessionId: 's1',
          scope: V2MemoryScope.global,
          id: snapshot.facts[1].id,
          snapshot: snapshot,
        );

        expect(client.files['MEMORY.md'], '- One\n- Three\n');
        expect(client.deleted, isEmpty);
      },
    );

    test('forgetting the last global fact deletes the empty file', () async {
      final client = _FakeMemoryClient(
        shared: true,
        files: {'MEMORY.md': '- Only fact\n'},
      );
      final source = V2MemorySource(client: client);
      final snapshot = await source.load('s1');

      await source.forget(
        sessionId: 's1',
        scope: V2MemoryScope.global,
        id: snapshot.facts.single.id,
        snapshot: snapshot,
      );

      expect(client.deleted, ['MEMORY.md']);
    });

    test('forgetting a session row deletes that file', () async {
      final client = _FakeMemoryClient(
        files: {'MEMORY.md': '- A', 'spec.md': '- B'},
      );
      final source = V2MemorySource(client: client);
      final snapshot = await source.load('s1');

      await source.forget(
        sessionId: 's1',
        scope: V2MemoryScope.session,
        id: 'spec.md',
        snapshot: snapshot,
      );

      expect(client.deleted, ['spec.md']);
      expect(client.files.containsKey('MEMORY.md'), isTrue);
    });
  });

  group('memory writes', () {
    test(
      'editing a global fact rewrites its line and keeps the bullet',
      () async {
        final client = _FakeMemoryClient(
          shared: true,
          files: {'MEMORY.md': '- One\n- Two\n'},
        );
        final source = V2MemorySource(client: client);
        final snapshot = await source.load('s1');

        final saved = await source.editFact(
          sessionId: 's1',
          scope: V2MemoryScope.global,
          id: snapshot.facts.first.id,
          text: 'Uno',
        );

        expect(saved, 'Uno');
        expect(client.files['MEMORY.md'], '- Uno\n- Two\n');
      },
    );

    test('adding a fact appends it and returns the stored entry', () async {
      final client = _FakeMemoryClient(
        shared: true,
        files: {'MEMORY.md': '- One\n'},
      );
      final source = V2MemorySource(client: client);

      final created = await source.addFact(sessionId: 's1', text: 'Two');

      expect(created, isNotNull);
      expect(created!.text, 'Two');
      expect(client.files['MEMORY.md'], '- One\n- Two\n');
      expect(created.id, startsWith('MEMORY.md#'));
    });

    test('adding the first fact creates MEMORY.md', () async {
      final client = _FakeMemoryClient(shared: true);
      final source = V2MemorySource(client: client);

      final created = await source.addFact(sessionId: 's1', text: 'Hello');

      expect(created?.text, 'Hello');
      expect(client.files['MEMORY.md'], '- Hello\n');
    });

    test('a failed write reports null instead of inventing an entry', () async {
      final client = _FailingWriteMemoryClient(shared: true);
      final source = V2MemorySource(client: client);

      final created = await source.addFact(sessionId: 's1', text: 'Nope');

      expect(created, isNull);
    });
  });

  group('permissions', () {
    test('only the two manifest permissions are listed', () {
      final items = V2SettingsRoutes.permissionItemsForTest({
        'microphone': PermissionStatus.granted,
        'notifications': PermissionStatus.granted,
        'camera': PermissionStatus.granted,
        'photos': PermissionStatus.granted,
        'storage': PermissionStatus.granted,
      });

      expect(items.map((item) => item.id), ['microphone', 'notifications']);
    });

    test('a refused permission reads as denied, not "Not asked"', () {
      expect(
        V2SettingsRoutes.permissionAccessForTest(PermissionStatus.denied),
        V2PermissionAccess.denied,
      );
      expect(
        V2SettingsRoutes.permissionAccessForTest(PermissionStatus.granted),
        V2PermissionAccess.granted,
      );
      expect(
        V2SettingsRoutes.permissionAccessForTest(
          PermissionStatus.permanentlyDenied,
        ),
        V2PermissionAccess.permanentlyDenied,
      );
    });
  });

  group('presets', () {
    test('the route hands the page real hooks and model options', () {
      final data = V2SettingsRoutes.presetsPageForTest();

      expect(data.onApply, isNotNull);
      expect(data.onCreatePreset, isNotNull);
      expect(data.onUpdatePreset, isNotNull);
      expect(data.onDeletePreset, isNotNull);
      expect(data.models, isNotEmpty);
      expect(data.models.first.id, 'auto');
      expect(data.defaultResponseWaitSeconds, AppState.I.responseTimeoutSec);
    });

    test(
      'create and edit keep wait and mode; built-ins stay protected',
      () async {
        final data = V2SettingsRoutes.presetsPageForTest();

        await data.onCreatePreset!(
          const V2AgentPresetDraft(
            name: 'Release notes',
            description: 'Changelog',
            modelId: 'auto',
            modelLabel: 'Auto',
            responseWaitSeconds: 120,
            permissionModeId: 'drive',
          ),
        );
        final created = PresetRegistry.customPresets.single;
        expect(created.label, 'Release notes');
        expect(created.responseWaitSeconds, 120);
        expect(created.permissionMode, 'drive');

        await data.onUpdatePreset!(
          created.id,
          const V2AgentPresetDraft(
            name: 'Release notes v2',
            modelId: 'auto',
            modelLabel: 'Auto',
            responseWaitSeconds: 60,
            permissionModeId: 'safe',
          ),
        );
        final updated = PresetRegistry.byId(created.id);
        expect(updated.label, 'Release notes v2');
        expect(updated.responseWaitSeconds, 60);
        expect(updated.permissionMode, 'safe');

        await expectLater(
          data.onUpdatePreset!(
            'standard',
            const V2AgentPresetDraft(
              name: 'Hijacked',
              modelId: 'auto',
              modelLabel: 'Auto',
            ),
          ),
          throwsA(isA<StateError>()),
        );
        expect(PresetRegistry.byId('standard').label, 'Standard');
        expect(PresetRegistry.customPresets, hasLength(1));
      },
    );

    test('response wait and permission mode round-trip through JSON', () {
      const preset = AgentPreset(
        id: 'custom_release',
        label: 'Release',
        description: 'Writes the changelog.',
        model: 'ovid-2-pro',
        responseWaitSeconds: 120,
        permissionMode: 'drive',
      );

      final restored = AgentPreset.fromJson(preset.toJson());

      expect(restored.responseWaitSeconds, 120);
      expect(restored.permissionMode, 'drive');
      expect(restored.model, 'ovid-2-pro');
    });

    test('copyWith preserves the recorded wait and mode', () {
      const preset = AgentPreset(
        id: 'custom_release',
        label: 'Release',
        description: '',
        responseWaitSeconds: 60,
        permissionMode: 'safe',
      );

      final renamed = preset.copyWith(label: 'Release notes');

      expect(renamed.responseWaitSeconds, 60);
      expect(renamed.permissionMode, 'safe');
    });

    test('saving a custom preset persists its wait and mode', () async {
      const preset = AgentPreset(
        id: 'custom_persisted',
        label: 'Persisted',
        description: '',
        responseWaitSeconds: 90,
        permissionMode: 'studio',
      );

      await AppState.I.saveCustomPreset(preset);

      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('ovid_custom_presets');
      expect(raw, isNotNull);
      final list = jsonDecode(raw!) as List<dynamic>;
      final entry = list.cast<Map<String, dynamic>>().singleWhere(
        (row) => row['id'] == 'custom_persisted',
      );

      expect(entry['responseWaitSeconds'], 90);
      expect(entry['permissionMode'], 'studio');

      // What the store wrote is what a reload reads back.
      final restored = AgentPreset.fromJson(entry);
      expect(restored.responseWaitSeconds, 90);
      expect(restored.permissionMode, 'studio');
    });
  });

  group('response wait', () {
    test('a refused prefs write rolls back and reports the failure', () async {
      final backend = _RefusingPrefs();
      SharedPreferencesStorePlatform.instance = backend;
      final app = AppState.I;
      final before = app.responseTimeoutSec;
      backend.refuseKey = 'ovid_response_timeout_sec';

      await expectLater(
        app.setResponseTimeout(120),
        throwsA(isA<PlatformException>()),
      );

      expect(app.responseTimeoutSec, before);
    });
  });

  group('about', () {
    testWidgets('renders build info without asking for service status', (
      tester,
    ) async {
      final client = _CountingAccountClient();
      AccountSettingsClient.installForTest(client);
      final usage = CloudUsageStore.acquire(AppState.I);
      final actions = V2SettingsActions(usage);

      late BuildContext context;
      await tester.pumpWidget(
        MaterialApp(
          theme: OTheme.light(),
          home: Scaffold(
            body: Builder(
              builder: (ctx) {
                context = ctx;
                return const SizedBox.shrink();
              },
            ),
          ),
        ),
      );

      final before = client.statusCalls;
      unawaited(V2SettingsRoutes.open(context, 'about', actions));
      await tester.pumpAndSettle();

      expect(find.byType(AboutPage), findsOneWidget);
      expect(client.statusCalls, before);
      // Release in the body: the store's refresh cooldown timer would otherwise
      // outlive the widget tree.
      usage.release();
    });
  });

  group('export selection', () {
    test('rows carry real sizes, message counts and selection', () {
      final older = ChatSession(
        id: 'a',
        title: 'Older chat',
        model: 'auto',
        createdAt: DateTime(2026, 1, 1),
      )..messages.add(Message(role: 'user', content: 'hello'));
      final newer =
          ChatSession(
              id: 'b',
              title: 'Newer chat',
              model: 'auto',
              createdAt: DateTime(2026, 2, 1),
            )
            ..messages.addAll([
              Message(role: 'user', content: 'one'),
              Message(role: 'assistant', content: 'two'),
            ]);
      final empty = ChatSession(
        id: 'c',
        title: 'Empty',
        model: 'auto',
        createdAt: DateTime(2026, 3, 1),
      );

      final rows = V2SettingsRoutes.exportSessionsFor(
        [older, newer, empty],
        {'a': false},
      );

      // Newest first; a chat with no messages has nothing to export.
      expect(rows.map((row) => row.id), ['b', 'a']);
      expect(rows.first.detail, '2 messages');
      expect(rows.first.sizeBytes, greaterThan(0));
      expect(rows.last.detail, '1 message');
      expect(rows.last.selected, isFalse);
      expect(rows.first.selected, isTrue);
    });
  });
}
