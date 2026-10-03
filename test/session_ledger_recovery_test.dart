import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/session_ledger.dart';

void main() {
  late Directory root;
  const sid = 'recovery';
  late File file;

  setUp(() {
    root = Directory.systemTemp.createTempSync('ledger-recovery-');
    SessionLedger.rootOverrideForTest = root;
    file = File('${root.path}/$sid.jsonl');
  });

  tearDown(() async {
    await SessionLedger.I.close(sid);
    SessionLedger.rootOverrideForTest = null;
    root.deleteSync(recursive: true);
  });

  test('first concurrent appends recover highest durable sequence', () async {
    file.writeAsStringSync(
      '{"seq":8,"kind":"checkpoint"}\n'
      'bad complete line\n'
      '{"seq":3,"kind":"note"}\n',
    );
    await Future.wait([
      SessionLedger.I.append(sid, 'note', {'text': 'first'}),
      SessionLedger.I.append(sid, 'note', {'text': 'second'}),
    ]);
    final events = await SessionLedger.I.read(sid);
    expect(events.map((e) => e['seq']), [8, 3, 9, 10]);
    expect(events.last['text'], 'second');
    expect(SessionLedger.I.sinkOpensForTest[sid], 1);
  });

  for (final tail in [
    '{"seq":99,"kind":',
    '{"seq":12,"kind":"note"}',
    '\u{fffd}',
  ]) {
    test('non-newline tail preserves the first new event: $tail', () async {
      final original = '{"seq":7,"kind":"checkpoint"}\n$tail';
      file.writeAsStringSync(original);
      await SessionLedger.I.read(
        sid,
      ); // Recovery must also work with a warm cache.
      await SessionLedger.I.append(sid, 'note', {'text': 'first new event'});
      await SessionLedger.I.flush(sid);
      final bytes = file.readAsStringSync();
      expect(bytes, startsWith('$original\n'));
      final last = jsonDecode(file.readAsLinesSync().last) as Map;
      expect(last['text'], 'first new event');
      expect(last['seq'], tail.endsWith('}') ? 13 : 8);
      final events = await SessionLedger.I.read(sid);
      expect(events.last['seq'], last['seq']);
      expect(await SessionLedger.I.lastCheckpointSeq(sid), 7);
    });
  }

  test('invalid UTF-8 in a torn tail does not prevent recovery', () async {
    file.writeAsBytesSync([
      ...utf8.encode('{"seq":4,"kind":"checkpoint"}\n{"text":"'),
      0xe2,
      0x82,
    ]);
    await SessionLedger.I.append(sid, 'note', {'text': 'survived'});
    final events = await SessionLedger.I.read(sid);
    expect(events.map((e) => e['seq']), [4, 5]);
    expect(events.last['text'], 'survived');
  });

  test('failed sink opening can recover on the next append', () async {
    // The test root exists, but this session's ledger path is not writable
    // as a file until the obstructing directory is removed.
    Directory(file.path).createSync();
    await SessionLedger.I.append(sid, 'note', {'text': 'failed'});
    await SessionLedger.I.flush(sid);
    Directory(file.path).deleteSync();
    await SessionLedger.I.append(sid, 'note', {'text': 'recovered'});
    await SessionLedger.I.flush(sid);
    expect(file.existsSync(), isTrue);
    expect((await SessionLedger.I.read(sid)).single['text'], 'recovered');
  });

  test(
    'close waits for a pending first append and releases its descriptor',
    () async {
      final append = SessionLedger.I.append(sid, 'note', {'text': 'pending'});
      await SessionLedger.I.close(sid);
      await append;
      expect(file.existsSync(), isFalse);
      if (Platform.isLinux) {
        final targets = <String>[];
        for (final entry in Directory('/proc/self/fd').listSync()) {
          try {
            targets.add(Link(entry.path).targetSync());
          } on FileSystemException {
            // The iterator's descriptor can disappear before targetSync().
          }
        }
        expect(targets.where((p) => p.startsWith(file.path)), isEmpty);
      }
      await SessionLedger.I.append(sid, 'note', {'text': 'new lifetime'});
      expect((await SessionLedger.I.read(sid)).single['seq'], 1);
    },
  );

  test('queued close separates concurrent append lifetimes', () async {
    final before = SessionLedger.I.append(sid, 'note', {'text': 'old'});
    final flushBefore = SessionLedger.I.flush(sid);
    final close = SessionLedger.I.close(sid);
    final after = SessionLedger.I.append(sid, 'note', {'text': 'new'});
    final flushAfter = SessionLedger.I.flush(sid);
    final read = SessionLedger.I.read(sid);
    await Future.wait([before, flushBefore, close, after, flushAfter]);
    final events = await read;
    expect(events.map((e) => e['text']), ['new']);
    expect(events.single['seq'], 1);
    expect(SessionLedger.I.sinkOpensForTest[sid], 1);
    expect(jsonDecode(file.readAsLinesSync().single)['text'], 'new');
  });

  test('concurrent reads and flushes are ordered between appends', () async {
    final operations = <Future<void>>[];
    final snapshots = <Future<List<Map<String, dynamic>>>>[];
    for (var i = 0; i < 12; i++) {
      operations.add(SessionLedger.I.append(sid, 'note', {'i': i}));
      operations.add(SessionLedger.I.flush(sid));
      snapshots.add(SessionLedger.I.read(sid));
    }
    await Future.wait(operations);
    for (var i = 0; i < snapshots.length; i++) {
      final events = await snapshots[i];
      expect(events.map((e) => e['seq']), List.generate(i + 1, (n) => n + 1));
      expect(events.last['i'], i);
    }
    expect(SessionLedger.I.sinkOpensForTest[sid], 1);
  });

  test(
    'suspended async write holds later writes, flush and close in order',
    () async {
      final entered = Completer<void>();
      final release = Completer<void>();
      final calls = <String>[];
      // Delegate to real disk I/O, pausing only the first asynchronous write.
      // Sync file methods are intentionally unsupported by these wrappers.
      await IOOverrides.runZoned(
        () async {
          final first = SessionLedger.I.append(sid, 'note', {'text': 'first'});
          try {
            await Future.any([
              entered.future,
              first.then(
                (_) => throw StateError('append bypassed async write'),
              ),
            ]);
            final second = SessionLedger.I.append(sid, 'note', {
              'text': 'second',
            });
            final flush = SessionLedger.I.flush(sid);
            final close = SessionLedger.I.close(sid);
            // Yield without relying on wall-clock timing. The write remains gated.
            await Future<void>.delayed(Duration.zero);
            expect(calls, ['write first start']);
            release.complete();
            await Future.wait([first, second, flush, close]);
            expect(calls, [
              'write first start',
              'write first end',
              'write second start',
              'write second end',
              'flush',
              'close',
            ]);
            expect(file.existsSync(), isFalse);
          } finally {
            if (!release.isCompleted) release.complete();
            await first;
            await SessionLedger.I.close(sid);
          }
        },
        createFile: (path) {
          expect(path, file.path);
          return _AsyncFile(file, entered, release, calls);
        },
      );
    },
  );

  test(
    'streamed recovery spans chunks and retains the highest sequence',
    () async {
      final writer = file.openWrite();
      for (var i = 1; i <= 1500; i++) {
        writer.writeln(jsonEncode({'seq': i, 'text': 'record $i'}));
      }
      writer.writeln(jsonEncode({'seq': 9000, 'text': '€' * 40000}));
      writer.write('{"seq":9999,"text":"torn');
      await writer.close();
      await SessionLedger.I.append(sid, 'note', {'text': 'new'});
      await SessionLedger.I.flush(sid);
      final events = await SessionLedger.I.read(sid);
      expect(events, hasLength(1502));
      expect(events[1500]['seq'], 9000);
      expect(events.last['seq'], 9001);
      expect(events.last['text'], 'new');
    },
  );
}

class _AsyncFile implements File {
  _AsyncFile(this.file, this.entered, this.release, this.calls);
  final File file;
  final Completer<void> entered;
  final Completer<void> release;
  final List<String> calls;

  @override
  String get path => file.path;

  @override
  Future<bool> exists() => file.exists();

  @override
  Future<FileSystemEntity> delete({bool recursive = false}) =>
      file.delete(recursive: recursive);

  @override
  Future<RandomAccessFile> open({FileMode mode = FileMode.read}) async =>
      _AsyncHandle(await file.open(mode: mode), entered, release, calls);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _AsyncHandle implements RandomAccessFile {
  _AsyncHandle(this.handle, this.entered, this.release, this.calls);
  final RandomAccessFile handle;
  final Completer<void> entered;
  final Completer<void> release;
  final List<String> calls;

  @override
  Future<RandomAccessFile> writeString(
    String string, {
    Encoding encoding = utf8,
  }) async {
    final text = (jsonDecode(string) as Map)['text'];
    calls.add('write $text start');
    if (!entered.isCompleted) {
      entered.complete();
      await release.future;
    }
    await handle.writeString(string, encoding: encoding);
    calls.add('write $text end');
    return this;
  }

  @override
  Future<RandomAccessFile> flush() async {
    calls.add('flush');
    await handle.flush();
    return this;
  }

  @override
  Future<void> close() async {
    calls.add('close');
    await handle.close();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
