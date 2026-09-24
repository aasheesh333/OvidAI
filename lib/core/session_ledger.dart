import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// Append-only session event ledger (PR19, session-persistence parity).
///
/// A PARALLEL durable record — the existing message model is untouched and
/// remains the chat-rendering source. The ledger records STRUCTURED events
/// (user turn, assistant turn, tool call/result incl. duration, subagent
/// lifecycle, checkpoint barriers) as one JSON line each in
/// `<docs>/session-ledgers/<sessionId>.jsonl`.
///
/// Consumers:
///   • trajectory view — the event-ledger tab (records + inspector)
///   • stats projection — turn/step counts, wall times (exact, not sampled)
///   • checkpoint recovery — the last barrier decides TOOL_OUTCOME_UNKNOWN
///
/// Writes are best-effort: a failing disk never breaks a run. Every event
/// carries a monotonically increasing `seq` per session for stable ordering.
class SessionLedger {
  SessionLedger._();
  static final SessionLedger I = SessionLedger._();

  Directory? _root;

  /// Session → the (single) append sink, memoised as a FUTURE so the
  /// check-and-insert is atomic — see [_sinkFor].
  final Map<String, Future<IOSink>> _sinks = {};
  final Map<String, int> _seqs = {};
  final Map<String, List<Map<String, dynamic>>> _replayCache = {};

  /// Test seam: how many append sinks have been OPENED for a session in its
  /// current lifetime. Must be exactly 1 no matter how many appends race —
  /// every extra open orphans a sink (leaked descriptor, possibly a lost
  /// buffered line). Reset by [close].
  @visibleForTesting
  final Map<String, int> sinkOpensForTest = {};

  /// Test seam: fixed ledger root (no path_provider channel). Also used
  /// when the platform channel is unavailable — the ledger degrades to
  /// memory-only rather than throwing into live runs.
  @visibleForTesting
  static Directory? rootOverrideForTest;

  Future<Directory> _dir() async {
    if (rootOverrideForTest != null) return rootOverrideForTest!;
    if (_root != null) return _root!;
    final d = Directory(
      '${(await getApplicationDocumentsDirectory()).path}/session-ledgers',
    );
    d.createSync(recursive: true);
    _root = d;
    return d;
  }

  Future<File> _fileFor(String sessionId) async => File(
        '${(await _dir()).path}/${_sessionIdSafe(sessionId)}.jsonl',
      );

  static String _sessionIdSafe(String id) => id.replaceAll(
        RegExp(r'[^A-Za-z0-9_\-]'),
        '_',
      );

  /// The session's append sink, opened at most once per lifetime.
  ///
  /// LEAK FIX (2026-09-24): this used to be an inline
  /// `if (sink != null) … else { await _fileFor(); openWrite(); _sinks[id] = s; }`
  /// — a check-then-`await`-then-assign race. Appends arrive concurrently (a
  /// run start fires `turn_start` and `checkpoint` back to back, both
  /// `unawaited`; a subagent fan-out opens many fresh sessions at once), so two
  /// first-appenders both saw `null`, both called `openWrite`, and the second
  /// assignment orphaned the first sink: never flushed, never closed. One
  /// leaked file descriptor per fresh session, plus any line still buffered in
  /// it. The check and the insert below are both synchronous, so in this single
  /// isolate they are atomic and late callers share one future.
  Future<IOSink> _sinkFor(String sessionId) {
    final existing = _sinks[sessionId];
    if (existing != null) return existing;
    sinkOpensForTest[sessionId] = (sinkOpensForTest[sessionId] ?? 0) + 1;
    final future = () async {
      final f = await _fileFor(sessionId);
      return f.openWrite(mode: FileMode.append);
    }();
    _sinks[sessionId] = future;
    // If the open FAILS (path_provider unavailable, disk full) do not leave the
    // rejected future cached: that would poison the session's ledger for the
    // rest of the process, where the old code simply retried next time. This
    // handler also marks the error as observed, so a future nobody else awaits
    // cannot surface as an unhandled async error — the real awaiters
    // ([append], [flush]) still see it inside their own try/catch.
    future.then(
      (_) {},
      onError: (Object _) {
        if (identical(_sinks[sessionId], future)) _sinks.remove(sessionId);
      },
    );
    return future;
  }

  /// Append one event. [kind] is one of: turn_start, turn_end, tool_start,
  /// tool_end, subagent_start, subagent_end, checkpoint, note.
  Future<void> append(String sessionId, String kind, Map<String, dynamic> data) async {
    try {
      final seq = (_seqs[sessionId] ?? 0) + 1;
      _seqs[sessionId] = seq;
      final t = DateTime.now().toIso8601String();
      final event = {
        'seq': seq,
        't': t,
        'kind': kind,
        ...data,
      };
      final line = jsonEncode(event);
      final sink = await _sinkFor(sessionId);
      sink.writeln(line);
      _replayCache[sessionId]?.add(event);
    } catch (_) {
      // Best-effort durability — a ledger write failure must never break a
      // live run. The trajectory view degrades to "no records" per session.
    }
  }

  /// Read every event of a session (trajectory view / stats projection).
  /// Open sinks are flushed first so a just-written line is visible.
  /// Empty when the ledger does not exist yet (fresh sessions).
  Future<List<Map<String, dynamic>>> read(String sessionId) async {
    try {
      await flush(sessionId);
      final cached = _replayCache[sessionId];
      if (cached != null && cached.isNotEmpty) return List.of(cached);
      final f = await _fileFor(sessionId);
      if (!f.existsSync()) return const [];
      final events = <Map<String, dynamic>>[];
      for (final line in f.readAsLinesSync()) {
        if (line.trim().isEmpty) continue;
        try {
          events.add(jsonDecode(line) as Map<String, dynamic>);
        } catch (_) {
          // A torn tail line (crash mid-write) is skipped, not fatal.
        }
      }
      _replayCache[sessionId] = events;
      return List.of(events);
    } catch (_) {
      return const [];
    }
  }

  /// The seq of the last CHECKPOINT barrier in the ledger — recovery reads
  /// this to decide which in-flight tool result is unknown (C9).
  Future<int?> lastCheckpointSeq(String sessionId) async {
    final events = await read(sessionId);
    for (final e in events.reversed) {
      if (e['kind'] == 'checkpoint') return e['seq'] as int?;
    }
    return null;
  }

  /// Wall-clock/turn/step projection over the ledger (stats parity).
  Future<SessionProjection> projection(String sessionId) async {
    final events = await read(sessionId);
    var turns = 0, steps = 0, toolMs = 0, llmMs = 0;
    DateTime? firstStart, lastEnd;
    final toolCounts = <String, int>{};
    for (final e in events) {
      switch (e['kind'] as String?) {
        case 'turn_start':
          turns++;
          firstStart ??= DateTime.tryParse(e['t'] as String? ?? '');
        case 'turn_end':
          lastEnd = DateTime.tryParse(e['t'] as String? ?? '');
        case 'tool_start':
          steps++;
          final n = e['tool'] as String?;
          if (n != null) toolCounts[n] = (toolCounts[n] ?? 0) + 1;
        case 'tool_end':
          toolMs += (e['ms'] as num?)?.toInt() ?? 0;
        case 'llm':
          llmMs += (e['ms'] as num?)?.toInt() ?? 0;
      }
    }
    return SessionProjection(
      turns: turns,
      steps: steps,
      toolMs: toolMs,
      llmMs: llmMs,
      wallMs: (firstStart != null && lastEnd != null)
          ? lastEnd.difference(firstStart).inMilliseconds
          : 0,
      toolCounts: toolCounts,
    );
  }

  /// Close (and forget) a session's sink — call on session delete.
  Future<void> close(String sessionId) async {
    final pending = _sinks.remove(sessionId);
    if (pending != null) {
      try {
        // LEAK FIX (2026-09-24): `close()` implies `flush()` AND releases the
        // descriptor. This used to call `flush()` only and then delete the file
        // underneath the still-open handle, so *every* session deletion leaked
        // one descriptor pointing at an unlinked inode for the rest of the
        // process's life.
        await (await pending).close();
      } catch (_) {}
    }
    _seqs.remove(sessionId);
    _replayCache.remove(sessionId);
    sinkOpensForTest.remove(sessionId);
    try {
      final f = await _fileFor(sessionId);
      f.deleteSync();
    } catch (_) {}
  }

  /// Flush a session's sink (checkpoint durability barrier).
  Future<void> flush(String sessionId) async {
    final pending = _sinks[sessionId];
    if (pending == null) return;
    try {
      await (await pending).flush();
    } catch (_) {}
  }
}

/// Aggregated stats over one session's ledger (the session ledger stats parity).
class SessionProjection {
  final int turns;
  final int steps;
  final int toolMs;
  final int llmMs;
  final int wallMs;
  final Map<String, int> toolCounts;
  const SessionProjection({
    required this.turns,
    required this.steps,
    required this.toolMs,
    required this.llmMs,
    required this.wallMs,
    required this.toolCounts,
  });
}
