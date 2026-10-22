import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../../../core/cloud/artifact_vault.dart';
import '../../../core/chat_integration_ports.dart';
import '../../../core/firebase_service.dart';
import '../../../core/github_service.dart';
import '../../../core/revenuecat_billing.dart';
import '../../../core/state.dart';
import '../../../core/session_artifacts.dart';
import '../../github_login_sheet.dart';
import '../browser/browser_live_page.dart';
import '../connectors/connectors_page.dart';
import '../library/artifact_detail_page.dart';
import '../library/artifacts_page.dart';
import '../schedules/schedules_flow.dart';
import '../studio/repo_picker_page.dart';
import 'v2_settings_actions.dart';
import 'v2_settings_routes.dart';
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

  static Future<void> openConnectors(
    BuildContext context,
    V2SettingsActions actions,
  ) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ConnectorsPage(
          data: const V2ConnectorsData(
            status: V2ConnectorsStatus.content,
            connectors: [],
          ),
          // The cap follows the server-confirmed plan, not the display cache.
          plan: V2ConnectorPlan.forTier(
            confirmedPlanTier ?? AppState.I.ovidCloudTier,
          ),
        ),
      ),
    );
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

/// The Studio binding backed by the signed-in GitHub account.
///
/// Repositories and branches come from the GitHub REST API with the token the
/// device flow (or a PAT in Credentials) put in [GitHubService]; the chosen
/// pair is written to the session, which is what the agent tools read. Nothing
/// is cached or invented: signed out means `ready == false`.
class GitHubStudioBindingPort extends StudioBindingPort {
  GitHubStudioBindingPort() {
    GitHubService.I.addListener(notifyListeners);
  }

  static const _api = 'https://api.github.com';

  @override
  bool get ready => GitHubService.I.isLoggedIn;

  @override
  StudioBinding? bindingFor(String sessionId) {
    final app = AppState.I;
    final repo = app.getRepoForSession(sessionId);
    if (repo == null || repo.trim().isEmpty) return null;
    return StudioBinding(
      repo: repo.trim(),
      branch: app.getBranchForSession(sessionId),
    );
  }

  @override
  Future<List<String>> listRepos() async {
    final body = await _get('/user/repos?per_page=100&sort=updated');
    if (body is! List) return const [];
    return [
      for (final row in body)
        if (row is Map && row['full_name'] is String)
          row['full_name'] as String,
    ];
  }

  @override
  Future<List<String>> listBranches(String repo) async {
    final body = await _get('/repos/$repo/branches?per_page=100');
    if (body is! List) return const [];
    return [
      for (final row in body)
        if (row is Map && row['name'] is String) row['name'] as String,
    ];
  }

  @override
  Future<void> bind(
    String sessionId, {
    required String repo,
    required String branch,
  }) async {
    AppState.I
      ..setRepoForSession(sessionId, repo)
      ..setBranchForSession(sessionId, branch);
    notifyListeners();
  }

  /// Confirms the binding still resolves on GitHub before the next task.
  @override
  Future<void> syncLatest(String sessionId) async {
    final binding = bindingFor(sessionId);
    if (binding == null) return;
    await _get('/repos/${binding.repo}');
  }

  @override
  void dispose() {
    GitHubService.I.removeListener(notifyListeners);
    super.dispose();
  }

  Future<Object?> _get(String path) async {
    final token = GitHubService.I.token;
    if (token == null || token.isEmpty) {
      throw const StudioAccessException('Sign in to GitHub to use Studio.');
    }
    final client = http.Client();
    try {
      final response = await client
          .get(
            Uri.parse('$_api$path'),
            headers: {
              'Authorization': 'Bearer $token',
              'Accept': 'application/vnd.github+json',
            },
          )
          .timeout(const Duration(seconds: 20));
      if (response.statusCode == 401) {
        throw const StudioAccessException(
          'GitHub sign-in expired. Connect GitHub again.',
        );
      }
      if (response.statusCode == 403 || response.statusCode == 429) {
        throw const StudioAccessException(
          'GitHub rate-limited this request. Try again in a minute.',
        );
      }
      if (response.statusCode != 200) {
        throw const StudioAccessException(
          'GitHub could not answer that request. Try again.',
        );
      }
      return jsonDecode(response.body);
    } finally {
      client.close();
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

/// Loads the real repository list, the GitHub device flow and branch discovery
/// for the Studio picker.
///
/// Repository and branch data come from the installed [StudioBindingPort];
/// without one the page says so instead of showing an empty "connected"
/// screen. GitHub sign-in is the real RFC 8628 device flow.
class _RepoPickerHost extends StatefulWidget {
  const _RepoPickerHost({this.actions});

  /// Null when the picker was opened from the workspace's empty state, which
  /// has no Settings actions to lend. The token shortcut is then hidden.
  final V2SettingsActions? actions;

  @override
  State<_RepoPickerHost> createState() => _RepoPickerHostState();
}

class _RepoPickerHostState extends State<_RepoPickerHost> {
  V2RepoPickerData _data = const V2RepoPickerData(
    status: V2RepoPickerStatus.loading,
  );
  bool _portReady = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final port = StudioBindingPort.instance;
    final ready = port?.ready ?? false;
    final repos = <V2Repo>[];
    String? error;
    if (port != null && port.ready) {
      try {
        for (final fullName in await port.listRepos()) {
          final parts = fullName.split('/');
          repos.add(
            V2Repo(
              id: fullName,
              name: parts.length > 1 ? parts.last : fullName,
              owner: parts.length > 1 ? parts.first : '',
            ),
          );
        }
      } catch (e) {
        error = e is StudioAccessException
            ? e.message
            : 'We could not load your repositories. Check your connection and '
                  'try again.';
      }
    }
    if (!mounted) return;
    setState(() {
      _portReady = ready;
      _data = V2RepoPickerData(
        status: error != null
            ? V2RepoPickerStatus.error
            : repos.isEmpty
            ? V2RepoPickerStatus.empty
            : V2RepoPickerStatus.content,
        repos: repos,
        githubConnected: ready,
        accountLabel: GitHubService.I.login == null
            ? null
            : '@${GitHubService.I.login}',
        errorMessage: error,
      );
    });
  }

  Future<void> _connectGithub() async {
    showGithubLoginSheet(context, onConnected: () => unawaited(_load()));
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
      await port.bind(sessionId, repo: repo.id, branch: branch);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Could not bind that repository. Try again.'),
          ),
        );
      }
      return;
    }
    // The chat's STUDIO send gate reads the session's repo/branch. A port is
    // expected to write them, but the route records the user's confirmed
    // choice too so the gate and the workspace can never disagree.
    AppState.I
      ..setRepoForSession(sessionId, repo.id)
      ..setBranchForSession(sessionId, branch);
    if (!mounted) return;
    await V2StudioRoutes.openWorkspace(
      context,
      repo.id,
      branch,
      sessionId: sessionId,
    );
  }

  Future<List<V2RepoBranch>> _loadBranches(V2Repo repo) async {
    final port = StudioBindingPort.instance;
    if (port == null || !port.ready) return const <V2RepoBranch>[];
    final names = await port.listBranches(repo.id);
    return [for (final name in names) V2RepoBranch(name: name)];
  }

  @override
  Widget build(BuildContext context) {
    return V2RepoPickerPage(
      data: _data,
      onRetry: () => unawaited(_load()),
      onConnectGithub: () => unawaited(_connectGithub()),
      // Token entry lives on the Credentials screen, where the real secure
      // store and validation already exist.
      onOpenToken: widget.actions == null
          ? null
          : () =>
                V2SettingsRoutes.open(context, 'credentials', widget.actions!),
      onLoadBranches: _loadBranches,
      onConfirm: _portReady
          ? (repo, branch) => unawaited(_confirm(repo, branch))
          : null,
    );
  }
}
