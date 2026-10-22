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
    this.counts,
    this.keyPrefix = 'memory-scope',
  });

  /// `All` first, then the real scopes.
  final List<String> labels;

  /// Index into [labels]; 0 is `All`.
  final int selected;
  final ValueChanged<int> onSelected;

  /// Optional count per label. When supplied it is rendered beside the label
  /// and spoken after it ("Global, 2 entries"), so a filter never claims rows
  /// it does not hold.
  final List<int>? counts;
  final String keyPrefix;

  @override
  Widget build(BuildContext context) {
    final values = counts;
    assert(
      values == null || values.length == labels.length,
      'counts must describe every label',
    );
    return Wrap(
      spacing: OSpace.s,
      runSpacing: OSpace.s,
      children: [
        for (var index = 0; index < labels.length; index++)
          OChip(
            key: ValueKey<String>('$keyPrefix-${_slug(labels[index])}'),
            label: values == null
                ? labels[index]
                : '${labels[index]} ${values[index]}',
            semanticLabel: values == null
                ? labels[index]
                : '${labels[index]}, ${values[index]} '
                      '${values[index] == 1 ? 'entry' : 'entries'}',
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

  /// The service's summary of the project's memory. Kept on the data object so
  /// callers do not lose it; the screen lists the project on one line and does
  /// not render this description.
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

  /// The service's size/type summary. Kept for callers; the row is one line.
  final String detail;
  final IconData icon;
}

/// Deletes one entry. Return `true` (or a `Future` that completes without
/// throwing) when the write reached the service; return `false`, throw, or
/// resolve to `false` when it did not, and the row stays with an inline error.
///
/// A plain `void` handler is accepted for older callers. It gives no
/// completion signal, so the row is never removed optimistically: the owner's
/// next data refresh is the success signal.
typedef V2MemoryForget = Object? Function(V2MemoryScope scope, String id);

/// Saves an edited fact. Returns the text the service stored, or null when the
/// save failed; the list keeps the old text in that case.
typedef V2MemoryEdit =
    Future<String?> Function(V2MemoryScope scope, String id, String text);

/// Stores a new fact. Returns the entry the service created (with its real
/// id), or null on failure. The screen never invents an entry for a write that
/// has not been confirmed.
typedef V2MemoryAdd = Future<V2MemoryEntry?> Function(String text);

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
    this.onEditMemory,
    this.onAddMemory,
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

  /// Opens the memory files screen. Retained for callers; this screen does not
  /// render a control for it because that destination has no write path yet.
  final VoidCallback? onEditGlobal;
  final ValueChanged<String>? onProjectTap;
  final ValueChanged<String>? onFileDownload;

  /// Deletes one entry. Global entries pass their id (or text when no id was
  /// supplied), project rows their project id and session rows their file id.
  final V2MemoryForget? onForgetMemory;

  /// Edits one global fact in place. When null, facts are read-only here and
  /// tapping one does nothing.
  final V2MemoryEdit? onEditMemory;

  /// Adds a global fact. When null, no add control is rendered: there is no
  /// write path to reach.
  final V2MemoryAdd? onAddMemory;

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
      resolvedGlobalEntries.isEmpty && projects.isEmpty && sessionFiles.isEmpty;
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

  /// Row keys (`scope:id`) whose forget is in flight. The row stays visible
  /// with a progress indicator until the service answers.
  final Set<String> _pending = <String>{};

  /// The last per-entry failure. Shown above the list, not in a snackbar, so
  /// the row that failed stays in view next to its reason.
  String? _actionError;

  @override
  void didUpdateWidget(covariant MemoryPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A parent rebuild is the source of truth: re-sync the working copies so a
    // delete that failed server-side reappears instead of staying hidden.
    if (!identical(oldWidget.data, widget.data)) {
      _global = widget.data.resolvedGlobalEntries;
      _projects = widget.data.projects;
      _files = widget.data.sessionFiles;
      final present = <String>{
        for (final entry in _global) 'global:${entry.id}',
        for (final project in _projects) 'project:${project.id}',
        for (final file in _files) 'session:${file.id}',
      };
      _pending.removeWhere((key) => !present.contains(key));
    }
  }

  V2MemoryPageData get data => widget.data;

  bool _shows(V2MemoryScope scope) =>
      _scope == V2MemoryScope.all || _scope == scope;

  bool get _locallyEmpty =>
      _global.isEmpty && _projects.isEmpty && _files.isEmpty;

  static String _key(V2MemoryScope scope, String id) => '${scope.name}:$id';

  List<int> get _counts => [
    _global.length + _projects.length + _files.length,
    _global.length,
    _projects.length,
    _files.length,
  ];

  List<_MemoryRow> get _rows => [
    if (_shows(V2MemoryScope.global))
      for (final entry in _global)
        _MemoryRow(
          scope: V2MemoryScope.global,
          id: entry.id,
          text: entry.text,
          icon: Icons.terminal_rounded,
          hint: data.onEditMemory == null ? null : 'Edit',
          onTap: data.onEditMemory == null ? null : () => _edit(entry),
        ),
    if (_shows(V2MemoryScope.project))
      for (final project in _projects)
        _MemoryRow(
          scope: V2MemoryScope.project,
          id: project.id,
          text: project.name,
          icon: Icons.folder_rounded,
          hint: data.onProjectTap == null ? null : 'Open',
          onTap: data.onProjectTap == null
              ? null
              : () => data.onProjectTap!(project.id),
        ),
    if (_shows(V2MemoryScope.session))
      for (final file in _files)
        _MemoryRow(
          scope: V2MemoryScope.session,
          id: file.id,
          text: file.name,
          icon: file.icon,
        ),
  ];

  /// Calls the real delete handler. The row is removed only after the handler
  /// reports success; a failure keeps the row and shows the reason inline.
  Future<void> _forget(_MemoryRow row) async {
    final handler = data.onForgetMemory;
    if (handler == null) return;
    final key = _key(row.scope, row.id);
    if (_pending.contains(key)) return;
    setState(() {
      _actionError = null;
      _pending.add(key);
    });
    try {
      final result = handler(row.scope, row.id);
      if (result is Future) {
        final outcome = await result;
        if (!mounted) return;
        if (outcome == false) {
          _failForget();
          return;
        }
        _remove(row);
      } else if (result is bool) {
        if (!result) {
          _failForget();
          return;
        }
        _remove(row);
      }
      // A void result is a legacy fire-and-forget handler: it never proves
      // success, so the row stays until the owner supplies fresh data.
    } catch (_) {
      if (mounted) _failForget();
    } finally {
      if (mounted) setState(() => _pending.remove(key));
    }
  }

  void _failForget() {
    setState(() => _actionError = 'Could not forget that memory.');
  }

  void _remove(_MemoryRow row) {
    if (!mounted) return;
    setState(() {
      switch (row.scope) {
        case V2MemoryScope.global:
          _global = [
            for (final entry in _global)
              if (entry.id != row.id) entry,
          ];
        case V2MemoryScope.project:
          _projects = [
            for (final project in _projects)
              if (project.id != row.id) project,
          ];
        case V2MemoryScope.session:
          _files = [
            for (final file in _files)
              if (file.id != row.id) file,
          ];
        case V2MemoryScope.all:
          break;
      }
    });
  }

  /// Opens one fact in an editor prefilled with its stored text. The list is
  /// only changed after the save handler confirms what the service stored.
  Future<void> _edit(V2MemoryEntry entry) async {
    final edit = data.onEditMemory;
    if (edit == null) return;
    final saved = await _openEditor(
      title: 'Edit memory',
      initialText: entry.text,
      onSave: (text) async {
        final stored = await edit(V2MemoryScope.global, entry.id, text);
        return stored == null
            ? null
            : V2MemoryEntry(id: entry.id, text: stored);
      },
    );
    if (saved == null || !mounted) return;
    setState(() {
      _global = [
        for (final current in _global)
          if (current.id == saved.id) saved else current,
      ];
      _actionError = null;
    });
  }

  Future<void> _add() async {
    final add = data.onAddMemory;
    if (add == null) return;
    final created = await _openEditor(
      title: 'Add memory',
      initialText: '',
      onSave: add,
    );
    if (created == null || !mounted) return;
    setState(() {
      _global = [created, ..._global];
      // Show the fact that was just stored, even if the filter was elsewhere.
      if (_scope != V2MemoryScope.all) _scope = V2MemoryScope.global;
      _actionError = null;
    });
  }

  Future<V2MemoryEntry?> _openEditor({
    required String title,
    required String initialText,
    required Future<V2MemoryEntry?> Function(String text) onSave,
  }) {
    return showModalBottomSheet<V2MemoryEntry>(
      context: context,
      isScrollControlled: true,
      backgroundColor: OColors.of(context).surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(ORadius.xl)),
      ),
      builder: (_) =>
          _MemoryEditor(title: title, initialText: initialText, onSave: onSave),
    );
  }

  @override
  Widget build(BuildContext context) {
    return OScreen(
      title: 'Memory',
      actions: [
        if (!data.loading &&
            data.errorMessage == null &&
            !_locallyEmpty &&
            data.onAddMemory != null)
          OIconButton(
            key: const ValueKey<String>('memory-add'),
            icon: Icons.add_rounded,
            semanticLabel: 'Add memory',
            tooltip: 'Add',
            onPressed: _add,
          ),
        // The memory files destination is real (view/delete); keep it reachable
        // without pretending this screen can add a file.
        if (!data.loading &&
            data.errorMessage == null &&
            data.onEditGlobal != null)
          OIconButton(
            key: const ValueKey<String>('memory-files'),
            icon: Icons.folder_outlined,
            semanticLabel: 'Memory files',
            tooltip: 'Files',
            onPressed: data.onEditGlobal,
          ),
      ],
      child: _body(context),
    );
  }

  Widget _body(BuildContext context) {
    if (data.loading) return const OSkeletonList(rows: 6);
    if (data.errorMessage != null) {
      return OErrorState(message: data.errorMessage!, onRetry: data.onRetry);
    }
    if (_locallyEmpty) return _emptyState();

    final c = OColors.of(context);
    final rows = _rows;
    return CustomScrollView(
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.only(top: OSpace.l),
          sliver: SliverList(
            delegate: SliverChildListDelegate([
              _scopeFilter(),
              if (_actionError != null) ...[
                const SizedBox(height: OSpace.m),
                _InlineError(message: _actionError!),
              ],
              const SizedBox(height: OSpace.s),
            ]),
          ),
        ),
        if (rows.isEmpty)
          SliverToBoxAdapter(child: _noMatch(context))
        else
          SliverList.builder(
            itemCount: rows.length,
            itemBuilder: (context, index) => Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (index > 0)
                  Divider(
                    height: 1,
                    thickness: 1,
                    indent: v2SettingsRowDividerIndent,
                    color: c.hairline,
                  ),
                _row(rows[index]),
              ],
            ),
          ),
        if (data.onResetAll != null)
          SliverPadding(
            padding: const EdgeInsets.only(top: OSpace.l),
            sliver: SliverToBoxAdapter(
              child: OButton(
                label: 'Reset all memory',
                icon: Icons.warning_amber_rounded,
                variant: OButtonVariant.danger,
                expand: true,
                onPressed: data.onResetAll,
              ),
            ),
          ),
        const SliverToBoxAdapter(child: SizedBox(height: OSpace.xxl)),
      ],
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
    } else if (data.onAddMemory != null) {
      action = OButton(
        label: 'Add a memory',
        icon: Icons.add_rounded,
        onPressed: _add,
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
  Widget _scopeFilter() {
    return V2MemoryScopeBar(
      labels: [for (final scope in V2MemoryScope.values) scope.label],
      counts: _counts,
      selected: _scope.index,
      onSelected: (index) => setState(() {
        _scope = V2MemoryScope.values[index];
        _actionError = null;
      }),
    );
  }

  /// A scope that holds no rows, while other scopes do. This is deliberately
  /// different copy from the empty state: the memory is not empty, the filter
  /// is just narrower than the data.
  Widget _noMatch(BuildContext context) {
    final c = OColors.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: OSpace.m),
      child: Text(
        'No memories in this scope',
        style: OType.bodySm.copyWith(color: c.textMuted),
      ),
    );
  }

  Widget _row(_MemoryRow row) {
    final key = _key(row.scope, row.id);
    final pending = _pending.contains(key);
    final canForget = data.onForgetMemory != null && !pending;
    return _MemoryFactRow(
      key: ValueKey<String>('memory-row-$key'),
      icon: row.icon,
      text: row.text,
      scope: row.scope,
      hint: row.hint,
      busy: pending,
      onTap: pending ? null : row.onTap,
      trailing: data.onForgetMemory == null
          ? null
          : pending
          ? Semantics(
              label: 'Forgetting ${row.text}',
              liveRegion: true,
              child: const SizedBox(
                width: OSpace.touch,
                height: OSpace.touch,
                child: Center(
                  child: SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
              ),
            )
          : OIconButton(
              key: ValueKey<String>('memory-forget-$key'),
              icon: Icons.delete_outline_rounded,
              semanticLabel: 'Forget ${row.text}, destructive',
              tooltip: 'Forget',
              onPressed: canForget ? () => _forget(row) : null,
            ),
    );
  }
}

/// One fact on one line: a scope icon, the text, and one destructive control.
///
/// Built here rather than with `OListRow` because a fact must ellipsize to a
/// single line; the row keeps the same 56 dp floor, gutter and type.
class _MemoryFactRow extends StatelessWidget {
  const _MemoryFactRow({
    super.key,
    required this.icon,
    required this.text,
    required this.scope,
    required this.busy,
    required this.trailing,
    this.hint,
    this.onTap,
  });

  final IconData icon;
  final String text;
  final V2MemoryScope scope;
  final bool busy;
  final Widget? trailing;
  final String? hint;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    final label = '$text, ${scope.label} memory';
    final content = Row(
      children: [
        Container(
          width: OSpace.iconTile,
          height: OSpace.iconTile,
          decoration: BoxDecoration(
            color: c.surfaceAlt,
            borderRadius: BorderRadius.circular(ORadius.m),
          ),
          child: Icon(icon, size: 19, color: c.textMuted),
        ),
        const SizedBox(width: OSpace.m),
        Expanded(
          child: ExcludeSemantics(
            child: Text(
              text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: OType.body.copyWith(
                color: c.text,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ),
        if (trailing != null) ...[const SizedBox(width: OSpace.s), trailing!],
      ],
    );
    final row = ConstrainedBox(
      constraints: const BoxConstraints(minHeight: OSpace.listRow),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: OSpace.l,
          vertical: OSpace.m,
        ),
        child: content,
      ),
    );
    if (onTap == null) {
      return Semantics(label: label, child: row);
    }
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(ORadius.m),
        child: Semantics(
          label: label,
          hint: hint,
          button: true,
          enabled: !busy,
          child: row,
        ),
      ),
    );
  }
}

/// One compact failure row above the list. It stays inline so the row that
/// failed is still visible beside the reason.
class _InlineError extends StatelessWidget {
  const _InlineError({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    return Semantics(
      liveRegion: true,
      child: Container(
        key: const ValueKey<String>('memory-action-error'),
        padding: const EdgeInsets.all(OSpace.m),
        decoration: BoxDecoration(
          color: c.danger.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(ORadius.m),
          border: Border.all(color: c.danger.withValues(alpha: 0.40)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Icon(
                Icons.error_outline_rounded,
                size: 20,
                color: c.danger,
              ),
            ),
            const SizedBox(width: OSpace.s),
            Expanded(
              child: Text(
                message,
                style: OType.bodySm.copyWith(color: c.danger),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Editor sheet for one fact. Owns its controller so it is disposed with the
/// route, not while the sheet is still animating out.
///
/// The sheet only pops after [onSave] returns an entry: a failed save keeps
/// the editor open with the text the person typed and the reason above the
/// field, so nothing is lost and nothing is rolled back silently.
class _MemoryEditor extends StatefulWidget {
  const _MemoryEditor({
    required this.title,
    required this.initialText,
    required this.onSave,
  });

  final String title;
  final String initialText;
  final Future<V2MemoryEntry?> Function(String text) onSave;

  @override
  State<_MemoryEditor> createState() => _MemoryEditorState();
}

class _MemoryEditorState extends State<_MemoryEditor> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initialText,
  );
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _controller.selection = TextSelection.collapsed(
      offset: _controller.text.length,
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_saving) return;
    final text = _controller.text.trim();
    if (text.isEmpty) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final saved = await widget.onSave(text);
      if (!mounted) return;
      if (saved == null) {
        setState(() {
          _saving = false;
          _error = 'Could not save that memory.';
        });
        return;
      }
      Navigator.pop(context, saved);
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = 'Could not save that memory.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SafeArea(
        top: false,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * 0.9,
          ),
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(OSpace.l),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(widget.title, style: OType.h2.copyWith(color: c.text)),
                const SizedBox(height: OSpace.m),
                TextField(
                  key: const ValueKey<String>('memory-editor-field'),
                  controller: _controller,
                  autofocus: true,
                  minLines: 3,
                  maxLines: 6,
                  textCapitalization: TextCapitalization.sentences,
                  style: OType.bodySm.copyWith(color: c.text),
                  onChanged: (_) => setState(() {}),
                  decoration: InputDecoration(
                    hintText: 'What should Ovid remember?',
                    hintStyle: OType.bodySm.copyWith(color: c.textFaint),
                    filled: true,
                    fillColor: c.surfaceAlt,
                    contentPadding: const EdgeInsets.all(OSpace.m),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(ORadius.m),
                      borderSide: BorderSide(color: c.hairline),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(ORadius.m),
                      borderSide: BorderSide(color: c.hairline),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(ORadius.m),
                      borderSide: BorderSide(color: c.accentFill),
                    ),
                  ),
                ),
                if (_error != null) ...[
                  const SizedBox(height: OSpace.m),
                  _InlineError(message: _error!),
                ],
                const SizedBox(height: OSpace.m),
                Row(
                  children: [
                    Expanded(
                      child: OButton(
                        label: 'Cancel',
                        variant: OButtonVariant.secondary,
                        onPressed: _saving
                            ? null
                            : () => Navigator.pop(context),
                      ),
                    ),
                    const SizedBox(width: OSpace.s),
                    Expanded(
                      child: OButton(
                        key: const ValueKey<String>('memory-editor-save'),
                        label: 'Save',
                        icon: Icons.check_rounded,
                        loading: _saving,
                        onPressed: _saving || _controller.text.trim().isEmpty
                            ? null
                            : _save,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// One flattened memory row, whatever its scope.
class _MemoryRow {
  const _MemoryRow({
    required this.scope,
    required this.id,
    required this.text,
    required this.icon,
    this.hint,
    this.onTap,
  });

  final V2MemoryScope scope;
  final String id;
  final String text;
  final IconData icon;
  final String? hint;
  final VoidCallback? onTap;
}
