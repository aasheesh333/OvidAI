import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../../../core/cloud/artifact_vault.dart';
import '../../../core/cloud/schedule_client.dart';
import '../../../core/chat_integration_ports.dart';
import '../../../core/firebase_service.dart';
import '../../../core/github_service.dart';
import '../../../core/state.dart';
import '../../../core/session_artifacts.dart';
import '../../github_login_sheet.dart';
import '../browser/browser_live_page.dart';
import '../connectors/connectors_page.dart';
import '../library/artifact_detail_page.dart';
import '../library/artifacts_page.dart';
import '../schedules/schedule_runs_page.dart';
import '../schedules/schedules_page.dart';
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
  ) async {
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
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => const BrowserLivePage(),
      ),
    );
  }

  static Future<void> openArtifacts(
    BuildContext context,
    V2SettingsActions actions,
  ) async {
    final svc = FirebaseService.I;
    final accountId = svc.isSignedIn && svc.uid != null
        ? 'firebase:${svc.uid}'
        : null;
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
              for (final artifact in items)
                V2ArtifactItem(
                  id: artifact.id,
                  name: artifact.name,
                  kind: _kindOf(artifact.kind),
                  createdAt: artifact.time,
                  sizeLabel: _bytes(artifact.size ?? 0),
                ),
            ],
          ),
          onArtifactTap: (item) async {
            final artifact = items.where((a) => a.id == item.id).firstOrNull;
            if (artifact == null) return;
            // Minting happens only on this explicit tap, never for list rows.
            String downloadUrl = '';
            try {
              final minted = await client.mintPreferredUrl(
                artifact,
                download: true,
              );
              downloadUrl = minted.url;
            } catch (_) {
              // The detail still opens; Download stays hidden without a URL.
            }
            if (!context.mounted) return;
            await Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => ArtifactDetailPage(
                  data: V2ArtifactDetailData(
                    name: artifact.name,
                    typeLabel: artifact.kind.name,
                    sizeLabel: _bytes(artifact.size ?? 0),
                    createdLabel: _timeLabel(artifact.time),
                    sourceChatTitle: artifact.sessionTitle,
                    downloadUrl: downloadUrl,
                    openUrl: downloadUrl,
                    details: [
                      V2ArtifactDetailRow(
                        label: 'Source',
                        value: artifact.origin.name,
                      ),
                      if (artifact.path != null)
                        V2ArtifactDetailRow(
                          label: 'Path',
                          value: artifact.path!,
                        ),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
    controller.dispose();
  }

  static Future<void> openSchedules(
    BuildContext context,
    V2SettingsActions actions,
  ) async {
    final client = ScheduleClient.I;
    List<ScheduleDto> schedules = const [];
    try {
      schedules = await client.list();
    } catch (_) {
      // Empty state below.
    }
    if (!context.mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => SchedulesPage(
          data: V2SchedulesData(
            status: schedules.isEmpty
                ? V2SchedulesStatus.empty
                : V2SchedulesStatus.content,
            schedules: [
              for (final schedule in schedules)
                V2ScheduleItem(
                  id: schedule.id,
                  title: schedule.title,
                  description: schedule.description,
                  rule: schedule.trigger.describe(),
                  nextRun: schedule.nextRunAt == null
                      ? null
                      : _timeLabel(schedule.nextRunAt!),
                  enabled: schedule.status == 'active',
                  lastRunFailed: schedule.lastResult?.status == 'failed',
                ),
            ],
          ),
          // No schedule authoring screen is wired yet; the list stays
          // read-only instead of offering controls that cannot run.
          onCreate: null,
          onScheduleTap: (item) => Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => const ScheduleRunsPage(
                data: V2ScheduleRunsData(),
              ),
            ),
          ),
          onToggle: null,
          onRetryRun: null,
        ),
      ),
    );
  }

  static Future<void> openConnectors(
    BuildContext context,
    V2SettingsActions actions,
  ) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => const ConnectorsPage(
          data: V2ConnectorsData(
            status: V2ConnectorsStatus.content,
            connectors: [],
          ),
        ),
      ),
    );
  }

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
        if (row is Map && row['full_name'] is String) row['full_name'] as String,
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
        throw StudioAccessException(
          'GitHub answered ${response.statusCode} for that request.',
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
  const _RepoPickerHost({required this.actions});

  final V2SettingsActions actions;

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
    showGithubLoginSheet(
      context,
      onConnected: () => unawaited(_load()),
    );
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
      onOpenToken: () =>
          V2SettingsRoutes.open(context, 'credentials', widget.actions),
      onLoadBranches: _loadBranches,
      onConfirm: _portReady ? (repo, branch) => unawaited(_confirm(repo, branch)) : null,
    );
  }
}
