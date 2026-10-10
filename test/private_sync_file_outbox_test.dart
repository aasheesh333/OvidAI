import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/private_sync/file_outbox.dart';
import 'package:ovid_ai/core/private_sync/outbox.dart';

void main() {
  test(
    'atomic file survives reopen and fenced queued writes cannot replace it',
    () async {
      final root = await Directory.systemTemp.createTemp('file-outbox-');
      addTearDown(() => root.delete(recursive: true));
      var owns = true;
      final file = File('${root.path}/outbox.json');
      final persistence = FileOutboxPersistence(file, owns: () => owns);
      await persistence.writeAtomically([1, 2, 3]);
      expect(await FileOutboxPersistence(file).read(), [1, 2, 3]);
      final pending = persistence.writeAtomically([4, 5, 6]);
      owns = false;
      await expectLater(pending, throwsA(isA<OutboxFencedException>()));
      expect(await FileOutboxPersistence(file).read(), [1, 2, 3]);
      expect(await root.list().length, 1);
    },
  );
}
