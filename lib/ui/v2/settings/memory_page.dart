import 'package:flutter/material.dart';

import '../../design/o_components.dart';
import '../../design/o_screen.dart';
import '../../design/o_tokens.dart';
import 'settings_rows.dart';

// TODO(l10n): move user-facing copy to the ARB files in the localization pass.

/// The one scope filter shared by Memory, Memory files and Shared memory.
///
/// Same chips, same order, same spacing on all three screens: that is what
/// makes them read as one family instead of three variations.
class V2MemoryScopeBar extends StatelessWidget {
  const V2MemoryScopeBar({
    super.key,
    required this.labels,
    required this.selected,
    required this.onSelected,
    this.keyPrefix = 'memory-scope',
  });

  /// `All` first, then the real scopes.
  final List<String> labels;

  /// Index into [labels]; 0 is `All`.
  final int selected;
  final ValueChanged<int> onSelected;
  final String keyPrefix;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: OSpace.s,
      runSpacing: OSpace.s,
      children: [
        for (var index = 0; index < labels.length; index++)
          OChip(
            key: ValueKey<String>('$keyPrefix-${_slug(labels[index])}'),
            label: labels[index],
            selected: selected == index,
            onTap: () => onSelected(index),
          ),
      ],
    );
  }

  static String _slug(String label) => label.toLowerCase().replaceAll(' ', '-');
}

/// One project's learned memory.
@immutable
class V2MemoryProject {
  const V2MemoryProject({
    required this.id,
    required this.name,
    required this.detail,
  });

  final String id;
  final String name;
  final String detail;
}

/// The scope a memory entry belongs to. Also used by the filter chips so the
/// screen can show one scope at a time instead of one long list.
enum V2MemoryScope {
  all('All'),
  global('Global'),
  project('Project'),
  session('Chat');

  const V2MemoryScope(this.label);

  final String label;
}

/// One learned fact with a stable id, so it can be forgotten individually.
@immutable
class V2MemoryEntry {
  const V2MemoryEntry({required this.id, required this.text});

  final String id;
  final String text;
}

/// A file cached for the current chat.
@immutable
class V2MemoryFile {
  const V2MemoryFile({
    required this.id,
    required this.name,
    required this.detail,
    this.icon = Icons.description_outlined,
  });

  final String id;
  final String name;
  final String detail;
  final IconData icon;
}

/// Injected state for the Memory screen.
@immutable
class V2MemoryPageData {
  const V2MemoryPageData({
    this.memoryEnabled = true,
    this.shareSessionMemory = false,
    this.globalMemory = const <String>[],
    this.globalEntries,
    this.globalVersionLabel = '',
    this.projects = const <V2MemoryProject>[],
    this.sessionFiles = const <V2MemoryFile>[],
    this.initialScope = V2MemoryScope.all,
    this.loading = false,
    this.errorMessage,
    this.onMemoryEnabledChanged,
    this.onShareSessionMemoryChanged,
    this.onEditGlobal,
    this.onProjectTap,
    this.onFileDownload,
    this.onForgetMemory,
    this.onExport,
    this.onResetAll,
    this.onRetry,
  });

  final bool memoryEnabled;

  /// Whether facts from this chat may be reused by projects and shared chats.
  final bool shareSessionMemory;
  final List<String> globalMemory;

  /// Facts with stable ids. When null, [globalMemory] is shown and each fact's
  /// text doubles as its id.
  final List<V2MemoryEntry>? globalEntries;
  final String globalVersionLabel;
  final List<V2MemoryProject> projects;
  final List<V2MemoryFile> sessionFiles;

  /// Scope selected when the screen opens. The chips then change it locally.
  final V2MemoryScope initialScope;
  final bool loading;
  final String? errorMessage;

  final ValueChanged<bool>? onMemoryEnabledChanged;
  final ValueChanged<bool>? onShareSessionMemoryChanged;
  final VoidCallback? onEditGlobal;
  final ValueChanged<String>? onProjectTap;
  final ValueChanged<String>? onFileDownload;

  /// Deletes one entry. Global entries pass their id (or text when no id was
  /// supplied), project rows their project id and session rows their file id.
  final void Function(V2MemoryScope scope, String id)? onForgetMemory;
  final VoidCallback? onExport;
  final VoidCallback? onResetAll;
  final VoidCallback? onRetry;

  /// Global facts as entries, whether the caller supplied ids or plain text.
  List<V2MemoryEntry> get resolvedGlobalEntries {
    final explicit = globalEntries;
    if (explicit != null) return explicit;
    return [
      for (var i = 0; i < globalMemory.length; i++)
        V2MemoryEntry(id: '$i:${globalMemory[i]}', text: globalMemory[i]),
    ];
  }

  bool get isEmpty =>
      globalMemory.isEmpty &&
      (globalEntries?.isEmpty ?? true) &&
      projects.isEmpty &&
      sessionFiles.isEmpty;
}

/// Memory settings: what Ovid remembers between chats, and how to clear it.
///
/// One list, one scope filter and one delete per row. The same shape is used by
/// Memory files and Shared memory, so the three screens read as one family.
class MemoryPage extends StatefulWidget {
  const MemoryPage({super.key, required this.data});

  final V2MemoryPageData data;

  @override
  State<MemoryPage> createState() => _MemoryPageState();
}

class _MemoryPageState extends State<MemoryPage> {
  late V2MemoryScope _scope = widget.data.initialScope;
  late List<V2MemoryEntry> _global = widget.data.resolvedGlobalEntries;
  late List<V2MemoryProject> _projects = widget.data.projects;
  late List<V2MemoryFile> _files = widget.data.sessionFiles;

  @override
  void didUpdateWidget(covariant MemoryPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A parent rebuild is the source of truth: re-sync the working copies so a
    // delete that failed server-side reappears instead of staying hidden.
    if (!identical(oldWidget.data, widget.data)) {
      _global = widget.data.resolvedGlobalEntries;
      _projects = widget.data.projects;
      _files = widget.data.sessionFiles;
    }
  }

  V2MemoryPageData get data => widget.data;

  bool _shows(V2MemoryScope scope) =>
      _scope == V2MemoryScope.all || _scope == scope;

  bool get _locallyEmpty =>
      _global.isEmpty && _projects.isEmpty && _files.isEmpty;

  /// Removes the entry locally, then reports it so the owner can delete it for
  /// real. The list updates immediately, which is what makes "Forget" honest.
  void _forget(V2MemoryScope scope, String id) {
    setState(() {
      switch (scope) {
        case V2MemoryScope.global:
          _global = [
            for (final entry in _global)
              if (entry.id != id) entry,
          ];
        case V2MemoryScope.project:
          _projects = [
            for (final project in _projects)
              if (project.id != id) project,
          ];
        case V2MemoryScope.session:
          _files = [
            for (final file in _files)
              if (file.id != id) file,
          ];
        case V2MemoryScope.all:
          break;
      }
    });
    data.onForgetMemory?.call(scope, id);
  }

  List<_MemoryRow> get _rows => [
    if (_shows(V2MemoryScope.global))
      for (final entry in _global)
        _MemoryRow(
          scope: V2MemoryScope.global,
          id: entry.id,
          title: entry.text,
          subtitle: 'Global',
          icon: Icons.terminal_rounded,
        ),
    if (_shows(V2MemoryScope.project))
      for (final project in _projects)
        _MemoryRow(
          scope: V2MemoryScope.project,
          id: project.id,
          title: project.name,
          subtitle: project.detail,
          icon: Icons.folder_rounded,
          onTap: data.onProjectTap == null
              ? null
              : () => data.onProjectTap!(project.id),
        ),
    if (_shows(V2MemoryScope.session))
      for (final file in _files)
        _MemoryRow(
          scope: V2MemoryScope.session,
          id: file.id,
          title: file.name,
          subtitle: file.detail,
          icon: file.icon,
        ),
  ];

  @override
  Widget build(BuildContext context) {
    return OScreen(title: 'Memory', child: _body(context));
  }

  Widget _body(BuildContext context) {
    if (data.loading) return const OSkeletonList(rows: 6);
    if (data.errorMessage != null) {
      return OErrorState(message: data.errorMessage!, onRetry: data.onRetry);
    }
    if (_locallyEmpty) return _emptyState();

    final c = OColors.of(context);
    final rows = _rows;
    return SingleChildScrollView(
      padding: const EdgeInsets.only(top: OSpace.l, bottom: OSpace.xxl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _scopeFilter(context),
          const SizedBox(height: OSpace.s),
          if (rows.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: OSpace.m),
              child: Text(
                'Nothing in this scope',
                style: OType.bodySm.copyWith(color: c.textMuted),
              ),
            )
          else
            V2SettingsRowList(rows: [for (final row in rows) _row(context, row)]),
          if (data.onResetAll != null) ...[
            const SizedBox(height: OSpace.l),
            OButton(
              label: 'Reset all memory',
              icon: Icons.warning_amber_rounded,
              variant: OButtonVariant.danger,
              expand: true,
              onPressed: data.onResetAll,
            ),
          ],
        ],
      ),
    );
  }

  Widget _emptyState() {
    final canTurnOn =
        !data.memoryEnabled && data.onMemoryEnabledChanged != null;
    final Widget? action;
    if (canTurnOn) {
      action = OButton(
        label: 'Turn on memory',
        icon: Icons.toggle_on_rounded,
        onPressed: () => data.onMemoryEnabledChanged!(true),
      );
    } else if (data.onEditGlobal != null) {
      action = OButton(
        label: 'Add a memory',
        icon: Icons.edit_rounded,
        onPressed: data.onEditGlobal,
      );
    } else {
      action = null;
    }
    return OEmptyState(
      icon: Icons.psychology_alt_outlined,
      title: 'No memories yet',
      message: 'Ovid remembers details as you chat.',
      action: action,
    );
  }

  /// Scope chips. Selecting one really filters the list; `All` restores it.
  Widget _scopeFilter(BuildContext context) {
    return V2MemoryScopeBar(
      labels: [for (final scope in V2MemoryScope.values) scope.label],
      selected: _scope.index,
      onSelected: (index) =>
          setState(() => _scope = V2MemoryScope.values[index]),
    );
  }

  Widget _row(BuildContext context, _MemoryRow row) {
    final canForget = data.onForgetMemory != null;
    return V2SettingsRow(
      icon: row.icon,
      title: row.title,
      subtitle: row.subtitle,
      showChevron: false,
      onTap: row.onTap,
      trailing: canForget
          ? OIconButton(
              key: ValueKey<String>(
                'memory-forget-${row.scope.name}-${row.id}',
              ),
              icon: Icons.delete_outline_rounded,
              semanticLabel: 'Forget ${row.title}',
              tooltip: 'Forget',
              onPressed: () => _forget(row.scope, row.id),
            )
          : null,
    );
  }
}

/// One flattened memory row, whatever its scope.
class _MemoryRow {
  const _MemoryRow({
    required this.scope,
    required this.id,
    required this.title,
    required this.subtitle,
    required this.icon,
    this.onTap,
  });

  final V2MemoryScope scope;
  final String id;
  final String title;
  final String subtitle;
  final IconData icon;
  final VoidCallback? onTap;
}
