import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'diag.dart';
import 'workspace_files.dart';

/// Audit 2026-09-25 §2 — what one [RepoCache.sync] actually managed to fetch.
/// Every way the working copy can end up PARTIAL is counted here so callers
/// can surface the truth instead of trusting a bare "synced ✓ N files".
@immutable
class SyncReport {
  SyncReport({
    required this.requested,
    required this.fetched,
    required this.skippedByFilter,
    required this.treeTruncated,
    required this.droppedByCap,
    required List<String> failedPaths,
    required List<String> unattemptedPaths,
    required List<String> preservedPaths,
    this.localWorkspace = false,
    this.traversalDeadlineExceeded = false,
  }) : failedPaths = List.unmodifiable(failedPaths),
       unattemptedPaths = List.unmodifiable(unattemptedPaths),
       preservedPaths = List.unmodifiable(preservedPaths);

  /// Files this sync intended to fetch (after the skip filter and the cap).
  final int requested;

  /// Files fetched successfully and published into [RepoCache.files].
  final int fetched;

  /// Tree blobs excluded by the binary/vendor skip filter (by design).
  final int skippedByFilter;

  /// The Trees API answered `truncated: true` — GitHub itself cut the tree
  /// before our cap even applied (audit 2026-09-25 §2).
  final bool treeTruncated;

  /// Eligible files not fetched because of the `maxFiles` cap.
  final int droppedByCap;

  /// Files whose content fetch failed even after retries.
  final List<String> failedPaths;

  /// Files never attempted because the overall deadline passed.
  final List<String> unattemptedPaths;

  /// Dirty files whose local edit was preserved over fresh upstream content
  /// (audit 2026-09-25 §1) — a potential-conflict list callers may show.
  final List<String> preservedPaths;
  final bool localWorkspace;
  final bool traversalDeadlineExceeded;

  bool get deadlineExceeded => traversalDeadlineExceeded || unattemptedPaths.isNotEmpty;

  /// True when the in-memory copy is NOT the whole repo.
  bool get partial =>
      treeTruncated ||
      droppedByCap > 0 ||
      failedPaths.isNotEmpty ||
      deadlineExceeded;

  /// Human-readable problems only (excludes by-design filtering and the
  /// preserved-edits note). Suitable for a toast or an agent reply.
  List<String> get issues {
    final out = <String>[];
    if (treeTruncated) {
      out.add(localWorkspace
          ? 'Workspace traversal stopped at its limit — more files may exist'
          : 'GitHub TRUNCATED the repo tree — some files were never listed');
    }
    if (droppedByCap > 0) {
      out.add('$droppedByCap files left out by the sync cap');
    }
    if (failedPaths.isNotEmpty) {
      out.add(
        '${failedPaths.length} fetch failed (${_fmtPaths(failedPaths)})',
      );
    }
    if (deadlineExceeded) {
      out.add(traversalDeadlineExceeded
          ? 'deadline exceeded — workspace traversal is incomplete'
          : 'deadline exceeded — ${unattemptedPaths.length} files not attempted');
    }
    return out;
  }

  /// One honest line a caller can render verbatim.
  String get summary {
    final parts = <String>['synced $fetched/$requested files', ...issues];
    if (preservedPaths.isNotEmpty) {
      parts.add('${preservedPaths.length} local edits preserved');
    }
    return parts.join(' · ');
  }
}

String _fmtPaths(List<String> paths) {
  final shown = paths.take(3).join(', ');
  return paths.length > 3 ? '$shown, … +${paths.length - 3} more' : shown;
}

// Dart's UTF-8 decoder consumes a leading BOM. Working-copy text must retain
// it so re-encoding and approval comparisons represent the actual file bytes.
String _decodeFileBytes(List<int> bytes, {bool allowMalformed = false}) {
  final bom = bytes.length >= 3 && bytes[0] == 0xef && bytes[1] == 0xbb && bytes[2] == 0xbf;
  return '${bom ? '\uFEFF' : ''}${utf8.decode(bytes, allowMalformed: allowMalformed)}';
}

/// Why a [RepoCache.fetchFileResult] call did not return content.
/// `none` means success (audit 2026-09-25 §6: no-token, 401 and 404 all used
/// to collapse into the same silent `null`).
enum FetchFailure {
  none,
  notBound,
  noToken,
  unauthorized,
  forbidden,
  notFound,
  server,
  timeout,
  network,
  unknown,
}

/// Result of [RepoCache.fetchFileResult]: content plus a classifyable
/// failure. [ok] is the only success signal callers should trust.
@immutable
class FetchResult {
  const FetchResult(this.content, this.failure);
  final String? content;
  final FetchFailure failure;
  bool get ok => failure == FetchFailure.none && content != null;
}

/// How the last successful [RepoCache.commitAll] pushed (audit §4).
enum CommitMode {
  /// ONE commit + ONE ref update via the Git Data API.
  atomic,

  /// Legacy contents-API mode, retained for API compatibility.
  perFile,
}

enum CommitFailureKind { staleApproval, upstreamConflict, unknown, persistence, busy, unsupported }

class CommitFailure implements Exception {
  const CommitFailure(this.kind, this.message, {this.intendedSha});
  final CommitFailureKind kind;
  final String message;
  final String? intendedSha;
  @override
  String toString() => message;
}

/// A read-only review artifact. Only RepoCache can construct one; publication
/// takes this artifact rather than a mutable message/path selection.
@immutable
class CommitApproval {
  CommitApproval._({required this.repo, required this.branch,
    required this.baseCommit, required this.baseTree, required this.message,
    required this.binding, required this.generation,
    required Map<String, String?> contents, required Map<String, String?> originals,
    required Map<String, String> modes, required Map<String, String?> originalModes,
    required Map<String, String?> stagedModes, required Map<String, String?> revisions})
       : contents = Map.unmodifiable(contents), originals = Map.unmodifiable(originals),
         modes = Map.unmodifiable(modes), originalModes = Map.unmodifiable(originalModes),
         _stagedModes = Map.unmodifiable(stagedModes), _revisions = Map.unmodifiable(revisions);
  final String repo, branch, baseCommit, baseTree, message, binding;
  final int generation;
  final Map<String, String?> contents, originals;
  final Map<String, String> modes;
  final Map<String, String?> originalModes;
  final Map<String, String?> _stagedModes, _revisions;
  List<String> get paths => List.unmodifiable(contents.keys);

  /// Full-file unified hunks avoid a misleading truncated/summary-only diff.
  /// Missing trailing newlines are explicit, including for empty files.
  String get diff {
    final out = StringBuffer();
    List<String> lines(String? text) {
      if (text == null || text.isEmpty) return [];
      final parts = text.split('\n');
      if (parts.last.isEmpty) parts.removeLast();
      return parts;
    }
    void body(String? text, String prefix) {
      for (final line in lines(text)) { out.writeln('$prefix$line'); }
      if (text != null && text.isNotEmpty && !text.endsWith('\n')) {
        out.writeln(r'\ No newline at end of file');
      }
    }
    for (final path in paths) {
      final before = originals[path], after = contents[path];
      final quoted = jsonEncode(path);
      out.writeln('diff --git $quoted $quoted');
      out.writeln(before == null ? 'new file mode ${modes[path]}' :
          after == null ? 'deleted file mode ${originalModes[path]}' :
          originalModes[path] != modes[path] ? 'old mode ${originalModes[path]}\nnew mode ${modes[path]}' :
          'file mode ${modes[path]} (unchanged)');
      if (before == after) continue;
      out.writeln('--- ${before == null ? '/dev/null' : 'a/$quoted'}');
      out.writeln('+++ ${after == null ? '/dev/null' : 'b/$quoted'}');
      out.writeln('@@ -${lines(before).isEmpty ? 0 : 1},${lines(before).length} +${lines(after).isEmpty ? 0 : 1},${lines(after).length} @@');
      body(before, '-');
      body(after, '+');
    }
    return out.toString();
  }
}

/// What the last successful [RepoCache.commitAll] actually did.
@immutable
class CommitInfo {
  const CommitInfo({
    required this.mode,
    required this.files,
    required this.branch,
    this.commitSha,
  });
  final CommitMode mode;
  final int files;
  final String branch;

  /// The single commit SHA in [CommitMode.atomic] mode; null for the
  /// per-file fallback (which produces one SHA per file).
  final String? commitSha;
}

/// RepoCache — clones the user's connected GitHub repo into app storage
/// (Git Trees API, recursive) so the agent can vibe-code the WHOLE project:
///
///   • listRepoTree()  → every file path (fast, 1 API call)
///   • readAll()       → load file contents into memory map
///   • write()         → local edit (pending commit)
///   • sync()          → refresh; returns an honest [SyncReport], keeps edits
///   • commitAll()     → push pending edits as ONE atomic commit
///   • exportPreview() → copy web projects (html/css/js) for live preview
class RepoCache extends ChangeNotifier {
  RepoCache._();
  static final RepoCache I = RepoCache._();

  // Admission is keyed by the remote ref, not session: two sessions may target
  // the same ref. An admitted call owns it through persistence and publication.
  static final Set<String> _commitAdmissions = {};
  static final _retainedIntents = Expando<Map<String, Map<String, dynamic>>>();
  static final _intentStorageKeys = Expando<Map<String, Set<String>>>();
  static const _intentPrefix = 'ovid.repo.pending.v1.';
  String _intentKey(String repo, String branch) =>
      '$_intentPrefix${base64Url.encode(utf8.encode(jsonEncode([repo.toLowerCase(), branch])))}';

  // v1 used the display spelling. Discover all legacy aliases without deleting
  // or overwriting an unresolved intent. They retire only after exact proof.
  String? _canonicalIntentKey(String storedKey) {
    if (!storedKey.startsWith(_intentPrefix)) return null;
    try {
      final parts = jsonDecode(utf8.decode(base64Url.decode(storedKey.substring(_intentPrefix.length)))) as List;
      if (parts.length != 2 || parts.any((p) => p is! String)) return null;
      return _intentKey(parts[0] as String, parts[1] as String);
    } catch (_) {
      return null;
    }
  }

  String _canonicalCopyKey(String key) {
    final parts = jsonDecode(key) as List;
    if (parts.length != 4) throw const FormatException('invalid owner binding');
    if (parts[1] is String) parts[1] = (parts[1] as String).toLowerCase();
    return jsonEncode(parts);
  }

  Future<Map<String, dynamic>?> _loadIntent(String key) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final retained = _retainedIntents[prefs] ??= {};
      if (retained.containsKey(key)) return retained[key];
      final storageKeys = prefs.getKeys().where((k) => _canonicalIntentKey(k) == key).toSet();
      if (storageKeys.isEmpty) return null;
      Map<String, dynamic>? found;
      for (final storedKey in storageKeys) {
        final record = jsonDecode(prefs.getString(storedKey)!) as Map<String, dynamic>;
        if (record['sha'] is! String || (record['sha'] as String).isEmpty ||
            record['pending'] is! Map || record['owner'] is! String ||
            record['repo'] is! String || record['branch'] is! String ||
            key != _intentKey(record['repo'] as String, record['branch'] as String) ||
            (record['pending'] as Map).isEmpty ||
            (record['pending'] as Map).entries.any((e) => e.key is! String || (e.value != null && e.value is! String))) {
          throw const FormatException('invalid pending commit');
        }
        record['owner'] = _canonicalCopyKey(record['owner'] as String);
        if (record.containsKey('version') && record['version'] != 2) {
          throw const FormatException('unsupported intent version');
        }
        if (record['version'] == 2) {
          for (final field in ['modes', 'revisions']) {
            final values = record[field];
            if (values is! Map || !setEquals(values.keys.toSet(), (record['pending'] as Map).keys.toSet()) ||
                values.values.any((v) => field == 'modes' ? !['100644', '100755'].contains(v) : v is! String)) {
              throw const FormatException('invalid staging intent');
            }
          }
        }
        if (found != null && (found['sha'] != record['sha'] || found['owner'] != record['owner'] ||
            !mapEquals(found['pending'] as Map, record['pending'] as Map) ||
            found['version'] != record['version'] ||
            !mapEquals(found['modes'] as Map?, record['modes'] as Map?) ||
            !mapEquals(found['revisions'] as Map?, record['revisions'] as Map?))) {
          throw const FormatException('conflicting legacy intents');
        }
        found = record;
      }
      (_intentStorageKeys[prefs] ??= {})[key] = storageKeys;
      retained[key] = found!;
      return found;
    } catch (_) {
      // Decoder/platform errors can embed persisted source bytes. Never copy
      // them into a tool result or diagnostic; retain the fence and record.
      throw const CommitFailure(CommitFailureKind.persistence,
          'Cannot read pending commit intent; stored recovery data is invalid or unavailable');
    }
  }

  Future<void> _saveIntent(String key, Map<String, dynamic> record) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!await prefs.setString(key, jsonEncode(record))) {
        throw StateError('preferences write rejected');
      }
      (_retainedIntents[prefs] ??= {})[key] = record;
      (_intentStorageKeys[prefs] ??= {})[key] = {key};
    } catch (_) {
      throw const CommitFailure(CommitFailureKind.persistence,
          'Cannot persist pending commit intent; ref update not sent');
    }
  }

  Future<void> _clearIntent(String key) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      // A failed removal must not make the optimistic preferences cache authorize
      // another mutation. Keep the retained record until removal is acknowledged.
      for (final storedKey in _intentStorageKeys[prefs]?[key] ?? {key}) {
        if (!await prefs.remove(storedKey)) {
          throw const CommitFailure(CommitFailureKind.persistence, 'Cannot clear reconciled commit intent; retry reconciliation');
        }
      }
      _retainedIntents[prefs]?.remove(key);
      _intentStorageKeys[prefs]?.remove(key);
    } catch (_) {
      throw const CommitFailure(CommitFailureKind.persistence,
          'Cannot clear reconciled commit intent; retry reconciliation');
    }
  }

  Future<int?> _recoverIntent(String repo, String branch, String token,
      http.Client client, int generation) async {
    final key = _intentKey(repo, branch);
    final record = await _loadIntent(key);
    _ensureBinding(generation);
    if (record == null) return null;
    final sha = record['sha'] as String;
    String? observed;
    try {
      final response = await _sendRetried(() {
        _ensureBinding(generation);
        return client.get(_apiUri('repos/$repo/git/ref/heads/$branch'),
            headers: {'Authorization': 'Bearer $token', 'Accept': 'application/vnd.github+json'});
      });
      _ensureBinding(generation);
      if (response.statusCode == 200) {
        observed = (jsonDecode(response.body)['object'] as Map?)?['sha'] as String?;
      }
    } on StateError {
      rethrow;
    } catch (_) {
      // No proof of publication: retain the intent even if the base is unchanged.
    }
    _ensureBinding(generation);
    if (observed != sha) {
      throw CommitFailure(CommitFailureKind.unknown,
          'commit outcome unknown for $repo "$branch": intended commit $sha; observed ref ${observed ?? 'unavailable'} — pending intent retained; read-only reconciliation required',
          intendedSha: sha);
    }
    final pending = Map<String, String?>.from(record['pending'] as Map);
    final modes = record['version'] == 2 ? Map<String, String>.from(record['modes'] as Map) : null;
    final revisions = record['version'] == 2 ? Map<String, String>.from(record['revisions'] as Map) : null;
    if (record['owner'] == _copyKey) {
      _dropPushed(pending, modes: modes, revisions: revisions);
    } else {
      final owner = record['owner'] as String;
      final saved = _workingCopies[owner];
      final workspace = (jsonDecode(owner) as List)[3] as String?;
      if (saved != null) {
        _accountPushed(pending, modes: modes, revisions: revisions, workspace: workspace,
            contents: saved.files, dirty: saved.dirty, unsaved: saved.unsaved,
            deletions: saved.deletions, stagedModes: saved.modes, edits: saved.revisions);
      }
    }
    // Account for confirmed bytes before asynchronous storage cleanup: a bind
    // during remove must save the already-reconciled working copy, not drafts
    // which could be blindly replayed after the durable fence disappears.
    await _clearIntent(key);
    _ensureBinding(generation);
    _lastCommit = CommitInfo(mode: CommitMode.atomic, files: pending.length,
        branch: branch, commitSha: sha);
    notifyListeners();
    return pending.length;
  }

  static const _api = 'https://api.github.com';

  /// Per-request timeout. Public + mutable so tests can shrink it
  /// (precedent: `GitHubService.profileRetryDelay`).
  Duration requestTimeout = const Duration(seconds: 20);

  /// Base delay for the exponential backoff on transient failures
  /// (429/5xx/timeout/network). Public + mutable for tests.
  /// Audit 2026-09-25 §8: a secondary rate limit used to drop files silently.
  Duration retryBaseDelay = const Duration(milliseconds: 500);

  /// Overall wall-clock budget for one [sync]. When it passes, sync stops
  /// starting new fetches, publishes what it has, and reports the rest as
  /// unattempted — never silently (audit 2026-09-25 §8).
  static const defaultSyncDeadline = Duration(seconds: 120);

  /// Max overlapping content fetches during [sync] (audit 2026-09-25 §8: the
  /// loop used to be fully sequential — 400 × 20 s worst case — despite the
  /// comment claiming "small batches").
  static const defaultSyncConcurrency = 6;

  /// Total tries per HTTP call: 1 + 2 retries on transient failures.
  static const int _maxAttempts = 3;

  /// Blob uploads during an atomic commit — smaller than the sync pool
  /// because these are writes.
  static const int _blobConcurrency = 4;

  static const Set<int> _transientStatuses = {429, 500, 502, 503, 504};
  static const Duration _retryAfterCap = Duration(seconds: 60);

  String? repoFull; // "owner/repo"
  String? _token; // from GitHubService after login
  String? defaultBranch;

  /// The session that owns the current binding, when the caller supplied one.
  /// This is a lightweight guard against cross-session bleed: the cache is a
  /// singleton, so callers can detect that the working copy belongs to another
  /// session and rebind before trusting [files]. A full per-session cache is
  /// out of scope.
  String? _boundSessionId;
  String? get boundSessionId => _boundSessionId;

  int _bindingGeneration = 0;
  /// UI actions opened under an older binding must not target the current one.
  int get bindingGeneration => _bindingGeneration;
  String? workspaceFolder;
  final Set<String> _unsaved = {};
  final Map<String, ({Map<String, String> files, Set<String> dirty, Set<String> unsaved,
    List<String> tree, Set<String> deletions, Map<String, String> modes,
    Map<String, String> revisions})> _workingCopies = {};
  final Set<String> _deletions = {};
  final Map<String, String> _stagedModes = {};
  final Map<String, String> _revisions = {};
  // Persistable edit identities distinguish a newer intent even when its bytes
  // and mode return to the approved values, including after process restart.
  void _edited(String path) {
    _revisions[path] = base64Url.encode(List.generate(18, (_) => Random.secure().nextInt(256)));
    _dirty.add(path);
  }
  String? stagedMode(String path) => _stagedModes[path];
  bool isStagedDeletion(String path) => _deletions.contains(path);
  String get _copyKey => jsonEncode([
    _boundSessionId, repoFull?.toLowerCase(), defaultBranch, workspaceFolder,
  ]);

  /// path → content (working copy)
  final Map<String, String> files = {};
  final Set<String> _dirty = {}; // locally modified paths
  final List<String> treePaths = []; // all paths from git tree
  DateTime? lastSync;

  SyncReport? _lastSyncReport;

  /// The report of the most recent [sync] — callers that cannot consume the
  /// return value (e.g. fired-and-forgotten syncs) can still surface the
  /// truth about partial copies (audit 2026-09-25 §2).
  SyncReport? get lastSyncReport => _lastSyncReport;

  CommitInfo? _lastCommit;

  /// What the most recent successful [commitAll] did (audit 2026-09-25 §4).
  CommitInfo? get lastCommit => _lastCommit;

  bool get isReady => repoFull != null && files.isNotEmpty;
  bool get hasPending => _dirty.isNotEmpty;
  List<String> get pendingPaths => List.unmodifiable(_dirty.toList()..sort());
  int get dirtyCount => _dirty.length;

  @override
  void notifyListeners() => super.notifyListeners();

  // ── init ─────────────────────────────────────────────────────────────
  void bind(
    String full,
    String token, {
    String branch = 'main',
    String? sessionId,
    String? workspaceFolder,
  }) {
    final oldKey = _copyKey;
    final newKey = jsonEncode([sessionId, full.toLowerCase(), branch, workspaceFolder]);
    if (oldKey != newKey) {
      _workingCopies[oldKey] = (
        files: Map.of(files), dirty: Set.of(_dirty), unsaved: Set.of(_unsaved), tree: List.of(treePaths),
        deletions: Set.of(_deletions), modes: Map.of(_stagedModes), revisions: Map.of(_revisions),
      );
      final saved = _workingCopies.remove(newKey);
      files..clear()..addAll(saved?.files ?? {});
      _dirty..clear()..addAll(saved?.dirty ?? {});
      _unsaved..clear()..addAll(saved?.unsaved ?? {});
      _deletions..clear()..addAll(saved?.deletions ?? {});
      _stagedModes..clear()..addAll(saved?.modes ?? {});
      _revisions..clear()..addAll(saved?.revisions ?? {});
      treePaths..clear()..addAll(saved?.tree ?? []);
      lastSync = null;
      _lastSyncReport = null;
      _lastCommit = null;
    }
    _bindingGeneration++;
    repoFull = full;
    _token = token;
    defaultBranch = branch;
    _boundSessionId = sessionId;
    this.workspaceFolder = workspaceFolder;
    // Audit 2026-09-25 §7: listeners used to learn about a new binding only
    // when the next sync finished (or failed). Notify at bind time; the
    // generation bump above still keeps any in-flight sync of the OLD
    // binding from publishing over the new one.
    notifyListeners();
  }

  /// Disconnect — clear everything so Studio shows the login state again.
  void unbind() {
    _bindingGeneration++;
    repoFull = null;
    _token = null;
    defaultBranch = null;
    _boundSessionId = null;
    workspaceFolder = null;
    _workingCopies.clear();
    _unsaved.clear();
    _deletions.clear();
    _stagedModes.clear();
    _revisions.clear();
    files.clear();
    treePaths.clear();
    _dirty.clear();
    lastSync = null;
    _lastSyncReport = null;
    _lastCommit = null;
    notifyListeners();
  }

  // ── sync from GitHub ─────────────────────────────────────────────────
  /// Fetches the recursive git tree (single API call) then file contents
  /// under a bounded pool with retries and an overall [deadline].
  /// [maxFiles] keeps memory sane on huge repos — everything the cap, the
  /// skip filter, fetch failures or the deadline left out is counted on the
  /// returned [SyncReport] (audit 2026-09-25 §2), never silently dropped.
  ///
  /// Uncommitted work is NEVER discarded (audit 2026-09-25 §1 — the old
  /// `_dirty.clear()` threw pending edits away on every re-sync): dirty
  /// files are re-applied over the refreshed content, stay dirty, and are
  /// listed on [SyncReport.preservedPaths]. A dirty file whose local copy
  /// now equals upstream is no longer pending.
  ///
  /// A PARTIAL sync does not throw — check `report.partial` and surface
  /// `report.summary`. Only binding loss and auth death throw.
  Future<SyncReport> sync({
    int maxFiles = 2000,
    void Function(String line)? onLine,
    http.Client? client,
    Duration deadline = defaultSyncDeadline,
    int concurrency = defaultSyncConcurrency,
  }) async {
    if (workspaceFolder != null) {
      return _syncWorkspace(maxFiles: maxFiles, deadline: deadline);
    }
    final repo = repoFull;
    final token = _token;
    final branch = defaultBranch ?? 'main';
    final generation = _bindingGeneration;
    if (repo == null || token == null || token.isEmpty) {
      throw Exception('repo not bound');
    }

    final c = client ?? http.Client();
    final deadlineAt = DateTime.now().add(deadline);
    try {
      onLine?.call('fetching tree of $repo …');
      final tree = await _getTree(repo, token, branch, c);
      final blobPaths = tree.entries
          .where((e) => e['type'] == 'blob')
          .map((e) => e['path'] as String)
          .toList();
      // Segment-boundary skip matching (audit 2026-09-25 §3).
      final okPaths = blobPaths.where((p) => !shouldSkipPath(p)).toList();
      final skippedByFilter = blobPaths.length - okPaths.length;

      final take = okPaths.length > maxFiles
          ? okPaths.sublist(0, maxFiles)
          : okPaths;
      final droppedByCap = okPaths.length - take.length;

      final syncedFiles = <String, String>{};
      final failedPaths = <String>[];
      final unattempted = <String>[];

      // Bounded-concurrency fetch (audit 2026-09-25 §8). A per-file failure
      // is counted, never swallowed into a fake "synced ✓"; only auth death
      // and binding loss abort the whole sync.
      var done = 0;
      await _forEachConcurrent(take, concurrency, (p) async {
        _ensureBinding(generation);
        if (DateTime.now().isAfter(deadlineAt)) {
          unattempted.add(p);
          return;
        }
        final r = await _fetchRaw(
          repo,
          token,
          p,
          branch,
          c,
          deadlineAt: deadlineAt,
        );
        _ensureBinding(generation);
        if (r.content != null) {
          syncedFiles[p] = r.content!;
        } else if (r.status == 401 || r.status == 403) {
          // A dead token mid-sync fails every remaining file; abort loudly
          // instead of publishing a hollow copy.
          throw Exception(
            r.status == 401
                ? 'authentication failed (401) — aborting sync of $repo'
                : 'authorization failed or rate-limited (403) — aborting sync of $repo',
          );
        } else {
          failedPaths.add(p);
        }
        done++;
        if (done % 25 == 0) {
          onLine?.call('synced $done / ${take.length} files');
        }
      });
      _ensureBinding(generation);

      // Publish atomically: a failed sync never mutates the working copy.
      final previousFiles = Map<String, String>.of(files);
      final previousDirty = Set<String>.of(_dirty);
      treePaths
        ..clear()
        ..addAll(take);
      files
        ..clear()
        ..addAll(syncedFiles);

      // Audit 2026-09-25 §1: re-apply uncommitted edits over the refreshed
      // content. A dirty file whose local copy now EQUALS upstream has
      // nothing pending anymore; anything else keeps the local bytes, stays
      // dirty, and stays visible in the tree even when the fetch failed or
      // upstream deleted the path.
      final preserved = <String>[];
      for (final p in previousDirty) {
        final local = previousFiles[p];
        if (_deletions.contains(p)) {
          // Absence in a dirty entry is an explicit staged deletion.
          files.remove(p);
          treePaths.remove(p);
          preserved.add(p);
          continue;
        }
        if (syncedFiles[p] == local && !_stagedModes.containsKey(p)) continue;
        if (local != null) files[p] = local;
        preserved.add(p);
        if (!treePaths.contains(p)) treePaths.add(p);
      }
      _dirty
        ..clear()
        ..addAll(preserved);

      lastSync = DateTime.now();
      final report = SyncReport(
        requested: take.length,
        fetched: syncedFiles.length,
        skippedByFilter: skippedByFilter,
        treeTruncated: tree.truncated,
        droppedByCap: droppedByCap,
        failedPaths: failedPaths,
        unattemptedPaths: unattempted,
        preservedPaths: preserved,
      );
      _lastSyncReport = report;
      final issues = report.issues;
      onLine?.call(
        issues.isEmpty
            ? 'repo synced ✓ ${files.length} files in memory'
                  '${preserved.isEmpty ? '' : ' · ${preserved.length} local edit${preserved.length == 1 ? '' : 's'} preserved'}'
            : 'repo synced ⚠ ${files.length} files in memory · ${issues.join(' · ')}',
      );
      notifyListeners();
      return report;
    } finally {
      if (client == null) c.close();
    }
  }

  void _ensureBinding(int generation) {
    if (generation != _bindingGeneration) {
      throw StateError('repository binding changed');
    }
  }

  /// A selected on-disk checkout is authoritative, including untracked files
  /// and edits made by shell tools. Never replace it with GitHub API bytes.
  Future<SyncReport> _syncWorkspace({required int maxFiles, required Duration deadline}) async {
    final root = Directory(workspaceFolder!);
    final generation = _bindingGeneration;
    final deadlineAt = DateTime.now().add(deadline);
    final paths = <String>[];
    final contents = <String, String>{};
    final failed = <String>[];
    var skipped = 0;
    var truncated = false;
    var timedOut = false;
    var entries = 0;
    // Bound directory-only trees too, and avoid an unbounded recursion stack.
    final pending = <({Directory dir, String prefix})>[(dir: root, prefix: '')];
    bool stop() {
      _ensureBinding(generation);
      if (!DateTime.now().isBefore(deadlineAt)) {
        timedOut = true;
        return true;
      }
      if (paths.length >= maxFiles || entries >= 20000) {
        truncated = true;
        return true;
      }
      return false;
    }
    while (pending.isNotEmpty && !stop()) {
      final next = pending.removeLast();
      final dir = next.dir;
      final prefix = next.prefix;
      if (prefix.isNotEmpty && workspaceFilePath(root, prefix) == null) continue;
      await for (final entry in dir.list(followLinks: false).timeout(
        deadlineAt.difference(DateTime.now()),
        onTimeout: (sink) {
          timedOut = true;
          sink.close();
        },
      )) {
        if (stop()) break;
        entries++;
        final name = entry.uri.pathSegments.where((s) => s.isNotEmpty).last;
        final path = '$prefix$name';
        if (entry is Link || shouldSkipPath(entry is Directory ? '$path/' : path)) {
          skipped++;
          continue;
        }
        if (entry is Directory) {
          pending.add((dir: entry, prefix: '$path/'));
        } else if (entry is File) {
          paths.add(path);
          try {
            final safe = workspaceFilePath(root, path);
            if (safe == null) throw StateError('Workspace path is a symlink: $path');
            final file = File(safe);
            final bytes = await file.openRead(0, 2 * 1024 * 1024 + 1)
                .fold<List<int>>([], (all, chunk) => all..addAll(chunk))
                .timeout(deadlineAt.difference(DateTime.now()));
            if (bytes.length > 2 * 1024 * 1024) {
              failed.add(path);
            } else {
              contents[path] = _decodeFileBytes(bytes);
            }
          } catch (error, stack) {
            Diag.swallow('repo_cache.syncWorkspace', error, stack);
            failed.add(path);
            if (error is TimeoutException) timedOut = true;
          }
        }
        if (timedOut) break;
      }
      if (timedOut || truncated) break;
    }
    _ensureBinding(generation);
    // Reapply drafts from the LIVE map: edits may have arrived during traversal.
    final drafts = {for (final p in _unsaved) if (files[p] != null) p: files[p]!};
    files..clear()..addAll(contents);
    files.addAll(drafts);
    for (final path in _deletions.toList()) { _refreshDeletion(path); }
    treePaths..clear()..addAll({...paths, ...drafts.keys, ..._dirty});
    final report = SyncReport(requested: paths.length, fetched: contents.length,
      skippedByFilter: skipped, treeTruncated: truncated, droppedByCap: 0,
      failedPaths: failed, localWorkspace: true, traversalDeadlineExceeded: timedOut,
      unattemptedPaths: [], preservedPaths: {...drafts.keys, ..._dirty}.toList());
    lastSync = DateTime.now();
    _lastSyncReport = report;
    notifyListeners();
    return report;
  }

  /// Runs [body] over [items] with at most [concurrency] tasks in flight.
  /// The first thrown error aborts the run (remaining items are not started)
  /// and is rethrown with its original stack.
  Future<void> _forEachConcurrent<T>(
    List<T> items,
    int concurrency,
    Future<void> Function(T item) body,
  ) async {
    if (items.isEmpty) return;
    var next = 0;
    Object? failure;
    StackTrace? failureStack;
    Future<void> worker() async {
      while (failure == null) {
        final i = next++;
        if (i >= items.length) return;
        try {
          await body(items[i]);
        } catch (e, s) {
          failure ??= e;
          failureStack ??= s;
          return;
        }
      }
    }

    await Future.wait([
      for (var w = concurrency.clamp(1, items.length); w > 0; w--) worker(),
    ]);
    if (failure != null) Error.throwWithStackTrace(failure!, failureStack!);
  }

  /// Drop the in-memory working copy without changing the binding. Used when a
  /// sync fails so stale files from a previous repo/branch are never shown
  /// under the new binding.
  void clearWorkingCopy() {
    final staged = {..._deletions, ..._stagedModes.keys};
    final drafts = workspaceFolder == null ? <String, String>{} : {
      for (final path in _unsaved) if (files[path] != null) path: files[path]!,
    };
    for (final path in _stagedModes.keys) {
      if (files[path] != null) drafts[path] = files[path]!;
    }
    final unsaved = _unsaved.intersection(drafts.keys.toSet());
    files.clear();
    treePaths.clear();
    _dirty.clear();
    _unsaved.clear();
    files.addAll(drafts);
    treePaths.addAll(drafts.keys);
    _dirty.addAll({...drafts.keys, ...staged});
    _unsaved.addAll(unsaved);
    _revisions.removeWhere((path, _) => !_dirty.contains(path));
    lastSync = null;
    _lastSyncReport = null;
    notifyListeners();
  }

  /// Directory patterns are matched on SEGMENT boundaries (audit 2026-09-25
  /// §3): `build/` skips `build/x` and `a/build/x` but never `src/rebuild/x`.
  static const List<String> _skipDirPatterns = [
    'node_modules/',
    '.git/',
    'build/',
    '.dart_tool/',
    'dist/',
    'android/app/build/',
    'ios/Pods/',
  ];

  /// Extension patterns are matched as an EXACT suffix, case-insensitively
  /// (audit 2026-09-25 §3): `.png` skips `logo.PNG` but never `notes.png.md`,
  /// `.bin` never eats `lib/foo.binding.dart`.
  static const List<String> _skipExtensions = [
    '.png',
    '.jpg',
    '.jpeg',
    '.gif',
    '.webp',
    '.ico',
    '.woff',
    '.woff2',
    '.ttf',
    '.zip',
    '.jar',
    '.so',
    '.apk',
    '.pdf',
    '.mp4',
    '.bin',
  ];

  /// True when [path] is a binary/vendor file the working copy deliberately
  /// leaves out. The old `path.contains(pattern)` match silently vanished
  /// source files like `lib/foo.binding.dart` from the agent's and Studio's
  /// worldview (audit 2026-09-25 §3).
  @visibleForTesting
  static bool shouldSkipPath(String path) {
    for (final dir in _skipDirPatterns) {
      if (path.startsWith(dir) || path.contains('/$dir')) return true;
    }
    final lower = path.toLowerCase();
    for (final ext in _skipExtensions) {
      if (lower.endsWith(ext)) return true;
    }
    return false;
  }

  Future<({List<Map<String, dynamic>> entries, bool truncated})> _getTree(
    String repo,
    String token,
    String branch,
    http.Client client,
  ) async {
    // `{tree_sha}` is a single path segment, so a branch like `feature/x`
    // must be percent-encoded or it routes to a different endpoint (404).
    // The repo part is encoded per segment like every other API URL.
    final res = await _sendRetried(
      () => client.get(
        Uri.parse(
          '$_api/repos/${_encodeApiPath(repo)}/git/trees/'
          '${Uri.encodeComponent(branch)}?recursive=1',
        ),
        headers: {
          'Authorization': 'Bearer $token',
          'Accept': 'application/vnd.github+json',
        },
      ),
    );
    if (res.statusCode != 200) {
      throw Exception('tree fetch ${res.statusCode}');
    }
    final j = jsonDecode(res.body) as Map<String, dynamic>;
    final entries =
        (j['tree'] as List? ?? const []).cast<Map<String, dynamic>>();
    // Audit 2026-09-25 §2: GitHub sets `truncated: true` when the recursive
    // tree is too large to return whole. Ignoring it silently hid part of
    // the repo BEFORE our own cap even applied.
    return (entries: entries, truncated: j['truncated'] == true);
  }

  /// Builds an API URL with PER-SEGMENT percent-encoding (audit 2026-09-25
  /// §5): the old whole-path `Uri.encodeComponent` turned `/` into `%2F`,
  /// disagreeing with `GitHubService._encodeApiPath` (the test-covered form).
  static Uri _apiUri(String path, {Map<String, String>? query}) {
    final encoded = _encodeApiPath(path);
    if (query == null || query.isEmpty) return Uri.parse('$_api/$encoded');
    final q = query.entries
        .map(
          (e) =>
              '${Uri.encodeQueryComponent(e.key)}=${Uri.encodeQueryComponent(e.value)}',
        )
        .join('&');
    return Uri.parse('$_api/$encoded?$q');
  }

  /// Mirrors `GitHubService._encodeApiPath`: encode each segment, preserve
  /// `/` separators.
  static String _encodeApiPath(String p) =>
      p.split('/').map(Uri.encodeComponent).join('/');

  /// One raw content fetch, classified instead of flattened to `null`
  /// (audit 2026-09-25 §2/§6). Never throws ordinary failures — they come
  /// back on the record; only binding [StateError]s propagate.
  Future<({int? status, String? content, Object? error})> _fetchRaw(
    String repo,
    String token,
    String path,
    String branch,
    http.Client client, {
    DateTime? deadlineAt,
  }) async {
    try {
      final res = await _sendRetried(
        () => client.get(
          _apiUri('repos/$repo/contents/$path', query: {'ref': branch}),
          headers: {
            'Authorization': 'Bearer $token',
            'Accept': 'application/vnd.github.raw',
          },
        ),
        deadlineAt: deadlineAt,
      );
      if (res.statusCode != 200) {
        return (status: res.statusCode, content: null, error: null);
      }
      return (
        status: 200,
        content: _decodeFileBytes(res.bodyBytes, allowMalformed: true),
        error: null,
      );
    } on StateError {
      rethrow;
    } catch (e) {
      return (status: null, content: null, error: e);
    }
  }

  /// Runs one HTTP call with up to [_maxAttempts] tries, retrying transient
  /// failures (429/5xx/timeouts/network, and 403s that GitHub marks as rate
  /// limits) with exponential backoff and `Retry-After` support — audit
  /// 2026-09-25 §8. Non-transient results (200, 401, 404 …) return
  /// immediately; exhausted transients throw [_TransientExhausted] or the
  /// last network error. [deadlineAt] stops retries that cannot finish in
  /// time.
  Future<http.Response> _sendRetried(
    Future<http.Response> Function() send, {
    DateTime? deadlineAt,
  }) async {
    Object? last;
    for (var attempt = 1; attempt <= _maxAttempts; attempt++) {
      try {
        final res = await send().timeout(requestTimeout);
        if (!_isTransientStatus(res)) return res;
        last = _TransientExhausted(
          res.statusCode,
          attempt,
          retryAfter: _retryAfter(res),
        );
      } on StateError {
        rethrow; // binding guards must reach the caller untouched
      } catch (e) {
        if (!_isTransientError(e)) rethrow;
        last = e;
      }
      if (attempt == _maxAttempts) break;
      final delay = _backoffFor(last, attempt);
      if (deadlineAt != null && DateTime.now().add(delay).isAfter(deadlineAt)) {
        break;
      }
      await Future<void>.delayed(delay);
    }
    throw last ?? Exception('request failed');
  }

  bool _isTransientStatus(http.Response res) =>
      _transientStatuses.contains(res.statusCode) ||
      // GitHub signals secondary rate limits as 403 + Retry-After or a
      // "rate limit" body; a plain 403 (no permission) is NOT transient.
      (res.statusCode == 403 &&
          (res.headers.containsKey('retry-after') ||
              res.body.toLowerCase().contains('rate limit')));

  static bool _isTransientError(Object e) =>
      e is TimeoutException ||
      e is http.ClientException ||
      e is SocketException;

  static Duration? _retryAfter(http.Response res) {
    final v = res.headers['retry-after'];
    if (v == null) return null;
    final secs = int.tryParse(v.trim());
    return secs == null ? null : Duration(seconds: secs);
  }

  Duration _backoffFor(Object last, int attempt) {
    if (last is _TransientExhausted && last.retryAfter != null) {
      final ra = last.retryAfter!;
      return ra > _retryAfterCap ? _retryAfterCap : ra;
    }
    return retryBaseDelay * (1 << (attempt - 1));
  }

  // ── working copy ops (agent edits land here first) ───────────────────
  void write(String path, String content) {
    _validateWorkspacePath(path);
    _deletions.remove(path);
    files[path] = content;
    _edited(path);
    if (workspaceFolder != null) _unsaved.add(path);
    notifyListeners();
  }

  String? read(String path) {
    final root = workspaceFolder;
    if (root != null) {
      try {
        final safe = workspaceFilePath(Directory(root), path);
        if (safe == null) return null;
        if (_unsaved.contains(path)) return files[path];
        final file = File(safe);
        if (FileSystemEntity.typeSync(safe, followLinks: false) != FileSystemEntityType.file) return null;
        return _decodeFileBytes(file.readAsBytesSync());
      } catch (error, stack) {
        Diag.swallow('repo_cache.readWorkspace', error, stack);
        return null;
      }
    }
    return files[path];
  }

  /// A successful disk save clears draft status, not pending-commit status.
  void didSaveWorkspaceFile(String path, String content) {
    if (files[path] == content) _unsaved.remove(path);
  }

  void _validateWorkspacePath(String path) {
    final root = workspaceFolder;
    if (root != null && workspaceFilePath(Directory(root), path) == null) {
      throw StateError('Path escapes workspace or uses a symlink: $path');
    }
  }

  /// Public on-demand fetch for a path that exists in the repo tree but was
  /// never synced into memory (e.g. Studio file-tree tap). Returns the real
  /// file content and CACHES it into [files] (audit 2026-09-25 §6 — the
  /// docstring always promised this; the code never did it), unless the path
  /// holds a dirty local edit, which is never clobbered. Returns null when
  /// unreachable; [fetchFileResult] says WHY.
  Future<String?> fetchFile(String path, {http.Client? client}) async =>
      (await fetchFileResult(path, client: client)).content;

  /// [fetchFile] with a distinguishable failure reason. The old version sent
  /// `Bearer ` (empty token) and flattened no-token / 401 / 404 / network
  /// death into the same silent `null` (audit 2026-09-25 §6).
  Future<FetchResult> fetchFileResult(
    String path, {
    http.Client? client,
  }) async {
    if (workspaceFolder != null) {
      final content = read(path);
      return FetchResult(content,
        content == null ? FetchFailure.notFound : FetchFailure.none);
    }
    final repo = repoFull;
    final token = _token;
    if (repo == null) {
      final cached = files[path];
      return FetchResult(
        cached,
        cached != null ? FetchFailure.none : FetchFailure.notBound,
      );
    }
    if (token == null || token.isEmpty) {
      // Never fire a doomed request: an empty Bearer token guarantees a 401
      // that used to be indistinguishable from a missing file.
      return FetchResult(files[path], FetchFailure.noToken);
    }
    final branch = defaultBranch ?? 'main';
    final generation = _bindingGeneration;
    final c = client ?? http.Client();
    try {
      final r = await _fetchRaw(repo, token, path, branch, c);
      _ensureBinding(generation);
      if (r.content != null) {
        if (!_dirty.contains(path)) {
          files[path] = r.content!;
          notifyListeners();
        }
        return FetchResult(r.content, FetchFailure.none);
      }
      return FetchResult(null, _failureOf(r));
    } finally {
      if (client == null) c.close();
    }
  }

  static FetchFailure _failureOf(({int? status, String? content, Object? error}) r) {
    final s = r.status;
    if (s == 401) return FetchFailure.unauthorized;
    if (s == 403) return FetchFailure.forbidden;
    if (s == 404) return FetchFailure.notFound;
    if (s != null && (s >= 500 || s == 429)) return FetchFailure.server;
    final e = r.error;
    if (e is _TransientExhausted) {
      if (e.status >= 500 || e.status == 429) return FetchFailure.server;
      if (e.status == 403) return FetchFailure.forbidden;
      return FetchFailure.unknown;
    }
    if (e is TimeoutException) return FetchFailure.timeout;
    if (e != null) return FetchFailure.network;
    return FetchFailure.unknown;
  }

  bool exists(String path) => files.containsKey(path);

  void create(String path, String content) {
    _validateWorkspacePath(path);
    _deletions.remove(path);
    files[path] = content;
    _edited(path);
    if (workspaceFolder != null) _unsaved.add(path);
    if (!treePaths.contains(path)) treePaths.add(path);
    notifyListeners();
  }

  void remove(String path) {
    files.remove(path);
    _dirty.remove(path);
    _unsaved.remove(path);
    _deletions.remove(path);
    _stagedModes.remove(path);
    _revisions.remove(path);
    treePaths.remove(path);
  }

  /// Stages only an already-missing checkout path; never deletes disk bytes.
  /// Remote-cache deletion is likewise an explicit operation, not read failure.
  void stageDeletion(String path) {
    final safe = _stagingPath(path);
    if (safe != null && _checkedType(safe) != FileSystemEntityType.notFound) {
      throw const CommitFailure(CommitFailureKind.unsupported,
          'Only an already-missing checkout file can be staged for deletion. No disk files were changed.');
    }
    files.remove(path);
    _unsaved.remove(path);
    _stagedModes.remove(path);
    _deletions.add(path);
    _edited(path);
    treePaths.remove(path);
    notifyListeners();
  }

  /// Proposes a Git executable bit without changing checkout permissions.
  void stageMode(String path, String mode) {
    if (!['100644', '100755'].contains(mode)) {
      throw const CommitFailure(CommitFailureKind.unsupported, 'Only regular Git modes 100644 and 100755 are supported');
    }
    if (_commitContent(path) == null) {
      throw const CommitFailure(CommitFailureKind.unsupported, 'Cannot stage a mode for a deleted file');
    }
    _stagedModes[path] = mode;
    _edited(path);
    notifyListeners();
  }

  String? _stagingPath(String path) {
    if (path.isEmpty || path.contains('\\') || path.contains('\u0000') ||
        path.split('/').any((p) => p.isEmpty || p == '.' || p == '..')) {
      throw const CommitFailure(CommitFailureKind.unsupported, 'Staging requires a repository-relative canonical file path');
    }
    if (workspaceFolder == null) return null;
    final safe = workspaceFilePath(Directory(workspaceFolder!), path);
    if (safe == null) {
      throw const CommitFailure(CommitFailureKind.unsupported, 'Staging path escapes the workspace or uses a symlink');
    }
    var parent = File(safe).parent;
    final root = Directory(workspaceFolder!).resolveSymbolicLinksSync();
    while (parent.path != root) {
      final type = _checkedType(parent.path);
      if (type != FileSystemEntityType.directory && type != FileSystemEntityType.notFound) {
        throw const CommitFailure(CommitFailureKind.unsupported, 'Staging path has a non-directory parent');
      }
      parent = parent.parent;
    }
    return safe;
  }

  /// dart:io's typeSync/statSync hide *all* lookup errors as notFound. Only
  /// an error-preserving lookup reporting ENOENT proves absence. EACCES,
  /// ENOTDIR, I/O errors and unclassified failures must never approve a delete.
  FileSystemEntityType _checkedType(String path) {
    final type = FileSystemEntity.typeSync(path, followLinks: false);
    if (type != FileSystemEntityType.notFound) return type;
    try {
      File(path).resolveSymbolicLinksSync();
    } on FileSystemException catch (e) {
      final code = e.osError?.errorCode;
      // POSIX ENOENT; Windows ERROR_FILE_NOT_FOUND / ERROR_PATH_NOT_FOUND.
      if (code == 2 || (Platform.isWindows && code == 3)) {
        return FileSystemEntityType.notFound;
      }
    }
    // Successful resolution after notFound is a racing/inconsistent lookup,
    // not proof of absence either. Keep diagnostics free of local file bytes.
    throw const CommitFailure(CommitFailureKind.unsupported,
        'Cannot confirm workspace path state; lookup failed or changed. Retry when accessible.');
  }

  void _refreshDeletion(String path) {
    if (!_deletions.contains(path) || workspaceFolder == null) return;
    final safe = _stagingPath(path);
    if (_checkedType(safe!) == FileSystemEntityType.file) {
      _deletions.remove(path);
      _edited(path);
    }
  }

  String? _commitContent(String path) {
    final safe = _stagingPath(path);
    _refreshDeletion(path);
    if (safe != null) {
      final type = _checkedType(safe);
      if (type != FileSystemEntityType.file && type != FileSystemEntityType.notFound) {
        throw const CommitFailure(CommitFailureKind.unsupported, 'Cannot stage a non-regular workspace file');
      }
    }
    if (_deletions.contains(path)) return null;
    final content = read(path);
    if (content == null) {
      throw const CommitFailure(CommitFailureKind.unsupported,
          'Selected bytes are missing or unreadable; deletion requires explicit staging');
    }
    return content;
  }

  /// List files of a folder (children names) for the Studio tree UI.
  List<(String name, bool isDir)> listDir(String dir) {
    final prefix = dir.isEmpty ? '' : '$dir/';
    final seen = <String>{};
    final out = <(String, bool)>[];
    for (final p in treePaths) {
      if (!p.startsWith(prefix)) continue;
      final rest = p.substring(prefix.length);
      final seg = rest.split('/').first;
      if (seg.isEmpty || seen.contains(seg)) continue;
      seen.add(seg);
      out.add((seg, rest.contains('/')));
    }
    return out;
  }

  // ── commit pending ───────────────────────────────────────────────────
  void validateApproval(CommitApproval approval) {
    if (approval.generation != _bindingGeneration || approval.binding != _copyKey ||
        approval.contents.entries.any((e) => !_dirty.contains(e.key) ||
            _commitContent(e.key) != e.value || _revisions[e.key] != approval._revisions[e.key] ||
            _stagedModes[e.key] != approval._stagedModes[e.key])) {
      throw const CommitFailure(CommitFailureKind.staleApproval,
          'Commit preview is stale; repository binding, selected bytes, operation or mode changed. Review again.');
    }
  }

  Future<CommitApproval> prepareCommit(String message, {
    Iterable<String>? paths, http.Client? client,
  }) async {
    final repo = repoFull, token = _token;
    final branch = defaultBranch ?? 'main';
    final generation = _bindingGeneration, binding = _copyKey;
    if (repo == null || token == null || token.isEmpty) throw StateError('repo not bound');
    if (message.trim().isEmpty) {
      throw const CommitFailure(CommitFailureKind.staleApproval, 'Commit message is empty');
    }
    final selected = (paths ?? pendingPaths).toSet().toList()..sort();
    if (selected.isEmpty || selected.any((p) => !_dirty.contains(p))) {
      throw const CommitFailure(CommitFailureKind.staleApproval, 'Select pending paths to review');
    }
    final contents = {for (final p in selected) p: _commitContent(p)};
    final stagedModes = {for (final p in selected) p: _stagedModes[p]};
    final revisions = {for (final p in selected) p: _revisions[p]};
    final c = client ?? http.Client();
    Future<Map<String, dynamic>> get(String path, {Map<String, String>? query}) async {
      final response = await _sendRetried(() {
        _ensureBinding(generation);
        return c.get(_apiUri(path, query: query), headers: {
          'Authorization': 'Bearer $token', 'Accept': 'application/vnd.github+json',
        });
      });
      _ensureBinding(generation);
      if (response.statusCode != 200) {
        throw Exception('commit preview fetch failed: ${response.statusCode} — no non-atomic fallback; per-file commits require explicit approval');
      }
      return jsonDecode(response.body) as Map<String, dynamic>;
    }
    try {
      final ref = await get('repos/$repo/git/ref/heads/$branch');
      final base = (ref['object'] as Map?)?['sha'] as String?;
      if (base == null || base.isEmpty) throw const FormatException('Missing base commit');
      final tree = await get('repos/$repo/git/trees/$base', query: {'recursive': '1'});
      if (tree['truncated'] == true || tree['tree'] is! List || tree['sha'] is! String) {
        throw const CommitFailure(CommitFailureKind.unsupported,
            'Cannot review incomplete tree or missing base tree revision');
      }
      final entries = {for (final e in tree['tree'] as List) (e as Map)['path'] as String: e};
      final originals = <String, String?>{};
      final modes = <String, String>{};
      final originalModes = <String, String?>{};
      for (final p in selected) {
        final entry = entries[p];
        if (entry == null) {
          if (contents[p] == null) throw CommitFailure(CommitFailureKind.staleApproval, 'Deletion target is absent upstream: $p');
          originals[p] = null;
          originalModes[p] = null;
          modes[p] = stagedModes[p] ?? '100644';
          continue;
        }
        if (entry['type'] != 'blob' || !['100644', '100755'].contains(entry['mode']) || entry['sha'] is! String) {
          throw CommitFailure(CommitFailureKind.unsupported, 'Cannot safely review non-regular file or unknown mode: $p');
        }
        originalModes[p] = entry['mode'] as String;
        modes[p] = contents[p] == null ? entry['mode'] as String : stagedModes[p] ?? entry['mode'] as String;
        final blob = await get('repos/$repo/git/blobs/${entry['sha']}');
        if (blob['encoding'] != 'base64' || blob['content'] is! String) {
          throw CommitFailure(CommitFailureKind.unsupported, 'Cannot decode original bytes: $p');
        }
        originals[p] = _decodeFileBytes(base64Decode((blob['content'] as String).replaceAll(RegExp(r'\s'), '')));
      }
      final approval = CommitApproval._(repo: repo, branch: branch, baseCommit: base,
          baseTree: tree['sha'] as String, message: message, binding: binding,
          generation: generation, contents: contents, originals: originals, modes: modes,
          originalModes: originalModes, stagedModes: stagedModes, revisions: revisions);
      validateApproval(approval);
      return approval;
    } finally {
      if (client == null) c.close();
    }
  }

  /// Existing admitted automated callers get the same snapshot/validation
  /// contract. Interactive callers must prepare BEFORE asking for approval.
  Future<int> commitAll(String message, {http.Client? client}) =>
      _commit(message: message, client: client);

  Future<int> commitApproved(CommitApproval approval, {http.Client? client}) =>
      _commit(approval: approval, client: client);

  /// Read-only even when there is no intent. Available without local drafts so
  /// a restarted application can recover a prior publication.
  Future<int?> reconcilePending({http.Client? client}) async {
    final repo = repoFull, token = _token;
    final branch = defaultBranch ?? 'main', generation = _bindingGeneration;
    if (repo == null || token == null || token.isEmpty) throw StateError('repo not bound');
    final key = _intentKey(repo, branch);
    if (!_commitAdmissions.add(key)) {
      throw const CommitFailure(CommitFailureKind.busy, 'Commit already in progress for this repository branch');
    }
    final c = client ?? http.Client();
    try {
      return await _recoverIntent(repo, branch, token, c, generation);
    } finally {
      _commitAdmissions.remove(key);
      if (client == null) c.close();
    }
  }

  /// Pushes every dirty file as ONE atomic commit via the Git Data API
  /// (create blobs → create tree on the branch tip → create commit → update
  /// ref). Objects created before the ref update are not published on the
  /// branch. Mutation requests are never automatically replayed.
  ///
  /// A lost ref-update response is reconciled against the intended commit SHA.
  /// If publication cannot be confirmed, throws an actionable unknown outcome
  /// and keeps pending edits. There is no non-atomic approval contract, so even
  /// an unsupported atomic API must fail rather than fall back to contents PUTs.
  /// Returns the number of committed files; [lastCommit] describes success only.
  Future<int> _commit({String? message, CommitApproval? approval, http.Client? client}) async {
    final repo = repoFull;
    final token = _token;
    final branch = defaultBranch ?? 'main';
    final generation = _bindingGeneration;
    if (repo == null || token == null || token.isEmpty) {
      throw StateError('repo not bound');
    }
    final key = _intentKey(repo, branch);
    if (!_commitAdmissions.add(key)) {
      throw const CommitFailure(CommitFailureKind.busy, 'Commit already in progress for this repository branch');
    }
    final c = client ?? http.Client();
    try {
      if (approval != null) validateApproval(approval);
      final recovered = await _recoverIntent(repo, branch, token, c, generation);
      if (recovered != null) return recovered;
      if (approval == null && _dirty.isEmpty) return 0;
      final snapshot = approval ?? await prepareCommit(message!, client: c);
      validateApproval(snapshot);
      final pending = snapshot.contents;
      final commitSha = await _commitAtomic(
        repo,
        token,
        branch,
        snapshot.message,
        pending,
        c,
        generation,
        snapshot,
      );
      _ensureBinding(generation);
      _dropPushed(pending, modes: snapshot.modes, revisions: snapshot._revisions);
      _lastCommit = CommitInfo(
        mode: CommitMode.atomic,
        commitSha: commitSha,
        files: pending.length,
        branch: branch,
      );
      notifyListeners();
      return pending.length;
    } finally {
      _commitAdmissions.remove(key);
      if (client == null) c.close();
    }
  }

  void _dropPushed(Map<String, String?> pending, {Map<String, String>? modes,
      Map<String, String?>? revisions}) {
    _accountPushed(pending, modes: modes, revisions: revisions, workspace: workspaceFolder,
        contents: files, dirty: _dirty, unsaved: _unsaved, deletions: _deletions,
        stagedModes: _stagedModes, edits: _revisions);
  }

  void _accountPushed(Map<String, String?> pending, {required Map<String, String>? modes,
      required Map<String, String?>? revisions, required String? workspace,
      required Map<String, String> contents, required Set<String> dirty,
      required Set<String> unsaved, required Set<String> deletions,
      required Map<String, String> stagedModes, required Map<String, String> edits}) {
    for (final entry in pending.entries) {
      final path = entry.key;
      if (revisions != null && edits[path] != revisions[path]) continue;
      if (stagedModes.containsKey(path) && stagedModes[path] != modes?[path]) continue;
      if ((entry.value == null) != deletions.contains(path)) continue;
      String? current = deletions.contains(path) ? null : contents[path];
      if (workspace != null) {
        try {
          final safe = workspaceFilePath(Directory(workspace), path);
          if (safe == null) continue;
          final type = _checkedType(safe);
          if (entry.value == null) {
            if (type != FileSystemEntityType.notFound) continue;
          } else {
            if (type != FileSystemEntityType.file && type != FileSystemEntityType.notFound) continue;
            if (!unsaved.contains(path)) current = _decodeFileBytes(File(safe).readAsBytesSync());
          }
        } catch (_) {
          continue; // Missing/unreadable bytes never prove an approved operation.
        }
      }
      if (current == entry.value) {
        dirty.remove(path);
        deletions.remove(path);
        stagedModes.remove(path);
        edits.remove(path);
      }
    }
  }

  /// The Git Data API dance. Every URL is per-segment encoded (audit §5);
  /// the branch ref path keeps its slashes (`heads/feature/x`) because git
  /// refs are hierarchical.
  Future<String> _commitAtomic(
    String repo,
    String token,
    String branch,
    String message,
    Map<String, String?> pending,
    http.Client c,
    int generation,
    CommitApproval approval,
  ) async {
    final headers = {
      'Authorization': 'Bearer $token',
      'Accept': 'application/vnd.github+json',
    };
    final jsonHeaders = {...headers, 'Content-Type': 'application/json'};

    // Fence every read attempt, including retries after a lost response.
    Future<http.Response> get(Uri uri) => _sendRetried(() {
      _ensureBinding(generation);
      return c.get(uri, headers: headers);
    });

    // POSTs may have been accepted even if their response was lost. Do not
    // create duplicate objects/commits by feeding writes through read retries.
    Future<http.Response> post(String path, String body) async {
      _ensureBinding(generation);
      try {
        return await c
            .post(_apiUri(path), headers: jsonHeaders, body: body)
            .timeout(requestTimeout);
      } finally {
        _ensureBinding(generation);
      }
    }

    Exception failed(String operation, int status) => Exception(
      '$operation failed: $status — '
      'no non-atomic fallback; per-file commits require explicit approval',
    );

    // 1. Branch tip.
    final refUri = _apiUri('repos/$repo/git/ref/heads/$branch');
    final refRes = await get(refUri);
    _ensureBinding(generation);
    if (refRes.statusCode != 200) {
      throw failed('ref fetch for branch "$branch"', refRes.statusCode);
    }
    final refObject =
        (jsonDecode(refRes.body) as Map<String, dynamic>)['object'];
    final baseCommit = refObject is Map ? refObject['sha'] as String? : null;
    if (baseCommit == null) {
      throw Exception('ref fetch for branch "$branch" returned no commit sha');
    }
    if (baseCommit != approval.baseCommit) {
      throw CommitFailure(CommitFailureKind.upstreamConflict,
          'Upstream conflict: approved base ${approval.baseCommit} changed to $baseCommit. Refresh and review again.');
    }
    validateApproval(approval);
    final modes = approval.modes;

    // 3. One blob per dirty file (bounded concurrency).
    final paths = pending.keys.toList()..sort();
    final blobShas = <String, String>{};
    await _forEachConcurrent(paths, _blobConcurrency, (p) async {
      _ensureBinding(generation);
      if (pending[p] == null) return;
      final body = jsonEncode({
        'content': base64Encode(utf8.encode(pending[p]!)),
        'encoding': 'base64',
      });
      final res = await post('repos/$repo/git/blobs', body);
      _ensureBinding(generation);
      if (res.statusCode != 201 && res.statusCode != 200) {
        throw failed('blob create for "$p"', res.statusCode);
      }
      final sha = (jsonDecode(res.body) as Map<String, dynamic>)['sha']
          as String?;
      if (sha == null) throw Exception('blob create for "$p" returned no sha');
      blobShas[p] = sha;
    });

    // 4. New tree on top of the branch tip.
    final treeBody = jsonEncode({
      'base_tree': approval.baseTree,
      'tree': [
        for (final p in paths)
          {
            'path': p,
            'mode': modes[p] ?? '100644',
            'type': 'blob',
            'sha': blobShas[p],
          },
      ],
    });
    final treeRes = await post('repos/$repo/git/trees', treeBody);
    _ensureBinding(generation);
    if (treeRes.statusCode != 201 && treeRes.statusCode != 200) {
      throw failed('tree create', treeRes.statusCode);
    }
    final treeSha = (jsonDecode(treeRes.body) as Map<String, dynamic>)['sha']
        as String?;
    if (treeSha == null) throw Exception('tree create returned no sha');

    // 5. The commit — exactly ONE for the whole pending set.
    final commitBody = jsonEncode({
      'message': message,
      'tree': treeSha,
      'parents': [baseCommit],
    });
    final commitRes = await post('repos/$repo/git/commits', commitBody);
    _ensureBinding(generation);
    if (commitRes.statusCode != 201 && commitRes.statusCode != 200) {
      throw failed('commit create', commitRes.statusCode);
    }
    final commitSha =
        (jsonDecode(commitRes.body) as Map<String, dynamic>)['sha'] as String?;
    if (commitSha == null) throw Exception('commit create returned no sha');

    // 6. Publish once, non-force. A transport/server failure does not tell us
    // whether GitHub accepted the update. Reconcile by reading, never by
    // retrying PATCH or switching to per-file writes.
    final patchBody = jsonEncode({'sha': commitSha, 'force': false});
    http.Response? patchRes;
    final intentKey = _intentKey(repo, branch);
    await _saveIntent(intentKey, {
      'sha': commitSha, 'repo': repo, 'branch': branch, 'base': baseCommit,
      'message': message, 'pending': pending, 'owner': _copyKey,
      'version': 2, 'modes': approval.modes, 'revisions': approval._revisions,
    });
    _ensureBinding(generation);
    try {
      patchRes = await c
          .patch(
            _apiUri('repos/$repo/git/refs/heads/$branch'),
            headers: jsonHeaders,
            body: patchBody,
          )
          .timeout(requestTimeout);
    } on StateError {
      rethrow;
    } catch (_) {
      // The request may have reached GitHub. Only an exact ref match below
      // can turn a lost response into a confirmed success.
    }
    _ensureBinding(generation);
    if (patchRes?.statusCode == 200) {
      _dropPushed(pending, modes: approval.modes, revisions: approval._revisions);
      await _clearIntent(intentKey);
      _ensureBinding(generation);
      return commitSha;
    }
    final status = patchRes?.statusCode;
    if (status == 409 || status == 422) {
      await _clearIntent(intentKey);
      _ensureBinding(generation);
      throw CommitFailure(CommitFailureKind.upstreamConflict,
        'ref update conflict/rejection ($status) for $repo "$branch" '
        'at intended commit $commitSha — refresh upstream and review pending '
        'edits before retrying',
      );
    }
    if (status != null && status >= 400 && status < 500 && status != 408) {
      await _clearIntent(intentKey);
      _ensureBinding(generation);
      throw failed('ref update for "$branch"', status);
    }

    String? observed;
    try {
      final res = await get(refUri);
      _ensureBinding(generation);
      if (res.statusCode == 200) {
        final object = (jsonDecode(res.body) as Map<String, dynamic>)['object'];
        if (object is Map) observed = object['sha'] as String?;
      }
    } on StateError {
      rethrow;
    } catch (_) {
      // An unreadable ref leaves publication unknown, not failed or successful.
    }
    _ensureBinding(generation);
    if (observed == commitSha) {
      _dropPushed(pending, modes: approval.modes, revisions: approval._revisions);
      await _clearIntent(intentKey);
      _ensureBinding(generation);
      return commitSha;
    }
    throw CommitFailure(CommitFailureKind.unknown,
      'commit outcome unknown for $repo "$branch": intended commit $commitSha; '
      'observed ref ${observed ?? 'unavailable'}'
      '${status == null ? '' : '; ref update HTTP $status'} — '
      'pending edits retained. Inspect the upstream ref and intended commit '
      'before retrying; no mutation was retried or sent via per-file fallback',
      intendedSha: commitSha,
    );
  }

  // ── live preview (vibe-coding) ───────────────────────────────────────
  /// Copies an index.html-based project to a preview dir for WebView.
  /// Rewrites relative refs (./style.css → style.css) so the preview works.
  Future<String?> exportPreview(String projectDir) async {
    final base = await getApplicationDocumentsDirectory();
    final prevDir = Directory('${base.path}/ovid/preview');
    if (prevDir.existsSync()) prevDir.deleteSync(recursive: true);
    prevDir.createSync(recursive: true);

    final idx = files['$projectDir/index.html'] ?? files['index.html'];
    if (idx == null) return null;

    for (final e in files.entries) {
      final name = e.key.split('/').last;
      final ext = name.contains('.') ? name.split('.').last : '';
      if (['html', 'css', 'js', 'svg', 'json'].contains(ext)) {
        File('${prevDir.path}/$name').writeAsStringSync(e.value);
      }
    }
    return '${prevDir.path}/index.html';
  }
}

/// A transient HTTP status whose retry budget was exhausted (audit
/// 2026-09-25 §8) — carries the status so callers can classify it.
class _TransientExhausted implements Exception {
  _TransientExhausted(this.status, this.attempts, {this.retryAfter});
  final int status;
  final int attempts;
  final Duration? retryAfter;
  @override
  String toString() => 'HTTP $status after $attempts attempts';
}
