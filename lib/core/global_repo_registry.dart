import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// Runs `git clone -b BRANCH https://github.com/OWNER/REPO.git DEST`.
/// Injectable so tests can simulate a clone without network/git.
typedef GitCloneRunner =
    Future<void> Function(String repoFull, String branch, String dest);

/// GlobalRepoRegistry — clone-once registry for Studio repos.
///
/// Layout under `<appSupport>/global/`:
///   `repos/<owner>__<repo>__<branch>/` — one real `git clone` per
///                                         (repo, branch), shared by sessions
///   repo_index.json                    — persistent index:
///       (repoFull, branch) → local path, plus sessionId → binding
///
/// Sessions bind to a registry folder via [bindSession]; the workspace read
/// path ([SandboxService.workDirFor]/[workDirForSync]) consults
/// [boundWorkspaceFor] first and falls back to the per-session `ws_<id>`
/// folder when there is no binding, so general mode keeps its isolation.
///
/// The git runner is injectable (constructor [GitCloneRunner]); the default
/// runs a real `git clone -b BRANCH` through [Process.run] and never
/// touches [AgentService].
class GlobalRepoRegistry {
  GlobalRepoRegistry._(this._globalDir, {this._gitRunner});

  final Directory _globalDir;
  final GitCloneRunner? _gitRunner;

  /// Supplies the GitHub OAuth token used for private-repo clones. Wired by
  /// the UI layer (which owns the GitHub sign-in) — e.g.
  /// `GlobalRepoRegistry.gitTokenProvider = () => GitHubService.I.token;`
  /// Kept static so the default git runner stays dependency-free (no import
  /// cycle with the GitHub/sandbox services). Null → anonymous clone.
  static String? Function()? gitTokenProvider;

  /// Supplies the git auth **env** for a clone, wired by the sandbox layer:
  /// `GlobalRepoRegistry.gitCredentialEnvProvider = SandboxService.I.gitCredentialEnv;`
  /// SECURITY (2026-09-24): clones must not interpolate the token into an env
  /// value — the provider returns a host-scoped `store` helper that names a
  /// 0600 credential file instead. Null → anonymous clone (tests, host git).
  static Map<String, String> Function()? gitCredentialEnvProvider;

  /// Production override for the git runner, wired once by the app layer
  /// (which owns the Linux sandbox) — e.g. in Studio setup:
  /// `GlobalRepoRegistry.cloneRunnerOverride ??= _sandboxGitClone;`
  /// Precedence: injected [_gitRunner] (tests) first, then this override,
  /// then the host-`git` [_defaultGitClone] fallback. Null → host `git`
  /// (desktop/CLI use).
  ///
  /// This exists because Android ships no usable system `git`: spawning a
  /// host `git clone` fails with `ProcessException: Permission denied`.
  /// Every working git in Ovid (the agent's git_clone, the Health probes)
  /// goes through the sandbox's `<prefix>/bin/git` with the sandbox env
  /// (PATH, GIT_EXEC_PATH, GIT_SSL_CAINFO, HOME) — Studio clones must too.
  static GitCloneRunner? cloneRunnerOverride;

  // ── singleton (production) ─────────────────────────────────────────
  static GlobalRepoRegistry? _instance;

  /// Production instance rooted at `<appSupport>/global/` (or a
  /// system-temp fallback when app-support is unavailable — see
  /// [_create]). The result is cached once it completes.
  ///
  /// The in-flight future is deliberately NOT cached. Caching it poisoned
  /// every later caller when a creation stranded mid-flight: a
  /// path_provider method-channel call issued inside a widget test's
  /// fake-async zone never completes, so the cached future was a zombie
  /// that wedged all subsequent `instance()` awaits forever. `_create()`
  /// never throws, so concurrent creations are harmless — the first to
  /// finish wins via `??=`.
  static Future<GlobalRepoRegistry> instance() async {
    final ready = _instance;
    if (ready != null) return ready;
    final created = await _create();
    _instance ??= created;
    return _instance!;
  }

  /// The already-initialized instance, or null when [instance] was never
  /// (successfully) awaited. Used by sync read paths that must not block.
  static GlobalRepoRegistry? get maybeInstance => _instance;

  /// Resolve the registry root and load the index. NEVER throws: when
  /// the app-support directory is unavailable (unit tests have no
  /// path_provider; the platform may also stall), fall back to a
  /// subdirectory of [Directory.systemTemp] so callers always get a
  /// usable registry instead of a [MissingPluginException].
  static Future<GlobalRepoRegistry> _create() async {
    Directory support;
    try {
      support = await getApplicationSupportDirectory();
    } catch (_) {
      support = Directory('${Directory.systemTemp.path}/ovid-global');
    }
    final reg = GlobalRepoRegistry._(Directory('${support.path}/global'));
    await reg.reload();
    return reg;
  }

  /// Test/CLI seam: build a registry rooted at [baseDir] with an optional
  /// fake git runner. Does NOT touch the production singleton. Call
  /// [reload] to load a previously saved index.
  @visibleForTesting
  static GlobalRepoRegistry createForTest({
    required Directory baseDir,
    GitCloneRunner? gitRunner,
  }) => GlobalRepoRegistry._(baseDir, gitRunner: gitRunner);

  // ── index state ────────────────────────────────────────────────────
  /// "$repoFull@$branch" → absolute local path of the shared clone.
  final Map<String, String> _repoPaths = {};

  /// sessionId → binding.
  final Map<String, _SessionBinding> _sessions = {};

  static String _repoKey(String repoFull, String branch) => '$repoFull@$branch';

  File get _indexFile => File('${_globalDir.path}/repo_index.json');
  Directory get _reposDir => Directory('${_globalDir.path}/repos');

  /// (Re)load the index from disk. Missing or corrupt file → start empty.
  Future<void> reload() async {
    _repoPaths.clear();
    _sessions.clear();
    final f = _indexFile;
    if (!f.existsSync()) return;
    try {
      final j = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
      final repos = j['repos'];
      if (repos is Map) {
        for (final e in repos.entries) {
          if (e.key is String && e.value is String) {
            _repoPaths[e.key as String] = e.value as String;
          }
        }
      }
      final sessions = j['sessions'];
      if (sessions is Map) {
        for (final e in sessions.entries) {
          if (e.key is String && e.value is Map) {
            final b = _SessionBinding.fromJson(
              (e.value as Map).cast<String, dynamic>(),
            );
            if (b != null) _sessions[e.key as String] = b;
          }
        }
      }
    } catch (_) {
      _repoPaths.clear();
      _sessions.clear();
    }
  }

  Future<void> _save() async {
    final f = _indexFile;
    await f.parent.create(recursive: true);
    final payload = jsonEncode({
      'version': 1,
      'repos': _repoPaths,
      'sessions': {
        for (final e in _sessions.entries) e.key: e.value.toJson(),
      },
    });
    // Atomic write: a crash mid-save never leaves a half-written index.
    final tmp = File('${f.path}.tmp');
    await tmp.writeAsString(payload);
    await tmp.rename(f.path);
  }

  // ── folder naming ──────────────────────────────────────────────────
  /// Filesystem-safe folder name `<owner>__<repo>__<branch>`. Unsafe chars
  /// (e.g. `/` in `feature/foo`) become `_`; segments are length-capped so
  /// paths stay sane.
  static String folderNameFor(String repoFull, String branch) {
    String safe(String s) => s.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    String cap(String s, int n) => s.length <= n ? s : s.substring(0, n);
    final parts = repoFull.split('/');
    final owner = parts.isNotEmpty ? safe(parts[0]) : 'repo';
    final repo = parts.length > 1 ? safe(parts.sublist(1).join('_')) : 'repo';
    var b = safe(branch);
    if (b.isEmpty) b = 'branch';
    return '${cap(owner, 60)}__${cap(repo, 60)}__${cap(b, 60)}';
  }

  static String _shortHash(String s) {
    var h = 0x811c9dc5;
    for (final c in s.codeUnits) {
      h ^= c;
      h = (h * 0x01000193) & 0xffffffff;
    }
    return h.toRadixString(16).padLeft(8, '0');
  }

  // ── clone ──────────────────────────────────────────────────────────
  static void _validate(String repoFull, String branch) {
    final parts = repoFull.split('/');
    if (parts.length != 2 || parts.any((p) => p.trim().isEmpty)) {
      throw ArgumentError('repoFull must be "owner/repo", got "$repoFull"');
    }
    if (branch.trim().isEmpty) {
      throw ArgumentError('branch must not be empty');
    }
  }

  /// The effective git runner: the injected fake in tests, else the
  /// app-wired sandbox runner ([cloneRunnerOverride]), else the real
  /// host `git clone -b BRANCH` below.
  GitCloneRunner get _effectiveRunner =>
      _gitRunner ?? cloneRunnerOverride ?? _defaultGitClone;

  /// Real clone used in production. Never prompts (a hung credential
  /// prompt is worse than a clean failure); when the app wired
  /// [gitCredentialEnvProvider], private repos clone through a host-scoped
  /// credential store file. The token is never interpolated into an env
  /// value here — see that field's SECURITY note.
  Future<void> _defaultGitClone(
    String repoFull,
    String branch,
    String dest,
  ) async {
    _validate(repoFull, branch);
    final env = <String, String>{
      'GIT_TERMINAL_PROMPT': '0',
      ...?gitCredentialEnvProvider?.call(),
    };
    final res = await Process.run('git', [
      'clone',
      '-b',
      branch,
      'https://github.com/$repoFull.git',
      dest,
    ], environment: env);
    if (res.exitCode != 0) {
      throw Exception(
        'git clone $repoFull@$branch failed '
        '(exit ${res.exitCode}): ${res.stderr}'.trim(),
      );
    }
  }

  /// Run the effective git runner for an explicit destination. Used by the
  /// "local folder clone" flow, which clones outside the global area.
  Future<void> cloneRepo(String repoFull, String branch, String dest) =>
      _effectiveRunner(repoFull, branch, dest);

  /// Return the shared working copy for (repoFull, branch), cloning once
  /// into `<appSupport>/global/repos/` on a miss. A registry hit whose
  /// folder vanished from disk re-clones instead of returning a dead path.
  /// The same folder is returned for every session → no re-clone.
  Future<String> ensureCloned(String repoFull, String branch) async {
    _validate(repoFull, branch);
    final key = _repoKey(repoFull, branch);
    final hit = _repoPaths[key];
    if (hit != null) {
      if (Directory(hit).existsSync()) return hit;
      // Indexed folder is gone (user deleted it, storage cleared) —
      // fall through and re-clone into the same deterministic path.
      _repoPaths.remove(key);
    }
    final dest = _destFor(key, repoFull, branch);
    final destDir = Directory(dest);
    if (destDir.existsSync()) {
      // Stale/partial dir at our path (never a live hit — those return
      // above): clear it so the clone starts clean.
      await destDir.delete(recursive: true);
    }
    await destDir.parent.create(recursive: true);
    try {
      await _effectiveRunner(repoFull, branch, dest);
    } catch (_) {
      // Never leave a broken half-clone behind, and never index it.
      try {
        if (destDir.existsSync()) await destDir.delete(recursive: true);
      } catch (_) {}
      rethrow;
    }
    _repoPaths[key] = dest;
    await _save();
    return dest;
  }

  /// Deterministic destination for [key]; on a name collision with an
  /// unrelated existing dir (two keys sanitizing to the same folder),
  /// disambiguate with a short hash of the key.
  String _destFor(String key, String repoFull, String branch) {
    final base = '${_reposDir.path}/${folderNameFor(repoFull, branch)}';
    if (Directory(base).existsSync() && !_repoPaths.values.contains(base)) {
      return '${base}__${_shortHash(key)}';
    }
    return base;
  }

  // ── session bindings ───────────────────────────────────────────────
  /// Bind [sessionId] to the working copy at [path] for (repoFull, branch).
  Future<void> bindSession(
    String sessionId,
    String repoFull,
    String branch,
    String path,
  ) async {
    _sessions[sessionId] = _SessionBinding(
      repoFull: repoFull,
      branch: branch,
      path: path,
    );
    await _save();
  }

  /// The session's bound workspace folder, or null when unbound / the
  /// folder vanished (callers then fall back to the default workspace).
  String? boundWorkspaceFor(String sessionId) {
    final b = _sessions[sessionId];
    if (b == null) return null;
    if (!Directory(b.path).existsSync()) return null;
    return b.path;
  }

  /// Drop the session's binding (the shared clone itself is kept — other
  /// sessions may still use it).
  Future<void> unbindSession(String sessionId) async {
    if (_sessions.remove(sessionId) != null) await _save();
  }

  /// Number of indexed (repo, branch) clones — handy for diagnostics.
  int get cloneCount => _repoPaths.length;
}

class _SessionBinding {
  _SessionBinding({
    required this.repoFull,
    required this.branch,
    required this.path,
  });

  final String repoFull;
  final String branch;
  final String path;

  Map<String, String> toJson() => {
    'repoFull': repoFull,
    'branch': branch,
    'path': path,
  };

  static _SessionBinding? fromJson(Map<String, dynamic> j) {
    final repoFull = j['repoFull'];
    final branch = j['branch'];
    final path = j['path'];
    if (repoFull is! String || branch is! String || path is! String) {
      return null;
    }
    return _SessionBinding(repoFull: repoFull, branch: branch, path: path);
  }
}
