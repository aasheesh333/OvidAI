import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import '../core/theme.dart';
import '../core/state.dart';
import '../core/github_service.dart';
import '../core/agent_service.dart';
import '../core/repo_cache.dart';
import '../core/studio_terminal.dart';
import '../core/sandbox_service.dart';
import 'github_login_sheet.dart';

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

/// Test seam: replaces the sandbox spawner for the Studio terminal so host
/// widget tests can drive a real host shell without a native sandbox.
/// Production is null (commands run through [SandboxService.spawn]).
@visibleForTesting
Future<Process> Function()? studioPtySpawnerOverrideForTest;

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

/// Branch to bind when a repo is picked: the repo's `default_branch`, else
/// `main`. Prevents carrying the previous repo's branch onto the new repo.
@visibleForTesting
String branchForPickedRepo(Map<String, dynamic>? repo) {
  final branch = (repo?['default_branch'] as String?)?.trim();
  return (branch == null || branch.isEmpty) ? 'main' : branch;
}

/// Studio — coding harness (DeepSeek-web style): file explorer bound to the
/// user's connected GitHub repo, real editable editor with per-session
/// buffers, agent-visible tabs, and a live Ubuntu sandbox terminal. The
/// user never sees OS/infra details — only "Sandbox ● ready".
class StudioScreen extends StatefulWidget {
  const StudioScreen({super.key});
  @override
  State<StudioScreen> createState() => _StudioScreenState();
}

class _StudioScreenState extends State<StudioScreen> {
  bool _showFiles = true;
  bool _syncing = false;
  bool _handledInitialAuth = false;
  String? _syncError;

  String? get _repo => AgentService.I.sessionRepoFull;

  @override
  void initState() {
    super.initState();
    GitHubService.I.addListener(_handleInitialAuth);
    WidgetsBinding.instance.addPostFrameCallback((_) => _handleInitialAuth());
  }

  @override
  void dispose() {
    GitHubService.I.removeListener(_handleInitialAuth);
    super.dispose();
  }

  void _handleInitialAuth() {
    final github = GitHubService.I;
    if (!mounted || _handledInitialAuth) return;
    if (github.isLoggedIn) {
      // The token is assigned before the profile fetch, so during a restore
      // that will 401 `isLoggedIn` is momentarily true. Only settle once
      // initialization has finished; otherwise that transient state consumes
      // the one prompt and a later signed-out settle never re-prompts.
      if (github.isInitializing) return;
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
    _handledInitialAuth = true;
    (studioLoginPromptOverrideForTest ?? showGithubLoginSheet)(context);
  }

  Future<void> _autoSync() async {
    if (_repo == null || _syncing) return;
    setState(() {
      _syncing = true;
      _syncError = null;
    });
    String? error;
    try {
      RepoCache.I.bind(
        _repo!,
        GitHubService.I.token!,
        branch: AgentService.I.sessionBranch,
        sessionId: AppState.I.activeSession?.id,
      );
      final sync = studioRepoSyncOverrideForTest ?? (() => RepoCache.I.sync());
      await sync();
    } catch (e) {
      error = '$e';
    }
    if (!mounted) return;
    if (error != null) {
      // A missing branch/ref must surface, not be swallowed — and the previous
      // repo's files must not linger under the new binding.
      RepoCache.I.clearWorkingCopy();
      setState(() => _syncError = error);
      _toast('Repo sync failed: $error');
    }
    setState(() => _syncing = false);
  }

  /// After a repo is bound + synced, offer to pin a working folder for this
  /// chat so edits land in a real project directory instead of only the
  /// in-memory repo cache. Skipped when the session already has one.
  Future<void> _offerWorkspaceFolder(String repo) async {
    final s = AppState.I.activeSession;
    if (!mounted || s == null) return;
    final existing = s.workspaceFolder;
    if (existing != null && existing.isNotEmpty) return;
    final sandbox = await SandboxService.I.workDirFor(s.sandboxId ?? s.id);
    if (!mounted) return;
    final choice = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Aether.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (sheetCtx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SizedBox(height: 14),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 18),
              child: Text(
                'Where should "$repo" live?',
                style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            const SizedBox(height: 4),
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 0, 18, 8),
              child: Text(
                'The agent runs shell commands and writes files inside this '
                'folder for this chat.',
                style: TextStyle(fontSize: 12, color: Aether.textMuted),
              ),
            ),
            ListTile(
              dense: true,
              leading: Icon(
                Icons.inventory_2_outlined,
                size: 19,
                color: Aether.accent,
              ),
              title: const Text(
                'Session sandbox (recommended)',
                style: TextStyle(fontSize: 13.5),
              ),
              subtitle: Text(
                sandbox.path,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 11, color: Aether.textFaint),
              ),
              onTap: () => Navigator.pop(sheetCtx, 'sandbox'),
            ),
            ListTile(
              dense: true,
              leading: Icon(
                Icons.folder_open_outlined,
                size: 19,
                color: Aether.textMuted,
              ),
              title: const Text(
                'Pick a folder on this device',
                style: TextStyle(fontSize: 13.5),
              ),
              subtitle: Text(
                'Clone/edit inside a folder you choose',
                style: TextStyle(fontSize: 11, color: Aether.textFaint),
              ),
              onTap: () => Navigator.pop(sheetCtx, 'pick'),
            ),
            const SizedBox(height: 10),
          ],
        ),
      ),
    );
    if (!mounted || choice == null) return;
    if (choice == 'sandbox') {
      AppState.I.setSessionWorkspaceFolder(null);
      _toast('Working in the session sandbox.');
      return;
    }
    await _pickAndPinFolder(dialogTitle: 'Pick working folder for $repo');
  }

  /// Studio affordance (opened from the app-bar folder button): change or
  /// clear the ACTIVE session's pinned working folder. Folder selection
  /// lives only in Studio — the composer chip just opens Studio.
  Future<void> _manageWorkspaceFolder() async {
    final s = AppState.I.activeSession;
    if (!mounted || s == null) return;
    final current = s.workspaceFolder;
    final hasFolder = current != null && current.isNotEmpty;
    final choice = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Aether.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (sheetCtx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SizedBox(height: 14),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 18),
              child: Text(
                'Working folder',
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
              ),
            ),
            const SizedBox(height: 4),
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 0, 18, 8),
              child: Text(
                hasFolder ? current : 'Session sandbox (no pinned folder)',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 11.5, color: Aether.textFaint),
              ),
            ),
            ListTile(
              dense: true,
              leading: Icon(
                Icons.drive_file_move_outline,
                size: 19,
                color: Aether.accent,
              ),
              title: const Text(
                'Change folder',
                style: TextStyle(fontSize: 13.5),
              ),
              onTap: () => Navigator.pop(sheetCtx, 'pick'),
            ),
            ListTile(
              dense: true,
              leading: Icon(
                Icons.inventory_2_outlined,
                size: 19,
                color: Aether.textMuted,
              ),
              title: const Text(
                'Use session sandbox',
                style: TextStyle(fontSize: 13.5),
              ),
              onTap: () => Navigator.pop(sheetCtx, 'sandbox'),
            ),
            const SizedBox(height: 10),
          ],
        ),
      ),
    );
    if (!mounted || choice == null) return;
    if (choice == 'sandbox') {
      AppState.I.setSessionWorkspaceFolder(null);
      _toast('Working in the session sandbox.');
      return;
    }
    await _pickAndPinFolder(dialogTitle: 'Pick working folder');
  }

  /// Picks a directory (device picker, or the test override) and pins it as
  /// the active session's working folder after a writability probe.
  Future<void> _pickAndPinFolder({required String dialogTitle}) async {
    String? path;
    try {
      path = studioFolderPickOverrideForTest ??
          await FilePicker.platform.getDirectoryPath(dialogTitle: dialogTitle);
    } catch (_) {
      path = null;
    }
    if (!mounted || path == null) return;
    final dir = Directory(path);
    if (!dir.existsSync()) {
      _toast('That folder is not accessible.');
      return;
    }
    var writable = _probeWritable(path);
    if (!writable) {
      final granted = await AgentService.I.requestAllFilesAccess();
      if (granted) writable = _probeWritable(path);
    }
    if (!mounted) return;
    if (!writable) {
      _toast(
        'That folder is read-only for Ovid — grant All Files Access or pick '
        'another folder.',
      );
      return;
    }
    AppState.I.setSessionWorkspaceFolder(path);
    _toast('Working folder: ${path.split('/').last}');
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
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), behavior: SnackBarBehavior.floating),
    );
  }

  Future<void> _pickRepo() async {
    if (!GitHubService.I.isLoggedIn) {
      showGithubLoginSheet(context);
      return;
    }
    try {
      final repos = await GitHubService.I.listRepos();
      if (!mounted) return;
      final picked = await showModalBottomSheet<String>(
        context: context,
        backgroundColor: Aether.surface,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
        builder: (_) => SafeArea(
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.symmetric(vertical: 8),
            children: [
              const Padding(
                padding: EdgeInsets.all(14),
                child: Text(
                  'Your repositories',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
                ),
              ),
              for (final r in repos)
                ListTile(
                  dense: true,
                  leading: Icon(
                    Icons.bookmark_border,
                    size: 18,
                    color: Aether.textMuted,
                  ),
                  title: Text(
                    r['full_name'] ?? '${r['name']}',
                    style: const TextStyle(fontSize: 13.5),
                  ),
                  subtitle: Text(
                    '${r['language'] ?? '—'} · ⭐ ${r['stargazers_count'] ?? 0}',
                    style: TextStyle(fontSize: 11, color: Aether.textFaint),
                  ),
                  onTap: () => Navigator.pop(context, r['full_name'] as String),
                ),
            ],
          ),
        ),
      );
      if (picked != null) {
        final pickedRepo = repos.firstWhere(
          (r) => r['full_name'] == picked,
          orElse: () => const <String, dynamic>{},
        );
        AgentService.I.sessionRepoFull = picked;
        // A new repo starts on its own default branch — never the previous
        // repo's branch, whose ref may not exist (tree fetch would 404).
        AgentService.I.sessionBranch = branchForPickedRepo(pickedRepo);
        await _autoSync();
        // Freshly bound repo → ask where the work should happen (the studio workspace prompt asks
        // for a workspace directory before it starts editing).
        await _offerWorkspaceFolder(picked);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Repo list failed: $e')));
      }
    }
  }

  /// Change the branch half of the `(repo, branch)` binding, then re-sync so
  /// reads/commits target the chosen ref.
  Future<void> _pickBranch() async {
    final repo = _repo;
    if (repo == null || !GitHubService.I.isLoggedIn) return;
    final parts = repo.split('/');
    if (parts.length != 2 || parts.any((p) => p.isEmpty)) return;
    try {
      final lister =
          studioListBranchesOverrideForTest ?? GitHubService.I.listBranches;
      final branches = await lister(parts[0], parts[1]);
      if (!mounted) return;
      final current = AgentService.I.sessionBranch;
      final picked = await showModalBottomSheet<String>(
        context: context,
        backgroundColor: Aether.surface,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
        builder: (_) => SafeArea(
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.symmetric(vertical: 8),
            children: [
              const Padding(
                padding: EdgeInsets.all(14),
                child: Text(
                  'Branches',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
                ),
              ),
              for (final b in branches)
                ListTile(
                  dense: true,
                  leading: Icon(
                    b == current
                        ? Icons.radio_button_checked
                        : Icons.call_split,
                    size: 18,
                    color: b == current ? Aether.accent : Aether.textMuted,
                  ),
                  title: Text(b, style: const TextStyle(fontSize: 13.5)),
                  onTap: () => Navigator.pop(context, b),
                ),
            ],
          ),
        ),
      );
      if (picked != null && picked != current) {
        AgentService.I.sessionBranch = picked;
        await _autoSync();
      }
    } catch (e) {
      _toast('Branch list failed: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Aether.bg,
      appBar: AppBar(
        leading: const BackButton(),
        title: const Text('Studio'),
        actions: [
          // Working-folder control: the only place to change/clear a pinned
          // folder (the chat chip just opens Studio).
          IconButton(
            tooltip: 'Working folder',
            visualDensity: VisualDensity.compact,
            icon: Icon(
              Icons.drive_file_move_outline,
              size: 19,
              color: Aether.textMuted,
            ),
            onPressed: _manageWorkspaceFolder,
          ),
          IconButton(
            tooltip: 'Toggle files',
            visualDensity: VisualDensity.compact,
            icon: Icon(
              _showFiles ? Icons.folder_open : Icons.folder_outlined,
              size: 19,
              color: Aether.textMuted,
            ),
            onPressed: () => setState(() => _showFiles = !_showFiles),
          ),
          // Sync button — pull latest repo into workspace (real).
          if (_repo != null)
            IconButton(
              tooltip: 'Sync repo',
              visualDensity: VisualDensity.compact,
              icon: _syncing
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 1.5,
                        color: Aether.accent,
                      ),
                    )
                  : Icon(Icons.sync_rounded, size: 18, color: Aether.textMuted),
              onPressed: _syncing ? null : _autoSync,
            ),
          // ── GitHub account chip + sign out ──
          const _AccountChip(),
          Padding(
            padding: const EdgeInsets.only(right: 14, left: 4),
            child: AnimatedBuilder(
              animation: AppState.I,
              builder: (context, _) => Row(
                children: [
                  Container(
                    width: 7,
                    height: 7,
                    decoration: BoxDecoration(
                      color: AppState.I.sandboxInstalled
                          ? Aether.success
                          : Aether.warn,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    AppState.I.sandboxInstalled
                        ? 'Sandbox ready'
                        : 'Sandbox pending',
                    style: TextStyle(fontSize: 11.5, color: Aether.textMuted),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            _RepoBar(
              repo: _repo ?? 'Connect a repo',
              branch: AgentService.I.sessionBranch,
              onPick: _pickRepo,
              onPickBranch: _pickBranch,
              syncing: _syncing,
            ),
            if (_syncError != null)
              Container(
                width: double.infinity,
                color: Aether.warn.withValues(alpha: 0.12),
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 6,
                ),
                child: Text(
                  'Sync failed: $_syncError',
                  style: TextStyle(fontSize: 11.5, color: Aether.warn),
                ),
              ),
            Expanded(
              child: Row(
                children: [
                  if (_showFiles) ...[
                    SizedBox(width: 210, child: _FileTree()),
                    const VerticalDivider(width: 1),
                  ],
                  const Expanded(
                    child: Column(
                      children: [
                        _Tabs(),
                        Expanded(child: _Editor()),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            SizedBox(height: 240, child: const StudioTerminalTabs()),
          ],
        ),
      ),
    );
  }
}

class _RepoBar extends StatelessWidget {
  final String repo;
  final String branch;
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
    return Container(
      height: 40,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: Aether.surface,
        border: Border(bottom: BorderSide(color: Aether.hairline)),
      ),
      child: Row(
        children: [
          Icon(Icons.hub_outlined, size: 15, color: Aether.textMuted),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              repo,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
                color: repo == 'Connect a repo'
                    ? Aether.textFaint
                    : Aether.text,
              ),
            ),
          ),
          if (repo != 'Connect a repo') Tag('GITHUB', color: Aether.textMuted),
          if (repo != 'Connect a repo') ...[
            const SizedBox(width: 8),
            TextButton.icon(
              style: TextButton.styleFrom(
                minimumSize: Size.zero,
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                foregroundColor: Aether.textMuted,
              ),
              onPressed: onPickBranch,
              icon: const Icon(Icons.call_split, size: 13),
              label: Text(
                branch,
                style: const TextStyle(fontSize: 12),
              ),
            ),
          ],
          if (syncing) ...[
            const SizedBox(width: 8),
            const SizedBox(
              width: 11,
              height: 11,
              child: CircularProgressIndicator(
                strokeWidth: 1.5,
                color: Aether.accent,
              ),
            ),
          ],
          const SizedBox(width: 8),
          TextButton(
            style: TextButton.styleFrom(
              minimumSize: Size.zero,
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              foregroundColor: Aether.accent,
            ),
            onPressed: onPick,
            child: Text(
              repo == 'Connect a repo' ? 'Connect' : 'Change',
              style: const TextStyle(fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }
}

class _FileTree extends StatelessWidget {
  const _FileTree();

  /// Fallback for a repo path whose content isn't pre-cached — fetch the
  /// real file content from GitHub via the RepoCache read API (disks-first).
  Future<void> _openUnknownFile(BuildContext context, String path) async {
    final cached = RepoCache.I.read(path);
    if (cached != null) {
      AgentService.I.openStudioFile(path, cached);
      return;
    }
    try {
      final content = await RepoCache.I.fetchFile(path);
      AgentService.I.openStudioFile(path, content ?? '');
    } catch (_) {
      AgentService.I.openStudioFile(path, '');
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([RepoCache.I, AgentService.I]),
      builder: (_, _) {
        final cache = RepoCache.I;
        final paths = cache.treePaths;
        return Container(
          color: Aether.surface,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: EdgeInsets.fromLTRB(12, 10, 12, 8),
                child: Text(
                  'FILES',
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1.4,
                    color: Aether.textFaint,
                  ),
                ),
              ),
              Expanded(
                child: paths.isEmpty
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(14),
                          child: Text(
                            'Connect a repo —\nfiles appear here live.',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontSize: 11.5,
                              height: 1.6,
                              color: Aether.textFaint,
                            ),
                          ),
                        ),
                      )
                    : ListView.builder(
                        padding: EdgeInsets.zero,
                        itemCount: paths.length,
                        itemBuilder: (_, i) {
                          final p = paths[i];
                          final depth = '/'.allMatches(p).length;
                          final isDir =
                              i + 1 < paths.length &&
                              paths[i + 1].startsWith('$p/');
                          final active = AgentService.I.activeFilePath == p;
                          return InkWell(
                            onTap: () {
                              final cached = cache.files[p];
                              if (!isDir && cached != null) {
                                AgentService.I.openStudioFile(p, cached);
                              } else if (!isDir) {
                                // File exists only as a repo tree path —
                                // pull its real content from the workspace.
                                _openUnknownFile(context, p);
                              }
                            },
                            child: Container(
                              color: active
                                  ? Aether.accentSoft
                                  : Colors.transparent,
                              padding: EdgeInsets.fromLTRB(
                                10.0 + depth * 14,
                                6,
                                8,
                                6,
                              ),
                              child: Row(
                                children: [
                                  Icon(
                                    isDir
                                        ? Icons.folder_outlined
                                        : Icons.description_outlined,
                                    size: 13,
                                    color: isDir
                                        ? Aether.textMuted
                                        : Aether.textFaint,
                                  ),
                                  const SizedBox(width: 6),
                                  Expanded(
                                    child: Text(
                                      p.split('/').last,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        fontSize: 12,
                                        fontFamily: Aether.mono,
                                        color: active
                                            ? Aether.accent
                                            : isDir
                                            ? Aether.text
                                            : Aether.textMuted,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 9,
                ),
                decoration: BoxDecoration(
                  border: Border(top: BorderSide(color: Aether.hairline)),
                ),
                child: Row(
                  children: [
                    Icon(
                      cache.isReady
                          ? Icons.cloud_done_outlined
                          : Icons.cloud_off_outlined,
                      size: 13,
                      color: cache.isReady ? Aether.success : Aether.textFaint,
                    ),
                    const SizedBox(width: 7),
                    Expanded(
                      child: Text(
                        cache.isReady
                            ? 'Synced · ${cache.files.length} files'
                            : 'Not connected',
                        style: TextStyle(fontSize: 11, color: Aether.textMuted),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _Tabs extends StatelessWidget {
  const _Tabs();

  Future<void> _askNewFile(BuildContext context) async {
    final ctrl = TextEditingController();
    final ok = await showDialog<String>(
      context: context,
      builder: (d) => AlertDialog(
        title: const Text('New file', style: TextStyle(fontSize: 15)),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          style: const TextStyle(fontFamily: Aether.mono, fontSize: 13),
          decoration: const InputDecoration(
            hintText: 'path/to/file.dart',
            isDense: true,
          ),
          onSubmitted: (v) => Navigator.pop(d, v.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(d),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(d, ctrl.text.trim()),
            child: const Text('Create'),
          ),
        ],
      ),
    );
    if (ok == null || ok.isEmpty) return;
    AgentService.I.newStudioFile(ok);
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: AgentService.I,
      builder: (_, _) {
        final tabs = AgentService.I.studioOpenFiles;
        final active = AgentService.I.activeFilePath;
        return Container(
          height: 38,
          color: Aether.surface,
          child: Row(
            children: [
              Expanded(
                child: tabs.isEmpty
                    ? Padding(
                        padding: EdgeInsets.symmetric(horizontal: 12),
                        child: Text(
                          'No open files — tap a file in the tree or +',
                          style: TextStyle(
                            fontSize: 11,
                            color: Aether.textFaint,
                          ),
                        ),
                      )
                    : ListView.builder(
                        scrollDirection: Axis.horizontal,
                        itemCount: tabs.length,
                        itemBuilder: (_, i) {
                          final p = tabs[i];
                          final sel = p == active;
                          return GestureDetector(
                            onTap: () => AgentService.I.selectStudioFile(p),
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                              ),
                              decoration: BoxDecoration(
                                border: Border(
                                  right: BorderSide(color: Aether.hairline),
                                  top: BorderSide(
                                    color: sel
                                        ? Aether.accent
                                        : Colors.transparent,
                                    width: 2,
                                  ),
                                ),
                                color: sel ? Aether.bg : Aether.surface,
                              ),
                              child: Row(
                                children: [
                                  Icon(
                                    Icons.description_outlined,
                                    size: 13,
                                    color: sel ? Aether.text : Aether.textFaint,
                                  ),
                                  const SizedBox(width: 6),
                                  Text(
                                    p.split('/').last,
                                    style: TextStyle(
                                      fontSize: 12,
                                      fontFamily: Aether.mono,
                                      color: sel
                                          ? Aether.text
                                          : Aether.textMuted,
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  GestureDetector(
                                    onTap: () =>
                                        AgentService.I.closeStudioFile(p),
                                    child: Padding(
                                      padding: EdgeInsets.all(4),
                                      child: Icon(
                                        Icons.close,
                                        size: 12,
                                        color: Aether.textFaint,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
              ),
              IconButton(
                tooltip: 'New file',
                visualDensity: VisualDensity.compact,
                icon: Icon(Icons.add, size: 16, color: Aether.textMuted),
                onPressed: () => _askNewFile(context),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _Editor extends StatefulWidget {
  const _Editor();

  @override
  State<_Editor> createState() => _EditorState();
}

class _EditorState extends State<_Editor> {
  final _ctrl = TextEditingController();
  String? _boundPath;
  bool _dirty = false;

  void _bind(String path, String content) {
    // Reposition caret: only rewrite the text when the underlying buffer
    // actually changed (agent file_write or a fresh open), not per keystroke.
    if (_boundPath == path && _ctrl.text == content) return;
    if (_boundPath != path) _dirty = false;
    _boundPath = path;
    _ctrl.value = TextEditingValue(
      text: content,
      selection: TextSelection.collapsed(offset: content.length),
    );
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: AgentService.I,
      builder: (_, _) {
        final a = AgentService.I;
        final path = a.activeFilePath;
        if (path == null) {
          return Container(
            color: Aether.bg,
            child: Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text(
                  'Ovid Studio\n\n• Pick a file from the tree, or + to create one\n'
                  '• Ask the AI in chat to read/edit files — they open here as tabs\n'
                  '• Terminal below runs inside the native Linux sandbox',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 12.5,
                    height: 1.7,
                    color: Aether.textFaint,
                  ),
                ),
              ),
            ),
          );
        }
        final content = a.fileBuffer[path] ?? RepoCache.I.read(path) ?? '';
        _bind(path, content);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Active file path header (real path, real repo name)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
              color: Aether.surfaceAlt,
              child: Row(
                children: [
                  Icon(
                    _dirty ? Icons.circle : Icons.edit_note,
                    size: 12,
                    color: _dirty ? Aether.warn : Aether.accent,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      path,
                      style: TextStyle(
                        fontFamily: Aether.mono,
                        fontSize: 10.5,
                        color: Aether.textMuted,
                      ),
                    ),
                  ),
                  if (_dirty)
                    GestureDetector(
                      onTap: _save,
                      child: Text(
                        'Save',
                        style: TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w600,
                          color: Aether.accent,
                        ),
                      ),
                    ),
                  if (a.sessionRepoFull != null) ...[
                    const SizedBox(width: 10),
                    Text(
                      a.sessionRepoFull!,
                      style: TextStyle(
                        fontFamily: Aether.mono,
                        fontSize: 10,
                        color: Aether.textFaint,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            Expanded(
              child: TextField(
                controller: _ctrl,
                maxLines: null,
                expands: true,
                keyboardType: TextInputType.multiline,
                style: TextStyle(
                  fontFamily: Aether.mono,
                  fontSize: 12.5,
                  height: 1.55,
                  color: Aether.text,
                ),
                decoration: InputDecoration(
                  contentPadding: EdgeInsets.all(12),
                  isDense: true,
                  filled: true,
                  fillColor: Aether.bg,
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                ),
                onChanged: (v) {
                  final a2 = AgentService.I;
                  a2.fileBuffer[_boundPath!] = v;
                  setState(() => _dirty = true);
                },
              ),
            ),
          ],
        );
      },
    );
  }

  void _save() {
    final p = _boundPath;
    if (p == null) return;
    RepoCache.I.write(p, _ctrl.text);
    AgentService.I.refreshNow();
    setState(() => _dirty = false);
  }
}

// ── Multi-terminal (P8) — N independent persistent shells ─────────────
// Each terminal keeps its own scrollback + busy state and its own
// persistent pipe shell (StudioShellSession), so `cd`/exports survive
// across commands. Tabs at the top with add/close icons (VS Code style).
// Shells are owner-scoped in PtyPool so agent Stop never kills them.
class StudioTerminalTabs extends StatefulWidget {
  const StudioTerminalTabs({super.key});
  @override
  State<StudioTerminalTabs> createState() => _StudioTerminalTabsState();
}

class _StudioTerminalTabsState extends State<StudioTerminalTabs> {
  final List<_TerminalSession> _terms = [];
  int _active = 0;

  @override
  void initState() {
    super.initState();
    _addTerminal();
  }

  void _addTerminal() {
    setState(() {
      _terms.add(_TerminalSession());
      _active = _terms.length - 1;
    });
  }

  void _closeTerminal(int i) {
    final t = _terms[i];
    t.dispose();
    setState(() {
      _terms.removeAt(i);
      if (_terms.isEmpty) {
        _terms.add(_TerminalSession());
        _active = 0;
      } else if (_active >= _terms.length) {
        _active = _terms.length - 1;
      }
    });
  }

  @override
  void dispose() {
    for (final t in _terms) {
      t.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // Terminal tab strip.
        Container(
          height: 30,
          color: Aether.surface,
          child: Row(
            children: [
              const SizedBox(width: 8),
              Icon(Icons.terminal, size: 12, color: Aether.textMuted),
              const SizedBox(width: 6),
              Text(
                'TERMINALS',
                style: TextStyle(
                  fontSize: 9.5,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.8,
                  color: Aether.textFaint,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: ListView.builder(
                  scrollDirection: Axis.horizontal,
                  itemCount: _terms.length,
                  itemBuilder: (_, i) {
                    final t = _terms[i];
                    final sel = i == _active;
                    return GestureDetector(
                      onTap: () => setState(() => _active = i),
                      child: AnimatedBuilder(
                        animation: t.shell,
                        builder: (_, _) {
                          final busy = t.shell.busy;
                          return Container(
                            padding: const EdgeInsets.symmetric(horizontal: 9),
                            margin: const EdgeInsets.fromLTRB(0, 4, 6, 4),
                            decoration: BoxDecoration(
                              color: sel
                                  ? Aether.surfaceAlt
                                  : Colors.transparent,
                              borderRadius: BorderRadius.circular(6),
                              border: Border.all(
                                color: sel
                                    ? Aether.hairline
                                    : Colors.transparent,
                              ),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  busy ? Icons.sync : Icons.chevron_right,
                                  size: 11,
                                  color: busy
                                      ? Aether.accent
                                      : sel
                                      ? Aether.textMuted
                                      : Aether.textFaint,
                                ),
                                const SizedBox(width: 4),
                                Text(
                                  'bash ${i + 1}',
                                  style: TextStyle(
                                    fontFamily: Aether.mono,
                                    fontSize: 10,
                                    color: sel
                                        ? Aether.text
                                        : Aether.textFaint,
                                  ),
                                ),
                                const SizedBox(width: 5),
                                GestureDetector(
                                  onTap: () => _closeTerminal(i),
                                  child: Icon(
                                    Icons.close,
                                    size: 11,
                                    color: Aether.textFaint,
                                  ),
                                ),
                              ],
                            ),
                          );
                        },
                      ),
                    );
                  },
                ),
              ),
              // New terminal button.
              IconButton(
                tooltip: 'New terminal',
                visualDensity: VisualDensity.compact,
                icon: Icon(Icons.add, size: 15, color: Aether.textMuted),
                onPressed: _addTerminal,
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: _terms.isEmpty
              ? const SizedBox.shrink()
              : _TerminalPane(term: _terms[_active]),
        ),
      ],
    );
  }
}

/// One terminal's mutable UI state. Each tab owns a stable [tabId] and the
/// persistent shell it is bound to (created lazily on first command).
class _TerminalSession {
  _TerminalSession() {
    tabId = 'tab-${_seq++}';
    shell = StudioShellSession(tabId: tabId);
  }
  static int _seq = 0;
  late final String tabId;
  late final StudioShellSession shell;
  final input = TextEditingController();
  final scroll = ScrollController();

  void dispose() {
    shell.dispose();
    input.dispose();
    scroll.dispose();
  }
}

/// The active terminal's pane (scrollback + input).
class _TerminalPane extends StatefulWidget {
  final _TerminalSession term;
  const _TerminalPane({required this.term});
  @override
  State<_TerminalPane> createState() => _TerminalPaneState();
}

class _TerminalPaneState extends State<_TerminalPane> {
  @override
  void initState() {
    super.initState();
    widget.term.shell.addListener(_onShellChanged);
  }

  @override
  void didUpdateWidget(_TerminalPane oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.term, widget.term)) {
      oldWidget.term.shell.removeListener(_onShellChanged);
      widget.term.shell.addListener(_onShellChanged);
    }
  }

  @override
  void dispose() {
    widget.term.shell.removeListener(_onShellChanged);
    super.dispose();
  }

  void _onShellChanged() => _scrollToBottom(widget.term);

  void _scrollToBottom(_TerminalSession t) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (t.scroll.hasClients) {
        t.scroll.jumpTo(t.scroll.position.maxScrollExtent);
      }
    });
  }

  Future<void> _run(String cmd) async {
    final t = widget.term;
    final shell = t.shell;
    final c = cmd.trim();
    if (c.isEmpty || shell.busy) return;
    t.input.clear();
    shell.begin(c);
    _scrollToBottom(t);

    final sessionId = AppState.I.activeSession?.sandboxId ?? 'default';
    // Persistent per-tab shell: state (`cd`, exports) survives commands and
    // output streams in as it happens. Falls back to the one-shot exec when
    // the sandbox is unavailable.
    final override = studioPtySpawnerOverrideForTest;
    try {
      final spawner =
          override ??
          () async {
            final workDir = await SandboxService.I.workDirFor(sessionId);
            return SandboxService.I.spawn(['bash'], hostWorkDir: workDir);
          };
      if (await shell.runPersistent(c, sid: sessionId, spawner: spawner)) {
        return;
      }
    } catch (_) {
      // Fall through to the one-shot exec fallback.
    }

    try {
      final workDir = await SandboxService.I.workDirFor(sessionId);
      final out = await SandboxService.I.exec(
        ['bash', '-c', c],
        hostWorkDir: workDir,
        onLine: shell.addOutput,
      );
      if (out.trim().isEmpty) shell.addOutput('(no output)');
    } catch (e) {
      shell.addOutput('⚠ $e');
    } finally {
      shell.finish();
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.term;
    return AnimatedBuilder(
      animation: t.shell,
      builder: (_, _) {
        final s = t.shell;
        return Column(
          children: [
            Expanded(
              child: ListView.builder(
                controller: t.scroll,
                padding: const EdgeInsets.all(12),
                itemCount: s.history.length + (s.busy ? 1 : 0),
                itemBuilder: (_, i) {
                  if (i == s.history.length) {
                    return const Padding(
                      padding: EdgeInsets.only(top: 2),
                      child: SizedBox(
                        width: 12,
                        height: 12,
                        child: CircularProgressIndicator(
                          strokeWidth: 1.5,
                          color: Aether.accent,
                        ),
                      ),
                    );
                  }
                  final l = s.history[i];
                  return SelectableText(
                    l,
                    style: TextStyle(
                      fontFamily: Aether.mono,
                      fontSize: 11.5,
                      height: 1.6,
                      color: l.startsWith('\$')
                          ? Aether.accent
                          : l.startsWith('⚠')
                          ? Aether.danger
                          : l.endsWith('✓') || l.startsWith('✓')
                          ? Aether.success
                          : Aether.textMuted,
                    ),
                  );
                },
              ),
            ),
            // Real command input — runs natively in the sandbox.
            Container(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
              decoration: BoxDecoration(
                border: Border(top: BorderSide(color: Aether.hairline)),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: t.input,
                      style: const TextStyle(
                        fontFamily: Aether.mono,
                        fontSize: 12.5,
                      ),
                      decoration: InputDecoration(
                        isDense: true,
                        hintText: 'bash \$ …',
                        hintStyle: TextStyle(
                          fontFamily: Aether.mono,
                          color: Aether.textFaint,
                        ),
                        border: InputBorder.none,
                        enabledBorder: InputBorder.none,
                        focusedBorder: InputBorder.none,
                        prefixIcon: const Icon(
                          Icons.chevron_right,
                          size: 16,
                          color: Aether.accent,
                        ),
                        suffixIcon: s.busy
                            ? const SizedBox(
                                width: 14,
                                height: 14,
                                child: CircularProgressIndicator(
                                  strokeWidth: 1.5,
                                  color: Aether.accent,
                                ),
                              )
                            : null,
                      ),
                      textInputAction: TextInputAction.send,
                      onSubmitted: _run,
                      enabled: !s.busy,
                    ),
                  ),
                  // Clear scrollback for THIS terminal.
                  if (s.history.isNotEmpty)
                    IconButton(
                      tooltip: 'Clear',
                      visualDensity: VisualDensity.compact,
                      icon: Icon(
                        Icons.delete_outline,
                        size: 14,
                        color: Aether.textFaint,
                      ),
                      onPressed: () => setState(s.history.clear),
                    ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

/// ── GitHub account chip with avatar, login name, and sign-out menu ──
class _AccountChip extends StatelessWidget {
  const _AccountChip();

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
              showDialog(
                context: context,
                builder: (d) => AlertDialog(
                  title: const Text(
                    'Sign out of GitHub?',
                    style: TextStyle(fontSize: 15),
                  ),
                  content: const Text(
                    'The repo connection will be cleared. Your GitHub access token is removed from this device only.',
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
                        } catch (_) {
                          if (!context.mounted) return;
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text(
                                'Signed out, but the saved token could not be removed.',
                              ),
                            ),
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
                            fontSize: 10.5,
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
                  Icon(Icons.logout, size: 15, color: Aether.danger),
                  SizedBox(width: 8),
                  Text(
                    'Sign out',
                    style: TextStyle(fontSize: 12.5, color: Aether.danger),
                  ),
                ],
              ),
            ),
          ],
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _Avatar(url: gh.avatarUrl, size: 20),
                const SizedBox(width: 6),
                Text(
                  gh.login ?? '',
                  style: TextStyle(fontSize: 11.5, color: Aether.textMuted),
                ),
                Icon(Icons.expand_more, size: 14, color: Aether.textFaint),
              ],
            ),
          ),
        );
      },
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
