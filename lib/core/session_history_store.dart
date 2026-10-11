import 'dart:async';
import 'dart:convert';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:sqlite3_flutter_libs/sqlite3_flutter_libs.dart';

import 'diag.dart';

/// Durable chat-history storage behind `AppState` (F-045, master plan 4.3).
///
/// Every namespace is addressed by the SharedPreferences key that used to hold
/// its `StringList` (`ovid_sessions`, `ovid_sessions_owner_<uid>`), and every
/// row is the exact JSON string `AppState` produced. The repository therefore
/// keeps AppState's persistence contract (ordered raw rows, opaque rows are
/// preserved byte-for-byte) while moving the bytes out of SharedPreferences.
///
/// Backends:
///  * legacy (default, used by tests and as a fallback): the prefs `StringList`.
///  * SQLite (production opts in from `main` via [enableSqlite]): one row per
///    session (`history_rows`, with summary columns), one derived row per
///    message (`history_messages` + the `history_fts` FTS5 index) and
///    incremental writes — an unchanged session is never re-written.
///
/// Migration safety (per namespace, lazily on first access):
///  1. The legacy rows are imported in ONE transaction (corrupt / duplicate
///     rows go to `history_quarantine`, never dropped) and the migration row is
///     recorded as `imported`.
///  2. The DB is read back and verified (row count + SHA-256 over the ordered
///     rows, plus imported + quarantined == source count). Only then is the
///     state set to `verified` and the key added to the prefs marker
///     [migratedMarkerKey].
///  3. Only after that is the legacy prefs blob removed.
///  A kill at any step leaves either the blob authoritative (steps 1-2: the
///  next launch re-imports from scratch, idempotently) or the DB authoritative
///  with a leftover blob (step 3), which is MERGED (unknown ids appended,
///  differing copies quarantined) before it is removed — so a chat written by a
///  downgraded build is never lost. A failed verification falls back to the
///  legacy blob for the rest of the process and retries on the next launch.
///  Rollback: [disableSqlite] (kill switch) copies every migrated namespace
///  back into prefs, verifies the readback and only then clears the marker.
class SessionHistoryRepository {
  SessionHistoryRepository._();

  /// Fresh, unconfigured instance — models a new process in migration tests.
  @visibleForTesting
  SessionHistoryRepository.forTest();

  static final SessionHistoryRepository I = SessionHistoryRepository._();

  /// Prefs `StringList` of namespaces whose authority has moved to SQLite.
  static const migratedMarkerKey = 'ovid_sessions_sqlite_v1';
  static const dbFileName = 'chat-history.db';
  static const schemaVersion = 1;

  /// Largest message body indexed for search (characters).
  static const maxIndexedBodyLength = 32 * 1024;

  bool _sqliteEnabled = false;
  bool _rollbackRequested = false;
  String? _dbPath;
  bool _backgroundSearch = true;
  Database? _db;
  Future<Database>? _opening;
  bool _busy = false;
  final List<Completer<void>> _waiters = [];

  /// Namespaces read successfully in this process. A namespace that already
  /// holds rows can only be rewritten after it was read, so a failed load can
  /// never be followed by a write that deletes history it did not see.
  final Set<String> _readNamespaces = {};

  /// Namespaces pinned to the legacy blob for this process (verification or
  /// open failed before the marker was set). Retried on the next launch.
  final Set<String> _legacyNamespaces = {};

  /// Identity cache of the last raw strings read/written per namespace.
  /// AppState reuses identical `String` instances for unchanged sessions, so
  /// an unchanged row costs one `identical` check, not a hash of its bytes.
  final Map<String, Map<String, String>> _known = {};

  final List<SessionHistoryMigrationReport> _reports = [];

  /// Migration reports of this process (one per migrated/merged namespace).
  List<SessionHistoryMigrationReport> get migrationReports =>
      List.unmodifiable(_reports);

  bool get sqliteEnabled => _sqliteEnabled;

  /// True when content search can use the FTS index (SQLite opened).
  bool get searchIndexAvailable => _sqliteEnabled && _db != null;

  /// Test seam: called at named migration checkpoints. Throwing simulates the
  /// process dying at that point; durable state is whatever was committed.
  @visibleForTesting
  void Function(String stage, {int? index})? migrationFaultForTest;

  /// Production opt-in (called from `main`). [path] overrides the default
  /// `<documents>/chat-history.db`; tests pass a temp file or `:memory:`.
  void enableSqlite({String? path, bool backgroundSearch = true}) {
    _sqliteEnabled = true;
    _rollbackRequested = false;
    _dbPath = path ?? _dbPath;
    _backgroundSearch = backgroundSearch;
  }

  /// Kill switch / rollback: history authority returns to SharedPreferences.
  /// Migrated namespaces are copied back (verified) on their next access, or
  /// eagerly through [rollbackAll].
  void disableSqlite({String? path}) {
    _sqliteEnabled = false;
    _rollbackRequested = true;
    _dbPath = path ?? _dbPath;
  }

  /// One storage operation at a time. An idle repository runs [op] directly
  /// (no chained futures from another zone, which fake-async tests rely on).
  Future<T> _serial<T>(Future<T> Function() op) async {
    if (_busy) {
      final turn = Completer<void>();
      _waiters.add(turn);
      await turn.future;
    }
    _busy = true;
    try {
      return await op();
    } finally {
      if (_waiters.isNotEmpty) {
        _waiters.removeAt(0).complete();
      } else {
        _busy = false;
      }
    }
  }

  /// Plain legacy mode: prefs is the only store and nothing to roll back.
  bool get _plainLegacy => !_sqliteEnabled && !_rollbackRequested;

  // ── Opening ─────────────────────────────────────────────────────────────

  Future<Database> _open() async {
    final existing = _db;
    if (existing != null) return existing;
    final opening = _opening ??= () async {
      await applyWorkaroundToOpenSqlite3OnOldAndroidVersions();
      final path = _dbPath ??=
          '${(await getApplicationDocumentsDirectory()).path}/$dbFileName';
      final db = sqlite3.open(path);
      try {
        _initSchema(db);
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

  static void _initSchema(Database db) {
    db.execute('PRAGMA journal_mode = WAL');
    db.execute('PRAGMA synchronous = FULL');
    db.execute('PRAGMA busy_timeout = 3000');
    final version = db.select('PRAGMA user_version').single.columnAt(0) as int;
    if (version > schemaVersion) {
      throw StateError('Chat history schema $version is newer than this app.');
    }
    db.execute('''
      CREATE TABLE IF NOT EXISTS history_rows(
        ns TEXT NOT NULL,
        row_key TEXT NOT NULL,
        session_id TEXT,
        pos INTEGER NOT NULL,
        raw TEXT NOT NULL,
        hash INTEGER NOT NULL,
        title TEXT,
        model TEXT,
        parent_id TEXT,
        created_at TEXT,
        updated_at TEXT,
        PRIMARY KEY(ns, row_key)
      ) WITHOUT ROWID;
      CREATE INDEX IF NOT EXISTS history_rows_pos ON history_rows(ns, pos);
      CREATE TABLE IF NOT EXISTS history_messages(
        ns TEXT NOT NULL,
        row_key TEXT NOT NULL,
        idx INTEGER NOT NULL,
        sig INTEGER NOT NULL,
        fts_rowid INTEGER,
        PRIMARY KEY(ns, row_key, idx)
      ) WITHOUT ROWID;
      CREATE VIRTUAL TABLE IF NOT EXISTS history_fts USING fts5(
        body,
        ns UNINDEXED,
        session_id UNINDEXED,
        idx UNINDEXED,
        role UNINDEXED,
        tokenize = 'unicode61'
      );
      CREATE TABLE IF NOT EXISTS history_migrations(
        ns TEXT PRIMARY KEY,
        state TEXT NOT NULL,
        source_count INTEGER NOT NULL,
        imported INTEGER NOT NULL,
        quarantined INTEGER NOT NULL,
        checksum TEXT NOT NULL,
        updated_at TEXT NOT NULL
      );
      CREATE TABLE IF NOT EXISTS history_quarantine(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        ns TEXT NOT NULL,
        source_index INTEGER,
        raw TEXT NOT NULL,
        reason TEXT NOT NULL,
        at TEXT NOT NULL
      );
    ''');
    if (version < schemaVersion) {
      db.execute('PRAGMA user_version = $schemaVersion');
    }
  }

  /// Release the handle (tests / account teardown). Data is kept.
  Future<void> close() => _serial(() async {
    try {
      await _opening;
    } catch (_) {}
    _db?.dispose();
    _db = null;
    _opening = null;
  });

  @visibleForTesting
  Future<void> resetForTest() async {
    await close();
    _sqliteEnabled = false;
    _rollbackRequested = false;
    _dbPath = null;
    _backgroundSearch = true;
    _readNamespaces.clear();
    _legacyNamespaces.clear();
    _known.clear();
    _reports.clear();
    migrationFaultForTest = null;
  }

  // ── Public API (all operations serialised) ──────────────────────────────

  /// Ordered raw rows of [key], or null when the namespace holds nothing.
  Future<List<String>?> readRows(SharedPreferences prefs, String key) async {
    if (_plainLegacy) return prefs.getStringList(key);
    return _serial(() async {
      final db = await _resolve(prefs, key);
      if (db == null) return prefs.getStringList(key);
      final rows = [
        for (final r in db.select(
          'SELECT row_key, raw FROM history_rows WHERE ns = ? ORDER BY pos',
          [key],
        ))
          (key: r.columnAt(0) as String, raw: r.columnAt(1) as String),
      ];
      _readNamespaces.add(key);
      _known[key] = {for (final r in rows) r.key: r.raw};
      return rows.isEmpty ? null : [for (final r in rows) r.raw];
    });
  }

  /// Replace [key]'s rows ([rows] null or empty removes the namespace).
  /// Returns false when the backend rejected the write (legacy prefs).
  Future<bool> writeRows(
    SharedPreferences prefs,
    String key,
    List<String>? rows,
  ) async {
    Future<bool> legacy() =>
        rows == null ? prefs.remove(key) : prefs.setStringList(key, rows);
    if (_plainLegacy) return legacy();
    return _serial(() async {
      final db = await _resolve(prefs, key);
      if (db == null) return legacy();
      _writeSqlite(db, key, rows ?? const []);
      return true;
    });
  }

  /// Remove [key] (verified reset).
  Future<bool> removeRows(SharedPreferences prefs, String key) =>
      writeRows(prefs, key, null);

  /// Wipe every namespace (legacy "delete all data" after `prefs.clear()`).
  Future<void> deleteAll() => _serial(() async {
    _known.clear();
    _readNamespaces.clear();
    _legacyNamespaces.clear();
    if (!_sqliteEnabled && !_rollbackRequested) return;
    final db = await _open();
    db.execute('BEGIN IMMEDIATE');
    try {
      for (final table in const [
        'history_rows',
        'history_messages',
        'history_fts',
        'history_migrations',
        'history_quarantine',
      ]) {
        db.execute('DELETE FROM $table');
      }
      db.execute('COMMIT');
    } catch (_) {
      if (!db.autocommit) db.execute('ROLLBACK');
      rethrow;
    }
  });

  /// Readback for the verified reset: true when no table of any namespace
  /// (rows, message index, FTS, migration markers, quarantined raw rows)
  /// holds data. Trivially true while SQLite is not in use.
  Future<bool> isEmpty() => _serial(() async {
    if (!_sqliteEnabled && !_rollbackRequested) return true;
    final db = await _open();
    for (final table in const [
      'history_rows',
      'history_messages',
      'history_fts',
      'history_migrations',
      'history_quarantine',
    ]) {
      if (db.select('SELECT 1 FROM $table LIMIT 1').isNotEmpty) return false;
    }
    return true;
  });

  /// Copy every migrated namespace back to prefs (kill switch, eager form).
  Future<void> rollbackAll(SharedPreferences prefs) async {
    final keys = prefs.getStringList(migratedMarkerKey) ?? const [];
    for (final key in List.of(keys)) {
      await _serial(() => _resolve(prefs, key));
    }
  }

  /// Rows quarantined during migration/merge for [key] (never deleted).
  Future<List<({int? index, String reason, String raw})>> quarantined(
    String key,
  ) => _serial(() async {
    final db = await _open();
    return [
      for (final r in db.select(
        'SELECT source_index, reason, raw FROM history_quarantine '
        'WHERE ns = ? ORDER BY id',
        [key],
      ))
        (
          index: r.columnAt(0) as int?,
          reason: r.columnAt(1) as String,
          raw: r.columnAt(2) as String,
        ),
    ];
  });

  /// FTS5 content search over [key]'s message text. Returns null when the
  /// index is not available (legacy backend) so callers can fall back.
  /// One best-ranked hit per session, ordered by rank. Runs on a background
  /// isolate for file-backed databases.
  Future<List<SessionContentHit>?> searchContent(
    SharedPreferences prefs,
    String key,
    String query, {
    int limit = 20,
  }) async {
    final match = matchQuery(query);
    if (match.isEmpty) return const [];
    final db = await _serial(() => _resolve(prefs, key));
    if (db == null) return null;
    final path = _dbPath;
    if (_backgroundSearch && path != null && path != ':memory:') {
      try {
        return await _searchInIsolate(path, key, match, limit);
      } on ArgumentError catch (error) {
        // The native library could not be loaded in a fresh isolate (e.g. a
        // host test VM); search inline from now on.
        Diag.swallow('history.search.isolate', error);
        _backgroundSearch = false;
      }
    }
    return _search(db, key, match, limit);
  }

  // Static so the isolate closure captures only its arguments.
  static Future<List<SessionContentHit>> _searchInIsolate(
    String path,
    String key,
    String match,
    int limit,
  ) => Isolate.run(() => _searchFile(path, key, match, limit));

  static List<SessionContentHit> _searchFile(
    String path,
    String key,
    String match,
    int limit,
  ) {
    final reader = sqlite3.open(path, mode: OpenMode.readOnly);
    try {
      return _search(reader, key, match, limit);
    } finally {
      reader.dispose();
    }
  }

  /// User text → FTS5 MATCH: literal quoted terms with implicit AND; the last
  /// term is a prefix so results appear while typing.
  static String matchQuery(String query) {
    final terms = RegExp(r'"([^"]*)"|([^\s"]+)')
        .allMatches(query.replaceAll('\u0000', ' '))
        .map((m) => m.group(1) ?? m.group(2)!)
        .where((t) => t.trim().isNotEmpty)
        .toList();
    if (terms.isEmpty) return '';
    final quoted = [for (final t in terms) '"${t.replaceAll('"', '""')}"'];
    quoted[quoted.length - 1] = '${quoted.last}*';
    return quoted.join(' AND ');
  }

  static const highlightStart = '\u0001';
  static const highlightEnd = '\u0002';

  static List<SessionContentHit> _search(
    Database db,
    String key,
    String match,
    int limit,
  ) {
    // Best-ranked message per session (SQLite returns the bare columns of the
    // MIN row), then one snippet query per winning row.
    final ResultSet best;
    try {
      best = db.select(
        'SELECT rowid, session_id, idx, role, MIN(rank) AS r FROM ('
        'SELECT rowid, session_id, idx, role, rank '
        'FROM history_fts WHERE history_fts MATCH ? AND ns = ?) '
        'GROUP BY session_id ORDER BY r, session_id LIMIT ?',
        [match, key, limit],
      );
    } on SqliteException catch (error) {
      // Only MATCH grammar failures are "no results"; operational errors
      // (corruption, locks) propagate.
      if (error.resultCode == 1 &&
          (error.message.startsWith('fts5: syntax error') ||
              error.message.startsWith('unterminated string') ||
              error.message.startsWith('no such column:'))) {
        return const [];
      }
      rethrow;
    }
    final snippet = db.prepare(
      "SELECT snippet(history_fts, 0, '$highlightStart', '$highlightEnd', "
      "'…', 10) FROM history_fts WHERE history_fts MATCH ? AND rowid = ?",
    );
    try {
      return [
        for (final r in best)
          if (r.columnAt(1) is String)
            SessionContentHit(
              sessionId: r.columnAt(1) as String,
              messageIndex: (r.columnAt(2) as num).toInt(),
              role: r.columnAt(3) as String? ?? '',
              snippet:
                  snippet
                          .select([match, r.columnAt(0)])
                          .firstOrNull
                          ?.columnAt(0)
                      as String? ??
                  '',
            ),
      ];
    } finally {
      snippet.dispose();
    }
  }

  // ── Authority resolution + migration ────────────────────────────────────

  /// Returns the database when SQLite is authoritative for [key], or null
  /// when the legacy prefs blob is. Performs the pending migration, merge or
  /// rollback for [key] first.
  Future<Database?> _resolve(SharedPreferences prefs, String key) async {
    final marker = prefs.getStringList(migratedMarkerKey) ?? const [];
    final migrated = marker.contains(key);
    if (!_sqliteEnabled) {
      if (_rollbackRequested && migrated) await _rollback(prefs, key);
      return null;
    }
    if (_legacyNamespaces.contains(key)) return null;
    final Database db;
    try {
      db = await _open();
    } catch (error) {
      // Never migrated: the blob is authoritative, keep using it.
      if (!migrated) {
        Diag.swallow('history.open', error);
        _legacyNamespaces.add(key);
        return null;
      }
      // Migrated: the blob is gone/partial. Fail closed — no write may run.
      rethrow;
    }
    final state = _migrationState(db, key);
    if (state == 'verified' || migrated) {
      if (!migrated) await _addMarker(prefs, key);
      if (prefs.getStringList(key) != null) {
        await _mergeLeftover(db, prefs, key);
      }
      return db;
    }
    try {
      await _migrate(db, prefs, key);
      return db;
    } catch (error) {
      if (migrationFaultForTest != null && error is SimulatedCrash) rethrow;
      Diag.swallow('history.migrate', error);
      _legacyNamespaces.add(key);
      return null;
    }
  }

  static String? _migrationState(Database db, String key) =>
      db
              .select('SELECT state FROM history_migrations WHERE ns = ?', [
                key,
              ])
              .firstOrNull
              ?.columnAt(0)
          as String?;

  Future<void> _addMarker(SharedPreferences prefs, String key) async {
    final marker = List<String>.of(
      prefs.getStringList(migratedMarkerKey) ?? const [],
    );
    if (marker.contains(key)) return;
    marker.add(key);
    if (!await prefs.setStringList(migratedMarkerKey, marker)) {
      throw StateError('History migration marker rejected write');
    }
  }

  Future<void> _removeMarker(SharedPreferences prefs, String key) async {
    final marker = List<String>.of(
      prefs.getStringList(migratedMarkerKey) ?? const [],
    )..remove(key);
    final ok = marker.isEmpty
        ? await prefs.remove(migratedMarkerKey)
        : await prefs.setStringList(migratedMarkerKey, marker);
    if (!ok) throw StateError('History migration marker rejected write');
  }

  void _fault(String stage, {int? index}) =>
      migrationFaultForTest?.call(stage, index: index);

  Future<void> _migrate(
    Database db,
    SharedPreferences prefs,
    String key,
  ) async {
    final source = prefs.getStringList(key) ?? const <String>[];
    final valid = <_Row>[];
    final quarantine = <({int index, String raw, String reason})>[];
    final ids = <String>{};
    for (var i = 0; i < source.length; i++) {
      final raw = source[i];
      final reason = _corruptReason(raw, ids);
      if (reason != null) {
        quarantine.add((index: i, raw: raw, reason: reason));
      } else {
        valid.add(_Row(sessionIdOf(raw)!, raw));
      }
    }
    final expected = _checksum(valid.map((r) => r.raw));
    db.execute('BEGIN IMMEDIATE');
    try {
      _deleteNamespace(db, key);
      db.execute('DELETE FROM history_quarantine WHERE ns = ?', [key]);
      for (var i = 0; i < valid.length; i++) {
        _fault('import', index: i);
        _upsert(db, key, valid[i].key, i, valid[i].raw, null);
      }
      final now = DateTime.now().toUtc().toIso8601String();
      for (final q in quarantine) {
        db.execute(
          'INSERT INTO history_quarantine(ns, source_index, raw, reason, at) '
          'VALUES (?, ?, ?, ?, ?)',
          [key, q.index, q.raw, q.reason, now],
        );
      }
      db.execute(
        'INSERT OR REPLACE INTO history_migrations'
        '(ns, state, source_count, imported, quarantined, checksum, updated_at)'
        " VALUES (?, 'imported', ?, ?, ?, ?, ?)",
        [key, source.length, valid.length, quarantine.length, expected, now],
      );
      db.execute('COMMIT');
    } catch (_) {
      if (!db.autocommit) db.execute('ROLLBACK');
      rethrow;
    }
    _fault('imported');

    // Verify by reading the DB back: count + checksum over ordered rows.
    final stored = [
      for (final r in db.select(
        'SELECT raw FROM history_rows WHERE ns = ? ORDER BY pos',
        [key],
      ))
        r.columnAt(0) as String,
    ];
    final storedQuarantine =
        db
                .select(
                  'SELECT COUNT(*) FROM history_quarantine WHERE ns = ?',
                  [key],
                )
                .single
                .columnAt(0)
            as int;
    if (stored.length != valid.length ||
        _checksum(stored) != expected ||
        stored.length + storedQuarantine != source.length) {
      throw StateError('History migration verification failed for $key');
    }
    db.execute(
      "UPDATE history_migrations SET state = 'verified', updated_at = ? "
      'WHERE ns = ?',
      [DateTime.now().toUtc().toIso8601String(), key],
    );
    _fault('verified');
    await _addMarker(prefs, key);
    _fault('marked');
    // Only now is the legacy copy redundant. The DB is already authoritative;
    // a failed removal leaves a blob the next launch merges (a no-op here).
    try {
      await prefs.remove(key);
    } catch (error) {
      Diag.swallow('history.migrate.removeLegacy', error);
    }
    final report = SessionHistoryMigrationReport(
      key: key,
      sourceRows: source.length,
      imported: valid.length,
      quarantined: [
        for (final q in quarantine) (index: q.index, reason: q.reason),
      ],
      checksum: expected,
    );
    _reports.add(report);
    if (quarantine.isNotEmpty) {
      Diag.swallow(
        'history.migrate.quarantine',
        StateError(
          '${quarantine.length} unreadable chat row(s) in $key were kept in '
          'quarantine: ${quarantine.map((q) => '#${q.index} ${q.reason}').join(', ')}',
        ),
      );
    }
  }

  /// A leftover blob next to an authoritative DB: the migration was killed
  /// after its marker, or an older build wrote chats. Append unknown sessions,
  /// quarantine differing copies of known ones, then drop the blob.
  Future<void> _mergeLeftover(
    Database db,
    SharedPreferences prefs,
    String key,
  ) async {
    final source = prefs.getStringList(key) ?? const <String>[];
    final existing = {
      for (final r in db.select(
        'SELECT row_key, raw FROM history_rows WHERE ns = ?',
        [key],
      ))
        r.columnAt(0) as String: r.columnAt(1) as String,
    };
    var pos =
        (db
                .select(
                  'SELECT COALESCE(MAX(pos), -1) FROM history_rows '
                  'WHERE ns = ?',
                  [key],
                )
                .single
                .columnAt(0)
            as int) +
        1;
    final now = DateTime.now().toUtc().toIso8601String();
    var appended = 0;
    final quarantined = <({int index, String reason})>[];
    db.execute('BEGIN IMMEDIATE');
    try {
      final ids = <String>{};
      for (var i = 0; i < source.length; i++) {
        final raw = source[i];
        var reason = _corruptReason(raw, ids);
        if (reason == null) {
          final id = sessionIdOf(raw)!;
          final current = existing[id];
          if (current == raw) continue;
          if (current == null) {
            _upsert(db, key, id, pos++, raw, null);
            appended++;
            continue;
          }
          reason = 'superseded legacy copy';
        }
        quarantined.add((index: i, reason: reason));
        db.execute(
          'INSERT INTO history_quarantine(ns, source_index, raw, reason, at) '
          'VALUES (?, ?, ?, ?, ?)',
          [key, i, raw, reason, now],
        );
      }
      db.execute('COMMIT');
    } catch (_) {
      if (!db.autocommit) db.execute('ROLLBACK');
      rethrow;
    }
    _known.remove(key);
    await prefs.remove(key);
    _reports.add(
      SessionHistoryMigrationReport(
        key: key,
        sourceRows: source.length,
        imported: appended,
        quarantined: quarantined,
        checksum: '',
        merged: true,
      ),
    );
  }

  Future<void> _rollback(SharedPreferences prefs, String key) async {
    final db = await _open();
    final rows = [
      for (final r in db.select(
        'SELECT raw FROM history_rows WHERE ns = ? ORDER BY pos',
        [key],
      ))
        r.columnAt(0) as String,
    ];
    final blob = prefs.getStringList(key);
    // A blob written while rolled back (or by an older build) is merged first.
    final merged = [...rows];
    if (blob != null) {
      final known = {for (final r in rows) sessionIdOf(r)};
      merged.addAll(blob.where((r) => !known.contains(sessionIdOf(r))));
    }
    final ok = merged.isEmpty
        ? await prefs.remove(key)
        : await prefs.setStringList(key, merged);
    final readBack = prefs.getStringList(key) ?? const <String>[];
    if (!ok || !listEquals(readBack, merged)) {
      throw StateError('History rollback verification failed for $key');
    }
    db.execute(
      "UPDATE history_migrations SET state = 'rolled_back', updated_at = ? "
      'WHERE ns = ?',
      [DateTime.now().toUtc().toIso8601String(), key],
    );
    await _removeMarker(prefs, key);
    _known.remove(key);
  }

  static String? _corruptReason(String raw, Set<String> seenIds) {
    Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } catch (_) {
      return 'invalid JSON';
    }
    if (decoded is! Map) return 'not a JSON object';
    final id = decoded['id'];
    if (id is! String || id.isEmpty) return 'missing session id';
    if (!seenIds.add(id)) return 'duplicate session id';
    return null;
  }

  static String _checksum(Iterable<String> rows) {
    final out = _DigestSink();
    final input = sha256.startChunkedConversion(out);
    for (final raw in rows) {
      final bytes = utf8.encode(raw);
      input.add(utf8.encode('${bytes.length}:'));
      input.add(bytes);
    }
    input.close();
    return out.value.toString();
  }

  // ── Incremental writes ──────────────────────────────────────────────────

  void _writeSqlite(Database db, String key, List<String> rows) {
    final stored = {
      for (final r in db.select(
        'SELECT row_key, hash, pos FROM history_rows WHERE ns = ?',
        [key],
      ))
        r.columnAt(0) as String: (
          hash: r.columnAt(1) as int,
          pos: r.columnAt(2) as int,
        ),
    };
    if (stored.isNotEmpty && !_readNamespaces.contains(key)) {
      throw StateError(
        'Refusing to overwrite chat history that was not loaded ($key).',
      );
    }
    final known = _known[key] ?? const <String, String>{};
    final next = <String, String>{};
    final keys = rowKeys(rows);
    db.execute('BEGIN IMMEDIATE');
    try {
      for (var i = 0; i < rows.length; i++) {
        final raw = rows[i];
        final rowKey = keys[i];
        next[rowKey] = raw;
        final old = stored[rowKey];
        if (old != null && identical(known[rowKey], raw)) {
          if (old.pos != i) _setPos(db, key, rowKey, i);
          continue;
        }
        final hash = fnv64(raw);
        if (old != null && old.hash == hash) {
          if (old.pos != i) _setPos(db, key, rowKey, i);
          continue;
        }
        _upsert(db, key, rowKey, i, raw, hash);
      }
      for (final rowKey in stored.keys) {
        if (!next.containsKey(rowKey)) _deleteRow(db, key, rowKey);
      }
      db.execute('COMMIT');
    } catch (_) {
      if (!db.autocommit) db.execute('ROLLBACK');
      _known.remove(key);
      rethrow;
    }
    _known[key] = next;
    _readNamespaces.add(key);
  }

  static void _setPos(Database db, String ns, String rowKey, int pos) =>
      db.execute(
        'UPDATE history_rows SET pos = ? WHERE ns = ? AND row_key = ?',
        [pos, ns, rowKey],
      );

  static void _deleteNamespace(Database db, String ns) {
    db.execute(
      'DELETE FROM history_fts WHERE rowid IN '
      '(SELECT fts_rowid FROM history_messages WHERE ns = ?)',
      [ns],
    );
    db.execute('DELETE FROM history_messages WHERE ns = ?', [ns]);
    db.execute('DELETE FROM history_rows WHERE ns = ?', [ns]);
  }

  static void _deleteRow(Database db, String ns, String rowKey) {
    db.execute(
      'DELETE FROM history_fts WHERE rowid IN (SELECT fts_rowid FROM '
      'history_messages WHERE ns = ? AND row_key = ?)',
      [ns, rowKey],
    );
    db.execute('DELETE FROM history_messages WHERE ns = ? AND row_key = ?', [
      ns,
      rowKey,
    ]);
    db.execute('DELETE FROM history_rows WHERE ns = ? AND row_key = ?', [
      ns,
      rowKey,
    ]);
  }

  /// Insert/replace one session row and diff its per-message index rows.
  static void _upsert(
    Database db,
    String ns,
    String rowKey,
    int pos,
    String raw,
    int? hash,
  ) {
    Map<String, dynamic>? json;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) json = decoded;
    } catch (_) {
      // Opaque row: stored byte-for-byte, simply not indexed.
    }
    final sessionId = json?['id'] is String ? json!['id'] as String : null;
    final messages = json?['messages'] is List
        ? json!['messages'] as List
        : const [];
    db.execute(
      'INSERT OR REPLACE INTO history_rows(ns, row_key, session_id, pos, raw, '
      'hash, title, model, parent_id, created_at, updated_at) '
      'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
      [
        ns,
        rowKey,
        sessionId,
        pos,
        raw,
        hash ?? fnv64(raw),
        json?['title'] is String ? json!['title'] : null,
        json?['model'] is String ? json!['model'] : null,
        json?['parentId'] is String ? json!['parentId'] : null,
        json?['createdAt'] is String ? json!['createdAt'] : null,
        _updatedAt(json, messages),
      ],
    );
    final old = {
      for (final r in db.select(
        'SELECT idx, sig, fts_rowid FROM history_messages '
        'WHERE ns = ? AND row_key = ?',
        [ns, rowKey],
      ))
        r.columnAt(0) as int: (sig: r.columnAt(1) as int, rowid: r.columnAt(2)),
    };
    for (var i = 0; i < messages.length; i++) {
      final m = messages[i];
      final indexed = sessionId == null ? null : _indexable(m);
      final sig = indexed == null
          ? 0
          : fnv64('${indexed.role}\u0000${indexed.body}');
      final previous = old.remove(i);
      if (previous != null && previous.sig == sig) continue;
      if (previous?.rowid != null) {
        db.execute('DELETE FROM history_fts WHERE rowid = ?', [
          previous!.rowid,
        ]);
      }
      int? ftsRowid;
      if (indexed != null) {
        db.execute(
          'INSERT INTO history_fts(body, ns, session_id, idx, role) '
          'VALUES (?, ?, ?, ?, ?)',
          [indexed.body, ns, sessionId, i, indexed.role],
        );
        ftsRowid = db.lastInsertRowId;
      }
      db.execute(
        'INSERT OR REPLACE INTO history_messages(ns, row_key, idx, sig, '
        'fts_rowid) VALUES (?, ?, ?, ?, ?)',
        [ns, rowKey, i, sig, ftsRowid],
      );
    }
    for (final entry in old.entries) {
      if (entry.value.rowid != null) {
        db.execute('DELETE FROM history_fts WHERE rowid = ?', [
          entry.value.rowid,
        ]);
      }
      db.execute(
        'DELETE FROM history_messages WHERE ns = ? AND row_key = ? AND idx = ?',
        [ns, rowKey, entry.key],
      );
    }
  }

  static String? _updatedAt(Map<String, dynamic>? json, List messages) {
    if (json == null) return null;
    if (json['updatedAt'] is String) return json['updatedAt'] as String;
    final last = messages.isEmpty ? null : messages.last;
    if (last is Map && last['time'] is String) return last['time'] as String;
    return json['createdAt'] is String ? json['createdAt'] as String : null;
  }

  static ({String role, String body})? _indexable(Object? message) {
    if (message is! Map) return null;
    final role = message['role'];
    final kind = message['kind'] ?? 'text';
    final content = message['content'];
    if (role != 'user' && role != 'assistant') return null;
    if (kind != 'text' && kind != 'streaming') return null;
    if (content is! String || content.trim().isEmpty) return null;
    return (
      role: role as String,
      body: content.length > maxIndexedBodyLength
          ? content.substring(0, maxIndexedBodyLength)
          : content,
    );
  }

  // ── Row identity ────────────────────────────────────────────────────────

  static final _idPrefix = RegExp(r'\{"id":("(?:[^"\\]|\\.)*")[,}]');

  /// Session id of an encoded row: a prefix match for AppState's own
  /// encoding (`{"id":...`), else a full decode. Null for opaque rows.
  static String? sessionIdOf(String raw) {
    final m = _idPrefix.matchAsPrefix(raw);
    if (m != null) {
      try {
        final id = jsonDecode(m.group(1)!);
        if (id is String && id.isNotEmpty) return id;
      } catch (_) {}
    }
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map && decoded['id'] is String) {
        final id = decoded['id'] as String;
        return id.isEmpty ? null : id;
      }
    } catch (_) {}
    return null;
  }

  /// Stable, unique storage key per row: the session id, with a suffix for
  /// duplicates; opaque rows are keyed by content hash.
  @visibleForTesting
  static List<String> rowKeys(List<String> rows) {
    final used = <String>{};
    return [
      for (final raw in rows)
        () {
          final base =
              sessionIdOf(raw) ??
              '~raw:${fnv64(raw).toUnsigned(64).toRadixString(16)}';
          var candidate = base;
          for (var n = 1; !used.add(candidate); n++) {
            candidate = '$base~dup$n';
          }
          return candidate;
        }(),
    ];
  }

  /// FNV-1a 64 over UTF-16 code units — a cheap change detector (not a MAC).
  static int fnv64(String s) {
    var h = 0xcbf29ce484222325;
    for (var i = 0; i < s.length; i++) {
      h ^= s.codeUnitAt(i);
      h *= 0x100000001b3;
    }
    return h;
  }
}

class _DigestSink implements Sink<Digest> {
  late Digest value;
  @override
  void add(Digest data) => value = data;
  @override
  void close() {}
}

class _Row {
  _Row(this.key, this.raw);
  final String key;
  final String raw;
}

/// Thrown by migration tests to model a process death at a checkpoint.
class SimulatedCrash implements Exception {
  const SimulatedCrash(this.stage);
  final String stage;
  @override
  String toString() => 'SimulatedCrash($stage)';
}

class SessionHistoryMigrationReport {
  const SessionHistoryMigrationReport({
    required this.key,
    required this.sourceRows,
    required this.imported,
    required this.quarantined,
    required this.checksum,
    this.merged = false,
  });

  final String key;
  final int sourceRows;
  final int imported;
  final List<({int index, String reason})> quarantined;
  final String checksum;

  /// True for a leftover-blob merge rather than a first migration.
  final bool merged;
}

class SessionContentHit {
  const SessionContentHit({
    required this.sessionId,
    required this.messageIndex,
    required this.role,
    required this.snippet,
  });

  final String sessionId;
  final int messageIndex;
  final String role;

  /// Excerpt with matches wrapped in [SessionHistoryRepository.highlightStart]
  /// / [SessionHistoryRepository.highlightEnd].
  final String snippet;
}
