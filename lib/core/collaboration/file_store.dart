import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'store.dart';

/// A durable collaboration record stored as one account-owned JSON file.
///
/// Writes are serialized per backend and committed by renaming a temporary
/// file in the record's directory. The old record therefore remains intact
/// if encoding or replacement fails. The account fence is checked on every
/// read, write, and clear so an account handoff cannot expose or remove a
/// different account's record.
class FileCollaborationStoreBackend implements GuardedCollaborationStoreBackend {
  FileCollaborationStoreBackend(this.file, {required this.ownerFence});

  final File file;
  final String ownerFence;
  Future<void> _tail = Future<void>.value();
  int _temporaryFileId = 0;

  @override
  Future<Map<String, Object?>?> read() => _enqueue(() async {
    if (!await file.exists()) return null;
    try {
      final decoded = jsonDecode(await file.readAsString());
      final record = _asRecord(decoded);
      _checkOwner(record);
      return record;
    } on CollaborationStoreException {
      rethrow;
    } catch (_) {
      throw const CollaborationStoreException('invalid collaboration record');
    }
  });

  @override
  Future<void> write(Map<String, Object?> record) => writeGuarded(record, () => true);

  @override
  Future<void> writeGuarded(Map<String, Object?> record, bool Function() owns) => _enqueue(() async {
    if (!owns()) return;
    _checkOwner(record);
    final encoded = _encode(record);
    final parent = file.parent;
    await parent.create(recursive: true);
    final temporary = File('${file.path}.tmp-$pid-${_temporaryFileId++}');
    try {
      await temporary.writeAsBytes(
        Uint8List.fromList(utf8.encode(encoded)),
        flush: true,
      );
      if (!owns()) {
        await temporary.delete();
        return;
      }
      // No asynchronous gap between the authority check and publication.
      temporary.renameSync(file.path);
    } catch (error) {
      try {
        if (await temporary.exists()) await temporary.delete();
      } catch (_) {
        // Preserve the original persistence failure.
      }
      if (error is CollaborationStoreException) rethrow;
      throw const CollaborationStoreException('persistence failed');
    }
  });

  @override
  Future<void> clear() => _enqueue(() async {
    if (!await file.exists()) return;
    try {
      final record = _asRecord(jsonDecode(await file.readAsString()));
      _checkOwner(record);
      await file.delete();
    } on CollaborationStoreException {
      rethrow;
    } catch (_) {
      throw const CollaborationStoreException('persistence failed');
    }
  });

  Future<T> _enqueue<T>(Future<T> Function() operation) {
    final result = Completer<T>();
    final previous = _tail;
    _tail = previous.then<void>((_) async {
      try {
        result.complete(await operation());
      } catch (error, stackTrace) {
        result.completeError(error, stackTrace);
      }
    });
    return result.future;
  }

  String _encode(Map<String, Object?> record) {
    try {
      return jsonEncode(record);
    } catch (_) {
      throw const CollaborationStoreException('persistence failed');
    }
  }

  Map<String, Object?> _asRecord(Object? value) {
    if (value is! Map) {
      throw const CollaborationStoreException('invalid collaboration record');
    }
    final record = <String, Object?>{};
    for (final entry in value.entries) {
      if (entry.key is! String) {
        throw const CollaborationStoreException('invalid collaboration record');
      }
      record[entry.key as String] = entry.value;
    }
    return record;
  }

  void _checkOwner(Map<String, Object?> record) {
    if (record['accountId'] != ownerFence) {
      throw const CollaborationStoreException('owner fence mismatch');
    }
  }
}
