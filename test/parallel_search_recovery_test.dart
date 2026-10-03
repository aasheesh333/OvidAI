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

SearchSession session(String id, String body) =>
    (id: id, model: 'model', rows: [(role: 'user', content: body)]);

void main() {
  if (Platform.isLinux) {
    open.overrideFor(
      OperatingSystem.linux,
      () => ffi.DynamicLibrary.open('libsqlite3.so.0'),
    );
  }
  final search = SessionSearch.I;
  late Directory root;
  late String path;

  setUp(() {
    root = Directory.systemTemp.createTempSync('parallel-search-');
    path = '${root.path}/index.db';
    SessionSearch.dbPathOverrideForTest = path;
  });

  tearDown(() async {
    await search.close();
    SessionSearch.dbPathOverrideForTest = null;
    root.deleteSync(recursive: true);
  });

  test('concurrent failed opens recover after a real SQLite lock', () async {
    final blocker = sqlite3.open(path);
    try {
      blocker.execute('BEGIN EXCLUSIVE');
      await Future.wait([
        expectLater(search.search('needle'), throwsA(isA<SqliteException>())),
        expectLater(search.reindex([]), throwsA(isA<SqliteException>())),
      ]);
      blocker.execute('ROLLBACK');
      await search.reindex([session('recovered', 'needle')]);
      expect((await search.search('needle')).single.sessionId, 'recovered');
    } finally {
      blocker.dispose();
    }
  });

  test(
    'failed native open retries after its parent directory is restored',
    () async {
      SessionSearch.dbPathOverrideForTest = '${root.path}/restored/index.db';
      await expectLater(search.reindex([]), throwsA(isA<SqliteException>()));
      Directory('${root.path}/restored').createSync();
      await search.reindex([session('retry-open', 'needle')]);
      expect((await search.search('needle')).single.sessionId, 'retry-open');
    },
  );

  test('a failed second insert rolls back and releases the writer', () async {
    final observer = sqlite3.open(path);
    try {
      observer.execute(
        'CREATE TABLE msgs(sessionId, model, role, body UNIQUE)',
      );
      observer.execute("INSERT INTO msgs VALUES ('old', 'm', 'user', 'saved')");
      await expectLater(
        search.reindex([session('a', 'duplicate'), session('b', 'duplicate')]),
        throwsA(isA<SqliteException>()),
      );
      observer.execute('BEGIN IMMEDIATE');
      observer.execute('COMMIT');
      expect(observer.select('SELECT body FROM msgs').single['body'], 'saved');
      await search.reindex([session('retry', 'replacement')]);
      expect(
        observer.select('SELECT sessionId FROM msgs').single['sessionId'],
        'retry',
      );
    } finally {
      observer.dispose();
    }
  });

  test('a superseded rebuild never consumes its stale snapshot', () async {
    var consumed = false;
    Iterable<SearchSession> stale() sync* {
      consumed = true;
      yield session('old', 'needle');
    }

    final old = search.reindex(stale());
    final latest = search.reindex([session('new', 'needle')]);
    await Future.wait([old, latest]);
    expect(consumed, isFalse);
    expect((await search.search('needle')).single.sessionId, 'new');
  });

  test(
    'pagination rejects oversized pages and offsets before opening',
    () async {
      SessionSearch.dbPathOverrideForTest = '${root.path}/missing/index.db';
      await expectLater(search.search('needle', limit: 101), throwsRangeError);
      await expectLater(
        search.search('needle', cursor: 100001),
        throwsRangeError,
      );
    },
  );

  test('oversized queries are rejected before opening', () async {
    SessionSearch.dbPathOverrideForTest = '${root.path}/missing/index.db';
    await expectLater(search.search('x' * 4097), throwsRangeError);
  });

  test(
    'rank ties page consistently after snapshot enumeration changes',
    () async {
      await search.reindex([session('b', 'needle'), session('a', 'needle')]);
      final first = (await search.search('needle', limit: 1)).single.sessionId;
      await search.reindex([session('a', 'needle'), session('b', 'needle')]);
      expect((await search.search('needle', limit: 1)).single.sessionId, first);
      expect(
        (await search.search('needle', limit: 1, cursor: 1)).single.sessionId,
        'b',
      );
    },
  );

  test('maximum page size remains bounded with a real larger index', () async {
    await search.reindex([
      for (var i = 0; i < 105; i++)
        session('row-${i.toString().padLeft(3, '0')}', 'needle'),
    ]);
    final first = await search.search('needle', limit: 100);
    final last = await search.search('needle', limit: 100, cursor: 100);
    expect(first, hasLength(100));
    expect(last.map((hit) => hit.sessionId), [
      'row-100',
      'row-101',
      'row-102',
      'row-103',
      'row-104',
    ]);
    expect(await search.search('needle', cursor: 100000), isEmpty);
    await expectLater(search.search('needle', limit: 101), throwsRangeError);
  });

  test(
    'literal Unicode, punctuation and embedded NUL never become MATCH grammar',
    () async {
      await search.reindex([
        session('literal', 'café OR 東京'),
        session('phrase', 'red fox'),
        session('apart', 'red quick fox'),
      ]);
      expect((await search.search('café OR 東京')).single.sessionId, 'literal');
      expect((await search.search('"red fox"')).single.sessionId, 'phrase');
      expect(
        (await search.search('red\u0000fox')).map((hit) => hit.sessionId),
        unorderedEquals(['phrase', 'apart']),
      );
      for (final query in ['*', '"', '()', ':', '\u0000', ' \n\t ']) {
        expect(await search.search(query), isEmpty, reason: query);
      }
    },
  );

  test(
    'delete fences a pending rebuild and tombstones later stale rows',
    () async {
      await search.reindex([
        session('deleted', 'needle'),
        session('kept', 'needle'),
      ]);
      final token = search.generation;
      final pending = search.reindex([session('deleted', 'replacement')]);
      final deletion = search.deleteSession('deleted');
      expect(await pending, isNull);
      await deletion;
      expect((await search.search('needle')).single.sessionId, 'kept');
      expect(
        await search.reindex([
          session('deleted', 'resurrect'),
        ], expectedGeneration: token),
        isNull,
      );
      await search.reindex([
        session('deleted', 'resurrect'),
        session('kept', 'needle'),
      ]);
      expect(await search.search('resurrect'), isEmpty);
      final observer = sqlite3.open(path);
      try {
        expect(
          observer.select("SELECT * FROM msgs WHERE sessionId = 'deleted'"),
          isEmpty,
        );
      } finally {
        observer.dispose();
      }
    },
  );

  test(
    'deletion during lazy snapshot iteration rolls back partial inserts',
    () async {
      await search.reindex([
        session('deleted-during', 'needle'),
        session('kept', 'needle'),
      ]);
      late Future<void> deletion;
      Iterable<SearchSession> deletingSnapshot() sync* {
        yield session('partial', 'replacement');
        deletion = search.deleteSession('deleted-during');
        yield session('deleted-during', 'resurrect');
      }

      expect(await search.reindex(deletingSnapshot()), isNull);
      await deletion;
      expect((await search.search('needle')).single.sessionId, 'kept');
      expect(await search.search('replacement'), isEmpty);
      expect(await search.search('resurrect'), isEmpty);
    },
  );

  test(
    'overlapping deletions remove every tombstone before reads resume',
    () async {
      await search.reindex([
        session('overlap-a', 'needle'),
        session('overlap-b', 'needle'),
        session('kept', 'needle'),
      ]);
      await Future.wait([
        search.deleteSession('overlap-a'),
        search.deleteSession('overlap-b'),
      ]);
      expect((await search.search('needle')).single.sessionId, 'kept');
    },
  );

  test(
    'a failed delete hides old rows and a retry releases the fence',
    () async {
      await search.reindex([
        session('failed-delete', 'needle'),
        session('kept', 'needle'),
      ]);
      final blocker = sqlite3.open(path);
      try {
        blocker.execute('BEGIN IMMEDIATE');
        await expectLater(
          search.deleteSession('failed-delete'),
          throwsA(isA<SqliteException>()),
        );
        expect(await search.search('needle'), isEmpty);
        blocker.execute('ROLLBACK');
        await search.deleteSession('failed-delete');
        expect((await search.search('needle')).single.sessionId, 'kept');
      } finally {
        blocker.dispose();
      }
    },
  );

  test(
    'account replacement fences in-flight reads and old snapshot tokens',
    () async {
      await search.setAccount('account-a');
      final oldToken = await search.reindex([
        session('same-id', 'private alpha'),
      ]);
      final pendingRead = search.search(
        'private',
        expectedGeneration: oldToken,
      );
      final transition = search.setAccount('account-b');
      expect(await pendingRead, isEmpty);
      await transition;
      expect(await search.search('private'), isEmpty);
      expect(
        await search.reindex([
          session('same-id', 'private alpha'),
        ], expectedGeneration: oldToken),
        isNull,
      );
      final currentToken = await search.reindex([
        session('same-id', 'private beta'),
      ]);
      expect(
        await search.search('alpha', expectedGeneration: currentToken),
        isEmpty,
      );
      expect(
        (await search.search(
          'beta',
          expectedGeneration: currentToken,
        )).single.sessionId,
        'same-id',
      );
      await search.deleteSession('same-id', expectedGeneration: oldToken);
      expect((await search.search('beta')).single.sessionId, 'same-id');
    },
  );

  test('failed account clearing can retry for the same identity', () async {
    await search.reindex([session('old', 'private')]);
    final blocker = sqlite3.open(path);
    try {
      blocker.execute('BEGIN IMMEDIATE');
      await expectLater(
        search.setAccount('retry-account'),
        throwsA(isA<SqliteException>()),
      );
      expect(await search.search('private'), isEmpty);
      blocker.execute('ROLLBACK');
      await search.setAccount('retry-account');
      expect(blocker.select('SELECT * FROM msgs'), isEmpty);
    } finally {
      blocker.dispose();
    }
  });

  test('generation-bound pages cannot read a rebuilt snapshot', () async {
    final token = await search.reindex([
      session('a', 'needle'),
      session('b', 'needle'),
    ]);
    expect(
      (await search.search(
        'needle',
        limit: 1,
        expectedGeneration: token,
      )).single.sessionId,
      'a',
    );
    await search.reindex([session('c', 'needle'), session('d', 'needle')]);
    expect(
      await search.search(
        'needle',
        limit: 1,
        cursor: 1,
        expectedGeneration: token,
      ),
      isEmpty,
    );
  });

  test(
    'clear fences a waiting rebuild and remains unreadable until rebuilt',
    () async {
      await search.reindex([session('old', 'needle')]);
      final pending = search.reindex([session('late', 'needle')]);
      final clearing = search.clear();
      expect(await pending, isNull);
      await clearing;
      expect(await search.search('needle'), isEmpty);
      await search.reindex([session('new', 'needle')]);
      expect((await search.search('needle')).single.sessionId, 'new');
    },
  );

  test(
    'close fences a waiting rebuild without losing committed rows',
    () async {
      await search.reindex([session('saved', 'needle')]);
      final pending = search.reindex([session('late', 'needle')]);
      await search.close();
      expect(await pending, isNull);
      expect((await search.search('needle')).single.sessionId, 'saved');
    },
  );

  test(
    'advanced MATCH is explicit and malformed input stays recoverable',
    () async {
      await search.reindex([
        session('a', 'red fox'),
        session('b', 'blue bird'),
      ]);
      expect(await search.search('red OR blue'), isEmpty);
      expect(
        (await search.search(
          'red OR blue',
          advanced: true,
        )).map((hit) => hit.sessionId),
        unorderedEquals(['a', 'b']),
      );
      expect(
        (await search.search('red NOT blue', advanced: true)).single.sessionId,
        'a',
      );
      for (final query in [
        '"red',
        'red OR',
        '(',
        '*',
        'missing:red',
        'NEAR(red, nope)',
        'NEAR()',
        'AND',
        'red\u0000fox',
        '""',
      ]) {
        expect(
          await search.search(query, advanced: true),
          isEmpty,
          reason: query,
        );
      }
      expect((await search.search('blue')).single.sessionId, 'b');
    },
  );

  test(
    'malformed MATCH handling never masks structural database failures',
    () async {
      final observer = sqlite3.open(path);
      try {
        observer.execute('CREATE TABLE msgs(sessionId, model, role, body)');
        await expectLater(
          search.search('red', advanced: true),
          throwsA(isA<SqliteException>()),
        );
      } finally {
        observer.dispose();
      }
    },
  );
}
