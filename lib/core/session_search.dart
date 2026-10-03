import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/sqlite3.dart';

/// FTS5 cross-session content search (PR19, session-query-sqlite parity).
///
/// An on-device SQLite FTS5 index over every session's messages, refreshed
/// from `AppState.sessions` on demand. The index is DERIVED data — sessions
/// remain the source of truth, so a dropped index costs nothing but a
/// rebuild. Features parity:
///   • literal-phrase search (quoted phrases supported)
///   • ranked results (bm25) with snippet excerpts
///   • metadata filters (session id / model)
///   • an opaque cursor for paging
class SessionSearch {
  SessionSearch._();
  static final SessionSearch I = SessionSearch._();

  Database? _db;
  Future<Database>? _opening;

  /// Test seam: fixed db path (no path_provider channel).
  @visibleForTesting
  static String? dbPathOverrideForTest;

  Future<Database> _open() async {
    if (_db != null) return _db!;
    final opening = _opening ??= () async {
      final path =
          dbPathOverrideForTest ??
          '${(await getApplicationDocumentsDirectory()).path}/session-search.db';
      final db = sqlite3.open(path);
      try {
        db.execute('''
        CREATE VIRTUAL TABLE IF NOT EXISTS msgs USING fts5(
          sessionId UNINDEXED,
          model UNINDEXED,
          role UNINDEXED,
          body,
          tokenize = 'unicode61'
        );
      ''');
        _db = db;
        return db;
      } catch (_) {
        db.dispose();
        rethrow;
      }
    }();
    try {
      return await opening;
    } finally {
      if (identical(_opening, opening)) _opening = null;
    }
  }

  /// Releases the index handle without deleting its data. The next operation
  /// reopens it; callers should await outstanding operations before closing.
  Future<void> close() async {
    try {
      await _opening;
    } finally {
      final db = _db;
      _db = null;
      _opening = null;
      db?.dispose();
    }
  }

  /// Rows have changed → drop and rebuild. Cheap (thousands of rows).
  Future<void> reindex(
    Iterable<
      ({String id, String model, List<({String role, String content})> rows})
    >
    sessions,
  ) async {
    final db = await _open();
    db.execute('BEGIN');
    try {
      db.execute('DELETE FROM msgs');
      final stmt = db.prepare(
        'INSERT INTO msgs (sessionId, model, role, body) VALUES (?, ?, ?, ?)',
      );
      try {
        for (final s in sessions) {
          for (final m in s.rows) {
            stmt.execute([s.id, s.model, m.role, m.content]);
          }
        }
      } finally {
        stmt.dispose();
      }
      db.execute('COMMIT');
    } catch (_) {
      // SQLite can roll back automatically on some errors. Otherwise restore
      // the previous index and release the writer lock before propagating.
      if (!db.autocommit) db.execute('ROLLBACK');
      rethrow;
    }
  }

  /// Literal-phrase search with bm25 ranking and snippet excerpts.
  /// [cursor] is an opaque offset for paging (0-based row offset).
  Future<List<SessionSearchHit>> search(
    String query, {
    int limit = 20,
    int cursor = 0,
    String? sessionId,
    String? model,
  }) async {
    RangeError.checkNotNegative(limit, 'limit');
    RangeError.checkNotNegative(cursor, 'cursor');
    final literalQuery = _literalQuery(query);
    if (limit == 0 || literalQuery.isEmpty) return [];
    final db = await _open();
    final where = [
      'msgs MATCH ?',
      if (sessionId != null) 'sessionId = ?',
      if (model != null) 'model = ?',
    ].join(' AND ');
    final rows = db.select(
      "SELECT sessionId, model, role, snippet(msgs, 3, '→', '←', '…', 12), "
      'bm25(msgs) AS rank '
      'FROM msgs WHERE $where '
      'ORDER BY rank LIMIT ? OFFSET ?',
      [literalQuery, ?sessionId, ?model, limit, cursor],
    );
    return [
      for (final r in rows)
        SessionSearchHit(
          sessionId: r['sessionId'] as String,
          model: r['model'] as String? ?? '',
          role: r['role'] as String? ?? '',
          snippet: r.columnAt(3) as String? ?? '',
        ),
    ];
  }

  // Retain implicit AND between terms and explicit quoted phrases, but never
  // interpret user punctuation or words such as OR/NOT as FTS operators.
  static String _literalQuery(String query) => RegExp(r'"([^"]*)"|([^\s"]+)')
      .allMatches(query)
      .map((m) => m.group(1) ?? m.group(2)!)
      .where((term) => term.trim().isNotEmpty)
      .map((term) => '"${term.replaceAll('"', '""')}"')
      .join(' AND ');
}

class SessionSearchHit {
  final String sessionId;
  final String model;
  final String role;
  final String snippet;
  const SessionSearchHit({
    required this.sessionId,
    required this.model,
    required this.role,
    required this.snippet,
  });
}
