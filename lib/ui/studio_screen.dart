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
  String _repo = 'orbit/orbit-app';

  @override
  void initState() {
    super.initState();
    // Not logged in yet → show Device Flow login sheet once.
    if (!GitHubService.I.isLoggedIn) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        showGithubLoginSheet(context);
      });
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
          Padding(
            padding: const EdgeInsets.only(right: 14),
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
            _RepoBar(repo: _repo),
            Expanded(
              child: Row(
                children: [
                  if (_showFiles) ...[
                    SizedBox(width: 210, child: _FileTree(repo: _repo)),
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
  const _RepoBar({required this.repo});

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
        Text(repo,
            style: const TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
                color: Aether.text)),
        const SizedBox(width: 8),
        const Tag('GITHUB', color: Aether.textMuted),
        const Spacer(),
        const Text('AI edits sync to this repo automatically',
            style: TextStyle(fontSize: 11, color: Aether.textFaint)),
        const SizedBox(width: 10),
        TextButton(
          style: TextButton.styleFrom(
              minimumSize: Size.zero,
              padding:
                  const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              foregroundColor: Aether.accent),
          onPressed: () {},
          child: const Text('Change', style: TextStyle(fontSize: 12)),
        ),
      ]),
    );
  }
}

class _FileTree extends StatelessWidget {
  final String repo;
  const _FileTree({required this.repo});

  static const tree = [
    ('lib/', 0, true),
    ('main.dart', 1, false),
    ('core/', 1, true),
    ('theme.dart', 2, false),
    ('state.dart', 2, false),
    ('ui/', 1, true),
    ('chat_screen.dart', 2, false),
    ('studio_screen.dart', 2, false),
    ('pubspec.yaml', 0, false),
    ('README.md', 0, false),
  ];

  @override
  Widget build(BuildContext context) {
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
            child: ListView(
              padding: EdgeInsets.zero,
              children: [
                for (final (name, depth, isDir) in tree)
                  InkWell(
                    onTap: () {},
                    child: Padding(
                      padding: EdgeInsets.fromLTRB(
                          10.0 + depth * 14, 6, 8, 6),
                      child: Row(children: [
                        Icon(
                          isDir
                              ? Icons.keyboard_arrow_down
                              : Icons.description_outlined,
                          size: 13,
                          color: isDir
                              ? Aether.textMuted
                              : Aether.textFaint,
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(name,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                  fontSize: 12,
                                  color: isDir
                                      ? Aether.text
                                      : Aether.textMuted)),
                        ),
                      ]),
                    ),
                  ),
              ],
            ),
          ),
          Container(
            padding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
            decoration: const BoxDecoration(
                border:
                    Border(top: BorderSide(color: Aether.hairline))),
            child: const Row(children: [
              Icon(Icons.cloud_done_outlined,
                  size: 13, color: Aether.success),
              SizedBox(width: 7),
              Text('Synced with GitHub',
                  style: TextStyle(
                      fontSize: 11, color: Aether.textMuted)),
            ]),
          ),
        ],
      ),
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
