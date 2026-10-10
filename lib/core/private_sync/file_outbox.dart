import 'dart:async';
import 'dart:io';

import 'outbox.dart';

/// One atomic file per account. A revoked writer cannot replace the file after
/// an account handoff, including while a staged write is being flushed.
class FileOutboxPersistence implements OutboxPersistence {
  FileOutboxPersistence(this.file, {bool Function()? owns})
    : owns = owns ?? (() => true);

  final File file;
  final bool Function() owns;
  Future<void> _tail = Future.value();
  int _sequence = 0;

  Future<void> get drained => _tail;

  @override
  Future<List<int>?> read() async {
    await _tail;
    return await file.exists() ? file.readAsBytes() : null;
  }

  @override
  Future<void> writeAtomically(List<int> bytes) {
    final operation = _tail.then((_) async {
      if (!owns()) throw const OutboxFencedException();
      await file.parent.create(recursive: true);
      final staged = File('${file.path}.tmp-$pid-${_sequence++}');
      try {
        await staged.writeAsBytes(bytes, flush: true);
        if (!owns()) throw const OutboxFencedException();
        // Synchronous rename closes the fence-check/commit interleaving window.
        staged.renameSync(file.path);
      } finally {
        if (await staged.exists()) await staged.delete();
      }
    });
    _tail = operation.catchError((Object _) {});
    return operation;
  }
}
