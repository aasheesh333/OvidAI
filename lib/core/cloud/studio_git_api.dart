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
  final bool dirty;
  final int behind;
  final int ahead;
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
      dirty: raw['dirty'] == true,
      behind: behind is num ? behind.toInt() : 0,
      ahead: ahead is num ? ahead.toInt() : 0,
      branch: branch,
      message: message is String ? message : '',
      reason: reason is String && reason.isNotEmpty ? reason : null,
    );
  }
}

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
