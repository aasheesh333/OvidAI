import 'dart:convert';

import '../cloud/cloud_rest.dart';
import 'cloud_session_store.dart';

/// Studio's GitHub + git surface, reconciled against the BUILT gateway routes
/// (`cloud/apps/gateway/src/routes/studio.ts`, `studioGithub.ts`,
/// `studioGit.ts`) rather than the plan prose.
///
/// Endpoints (all under the [CloudRestClient] base, `/cloud/v1`):
///
///  - `GET  /studio/github` → `{connected, login, source}`
///  - `GET  /studio/repos?page&perPage`
///    → `{items:[GithubRepo], page, perPage, hasMore}`
///  - `GET  /studio/repos/:owner/:repo/branches?page&perPage`
///    → `{items:[GithubBranch], page, perPage, hasMore}`
///  - `GET  /studio/sessions/:id/git`
///    → `{sessionId, repo:{repo,repoDir,branch,updatedAt}|null,
///        git:{available, reason}}`
///  - `POST /studio/sessions/:id/git/clone {repo, branch?, dest?}`
///    → 201 `{sessionId, repo, repoDir, branch, bindingStored}`
///  - `POST /studio/sessions/:id/git/branch {branch}`
///    → `{status, branch, stashed, stashRef?, stashNote?, message}`
///  - `POST /studio/sessions/:id/git/sync`
///    → `{status, dirty, behind, ahead, branch, message, reason?}`
///
/// Two rules are load-bearing:
///
///  1. **The token never reaches this client.** The gateway reads the user's
///     curated `github` MCP row and the worker passes the token to git through
///     an ephemeral askpass helper. No request here carries a GitHub token.
///  2. **An unavailable operation is refused, never faked.** Until the worker
///     transport is wired the three git mutations answer
///     `503 studio_git_unavailable`; that becomes
///     [StudioGitUnavailableException] so no caller can mistake a refusal for
///     a completed clone, switch or sync.
///
/// Session ids: the app keys chats by a LOCAL id; the gateway requires the
/// server UUID. Every session-scoped call resolves it through
/// [CloudSessionStore] and never sends an unmapped id (the gateway would 404 a
/// non-UUID path).

/// The account the gateway's curated `github` integration resolves to.
class StudioGithubConnection {
  const StudioGithubConnection({
    required this.connected,
    this.login,
    this.source = 'mcp',
  });

  final bool connected;

  /// The GitHub login the saved token belongs to, when connected.
  final String? login;

  /// Where the gateway got the token. The built route answers `mcp`.
  final String source;

  static StudioGithubConnection fromJson(Map<String, dynamic> json) {
    final login = json['login'];
    final source = json['source'];
    return StudioGithubConnection(
      connected: json['connected'] == true,
      login: login is String && login.isNotEmpty ? login : null,
      source: source is String && source.isNotEmpty ? source : 'mcp',
    );
  }
}

/// One repository the token can see (`GithubRepo` on the gateway).
class StudioRepo {
  const StudioRepo({
    required this.id,
    required this.owner,
    required this.name,
    required this.fullName,
    this.isPrivate = false,
    this.defaultBranch = '',
    this.description,
    this.updatedAt,
    this.url = '',
  });

  final int id;
  final String owner;
  final String name;
  final String fullName;
  final bool isPrivate;
  final String defaultBranch;
  final String? description;
  final DateTime? updatedAt;
  final String url;

  static StudioRepo? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['id'];
    final owner = raw['owner'];
    final name = raw['name'];
    final fullName = raw['fullName'];
    if (id is! num || owner is! String || name is! String) return null;
    if (fullName is! String || fullName.isEmpty) return null;
    final description = raw['description'];
    final updatedAt = raw['updatedAt'];
    final url = raw['url'];
    final branch = raw['defaultBranch'];
    return StudioRepo(
      id: id.toInt(),
      owner: owner,
      name: name,
      fullName: fullName,
      isPrivate: raw['private'] == true,
      defaultBranch: branch is String ? branch : '',
      description: description is String ? description : null,
      updatedAt: updatedAt is String ? DateTime.tryParse(updatedAt) : null,
      url: url is String ? url : '',
    );
  }
}

/// One branch of a repository (`GithubBranch` on the gateway).
class StudioBranch {
  const StudioBranch({
    required this.name,
    this.isProtected = false,
    this.commitSha = '',
  });

  final String name;
  final bool isProtected;
  final String commitSha;

  static StudioBranch? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final name = raw['name'];
    if (name is! String || name.isEmpty) return null;
    final sha = raw['commitSha'];
    return StudioBranch(
      name: name,
      isProtected: raw['protected'] == true,
      commitSha: sha is String ? sha : '',
    );
  }
}

/// One gateway page. `hasMore` is the server's own answer (a full page), not
/// a guess from the client.
class StudioPage<T> {
  const StudioPage({
    required this.items,
    required this.page,
    required this.perPage,
    required this.hasMore,
  });

  final List<T> items;
  final int page;
  final int perPage;
  final bool hasMore;

  static StudioPage<T> parse<T>(
    Map<String, dynamic> json,
    T? Function(Object?) parseItem,
  ) {
    final rawItems = json['items'];
    final page = json['page'];
    final perPage = json['perPage'];
    return StudioPage<T>(
      items: <T>[
        for (final item in (rawItems is List ? rawItems : const []))
          ?parseItem(item),
      ],
      page: page is num ? page.toInt() : 1,
      perPage: perPage is num ? perPage.toInt() : 30,
      hasMore: json['hasMore'] == true,
    );
  }
}

/// The repo folder a session cloned (`GET …/git`'s `repo` object).
class StudioRepoBinding {
  const StudioRepoBinding({
    required this.repo,
    required this.repoDir,
    required this.branch,
    this.updatedAt,
  });

  /// `owner/name`.
  final String repo;

  /// Workspace-relative folder the clone created.
  final String repoDir;
  final String branch;
  final DateTime? updatedAt;

  static StudioRepoBinding? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final repo = raw['repo'];
    final repoDir = raw['repoDir'];
    final branch = raw['branch'];
    if (repo is! String || repo.isEmpty) return null;
    if (repoDir is! String || repoDir.isEmpty) return null;
    if (branch is! String) return null;
    final updatedAt = raw['updatedAt'];
    return StudioRepoBinding(
      repo: repo,
      repoDir: repoDir,
      branch: branch,
      updatedAt: updatedAt is String ? DateTime.tryParse(updatedAt) : null,
    );
  }
}

/// A session's binding plus whether the deployment can run git at all.
class StudioSessionGit {
  const StudioSessionGit({
    required this.sessionId,
    required this.available,
    this.binding,
    this.reason,
  });

  final String sessionId;
  final StudioRepoBinding? binding;

  /// False means clone/switch/sync answer `503 studio_git_unavailable`.
  /// The screen renders no control that would claim otherwise.
  final bool available;

  /// The gateway's reason code when [available] is false.
  final String? reason;

  static StudioSessionGit? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final sessionId = raw['sessionId'];
    if (sessionId is! String || sessionId.isEmpty) return null;
    final git = raw['git'];
    final available = git is Map && git['available'] == true;
    final reason = git is Map && git['reason'] is String
        ? git['reason'] as String
        : null;
    return StudioSessionGit(
      sessionId: sessionId,
      binding: StudioRepoBinding.tryParse(raw['repo']),
      available: available,
      reason: reason,
    );
  }
}

/// The answer to a successful clone (`POST …/git/clone`, 201).
class StudioCloneResult {
  const StudioCloneResult({
    required this.sessionId,
    required this.repo,
    required this.repoDir,
    required this.branch,
    required this.bindingStored,
  });

  final String sessionId;
  final String repo;
  final String repoDir;
  final String branch;

  /// False when the clone succeeded but the binding row could not be stored.
  /// The caller must not present that as a failed clone (the files are there).
  final bool bindingStored;

  static StudioCloneResult? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final sessionId = raw['sessionId'];
    final repo = raw['repo'];
    final repoDir = raw['repoDir'];
    final branch = raw['branch'];
    if (sessionId is! String || repo is! String) return null;
    if (repoDir is! String || repoDir.isEmpty) return null;
    if (branch is! String) return null;
    return StudioCloneResult(
      sessionId: sessionId,
      repo: repo,
      repoDir: repoDir,
      branch: branch,
      bindingStored: raw['bindingStored'] == true,
    );
  }
}

/// The answer to `POST …/git/branch`.
class StudioSwitchResult {
  const StudioSwitchResult({
    required this.status,
    required this.branch,
    required this.stashed,
    required this.message,
    this.stashRef,
    this.stashNote,
  });

  /// `switched`, `unchanged` or `failed`.
  final String status;
  final String branch;
  final bool stashed;
  final String message;
  final String? stashRef;
  final String? stashNote;

  static StudioSwitchResult? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final status = raw['status'];
    final branch = raw['branch'];
    if (status is! String || branch is! String) return null;
    final stashRef = raw['stashRef'];
    final stashNote = raw['stashNote'];
    final message = raw['message'];
    return StudioSwitchResult(
      status: status,
      branch: branch,
      stashed: raw['stashed'] == true,
      message: message is String ? message : '',
      stashRef: stashRef is String && stashRef.isNotEmpty ? stashRef : null,
      stashNote: stashNote is String && stashNote.isNotEmpty ? stashNote : null,
    );
  }
}

/// The answer to `POST …/git/sync`.
class StudioSyncResult {
  const StudioSyncResult({
    required this.status,
    required this.dirty,
    required this.behind,
    required this.ahead,
    required this.branch,
    required this.message,
    this.reason,
  });

  /// `up_to_date`, `synced` or `needs_merge`.
  final String status;
  final bool? dirty;
  final int? behind;
  final int? ahead;
  final String branch;
  final String message;

  /// Present when the worker refused to touch the tree:
  /// `dirty_worktree`, `diverged`, `no_upstream` or `merge_failed`.
  final String? reason;

  bool get needsMerge => status == 'needs_merge';

  static StudioSyncResult? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final status = raw['status'];
    final branch = raw['branch'];
    if (status is! String || branch is! String) return null;
    final behind = raw['behind'];
    final ahead = raw['ahead'];
    final message = raw['message'];
    final reason = raw['reason'];
    return StudioSyncResult(
      status: status,
      dirty: raw['dirty'] is bool ? raw['dirty'] as bool : null,
      behind: behind is num ? behind.toInt() : null,
      ahead: ahead is num ? ahead.toInt() : null,
      branch: branch,
      message: message is String ? message : '',
      reason: reason is String && reason.isNotEmpty ? reason : null,
    );
  }
}

/// Read-only repository state from `POST …/git/preflight` or
/// `GET …/git/status`. Missing server values stay null; they are never
/// presented as a clean tree or a real zero.
class StudioGitStatus {
  const StudioGitStatus({
    required this.branch,
    required this.headSha,
    required this.upstream,
    required this.dirty,
    required this.ahead,
    required this.behind,
    required this.reason,
    required this.fetchedAt,
  });

  final String branch;
  final String headSha;
  final String? upstream;
  final bool? dirty;
  final int? ahead;
  final int? behind;
  final String? reason;
  final DateTime? fetchedAt;

  static StudioGitStatus? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final branch = raw['branch'];
    final headSha = raw['headSha'];
    if (branch is! String || headSha is! String) return null;
    final upstream = raw['upstream'];
    final ahead = raw['ahead'];
    final behind = raw['behind'];
    final reason = raw['reason'];
    final fetchedAt = raw['fetchedAt'];
    return StudioGitStatus(
      branch: branch,
      headSha: headSha,
      upstream: upstream is String && upstream.isNotEmpty ? upstream : null,
      dirty: raw['dirty'] is bool ? raw['dirty'] as bool : null,
      ahead: ahead is num ? ahead.toInt() : null,
      behind: behind is num ? behind.toInt() : null,
      reason: reason is String && reason.isNotEmpty ? reason : null,
      fetchedAt: fetchedAt is String ? DateTime.tryParse(fetchedAt) : null,
    );
  }
}

/// One source patch used to build a combined changeset. [staged] records the
/// actual gateway query, not an inferred Git state.
class StudioDiffPart {
  const StudioDiffPart({required this.patch, required this.staged});

  final String patch;
  final bool staged;
}

/// The gateway's bounded unified diff. [parts] is populated only by
/// [StudioGitApi.combinedDiff], so the UI can merge same-path records with
/// explicit staged/unstaged semantics instead of displaying duplicates.
/// Joining those parts with `\n` reproduces [patch] exactly, within the same
/// 256-KiB budget as the scoped content the mapper consumes.
class StudioDiff {
  const StudioDiff({
    required this.patch,
    required this.truncated,
    this.parts = const <StudioDiffPart>[],
  });

  final String patch;
  final bool truncated;
  final List<StudioDiffPart> parts;

  static StudioDiff? tryParse(Object? raw) {
    if (raw is! Map || raw['patch'] is! String) return null;
    final original = raw['patch'] as String;
    final tooLong = utf8.encode(original).length > studioDiffMaxBytes;
    final redacted = _redactStudioText(original);
    final bounded = _boundedStudioUtf8(redacted, studioDiffMaxBytes);
    return StudioDiff(
      patch: bounded.value,
      truncated: raw['truncated'] == true || tooLong || bounded.truncated,
    );
  }
}

class StudioRunLogRecord {
  const StudioRunLogRecord({
    required this.sha,
    required this.subject,
    required this.authoredAt,
  });

  final String sha;
  final String subject;
  final DateTime? authoredAt;
}

/// One bounded commit-log page. The current Task 4 gateway exposes `limit`
/// but no cursor, so [nextCursor] remains null unless a later server supplies
/// one; non-null client cursors are refused rather than silently ignored.
class StudioRunLogPage {
  const StudioRunLogPage({
    required this.items,
    required this.nextCursor,
    required this.truncated,
  });

  final List<StudioRunLogRecord> items;
  final String? nextCursor;
  final bool truncated;

  static StudioRunLogPage parse(Object? raw) {
    if (raw is! Map) {
      throw _unreadableStudioResult('log');
    }
    final rawItems = raw['items'];
    if (rawItems is! List) throw _unreadableStudioResult('log');
    final items = <StudioRunLogRecord>[];
    var truncated =
        raw['truncated'] == true || rawItems.length > studioLogLimit;
    for (final item in rawItems.take(studioLogLimit)) {
      if (item is! Map) continue;
      final sha = item['sha'];
      final subject = item['subject'];
      if (sha is! String || subject is! String) continue;
      final bounded = _boundedStudioUtf8(
        _redactStudioText(subject),
        studioLogSubjectMaxBytes,
      );
      truncated = truncated || bounded.truncated;
      final authoredAt = item['authoredAt'];
      items.add(
        StudioRunLogRecord(
          sha: sha,
          subject: bounded.value,
          authoredAt: authoredAt is String
              ? DateTime.tryParse(authoredAt)
              : null,
        ),
      );
    }
    final cursor = raw['nextCursor'];
    return StudioRunLogPage(
      items: List<StudioRunLogRecord>.unmodifiable(items),
      nextCursor: cursor is String && cursor.isNotEmpty ? cursor : null,
      truncated: truncated,
    );
  }
}

class StudioPathSearchMatch {
  const StudioPathSearchMatch({required this.path, required this.name});

  final String path;
  final String name;
}

class StudioPathSearchPage {
  const StudioPathSearchPage({required this.items, required this.truncated});

  final List<StudioPathSearchMatch> items;
  final bool truncated;

  static StudioPathSearchPage parse(Object? raw) {
    if (raw is! Map || raw['items'] is! List) {
      throw _unreadableStudioResult('search');
    }
    final rawItems = raw['items'] as List;
    final items = <StudioPathSearchMatch>[];
    for (final item in rawItems.take(studioSearchLimit)) {
      if (item is! Map || item['path'] is! String || item['name'] is! String) {
        continue;
      }
      items.add(
        StudioPathSearchMatch(
          path: _redactStudioText(item['path'] as String),
          name: _redactStudioText(item['name'] as String),
        ),
      );
    }
    return StudioPathSearchPage(
      items: List<StudioPathSearchMatch>.unmodifiable(items),
      truncated:
          raw['truncated'] == true || rawItems.length > studioSearchLimit,
    );
  }
}

const int studioDiffMaxBytes = 256 * 1024;
const int studioLogLimit = 50;
const int studioLogSubjectMaxBytes = 4 * 1024;
const int studioSearchLimit = 100;

/// The deployment has no git transport yet (`503 studio_git_unavailable`).
///
/// This is a state of the deployment, not a bug and not a success: callers
/// must show [message] plainly and must not claim the operation happened.
class StudioGitUnavailableException implements Exception {
  const StudioGitUnavailableException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Client for the gateway's Studio GitHub + git surface.
class StudioGitApi {
  StudioGitApi({CloudRestClient? rest, CloudSessionStore? sessions})
    : _rest = rest ?? CloudRestClient.I,
      // ignore: prefer_initializing_formals
      _sessions = sessions;

  final CloudRestClient _rest;

  /// Null uses the process store lazily, so constructing this client in a
  /// test never touches SharedPreferences.
  final CloudSessionStore? _sessions;

  CloudSessionStore get _store => _sessions ?? CloudSessionStore.I;

  /// The server UUID for a local (or already-server) chat id, or null when
  /// the chat has never reached the server.
  Future<String?> _serverId(String sessionId) async {
    final store = _store;
    await store.resolveServerSessionIdAsync(sessionId);
    return store.knownServerIdFor(sessionId);
  }

  Future<String> _requireServerId(String sessionId) async {
    final id = await _serverId(sessionId);
    if (id == null) {
      throw CloudApiException(
        status: 0,
        code: 'no_server_session',
        message: 'This chat is not on the server yet.',
      );
    }
    return id;
  }

  /// `GET /studio/github` — the gateway's own connection state. A 409 is
  /// never produced here: "not connected" is a 200 with `connected: false`.
  Future<StudioGithubConnection> github() async {
    final json = await _rest.getJson('/studio/github');
    return StudioGithubConnection.fromJson(json);
  }

  /// `GET /studio/repos` — one page of repositories the token can push to.
  Future<StudioPage<StudioRepo>> repos({int page = 1, int perPage = 30}) async {
    final json = await _rest.getJson(
      '/studio/repos',
      query: <String, String>{'page': '$page', 'perPage': '$perPage'},
    );
    return StudioPage.parse<StudioRepo>(json, StudioRepo.tryParse);
  }

  /// `GET /studio/repos/:owner/:repo/branches` — one page of branches.
  Future<StudioPage<StudioBranch>> branches(
    String owner,
    String repo, {
    int page = 1,
    int perPage = 30,
  }) async {
    final json = await _rest.getJson(
      '/studio/repos/${Uri.encodeComponent(owner)}/${Uri.encodeComponent(repo)}'
      '/branches',
      query: <String, String>{'page': '$page', 'perPage': '$perPage'},
    );
    return StudioPage.parse<StudioBranch>(json, StudioBranch.tryParse);
  }

  /// `GET /studio/sessions/:id/git` — the binding + the capability flag.
  ///
  /// Null when the chat has no server session yet: there is nothing on the
  /// server to ask about, and the caller must not invent a binding.
  Future<StudioSessionGit?> sessionGit(String sessionId) async {
    final serverId = await _serverId(sessionId);
    if (serverId == null) return null;
    final json = await _rest.getJson('/studio/sessions/$serverId/git');
    return StudioSessionGit.tryParse(json);
  }

  /// Fetch-only inspection. The worker updates remote refs only; it never
  /// fast-forwards, resets, stashes, or rewrites the checked-out worktree.
  Future<StudioGitStatus> inspect(String sessionId) async {
    final serverId = await _requireServerId(sessionId);
    final json = await _gitPost(
      '/studio/sessions/$serverId/git/preflight',
      body: const <String, Object>{},
    );
    final result = StudioGitStatus.tryParse(json);
    if (result == null) throw _unreadableStudioResult('status');
    return result;
  }

  /// Local repository status only; unlike [inspect], this performs no fetch.
  Future<StudioGitStatus> status(String sessionId) async {
    final serverId = await _requireServerId(sessionId);
    final json = await _gitGet('/studio/sessions/$serverId/git/status');
    final result = StudioGitStatus.tryParse(json);
    if (result == null) throw _unreadableStudioResult('status');
    return result;
  }

  /// The server's unified diff, capped at 256 KiB before it reaches widgets.
  /// [staged] selects `git diff --cached`; untracked files need a separate
  /// server capability and are never claimed by this response.
  Future<StudioDiff> diff(
    String sessionId, {
    String? path,
    bool staged = false,
  }) async {
    if (path != null && path.trim().isEmpty) {
      throw CloudApiException(
        status: 400,
        code: 'bad_request',
        message: 'A diff path must not be empty.',
      );
    }
    final serverId = await _requireServerId(sessionId);
    final json = await _gitGet(
      '/studio/sessions/$serverId/git/diff',
      query: <String, String>{
        if (staged) 'staged': 'true',
        if (path != null) 'path': path.trim(),
      },
    );
    final result = StudioDiff.tryParse(json);
    if (result == null) throw _unreadableStudioResult('diff');
    return result;
  }

  /// Reads both staged and unstaged patches without changing the worktree.
  /// The current gateway has no untracked-file diff operation, so callers must
  /// use `status.dirty` to keep coverage/totals unknown when appropriate.
  Future<StudioDiff> combinedDiff(String sessionId, {String? path}) async {
    final unstaged = await diff(sessionId, path: path);
    final staged = await diff(sessionId, path: path, staged: true);
    final bounded = _boundedCombinedDiffParts(<StudioDiffPart>[
      if (unstaged.patch.isNotEmpty)
        StudioDiffPart(patch: unstaged.patch, staged: false),
      if (staged.patch.isNotEmpty)
        StudioDiffPart(patch: staged.patch, staged: true),
    ], truncated: unstaged.truncated || staged.truncated);
    return StudioDiff(
      // The mapper joins these exact parts with the same newline separator.
      // One shared budget therefore covers both representations; no scoped
      // content outside this bounded patch can leak into parsing/rendering.
      patch: <String>[for (final part in bounded.parts) part.patch].join('\n'),
      truncated: bounded.truncated,
      parts: bounded.parts,
    );
  }

  /// Bounded commit history. Task 4 has no cursor query, so a caller cannot
  /// accidentally send an unsupported cursor or mistake a partial page for a
  /// complete history.
  Future<StudioRunLogPage> logs(
    String sessionId, {
    String? cursor,
    int limit = 20,
  }) async {
    if (cursor != null) {
      throw CloudApiException(
        status: 400,
        code: 'unsupported_cursor',
        message: 'This deployment does not support older git log pages.',
      );
    }
    final boundedLimit = limit < 1
        ? 1
        : (limit > studioLogLimit ? studioLogLimit : limit);
    final serverId = await _requireServerId(sessionId);
    final json = await _gitGet(
      '/studio/sessions/$serverId/git/logs',
      query: <String, String>{'limit': '$boundedLimit'},
    );
    return StudioRunLogPage.parse(json);
  }

  /// Read-only file search below the server-side repository binding.
  Future<StudioPathSearchPage> search(
    String sessionId, {
    required String query,
    String? path,
    int limit = 50,
  }) async {
    final needle = query.trim();
    if (needle.isEmpty || (path != null && path.trim().isEmpty)) {
      throw CloudApiException(
        status: 400,
        code: 'bad_request',
        message: 'Enter a file search and a valid path.',
      );
    }
    final boundedLimit = limit < 1
        ? 1
        : (limit > studioSearchLimit ? studioSearchLimit : limit);
    final serverId = await _requireServerId(sessionId);
    final json = await _gitGet(
      '/studio/sessions/$serverId/files/search',
      query: <String, String>{
        'q': needle,
        if (path != null) 'path': path.trim(),
        'limit': '$boundedLimit',
      },
    );
    return StudioPathSearchPage.parse(json);
  }

  /// `POST /studio/sessions/:id/git/clone`.
  Future<StudioCloneResult> clone(
    String sessionId, {
    required String repo,
    String? branch,
    String? dest,
  }) async {
    final serverId = await _requireServerId(sessionId);
    final json = await _gitPost(
      '/studio/sessions/$serverId/git/clone',
      body: <String, Object>{
        'repo': repo,
        if (branch != null && branch.trim().isNotEmpty) 'branch': branch.trim(),
        if (dest != null && dest.trim().isNotEmpty) 'dest': dest.trim(),
      },
    );
    final result = StudioCloneResult.tryParse(json);
    if (result == null) {
      throw CloudApiException(
        status: 200,
        code: 'internal',
        message: 'Ovid Cloud returned an unreadable clone result.',
      );
    }
    return result;
  }

  /// `POST /studio/sessions/:id/git/branch`.
  Future<StudioSwitchResult> switchBranch(
    String sessionId, {
    required String branch,
  }) async {
    final serverId = await _requireServerId(sessionId);
    final json = await _gitPost(
      '/studio/sessions/$serverId/git/branch',
      body: <String, Object>{'branch': branch.trim()},
    );
    final result = StudioSwitchResult.tryParse(json);
    if (result == null) {
      throw CloudApiException(
        status: 200,
        code: 'internal',
        message: 'Ovid Cloud returned an unreadable branch result.',
      );
    }
    return result;
  }

  /// `POST /studio/sessions/:id/git/sync`.
  Future<StudioSyncResult> sync(String sessionId) async {
    final serverId = await _requireServerId(sessionId);
    final json = await _gitPost('/studio/sessions/$serverId/git/sync');
    final result = StudioSyncResult.tryParse(json);
    if (result == null) {
      throw CloudApiException(
        status: 200,
        code: 'internal',
        message: 'Ovid Cloud returned an unreadable sync result.',
      );
    }
    return result;
  }

  Future<Map<String, dynamic>> _gitGet(
    String path, {
    Map<String, String>? query,
  }) async {
    try {
      return await _rest.getJson(path, query: query);
    } on CloudApiException catch (error) {
      if (error.code == 'studio_git_unavailable') {
        throw StudioGitUnavailableException(error.message);
      }
      rethrow;
    }
  }

  /// A git mutation: the one place the honest 503 refusal is recognised.
  Future<Map<String, dynamic>> _gitPost(String path, {Object? body}) async {
    try {
      return await _rest.postJson(path, body: body);
    } on CloudApiException catch (error) {
      if (error.code == 'studio_git_unavailable') {
        throw StudioGitUnavailableException(error.message);
      }
      rethrow;
    }
  }
}

CloudApiException _unreadableStudioResult(String operation) =>
    CloudApiException(
      status: 200,
      code: 'internal',
      message: 'Ovid Cloud returned an unreadable Studio $operation result.',
    );

final RegExp _githubCredentialPattern = RegExp(
  r'(?:github_pat_[A-Za-z0-9_]{10,}|gh[pousr]_[A-Za-z0-9]{20,})',
);
final RegExp _authorizationCredentialPattern = RegExp(
  r'\b(?:bearer|token)\s+[A-Za-z0-9._~+/=-]{8,}',
  caseSensitive: false,
);

String _redactStudioText(String value) => value
    .replaceAll(_githubCredentialPattern, '[redacted]')
    .replaceAll(_authorizationCredentialPattern, '[redacted]');

({List<StudioDiffPart> parts, bool truncated}) _boundedCombinedDiffParts(
  List<StudioDiffPart> source, {
  required bool truncated,
}) {
  final parts = <StudioDiffPart>[];
  var remaining = studioDiffMaxBytes;
  for (final part in source) {
    if (remaining <= 0) {
      truncated = true;
      break;
    }
    if (parts.isNotEmpty) {
      // Joining nonempty scoped parts costs one separator byte. Reserve it
      // only when content from the next part can actually be retained.
      remaining--;
      if (remaining <= 0) {
        truncated = true;
        break;
      }
    }
    final bounded = _boundedStudioUtf8(part.patch, remaining);
    if (bounded.value.isEmpty && part.patch.isNotEmpty) {
      truncated = true;
      break;
    }
    parts.add(StudioDiffPart(patch: bounded.value, staged: part.staged));
    remaining -= utf8.encode(bounded.value).length;
    truncated = truncated || bounded.truncated;
    if (bounded.truncated) break;
  }
  if (parts.length != source.length) truncated = true;
  return (
    parts: List<StudioDiffPart>.unmodifiable(parts),
    truncated: truncated,
  );
}

({String value, bool truncated}) _boundedStudioUtf8(
  String value,
  int maxBytes,
) {
  final bytes = utf8.encode(value);
  if (bytes.length <= maxBytes) return (value: value, truncated: false);
  var end = maxBytes;
  while (end > 0 && (bytes[end] & 0xC0) == 0x80) {
    end--;
  }
  return (value: utf8.decode(bytes.sublist(0, end)), truncated: true);
}
