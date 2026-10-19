// P8 Task 20 — one-time, consented, resumable history import.
//
// The thin client keeps the pre-cloud stores around only long enough to move
// their transcripts into Ovid Cloud (spec §13.3). This service is the whole
// client-side import contract:
//
//   * [plan] is strictly read-only: it counts the local transcript rows and
//     reports the per-account "already imported" marker. It never opens a
//     network connection and never writes a preference.
//   * [run] refuses to do anything (including a single HTTP request) unless
//     the caller passed `consent: true` (Review Focus #5).
//   * Transcripts are uploaded through the built
//     `POST /cloud/v1/import/sessions` route (Task 4): at most
//     [HistoryImportService.maxMessagesPerCall] messages per call, with a
//     deterministic `clientMsgId` per message so a re-run is idempotent even
//     if the progress marker was lost.
//   * Per-session progress is durable (`ovid_cloud_import_progress_<uid>`), so
//     a NEW service instance resumes after the last chunk a previous process
//     attempted instead of re-sending completed chunks.
//   * The ledger and personal-memory stores have NO server REST surface. They
//     are reported as `skipped (server endpoint not live)` — never silently
//     dropped and never pretended to have been imported.
//
// The constructor accepts the pinned `{rest, history, prefs}` arguments. The
// optional [account] and [memoryRoot] seams exist so the later login wiring can
// name the current account explicitly and so tests never touch path_provider.

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../session_history_store.dart';
import 'cloud_rest.dart';
import 'models.dart';

/// What [HistoryImportService.plan] found before anything was uploaded.
class HistoryImportPlan {
  const HistoryImportPlan({
    required this.sessions,
    required this.messages,
    required this.alreadyImported,
  });

  /// Transcript sessions found in the account's durable namespace.
  final int sessions;

  /// Messages across those sessions (including messages whose role the server
  /// cannot represent; those are counted as skipped by [run]).
  final int messages;

  /// True when this account already completed an import.
  final bool alreadyImported;
}

/// Outcome of one [HistoryImportService.run].
class HistoryImportResult {
  const HistoryImportResult({
    required this.imported,
    required this.skipped,
    required this.failedSessionKeys,
  });

  /// Messages the server accepted (`ImportReport.imported` summed).
  final int imported;

  /// Everything the import deliberately did not upload: messages the server
  /// already had (its idempotent `skipped` count), messages whose local role
  /// is not in the server enum, and every ledger event / memory file (those
  /// stores have no endpoint — see [HistoryImportService.skippedEndpointNotLive]).
  final int skipped;

  /// Local session keys whose upload failed. Their progress marker records how
  /// far the previous run got; a later run resumes from there.
  final List<String> failedSessionKeys;
}

/// One account's consented, chunked, resumable history import.
class HistoryImportService {
  HistoryImportService({
    required CloudRestClient rest,
    required SessionHistoryRepository history,
    required SharedPreferences prefs,
    String? account,
    Directory? memoryRoot,
    bool Function(String localSessionId)? isCloudSession,
  }) {
    _rest = rest;
    _history = history;
    _prefs = prefs;
    _account = account ?? _detectAccount(prefs);
    _memoryRoot = memoryRoot;
    _isCloudSession = isCloudSession;
  }

  /// True for a local row that already has a server copy (excluded from the
  /// scan so the import never duplicates it).
  late final bool Function(String localSessionId)? _isCloudSession;

  /// `POST /import/sessions` rejects a batch larger than this (Task 4's
  /// `import_too_large`). Keep the client at the same boundary.
  static const int maxMessagesPerCall = 500;

  /// Exact stage text for stores that have no server REST surface.
  static const String skippedEndpointNotLive =
      'skipped (server endpoint not live)';

  /// Stage text when the user has not consented yet.
  static const String stageNoConsent = 'skipped (no consent)';

  /// Stage text when this account already completed an import.
  static const String stageAlreadyImported = 'skipped (already imported)';

  static const String stageTranscripts = 'transcripts';
  static const String stageLedger = 'ledger';
  static const String stageMemory = 'memory';
  static const String stageDone = 'done';

  /// Roles the gateway's import schema accepts (`user|assistant|system|tool`).
  static const Set<String> _serverRoles = {
    'user',
    'assistant',
    'system',
    'tool',
  };

  late final CloudRestClient _rest;
  late final SessionHistoryRepository _history;
  late final SharedPreferences _prefs;
  late final String _account;
  late final Directory? _memoryRoot;

  // ── Read-only planning ───────────────────────────────────────────────────

  /// Scan the durable transcript store and read the completion marker.
  ///
  /// No network and no preference writes. (Ledger/memory are deliberately not
  /// touched here: scanning them during `plan` would make the read-only
  /// promise depend on filesystem state. They are counted during [run], where
  /// the import is already a mutating operation.)
  Future<HistoryImportPlan> plan() async {
    final sessions = await _scanSessions();
    return HistoryImportPlan(
      sessions: sessions.length,
      messages: sessions.fold<int>(0, (sum, s) => sum + s.messages.length),
      alreadyImported: _readDone(),
    );
  }

  // ── Import ───────────────────────────────────────────────────────────────

  /// Upload the local transcript history in chunks.
  ///
  /// [onProgress] receives a human-readable stage and a 0..1 fraction. Stages
  /// that need special handling by the UI:
  ///   * [stageNoConsent] — nothing was read from the network.
  ///   * [stageAlreadyImported] — nothing was uploaded.
  ///   * [skippedEndpointNotLive] — the ledger/memory stores cannot be
  ///     imported because the gateway exposes no route for them.
  Future<HistoryImportResult> run(
    void Function(String stage, double progress) onProgress, {
    required bool consent,
  }) async {
    // Consent is enforced HERE, not only in the sheet: without it there is no
    // scan and no request (Review Focus #5).
    if (!consent) {
      _emit(onProgress, stageNoConsent, 0);
      return const HistoryImportResult(
        imported: 0,
        skipped: 0,
        failedSessionKeys: <String>[],
      );
    }
    if (_readDone()) {
      _emit(onProgress, stageAlreadyImported, 0);
      return const HistoryImportResult(
        imported: 0,
        skipped: 0,
        failedSessionKeys: <String>[],
      );
    }

    _emit(onProgress, stageTranscripts, 0);
    final sessions = await _scanSessions();
    final progress = _readProgress();
    var imported = 0;
    var skipped = 0;
    final failed = <String>[];

    for (var s = 0; s < sessions.length; s++) {
      final session = sessions[s];
      final chunks = _chunks(session);
      final saved = progress[session.key];

      // Unknown roles are skipped locally. Count them once, on the run that
      // first processes this session (a resume must not double-count them).
      if (saved == null) {
        skipped += session.messages.where((m) => !m.importable).length;
      }

      final start = saved?.nextChunk ?? 0;
      if (start >= chunks.length) {
        // Completed in an earlier run (or nothing to send). Do not touch the
        // network; make a fresh zero-chunk session resumable too.
        if (saved == null) {
          progress[session.key] = _SessionProgress(
            nextChunk: chunks.length,
            completed: chunks.length,
            serverSessionId: null,
          );
          await _writeProgress(progress);
        }
        _emit(onProgress, 'session ${session.key}', _fraction(s, sessions.length, 1));
        continue;
      }

      var serverSessionId = saved?.serverSessionId;
      var sessionFailed = false;
      for (var c = start; c < chunks.length; c++) {
        final chunk = chunks[c];
        final batch = <ImportMessage>[
          for (final message in chunk)
            ImportMessage(
              // Deterministic idempotency key: the same local message always
              // produces the same key, so a re-run cannot duplicate it even
              // when the progress marker is missing.
              clientMsgId: _clientMsgId(session.key, message),
              role: message.role,
              content: message.content,
              createdAt: message.createdAt,
            ),
        ];
        final firstChunk = serverSessionId == null;
        try {
          final report = await _rest.importMessages(
            // Continuation id: once the first chunk created (or resolved) the
            // server session, every later chunk — including a resumed one —
            // must land in the SAME session.
            sessionId: serverSessionId,
            title: firstChunk ? session.title : null,
            createdAt: firstChunk ? session.createdAt : null,
            messages: batch,
          );
          imported += report.imported;
          skipped += report.skipped;
          serverSessionId = report.sessionId;
          progress[session.key] = _SessionProgress(
            nextChunk: c + 1,
            completed: c + 1,
            serverSessionId: serverSessionId,
          );
          await _writeProgress(progress);
          _emit(
            onProgress,
            'session ${session.key} chunk ${c + 1}/${chunks.length}',
            _fraction(s, sessions.length, (c + 1) / chunks.length),
          );
        } catch (_) {
          // A mid-session network failure must not abort the whole import or
          // lose the marker. Record both the chunks the server acknowledged
          // (`completed`) and the resume point (`nextChunk`). Per the pinned
          // resume contract a failure at chunk 3 of 10 resumes at chunk 4.
          // The one exception is the LAST chunk: advancing past it would mark
          // the session complete although its final messages never landed, so
          // that chunk is retried on the next run instead.
          sessionFailed = true;
          failed.add(session.key);
          final lastChunk = c + 1 >= chunks.length;
          progress[session.key] = _SessionProgress(
            nextChunk: lastChunk ? c : c + 1,
            completed: c,
            serverSessionId: serverSessionId,
          );
          await _writeProgress(progress);
          _emit(
            onProgress,
            'session ${session.key} failed',
            _fraction(s, sessions.length, (c + 1) / chunks.length),
          );
          break;
        }
      }
      if (sessionFailed) continue;
    }

    // Ledger and memory: the gateway has no route for either (transcripts are
    // the whole import scope). Report the skip explicitly — never drop them
    // silently and never claim they were imported.
    _emit(onProgress, stageLedger, 0.9);
    skipped += await _scanLedgerEvents();
    _emit(onProgress, skippedEndpointNotLive, 0.9);

    _emit(onProgress, stageMemory, 0.95);
    skipped += await _scanMemoryFiles();
    _emit(onProgress, skippedEndpointNotLive, 0.95);

    // Only a run with no failed sessions completes the one-time marker; a
    // partial run leaves it unset so the next launch can resume.
    if (failed.isEmpty) {
      await _prefs.setBool(_doneKey, true);
    }
    _emit(onProgress, stageDone, 1);
    return HistoryImportResult(
      imported: imported,
      skipped: skipped,
      failedSessionKeys: List<String>.unmodifiable(failed),
    );
  }

  // ── Store scanning ───────────────────────────────────────────────────────

  /// Raw `ChatSession` rows for the current account.
  ///
  /// `AppState` namespaces transcripts `ovid_sessions` for guests and
  /// `ovid_sessions_owner_<encoded account>` for signed-in accounts
  /// (state.dart `_accountKey`). The second candidate covers callers/tests
  /// that name the account by bare UID instead of `firebase:<uid>`; the first
  /// non-empty namespace wins.
  Future<List<String>> _readTranscriptRows() async {
    for (final key in _namespaceKeys()) {
      final rows = await _history.readRows(_prefs, key);
      if (rows != null && rows.isNotEmpty) return rows;
    }
    return const <String>[];
  }

  /// Only chats that exist on THIS device alone are importable (SE-015):
  ///   * rows keyed by a server UUID are cloud chats the session store
  ///     reconciled into the same namespace — uploading them again would
  ///     duplicate every cloud chat;
  ///   * rows the caller knows are already on the server ([_isCloudSession],
  ///     e.g. a local chat mapped to a server session after its first send);
  ///   * rows with no importable message (the auto-created empty chat).
  Future<List<_LocalSession>> _scanSessions() async {
    final rows = await _readTranscriptRows();
    final sessions = <_LocalSession>[];
    for (final row in rows) {
      final session = _parseSession(row);
      if (session == null) continue;
      if (_serverUuid.hasMatch(session.key)) continue;
      if (_isCloudSession?.call(session.key) ?? false) continue;
      if (!session.messages.any((m) => m.importable)) continue;
      sessions.add(session);
    }
    return sessions;
  }

  /// Server session ids are UUIDs (v7); local ids are microsecond stamps.
  static final RegExp _serverUuid = RegExp(
    r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-'
    r'[0-9a-fA-F]{12}$',
  );

  /// Parse the persisted `ChatSession.toJson` shape. Raw JSON is used rather
  /// than `ChatSession.fromJson` so a row without `time` gets a deterministic
  /// timestamp (the session's `createdAt`, else the epoch) instead of
  /// `DateTime.now()` — a wall clock here would change the idempotency key on
  /// every run.
  _LocalSession? _parseSession(String raw) {
    Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } catch (_) {
      return null;
    }
    if (decoded is! Map) return null;
    final json = Map<String, dynamic>.from(decoded);

    final id = json['id'];
    final key = id is String && id.isNotEmpty
        ? id
        : 'row-${sha256.convert(utf8.encode(raw)).toString().substring(0, 16)}';
    final titleRaw = json['title'];
    final title =
        titleRaw is String && titleRaw.trim().isNotEmpty ? titleRaw : null;
    final createdAt = _parseTime(json['createdAt']);

    final messages = <_LocalMessage>[];
    final rawMessages = json['messages'];
    if (rawMessages is List) {
      for (var i = 0; i < rawMessages.length; i++) {
        final entry = rawMessages[i];
        if (entry is! Map) continue;
        final message = Map<String, dynamic>.from(entry);
        final roleRaw = message['role'];
        final role = roleRaw is String && roleRaw.isNotEmpty ? roleRaw : 'user';
        final contentRaw = message['content'];
        messages.add(
          _LocalMessage(
            // The ORIGINAL position, including unimportable roles: inserting
            // or skipping a role must not shift another message's key.
            index: i,
            role: role,
            content: contentRaw is String ? contentRaw : '',
            createdAt: _parseTime(message['time']) ??
                createdAt ??
                DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
          ),
        );
      }
    }

    return _LocalSession(
      key: key,
      title: title,
      createdAt: createdAt,
      messages: messages,
    );
  }

  static DateTime? _parseTime(Object? value) =>
      value is String ? DateTime.tryParse(value) : null;

  List<List<_LocalMessage>> _chunks(_LocalSession session) {
    final importable = <_LocalMessage>[
      for (final message in session.messages)
        if (message.importable) message,
    ];
    final chunks = <List<_LocalMessage>>[];
    for (var i = 0; i < importable.length; i += maxMessagesPerCall) {
      chunks.add(
        importable.sublist(
          i,
          math.min(i + maxMessagesPerCall, importable.length),
        ),
      );
    }
    return chunks;
  }

  /// sha256 over the stable local identity of one message. 64 hex chars is
  /// exactly the server's `clientMsgId` limit.
  String _clientMsgId(String sessionKey, _LocalMessage message) {
    final input = <String>[
      sessionKey,
      '${message.index}',
      message.role,
      message.createdAt.toUtc().toIso8601String(),
      message.content,
    ].join('\u0000');
    return sha256.convert(utf8.encode(input)).toString();
  }

  /// Events in `<docs>/session-ledgers/*.jsonl` — the directory the retired
  /// local ledger wrote (P8 Task 20). The files are read directly because the
  /// ledger module no longer exists; the count feeds the same
  /// `skipped (server endpoint not live)` report. Best-effort: an unreadable
  /// ledger contributes zero and never fails the import.
  Future<int> _scanLedgerEvents() async {
    try {
      final docs = await getApplicationDocumentsDirectory();
      final dir = Directory('${docs.path}/session-ledgers');
      if (!await dir.exists()) return 0;
      var count = 0;
      await for (final entity in dir.list(followLinks: false)) {
        if (entity is! File || !entity.path.endsWith('.jsonl')) continue;
        try {
          final lines = await entity.readAsLines();
          count += lines.where((line) => line.trim().isNotEmpty).length;
        } catch (_) {
          // A single unreadable ledger contributes zero.
        }
      }
      return count;
    } catch (_) {
      return 0;
    }
  }

  /// Markdown files under the account's personal-memory root. The root is
  /// derived exactly like `AppState._memoryRootForAccount`:
  /// `<documents>/personal-memory` for guests and
  /// `<documents>/personal-memory/account-<sha256(account)>` otherwise.
  Future<int> _scanMemoryFiles() async {
    try {
      final root = _memoryRoot ?? await _defaultMemoryRoot();
      if (root == null || !await root.exists()) return 0;
      var count = 0;
      await for (final entity
          in root.list(recursive: true, followLinks: false)) {
        if (entity is File && entity.path.toLowerCase().endsWith('.md')) {
          count++;
        }
      }
      return count;
    } catch (_) {
      return 0;
    }
  }

  Future<Directory?> _defaultMemoryRoot() async {
    try {
      final docs = await getApplicationDocumentsDirectory();
      final base = Directory('${docs.path}/personal-memory');
      if (_account == 'guest') return base;
      return Directory(
        '${base.path}/account-${sha256.convert(utf8.encode(_account))}',
      );
    } catch (_) {
      // No path_provider (unit tests, desktop): nothing to count.
      return null;
    }
  }

  // ── Account-scoped prefs ─────────────────────────────────────────────────

  List<String> _namespaceKeys() {
    if (_account == 'guest') return const <String>['ovid_sessions'];
    final keys = <String>[
      'ovid_sessions_owner_${Uri.encodeComponent(_account)}',
    ];
    final bare = _markerAccount(_account);
    if (bare != _account) {
      keys.add('ovid_sessions_owner_${Uri.encodeComponent(bare)}');
    }
    return keys;
  }

  /// `AppState` stores accounts as `firebase:<uid>`; the plan pins the marker
  /// names as `ovid_cloud_import_{done,progress}_<uid>`.
  static String _markerAccount(String account) => account.startsWith('firebase:')
      ? account.substring('firebase:'.length)
      : account;

  String get _doneKey => 'ovid_cloud_import_done_${_markerAccount(_account)}';

  String get _progressKey =>
      'ovid_cloud_import_progress_${_markerAccount(_account)}';

  bool _readDone() {
    final value = _prefs.get(_doneKey);
    return value == true || value == 'true';
  }

  Map<String, _SessionProgress> _readProgress() {
    final raw = _prefs.getString(_progressKey);
    if (raw == null || raw.isEmpty) return <String, _SessionProgress>{};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return <String, _SessionProgress>{};
      final out = <String, _SessionProgress>{};
      for (final entry in decoded.entries) {
        if (entry.key is String && entry.value is Map) {
          out[entry.key as String] = _SessionProgress.fromJson(
            Map<String, dynamic>.from(entry.value as Map),
          );
        }
      }
      return out;
    } catch (_) {
      // A torn/corrupt marker must never block an import.
      return <String, _SessionProgress>{};
    }
  }

  Future<void> _writeProgress(Map<String, _SessionProgress> progress) async {
    final encoded = <String, Object>{
      for (final entry in progress.entries) entry.key: entry.value.toJson(),
    };
    await _prefs.setString(_progressKey, jsonEncode(encoded));
  }

  /// Best-effort progress callback: a UI exception must not abort an import.
  static void _emit(
    void Function(String stage, double progress) onProgress,
    String stage,
    double progress,
  ) {
    try {
      onProgress(stage, progress.clamp(0.0, 1.0).toDouble());
    } catch (_) {
      // Progress reporting is never allowed to fail the import.
    }
  }

  static double _fraction(int index, int total, double within) {
    if (total <= 0) return 0;
    // Leave the tail for the ledger/memory stages.
    return ((index + within) / total).clamp(0.0, 0.85).toDouble();
  }

  /// Fallback account discovery when the caller does not pass [account].
  ///
  /// Prefers the namespaces already present in prefs (including namespaces
  /// recorded by the SQLite migration). Ambiguity is resolved deterministically;
  /// the login wiring should pass the account explicitly.
  static String _detectAccount(SharedPreferences prefs) {
    final candidates = <String>{};
    void consider(Iterable<String> keys) {
      for (final key in keys) {
        const prefix = 'ovid_sessions_owner_';
        if (!key.startsWith(prefix)) continue;
        final suffix = key.substring(prefix.length);
        if (suffix.isEmpty) continue;
        try {
          candidates.add(Uri.decodeComponent(suffix));
        } catch (_) {
          // Ignore a malformed namespace key.
        }
      }
    }

    consider(prefs.getKeys());
    consider(
      prefs.getStringList(SessionHistoryRepository.migratedMarkerKey) ??
          const <String>[],
    );
    if (candidates.isEmpty) return 'guest';
    final sorted = candidates.toList()..sort();
    return sorted.first;
  }
}

class _LocalSession {
  const _LocalSession({
    required this.key,
    required this.title,
    required this.createdAt,
    required this.messages,
  });

  final String key;
  final String? title;
  final DateTime? createdAt;
  final List<_LocalMessage> messages;
}

class _LocalMessage {
  const _LocalMessage({
    required this.index,
    required this.role,
    required this.content,
    required this.createdAt,
  });

  final int index;
  final String role;
  final String content;
  final DateTime createdAt;

  bool get importable => HistoryImportService._serverRoles.contains(role);
}

class _SessionProgress {
  const _SessionProgress({
    required this.nextChunk,
    required this.completed,
    required this.serverSessionId,
  });

  factory _SessionProgress.fromJson(Map<String, dynamic> json) {
    final completed = (json['completed'] as num?)?.toInt() ?? 0;
    return _SessionProgress(
      nextChunk: (json['nextChunk'] as num?)?.toInt() ?? completed,
      completed: completed,
      serverSessionId: json['sessionId'] as String?,
    );
  }

  /// Chunk index the next run starts from.
  final int nextChunk;

  /// Chunks the server acknowledged. On a failure this is one less than
  /// [nextChunk]; the failed boundary is treated as attempted.
  final int completed;

  /// Server-side session created by the first successful chunk, so a resumed
  /// run continues the same session instead of starting another one.
  final String? serverSessionId;

  Map<String, Object?> toJson() => <String, Object?>{
        'nextChunk': nextChunk,
        'completed': completed,
        'sessionId': serverSessionId,
      };
}
