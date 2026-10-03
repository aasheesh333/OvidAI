import 'dart:ffi' as ffi;
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/session_search.dart';
import 'package:sqlite3/open.dart';
import 'package:sqlite3/sqlite3.dart';

typedef SearchSession = ({
  String id,
  String model,
  List<({String role, String content})> rows,
});

SearchSession session(String id, String body, {String model = 'm'}) => (
  id: id,
  model: model,
  rows: [(role: 'user', content: body)],
);

Iterable<SearchSession> interruptedSessions() sync* {
  yield session('partial', 'replacement');
  throw StateError('source iteration failed');
}

void main() {
  if (Platform.isLinux) {
    open.overrideFor(
      OperatingSystem.linux,
      () => ffi.DynamicLibrary.open('libsqlite3.so.0'),
    );
  }
  late Directory root;
  late String path;
  final search = SessionSearch.I;

  setUp(() {
    root = Directory.systemTemp.createTempSync('search-recovery-');
    path = '${root.path}/search.db';
    SessionSearch.dbPathOverrideForTest = path;
  });

  tearDown(() async {
    await search.close();
    SessionSearch.dbPathOverrideForTest = null;
    root.deleteSync(recursive: true);
  });

  test('failed opening can retry after the database lock is released', () async {
    final blocker = sqlite3.open(path);
    try {
      blocker.execute('BEGIN EXCLUSIVE');
      await expectLater(search.reindex([]), throwsA(isA<SqliteException>()));
      blocker.execute('ROLLBACK');
      await search.reindex([session('recovered', 'needle')]);
      expect((await search.search('needle')).single.sessionId, 'recovered');
    } finally {
      blocker.dispose();
    }
  });

  test('failed schema initialization releases its database handle', () async {
    final blocker = sqlite3.open(path);
    try {
      blocker.execute('BEGIN EXCLUSIVE');
      await expectLater(search.reindex([]), throwsA(isA<SqliteException>()));
    } finally {
      blocker.dispose();
    }
    expect(openDatabaseDescriptors(path), isEmpty);
  }, skip: !Platform.isLinux);

  test('corrupt index reports failure and preserves its original bytes', () async {
    final file = File(path)..writeAsStringSync('damaged database to inspect');
    final original = file.readAsBytesSync();
    await expectLater(search.reindex([]), throwsA(isA<SqliteException>()));
    expect(file.readAsBytesSync(), original);
    if (Platform.isLinux) expect(openDatabaseDescriptors(path), isEmpty);
  });

  test('close releases the handle, preserves data, and permits reopening', () async {
    await search.reindex([session('saved', 'needle')]);
    await search.close();
    expect(File(path).existsSync(), isTrue);
    if (Platform.isLinux) expect(openDatabaseDescriptors(path), isEmpty);
    expect((await search.search('needle')).single.sessionId, 'saved');
  });

  test('reindex rolls back partial rows when the source iterable throws', () async {
    await search.reindex([session('old', 'original')]);
    await expectLater(search.reindex(interruptedSessions()), throwsStateError);
    expect((await search.search('original')).single.sessionId, 'old');
    expect(await search.search('replacement'), isEmpty);
    await search.reindex([session('new', 'replacement')]);
    expect((await search.search('replacement')).single.sessionId, 'new');
  });

  test('reindex rolls back DELETE if preparing INSERT fails', () async {
    final inspector = sqlite3.open(path);
    try {
      inspector.execute('CREATE TABLE msgs(sessionId, model, body)');
      inspector.execute("INSERT INTO msgs VALUES ('old', 'm', 'original')");
      await expectLater(
        search.reindex([session('new', 'replacement')]),
        throwsA(isA<SqliteException>()),
      );
      // An abandoned transaction would keep the writer lock and fail this.
      inspector.execute('BEGIN IMMEDIATE');
      inspector.execute('ALTER TABLE msgs ADD COLUMN role');
      inspector.execute('COMMIT');
      expect(inspector.select('SELECT body FROM msgs').single['body'], 'original');
      await search.reindex([session('new', 'replacement')]);
      expect(inspector.select('SELECT body FROM msgs').single['body'], 'replacement');
    } finally {
      inspector.dispose();
    }
  });

  test('reindex rolls back on an INSERT constraint error', () async {
    final inspector = sqlite3.open(path);
    try {
      inspector.execute('CREATE TABLE msgs(sessionId, model, role, body UNIQUE)');
      inspector.execute("INSERT INTO msgs VALUES ('old', 'm', 'user', 'original')");
      await expectLater(
        search.reindex([session('a', 'duplicate'), session('b', 'duplicate')]),
        throwsA(isA<SqliteException>()),
      );
      inspector.execute('BEGIN IMMEDIATE');
      inspector.execute('COMMIT');
      expect(inspector.select('SELECT body FROM msgs').single['body'], 'original');
      await search.reindex([session('new', 'replacement')]);
      expect(inspector.select('SELECT body FROM msgs').single['body'], 'replacement');
    } finally {
      inspector.dispose();
    }
  });

  test('reindex rolls back when a reader prevents COMMIT', () async {
    await search.reindex([session('old', 'original')]);
    final reader = sqlite3.open(path);
    try {
      reader.execute('BEGIN');
      reader.select('SELECT * FROM msgs'); // Hold a real SQLite shared lock.
      await expectLater(
        search.reindex([session('new', 'replacement')]),
        throwsA(isA<SqliteException>()),
      );
      reader.execute('ROLLBACK');
      expect((await search.search('original')).single.sessionId, 'old');
      expect(await search.search('replacement'), isEmpty);
      await search.reindex([session('new', 'replacement')]);
      expect((await search.search('replacement')).single.sessionId, 'new');
    } finally {
      reader.dispose();
    }
  });

  test('literal terms preserve AND and explicit phrase semantics', () async {
    await search.reindex([
      session('phrase', 'red fox'),
      session('apart', 'red quick fox'),
      session('operator', 'red OR fox'),
      session('punctuation', 'error-code: failed'),
    ]);
    expect(
      (await search.search('red fox')).map((h) => h.sessionId),
      unorderedEquals(['phrase', 'apart', 'operator']),
    );
    expect((await search.search('"red fox"')).single.sessionId, 'phrase');
    expect((await search.search('red OR fox')).single.sessionId, 'operator');
    expect((await search.search('error-code:')).single.sessionId, 'punctuation');
    expect((await search.search('"red')).map((h) => h.sessionId), hasLength(3));
    expect(await search.search('*'), isEmpty);
    expect(await search.search(' \t\n '), isEmpty);
  });

  test('negative limit and cursor are rejected, zero limit is empty', () async {
    await search.reindex([session('s', 'needle')]);
    await expectLater(search.search('needle', limit: -1), throwsRangeError);
    await expectLater(search.search('needle', cursor: -1), throwsRangeError);
    expect(await search.search('needle', limit: 0), isEmpty);
  });

  test('filters, snippets and offset pagination remain compatible', () async {
    await search.reindex([
      session('a', 'needle', model: 'first'),
      session('b', 'needle', model: 'second'),
      session('c', 'needle', model: 'second'),
    ]);
    final all = await search.search('needle');
    final page = await search.search('needle', limit: 1, cursor: 1);
    expect(page.single.sessionId, all[1].sessionId);
    expect(page.single.role, 'user');
    expect(page.single.snippet, contains('→needle←'));
    expect((await search.search('needle', sessionId: 'b')).single.sessionId, 'b');
    expect(
      (await search.search('needle', model: 'second')).map((h) => h.sessionId),
      unorderedEquals(['b', 'c']),
    );
    expect(await search.search('needle', cursor: 3), isEmpty);
  });
}

List<String> openDatabaseDescriptors(String path) => [
  for (final entry in Directory('/proc/self/fd').listSync())
    if (_target(entry.path) == path) entry.path,
];

String? _target(String path) {
  try {
    return Link(path).targetSync();
  } on FileSystemException {
    return null; // The directory iterator's own descriptor may have closed.
  }
}
