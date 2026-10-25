import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// Playback resume offsets, kept apart from transcripts and attachments.
///
/// The default root is Android's app-private files directory. The app excludes
/// that domain from cloud backup and device transfer; this store additionally
/// keeps all of its files in one directory so [clear] never touches chat text.
/// Only message ids and UTF-16 character offsets are persisted, never answer
/// text, recorded audio or synthesized audio.
class VoiceCacheStore {
  VoiceCacheStore({Future<Directory> Function()? rootDirectory})
    : _rootDirectory = rootDirectory ?? getApplicationSupportDirectory;

  final Future<Directory> Function() _rootDirectory;
  Future<void> _tail = Future<void>.value();

  Future<Directory> _directory() async =>
      Directory('${(await _rootDirectory()).path}/voice-cache');

  Future<File> _file() async =>
      File('${(await _directory()).path}/playback.json');

  Future<T> _serial<T>(Future<T> Function() action) {
    final result = _tail.then((_) => action());
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  Future<Map<String, int>> _read() async {
    final file = await _file();
    if (!await file.exists()) return <String, int>{};
    try {
      final contents = await file.readAsString();
      if (contents.length > 64 * 1024) return <String, int>{};
      final decoded = jsonDecode(contents);
      if (decoded is! Map) return <String, int>{};
      return <String, int>{
        for (final entry in decoded.entries)
          if (entry.key is String && entry.value is int && entry.value >= 0)
            entry.key as String: entry.value as int,
      };
    } on FormatException {
      return <String, int>{};
    } on IOException {
      return <String, int>{};
    }
  }

  Future<void> savePosition({
    required String messageId,
    required int character,
  }) {
    if (messageId.isEmpty || character < 0) {
      return Future<void>.error(ArgumentError('Invalid playback position'));
    }
    return _serial(() async {
      final rows = await _read();
      rows[messageId] = character;
      final file = await _file();
      await file.parent.create(recursive: true);
      await file.writeAsString(jsonEncode(rows), flush: true);
    });
  }

  Future<int?> positionFor(String messageId) =>
      _serial(() async => (await _read())[messageId]);

  Future<void> removePosition(String messageId) => _serial(() async {
    final rows = await _read()
      ..remove(messageId);
    final file = await _file();
    if (rows.isEmpty) {
      if (await file.exists()) await file.delete();
      return;
    }
    await file.parent.create(recursive: true);
    await file.writeAsString(jsonEncode(rows), flush: true);
  });

  /// Clears voice state only. Chat databases and transcript files are outside
  /// this directory and are deliberately not opened here.
  Future<void> clear() => _serial(() async {
    final directory = await _directory();
    if (await directory.exists()) await directory.delete(recursive: true);
  });
}
