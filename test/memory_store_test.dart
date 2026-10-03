import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/memory_store.dart';

void main() {
  late Directory dir;
  late MemoryStore store;
  setUp(() {
    dir = Directory.systemTemp.createTempSync('ovid-memory-test-');
    store = MemoryStore(dir);
  });
  tearDown(() => dir.deleteSync(recursive: true));

  test('Markdown survives restart; global shared and session isolated', () {
    store.save(null, 'MEMORY.md', 'Prefer concise answers', mode: 'append');
    store.save('chat-a', 'MEMORY.md', 'Private project', mode: 'append');
    store.save('chat-a', 'details.md', 'Extra detail', mode: 'create');
    final restarted = MemoryStore(dir);
    expect(restarted.context('chat-a'), contains('Private project'));
    expect(restarted.context('chat-b'), contains('Prefer concise answers'));
    expect(restarted.context('chat-b'), isNot(contains('Private project')));
    expect(restarted.context('chat-a'), contains('details.md'));
    expect(restarted.context('chat-a'), isNot(contains('Extra detail')));
    expect(restarted.read('chat-a', 'details.md').content, 'Extra detail');
  });

  test('imports and stale edits cannot overwrite user memory', () {
    store.save(null, 'notes.md', 'Original', mode: 'create');
    final before = store.read(null, 'notes.md');
    store.save(
      null,
      'notes.md',
      'User edit',
      mode: 'replace',
      revision: before.revision,
    );
    expect(
      () => store.save(null, 'notes.md', 'Import', mode: 'create'),
      throwsStateError,
    );
    expect(
      () => store.save(null, 'NOTES.md', 'Import', mode: 'create'),
      throwsStateError,
    );
    expect(
      () => store.save(
        null,
        'notes.md',
        'Stale',
        mode: 'replace',
        revision: before.revision,
      ),
      throwsStateError,
    );
    expect(MemoryStore(dir).read(null, 'notes.md').content, 'User edit');
  });

  test('paths, symlinks, file count and UTF8 sizes are bounded', () {
    for (final name in [
      '../escape.md',
      '/escape.md',
      r'..\escape.md',
      'a/b.md',
      'x.html',
      '.hidden.md',
    ]) {
      expect(
        () => store.save(null, name, 'x', mode: 'create'),
        throwsFormatException,
      );
    }
    expect(
      () => store.save(null, 'large.md', 'é' * 20000, mode: 'create'),
      throwsFormatException,
    );
    store.read(null, 'MEMORY.md');
    final outside = Directory.systemTemp.createTempSync('outside-memory-');
    try {
      File('${outside.path}/secret.md').writeAsStringSync('secret');
      Link(
        '${dir.path}/global/link.md',
      ).createSync('${outside.path}/secret.md');
      expect(
        () => store.read(null, 'link.md'),
        throwsA(isA<FileSystemException>()),
      );
      expect(
        () => store.save(null, 'link.md', 'changed', mode: 'append'),
        throwsA(isA<FileSystemException>()),
      );
      expect(File('${outside.path}/secret.md').readAsStringSync(), 'secret');
      Link('${dir.path}/global/link.md').deleteSync();
      for (var i = 0; i < MemoryStore.maxFiles - 1; i++) {
        store.save(null, 'f$i.md', 'x', mode: 'create');
      }
      expect(
        () => store.save(null, 'overflow.md', 'x', mode: 'create'),
        throwsStateError,
      );
    } finally {
      outside.deleteSync(recursive: true);
    }
  });

  test('context is bounded and deletion removes only its session', () {
    store.save(null, 'MEMORY.md', 'g' * 30000, mode: 'append');
    store.save('a', 'MEMORY.md', 'a' * 30000, mode: 'append');
    store.save('b', 'MEMORY.md', 'keep', mode: 'append');
    expect(
      store.context('a').length,
      lessThanOrEqualTo(MemoryStore.maxContextChars),
    );
    store.deleteSession('a');
    final restarted = MemoryStore(dir);
    expect(restarted.read('a', 'MEMORY.md').content, isEmpty);
    expect(restarted.read('b', 'MEMORY.md').content, 'keep');
    expect(restarted.read(null, 'MEMORY.md').content, hasLength(30000));
  });

  test('escaped global data cannot crowd session data out of context', () {
    store.save(null, 'MEMORY.md', '\u0001' * 30000, mode: 'append');
    store.save('a', 'MEMORY.md', 'Current session fact', mode: 'append');
    expect(store.context('a'), contains('Current session fact'));
    expect(
      store.context('a').length,
      lessThanOrEqualTo(MemoryStore.maxContextChars),
    );
  });

  test('symlinked scope and root cannot redirect saves outside memory', () {
    final outside = Directory.systemTemp.createTempSync('outside-root-');
    try {
      Link('${dir.path}/global').createSync(outside.path);
      expect(
        () => store.save(null, 'MEMORY.md', 'escape', mode: 'append'),
        throwsA(isA<FileSystemException>()),
      );
      expect(outside.listSync(), isEmpty);
      Link('${dir.path}/global').deleteSync();
      final link = Link('${dir.path}/linked-root')..createSync(outside.path);
      expect(
        () => MemoryStore(Directory(link.path)).read(null, 'MEMORY.md'),
        throwsA(isA<FileSystemException>()),
      );
    } finally {
      outside.deleteSync(recursive: true);
    }
  });

  test('oversized append fails atomically without leaving partial content', () {
    store.save(null, 'MEMORY.md', 'x' * 32000, mode: 'append');
    expect(
      () => store.save(null, 'MEMORY.md', 'y' * 1000, mode: 'append'),
      throwsFormatException,
    );
    expect(MemoryStore(dir).read(null, 'MEMORY.md').content, 'x' * 32000);
    expect(
      Directory(
        '${dir.path}/global',
      ).listSync().map((f) => f.uri.pathSegments.last),
      ['MEMORY.md'],
    );
  });
}
