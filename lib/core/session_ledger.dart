import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// Append-only session event ledger (PR19, DSH session-persistence parity).
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
  final Map<String, IOSink?> _sinks = {};
  final Map<String, int> _seqs = {};
  final Map<String, List<Map<String, dynamic>>> _replayCache = {};

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
      final sink = _sinks[sessionId];
      if (sink != null) {
        sink.writeln(line);
      } else {
        final f = await _fileFor(sessionId);
        final s = f.openWrite(mode: FileMode.append);
        _sinks[sessionId] = s;
        s.writeln(line);
      }
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
    try {
      await _sinks.remove(sessionId)?.flush();
    } catch (_) {}
    _sinks.remove(sessionId);
    _seqs.remove(sessionId);
    _replayCache.remove(sessionId);
    try {
      final f = await _fileFor(sessionId);
      f.deleteSync();
    } catch (_) {}
  }

  /// Flush a session's sink (checkpoint durability barrier).
  Future<void> flush(String sessionId) async {
    try {
      await _sinks[sessionId]?.flush();
    } catch (_) {}
  }
}

/// Aggregated stats over one session's ledger (DSH session-stats parity).
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
