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
}
