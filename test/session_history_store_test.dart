import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/session_history_store.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqlite3/open.dart';

const key = 'ovid_sessions';

String chat(String id, List<String> bodies, {String? title}) => jsonEncode({
  'id': id,
  'title': title ?? 'Chat $id',
  'model': 'm',
  'sandboxId': id,
  'mode': 'auto',
  'messages': [
    for (var i = 0; i < bodies.length; i++)
      {
        'role': i.isEven ? 'user' : 'assistant',
        'kind': 'text',
        'content': bodies[i],
        'time': DateTime.utc(2026, 1, 1, 0, 0, i).toIso8601String(),
      },
  ],
  'createdAt': DateTime.utc(2026).toIso8601String(),
});

void main() {
  if (Platform.isLinux) {
    open.overrideFor(
      OperatingSystem.linux,
      () => ffi.DynamicLibrary.open('libsqlite3.so.0'),
    );
  }

  late Directory root;
  late String path;
  final opened = <SessionHistoryRepository>[];

  /// A fresh repository models a new app process on the same disk.
  SessionHistoryRepository process({bool sqlite = true}) {
    final repo = SessionHistoryRepository.forTest();
    if (sqlite) {
      repo.enableSqlite(path: path, backgroundSearch: false);
    } else {
      repo.disableSqlite(path: path);
    }
    opened.add(repo);
    return repo;
  }

  Future<SharedPreferences> seed(List<String>? rows) async {
    SharedPreferences.setMockInitialValues({key: ?rows});
    return SharedPreferences.getInstance();
  }

  setUp(() {
    root = Directory.systemTemp.createTempSync('history-store-');
    path = '${root.path}/history.db';
  });

  tearDown(() async {
    for (final repo in opened) {
      await repo.close();
    }
    opened.clear();
    root.deleteSync(recursive: true);
  });

  test('fresh install: nothing to migrate, writes land in SQLite', () async {
    final prefs = await seed(null);
    final repo = process();
    expect(await repo.readRows(prefs, key), isNull);
    expect(prefs.getStringList(SessionHistoryRepository.migratedMarkerKey), [
      key,
    ]);
    expect(
      await repo.writeRows(prefs, key, [
        chat('a', ['hi']),
      ]),
      isTrue,
    );
    expect(prefs.getStringList(key), isNull, reason: 'no prefs blob');
    final next = process();
    expect(await next.readRows(prefs, key), [
      chat('a', ['hi']),
    ]);
  });

  test(
    'upgrade with N chats migrates verbatim and re-run is idempotent',
    () async {
      final rows = [
        for (var i = 0; i < 250; i++) chat('s$i', ['question $i', 'answer $i']),
      ];
      final prefs = await seed(rows);
      final repo = process();
      expect(await repo.readRows(prefs, key), rows);
      final report = repo.migrationReports.single;
      expect(report.sourceRows, 250);
      expect(report.imported, 250);
      expect(report.quarantined, isEmpty);
      expect(report.checksum, hasLength(64));
      expect(prefs.getStringList(key), isNull, reason: 'blob removed last');

      final again = process();
      expect(await again.readRows(prefs, key), rows);
      expect(again.migrationReports, isEmpty, reason: 'no second migration');
    },
  );

  for (final stage in ['import', 'imported', 'verified', 'marked']) {
    test(
      'migration killed at "$stage" resumes without losing a chat',
      () async {
        final rows = [
          for (var i = 0; i < 120; i++) chat('k$i', ['body $i']),
        ];
        final prefs = await seed(rows);
        final crashing = process()
          ..migrationFaultForTest = (s, {index}) {
            if (s == stage && (index == null || index == 60)) {
              throw SimulatedCrash(s);
            }
          };
        await expectLater(
          crashing.readRows(prefs, key),
          throwsA(isA<SimulatedCrash>()),
        );
        await crashing.close();
        if (stage == 'import' || stage == 'imported' || stage == 'verified') {
          expect(prefs.getStringList(key), rows, reason: 'blob kept');
        }
        if (stage == 'import' || stage == 'imported') {
          expect(
            prefs.getStringList(SessionHistoryRepository.migratedMarkerKey),
            isNull,
          );
        }
        final resumed = process();
        expect(await resumed.readRows(prefs, key), rows);
        expect(prefs.getStringList(key), isNull);
        expect(
          prefs.getStringList(SessionHistoryRepository.migratedMarkerKey),
          [key],
        );
        // And the next process reads the same history again.
        expect(await process().readRows(prefs, key), rows);
      },
    );
  }

  test(
    'corrupt JSON rows are skipped, reported and kept in quarantine',
    () async {
      final good = chat('good', ['fine']);
      final source = [
        '{"id":"broken", "title": ',
        good,
        '[1,2,3]',
        chat('good', ['duplicate copy']),
        jsonEncode({'title': 'no id'}),
      ];
      final prefs = await seed(source);
      final repo = process();
      expect(await repo.readRows(prefs, key), [good]);
      final report = repo.migrationReports.single;
      expect(report.sourceRows, 5);
      expect(report.imported, 1);
      expect(report.quarantined.map((q) => q.index), [0, 2, 3, 4]);
      expect(report.quarantined.map((q) => q.reason), [
        'invalid JSON',
        'not a JSON object',
        'duplicate session id',
        'missing session id',
      ]);
      final kept = await repo.quarantined(key);
      expect(kept.map((q) => q.raw), [
        source[0],
        source[2],
        source[3],
        source[4],
      ]);
    },
  );

  test('leftover blob from an older build is merged, never dropped', () async {
    final prefs = await seed([
      chat('a', ['one']),
    ]);
    final repo = process();
    await repo.readRows(prefs, key);
    await repo.writeRows(prefs, key, [
      chat('a', ['one', 'two']),
    ]);
    await repo.close();
    // A downgraded build wrote a new chat (and a stale copy of "a").
    await prefs.setStringList(key, [
      chat('a', ['one']),
      chat('b', ['new on old build']),
    ]);
    final next = process();
    expect(await next.readRows(prefs, key), [
      chat('a', ['one', 'two']),
      chat('b', ['new on old build']),
    ]);
    expect(prefs.getStringList(key), isNull);
    expect(
      (await next.quarantined(key)).single.reason,
      'superseded legacy copy',
    );
  });

  test('incremental writes: update, reorder, delete and opaque rows', () async {
    final prefs = await seed(null);
    final repo = process();
    await repo.readRows(prefs, key);
    final a = chat('a', ['alpha apples']);
    final b = chat('b', ['beta bananas']);
    const opaque = '{"not":"a session"}';
    await repo.writeRows(prefs, key, [a, b, opaque]);
    final b2 = chat('b', ['beta bananas', 'cherry']);
    await repo.writeRows(prefs, key, [b2, a, opaque]);
    expect(await process().readRows(prefs, key), [b2, a, opaque]);
    expect(
      (await repo.searchContent(prefs, key, 'cherry'))!.single.sessionId,
      'b',
    );
    await repo.writeRows(prefs, key, [a]);
    expect(await process().readRows(prefs, key), [a]);
    expect(await repo.searchContent(prefs, key, 'cherry'), isEmpty);
    expect(await repo.searchContent(prefs, key, 'banana'), isEmpty);
    expect(
      (await repo.searchContent(prefs, key, 'appl'))!.single.sessionId,
      'a',
    );
  });

  test('a namespace that was never loaded cannot be overwritten', () async {
    final prefs = await seed([
      chat('a', ['keep me']),
    ]);
    await process().readRows(prefs, key);
    final fresh = process();
    await expectLater(
      fresh.writeRows(prefs, key, [
        chat('new', ['x']),
      ]),
      throwsStateError,
    );
    expect(await process().readRows(prefs, key), [
      chat('a', ['keep me']),
    ]);
  });

  test('unopenable database before migration falls back to the blob', () async {
    final rows = [
      chat('a', ['legacy']),
    ];
    final prefs = await seed(rows);
    final repo = SessionHistoryRepository.forTest()
      ..enableSqlite(path: root.path, backgroundSearch: false); // a directory
    expect(await repo.readRows(prefs, key), rows);
    expect(
      await repo.writeRows(prefs, key, [
        ...rows,
        chat('b', ['n']),
      ]),
      isTrue,
    );
    expect(prefs.getStringList(key), hasLength(2));
    expect(await repo.searchContent(prefs, key, 'legacy'), isNull);
    expect(
      prefs.getStringList(SessionHistoryRepository.migratedMarkerKey),
      isNull,
    );
  });

  test('unopenable database after migration fails closed', () async {
    final prefs = await seed([
      chat('a', ['x']),
    ]);
    await process().readRows(prefs, key);
    final repo = SessionHistoryRepository.forTest()
      ..enableSqlite(path: root.path, backgroundSearch: false);
    await expectLater(repo.readRows(prefs, key), throwsA(anything));
    await expectLater(repo.writeRows(prefs, key, const []), throwsA(anything));
  });

  test('kill switch rolls history back to prefs and can re-migrate', () async {
    final prefs = await seed([
      chat('a', ['x']),
    ]);
    final repo = process();
    await repo.readRows(prefs, key);
    await repo.writeRows(prefs, key, [
      chat('a', ['x']),
      chat('b', ['y']),
    ]);
    await repo.close();

    final legacy = process(sqlite: false);
    expect(await legacy.readRows(prefs, key), [
      chat('a', ['x']),
      chat('b', ['y']),
    ]);
    expect(prefs.getStringList(key), hasLength(2));
    expect(
      prefs.getStringList(SessionHistoryRepository.migratedMarkerKey),
      isNull,
    );
    await legacy.writeRows(prefs, key, [
      chat('c', ['z']),
    ]);
    await legacy.close();

    expect(await process().readRows(prefs, key), [
      chat('c', ['z']),
    ]);
  });

  test(
    'FTS search over 10k messages is fast and highlights the match',
    () async {
      final prefs = await seed(null);
      final repo = SessionHistoryRepository.forTest()
        ..enableSqlite(path: path); // background isolate search
      opened.add(repo);
      await repo.readRows(prefs, key);
      final rows = [
        for (var s = 0; s < 100; s++)
          chat('s$s', [
            for (var m = 0; m < 100; m++)
              s == 42 && m == 77
                  ? 'the zanzibar protocol uses quaternions'
                  : 'message $m of session $s about ordinary things',
          ]),
      ];
      await repo.writeRows(prefs, key, rows);
      final watch = Stopwatch()..start();
      final hits = (await repo.searchContent(prefs, key, 'zanzibar quatern'))!;
      watch.stop();
      expect(hits.single.sessionId, 's42');
      expect(hits.single.messageIndex, 77);
      expect(
        hits.single.snippet,
        contains('${SessionHistoryRepository.highlightStart}zanzibar'),
      );
      expect(watch.elapsedMilliseconds, lessThan(1500));
      final many = (await repo.searchContent(
        prefs,
        key,
        'ordinary',
        limit: 30,
      ))!;
      expect(many, hasLength(30));
      expect(many.map((h) => h.sessionId).toSet(), hasLength(30));
      expect(await repo.searchContent(prefs, key, 'OR NOT "'), isEmpty);
    },
  );

  test('deleteAll wipes every namespace', () async {
    final prefs = await seed([
      chat('a', ['x']),
    ]);
    final repo = process();
    await repo.readRows(prefs, key);
    await repo.deleteAll();
    expect(await process().readRows(prefs, key), isNull);
  });
}
