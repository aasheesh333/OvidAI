import 'package:flutter/material.dart';
import '../core/theme.dart';
import '../core/state.dart';
import '../core/github_service.dart';
import '../core/agent_service.dart';
import 'github_login_sheet.dart';

/// Studio — coding harness (DeepSeek-web style): file explorer bound to the
/// user's connected GitHub repo, editor with dummy code, agent activity rail,
/// and a sandbox terminal. The user never sees OS/infra details — only
/// "Sandbox ● ready".
class StudioScreen extends StatefulWidget {
  const StudioScreen({super.key});
  @override
  State<StudioScreen> createState() => _StudioScreenState();
}

class _StudioScreenState extends State<StudioScreen> {
  bool _showFiles = true;
  bool _syncing = false;

  String? get _repo => AgentService.I.repoFull;

  @override
  void initState() {
    super.initState();
    // Not logged in yet → show Device Flow login sheet once.
    if (!GitHubService.I.isLoggedIn) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        showGithubLoginSheet(context);
      });
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

  Future<void> _pickRepo() async {
    if (!GitHubService.I.isLoggedIn) {
      await showGithubLoginSheet(context);
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
                child: Text('Your repositories',
                    style:
                        TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
              ),
              for (final r in repos)
                ListTile(
                  dense: true,
                  leading: const Icon(Icons.bookmark_border,
                      size: 18, color: Aether.textMuted),
                  title: Text(r['full_name'] ?? '${r['name']}',
                      style: const TextStyle(fontSize: 13.5)),
                  subtitle: Text(
                      '${r['language'] ?? '—'} · ⭐ ${r['stargazers_count'] ?? 0}',
                      style: const TextStyle(
                          fontSize: 11, color: Aether.textFaint)),
                  onTap: () => Navigator.pop(context, r['full_name'] as String),
                ),
            ],
          ),
        ),
      );
      if (picked != null) {
        AgentService.I.repoFull = picked;
        await _autoSync();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Repo list failed: $e')));
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
            icon: Icon(_showFiles ? Icons.folder_open : Icons.folder_outlined,
                size: 19, color: Aether.textMuted),
            onPressed: () => setState(() => _showFiles = !_showFiles),
          ),
          const Icon(Icons.play_arrow_rounded,
              size: 22, color: Aether.success),
          const SizedBox(width: 14),
          const Icon(Icons.account_tree_outlined,
              size: 18, color: Aether.textMuted),
          const SizedBox(width: 14),
          // ── GitHub account chip + sign out ──
          const _AccountChip(),
          Padding(
            padding: const EdgeInsets.only(right: 14, left: 4),
            child: AnimatedBuilder(
              animation: AppState.I,
              builder: (context, _) => Row(children: [
                Container(
                    width: 7,
                    height: 7,
                    decoration: BoxDecoration(
                        color: AppState.I.sandboxInstalled
                            ? Aether.success
                            : Aether.warn,
                        shape: BoxShape.circle)),
                const SizedBox(width: 6),
                Text(
                    AppState.I.sandboxInstalled
                        ? 'Sandbox ready'
                        : 'Sandbox pending',
                    style: const TextStyle(
                        fontSize: 11.5, color: Aether.textMuted)),
              ]),
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
                syncing: _syncing),
            Expanded(
              child: Row(
                children: [
                  if (_showFiles) ...[
                    SizedBox(width: 210, child: _FileTree()),
                    const VerticalDivider(width: 1),
                  ],
                  const Expanded(
                    child: Column(children: [
                      _Tabs(),
                      Expanded(child: _Editor()),
                    ]),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            const _Terminal(),
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
  const _RepoBar(
      {required this.repo, required this.onPick, required this.syncing});

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 40,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: const BoxDecoration(
        color: Aether.surface,
        border: Border(bottom: BorderSide(color: Aether.hairline)),
      ),
      child: Row(children: [
        const Icon(Icons.hub_outlined, size: 15, color: Aether.textMuted),
        const SizedBox(width: 8),
        Expanded(
          child: Text(repo,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                  color: repo == 'Connect a repo'
                      ? Aether.textFaint
                      : Aether.text)),
        ),
        if (repo != 'Connect a repo')
          const Tag('GITHUB', color: Aether.textMuted),
        if (syncing) ...[
          const SizedBox(width: 8),
          const SizedBox(
              width: 11,
              height: 11,
              child: CircularProgressIndicator(
                  strokeWidth: 1.5, color: Aether.accent)),
        ],
        const SizedBox(width: 8),
        TextButton(
          style: TextButton.styleFrom(
              minimumSize: Size.zero,
              padding:
                  const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              foregroundColor: Aether.accent),
          onPressed: onPick,
          child: Text(repo == 'Connect a repo' ? 'Connect' : 'Change',
              style: const TextStyle(fontSize: 12)),
        ),
      ]),
    );
  }
}

class _FileTree extends StatelessWidget {
  const _FileTree();

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([RepoCache.I, AgentService.I]),
      builder: (_, __) {
        final cache = RepoCache.I;
        final paths = cache.treePaths;
        return Container(
          color: Aether.surface,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Padding(
                padding: EdgeInsets.fromLTRB(12, 10, 12, 8),
                child: Text('FILES',
                    style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 1.4,
                        color: Aether.textFaint)),
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
                                  color: Aether.textFaint)),
                        ),
                      )
                    : ListView.builder(
                        padding: EdgeInsets.zero,
                        itemCount: paths.length,
                        itemBuilder: (_, i) {
                          final p = paths[i];
                          final depth =
                              '/'.allMatches(p).length;
                          final isDir = i + 1 < paths.length &&
                              paths[i + 1].startsWith('$p/');
                          final active =
                              AgentService.I.activeFilePath == p;
                          return InkWell(
                            onTap: () {
                              AgentService.I.activeFilePath = p;
                              if (!isDir && cache.files[p] != null) {
                                AgentService.I.fileBuffer[p] = cache.files[p]!;
                              }
                              AgentService.I.refreshNow();
                            },
                            child: Container(
                              color: active
                                  ? Aether.accentSoft
                                  : Colors.transparent,
                              padding: EdgeInsets.fromLTRB(
                                  10.0 + depth * 14, 6, 8, 6),
                              child: Row(children: [
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
                                                  : Aether.textMuted)),
                                ),
                              ]),
                            ),
                          );
                        },
                      ),
              ),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
                decoration: const BoxDecoration(
                    border:
                        Border(top: BorderSide(color: Aether.hairline))),
                child: Row(children: [
                  Icon(
                      cache.isReady
                          ? Icons.cloud_done_outlined
                          : Icons.cloud_off_outlined,
                      size: 13,
                      color: cache.isReady
                          ? Aether.success
                          : Aether.textFaint),
                  const SizedBox(width: 7),
                  Expanded(
                    child: Text(
                        cache.isReady
                            ? 'Synced · ${cache.files.length} files'
                            : 'Not connected',
                        style: const TextStyle(
                            fontSize: 11, color: Aether.textMuted)),
                  ),
                ]),
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
  @override
  Widget build(BuildContext context) {
    final tabs = ['main.dart', 'theme.dart', 'README.md'];
    return Container(
      height: 38,
      color: Aether.surface,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        itemCount: tabs.length,
        itemBuilder: (_, i) {
          final active = i == 0;
          return Container(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            decoration: BoxDecoration(
              border: Border(
                right: const BorderSide(color: Aether.hairline),
                top: BorderSide(
                    color: active ? Aether.accent : Colors.transparent,
                    width: 2),
              ),
              color: active ? Aether.bg : Aether.surface,
            ),
            child: Row(children: [
              Icon(Icons.description_outlined,
                  size: 13,
                  color: active ? Aether.text : Aether.textFaint),
              const SizedBox(width: 6),
              Text(tabs[i],
                  style: TextStyle(
                      fontSize: 12,
                      color:
                          active ? Aether.text : Aether.textMuted)),
              const SizedBox(width: 8),
              const Icon(Icons.close, size: 12, color: Aether.textFaint),
            ]),
          );
        },
      ),
    );
  }
}

class _Editor extends StatelessWidget {
  const _Editor();

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: AgentService.I,
      builder: (_, __) {
        final a = AgentService.I;
        final path = a.activeFilePath ?? 'welcome.md';
        final code = a.fileBuffer[path] ??
            "Ovid Agent ready.\n\n"
                "Ask the AI in chat to:\n"
                "  • read a file from your connected repo\n"
                "  • run commands in the sandbox\n"
                "  • open pages in Browser\n\n"
                "Everything happens right here — live.";
        final lines = code.split('\n');
        return Container(
          color: Aether.bg,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Active file path header
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
                color: Aether.surfaceAlt,
                child: Row(children: [
                  const Icon(Icons.edit_note,
                      size: 12, color: Aether.accent),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(path,
                        style: TextStyle(
                            fontFamily: Aether.mono,
                            fontSize: 10.5,
                            color: Aether.textMuted)),
                  ),
                  if (AgentService.I.repoFull != null)
                    Text(AgentService.I.repoFull!,
                        style: const TextStyle(
                            fontFamily: Aether.mono,
                            fontSize: 10,
                            color: Aether.textFaint)),
                ]),
              ),
              Expanded(
                child: ListView.builder(
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  itemCount: lines.length,
                  itemBuilder: (_, i) => Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SizedBox(
                          width: 32,
                          child: Text('${i + 1}',
                              textAlign: TextAlign.right,
                              style: const TextStyle(
                                  fontFamily: Aether.mono,
                                  fontSize: 11.5,
                                  height: 1.6,
                                  color: Aether.textFaint)),
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: SelectableText(lines[i],
                              style: const TextStyle(
                                  fontFamily: Aether.mono,
                                  fontSize: 12,
                                  height: 1.6,
                                  color: Aether.text)),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _Terminal extends StatelessWidget {
  const _Terminal();

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: AgentService.I,
      builder: (_, __) {
        final events = AgentService.I.events
            .where((e) => e.kind == 'shell' || e.kind == 'shellOut')
            .toList();
        final lines = <String>['\$ ovid sandbox --ready'];
        for (final e in events) {
          lines.add(e.kind == 'shell' ? '\$ ${e.text}' : e.text);
        }
        if (AgentService.I.busy) lines.add('\$ ');
        return Container(
          height: 190,
          color: Aether.surface,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                color: Aether.surfaceAlt,
                child: const Row(children: [
                  Icon(Icons.terminal, size: 13, color: Aether.textMuted),
                  SizedBox(width: 8),
                  Text('SANDBOX TERMINAL',
                      style: TextStyle(
                          fontSize: 10.5,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.8,
                          color: Aether.textMuted)),
                  Spacer(),
                  Icon(Icons.add, size: 14, color: Aether.textFaint),
                  SizedBox(width: 12),
                  Icon(Icons.keyboard_arrow_up,
                      size: 16, color: Aether.textFaint),
                ]),
              ),
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.all(12),
                  children: [
                    for (final l in lines)
                      Text(l,
                          style: TextStyle(
                              fontFamily: Aether.mono,
                              fontSize: 11.5,
                              height: 1.6,
                              color: l.startsWith('\$')
                                  ? Aether.accent
                                  : l.startsWith('✓') || l.endsWith('✓')
                                      ? Aether.success
                                      : Aether.textMuted)),
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

/// ── GitHub account chip with avatar, login name, and sign-out menu ──
class _AccountChip extends StatelessWidget {
  const _AccountChip();

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: GitHubService.I,
      builder: (_, __) {
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
                  title: const Text('Sign out of GitHub?',
                      style: TextStyle(fontSize: 15)),
                  content: const Text(
                      'The repo connection will be cleared. Your GitHub access token is removed from this device only.',
                      style: TextStyle(fontSize: 12.5)),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.pop(d),
                        child: const Text('Cancel')),
                    TextButton(
                        onPressed: () {
                          gh.signOut();
                          Navigator.pop(d);
                        },
                        child: const Text('Sign out',
                            style: TextStyle(color: Aether.danger))),
                  ],
                ),
              );
            }
          },
          itemBuilder: (_) => [
            PopupMenuItem(
              enabled: false,
              child: Row(children: [
                _Avatar(url: gh.avatarUrl, size: 24),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(gh.name ?? gh.login ?? '',
                          style: const TextStyle(
                              fontSize: 12.5,
                              fontWeight: FontWeight.w600)),
                      Text('@${gh.login ?? ''}',
                          style: const TextStyle(
                              fontSize: 10.5,
                              color: Aether.textFaint)),
                    ],
                  ),
                ),
              ]),
            ),
            const PopupMenuDivider(height: 6),
            const PopupMenuItem(
              value: 'signout',
              child: Row(children: [
                Icon(Icons.logout,
                    size: 15, color: Aether.danger),
                SizedBox(width: 8),
                Text('Sign out',
                    style: TextStyle(
                        fontSize: 12.5, color: Aether.danger)),
              ]),
            ),
          ],
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              _Avatar(url: gh.avatarUrl, size: 20),
              const SizedBox(width: 6),
              Text(gh.login ?? '',
                  style: const TextStyle(
                      fontSize: 11.5, color: Aether.textMuted)),
              const Icon(Icons.expand_more,
                  size: 14, color: Aether.textFaint),
            ]),
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
        child: Icon(Icons.person_outline,
            size: size * 0.55, color: Aether.textMuted),
      );
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(size / 2),
      child: Image.network(
        url!,
        width: size,
        height: size,
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => Container(
          width: size,
          height: size,
          color: Aether.surfaceRaised,
          child: Icon(Icons.person_outline,
              size: size * 0.55, color: Aether.textMuted),
        ),
      ),
    );
  }
}
