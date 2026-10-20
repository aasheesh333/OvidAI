import 'package:flutter/material.dart';

import '../core/chat_integration_ports.dart';
import '../core/theme.dart';

/// W9 STUDIO repo/branch picker.
///
/// The data comes from the W3 [StudioBindingPort]; this sheet only renders it
/// and calls `bind`/`syncLatest`. Keeping the picker here means the chat
/// composer owns the gate (send is blocked until a binding exists) while W3
/// owns OAuth, cloning and branch discovery.
Future<void> showStudioBindingSheet(
  BuildContext context, {
  required String sessionId,
}) {
  final port = StudioBindingPort.instance;
  if (port == null) return Future<void>.value();
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Aether.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
    ),
    builder: (_) => FractionallySizedBox(
      heightFactor: .82,
      child: _StudioBindingSheet(sessionId: sessionId, port: port),
    ),
  );
}

class _StudioBindingSheet extends StatefulWidget {
  const _StudioBindingSheet({required this.sessionId, required this.port});

  final String sessionId;
  final StudioBindingPort port;

  @override
  State<_StudioBindingSheet> createState() => _StudioBindingSheetState();
}

class _StudioBindingSheetState extends State<_StudioBindingSheet> {
  List<String> _repos = const [];
  String? _repo;
  List<String> _branches = const [];
  String? _branch;
  bool _loadingRepos = true;
  bool _loadingBranches = false;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final current = widget.port.bindingFor(widget.sessionId);
    _repo = current?.repo;
    _branch = current?.branch;
    _loadRepos();
  }

  Future<void> _loadRepos() async {
    setState(() {
      _loadingRepos = true;
      _error = null;
    });
    try {
      final repos = await widget.port.listRepos();
      if (!mounted) return;
      setState(() {
        _repos = repos;
        _loadingRepos = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadingRepos = false;
        _error = 'Could not load repositories: $e';
      });
    }
  }

  Future<void> _pickRepo(String repo) async {
    setState(() {
      _repo = repo;
      _branch = null;
      _branches = const [];
      _loadingBranches = true;
      _error = null;
    });
    try {
      final branches = await widget.port.listBranches(repo);
      if (!mounted || _repo != repo) return;
      setState(() {
        _branches = branches;
        _branch = branches.contains('main')
            ? 'main'
            : (branches.isEmpty ? null : branches.first);
        _loadingBranches = false;
      });
    } catch (e) {
      if (!mounted || _repo != repo) return;
      setState(() {
        _loadingBranches = false;
        _error = 'Could not load branches: $e';
      });
    }
  }

  Future<void> _bind() async {
    final repo = _repo;
    final branch = _branch;
    if (repo == null || branch == null) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.port.bind(widget.sessionId, repo: repo, branch: branch);
      if (!mounted) return;
      Navigator.pop(context);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = 'Could not bind the repository: $e';
      });
    }
  }

  Future<void> _sync() async {
    setState(() => _error = null);
    try {
      await widget.port.syncLatest(widget.sessionId);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Latest changes synced'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = 'Could not sync: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final current = widget.port.bindingFor(widget.sessionId);
    return SafeArea(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 8, 6),
            child: Row(
              children: [
                Icon(Icons.code, size: 18, color: Aether.accent),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text(
                    'Repository & branch',
                    style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
                  ),
                ),
                IconButton(
                  tooltip: 'Close',
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close, size: 18),
                ),
              ],
            ),
          ),
          if (current != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '${current.repo} · ${current.branch}',
                      style: TextStyle(fontSize: 12, color: Aether.textMuted),
                    ),
                  ),
                  TextButton.icon(
                    key: const ValueKey('studio-binding-sync'),
                    onPressed: widget.port.syncingFor(widget.sessionId)
                        ? null
                        : _sync,
                    icon: const Icon(Icons.sync, size: 15),
                    label: const Text(
                      'Sync latest changes',
                      style: TextStyle(fontSize: 12),
                    ),
                  ),
                ],
              ),
            ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
              child: Text(
                _error!,
                style: TextStyle(fontSize: 12, color: Aether.danger),
              ),
            ),
          if (_loadingRepos)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Center(child: CircularProgressIndicator()),
            )
          else if (_repos.isEmpty)
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 12, 16, 16),
              child: Text(
                'No repositories available. Connect GitHub in Studio first.',
                style: TextStyle(fontSize: 13),
              ),
            )
          else
            Expanded(
              child: Row(
                children: [
                  Expanded(
                    child: _ListPane(
                      title: 'Repositories',
                      children: [
                        for (final repo in _repos)
                          _Row(
                            key: ValueKey('studio-repo-$repo'),
                            label: repo,
                            selected: repo == _repo,
                            onTap: () => _pickRepo(repo),
                          ),
                      ],
                    ),
                  ),
                  Container(width: .5, color: Aether.hairline),
                  Expanded(
                    child: _ListPane(
                      title: 'Branches',
                      children: [
                        if (_repo == null)
                          const _Hint('Choose a repository')
                        else if (_loadingBranches)
                          const Padding(
                            padding: EdgeInsets.all(20),
                            child: Center(child: CircularProgressIndicator()),
                          )
                        else if (_branches.isEmpty)
                          const _Hint('No branches found')
                        else
                          for (final branch in _branches)
                            _Row(
                              key: ValueKey('studio-branch-$branch'),
                              label: branch,
                              selected: branch == _branch,
                              onTap: () => setState(() => _branch = branch),
                            ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 14),
            child: FilledButton(
              key: const ValueKey('studio-binding-confirm'),
              onPressed: _saving || _repo == null || _branch == null
                  ? null
                  : _bind,
              child: _saving
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Text(
                      _repo == null || _branch == null
                          ? 'Choose a repository and branch'
                          : 'Use $_repo · $_branch',
                    ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ListPane extends StatelessWidget {
  const _ListPane({required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 8, 14, 4),
          child: Text(
            title.toUpperCase(),
            style: TextStyle(
              fontSize: 9.5,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.1,
              color: Aether.textFaint,
            ),
          ),
        ),
        Expanded(child: ListView(children: children)),
      ],
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      dense: true,
      selected: selected,
      selectedColor: Aether.accent,
      leading: Icon(
        selected ? Icons.check_circle : Icons.circle_outlined,
        size: 16,
        color: selected ? Aether.accent : Aether.textFaint,
      ),
      title: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 13),
      ),
      onTap: onTap,
    );
  }
}

class _Hint extends StatelessWidget {
  const _Hint(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(16),
    child: Text(text, style: TextStyle(fontSize: 12, color: Aether.textFaint)),
  );
}
