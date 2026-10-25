import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../../../core/cloud/artifact_vault.dart';
import '../../../core/cloud/cloud_rest.dart';
import '../../../core/cloud/cloud_session_store.dart';
import '../../../core/cloud/studio_git_api.dart';
import '../../../core/connectors/connector_api.dart';
import '../../../core/connectors/remote_connector_controller.dart';
import '../../../core/chat_integration_ports.dart';
import '../../../core/firebase_service.dart';
import '../../../core/revenuecat_billing.dart';
import '../../../core/state.dart';
import '../../../core/session_artifacts.dart';
import '../browser/browser_live_page.dart';
import '../connectors/connector_catalog_loader.dart';
import '../connectors/connectors_page.dart';
import '../library/artifact_detail_page.dart';
import '../library/artifacts_page.dart';
import '../schedules/schedules_flow.dart';
import '../studio/repo_picker_page.dart';
import 'v2_settings_actions.dart';
import 'v2_studio_routes.dart';

/// Routes for the work surfaces (Studio, Browser, Artifacts, Schedules,
/// Connectors). Reads live state; every screen stays presentational.
class V2WorkRoutes {
  const V2WorkRoutes._();

  static Future<void> openStudio(
    BuildContext context,
    V2SettingsActions actions,
  ) {
    return openRepoPicker(context, actions: actions);
  }

  /// Opens the repository picker. [actions] is optional so a screen that only
  /// needs the repo/branch gate (the workspace's "Pick a repository") can
  /// open the picker without owning the Settings surface; the token shortcut
  /// is hidden in that case.
  static Future<void> openRepoPicker(
    BuildContext context, {
    V2SettingsActions? actions,
  }) async {
    // Install the GitHub-backed port once, unless another workstream already
    // installed one (its implementation wins).
    StudioBindingPort.instance ??= GitHubStudioBindingPort();
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => _RepoPickerHost(actions: actions),
      ),
    );
  }

  static Future<void> openBrowser(
    BuildContext context,
    V2SettingsActions actions,
  ) async {
    await Navigator.of(
      context,
    ).push(MaterialPageRoute<void>(builder: (_) => const BrowserLivePage()));
  }

  /// The account the Artifact Vault fences every mint against, or null when
  /// signed out. Chat-derived artifact rows carry it so their detail page can
  /// mint a fresh capability exactly like a library row.
  static String? get artifactAccountId {
    final svc = FirebaseService.I;
    return svc.isSignedIn && svc.uid != null ? 'firebase:${svc.uid}' : null;
  }

  /// Opens one artifact with the same host the library uses.
  ///
  /// Minting and the preview fetch happen only after the explicit tap. A
  /// transcript row that already carries a signed URL uses it; a row with a
  /// cloud identity mints a fresh one; metadata still renders when both fail.
  static Future<void> openArtifactDetail(
    BuildContext context,
    SessionArtifact artifact,
  ) {
    final accountId = artifactAccountId;
    final client = ArtifactVaultClient(accountId: () => accountId);
    return Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => _ArtifactDetailHost(client: client, artifact: artifact),
      ),
    );
  }

  static Future<void> openArtifacts(
    BuildContext context,
    V2SettingsActions actions,
  ) async {
    final accountId = artifactAccountId;
    final client = ArtifactVaultClient(accountId: () => accountId);
    final controller = ArtifactVaultController(client: client);
    await controller.reload();
    final items = controller.items;
    if (!context.mounted) {
      controller.dispose();
      return;
    }
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ArtifactsPage(
          data: V2ArtifactsData(
            status: items.isEmpty
                ? V2ArtifactsStatus.empty
                : V2ArtifactsStatus.content,
            artifacts: [
              for (final artifact in items) artifactItemFor(artifact),
            ],
          ),
          onArtifactTap: (item) async {
            final artifact = items.where((a) => a.id == item.id).firstOrNull;
            if (artifact == null) return;
            await openArtifactDetail(context, artifact);
          },
        ),
      ),
    );
    controller.dispose();
  }

  /// Maps one vault row onto the library card.
  ///
  /// The cloud row carries no saved URL (a signed capability is minted only
  /// when a row is opened), so [V2ArtifactItem.url] stays null here. Source,
  /// size and the originating chat title are authoritative fields and are
  /// always passed, which is what gives the library its session and source
  /// filters real options.
  @visibleForTesting
  static V2ArtifactItem artifactItemFor(SessionArtifact artifact) =>
      V2ArtifactItem(
        id: artifact.id,
        name: artifact.name,
        kind: _kindOf(artifact.kind),
        createdAt: artifact.time,
        sizeLabel: _bytes(artifact.size ?? 0),
        sizeBytes: artifact.size ?? 0,
        source: artifact.origin == ArtifactOrigin.uploaded
            ? V2ArtifactSource.uploaded
            : V2ArtifactSource.generated,
        sessionTitle: artifact.sessionTitle,
        url: artifact.url,
      );

  static Future<void> openSchedules(
    BuildContext context,
    V2SettingsActions actions,
  ) => V2SchedulesFlow.openSchedules(
    context,
    sessionId: AppState.I.activeSessionId,
  );

  /// Opens the connector catalogue the GATEWAY serves.
  ///
  /// The list used to be a hardcoded empty array, so every row came from the
  /// built-in design catalogue and enabling one only set a local flag. The
  /// server is now the source of truth: what it does not serve, the screen
  /// does not offer.
  ///
  /// [actions] is nullable because the Studio picker opens this screen from
  /// the workspace's empty state, which has no Settings surface to lend. The
  /// catalogue read does not need it.
  static Future<void> openConnectors(
    BuildContext context,
    V2SettingsActions? actions, {
    ConnectorApi? connectorApi,
    String? Function()? accountId,
  }) async {
    final controller = RemoteConnectorController(
      api: connectorApi ?? ConnectorApi(),
      accountId: accountId ?? () => artifactAccountId,
      // This route now has versioned readiness, item health and canonical
      // create/lifecycle fences. Do not use the unavailable fallback.
      capabilities: ConnectorGatewayCapabilities.connectionLifecycle,
    );
    try {
      await controller.reload();
      if (!context.mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => ConnectorsPage(
            data: connectorCatalogForState(controller.value),
            controller: controller,
            // The cap follows the server-confirmed plan, not the display cache.
            plan: V2ConnectorPlan.forTier(
              confirmedPlanTier ?? AppState.I.ovidCloudTier,
            ),
            onRetry: controller.reload,
          ),
        ),
      );
    } finally {
      controller.dispose();
    }
  }

  static String _typeLabel(ArtifactKind kind) => switch (kind) {
    ArtifactKind.image => 'Image',
    ArtifactKind.html => 'Page',
    ArtifactKind.code => 'Code',
    ArtifactKind.document => 'Document',
    ArtifactKind.other => 'File',
  };

  static V2ArtifactKind _kindOf(ArtifactKind kind) => switch (kind) {
    ArtifactKind.image => V2ArtifactKind.image,
    ArtifactKind.html => V2ArtifactKind.document,
    ArtifactKind.code => V2ArtifactKind.code,
    ArtifactKind.document => V2ArtifactKind.document,
    ArtifactKind.other => V2ArtifactKind.data,
  };

  static String _bytes(int value) {
    if (value <= 0) return '';
    if (value < 1024) return '$value B';
    if (value < 1024 * 1024) return '${(value / 1024).toStringAsFixed(1)} KB';
    return '${(value / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  static String _timeLabel(DateTime at) {
    final local = at.toLocal();
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    if (!local.isBefore(today)) {
      final h = local.hour.toString().padLeft(2, '0');
      final m = local.minute.toString().padLeft(2, '0');
      return '$h:$m';
    }
    return '${local.day}/${local.month}';
  }
}

/// Opens one vault artifact with the real minted capability and, for text
/// files, the head of the file itself.
///
/// Minting and the preview fetch happen only after the explicit row tap. The
/// metadata still renders when either fails; Download, Copy link and Open
/// externally stay hidden until a URL really exists.
class _ArtifactDetailHost extends StatefulWidget {
  const _ArtifactDetailHost({required this.client, required this.artifact});

  final ArtifactVaultClient client;
  final SessionArtifact artifact;

  @override
  State<_ArtifactDetailHost> createState() => _ArtifactDetailHostState();
}

class _ArtifactDetailHostState extends State<_ArtifactDetailHost> {
  /// Preview text is bounded so a huge file never stalls the sheet.
  static const int _maxPreviewBytes = 1024 * 1024;
  static const int _maxPreviewLines = 200;

  static const Set<String> _textExtensions = {
    'txt',
    'md',
    'markdown',
    'csv',
    'tsv',
    'json',
    'yaml',
    'yml',
    'xml',
    'log',
    'ini',
    'toml',
    'sql',
    'dart',
    'js',
    'ts',
    'py',
    'css',
    'html',
    'htm',
  };

  V2ArtifactDetailStatus _status = V2ArtifactDetailStatus.loading;
  String _url = '';
  String _text = '';
  int? _totalLines;

  SessionArtifact get _artifact => widget.artifact;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  bool get _isTextual => switch (_artifact.kind) {
    ArtifactKind.code || ArtifactKind.html => true,
    ArtifactKind.image => false,
    ArtifactKind.document ||
    ArtifactKind.other => _textExtensions.contains(_extension),
  };

  String get _extension {
    final dot = _artifact.name.lastIndexOf('.');
    if (dot < 0 || dot == _artifact.name.length - 1) return '';
    return _artifact.name.substring(dot + 1).toLowerCase();
  }

  /// The inline page's real source: no URL, no fetch, nothing invented.
  String get _inlineText {
    final html = _artifact.html;
    if (html == null) return '';
    final buffer = StringBuffer(html.html);
    if (html.css.trim().isNotEmpty) {
      buffer.write('\n<style>\n${html.css}\n</style>');
    }
    if (html.javascript.trim().isNotEmpty) {
      buffer.write('\n<script>\n${html.javascript}\n</script>');
    }
    return buffer.toString();
  }

  V2ArtifactPreviewKind get _previewKind => switch (_artifact.kind) {
    ArtifactKind.image => V2ArtifactPreviewKind.image,
    ArtifactKind.code || ArtifactKind.html => V2ArtifactPreviewKind.code,
    ArtifactKind.document => V2ArtifactPreviewKind.document,
    ArtifactKind.other => V2ArtifactPreviewKind.data,
  };

  Future<void> _load() async {
    if (mounted) {
      setState(() => _status = V2ArtifactDetailStatus.loading);
    }
    var url = '';
    var text = _inlineText;
    int? totalLines = text.isEmpty ? null : text.split('\n').length;
    final cloudId = _artifact.cloudArtifactId ?? '';
    if (cloudId.isNotEmpty) {
      // A vault row: mint a fresh capability (the library path).
      try {
        url = (await widget.client.mintPreferredUrl(
          _artifact,
          download: true,
        )).url;
      } catch (_) {
        // No fresh capability: the detail still shows its real metadata.
      }
      // A transcript row also arrived with the URL the event minted; keep it
      // usable when the re-mint is refused instead of dropping a real link.
      if (url.isEmpty) url = _artifact.url ?? '';
    } else {
      // A transcript row already carries the URL the cloud event minted, or
      // has none. Nothing is minted without a cloud identity.
      url = _artifact.url ?? '';
    }
    final size = _artifact.size ?? 0;
    if (url.isNotEmpty &&
        _isTextual &&
        text.isEmpty &&
        (size == 0 || size <= _maxPreviewBytes)) {
      try {
        final response = await http
            .get(Uri.parse(url))
            .timeout(const Duration(seconds: 20));
        if (response.statusCode >= 200 &&
            response.statusCode < 300 &&
            response.bodyBytes.length <= _maxPreviewBytes) {
          final decoded = utf8.decode(response.bodyBytes, allowMalformed: true);
          final lines = decoded.split('\n');
          totalLines = lines.length;
          text = lines.take(_maxPreviewLines).join('\n');
        }
      } catch (_) {
        // The preview stays empty; the file can still be opened externally.
      }
    }
    if (!mounted) return;
    setState(() {
      _url = url;
      _text = text;
      _totalLines = totalLines;
      _status = V2ArtifactDetailStatus.content;
    });
  }

  @override
  Widget build(BuildContext context) {
    final code = _previewKind == V2ArtifactPreviewKind.code;
    final document =
        _previewKind == V2ArtifactPreviewKind.document ||
        _previewKind == V2ArtifactPreviewKind.data;
    return ArtifactDetailPage(
      data: V2ArtifactDetailData(
        status: _status,
        name: _artifact.name,
        typeLabel: V2WorkRoutes._typeLabel(_artifact.kind),
        sizeLabel: V2WorkRoutes._bytes(_artifact.size ?? 0),
        createdLabel: V2WorkRoutes._timeLabel(_artifact.time),
        sourceChatTitle: _artifact.sessionTitle,
        previewKind: _previewKind,
        previewCodeFile: _artifact.name,
        previewCode: code ? _text : '',
        previewTotalLines: code ? _totalLines : null,
        documentText: document ? _text : '',
        thumbnail:
            _previewKind == V2ArtifactPreviewKind.image && _url.isNotEmpty
            ? NetworkImage(_url)
            : null,
        downloadUrl: _url,
        // The same signed capability is what a recipient can open.
        shareUrl: _url,
        openUrl: _url,
        details: [
          V2ArtifactDetailRow(
            label: 'Type',
            value: V2WorkRoutes._typeLabel(_artifact.kind),
          ),
          V2ArtifactDetailRow(label: 'Source', value: _artifact.origin.name),
          if ((_artifact.size ?? 0) > 0)
            V2ArtifactDetailRow(
              label: 'Size',
              value: V2WorkRoutes._bytes(_artifact.size ?? 0),
            ),
          if (_artifact.path != null)
            V2ArtifactDetailRow(label: 'Path', value: _artifact.path!),
        ],
      ),
      onRetry: () => unawaited(_load()),
      onBackToArtifacts: () => Navigator.of(context).maybePop(),
    );
  }
}

/// The Studio binding backed by the GATEWAY's Studio routes.
///
/// The gateway owns the GitHub token (the curated `github` MCP row) and the
/// session→repo binding (`studio_repos`); it answers connection state, repo
/// pages and branch pages directly from GitHub, and forwards clone / branch
/// switch / sync to the worker's git service. This port is the thin client:
/// no GitHub token, no direct api.github.com call.
///
/// The three git mutations answer `503 studio_git_unavailable` until the
/// worker transport is wired. [bind] and [syncLatest] surface that refusal as
/// a [StudioAccessException] carrying the gateway's own message — they never
/// report a clone or sync that did not happen.
class GitHubStudioBindingPort extends StudioBindingPort {
  GitHubStudioBindingPort({StudioGitApi? api}) : _api = api ?? StudioGitApi();

  final StudioGitApi _api;

  /// Cached `GET /studio/github` answer; [ready] is false until it is loaded
  /// and says the user's GitHub integration is connected.
  bool _connected = false;
  String? _login;

  @override
  bool get ready => _connected;

  @override
  String? get accountLabel => _login;

  @override
  StudioBinding? bindingFor(String sessionId) {
    // Session-scoped on purpose: the Studio send gate asks "has THIS chat
    // selected a repo", and [AppState.getRepoForSession]'s last-selection
    // fallback would let a brand-new chat inherit another chat's binding.
    final session = AppState.I.sessionById(sessionId);
    final repo = session?.repo?.trim() ?? '';
    if (repo.isEmpty) return null;
    return StudioBinding(repo: repo, branch: session?.branch?.trim() ?? '');
  }

  @override
  Future<StudioGithubConnection?> loadConnection() async {
    try {
      final connection = await _api.github();
      _connected = connection.connected;
      _login = connection.login;
      notifyListeners();
      return connection;
    } on CloudApiException catch (error) {
      // Unreachable or misconfigured: no control may claim a connection.
      _connected = false;
      _login = null;
      notifyListeners();
      throw StudioAccessException(error.message);
    }
  }

  @override
  Future<List<String>> listRepos() async {
    final page = await _api.repos(perPage: 100);
    return [for (final repo in page.items) repo.fullName];
  }

  @override
  Future<StudioPage<StudioRepo>?> reposPage({int page = 1, int perPage = 30}) =>
      _api.repos(page: page, perPage: perPage);

  @override
  Future<List<String>> listBranches(String repo) async {
    final parts = repo.split('/');
    if (parts.length != 2 || parts[0].isEmpty || parts[1].isEmpty) {
      throw const StudioAccessException(
        'That repository address is not valid.',
      );
    }
    final page = await _api.branches(parts[0], parts[1], perPage: 100);
    return [for (final branch in page.items) branch.name];
  }

  /// Clones the repository into the session workspace through the gateway.
  ///
  /// The local binding is written only from the clone result, so a refused or
  /// failed clone can never open the Studio send gate.
  @override
  Future<void> bind(
    String sessionId, {
    required String repo,
    required String branch,
  }) async {
    try {
      // The clone route is session-scoped: the chat must exist on the server
      // before there is a session to clone into. A chat that has never been
      // sent is created here, exactly like its first message would.
      final serverId = await CloudSessionStore.I.ensureServerSession(sessionId);
      final result = await _api.clone(serverId, repo: repo, branch: branch);
      AppState.I
        ..setRepoForSession(sessionId, result.repo)
        ..setBranchForSession(sessionId, result.branch);
      notifyListeners();
    } on StudioGitUnavailableException catch (error) {
      throw StudioAccessException(error.message);
    } on CloudApiException catch (error) {
      throw StudioAccessException(error.message);
    }
  }

  @override
  Future<void> switchBranch(String sessionId, {required String branch}) async {
    try {
      final result = await _api.switchBranch(sessionId, branch: branch);
      AppState.I.setBranchForSession(sessionId, result.branch);
      notifyListeners();
    } on StudioGitUnavailableException catch (error) {
      throw StudioAccessException(error.message);
    } on CloudApiException catch (error) {
      throw StudioAccessException(error.message);
    }
  }

  /// Fetches and fast-forwards through the gateway.
  ///
  /// A `needs_merge` answer is a refusal to touch the tree (dirty worktree or
  /// divergence), so it is reported as such instead of "sync finished".
  @override
  Future<void> syncLatest(String sessionId) async {
    try {
      final result = await _api.sync(sessionId);
      final binding = bindingFor(sessionId);
      if (binding != null && binding.branch != result.branch) {
        AppState.I.setBranchForSession(sessionId, result.branch);
        notifyListeners();
      }
      if (result.needsMerge) throw StudioAccessException(result.message);
    } on StudioGitUnavailableException catch (error) {
      throw StudioAccessException(error.message);
    } on CloudApiException catch (error) {
      throw StudioAccessException(error.message);
    }
  }

  @override
  Future<StudioSessionGit?> loadSessionGit(String sessionId) async {
    try {
      final state = await _api.sessionGit(sessionId);
      final binding = state?.binding;
      if (binding != null) {
        AppState.I
          ..setRepoForSession(sessionId, binding.repo)
          ..setBranchForSession(sessionId, binding.branch);
        notifyListeners();
      }
      return state;
    } on CloudApiException {
      // A read that could not answer is not a binding; the caller keeps
      // whatever it already knew and draws no capability claim.
      return null;
    }
  }
}

/// A GitHub request the Studio surfaces can report verbatim.
class StudioAccessException implements Exception {
  const StudioAccessException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Loads the gateway-backed connection state, repository pages and branch
/// discovery for the Studio picker.
///
/// "Connected" is the GATEWAY's answer (`GET /studio/github`), which resolves
/// the curated `github` connector row — the same token the worker's git
/// service uses. A device-side GitHub login is not consulted: it would let the
/// screen claim a connection the agent cannot use.
class _RepoPickerHost extends StatefulWidget {
  const _RepoPickerHost({this.actions});

  /// Null when the picker was opened from the workspace's empty state, which
  /// has no Settings actions to lend. "Connect GitHub" then has no route and
  /// is not drawn.
  final V2SettingsActions? actions;

  @override
  State<_RepoPickerHost> createState() => _RepoPickerHostState();
}

class _RepoPickerHostState extends State<_RepoPickerHost> {
  static const int _perPage = 30;

  bool _loading = true;
  bool _connected = false;
  String? _login;
  String? _error;
  final List<V2Repo> _repos = <V2Repo>[];
  int _page = 1;
  bool _hasMore = false;
  bool _loadingMore = false;

  /// Guards a reload that overtakes an older in-flight one.
  int _request = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final port = StudioBindingPort.instance;
    final request = ++_request;
    if (port == null) {
      if (mounted) setState(() => _loading = false);
      return;
    }
    StudioGithubConnection? connection;
    String? error;
    try {
      connection = await port.loadConnection();
    } catch (e) {
      error = e is StudioAccessException
          ? e.message
          : 'We could not reach Ovid Cloud. Check your connection and retry.';
    }
    if (!mounted || request != _request) return;
    // A port with no gateway surface answers null: fall back to its own
    // readiness and its own list rather than claiming "disconnected".
    final connected = connection == null ? port.ready : connection.connected;
    final repos = <V2Repo>[];
    var page = 1;
    var hasMore = false;
    if (error == null && connected) {
      try {
        final first = await port.reposPage(page: 1, perPage: _perPage);
        if (first != null) {
          repos.addAll(first.items.map(_repoItem));
          page = first.page;
          hasMore = first.hasMore;
        } else {
          // A port without paging still answers its first list.
          for (final fullName in await port.listRepos()) {
            repos.add(_repoFromName(fullName));
          }
        }
      } catch (e) {
        error = e is StudioAccessException
            ? e.message
            : 'We could not load your repositories. Check your connection and '
                  'retry.';
      }
    }
    if (!mounted || request != _request) return;
    setState(() {
      _loading = false;
      _connected = connected;
      _login = connection?.login ?? port.accountLabel;
      _error = error;
      _repos
        ..clear()
        ..addAll(repos);
      _page = page;
      _hasMore = hasMore;
    });
  }

  /// Appends the next gateway page. A failed page leaves the list untouched;
  /// scrolling again is the retry.
  Future<void> _loadMore() async {
    if (_loadingMore || !_hasMore) return;
    final port = StudioBindingPort.instance;
    if (port == null) return;
    final request = _request;
    setState(() => _loadingMore = true);
    try {
      final next = await port.reposPage(page: _page + 1, perPage: _perPage);
      if (next == null || !mounted || request != _request) return;
      final known = {for (final repo in _repos) repo.id};
      setState(() {
        _repos.addAll([
          for (final repo in next.items.map(_repoItem))
            if (!known.contains(repo.id)) repo,
        ]);
        _page = next.page;
        _hasMore = next.hasMore;
      });
    } catch (_) {
      // The next scroll retries; nothing is claimed about this page.
    } finally {
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  static V2Repo _repoItem(StudioRepo repo) => V2Repo(
    id: repo.fullName,
    name: repo.name,
    owner: repo.owner,
    description: repo.description,
    isPrivate: repo.isPrivate,
    defaultBranch: repo.defaultBranch.isEmpty ? null : repo.defaultBranch,
  );

  static V2Repo _repoFromName(String fullName) {
    final parts = fullName.split('/');
    return V2Repo(
      id: fullName,
      name: parts.length > 1 ? parts.last : fullName,
      owner: parts.length > 1 ? parts.first : '',
    );
  }

  /// "Connect GitHub" opens the CONNECTORS screen.
  ///
  /// The gateway resolves the token from the curated `github` MCP row, so that
  /// row is the only connection Studio can use. The device-side GitHub login
  /// is not consulted here: it never reaches the worker's git service, and
  /// offering it would be a control that appears to connect Studio and does
  /// not.
  Future<void> _connectGithub() async {
    await V2WorkRoutes.openConnectors(context, widget.actions);
    if (mounted) unawaited(_load());
  }

  Future<void> _confirm(V2Repo repo, String branch) async {
    final port = StudioBindingPort.instance;
    if (port == null || !port.ready) return;
    var sessionId = AppState.I.activeSessionId;
    if (sessionId == null) {
      AppState.I.newSession();
      sessionId = AppState.I.activeSessionId;
    }
    if (sessionId == null) return;
    try {
      // The port clones through the gateway and writes the binding from the
      // clone result. A 503 `studio_git_unavailable` arrives here as the
      // gateway's own plain message — never as a completed clone.
      await port.bind(sessionId, repo: repo.id, branch: branch);
    } catch (e) {
      if (!mounted) return;
      _showMessage(
        e is StudioAccessException
            ? e.message
            : 'Could not open that repository. Try again.',
      );
      return;
    }
    if (!mounted) return;
    await V2StudioRoutes.openWorkspace(
      context,
      repo.id,
      branch,
      sessionId: sessionId,
    );
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<List<V2RepoBranch>> _loadBranches(V2Repo repo) async {
    final port = StudioBindingPort.instance;
    if (port == null || !port.ready) return const <V2RepoBranch>[];
    final names = await port.listBranches(repo.id);
    final preferred = repo.preferredBranch;
    return [
      for (final name in names)
        V2RepoBranch(
          name: name,
          isDefault: preferred != null && name == preferred,
        ),
    ];
  }

  V2RepoPickerData get _data {
    final error = _error;
    return V2RepoPickerData(
      status: _loading
          ? V2RepoPickerStatus.loading
          : error != null
          ? V2RepoPickerStatus.error
          : _repos.isEmpty
          ? V2RepoPickerStatus.empty
          : V2RepoPickerStatus.content,
      repos: _repos,
      githubConnected: _connected,
      accountLabel: _login == null ? null : '@$_login',
      errorMessage: error,
    );
  }

  @override
  Widget build(BuildContext context) {
    return V2RepoPickerPage(
      data: _data,
      onRetry: () => unawaited(_load()),
      onConnectGithub: () => unawaited(_connectGithub()),
      onLoadBranches: _loadBranches,
      onLoadMore: _hasMore ? _loadMore : null,
      onConfirm: _connected
          ? (repo, branch) => unawaited(_confirm(repo, branch))
          : null,
    );
  }
}
