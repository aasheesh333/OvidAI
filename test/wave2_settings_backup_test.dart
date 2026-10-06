import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/settings_backup_service.dart';
import 'package:ovid_ai/core/state.dart';

void main() {
  late Directory root;
  setUp(() => root = Directory.systemTemp.createTempSync('backup-test-'));
  tearDown(() => root.deleteSync(recursive: true));

  Map<String, dynamic> manifestOf(List<int> bytes) =>
      jsonDecode(
            utf8.decode(
              ZipDecoder().decodeBytes(bytes).findFile('manifest.json')!.content,
            ),
          )
          as Map<String, dynamic>;

  List<int> archiveWithManifest(Map<String, dynamic> manifest) {
    final data = utf8.encode(jsonEncode(manifest));
    final archive = Archive()
      ..add(ArchiveFile.noCompress('manifest.json', data.length, data));
    return ZipEncoder().encode(archive);
  }

  test(
    'oversized transcript rejected and streaming content excluded',
    () async {
      final service = SettingsBackupService();
      await expectLater(
        service.export([
          ChatSession(
            id: 'one',
            title: 't',
            model: 'm',
            messages: [Message(role: 'user', content: 'x' * (1024 * 1024 + 1))],
          ),
        ]),
        throwsFormatException,
      );
      final bytes = await service.export([
        ChatSession(
          id: 'one',
          title: 't',
          model: 'm',
          messages: [
            Message(role: 'assistant', content: 'unfinished', thinking: true),
          ],
        ),
      ]);
      final staged = await service.stage(bytes, root);
      expect(staged.sessions.single['messages'], isEmpty);
      await staged.dispose();
    },
  );

  test('oversized input and corrupted stored payload never stage', () async {
    final service = SettingsBackupService();
    await expectLater(
      service.stage(Uint8List(SettingsBackupService.maxArchiveBytes + 1), root),
      throwsFormatException,
    );
    final bytes = await service.export([
      ChatSession(id: 'one', title: 't', model: 'm'),
    ]);
    final directory = ZipDirectory()..read(InputMemoryStream(bytes));
    final header = directory.fileHeaders.single;
    final corrupt = List<int>.of(bytes);
    final offset = header.localHeaderOffset;
    final filenameLength = corrupt[offset + 26] | corrupt[offset + 27] << 8;
    final extraLength = corrupt[offset + 28] | corrupt[offset + 29] << 8;
    corrupt[offset + 30 + filenameLength + extraLength] ^= 1;
    await expectLater(service.stage(corrupt, root), throwsFormatException);
    expect(root.listSync(), isEmpty);
  });

  test(
    'publisher receives new IDs, portable files, and staging is removed after publish',
    () async {
      String? newId;
      Directory? stage;
      final service = SettingsBackupService(
        publisher: (backup, ids) async {
          newId = ids['one'];
          stage = backup.directory;
          expect(backup.sessions.single['title'], 'original');
        },
      );
      final bytes = await service.export([
        ChatSession(id: 'one', title: 'original', model: 'm'),
      ]);
      await service.restore(bytes, root);
      expect(newId, startsWith('restored-'));
      expect(newId, isNot('one'));
      expect(stage!.existsSync(), isFalse);
    },
  );

  test(
    'portable transcript roundtrip excludes grants, credentials and live state',
    () async {
      final attachment = File('${root.path}/note.txt')
        ..writeAsStringSync('portable');
      final service = SettingsBackupService(attachmentRoots: [root]);
      final session = ChatSession(
        id: 'one',
        title: 'Hello',
        model: 'model',
        workspaceFolder: '/private',
        agentState: 'running',
        schedules: [
          {'enabled': true, 'prompt': 'run'},
        ],
        messages: [
          Message(
            role: 'user',
            content: 'Hello',
            attachments: [
              MessageAttachment(
                name: 'note.txt',
                size: 8,
                path: attachment.path,
              ),
            ],
          ),
        ],
      );
      final bytes = await service.export([session]);
      final staged = await service.stage(bytes, root);
      expect(staged.sessions.single['title'], 'Hello');
      expect(staged.sessions.single.containsKey('workspaceFolder'), isFalse);
      expect(staged.sessions.single.containsKey('schedules'), isFalse);
      expect(staged.sessions.single.containsKey('grants'), isFalse);
      expect(staged.attachments.values.single.readAsStringSync(), 'portable');
      expect(
        utf8.decode(
          ZipDecoder().decodeBytes(bytes).findFile('manifest.json')!.content,
        ),
        isNot(contains(attachment.path)),
      );
      await staged.dispose();
      expect(staged.directory.existsSync(), isFalse);
    },
  );

  test(
    'missing attachment is explicit and source outside approved roots is never read',
    () async {
      final service = SettingsBackupService();
      final bytes = await service.export([
        ChatSession(
          id: 'one',
          title: 't',
          model: 'm',
          messages: [
            Message(
              role: 'user',
              attachments: [
                MessageAttachment(
                  name: 'secret',
                  size: 10,
                  path: '/etc/passwd',
                ),
              ],
            ),
          ],
        ),
      ]);
      final staged = await service.stage(bytes, root);
      final a =
          (staged.sessions.single['messages'] as List).single['attachments'][0];
      expect(a['status'], 'unavailable');
      expect(staged.attachments, isEmpty);
      await staged.dispose();
    },
  );

  test(
    'traversal, absolute paths, links and compressed archives are rejected',
    () async {
      final service = SettingsBackupService();
      for (final name in [
        '../escape',
        '/absolute',
        r'attachments\escape',
        'attachments/../escape',
      ]) {
        final archive = Archive()..add(ArchiveFile.noCompress(name, 1, [1]));
        await expectLater(
          service.stage(ZipEncoder().encode(archive), root),
          throwsFormatException,
        );
      }
      final link = Archive()
        ..add(
          ArchiveFile.noCompress('attachments/0', 9, utf8.encode('../escape'))
            ..mode = 0xa1ff,
        );
      await expectLater(
        service.stage(ZipEncoder().encode(link), root),
        throwsFormatException,
      );
      final compressed = Archive()
        ..add(ArchiveFile.string('manifest.json', '{}'));
      await expectLater(
        service.stage(ZipEncoder().encode(compressed), root),
        throwsFormatException,
      );
      expect(root.listSync(), isEmpty);
    },
  );

  test(
    'invalid version, duplicate IDs, missing blobs and unknown secret fields reject without staging',
    () async {
      final service = SettingsBackupService();
      final bytes = await service.export([
        ChatSession(id: 'one', title: 't', model: 'm'),
      ]);
      final manifest =
          jsonDecode(
                utf8.decode(
                  ZipDecoder()
                      .decodeBytes(bytes)
                      .findFile('manifest.json')!
                      .content,
                ),
              )
              as Map;
      for (final mutate in <void Function(Map)>[
        (m) => m['version'] = 999,
        (m) => (m['sessions'] as List).add((m['sessions'] as List).first),
        (m) => m['apiKey'] = 'secret',
        (m) => m['attachments'] = [
          {'path': 'attachments/0', 'size': 1, 'sha256': '0' * 64},
        ],
      ]) {
        final copy = jsonDecode(jsonEncode(manifest)) as Map;
        mutate(copy);
        final data = utf8.encode(jsonEncode(copy));
        final archive = Archive()
          ..add(ArchiveFile.noCompress('manifest.json', data.length, data));
        await expectLater(
          service.stage(ZipEncoder().encode(archive), root),
          throwsFormatException,
        );
        expect(root.listSync(), isEmpty);
      }
    },
  );

  test(
    'restore without atomic publisher leaves existing data intact',
    () async {
      final current = File('${root.path}/current')
        ..writeAsStringSync('original');
      final service = SettingsBackupService();
      final bytes = await service.export([
        ChatSession(id: 'one', title: 't', model: 'm'),
      ]);
      await expectLater(service.restore(bytes, root), throwsUnsupportedError);
      expect(current.readAsStringSync(), 'original');
      expect(root.listSync().length, 1);
    },
  );

  test(
    'failed publisher cleans staging and never claims publication',
    () async {
      final current = File('${root.path}/current')
        ..writeAsStringSync('original');
      final service = SettingsBackupService(
        publisher: (_, _) async => throw StateError('disk full'),
      );
      final bytes = await service.export([
        ChatSession(id: 'one', title: 't', model: 'm'),
      ]);
      await expectLater(service.restore(bytes, root), throwsStateError);
      expect(current.readAsStringSync(), 'original');
      expect(root.listSync().length, 1);
    },
  );

  test('allowlisted settings roundtrip and exclude secrets and grants', () async {
    final service = SettingsBackupService();
    final captured = SettingsBackupService.captureSettings({
      'ovid_theme_mode': 'light',
      'ovid_keep_alive': false,
      'ovid_chat_font_scale': 1.25,
      'ovid_response_timeout_sec': 120,
      'ovid_provider_configs_v1': '{"apiKey":"secret"}',
      'ovid_permission_grants_v1': ['grant'],
      'ovid_mcp_env_secret': 'token',
      'ovid_memories': 'private',
    });
    expect(captured.containsKey('ovid_provider_configs_v1'), isFalse);
    expect(captured.containsKey('ovid_permission_grants_v1'), isFalse);
    expect(captured.containsKey('ovid_mcp_env_secret'), isFalse);
    expect(captured.containsKey('ovid_memories'), isFalse);
    final bytes = await service.export([
      ChatSession(id: 'one', title: 't', model: 'm'),
    ], settings: captured);
    expect(manifestOf(bytes)['settings'], {
      'version': 1,
      'values': {
        'ovid_theme_mode': 'light',
        'ovid_keep_alive': false,
        'ovid_chat_font_scale': 1.25,
        'ovid_response_timeout_sec': 120,
      },
    });
    final staged = await service.stage(bytes, root);
    expect(staged.settings, captured);
    expect(staged.sessions.single['title'], 't');
    await staged.dispose();
  });

  test('settings snapshot rejects unknown keys, bad types and oversized strings', () async {
    final service = SettingsBackupService();
    final sessions = [ChatSession(id: 'one', title: 't', model: 'm')];
    await expectLater(
      service.export(sessions, settings: {'ovid_sessions': 'leak'}),
      throwsFormatException,
    );
    await expectLater(
      service.export(sessions, settings: {'ovid_keep_alive': 'yes'}),
      throwsFormatException,
    );
    await expectLater(
      service.export(sessions, settings: {'ovid_keep_alive': double.nan}),
      throwsFormatException,
    );
    await expectLater(
      service.export(sessions, settings: {
        'ovid_theme_mode':
            'x' * (SettingsBackupService.maxSettingStringLength + 1),
      }),
      throwsFormatException,
    );
    expect(
      () => SettingsBackupService.captureSettings({'ovid_keep_alive': 1}),
      throwsFormatException,
    );
    expect(root.listSync(), isEmpty);
  });

  test('restore publishes the settings snapshot with the transcripts', () async {
    Map<String, Object>? seen;
    final service = SettingsBackupService(
      publisher: (backup, ids) async {
        seen = backup.settings;
      },
    );
    final bytes = await service.export([
      ChatSession(id: 'one', title: 't', model: 'm'),
    ], settings: {'ovid_theme_mode': 'dark', 'ovid_keep_alive': true});
    await service.restore(bytes, root);
    expect(seen, {'ovid_theme_mode': 'dark', 'ovid_keep_alive': true});
  });

  test('settings restore applies every value or rolls back all previous values', () async {
    final store = <String, Object?>{
      'ovid_theme_mode': 'dark',
      'ovid_keep_alive': true,
      'unrelated': 'kept',
    };
    Future<void> write(String key, Object? value) async {
      if (value == null) {
        store.remove(key);
      } else {
        store[key] = value;
      }
    }

    await SettingsBackupService.applySettingsAtomically(
      snapshot: {'ovid_theme_mode': 'light', 'ovid_show_reasoning': false},
      previous: {'ovid_theme_mode': 'dark', 'ovid_keep_alive': true},
      write: write,
    );
    expect(store, {
      'ovid_theme_mode': 'light',
      'ovid_show_reasoning': false,
      'unrelated': 'kept',
    });

    final failing = <String, Object?>{
      'ovid_theme_mode': 'dark',
      'ovid_keep_alive': true,
    };
    var failed = false;
    Future<void> flaky(String key, Object? value) async {
      if (!failed && key == 'ovid_show_reasoning' && value != null) {
        failed = true;
        throw StateError('disk full');
      }
      if (value == null) {
        failing.remove(key);
      } else {
        failing[key] = value;
      }
    }

    await expectLater(
      SettingsBackupService.applySettingsAtomically(
        snapshot: {'ovid_theme_mode': 'light', 'ovid_show_reasoning': false},
        previous: {'ovid_theme_mode': 'dark', 'ovid_keep_alive': true},
        write: flaky,
      ),
      throwsStateError,
    );
    expect(failing, {'ovid_theme_mode': 'dark', 'ovid_keep_alive': true});
  });

  test('settings restore rejects non-allowlisted keys before writing', () async {
    var wrote = false;
    await expectLater(
      SettingsBackupService.applySettingsAtomically(
        snapshot: {'ovid_provider_configs_v1': 'secret'},
        previous: const {},
        write: (key, value) async {
          wrote = true;
        },
      ),
      throwsFormatException,
    );
    expect(wrote, isFalse);
  });

  test('transcript-only archive stays version 1 with no settings section', () async {
    final service = SettingsBackupService();
    final bytes = await service.export([
      ChatSession(id: 'one', title: 't', model: 'm'),
    ]);
    final manifest = manifestOf(bytes);
    expect(manifest['version'], 1);
    expect(manifest.containsKey('settings'), isFalse);
    final staged = await service.stage(bytes, root);
    expect(staged.settings, isEmpty);
    await staged.dispose();
  });

  test('invalid settings schema, unknown fields and values reject without staging', () async {
    final service = SettingsBackupService();
    final bytes = await service.export([
      ChatSession(id: 'one', title: 't', model: 'm'),
    ], settings: {'ovid_theme_mode': 'dark'});
    final manifest = manifestOf(bytes);
    for (final mutate in <void Function(Map<String, dynamic>)>[
      (m) => (m['settings'] as Map)['version'] = 999,
      (m) => (m['settings'] as Map)['apiKey'] = 'secret',
      (m) => ((m['settings'] as Map)['values'] as Map)['ovid_grants'] = 'secret',
      (m) => ((m['settings'] as Map)['values'] as Map)['ovid_keep_alive'] = 'yes',
      (m) => (m['settings'] as Map)['values'] = 'not-a-map',
    ]) {
      final copy = jsonDecode(jsonEncode(manifest)) as Map<String, dynamic>;
      mutate(copy);
      await expectLater(
        service.stage(archiveWithManifest(copy), root),
        throwsFormatException,
      );
      expect(root.listSync(), isEmpty);
    }
  });
}
