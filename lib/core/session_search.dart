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
    return _opening ??= () async {
      final path = dbPathOverrideForTest ??
          '${(await getApplicationDocumentsDirectory()).path}/session-search.db';
      final db = sqlite3.open(path);
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
    }();
  }

  /// Rows have changed → drop and rebuild. Cheap (thousands of rows).
  Future<void> reindex(
    Iterable<
      ({
        String id,
        String model,
        List<({String role, String content})> rows,
      })
    > sessions,
  ) async {
    final db = await _open();
    db.execute('BEGIN');
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
    final db = await _open();
    // FTS5 treats bare words as implicit AND; quoted phrases match
    // literally — same literal-phrase semantics as the query service.
    final q = query.replaceAll("'", "''");
    final where = [
      "msgs MATCH '$q'",
      if (sessionId != null) "sessionId = '$sessionId'",
      if (model != null) "model = '$model'",
    ].join(' AND ');
    final rows = db.select(
      "SELECT sessionId, model, role, snippet(msgs, 3, '→', '←', '…', 12), "
      'bm25(msgs) AS rank '
      'FROM msgs WHERE $where '
      'ORDER BY rank LIMIT ? OFFSET ?',
      [limit, cursor],
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

