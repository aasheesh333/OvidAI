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
///   • bounded offset paging with optional snapshot generation fencing
class SessionSearch {
  SessionSearch._();
  static final SessionSearch I = SessionSearch._();

  Database? _db;
  Future<Database>? _opening;
  int _generation = 0;
  bool _readable = true;
  bool _requiresRebuild = false;
  String? _accountId;
  final Set<String> _deletedSessionIds = {};

  /// Capture before building a snapshot and pass as [reindex]'s
  /// `expectedGeneration`. A successful rebuild returns the generation to use
  /// for searches/pages. A stale operation returns no results and does no work.
  int get generation => _generation;

  static const maxLimit = 100;
  static const maxCursor = 100000;

  /// Maximum query size in UTF-16 code units, before literal escaping.
  static const maxQueryLength = 4096;

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
    ++_generation;
    try {
      await _opening;
    } finally {
      final db = _db;
      _db = null;
      _opening = null;
      db?.dispose();
    }
  }

  /// Fence old account work immediately. The account lifecycle owner must call
  /// this before exposing a new account's sessions, including on cold startup.
  /// Rows remain unreadable until a successful rebuild from that account.
  Future<void> setAccount(String accountId) {
    if (_accountId == accountId && !_requiresRebuild) return Future.value();
    if (_accountId != accountId) {
      _accountId = accountId;
      _deletedSessionIds.clear();
    }
    return clear();
  }

  /// Invalidate pending snapshots/queries before asynchronously clearing rows.
  /// A failed clear leaves the old index unreadable and can be retried.
  Future<void> clear() async {
    final generation = ++_generation;
    _readable = false;
    _requiresRebuild = true;
    final db = await _open();
    if (generation != _generation) return;
    db.execute('DELETE FROM msgs');
  }

  /// Tombstone first so even a later rebuild containing a deleted session
  /// cannot restore its rows. Session IDs must not be reused within an account.
  Future<void> deleteSession(String id, {int? expectedGeneration}) async {
    if (!_isCurrent(expectedGeneration)) return;
    final generation = ++_generation;
    _deletedSessionIds.add(id);
    _readable = false;
    final db = await _open();
    if (generation != _generation) return;
    db.execute('BEGIN');
    try {
      // A newer deletion may have superseded an older one waiting for open.
      // Apply all tombstones before allowing reads again.
      for (final deletedId in _deletedSessionIds) {
        db.execute('DELETE FROM msgs WHERE sessionId = ?', [deletedId]);
      }
      db.execute('COMMIT');
      _readable = !_requiresRebuild;
    } catch (_) {
      if (!db.autocommit) db.execute('ROLLBACK');
      rethrow;
    }
  }

  bool _isCurrent(int? generation) =>
      generation == null || generation == _generation;

  /// Atomically replace rows from a snapshot. Superseded rebuilds return null;
  /// failures preserve the prior index and propagate for a caller retry.
  Future<int?> reindex(
    Iterable<
      ({String id, String model, List<({String role, String content})> rows})
    >
    sessions, {
    int? expectedGeneration,
  }) async {
    if (!_isCurrent(expectedGeneration)) return null;
    final generation = ++_generation;
    final db = await _open();
    if (generation != _generation) return null;
    db.execute('BEGIN');
    try {
      db.execute('DELETE FROM msgs');
      final stmt = db.prepare(
        'INSERT INTO msgs (sessionId, model, role, body) VALUES (?, ?, ?, ?)',
      );
      try {
        for (final s in sessions) {
          if (generation != _generation) break;
          if (_deletedSessionIds.contains(s.id)) continue;
          for (final m in s.rows) {
            if (generation != _generation) break;
            stmt.execute([s.id, s.model, m.role, m.content]);
          }
        }
      } finally {
        stmt.dispose();
      }
      if (generation != _generation) {
        db.execute('ROLLBACK');
        return null;
      }
      db.execute('COMMIT');
      _readable = true;
      _requiresRebuild = false;
      return generation;
    } catch (_) {
      // SQLite can roll back automatically on some errors. Otherwise restore
      // the previous index and release the writer lock before propagating.
      if (!db.autocommit) db.execute('ROLLBACK');
      rethrow;
    }
  }

  /// Literal terms use implicit AND, with double quotes grouping phrases.
  /// With [advanced], [query] is SQLite FTS5 MATCH grammar (AND/OR/NOT,
  /// prefixes, NEAR and column filters). Malformed MATCH returns no hits;
  /// storage/open failures still propagate so callers can retry.
  /// [cursor] is a bounded 0-based offset. Rank ties use stable session/message
  /// keys. Pass the rebuild's [expectedGeneration] on every page to reject a
  /// changed snapshot rather than mixing pages from different snapshots.
  Future<List<SessionSearchHit>> search(
    String query, {
    int limit = 20,
    int cursor = 0,
    String? sessionId,
    String? model,
    bool advanced = false,
    int? expectedGeneration,
  }) async {
    RangeError.checkValueInInterval(limit, 0, maxLimit, 'limit');
    RangeError.checkValueInInterval(cursor, 0, maxCursor, 'cursor');
    RangeError.checkValueInInterval(
      query.length,
      0,
      maxQueryLength,
      'query.length',
    );
    final matchQuery = advanced ? query.trim() : _literalQuery(query);
    if (limit == 0 || matchQuery.isEmpty || matchQuery.contains('\u0000')) {
      return [];
    }
    if (!_isCurrent(expectedGeneration) || !_readable) return [];
    final generation = _generation;
    final db = await _open();
    if (generation != _generation || !_readable) return [];
    final where = [
      'msgs MATCH ?',
      if (sessionId != null) 'sessionId = ?',
      if (model != null) 'model = ?',
    ].join(' AND ');
    final ResultSet rows;
    // Preparation errors concern our schema/SQL, not the user's MATCH grammar.
    final stmt = db.prepare(
      "SELECT sessionId, model, role, snippet(msgs, 3, '→', '←', '…', 12), "
      'bm25(msgs) AS rank '
      'FROM msgs WHERE $where '
      'ORDER BY rank, sessionId, model, role, body, rowid LIMIT ? OFFSET ?',
    );
    try {
      rows = stmt.select([matchQuery, ?sessionId, ?model, limit, cursor]);
    } on SqliteException catch (error) {
      // Only grammar failures are empty queries. Never hide a missing/corrupt
      // index, lock failure, or other operational SQLite error.
      if (error.resultCode == 1 &&
          (error.message.startsWith('fts5: syntax error') ||
              error.message.startsWith('unterminated string') ||
              error.message.startsWith('no such column:') ||
              error.message.startsWith('expected integer, got') ||
              error.message.startsWith('unknown special query:'))) {
        return [];
      }
      rethrow;
    } finally {
      stmt.dispose();
    }
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
      .allMatches(query.replaceAll('\u0000', ' '))
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
