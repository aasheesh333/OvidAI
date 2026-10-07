import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../core/theme.dart';
import '../core/state.dart';
import '../core/github_service.dart';
import '../core/global_repo_registry.dart';
import '../core/agent_service.dart';
import '../core/repo_cache.dart';
import '../core/sandbox_service.dart';
import 'github_login_sheet.dart';
// Note: sandbox_setup.dart imports this file (for StudioScreen) — the
// reverse import here is intentional so the not-installed banner routes
// through the canonical openStudio() entry point. Dart resolves the
// cycle; both files only reference each other's classes inside methods.
import 'sandbox_setup.dart';
import 'studio_editor.dart';
import 'studio_errors.dart';
import 'studio_file_tree.dart';
import 'studio_layout.dart';
import 'studio_terminal_tabs.dart';
import 'widgets/aether_primitives.dart';

// Studio's panes live in their own libraries; re-exported so callers (and the
// existing widget tests) keep reaching them through this one import.
export 'studio_editor.dart' show StudioEditor, StudioEditorTabs;
export 'studio_file_tree.dart' show StudioFileTree;
export 'studio_terminal_tabs.dart'
    show StudioTerminalTabs, studioPtySpawnerOverrideForTest;

/// Test seam: overrides the device directory picker for the Studio
/// working-folder affordance so host widget tests can drive "change folder"
/// without a platform channel. Production is null (real FilePicker).
@visibleForTesting
String? studioFolderPickOverrideForTest;

/// Test seam: overrides the GitHub login prompt so host widget tests can
/// assert the Studio auth gate without starting a real device flow.
/// Production is null (the real modal bottom sheet).
@visibleForTesting
void Function(BuildContext context)? studioLoginPromptOverrideForTest;

/// Test seam: overrides the branch list for the Studio branch picker so host
/// widget tests can drive "change branch" without a real GitHub request.
/// Production is null (the real [GitHubService.listBranches]).
@visibleForTesting
Future<List<String>> Function(String owner, String repo)?
studioListBranchesOverrideForTest;

/// Test seam: overrides the repo re-sync so host widget tests can exercise
/// the binding flow without network. Production is null (RepoCache.sync).
@visibleForTesting
Future<void> Function()? studioRepoSyncOverrideForTest;

@visibleForTesting
GlobalRepoRegistry? studioRegistryOverrideForTest;

/// Test seam: same as [studioRepoSyncOverrideForTest] but receives the
/// progress sink, so a test can assert that Studio surfaces [RepoCache.sync]'s
/// `onLine` callback instead of dropping it. The plain override wins when both
/// are set, which keeps every existing test working untouched.
@visibleForTesting
Future<void> Function(void Function(String line) onLine)?
studioRepoSyncProgressOverrideForTest;

/// Branch to bind when a repo is picked: the repo's `default_branch`, else
/// `main`. Prevents carrying the previous repo's branch onto the new repo.
@visibleForTesting
String branchForPickedRepo(Map<String, dynamic>? repo) {
  final branch = (repo?['default_branch'] as String?)?.trim();
  return (branch == null || branch.isEmpty) ? 'main' : branch;
}

/// Placeholder for a repository payload that carries no usable name.
const String studioUnnamedRepoLabel = '(unnamed repository)';

/// The `owner/repo` identity of a GitHub repo payload, or null when the
/// payload has none.
///
/// The picker used to render `full_name` with a `name` fallback — which shows
/// the literal string "null" for a nameless repo — and then its `onTap` cast
/// `full_name` to a non-null String anyway, contradicting its own guard and
/// crashing on tap (2026-09-30 audit). One function now decides, and a null
/// result means "listed, not pickable".
String? repoFullNameOf(Map<String, dynamic> repo) {
  final full = repo['full_name'];
  if (full is String && full.trim().isNotEmpty) return full.trim();
  final owner = repo['owner'];
  final name = repo['name'];
  if (owner is Map &&
      owner['login'] is String &&
      name is String &&
      name.trim().isNotEmpty) {
    return '${owner['login']}/${name.trim()}';
  }
  if (name is String && name.trim().isNotEmpty) return name.trim();
  return null;
}

/// Studio — coding harness (DeepSeek-web style): file explorer bound to the
/// user's connected GitHub repo, real editable editor with per-session
/// buffers, agent-visible tabs, and a live Ubuntu sandbox terminal.
///
/// The user never sees OS or infra details. Connection state is a labelled,
/// differently-shaped badge in the app bar (signed in / checking / signed
/// out); repo plumbing failures are translated by [StudioFailure] into one
/// human sentence, with the raw text demoted to a secondary line.
///
/// The layout is breakpoint-driven ([StudioMetrics]): below 840dp the file
/// tree stops being docked, below 600dp it becomes an overlay and the app bar
/// folds secondary actions into a menu, and on a short viewport the terminal
/// collapses rather than squeezing the editor below a usable height.
class StudioScreen extends StatefulWidget {
  /// Set when Studio is opened by the Studio first-open install flow
  /// (openStudio → SandboxSetupScreen(studioFirstOpen: true) → here).
  /// [_handleInitialAuth] then fires the one-time GitHub login prompt from
  /// its own branch instead of the regular path, so the sheet can never
  /// pop twice.
  final bool postInstallGithubPrompt;
  const StudioScreen({super.key, this.postInstallGithubPrompt = false});
  @override
  State<StudioScreen> createState() => _StudioScreenState();
}

class _StudioScreenState extends State<StudioScreen> {
  /// User's explicit choice for the tree. Null means "use the breakpoint
  /// default", so rotating a phone to tablet width re-docks the tree instead
  /// of fighting the user's last decision on the old geometry.
  bool? _showFilesOverride;
  bool _syncing = false;
  bool _resyncRequested = false;
  bool _committing = false;
  bool _handledInitialAuth = false;

  /// Human message for a failed sync; [_syncErrorDetail] keeps the raw text.
  String? _syncError;
  String? _syncErrorDetail;
  String? _cloneStatus;
  String? _workspaceKey;

  /// Live sync progress: a human line plus the parsed 0..1 fraction.
  String? _syncProgress;
  double? _syncFraction;

  /// User drags. Null means "use the breakpoint default"; every read goes
  /// back through [StudioMetrics.clampTreeWidth] / [clampTerminalHeight] so a
  /// stale drag value can never starve the editor after a rotation.
  double? _treeWidthOverride;
  double? _terminalHeightOverride;
  bool? _terminalCollapsedOverride;

  /// The repo bar and the app bar read `AgentService.sessionRepoFull` /
  /// `sessionBranch`, which resolve through [AppState]. Without subscribing,
  /// an external repo, branch or session change left the bar showing the
  /// previous binding until something else happened to rebuild the screen.
  late final Listenable _sessionSignals =
      Listenable.merge([AppState.I, GitHubService.I, RepoCache.I]);

  String? get _repo => AgentService.I.sessionRepoFull;
  String get _branch => AgentService.I.sessionBranch;

  @override
  void initState() {
    super.initState();
    final s = AppState.I.activeSession;
    _workspaceKey = '${s?.id}|${s?.repo}|${s?.branch}|${s?.workspaceFolder}';
    GitHubService.I.addListener(_handleInitialAuth);
    AppState.I.addListener(_onWorkspaceChanged);
    // Opening Studio is an explicit "try again now". The automatic restore
    // backoff runs out after ~2.5 minutes and nothing re-arms it, so a
    // secure-storage hiccup longer than that left this screen signed out for the
    // rest of the process. A UI-initiated retry restarts the window.
    unawaited(GitHubService.I.retryRestoreFromUi());
    WidgetsBinding.instance.addPostFrameCallback((_) => _handleInitialAuth());
    if (s?.workspaceFolder != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) { if (mounted) _autoSync(); });
    }
  }

  @override
  void dispose() {
    GitHubService.I.removeListener(_handleInitialAuth);
    AppState.I.removeListener(_onWorkspaceChanged);
    super.dispose();
  }

  void _onWorkspaceChanged() {
    final s = AppState.I.activeSession;
    final key = '${s?.id}|${s?.repo}|${s?.branch}|${s?.workspaceFolder}';
    if (_workspaceKey == key) return;
    _workspaceKey = key;
    if (_cloneStatus != null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _cloneStatus == null) _autoSync();
    });
  }

  void _handleInitialAuth() {
    final github = GitHubService.I;
    if (!mounted || _handledInitialAuth) return;
    if (widget.postInstallGithubPrompt) {
      // Opened by the Studio first-open install flow: the install screen
      // replaced itself with Studio, so the GitHub prompt fires here
      // (once) instead of the regular path below — no double popup.
      // Don't consume the one-shot while the restore is still settling;
      // the GitHubService listener re-fires after initialize() finishes.
      if (github.isInitializing) return;
      _handledInitialAuth = true;
      if (!github.isLoggedIn) {
        (studioLoginPromptOverrideForTest ?? showGithubLoginSheet)(context);
      }
      return;
    }
    if (github.isLoggedIn) {
      // The token is assigned before the profile fetch, so during a restore
      // that will 401 `isLoggedIn` is momentarily true. Only settle once
      // initialization has finished; otherwise that transient state consumes
      // the one prompt and a later signed-out settle never re-prompts.
      if (github.isInitializing) return;
      // ...and only settle once the profile has actually LOADED. A restored
      // token is assigned before its profile fetch, so a fetch that fails
      // leaves `isLoggedIn` true while `login` is still null. Latching on that
      // unconfirmed state consumes the one-shot, and if the token then turns
      // out to be dead (a confirmed 401 signs out later) the signed-out settle
      // could never re-prompt — Studio would sit showing a connected account it
      // cannot use. The profile retry (_scheduleProfileRetry) notifies once the
      // profile loads, and the latch happens then.
      if (github.login == null) return;
      _handledInitialAuth = true;
      // Re-sync when the cache is empty OR belongs to another session — the
      // singleton RepoCache would otherwise show session A's working copy to
      // session B (cross-session bleed).
      if (_repo != null &&
          (!RepoCache.I.isReady ||
              RepoCache.I.boundSessionId != AppState.I.activeSession?.id)) {
        _autoSync();
      }
      return;
    }
    if (github.isInitializing) return;
    // A FAILED storage read is not a sign-out: the token is still on disk and
    // retryRestoreIfNotLoggedIn() may recover it seconds later. Latching here
    // would show "sign in" over a session that is about to come back — and then
    // never offer it again once it does.
    if (github.restoreFailed) return;
    _handledInitialAuth = true;
    (studioLoginPromptOverrideForTest ?? showGithubLoginSheet)(context);
  }

  /// The one sync path. Production wires [RepoCache.sync]'s `onLine` progress
  /// callback, which Studio used to drop — a serial fetch of up to 400 files
  /// could run for minutes behind an 11px spinner.
  Future<void> _runSync(void Function(String) onLine) {
    final legacy = studioRepoSyncOverrideForTest;
    if (legacy != null) return legacy();
    final progress = studioRepoSyncProgressOverrideForTest;
    if (progress != null) return progress(onLine);
    return RepoCache.I.sync(onLine: onLine);
  }

  void _onSyncLine(String line) {
    if (!mounted) return;
    final counts = parseSyncCounts(line);
    setState(() {
      _syncFraction = parseSyncFraction(line);
      _syncProgress = counts == null
          ? 'Syncing…'
          : 'Syncing files · ${counts.done} / ${counts.total}';
    });
  }

  Future<void> _autoSync() async {
    final repo = _repo;
    final session = AppState.I.activeSession;
    final folder = session?.workspaceFolder;
    if (_syncing) {
      _resyncRequested = true;
      return;
    }
    if (repo == null && folder == null) return;
    setState(() {
      _syncing = true;
      _syncError = null;
      _syncErrorDetail = null;
      _syncProgress = 'Syncing…';
      _syncFraction = null;
    });
    StudioFailure? failure;
    int? binding;
    int? syncOperation;
    final workspaceKey = _workspaceKey;
    try {
      RepoCache.I.bind(
        repo ?? '',
        GitHubService.I.token ?? '',
        branch: AgentService.I.sessionBranch,
        sessionId: AppState.I.activeSession?.id,
        workspaceFolder: folder,
      );
      binding = RepoCache.I.bindingGeneration;
      final syncing = _runSync((line) {
        if (binding == RepoCache.I.bindingGeneration && workspaceKey == _workspaceKey &&
            (syncOperation == null || syncOperation == RepoCache.I.syncOperation)) {
          _onSyncLine(line);
        }
      });
      syncOperation = RepoCache.I.syncOperation;
      await syncing;
    } catch (e) {
      failure = StudioFailure.of(e);
    }
    if (!mounted) return;
    setState(() {
      _syncing = false;
      _syncProgress = null;
      _syncFraction = null;
    });
    if (failure != null && binding == RepoCache.I.bindingGeneration &&
        syncOperation == RepoCache.I.syncOperation && workspaceKey == _workspaceKey) {
      // A missing branch/ref must surface, not be swallowed — and the previous
      // repo's files must not linger under the new binding.
      RepoCache.I.clearWorkingCopy();
      setState(() {
        _syncError = failure!.message;
        _syncErrorDetail = failure.detail;
      });
      showStudioToast(context, failure.message, error: true);
    }
    if (_resyncRequested) {
      _resyncRequested = false;
      await _autoSync();
    }
  }

  /// After a repo+branch is picked, ask where this chat's working copy
  /// should live. Two REAL options — both run a real `git clone`
  /// the first time (with `-b <branch>`):
  ///   1. "Session clone" — clone once into Ovid's shared repo storage
  ///      ([GlobalRepoRegistry.ensureCloned]); a new session picking an
  ///      already-cloned repo+branch hits the registry and reuses the SAME
  ///      folder, no re-clone.
  ///   2. "Local folder clone" — the user picks a device folder; the repo
  ///      is cloned into a sanitized subfolder there.
  /// Either way the session is bound to the working copy. Skipped when the
  /// session already has a binding or a pinned folder; dismissing the
  /// dialog keeps the default session-sandbox workspace.
  Future<bool> _offerCloneTarget(ChatSession s, String repo, String branch) async {
    if (!mounted) return false;
    final sid = s.sandboxId ?? s.id;
    // Private repos need the OAuth token at clone time.
    GlobalRepoRegistry.gitTokenProvider ??= () => GitHubService.I.token;
    // SECURITY: hand the registry a secret-free auth env (a host-scoped
    // `store` helper naming a 0600 file) instead of letting it interpolate
    // the token into GIT_CONFIG_VALUE_0.
    GlobalRepoRegistry.gitCredentialEnvProvider ??=
        SandboxService.I.gitCredentialEnv;
    // Android ships no usable system git — a host `git clone` dies with
    // `ProcessException: Permission denied`. Route registry clones through
    // the sandbox's git (same one the agent's git_clone tool uses), with
    // the sandbox env (PATH, GIT_EXEC_PATH, GIT_SSL_CAINFO, HOME).
    GlobalRepoRegistry.cloneRunnerOverride ??= _sandboxGitClone;
    final reg = await GlobalRepoRegistry.instance();
    if (!mounted) return false;
    // Already working in the clone for THIS repo+branch? Then there is nothing
    // to offer.
    //
    // CLONE-ONCE (2026-09-24): this used to bail out whenever a folder existed
    // at all. A new session inherits the previous repo's clone path, so picking
    // repo B skipped the clone entirely and the session kept reading and writing
    // inside repo A's folder while the repo bar and the API view showed B.
    final existing = s.workspaceFolder;
    final bound = reg.boundWorkspaceFor(sid);
    final current =
        (existing != null && existing.isNotEmpty ? existing : null) ?? bound;
    if (current != null && GlobalRepoRegistry.checkoutMatches(current, repo, branch)) {
      await reg.bindSession(sid, repo, branch, current);
      AppState.I.setSessionWorkspaceFolder(current, sessionId: s.id);
      return true;
    }
    final choice = await showStudioSheet<String>(
      context,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          StudioSheetHeader(
            title: 'Where should "$repo" live?',
            subtitle: 'The agent runs shell commands and writes files inside '
                'this working copy for this chat.',
          ),
          StudioSheetTile(
            icon: Icons.inventory_2_outlined,
            iconColor: Aether.accent,
            title: 'Session clone',
            subtitle: 'Clone once into Ovid storage — reused by future sessions',
            onTap: () => Navigator.pop(context, 'session'),
          ),
          StudioSheetTile(
            icon: Icons.folder_open_outlined,
            title: 'Local folder clone',
            subtitle: 'Pick a device folder; the repo is cloned into a subfolder',
            onTap: () => Navigator.pop(context, 'local'),
          ),
          const SizedBox(height: 10),
        ],
      ),
    );
    if (!mounted || choice == null) return false;
    if (choice == 'session') {
      return _cloneIntoRegistry(reg, sid, repo, branch);
    } else {
      return _cloneIntoPickedFolder(reg, sid, repo, branch);
    }
  }

  /// Sandbox-backed git clone for [GlobalRepoRegistry.cloneRunnerOverride].
  ///
  /// Runs `<prefix>/bin/git` with the full sandbox env — the only working
  /// git on-device. Mirrors the token handling of the old host runner
  /// (process-scoped credential helper; no `.git-credentials` file), and
  /// fails fast with an actionable message when the sandbox or its git is
  /// missing/broken instead of the cryptic host `Permission denied`.
  static Future<void> _sandboxGitClone(
    String repoFull,
    String branch,
    String dest,
  ) async {
    final svc = SandboxService.I;
    final ready = svc.isInstalled || await svc.checkExisting();
    if (!ready) {
      throw Exception(
        'Linux sandbox not installed — open Studio once to install it, '
        'then retry the clone.',
      );
    }
    // Fail fast when the sandbox git itself is broken.
    try {
      final (vCode, vOut) = await svc
          .execChecked(['git', '--version'])
          .timeout(const Duration(seconds: 30));
      if (vCode != 0 || !vOut.contains('git version')) {
        throw Exception(
          'sandbox git is not working '
          '(${vOut.trim().split('\n').last}); reinstall it from the Health '
          'screen, then retry.',
        );
      }
    } catch (e) {
      if ('$e'.contains('sandbox git is not working')) rethrow;
      throw Exception(
        'could not run sandbox git (${e.toString().split('\n').first}); '
        'reinstall the Linux sandbox from the Health screen, then retry.',
      );
    }
    // SECURITY: secret-free auth env — git reads the token from the 0600
    // credential store named by GIT_CONFIG_VALUE_0, never from the env value.
    final env = <String, String>{
      'GIT_TERMINAL_PROMPT': '0',
      ...SandboxService.I.gitCredentialEnv(),
    };
    final parent = Directory(dest).parent;
    await parent.create(recursive: true);
    final (code, out) = await svc
        .execChecked(
          [
            'git',
            'clone',
            '-b',
            branch,
            'https://github.com/$repoFull.git',
            dest,
          ],
          hostWorkDir: parent,
          env: env,
        )
        .timeout(const Duration(minutes: 10));
    if (code != 0) {
      throw Exception(
        'git clone $repoFull@$branch failed (exit $code): ${out.trim()}',
      );
    }
  }

  /// Prepare the selected branch before publishing it to the session. Shared
  /// clones stay in the registry; local clones stay under the chosen parent.
  /// The previous checkout (and its local work) is retained on either outcome.
  Future<void> _rebindCloneToBranch(ChatSession s, String repo, String branch) async {
    final sid = s.sandboxId ?? s.id;
    final reg = studioRegistryOverrideForTest ?? await GlobalRepoRegistry.instance();
    final current = s.workspaceFolder ?? reg.boundWorkspaceFor(sid);
    if (current != null) {
      final String path;
      if (reg.isSharedWorkspace(current)) {
        path = await reg.ensureCloned(repo, branch);
      } else {
        path = '${Directory(current).parent.path}/${GlobalRepoRegistry.folderNameFor(repo, branch)}';
        await reg.cloneRepo(repo, branch, path);
      }
      await reg.bindSession(sid, repo, branch, path);
      AppState.I.setSessionWorkspaceFolder(path, sessionId: s.id);
    }
    await reg.rememberBranch(repo, branch);
  }

  Future<bool> _cloneIntoRegistry(
    GlobalRepoRegistry reg,
    String sid,
    String repo,
    String branch,
  ) async {
    setState(() => _cloneStatus = 'Cloning $repo@$branch …');
    try {
      final path = await reg.ensureCloned(repo, branch);
      await reg.bindSession(sid, repo, branch, path);
      final session = AppState.I.sessions.where((s) => (s.sandboxId ?? s.id) == sid).firstOrNull;
      if (session == null) return false;
      AppState.I.setSessionWorkspaceFolder(path, sessionId: session.id);
      _toast('Working copy: ${path.split('/').last}');
      return true;
    } catch (e) {
      _fail(e, 'Clone failed');
      return false;
    } finally {
      if (mounted) setState(() => _cloneStatus = null);
    }
  }

  /// "Local folder clone": the user picks a device folder; the repo is
  /// really cloned (with `git clone -b <branch>`) into a sanitized
  /// subfolder there, and the session workspace is bound to that subfolder.
  Future<bool> _cloneIntoPickedFolder(
    GlobalRepoRegistry reg,
    String sid,
    String repo,
    String branch,
  ) async {
    final dir = await _pickWritableFolder(
      dialogTitle: 'Pick a folder to clone $repo into',
    );
    if (!mounted || dir == null) return false;
    final dest = '$dir/${GlobalRepoRegistry.folderNameFor(repo, branch)}';
    setState(() => _cloneStatus = 'Cloning $repo@$branch …');
    try {
      await reg.cloneRepo(repo, branch, dest);
      await reg.bindSession(sid, repo, branch, dest);
      final session = AppState.I.sessions.where((s) => (s.sandboxId ?? s.id) == sid).firstOrNull;
      if (session == null) return false;
      AppState.I.setSessionWorkspaceFolder(dest, sessionId: session.id);
      _toast('Working copy: ${dest.split('/').last}');
      return true;
    } catch (e) {
      _fail(e, 'Clone failed');
      return false;
    } finally {
      if (mounted) setState(() => _cloneStatus = null);
    }
  }

  /// Studio affordance (opened from the app-bar folder button): change or
  /// clear the ACTIVE session's pinned working folder. Folder selection
  /// lives only in Studio — the composer chip just opens Studio.
  Future<void> _manageWorkspaceFolder() async {
    final s = AppState.I.activeSession;
    if (!mounted || s == null) return;
    final current = s.workspaceFolder;
    final hasFolder = current != null && current.isNotEmpty;
    final choice = await showStudioSheet<String>(
      context,
      child: SingleChildScrollView(child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          StudioSheetHeader(
            title: 'Working folder',
            subtitle: hasFolder ? current : 'Session sandbox (no pinned folder)',
          ),
          StudioSheetTile(
            icon: Icons.drive_file_move_outline,
            iconColor: Aether.accent,
            title: 'Change folder',
            onTap: () => Navigator.pop(context, 'pick'),
          ),
          StudioSheetTile(
            icon: Icons.inventory_2_outlined,
            title: 'Use session sandbox',
            onTap: () => Navigator.pop(context, 'sandbox'),
          ),
          const SizedBox(height: 10),
        ],
      )),
    );
    if (!mounted || choice == null) return;
    if (choice == 'sandbox') {
      await (await GlobalRepoRegistry.instance()).unbindSession(s.sandboxId ?? s.id);
      AppState.I.setSessionWorkspaceFolder(null, sessionId: s.id);
      _toast('Working in the session sandbox.');
      return;
    }
    await _pickAndPinFolder(dialogTitle: 'Pick working folder');
  }

  /// Picks a directory and pins it as the active session's working folder.
  Future<void> _pickAndPinFolder({required String dialogTitle}) async {
    final session = AppState.I.activeSession;
    final path = await _pickWritableFolder(dialogTitle: dialogTitle);
    if (!mounted || path == null || session == null) return;
    await (await GlobalRepoRegistry.instance()).unbindSession(session.sandboxId ?? session.id);
    AppState.I.setSessionWorkspaceFolder(path, sessionId: session.id);
    await _autoSync();
    _toast('Working folder: ${path.split('/').last}');
  }

  /// The one folder-pick path: device picker (or the test seam), existence
  /// check, writability probe, and the All-Files-Access retry with its
  /// explanatory toast. This was copy-pasted verbatim into
  /// `_cloneIntoPickedFolder` and `_pickAndPinFolder`.
  ///
  /// Returns null when the user cancelled or the folder is unusable — in the
  /// unusable case the reason has already been toasted.
  Future<String?> _pickWritableFolder({required String dialogTitle}) async {
    String? path;
    try {
      path = studioFolderPickOverrideForTest ??
          await FilePicker.platform.getDirectoryPath(dialogTitle: dialogTitle);
    } catch (e) {
      if (mounted) _fail(e, null);
      return null;
    }
    if (!mounted || path == null) return null;
    if (!Directory(path).existsSync()) {
      _toast('That folder is not accessible.');
      return null;
    }
    var writable = _probeWritable(path);
    if (!writable) {
      final granted = await AgentService.I.requestAllFilesAccess();
      if (granted) writable = _probeWritable(path);
    }
    if (!mounted) return null;
    if (!writable) {
      _toast(
        'That folder is read-only for Ovid Si — grant All Files Access or pick '
        'another folder.',
      );
      return null;
    }
    return path;
  }

  bool _probeWritable(String path) {
    try {
      final probe = File('$path/.ovid_probe');
      probe.writeAsStringSync('ok');
      probe.deleteSync();
      return true;
    } catch (_) {
      return false;
    }
  }

  void _toast(String msg) {
    if (!mounted) return;
    showStudioToast(context, msg);
  }

  /// One error path: a human headline for the user, the raw text only as a
  /// secondary line. [prefix] is prepended when the action needs naming.
  void _fail(Object error, String? prefix) {
    if (!mounted) return;
    final f = StudioFailure.of(error);
    showStudioToast(
      context,
      prefix == null ? f.message : '$prefix. ${f.message}',
      detail: f.detail,
      error: true,
    );
  }

  Future<void> _pickRepo() async {
    final session = AppState.I.activeSession;
    if (session == null) return;
    if (!GitHubService.I.isLoggedIn) {
      showGithubLoginSheet(context);
      return;
    }
    try {
      final repos = await GitHubService.I.listRepos();
      if (!mounted) return;
      final picked = await showStudioSheet<String>(
        context,
        child: StudioRepoSheet(repos: repos),
      );
      if (picked == null) return;
      final pickedRepo = repos.firstWhere(
        (r) => repoFullNameOf(r) == picked,
        orElse: () => const <String, dynamic>{},
      );
      // A new repo starts on its own default branch — never the previous
      // repo's branch, whose ref may not exist (tree fetch would 404).
      // Honour the branch the user chose for THIS repo before, instead of
      // resetting to the repository default on every re-pick.
      final reg2 = await GlobalRepoRegistry.instance();
      final branch = reg2.branchFor(picked) ?? branchForPickedRepo(pickedRepo);
      // Freshly picked repo+branch → offer a real working copy: a
      // clone-once session clone, or a clone into a picked device folder.
      // A new session picking an already-cloned repo+branch hits the
      // registry and reuses the SAME folder (no re-clone).
      if (!await _offerCloneTarget(session, picked, branch)) return;
      AppState.I.setRepoForSession(session.id, picked);
      AppState.I.setBranchForSession(session.id, branch);
      await reg2.rememberBranch(picked, branch);
      await _autoSync();
    } catch (e) {
      _fail(e, null);
    }
  }

  /// Change the branch half of the `(repo, branch)` binding, then re-sync so
  /// reads/commits target the chosen ref.
  Future<void> _pickBranch() async {
    final session = AppState.I.activeSession;
    final repo = _repo;
    if (repo == null || session == null || !GitHubService.I.isLoggedIn) return;
    final parts = repo.split('/');
    if (parts.length != 2 || parts.any((p) => p.isEmpty)) return;
    try {
      final lister =
          studioListBranchesOverrideForTest ?? GitHubService.I.listBranches;
      final branches = await lister(parts[0], parts[1]);
      if (!mounted) return;
      final current = AgentService.I.sessionBranch;
      final picked = await showStudioSheet<String>(
        context,
        child: StudioBranchSheet(branches: branches, current: current),
      );
      if (picked != null && picked != current) {
        setState(() => _cloneStatus = 'Switching to $picked …');
        await _rebindCloneToBranch(session, repo, picked);
        AppState.I.setBranchForSession(session.id, picked);
        await _autoSync();
      }
    } catch (e) {
      _fail(e, 'Branch switch failed');
    } finally {
      if (mounted) setState(() => _cloneStatus = null);
    }
  }

  void _toggleFiles() => setState(() {
        _showFilesOverride = !(_showFilesOverride ?? _treeDefaultFor(context));
      });

  bool _treeDefaultFor(BuildContext context) =>
      MediaQuery.sizeOf(context).width >= StudioMetrics.wideBreakpoint;

  void _onOverflowAction(String action) {
    switch (action) {
      case 'folder':
        _manageWorkspaceFolder();
      case 'sync':
        _autoSync();
      case 'commit':
        _commitPending();
    }
  }

  Future<void> _commitPending() async {
    if (_committing) return;
    setState(() => _committing = true);
    try {
      final count = await showDialog<int>(
        context: context,
        barrierDismissible: false,
        builder: (_) => const StudioCommitDialog(),
      );
      if (!mounted || count == null) return;
      final mode = RepoCache.I.lastCommit?.mode == CommitMode.atomic
          ? 'one atomic commit'
          : 'separate commits';
      showStudioToast(
        context,
        count == 0 ? 'No changes to commit' : 'Committed $count file(s) · $mode',
      );
    } catch (e) {
      if (mounted) showStudioToast(context, StudioFailure.of(e).message, error: true);
    } finally {
      if (mounted) setState(() => _committing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _sessionSignals,
      builder: (context, _) {
        final repo = _repo;
        final compactActions =
            MediaQuery.sizeOf(context).width < StudioMetrics.mediumBreakpoint;
        // On a compact width the tree is an overlay, so Android's back gesture
        // must dismiss it before it leaves the screen.
        final treeOverlayOpen = compactActions && (_showFilesOverride ?? false);
        return PopScope(
          canPop: !treeOverlayOpen,
          onPopInvokedWithResult: (didPop, _) {
            if (!didPop && treeOverlayOpen) {
              setState(() => _showFilesOverride = false);
            }
          },
          child: Scaffold(
          backgroundColor: Aether.bg,
          appBar: _appBar(repo, compactActions),
          body: SafeArea(
            child: StudioPaneViewport(
              // Keep the tab strip, a real editor viewport and terminal chrome
              // reachable even under a long approval or the software keyboard.
              minContentHeight: 122 + math.max(1.0,
                  MediaQuery.textScalerOf(context).scale(1.0)) *
                  (kStudioTapTarget + (_terminalCollapsedOverride == false
                      ? StudioMetrics.collapsedBarHeight + StudioMetrics.commandRowHeight
                      : StudioMetrics.collapsedBarHeight)),
              chrome: [
                // Graceful degradation: the sandbox may be missing here when
                // the user skipped the first-open install or the prefix was
                // wiped afterwards. Terminal commands already fail with a
                // friendly "open Studio" error; this banner makes the fix one
                // tap.
                AnimatedBuilder(
                  animation: AppState.I,
                  builder: (context, _) {
                    if (AppState.I.sandboxInstalled ||
                        AppState.I.sandboxSkipped) {
                      return const SizedBox.shrink();
                    }
                    return _SandboxMissingBanner(
                      onInstall: () => openStudio(context),
                    );
                  },
                ),
                _RepoBar(
                  repo: repo,
                  branch: _branch,
                  onPick: _pickRepo,
                  onPickBranch: _pickBranch,
                  syncing: _syncing,
                ),
                // The approval banner mirrors AgentService.pendingApproval for
                // the active session. Rendered as an AetherCard-warn so a
                // run-blocking approval is impossible to miss — Approve resolves
                // the gate, Decline rejects it. Both actions tick off the
                // approval contract in agent_service.dart via approve().
                _ApprovalBanner(
                  onDecision: (ok) {
                    final a = AgentService.I.pendingApproval;
                    if (a == null) return;
                    AgentService.I.approve(ok);
                    if (!ok) {
                      showStudioToast(context, 'Declined ${a.tool}');
                    }
                  },
                ),
                if (_syncError != null)
                  _SyncErrorBanner(
                    message: _syncError!,
                    detail: _syncErrorDetail,
                    onRetry: _syncing ? null : _autoSync,
                    onDismiss: () => setState(() {
                      _syncError = null;
                      _syncErrorDetail = null;
                    }),
                  ),
                if (_cloneStatus != null) _StatusBanner(_cloneStatus!),
                if (_syncing)
                  _SyncProgressBanner(
                    label: _syncProgress ?? 'Syncing…',
                    fraction: _syncFraction,
                  ),
              ],
              child: LayoutBuilder(builder: _workspace),
            ),
          ),
          ),
        );
      },
    );
  }

  PreferredSizeWidget _appBar(String? repo, bool compactActions) {
    final showFiles = _showFilesOverride ?? _treeDefaultFor(context);
    return AppBar(
      leading: const BackButton(),
      titleSpacing: 0,
      title: Semantics(
        header: true,
        child: const Text(
          'Studio',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: 17),
        ),
      ),
      actions: [
        // Working-folder control: the only place to change/clear a pinned
        // folder (the chat chip just opens Studio). Folded into the overflow
        // menu below 600dp so back + title + account never collide.
        StudioIconButton(
          icon: showFiles ? Icons.folder_open : Icons.folder_outlined,
          tooltip: 'Toggle files',
          onPressed: _toggleFiles,
        ),
        if (!compactActions)
          StudioIconButton(
            icon: Icons.drive_file_move_outline,
            tooltip: 'Working folder',
            onPressed: _manageWorkspaceFolder,
          ),
        // Sync button — pull latest repo into workspace (real).
        if (!compactActions && repo != null)
          StudioIconButton(
            icon: Icons.sync_rounded,
            tooltip: 'Sync repo',
            iconSize: 18,
            color: Aether.accent,
            onPressed: _syncing ? null : _autoSync,
          ),
        if (!compactActions && repo != null)
          StudioIconButton(
            icon: Icons.cloud_upload_outlined,
            tooltip: _committing
                ? 'Committing changes'
                : 'Commit ${RepoCache.I.dirtyCount} pending file(s)',
            iconSize: 18,
            color: Aether.warnLight,
            onPressed: _committing ? null : _commitPending,
          ),
        if (compactActions)
          PopupMenuButton<String>(
            tooltip: 'More Studio actions',
            onSelected: _onOverflowAction,
            position: PopupMenuPosition.under,
            itemBuilder: (_) => [
              const PopupMenuItem(
                value: 'folder',
                child: _OverflowRow(
                  icon: Icons.drive_file_move_outline,
                  label: 'Working folder',
                ),
              ),
               if (repo != null)
                 PopupMenuItem(
                  value: 'sync',
                  enabled: !_syncing,
                  child: _OverflowRow(
                    icon: Icons.sync_rounded,
                    label: _syncing ? 'Syncing…' : 'Sync repo',
                   ),
                 ),
               if (repo != null)
                 PopupMenuItem(
                   value: 'commit',
                   enabled: !_committing,
                   child: _OverflowRow(
                     icon: Icons.cloud_upload_outlined,
                     label: _committing
                         ? 'Committing…'
                         : 'Commit ${RepoCache.I.dirtyCount} file(s)',
                   ),
                 ),
            ],
            child: SizedBox(
              width: kStudioTapTarget,
              height: kStudioTapTarget,
              child: Center(
                child: Icon(
                  Icons.more_vert,
                  size: 20,
                  color: Aether.textMuted,
                ),
              ),
            ),
          ),
        // ── GitHub account chip + sign out ──
        _AccountChip(compact: compactActions),
        const _AuthBadge(),
        const SizedBox(width: 4),
      ],
    );
  }

  /// The tree/editor/terminal split for the height that is actually left
  /// after the app bar, repo bar and any banners.
  Widget _workspace(BuildContext context, BoxConstraints c) {
    final m = StudioMetrics.of(
      c,
      textScale: MediaQuery.textScalerOf(context).scale(1.0),
    );
    final showTree = _showFilesOverride ?? m.treeVisibleByDefault;
    final dockedWidth = m.clampTreeWidth(
      _treeWidthOverride ?? m.treeWidth,
      regionWidth: c.maxWidth - kStudioTapTarget,
    );
    // An explicit collapse wins; otherwise a viewport too short for both
    // panes collapses the terminal instead of squeezing the editor.
    final collapsed = _terminalCollapsedOverride ?? !m.terminalFits;
    // The collapsed bar is the terminal's header strip, whose height is
    // `44dp * text scale` — a flat 44dp would clip it at a large OS font size.
    final requestedTerminalHeight = collapsed
        ? StudioMetrics.collapsedBarHeight * m.textScale
        : m.resolveTerminalHeight(
            _terminalHeightOverride ?? m.terminalHeight,
            regionHeight: c.maxHeight,
          );
    // A terminal dragged to its maximum still leaves the editor's tab strip
    // and a scrollable content viewport. The outer viewport supplies this room
    // when a short screen cannot hold both panes.
    final terminalHeight = math.min(requestedTerminalHeight,
        math.max(0.0, c.maxHeight - (kStudioTapTarget * m.textScale + 122)));

    final editor = Column(
      children: const [
        StudioEditorTabs(),
        Expanded(child: StudioEditor()),
      ],
    );

    final split = Row(
      children: [
        if (showTree && m.treeDocked) ...[
          SizedBox(
            key: studioTreePaneKey,
            width: dockedWidth,
            child: const StudioFileTree(),
          ),
          StudioPaneDivider(
            key: studioTreeDividerKey,
            onDragDelta: (d) => setState(
              () => _treeWidthOverride = m.clampTreeWidth(
                dockedWidth + d,
                regionWidth: c.maxWidth - kStudioTapTarget,
              ),
            ),
            onReset: () => setState(() => _treeWidthOverride = null),
          ),
        ],
        Expanded(key: studioEditorPaneKey, child: editor),
      ],
    );

    return Column(
      children: [
        Expanded(
          child: showTree && m.treeOverlays
              ? Stack(
                  children: [
                    split,
                    Positioned.fill(
                      child: GestureDetector(
                        key: studioTreeScrimKey,
                        behavior: HitTestBehavior.opaque,
                        onTap: () => setState(() => _showFilesOverride = false),
                        child: const ColoredBox(color: Color(0x73000000)),
                      ),
                    ),
                    Positioned(
                      left: 0,
                      top: 0,
                      bottom: 0,
                      width: math.min(m.treeWidth, c.maxWidth),
                      child: Material(
                        elevation: 8,
                        color: Aether.surface,
                        child: Semantics(
                          label: 'Files panel',
                          container: true,
                          child: SizedBox(
                            key: studioTreePaneKey,
                            child: const StudioFileTree(),
                          ),
                        ),
                      ),
                    ),
                  ],
                )
              : split,
        ),
        SizedBox(
          key: studioTerminalPaneKey,
          height: terminalHeight,
          child: StudioTerminalTabs(
            collapsed: collapsed,
            onToggleCollapse: () => setState(
              () => _terminalCollapsedOverride = !collapsed,
            ),
            onResizeDrag: collapsed
                ? null
                : (d) => setState(
                      () => _terminalHeightOverride = m.resolveTerminalHeight(
                        terminalHeight - d,
                        regionHeight: c.maxHeight,
                      ),
                    ),
          ),
        ),
      ],
    );
  }
}

/// Selection and message stay editable, but each edit discards the review.
/// HTTP injection exercises the real RepoCache approval/publication contract.
class StudioCommitDialog extends StatefulWidget {
  const StudioCommitDialog({super.key, this.client});
  final http.Client? client;
  @override
  State<StudioCommitDialog> createState() => _StudioCommitDialogState();
}

class _StudioCommitDialogState extends State<StudioCommitDialog> {
  final _message = TextEditingController(text: 'Update files from Ovid Studio');
  late final List<String> _paths = RepoCache.I.pendingPaths.toList();
  late final Set<String> _selected = _paths.toSet();
  CommitApproval? _approval;
  String? _error;
  bool _busy = false;
  int _revision = 0;

  @override
  void initState() {
    super.initState();
    _message.addListener(_invalidate);
    RepoCache.I.addListener(_cacheChanged);
  }

  void _invalidate() {
    if (!mounted) return;
    setState(() { _revision++; _approval = null; });
  }

  void _cacheChanged() {
    final previousSelection = Set.of(_selected);
    final pending = RepoCache.I.pendingPaths;
    for (final path in pending) {
      if (!_paths.contains(path)) { _paths.add(path); _selected.add(path); }
    }
    _paths.removeWhere((path) => !pending.contains(path));
    _selected.removeWhere((path) => !pending.contains(path));
    if (previousSelection.length != _selected.length || !previousSelection.containsAll(_selected)) {
      _invalidate();
      return;
    }
    if (_approval == null) { _invalidate(); return; }
    try {
      RepoCache.I.validateApproval(_approval!);
    } catch (e) {
      _invalidate();
      setState(() => _error = '$e');
    }
  }

  Future<void> _review() async {
    final revision = _revision;
    setState(() { _busy = true; _error = null; _approval = null; });
    try {
      final approval = await RepoCache.I.prepareCommit(_message.text,
          paths: _selected, client: widget.client);
      if (mounted && revision == _revision) setState(() => _approval = approval);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _publish() async {
    final approval = _approval;
    if (approval == null) return;
    setState(() { _busy = true; _error = null; });
    try {
      final count = await RepoCache.I.commitApproved(approval, client: widget.client);
      if (mounted) Navigator.of(context).pop(count);
    } catch (e) {
      if (mounted) setState(() { _error = '$e'; _approval = null; });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _reconcile() async {
    setState(() { _busy = true; _error = null; });
    try {
      final count = await RepoCache.I.reconcilePending(client: widget.client);
      if (!mounted) return;
      if (count != null) {
        Navigator.of(context).pop(count);
      } else {
        setState(() => _error = 'No unresolved commit intent');
      }
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _stageMissingDeletion() async {
    var path = '';
    String? error;
    // Capture the binding: typing in this dialog must not target a new session.
    final cache = RepoCache.I;
    final binding = cache.bindingGeneration;
    await showDialog<void>(context: context, builder: (dialogContext) => StatefulBuilder(
      builder: (context, update) => AlertDialog(
        scrollable: true,
        title: const Text('Stage missing file deletion'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          const Text('Stages deletion from the repository at commit review. The checkout path must already be missing. This action does not delete any disk file.'),
          TextField(onChanged: (value) => path = value,
              decoration: const InputDecoration(labelText: 'Repository-relative path')),
          if (error != null) Text(error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.of(dialogContext).pop(), child: const Text('Cancel')),
          FilledButton(onPressed: () {
            try {
              if (binding != cache.bindingGeneration) {
                throw StateError('Repository binding changed; reopen staging');
              }
              cache.stageDeletion(path);
              Navigator.of(dialogContext).pop();
            } catch (e) { update(() => error = '$e'); }
          }, child: const Text('Stage deletion')),
        ],
      ),
    ));
  }

  @override
  void dispose() {
    RepoCache.I.removeListener(_cacheChanged);
    _message.removeListener(_invalidate);
    _message.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final approval = _approval;
    return PopScope(canPop: !_busy, child: AlertDialog(
      scrollable: true,
      title: const Text('Review commit'),
      content: SizedBox(width: 640, child: SingleChildScrollView(child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('${RepoCache.I.repoFull} · ${RepoCache.I.defaultBranch}'),
          TextField(controller: _message, enabled: !_busy,
              decoration: const InputDecoration(labelText: 'Commit message')),
          for (final path in _paths) CheckboxListTile(
            title: Text(path), value: _selected.contains(path),
            subtitle: Text(RepoCache.I.isStagedDeletion(path)
                ? 'Staged deletion · disk unchanged'
                : RepoCache.I.stagedMode(path) == null
                ? 'Content · review exact diff'
                : 'Staged Git mode ${RepoCache.I.stagedMode(path)}'),
            secondary: StudioStagingMenu(path: path, enabled: !_busy),
            onChanged: _busy ? null : (value) {
              _invalidate();
              setState(() { if (value == true) { _selected.add(path); } else { _selected.remove(path); } });
            },
          ),
          if (RepoCache.I.workspaceFolder != null)
            TextButton(onPressed: _busy ? null : _stageMissingDeletion,
                child: const Text('Stage missing file deletion')),
          const Text('Staging does not change disk files or permissions.'),
          if (approval != null) ...[
            Text('Repository: ${approval.repo}\nBranch: ${approval.branch}\nBase: ${approval.baseCommit}\nMessage: ${approval.message}\nSelected paths: ${approval.paths.join(', ')}'),
            SelectableText(approval.diff, style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
          ],
          if (_error != null) Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
          if (_busy) const LinearProgressIndicator(),
        ],
      ))),
      actions: [
        TextButton(onPressed: _busy ? null : () => Navigator.of(context).pop(), child: const Text('Cancel')),
        TextButton(onPressed: _busy ? null : _reconcile, child: const Text('Reconcile pending commit')),
        if (approval == null)
          FilledButton(onPressed: _busy || _selected.isEmpty ? null : _review, child: const Text('Review changes'))
        else
          FilledButton(onPressed: _busy ? null : _publish, child: const Text('Approve and commit')),
      ],
    ));
  }
}

class _OverflowRow extends StatelessWidget {
  const _OverflowRow({required this.icon, required this.label});
  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 17, color: Aether.textMuted),
        const SizedBox(width: 10),
        Expanded(child: Text(label, style: const TextStyle(fontSize: 13.5))),
      ],
    );
  }
}

class _SandboxMissingBanner extends StatelessWidget {
  final VoidCallback onInstall;
  const _SandboxMissingBanner({required this.onInstall});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      color: Aether.warnLight.withValues(alpha: 0.10),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Row(
        children: [
          Icon(Icons.terminal_outlined, size: 16, color: Aether.warnLight),
          const SizedBox(width: 8),
          const Expanded(
            child: Text(
              'Sandbox not installed — the terminal needs the one-time setup.',
              style: TextStyle(fontSize: 12),
            ),
          ),
          // 44dp target: the old compact TextButton measured ~26dp.
          SizedBox(
            height: kStudioTapTarget,
            child: TextButton(
              style: TextButton.styleFrom(
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.symmetric(horizontal: 12),
              ),
              onPressed: onInstall,
              child: const Text('Install', style: TextStyle(fontSize: 12.5)),
            ),
          ),
        ],
      ),
    );
  }
}

/// Repo + branch binding bar.
///
/// Takes a nullable [repo]: the old version was handed `_repo ?? 'Connect a
/// repo'` and then compared against that literal to decide styling and
/// behaviour, so a repository actually named "Connect a repo" would have
/// rendered as the disconnected state.
class _RepoBar extends StatelessWidget {
  final String? repo;
  final String? branch;
  final VoidCallback onPick;
  final VoidCallback onPickBranch;
  final bool syncing;
  const _RepoBar({
    required this.repo,
    required this.branch,
    required this.onPick,
    required this.onPickBranch,
    required this.syncing,
  });

  @override
  Widget build(BuildContext context) {
    final connected = repo != null && repo!.isNotEmpty;
    final scale = MediaQuery.textScalerOf(context).scale(1.0);
    return Semantics(
      label: connected
          ? 'Connected to $repo, branch $branch'
          : 'No repository connected',
      container: true,
      child: Container(
        key: studioRepoBarKey,
        constraints: BoxConstraints(minHeight: 48 * math.max(1.0, scale)),
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          color: Aether.surface,
          border: Border(bottom: BorderSide(color: Aether.hairline)),
        ),
        child: LayoutBuilder(
          builder: (context, c) {
            // The GITHUB tag is decoration; it is the first thing to go so the
            // repo name and the two real controls survive a narrow viewport at
            // a large OS text scale.
            final roomy = c.maxWidth >= 520;
            return Row(
              children: [
                Icon(Icons.hub_outlined, size: 16, color: Aether.textMuted),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    connected ? repo! : 'Connect a repo',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                      color: connected ? Aether.text : Aether.textFaint,
                    ),
                  ),
                ),
                if (connected && roomy) ...[
                  const SizedBox(width: 6),
                  Tag('GITHUB', color: Aether.textMuted),
                ],
                if (connected && branch != null && branch!.isNotEmpty)
                  Flexible(
                    child: _BarButton(
                      tooltip: 'Change branch',
                      icon: Icons.call_split,
                      label: branch!,
                      onTap: onPickBranch,
                    ),
                  ),
                if (syncing) ...[
                  const SizedBox(width: 6),
                  Semantics(
                    liveRegion: true,
                    label: 'Syncing',
                    child: const SizedBox(
                      width: 13,
                      height: 13,
                      child: CircularProgressIndicator(
                        strokeWidth: 1.5,
                        color: Aether.accent,
                      ),
                    ),
                  ),
                ],
                _BarButton(
                  tooltip:
                      connected ? 'Change repository' : 'Connect a repository',
                  label: connected ? 'Change' : 'Connect',
                  onTap: onPick,
                  accent: true,
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// A repo-bar text button that still meets the 44dp tap-target invariant.
class _BarButton extends StatelessWidget {
  const _BarButton({
    required this.label,
    required this.onTap,
    required this.tooltip,
    this.icon,
    this.accent = false,
  });

  final String label;
  final VoidCallback onTap;
  final String tooltip;
  final IconData? icon;
  final bool accent;

  @override
  Widget build(BuildContext context) {
    final color = accent ? Aether.accentC : Aether.textMuted;
    return Tooltip(
      message: tooltip,
      child: Semantics(
        button: true,
        label: tooltip,
        child: ConstrainedBox(
          constraints: const BoxConstraints(
            minWidth: kStudioTapTarget,
            minHeight: kStudioTapTarget,
          ),
          child: TextButton.icon(
            style: TextButton.styleFrom(
              minimumSize: const Size(kStudioTapTarget, kStudioTapTarget),
              padding: const EdgeInsets.symmetric(horizontal: 8),
              foregroundColor: color,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            onPressed: onTap,
            icon: icon == null
                ? const SizedBox.shrink()
                : Icon(icon, size: 14),
            label: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12),
            ),
          ),
        ),
      ),
    );
  }
}

/// Sync failure: a human sentence, with the raw text demoted to a secondary
/// line and a retry that is a real 44dp target.
class _SyncErrorBanner extends StatelessWidget {
  const _SyncErrorBanner({
    required this.message,
    required this.detail,
    required this.onRetry,
    required this.onDismiss,
  });

  final String message;
  final String? detail;
  final VoidCallback? onRetry;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      liveRegion: true,
      label: 'Sync failed. $message',
      container: true,
      child: Container(
        width: double.infinity,
        color: Aether.warnLight.withValues(alpha: 0.12),
        padding: const EdgeInsets.only(left: 12, right: 2, top: 2, bottom: 2),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Icon(Icons.cloud_off_outlined, size: 16, color: Aether.warnLight),
            const SizedBox(width: 8),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      message,
                      style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                        color: Aether.warnLight,
                      ),
                    ),
                    if (detail != null && detail!.isNotEmpty)
                      Text(
                        detail!,
                        style: TextStyle(
                          fontSize: kStudioMinFontSize,
                          color: Aether.textFaint,
                        ),
                      ),
                  ],
                ),
              ),
            ),
            StudioIconButton(
              icon: Icons.refresh,
              tooltip: 'Retry sync',
              iconSize: 18,
              onPressed: onRetry,
            ),
            StudioIconButton(
              icon: Icons.close,
              tooltip: 'Dismiss',
              iconSize: 16,
              onPressed: onDismiss,
            ),
          ],
        ),
      ),
    );
  }
}

/// Live sync progress. Replaces "an 11px spinner for several minutes".
class _SyncProgressBanner extends StatelessWidget {
  const _SyncProgressBanner({required this.label, required this.fraction});

  final String label;
  final double? fraction;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      liveRegion: true,
      label: label,
      container: true,
      child: Container(
        width: double.infinity,
        color: Aether.accent.withValues(alpha: 0.10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 7, 12, 7),
              child: Row(
                children: [
                  const SizedBox(
                    width: 13,
                    height: 13,
                    child: CircularProgressIndicator(
                      strokeWidth: 1.5,
                      color: Aether.accent,
                    ),
                  ),
                  const SizedBox(width: 9),
                  Expanded(
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 12, color: Aether.text),
                    ),
                  ),
                  if (fraction != null)
                    Text(
                      '${(fraction! * 100).round()}%',
                      style: TextStyle(
                        fontSize: 12,
                        fontFamily: Aether.mono,
                        fontFamilyFallback: kStudioMonoFallback,
                        color: Aether.textMuted,
                      ),
                    ),
                ],
              ),
            ),
            LinearProgressIndicator(
              value: fraction,
              minHeight: 2,
              backgroundColor: Colors.transparent,
              color: Aether.accent,
            ),
          ],
        ),
      ),
    );
  }
}

class _StatusBanner extends StatelessWidget {
  const _StatusBanner(this.label);
  final String label;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      liveRegion: true,
      label: label,
      container: true,
      child: Container(
        width: double.infinity,
        color: Aether.accent.withValues(alpha: 0.12),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        child: Row(
          children: [
            const SizedBox(
              width: 13,
              height: 13,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: 9),
            Expanded(
              child: Text(
                label,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12, color: Aether.text),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// GitHub connection state.
///
/// This used to be a bare 9×9px colour-only dot: green/amber/red with no
/// shape, no text and no semantics, so it was invisible to a screen reader
/// and unreadable for anyone with a colour vision deficiency. Each state now
/// has its own silhouette, a semantics label and a tooltip.
class _AuthBadge extends StatelessWidget {
  const _AuthBadge();

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: GitHubService.I,
      builder: (context, _) {
        final gh = GitHubService.I;
        final loggedIn = gh.isLoggedIn;
        // A storage read that FAILED, or a restore still in flight, is
        // not a sign-out — the token is on disk and a retry may recover
        // it seconds later. Showing red here told the user they had been
        // logged out when the app merely could not read the key yet,
        // which is exactly the "Studio keeps logging me out" report.
        final unknown =
            !loggedIn && (gh.restoreFailed || gh.isInitializing);

        final IconData icon;
        final Color color;
        final String label;
        if (loggedIn) {
          icon = Icons.check_circle;
          color = Aether.successLight;
          label = 'Signed in to GitHub';
        } else if (unknown) {
          icon = Icons.hourglass_top;
          color = Aether.warnLight;
          label = 'Checking your GitHub sign-in…';
        } else {
          icon = Icons.cancel;
          color = Aether.dangerC;
          label = 'Not signed in to GitHub';
        }

        return Semantics(
          liveRegion: true,
          label: label,
          child: Tooltip(
            message: label,
            child: SizedBox(
              width: 30,
              height: kStudioTapTarget,
              child: Center(child: Icon(icon, size: 16, color: color)),
            ),
          ),
        );
      },
    );
  }
}

/// The repository picker sheet. Public so the null-tolerance of the payload
/// can be tested without a network round-trip.
class StudioRepoSheet extends StatelessWidget {
  const StudioRepoSheet({required this.repos, super.key});

  final List<Map<String, dynamic>> repos;

  @override
  Widget build(BuildContext context) {
    return ListView(
      shrinkWrap: true,
      padding: const EdgeInsets.symmetric(vertical: 8),
      children: [
        const StudioSheetHeader(title: 'Your repositories'),
        for (final r in repos) _RepoTile(repo: r),
        const SizedBox(height: 10),
      ],
    );
  }
}

class _RepoTile extends StatelessWidget {
  const _RepoTile({required this.repo});
  final Map<String, dynamic> repo;

  @override
  Widget build(BuildContext context) {
    final full = repoFullNameOf(repo);
    return StudioSheetTile(
      icon: Icons.bookmark_border,
      // A payload with no usable name is listed but not pickable — it used to
      // render as the literal string "null" and crash on tap.
      title: full ?? studioUnnamedRepoLabel,
      subtitle:
          '${repo['language'] ?? '—'} · ⭐ ${repo['stargazers_count'] ?? 0}',
      onTap: full == null ? null : () => Navigator.pop(context, full),
    );
  }
}

/// The branch picker sheet.
class StudioBranchSheet extends StatelessWidget {
  const StudioBranchSheet({
    required this.branches,
    required this.current,
    super.key,
  });

  final List<String> branches;
  final String current;

  @override
  Widget build(BuildContext context) {
    return ListView(
      shrinkWrap: true,
      padding: const EdgeInsets.symmetric(vertical: 8),
      children: [
        const StudioSheetHeader(title: 'Branches'),
        for (final b in branches)
          StudioSheetTile(
            icon: b == current ? Icons.radio_button_checked : Icons.call_split,
            iconColor: b == current ? Aether.accent : Aether.textMuted,
            title: b,
            selected: b == current,
            onTap: () => Navigator.pop(context, b),
          ),
        const SizedBox(height: 10),
      ],
    );
  }
}

/// ── GitHub account chip with avatar, login name, and sign-out menu ──
class _AccountChip extends StatelessWidget {
  const _AccountChip({required this.compact});

  /// Below 600dp the chip drops its login text and chevron: the app bar has
  /// back + title + tree toggle + overflow + auth badge to fit as well.
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: GitHubService.I,
      builder: (_, _) {
        final gh = GitHubService.I;
        if (!gh.isLoggedIn) {
          return const SizedBox.shrink();
        }
        return PopupMenuButton<String>(
          tooltip: 'GitHub account',
          padding: EdgeInsets.zero,
          position: PopupMenuPosition.under,
          onSelected: (v) {
            if (v == 'signout') {
              _confirmSignOut(context, gh);
            }
          },
          itemBuilder: (_) => [
            PopupMenuItem(
              enabled: false,
              child: Row(
                children: [
                  _Avatar(url: gh.avatarUrl, size: 24),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          gh.name ?? gh.login ?? '',
                          style: const TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        Text(
                          '@${gh.login ?? ''}',
                          style: TextStyle(
                            fontSize: kStudioMinFontSize,
                            color: Aether.textFaint,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const PopupMenuDivider(height: 6),
            const PopupMenuItem(
              value: 'signout',
              child: Row(
                children: [
                  Icon(Icons.logout, size: 16, color: Aether.danger),
                  SizedBox(width: 8),
                  Text(
                    'Sign out',
                    style: TextStyle(fontSize: 12.5, color: Aether.danger),
                  ),
                ],
              ),
            ),
          ],
          child: Semantics(
            button: true,
            label: 'GitHub account ${gh.login ?? ''}',
            child: ConstrainedBox(
              constraints: const BoxConstraints(
                minWidth: kStudioTapTarget,
                minHeight: kStudioTapTarget,
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _Avatar(url: gh.avatarUrl, size: 20),
                    if (!compact) ...[
                      const SizedBox(width: 6),
                      Flexible(
                        child: Text(
                          gh.login ?? '',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 12,
                            color: Aether.textMuted,
                          ),
                        ),
                      ),
                      Icon(
                        Icons.expand_more,
                        size: 15,
                        color: Aether.textFaint,
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  void _confirmSignOut(BuildContext context, GitHubService gh) {
    showDialog(
      context: context,
      builder: (d) => AlertDialog(
        title: const Text(
          'Sign out of GitHub?',
          style: TextStyle(fontSize: 15),
        ),
        content: const Text(
          'The repo connection will be cleared. Your GitHub access token is '
          'removed from this device only.',
          style: TextStyle(fontSize: 12.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(d),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () async {
              Navigator.pop(d);
              try {
                await gh.signOut();
              } catch (e) {
                if (!context.mounted) return;
                showStudioToast(
                  context,
                  'Signed out, but the saved token could not be removed.',
                  detail: StudioFailure.of(e).detail,
                  error: true,
                );
              }
            },
            child: const Text(
              'Sign out',
              style: TextStyle(color: Aether.danger),
            ),
          ),
        ],
      ),
    );
  }
}

class _Avatar extends StatelessWidget {
  final String? url;
  final double size;
  const _Avatar({required this.url, required this.size});

  @override
  Widget build(BuildContext context) {
    if (url == null || url!.isEmpty) {
      return Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: Aether.surfaceRaised,
          shape: BoxShape.circle,
        ),
        child: Icon(
          Icons.person_outline,
          size: size * 0.55,
          color: Aether.textMuted,
        ),
      );
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(size / 2),
      child: Image.network(
        url!,
        width: size,
        height: size,
        fit: BoxFit.cover,
        // Avatars are drawn at `size` logical px; decoding the full upload is
        // pure waste (MEMORY, 2026-09-24).
        cacheWidth: Aether.imageCacheWidth(context, logicalWidth: size),
        errorBuilder: (_, _, _) => Container(
          width: size,
          height: size,
          color: Aether.surfaceRaised,
          child: Icon(
            Icons.person_outline,
            size: size * 0.55,
            color: Aether.textMuted,
          ),
        ),
      ),
    );
  }
}

/// Approval banner shown above the Studio workspace whenever the active
/// session has a pending agent approval. Rendered as an [AetherCard] warn
/// surface so a run-blocking gate stands out from informational banners
/// (status/sync/clone progress). Approve resolves the pending gate via
/// [AgentService.approve]; Decline rejects it. Questions and plan reviews
/// are the agent's own structured sheets — this banner only surfaces plain
/// tool approvals (summary + detail) so the Studio surface stays uncluttered.
class _ApprovalBanner extends StatelessWidget {
  const _ApprovalBanner({required this.onDecision});

  final void Function(bool ok) onDecision;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: AgentService.I,
      builder: (context, _) {
        final a = AgentService.I.pendingApproval;
        // Structured questions and plan reviews have their own dedicated UI
        // (ask_user_question sheet, plan review card). The Studio banner is
        // only for plain tool-approval prompts.
        if (a == null || a.questions != null || a.planBody != null) {
          return const SizedBox.shrink();
        }
        return Semantics(
          liveRegion: true,
          label: 'Approval required for ${a.tool}. ${a.summary}',
          container: true,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 2),
            child: AetherCard(
              color: Aether.warnLight.withValues(alpha: 0.08),
              padding: const EdgeInsets.all(14),
              title: Wrap(
                spacing: 8,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Icon(Icons.verified_user_outlined,
                      size: 16, color: Aether.warnLight),
                  const Text('Approval required'),
                  Text(
                    a.tool.toUpperCase(),
                    style: AetherType.label.copyWith(color: Aether.warnLight),
                  ),
                ],
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    a.summary.isEmpty
                        ? 'The agent is waiting for your decision.'
                        : a.summary,
                    style: AetherType.body,
                  ),
                  if (a.detail.trim().isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: Aether.surfaceAlt,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: Aether.hairline),
                      ),
                      child: Text(
                        a.detail,
                        style: TextStyle(
                          fontFamily: Aether.mono,
                          fontFamilyFallback: kStudioMonoFallback,
                          fontSize: 12,
                          color: Aether.textMuted,
                        ),
                      ),
                    ),
                  ],
                  const SizedBox(height: 12),
                  Wrap(
                    alignment: WrapAlignment.end,
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      SizedBox(
                        width: 140 * math.max(1.0,
                            MediaQuery.textScalerOf(context).scale(1.0)),
                        child: AetherGhostButton(
                        label: 'Decline',
                        icon: Icons.block,
                        onPressed: () => onDecision(false),
                        ),
                      ),
                      SizedBox(
                        width: 140 * math.max(1.0,
                            MediaQuery.textScalerOf(context).scale(1.0)),
                        child: AetherPrimaryButton(
                        label: 'Approve',
                        icon: Icons.check,
                        onPressed: () => onDecision(true),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
