import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/collaboration/file_store.dart';
import 'package:ovid_ai/core/collaboration/store.dart';

void main() {
  late Directory directory;
  late File file;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp(
      'collaboration-file-store-',
    );
    file = File('${directory.path}/collaboration.json');
  });

  tearDown(() async {
    if (await directory.exists()) await directory.delete(recursive: true);
  });

  test('round-trips an account-owned record', () async {
    final backend = FileCollaborationStoreBackend(
      file,
      ownerFence: 'account-a',
    );
    final record = <String, Object?>{
      'schemaVersion': 1,
      'accountId': 'account-a',
      'sessionGeneration': 3,
      'events': <Object?>[],
    };

    await backend.write(record);

    expect(await backend.read(), record);
  });

  test('does not replace the previous record when a write fails', () async {
    final backend = FileCollaborationStoreBackend(
      file,
      ownerFence: 'account-a',
    );
    final original = <String, Object?>{
      'accountId': 'account-a',
      'value': 'original',
    };
    await backend.write(original);

    final invalid = <String, Object?>{
      'accountId': 'account-a',
      'value': double.nan,
    };

    await expectLater(
      backend.write(invalid),
      throwsA(isA<CollaborationStoreException>()),
    );
    expect(await backend.read(), original);
  });

  test(
    'rejects records owned by another account without exposing them',
    () async {
      await file.writeAsString(
        jsonEncode(<String, Object?>{
          'accountId': 'account-b',
          'value': 'private',
        }),
      );
      final backend = FileCollaborationStoreBackend(
        file,
        ownerFence: 'account-a',
      );

      await expectLater(
        backend.read(),
        throwsA(isA<CollaborationStoreException>()),
      );
    },
  );

  test('clear removes the account record', () async {
    final backend = FileCollaborationStoreBackend(
      file,
      ownerFence: 'account-a',
    );
    await backend.write(<String, Object?>{'accountId': 'account-a'});

    await backend.clear();

    expect(await backend.read(), isNull);
    expect(await file.exists(), isFalse);
  });

  test('lease invalidated during staged flush cannot replace the durable file', () async {
    final backend = FileCollaborationStoreBackend(file, ownerFence: 'account-a');
    final original = <String, Object?>{'accountId': 'account-a', 'value': 'original'};
    await backend.write(original);
    await backend.writeGuarded({'accountId': 'account-a', 'value': 'late'},
      () => !directory.listSync().any((entry) => entry.path.contains('.tmp-')));
    expect(await backend.read(), original);
    expect(directory.listSync().length, 1);
  });
}
