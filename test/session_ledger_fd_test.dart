import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:ovid_ai/core/session_ledger.dart';

/// File-descriptor leaks in the session ledger (2026-09-24).
///
/// Two defects, both invisible until the process runs out of descriptors:
///
/// 1. **First-write race.** `_sinks` was `Map<String, IOSink?>` with a
///    check-then-`await`-then-assign sequence. A run start fires `turn_start`
///    and `checkpoint` back to back, both `unawaited`, so two appends arrive
///    concurrently on a fresh session: both saw `null`, both called
///    `openWrite`, and the second assignment **orphaned the first sink** —
///    never flushed, never closed. One leaked descriptor per fresh session,
///    plus any line still buffered in it. At 49 concurrent subagents (each a
///    fresh session) that is 49 leaked descriptors per fan-out.
///
/// 2. **`close()` flushed but never closed.** `IOSink.flush()` does not release
///    the descriptor — only `close()` does — and the file was then deleted
///    underneath it. So *every* session deletion leaked one descriptor to an
///    unlinked inode, forever.
///
/// Symptom once the limit is reached: `EMFILE` ("Too many open files") and
/// unrelated file/socket operations start failing across the whole app.
void main() {
  late Directory root;

  setUp(() {
    root = Directory.systemTemp.createTempSync('ledger-fd-');
    SessionLedger.rootOverrideForTest = root;
  });

  tearDown(() async {
    SessionLedger.rootOverrideForTest = null;
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  group('one sink per session, however many appends race', () {
    test('concurrent first appends open exactly one sink', () async {
      const sid = 'race-session';

      // Fire 40 appends without awaiting each other — the same shape as a run
      // start plus a 49-wide subagent fan-out.
      await Future.wait([
        for (var i = 0; i < 40; i++)
          SessionLedger.I.append(sid, 'note', {'i': i}),
      ]);

      expect(
        SessionLedger.I.sinkOpensForTest[sid],
        1,
        reason: 'every extra open orphans a sink: leaked fd + lost line',
      );
    });

    test('no event is lost to an orphaned sink', () async {
      const sid = 'lost-line-session';
      const n = 40;

      await Future.wait([
        for (var i = 0; i < n; i++)
          SessionLedger.I.append(sid, 'note', {'i': i}),
      ]);
      await SessionLedger.I.flush(sid);

      final events = await SessionLedger.I.read(sid);
      expect(events.length, n, reason: 'all appended events must survive');
      // seq is assigned synchronously before the await, so ordering is exact.
      expect(events.map((e) => e['seq']).toList(), [
        for (var i = 1; i <= n; i++) i,
      ]);
    });

    test('the file on disk really holds every line', () async {
      const sid = 'ondisk-session';
      const n = 25;

      await Future.wait([
        for (var i = 0; i < n; i++)
          SessionLedger.I.append(sid, 'note', {'i': i}),
      ]);
      await SessionLedger.I.close(sid);

      // close() deletes the ledger, so re-append and read back through the API
      // after a flush instead: this asserts durability, not deletion.
      final sid2 = 'ondisk-session-2';
      for (var i = 0; i < n; i++) {
        await SessionLedger.I.append(sid2, 'note', {'i': i});
      }
      await SessionLedger.I.flush(sid2);
      final f = File('${root.path}/$sid2.jsonl');
      expect(f.existsSync(), isTrue);
      expect(f.readAsLinesSync().where((l) => l.trim().isNotEmpty).length, n);
    });
  });

  group('close() actually releases the descriptor', () {
    test('close deletes the ledger and resets the sink lifetime', () async {
      const sid = 'close-session';
      await SessionLedger.I.append(sid, 'note', {'a': 1});
      expect(SessionLedger.I.sinkOpensForTest[sid], 1);

      await SessionLedger.I.close(sid);

      expect(File('${root.path}/$sid.jsonl').existsSync(), isFalse);
      expect(SessionLedger.I.sinkOpensForTest[sid] ?? 0, 0);

      // A later append starts a NEW single-sink lifetime rather than reusing a
      // stale (closed) handle.
      await SessionLedger.I.append(sid, 'note', {'b': 2});
      expect(SessionLedger.I.sinkOpensForTest[sid], 1);
      final events = await SessionLedger.I.read(sid);
      expect(events.length, 1);
      expect(events.single['b'], 2);

      await SessionLedger.I.close(sid);
    });

    test('flush on an unknown session is a no-op, not a crash', () async {
      await SessionLedger.I.flush('never-opened');
      await SessionLedger.I.close('never-opened');
    });
  });
}
