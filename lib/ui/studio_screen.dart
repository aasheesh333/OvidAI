import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import '../core/theme.dart';
import '../core/state.dart';
import '../core/github_service.dart';
import '../core/agent_service.dart';
import '../core/repo_cache.dart';
import '../core/sandbox_service.dart';
import 'github_login_sheet.dart';

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
    if (!mounted || _handledInitialAuth || github.isInitializing) return;
    _handledInitialAuth = true;
    if (!github.isLoggedIn) {
      showGithubLoginSheet(context);
    } else if (_repo != null && !RepoCache.I.isReady) {
      _autoSync();
    }
  }

  Future<void> _autoSync() async {
    if (_repo == null || _syncing) return;
    setState(() => _syncing = true);
    try {
      RepoCache.I.bind(_repo!, GitHubService.I.token!);
      await RepoCache.I.sync();
    } catch (_) {}
    if (mounted) setState(() => _syncing = false);
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
    String? path;
    try {
      path = await FilePicker.platform.getDirectoryPath(
        dialogTitle: 'Pick working folder for $repo',
      );
    } catch (_) {
      path = null;
    }
    if (!mounted || path == null) return;
    final dir = Directory(path);
    if (!dir.existsSync()) {
      _toast('That folder is not accessible.');
      return;
    }
    var writable = await _probeWritable(path);
    if (!writable) {
      final granted = await AgentService.I.requestAllFilesAccess();
      if (granted) writable = await _probeWritable(path);
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

  Future<bool> _probeWritable(String path) async {
    try {
      final probe = File('$path/.ovid_probe');
      await probe.writeAsString('ok');
      await probe.delete();
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
        AgentService.I.sessionRepoFull = picked;
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Aether.bg,
      appBar: AppBar(
        leading: const BackButton(),
        title: const Text('Studio'),
        actions: [
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
              onPick: _pickRepo,
              syncing: _syncing,
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
            SizedBox(height: 240, child: const _TerminalTabs()),
          ],
        ),
      ),
    );
  }
}

class _RepoBar extends StatelessWidget {
  final String repo;
  final VoidCallback onPick;
  final bool syncing;
  const _RepoBar({
    required this.repo,
    required this.onPick,
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

// ── Multi-terminal (P8) — N independent sandbox shells ────────────────
// Each terminal keeps its own scrollback + busy state; tabs at the top
// with add/close icons (VS Code style). All terminals share the session
// workspace as cwd; commands run through the native sandbox env.
class _TerminalTabs extends StatefulWidget {
  const _TerminalTabs();
  @override
  State<_TerminalTabs> createState() => _TerminalTabsState();
}

class _TerminalTabsState extends State<_TerminalTabs> {
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
    setState(() {
      // Dispose the closing terminal's controllers.
      final t = _terms.removeAt(i);
      t.input.dispose();
      t.scroll.dispose();
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
      t.input.dispose();
      t.scroll.dispose();
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
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 9),
                        margin: const EdgeInsets.fromLTRB(0, 4, 6, 4),
                        decoration: BoxDecoration(
                          color: sel ? Aether.surfaceAlt : Colors.transparent,
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(
                            color: sel ? Aether.hairline : Colors.transparent,
                          ),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              t.busy ? Icons.sync : Icons.chevron_right,
                              size: 11,
                              color: t.busy
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
                                color: sel ? Aether.text : Aether.textFaint,
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

/// One terminal's mutable UI state.
class _TerminalSession {
  final input = TextEditingController();
  final scroll = ScrollController();
  final history = <String>[];
  bool busy = false;
}

/// The active terminal's pane (scrollback + input).
class _TerminalPane extends StatefulWidget {
  final _TerminalSession term;
  const _TerminalPane({required this.term});
  @override
  State<_TerminalPane> createState() => _TerminalPaneState();
}

class _TerminalPaneState extends State<_TerminalPane> {
  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (widget.term.scroll.hasClients) {
        widget.term.scroll.jumpTo(widget.term.scroll.position.maxScrollExtent);
      }
    });
  }

  Future<void> _run(String cmd) async {
    final t = widget.term;
    final c = cmd.trim();
    if (c.isEmpty || t.busy) return;
    t.input.clear();
    setState(() {
      t.history.add('\$ $c');
      t.busy = true;
    });
    _scrollToBottom();
    try {
      final sessionId = AppState.I.activeSession?.sandboxId ?? 'default';
      final workDir = await SandboxService.I.workDirFor(sessionId);
      final out = await SandboxService.I.exec(
        ['bash', '-c', c],
        hostWorkDir: workDir,
        onLine: (l) {
          if (!mounted) return;
          setState(() => t.history.add(l));
          _scrollToBottom();
        },
      );
      if (out.trim().isEmpty) {
        setState(() => t.history.add('(no output)'));
      }
    } catch (e) {
      setState(() => t.history.add('⚠ $e'));
    } finally {
      t.busy = false;
      if (mounted) setState(() {});
      _scrollToBottom();
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.term;
    return Column(
      children: [
        Expanded(
          child: ListView.builder(
            controller: t.scroll,
            padding: const EdgeInsets.all(12),
            itemCount: t.history.length + (t.busy ? 1 : 0),
            itemBuilder: (_, i) {
              if (i == t.history.length) {
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
              final l = t.history[i];
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
                    suffixIcon: t.busy
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
                  enabled: !t.busy,
                ),
              ),
              // Clear scrollback for THIS terminal.
              if (t.history.isNotEmpty)
                IconButton(
                  tooltip: 'Clear',
                  visualDensity: VisualDensity.compact,
                  icon: Icon(
                    Icons.delete_outline,
                    size: 14,
                    color: Aether.textFaint,
                  ),
                  onPressed: () =>
                      setState(t.history.clear),
                ),
            ],
          ),
        ),
      ],
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
