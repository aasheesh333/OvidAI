import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'diag.dart';

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

  bool get deadlineExceeded => unattemptedPaths.isNotEmpty;

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
      out.add('GitHub TRUNCATED the repo tree — some files were never listed');
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
      out.add(
        'deadline exceeded — ${unattemptedPaths.length} files not attempted',
      );
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

  /// The contents-API fallback: N files = N separate GitHub commits.
  perFile,
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

  /// What the most recent successful [commitAll] did (audit 2026-09-25 §4):
  /// `CommitMode.atomic` (one commit) or the per-file contents-API fallback.
  CommitInfo? get lastCommit => _lastCommit;

  bool get isReady => repoFull != null && files.isNotEmpty;
  bool get hasPending => _dirty.isNotEmpty;
  int get dirtyCount => _dirty.length;

  @override
  void notifyListeners() => super.notifyListeners();

  // ── init ─────────────────────────────────────────────────────────────
  void bind(
    String full,
    String token, {
    String branch = 'main',
    String? sessionId,
  }) {
    _bindingGeneration++;
    repoFull = full;
    _token = token;
    defaultBranch = branch;
    _boundSessionId = sessionId;
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
    int maxFiles = 400,
    void Function(String line)? onLine,
    http.Client? client,
    Duration deadline = defaultSyncDeadline,
    int concurrency = defaultSyncConcurrency,
  }) async {
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
        if (local == null) continue;
        if (syncedFiles[p] == local) continue;
        files[p] = local;
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
    files.clear();
    treePaths.clear();
    _dirty.clear();
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
        content: utf8.decode(res.bodyBytes, allowMalformed: true),
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
    files[path] = content;
    _dirty.add(path);
    notifyListeners();
  }

  String? read(String path) => files[path];

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
    final c = client ?? http.Client();
    try {
      final r = await _fetchRaw(repo, token, path, branch, c);
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
    files[path] = content;
    _dirty.add(path);
    if (!treePaths.contains(path)) treePaths.add(path);
  }

  void remove(String path) {
    files.remove(path);
    _dirty.remove(path);
    treePaths.remove(path);
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
  /// Pushes every dirty file as ONE atomic commit via the Git Data API
  /// (create blobs → create tree on the branch tip → create commit → update
  /// ref) — audit 2026-09-25 §4. The old per-file contents PUT made N files
  /// = N GitHub commits: non-atomic, and a mid-loop failure left a partial
  /// push. Here nothing is visible upstream until the final ref update
  /// succeeds, so a failure before it changes NOTHING.
  ///
  /// If the atomic path is unavailable (e.g. the token lacks Git Data
  /// access), it falls back to per-file commits; a failure THERE throws an
  /// exception naming exactly how many files already landed — success is
  /// never reported for a partial write. [lastCommit] tells callers which
  /// mode ran. Returns the number of committed files.
  Future<int> commitAll(String message, {http.Client? client}) async {
    final repo = repoFull;
    final token = _token;
    final branch = defaultBranch ?? 'main';
    final generation = _bindingGeneration;
    if (repo == null || token == null || token.isEmpty) {
      throw StateError('repo not bound');
    }
    final pending = {
      for (final path in _dirty)
        if (files[path] case final String content) path: content,
    };
    if (pending.isEmpty) return 0;
    final c = client ?? http.Client();
    try {
      try {
        final commitSha = await _commitAtomic(
          repo,
          token,
          branch,
          message,
          pending,
          c,
          generation,
        );
        _dropPushed(pending);
        _lastCommit = CommitInfo(
          mode: CommitMode.atomic,
          commitSha: commitSha,
          files: pending.length,
          branch: branch,
        );
        notifyListeners();
        return pending.length;
      } on StateError {
        rethrow; // a rebind mid-commit must surface, not fall back
      } catch (atomicError, stack) {
        Diag.swallow('repo_cache.commitAtomic', atomicError, stack);
        final pushed = await _commitPerFile(
          repo,
          token,
          branch,
          message,
          pending,
          c,
          generation,
          atomicError,
        );
        _lastCommit = CommitInfo(
          mode: CommitMode.perFile,
          files: pushed,
          branch: branch,
        );
        notifyListeners();
        return pushed;
      }
    } finally {
      if (client == null) c.close();
    }
  }

  void _dropPushed(Map<String, String> pending) {
    for (final entry in pending.entries) {
      if (files[entry.key] == entry.value) _dirty.remove(entry.key);
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
    Map<String, String> pending,
    http.Client c,
    int generation,
  ) async {
    final headers = {
      'Authorization': 'Bearer $token',
      'Accept': 'application/vnd.github+json',
    };
    final jsonHeaders = {...headers, 'Content-Type': 'application/json'};

    // 1. Branch tip.
    final refRes = await _sendRetried(
      () => c.get(_apiUri('repos/$repo/git/ref/heads/$branch'), headers: headers),
    );
    _ensureBinding(generation);
    if (refRes.statusCode != 200) {
      throw Exception(
        'ref fetch for branch "$branch" failed: ${refRes.statusCode}',
      );
    }
    final refObject =
        (jsonDecode(refRes.body) as Map<String, dynamic>)['object'];
    final baseCommit = refObject is Map ? refObject['sha'] as String? : null;
    if (baseCommit == null) {
      throw Exception('ref fetch for branch "$branch" returned no commit sha');
    }

    // 2. Best-effort mode lookup so an existing 100755 (executable) or
    //    120000 (symlink) blob keeps its mode; new/unknown paths default to
    //    a regular 100644 blob.
    final modes = <String, String>{};
    try {
      final modeRes = await _sendRetried(
        () => c.get(
          _apiUri('repos/$repo/git/trees/$baseCommit', query: {'recursive': '1'}),
          headers: headers,
        ),
      );
      _ensureBinding(generation);
      if (modeRes.statusCode == 200) {
        final tj = jsonDecode(modeRes.body) as Map<String, dynamic>;
        for (final e in (tj['tree'] as List? ?? const []).cast<Map<String, dynamic>>()) {
          if (e['path'] case final String p when e['mode'] is String) {
            modes[p] = e['mode'] as String;
          }
        }
      }
    } on StateError {
      rethrow;
    } catch (e) {
      Diag.swallow('repo_cache.commitModeLookup', e);
    }

    // 3. One blob per dirty file (bounded concurrency).
    final paths = pending.keys.toList()..sort();
    final blobShas = <String, String>{};
    await _forEachConcurrent(paths, _blobConcurrency, (p) async {
      _ensureBinding(generation);
      final body = jsonEncode({
        'content': base64Encode(utf8.encode(pending[p]!)),
        'encoding': 'base64',
      });
      final res = await _sendRetried(
        () => c.post(
          _apiUri('repos/$repo/git/blobs'),
          headers: jsonHeaders,
          body: body,
        ),
      );
      _ensureBinding(generation);
      if (res.statusCode != 201 && res.statusCode != 200) {
        throw Exception('blob create for "$p" failed: ${res.statusCode}');
      }
      final sha = (jsonDecode(res.body) as Map<String, dynamic>)['sha']
          as String?;
      if (sha == null) throw Exception('blob create for "$p" returned no sha');
      blobShas[p] = sha;
    });

    // 4. New tree on top of the branch tip.
    final treeBody = jsonEncode({
      'base_tree': baseCommit,
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
    final treeRes = await _sendRetried(
      () => c.post(
        _apiUri('repos/$repo/git/trees'),
        headers: jsonHeaders,
        body: treeBody,
      ),
    );
    _ensureBinding(generation);
    if (treeRes.statusCode != 201 && treeRes.statusCode != 200) {
      throw Exception('tree create failed: ${treeRes.statusCode}');
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
    final commitRes = await _sendRetried(
      () => c.post(
        _apiUri('repos/$repo/git/commits'),
        headers: jsonHeaders,
        body: commitBody,
      ),
    );
    _ensureBinding(generation);
    if (commitRes.statusCode != 201 && commitRes.statusCode != 200) {
      throw Exception('commit create failed: ${commitRes.statusCode}');
    }
    final commitSha =
        (jsonDecode(commitRes.body) as Map<String, dynamic>)['sha'] as String?;
    if (commitSha == null) throw Exception('commit create returned no sha');

    // 6. Move the branch. Until this succeeds, upstream is untouched — a
    //    failure anywhere above changes NOTHING. Retrying the PATCH is safe:
    //    re-sending the same sha is a no-op on GitHub's side.
    final patchBody = jsonEncode({'sha': commitSha, 'force': false});
    final patchRes = await _sendRetried(
      () => c.patch(
        _apiUri('repos/$repo/git/refs/heads/$branch'),
        headers: jsonHeaders,
        body: patchBody,
      ),
    );
    _ensureBinding(generation);
    if (patchRes.statusCode != 200) {
      throw Exception(
        'ref update for "$branch" failed: ${patchRes.statusCode} — nothing was pushed',
      );
    }
    return commitSha;
  }

  /// The pre-audit contents-API path, kept ONLY as a fallback when the Git
  /// Data API is unavailable. Non-atomic by nature: a mid-loop failure throws
  /// an exception naming the partial count (audit 2026-09-25 §4 — the raw
  /// error used to imply nothing landed when some files already had).
  Future<int> _commitPerFile(
    String repo,
    String token,
    String branch,
    String message,
    Map<String, String> pending,
    http.Client c,
    int generation,
    Object atomicError,
  ) async {
    var pushed = 0;
    for (final entry in pending.entries) {
      _ensureBinding(generation);
      final sha = await _shaOf(repo, token, entry.key, branch, c);
      _ensureBinding(generation);
      try {
        await _putFile(
          repo,
          token,
          entry.key,
          entry.value,
          message,
          sha,
          branch,
          c,
        );
      } catch (e) {
        throw Exception(
          'partial push: $pushed/${pending.length} files committed before '
          '"${entry.key}" failed: $e (atomic commit also failed: $atomicError)',
        );
      }
      _ensureBinding(generation);
      if (files[entry.key] == entry.value) _dirty.remove(entry.key);
      pushed++;
    }
    return pushed;
  }

  Future<String?> _shaOf(
    String repo,
    String token,
    String path,
    String branch,
    http.Client client,
  ) async {
    try {
      final res = await _sendRetried(
        () => client.get(
          _apiUri('repos/$repo/contents/$path', query: {'ref': branch}),
          headers: {
            'Authorization': 'Bearer $token',
            'Accept': 'application/vnd.github+json',
          },
        ),
      );
      if (res.statusCode == 200) {
        return (jsonDecode(res.body))['sha'] as String?;
      }
    } catch (e) {
      Diag.swallow('repo_cache.shaOf', e);
    }
    return null;
  }

  Future<void> _putFile(
    String repo,
    String token,
    String path,
    String content,
    String message,
    String? sha,
    String branch,
    http.Client client,
  ) async {
    // GitHub's contents API commits to `branch` via the body; `?ref=` is not
    // accepted for PUT (the SHA read above carries `?ref=` instead).
    // Deliberately NOT retried: a PUT that timed out may still have
    // committed, and a blind retry with the now-stale `sha` would 409.
    final res = await client
        .put(
          _apiUri('repos/$repo/contents/$path'),
          headers: {
            'Authorization': 'Bearer $token',
            'Accept': 'application/vnd.github+json',
            'Content-Type': 'application/json',
          },
          body: jsonEncode({
            'message': message,
            'content': base64Encode(utf8.encode(content)),
            'branch': branch,
            'sha': ?sha,
          }),
        )
        .timeout(requestTimeout);
    // A vanished branch/ref must surface as a failure, never a silent no-op.
    if (res.statusCode != 200 && res.statusCode != 201) {
      throw Exception('contents PUT $path failed: ${res.statusCode}');
    }
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
