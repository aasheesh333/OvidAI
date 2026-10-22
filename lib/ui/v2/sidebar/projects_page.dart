import 'package:flutter/material.dart';

import '../../design/o_components.dart';
import '../../design/o_motion.dart';
import '../../design/o_screen.dart';
import '../../design/o_tokens.dart';

// TODO(l10n): route all user-facing copy through the ARB pass.

enum V2ProjectsStatus { loading, content, error }

/// Client-side order for the projects list.
///
/// The gateway returns projects in creation order and never sorts; ordering at
/// most a few dozen rows is a view concern. The choice lives in page state and
/// is deliberately not persisted — a sort preference is not worth a write.
enum V2ProjectSort {
  recent('Recent'),
  name('Name'),
  chats('Chats');

  const V2ProjectSort(this.label);

  final String label;
}

/// Immutable view data for the Projects screen.
@immutable
class V2ProjectsData {
  const V2ProjectsData({
    this.projects = const <V2Project>[],
    this.status = V2ProjectsStatus.content,
    this.errorMessage,
  });

  final List<V2Project> projects;
  final V2ProjectsStatus status;
  final String? errorMessage;
}

@immutable
class V2Project {
  const V2Project({
    required this.id,
    required this.name,
    required this.chatCount,
    this.shared = false,
    this.updatedAt,
    // Transitional arguments: the shell still builds its snapshot with the
    // old card fields. Rows show only name, count and share state, so these
    // are accepted but never read. Drop them with the shell migration.
    String? storageLabel,
    List<String> memberInitials = const <String>[],
    String? updatedLabel,
    String? colorKey,
  });

  final String id;
  final String name;
  final int chatCount;
  final bool shared;

  /// Last write time from `GET /projects` (`updatedAt`). Only used to order
  /// the list; rows never render it. Null for snapshots without a timestamp,
  /// which sort after every dated project.
  final DateTime? updatedAt;

  String get chatLabel => chatCount == 1 ? '1 chat' : '$chatCount chats';

  V2Project copyWith({String? name}) => V2Project(
    id: id,
    name: name ?? this.name,
    chatCount: chatCount,
    shared: shared,
    updatedAt: updatedAt,
  );
}

/// A draft produced by the New project sheet.
@immutable
class V2ProjectDraft {
  const V2ProjectDraft({required this.name});

  final String name;
}

/// Result of a create, rename or delete write.
///
/// [error] is shown inline in the sheet (create/rename) or in a snackbar
/// (delete); a failed write is never silently swallowed.
@immutable
class V2ProjectMutation {
  const V2ProjectMutation.ok({this.project}) : error = null;

  const V2ProjectMutation.failed(String this.error) : project = null;

  final V2Project? project;
  final String? error;

  bool get ok => error == null;
}

typedef V2CreateProject =
    Future<V2ProjectMutation> Function(V2ProjectDraft draft);
typedef V2RenameProject =
    Future<V2ProjectMutation> Function(V2Project project, String name);
typedef V2DeleteProject = Future<V2ProjectMutation> Function(V2Project project);

/// Projects list: create, open, project memory, rename and delete.
///
/// The screen owns its visible list while it is open: the caller passes a
/// snapshot, and every successful write is applied locally so a create,
/// rename or delete is visible without waiting for the page to be reopened.
/// A failed write is rolled back to the previous list.
///
/// Ordering is a client-side view choice (recent, name, chats) held in page
/// state. The chip row only renders once there are enough projects for the
/// order to matter; below that it is noise.
class ProjectsPage extends StatefulWidget {
  const ProjectsPage({
    super.key,
    required this.data,
    this.onProjectTap,
    this.onProjectMemory,
    this.createProject,
    this.renameProject,
    this.deleteProject,
    this.onRetry,
    this.onProjectActions,
    this.onCreateProject,
  });

  final V2ProjectsData data;

  /// Opens the project (chats and its memory).
  final ValueChanged<V2Project>? onProjectTap;

  /// Opens the project's memory directly.
  final ValueChanged<V2Project>? onProjectMemory;

  /// Persisted create. Returns the stored project so the row can be inserted,
  /// or an error so the sheet can report it inline.
  final V2CreateProject? createProject;

  /// Persisted rename. Returns an error to keep the sheet open and roll the
  /// optimistic row name back.
  final V2RenameProject? renameProject;

  /// Persisted delete. Returns an error to restore the optimistically removed
  /// row.
  final V2DeleteProject? deleteProject;

  final VoidCallback? onRetry;

  /// Transitional hook for the current shell; prefer [renameProject],
  /// [deleteProject] and [onProjectMemory].
  final ValueChanged<V2Project>? onProjectActions;

  /// Transitional create hook for the current shell; prefer [createProject].
  final ValueChanged<V2ProjectDraft>? onCreateProject;

  @override
  State<ProjectsPage> createState() => _ProjectsPageState();
}

class _ProjectsPageState extends State<ProjectsPage> {
  /// A chip row is noise for a handful of rows: below this many projects the
  /// list keeps its default order and the control stays hidden.
  static const int _sortChipMinProjects = 4;

  late List<V2Project> _projects;
  V2ProjectSort _sort = V2ProjectSort.recent;

  @override
  void initState() {
    super.initState();
    _projects = List<V2Project>.of(widget.data.projects);
  }

  @override
  void didUpdateWidget(covariant ProjectsPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A caller that rebuilds with a fresh snapshot (a controller update) wins;
    // a plain rebuild with the same snapshot must not discard local writes.
    if (!identical(oldWidget.data.projects, widget.data.projects)) {
      _projects = List<V2Project>.of(widget.data.projects);
    }
  }

  void _selectSort(V2ProjectSort sort) {
    if (sort == _sort) return;
    setState(() => _sort = sort);
  }

  /// The visible order. Every comparator falls back to the name so the result
  /// is deterministic when two rows tie or carry no timestamp.
  List<V2Project> get _sortedProjects {
    final items = List<V2Project>.of(_projects);
    items.sort(switch (_sort) {
      V2ProjectSort.recent => _byRecent,
      V2ProjectSort.name => _byName,
      V2ProjectSort.chats => _byChats,
    });
    return items;
  }

  static int _byName(V2Project a, V2Project b) =>
      a.name.toLowerCase().compareTo(b.name.toLowerCase());

  static int _byRecent(V2Project a, V2Project b) {
    final aAt = a.updatedAt;
    final bAt = b.updatedAt;
    if (aAt != null && bAt != null) {
      final byTime = bAt.compareTo(aAt);
      if (byTime != 0) return byTime;
    } else if (aAt != null) {
      return -1;
    } else if (bAt != null) {
      return 1;
    }
    return _byName(a, b);
  }

  static int _byChats(V2Project a, V2Project b) {
    final byCount = b.chatCount.compareTo(a.chatCount);
    return byCount != 0 ? byCount : _byName(a, b);
  }

  bool get _canCreate =>
      widget.createProject != null || widget.onCreateProject != null;

  bool get _hasActions =>
      widget.onProjectActions != null ||
      widget.onProjectMemory != null ||
      widget.renameProject != null ||
      widget.deleteProject != null;

  List<String> _names({String? exceptId}) => <String>[
    for (final project in _projects)
      if (project.id != exceptId) project.name,
  ];

  void _openNewProject() {
    if (!_canCreate) return;
    showOSheet<void>(
      context,
      title: 'New project',
      builder: (sheetContext) => _ProjectNameSheet(
        existingNames: _names(),
        submitLabel: 'Create project',
        submitKey: const Key('v2-create-project'),
        onSubmit: _createProject,
      ),
    );
  }

  Future<String?> _createProject(String name) async {
    final create = widget.createProject;
    if (create != null) {
      try {
        final result = await create(V2ProjectDraft(name: name));
        if (!mounted) return null;
        final project = result.project;
        if (!result.ok || project == null) {
          return result.error ?? 'Could not create project.';
        }
        setState(() {
          _projects = <V2Project>[
            for (final existing in _projects)
              if (existing.id != project.id) existing,
            project,
          ];
        });
        return null;
      } catch (_) {
        return 'Could not create project.';
      }
    }
    final legacy = widget.onCreateProject;
    if (legacy == null) return 'Could not create project.';
    try {
      await Future<void>.sync(() => legacy(V2ProjectDraft(name: name)));
      return null;
    } catch (_) {
      return 'Could not create project.';
    }
  }

  Future<void> _openProjectMenu(V2Project project) async {
    final memory = widget.onProjectMemory;
    final rename = widget.renameProject;
    final delete = widget.deleteProject;
    if (memory == null && rename == null && delete == null) {
      widget.onProjectActions?.call(project);
      return;
    }
    final action = await showOSheet<String>(
      context,
      title: project.name,
      builder: (sheetContext) => SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(OSpace.s, 0, OSpace.s, OSpace.l),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (memory != null)
              _MenuRow(
                icon: Icons.psychology_outlined,
                label: 'Project memory',
                semanticLabel: 'Project memory for ${project.name}',
                onTap: () => Navigator.of(sheetContext).pop('memory'),
              ),
            if (rename != null)
              _MenuRow(
                icon: Icons.edit_outlined,
                label: 'Rename',
                semanticLabel: 'Rename ${project.name}',
                onTap: () => Navigator.of(sheetContext).pop('rename'),
              ),
            if (delete != null)
              _MenuRow(
                icon: Icons.delete_outline_rounded,
                label: 'Delete project',
                semanticLabel: 'Delete ${project.name}, destructive',
                danger: true,
                onTap: () => Navigator.of(sheetContext).pop('delete'),
              ),
          ],
        ),
      ),
    );
    if (!mounted || action == null) return;
    switch (action) {
      case 'memory':
        widget.onProjectMemory?.call(project);
      case 'rename':
        await _openRename(project);
      case 'delete':
        await _confirmDelete(project);
    }
  }

  Future<void> _openRename(V2Project project) async {
    if (widget.renameProject == null) return;
    await showOSheet<void>(
      context,
      title: 'Rename project',
      builder: (sheetContext) => _ProjectNameSheet(
        initialName: project.name,
        existingNames: _names(exceptId: project.id),
        submitLabel: 'Save',
        submitKey: const Key('v2-rename-project'),
        onSubmit: (name) => _renameProject(project, name),
      ),
    );
  }

  Future<String?> _renameProject(V2Project project, String name) async {
    final rename = widget.renameProject;
    if (rename == null) return 'Could not rename project.';
    final previous = _projects;
    setState(() {
      _projects = <V2Project>[
        for (final existing in _projects)
          existing.id == project.id ? existing.copyWith(name: name) : existing,
      ];
    });
    try {
      final result = await rename(project, name);
      if (!mounted) return null;
      if (!result.ok) {
        setState(() => _projects = previous);
        return result.error ?? 'Could not rename project.';
      }
      return null;
    } catch (_) {
      if (mounted) setState(() => _projects = previous);
      return 'Could not rename project.';
    }
  }

  Future<void> _confirmDelete(V2Project project) async {
    if (widget.deleteProject == null) return;
    final confirmed = await showOSheet<bool>(
      context,
      title: 'Delete project?',
      builder: (sheetContext) {
        final c = OColors.of(sheetContext);
        return SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(OSpace.l, 0, OSpace.l, OSpace.l),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                '"${project.name}" and its memory will be removed. '
                'Chats stay.',
                style: OType.bodySm.copyWith(color: c.textMuted),
              ),
              const SizedBox(height: OSpace.l),
              OButton(
                key: const Key('v2-delete-project-confirm'),
                label: 'Delete project',
                semanticLabel: 'Delete ${project.name}, destructive',
                icon: Icons.delete_outline_rounded,
                variant: OButtonVariant.dangerFill,
                expand: true,
                onPressed: () => Navigator.of(sheetContext).pop(true),
              ),
              const SizedBox(height: OSpace.s),
              OButton(
                label: 'Keep project',
                variant: OButtonVariant.secondary,
                expand: true,
                onPressed: () => Navigator.of(sheetContext).pop(false),
              ),
            ],
          ),
        );
      },
    );
    if (confirmed != true || !mounted) return;
    final index = _projects.indexWhere((item) => item.id == project.id);
    if (index < 0) return;
    final delete = widget.deleteProject;
    if (delete == null) return;
    final previous = _projects;
    setState(() {
      _projects = List<V2Project>.of(_projects)..removeAt(index);
    });
    try {
      final result = await delete(project);
      if (!mounted) return;
      if (!result.ok) {
        setState(() => _projects = previous);
        showOSnack(context, result.error ?? 'Could not delete project.');
      }
    } catch (_) {
      if (!mounted) return;
      setState(() => _projects = previous);
      showOSnack(context, 'Could not delete project.');
    }
  }

  @override
  Widget build(BuildContext context) {
    final showContent =
        widget.data.status == V2ProjectsStatus.content && _projects.isNotEmpty;
    return OScreen(
      title: 'Projects',
      actions: [
        if (_canCreate && showContent)
          OIconButton(
            key: const Key('v2-new-project'),
            icon: Icons.add_rounded,
            semanticLabel: 'New project',
            onPressed: _openNewProject,
          ),
      ],
      child: OFadeSlide(
        child: CustomScrollView(
          key: const Key('v2-projects-scroll'),
          slivers: _buildSlivers(context),
        ),
      ),
    );
  }

  List<Widget> _buildSlivers(BuildContext context) {
    switch (widget.data.status) {
      case V2ProjectsStatus.loading:
        return const <Widget>[
          SliverFillRemaining(
            hasScrollBody: true,
            child: OSkeletonList(rows: 4),
          ),
        ];
      case V2ProjectsStatus.error:
        return <Widget>[
          SliverFillRemaining(
            hasScrollBody: false,
            child: OErrorState(
              title: 'Projects did not load',
              message:
                  widget.data.errorMessage ??
                  'Check your connection and try again.',
              onRetry: widget.onRetry,
            ),
          ),
        ];
      case V2ProjectsStatus.content:
        if (_projects.isEmpty) {
          return <Widget>[
            SliverFillRemaining(
              hasScrollBody: false,
              child: OEmptyState(
                icon: Icons.create_new_folder_outlined,
                title: 'No projects',
                message: 'Create a project to group chats and memory.',
                action: _canCreate
                    ? OButton(
                        key: const Key('v2-empty-new-project'),
                        label: 'New project',
                        icon: Icons.add_rounded,
                        onPressed: _openNewProject,
                      )
                    : null,
              ),
            ),
          ];
        }
        final projects = _sortedProjects;
        return <Widget>[
          if (_projects.length >= _sortChipMinProjects)
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(
                OSpace.s,
                OSpace.s,
                OSpace.s,
                0,
              ),
              sliver: SliverToBoxAdapter(
                child: Wrap(
                  spacing: OSpace.s,
                  runSpacing: OSpace.s,
                  children: [
                    for (final sort in V2ProjectSort.values)
                      _SortChip(
                        key: ValueKey<String>(
                          'v2-projects-sort-${sort.label.toLowerCase()}',
                        ),
                        label: sort.label,
                        selected: _sort == sort,
                        onTap: () => _selectSort(sort),
                      ),
                  ],
                ),
              ),
            ),
          SliverPadding(
            padding: const EdgeInsets.only(top: OSpace.s, bottom: OSpace.xl),
            sliver: SliverList.builder(
              itemCount: projects.length,
              itemBuilder: (context, index) {
                final project = projects[index];
                return _ProjectRow(
                  key: ValueKey<String>('v2-project-${project.id}'),
                  project: project,
                  showDivider: index < projects.length - 1,
                  onTap: widget.onProjectTap == null
                      ? null
                      : () => widget.onProjectTap!(project),
                  onMenu: _hasActions ? () => _openProjectMenu(project) : null,
                );
              },
            ),
          ),
        ];
    }
  }
}

/// One member of the sort radio group.
///
/// The visible [OChip] is excluded from semantics so the chip publishes exactly
/// one node: label, button, and the selected flag that makes TalkBack say
/// "Recent, selected". [Semantics.inMutuallyExclusiveGroup] marks it as a radio
/// member rather than a toggle.
class _SortChip extends StatelessWidget {
  const _SortChip({
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
    return Semantics(
      label: label,
      button: true,
      enabled: true,
      selected: selected,
      inMutuallyExclusiveGroup: true,
      onTap: onTap,
      child: ExcludeSemantics(
        child: OChip(label: label, selected: selected, onTap: onTap),
      ),
    );
  }
}

class _ProjectRow extends StatelessWidget {
  const _ProjectRow({
    super.key,
    required this.project,
    required this.showDivider,
    this.onTap,
    this.onMenu,
  });

  final V2Project project;
  final bool showDivider;
  final VoidCallback? onTap;
  final VoidCallback? onMenu;

  String get _semanticLabel =>
      '${project.name}, ${project.chatLabel}'
      '${project.shared ? ', shared' : ''}';

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    final row = ConstrainedBox(
      constraints: const BoxConstraints(minHeight: OSpace.listRow),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: OSpace.s,
          vertical: OSpace.s,
        ),
        child: LayoutBuilder(
          builder: (context, constraints) {
            // At a phone width the full "12 chats" line and the Shared pill do
            // not leave a usable name, and at a large text scale they no longer
            // fit at all. Keep the row one line: show a compact count and a
            // shared glyph instead of letting any child overflow its box.
            final scaled = MediaQuery.textScalerOf(context).scale(14);
            final compact =
                constraints.maxWidth < 340 ||
                (scaled > 20 && constraints.maxWidth < 380);
            return Row(
              children: [
                Expanded(
                  child: ExcludeSemantics(
                    child: Row(
                      children: [
                        Flexible(
                          child: Text(
                            project.name,
                            key: ValueKey<String>(
                              'v2-project-name-${project.id}',
                            ),
                            maxLines: 1,
                            softWrap: false,
                            overflow: TextOverflow.ellipsis,
                            style: OType.bodySm.copyWith(
                              color: c.text,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                        if (project.shared) ...[
                          const SizedBox(width: OSpace.s),
                          if (compact)
                            Icon(Icons.group_rounded, size: 16, color: c.accent)
                          else
                            const OPill(
                              label: 'Shared',
                              tone: OPillTone.accent,
                            ),
                        ],
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: OSpace.s),
                ExcludeSemantics(
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (compact) ...[
                        Icon(
                          Icons.chat_bubble_outline_rounded,
                          size: 14,
                          color: c.textMuted,
                        ),
                        const SizedBox(width: OSpace.xs),
                        Text(
                          '${project.chatCount}',
                          maxLines: 1,
                          style: OType.caption.copyWith(color: c.textMuted),
                        ),
                      ] else
                        Text(
                          project.chatLabel,
                          maxLines: 1,
                          softWrap: false,
                          overflow: TextOverflow.ellipsis,
                          style: OType.caption.copyWith(color: c.textMuted),
                        ),
                    ],
                  ),
                ),
                if (onMenu != null) ...[
                  const SizedBox(width: OSpace.xs),
                  OIconButton(
                    key: ValueKey<String>('v2-project-menu-${project.id}'),
                    icon: Icons.more_vert_rounded,
                    semanticLabel: 'Project options for ${project.name}',
                    size: 18,
                    onPressed: onMenu,
                  ),
                ],
              ],
            );
          },
        ),
      ),
    );

    final content = onTap == null
        ? Semantics(
            label: _semanticLabel,
            container: true,
            explicitChildNodes: true,
            child: row,
          )
        : OPressable(onTap: onTap, semanticLabel: _semanticLabel, child: row);

    return Container(
      decoration: showDivider
          ? BoxDecoration(
              border: Border(bottom: BorderSide(color: c.hairline)),
            )
          : null,
      child: content,
    );
  }
}

class _MenuRow extends StatelessWidget {
  const _MenuRow({
    required this.icon,
    required this.label,
    required this.semanticLabel,
    required this.onTap,
    this.danger = false,
  });

  final IconData icon;
  final String label;
  final String semanticLabel;
  final VoidCallback onTap;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: semanticLabel,
      button: true,
      enabled: true,
      container: true,
      onTap: onTap,
      child: ExcludeSemantics(
        child: OListRow(
          title: label,
          icon: icon,
          danger: danger,
          showChevron: false,
          onTap: onTap,
        ),
      ),
    );
  }
}

class _ProjectNameSheet extends StatefulWidget {
  const _ProjectNameSheet({
    required this.existingNames,
    required this.submitLabel,
    required this.submitKey,
    required this.onSubmit,
    this.initialName = '',
  });

  final List<String> existingNames;
  final String initialName;
  final String submitLabel;
  final Key submitKey;

  /// Returns an error to show inline, or null when the write succeeded and
  /// the sheet can close.
  final Future<String?> Function(String name) onSubmit;

  @override
  State<_ProjectNameSheet> createState() => _ProjectNameSheetState();
}

class _ProjectNameSheetState extends State<_ProjectNameSheet> {
  late final TextEditingController _name;
  String? _fieldError;
  String? _saveError;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _name = TextEditingController(text: widget.initialName);
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  bool get _canSubmit => !_saving && _name.text.trim().isNotEmpty;

  void _onChanged(String _) {
    setState(() {
      _fieldError = null;
      _saveError = null;
    });
  }

  Future<void> _submit() async {
    if (_saving) return;
    final name = _name.text.trim();
    if (name.isEmpty) {
      setState(() => _fieldError = 'Enter a project name.');
      return;
    }
    if (name.length > 80) {
      setState(() => _fieldError = 'Keep it under 80 characters.');
      return;
    }
    final lower = name.toLowerCase();
    if (widget.existingNames.any(
      (other) => other.trim().toLowerCase() == lower,
    )) {
      setState(() => _fieldError = 'That name is already in use.');
      return;
    }
    setState(() {
      _saving = true;
      _fieldError = null;
      _saveError = null;
    });
    String? error;
    try {
      error = await widget.onSubmit(name);
    } catch (_) {
      error = 'Could not save project.';
    }
    if (!mounted) return;
    if (error == null) {
      Navigator.of(context).pop();
      return;
    }
    setState(() {
      _saving = false;
      _saveError = error;
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(OSpace.l, 0, OSpace.l, OSpace.l),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            key: const Key('v2-project-name-field'),
            controller: _name,
            autofocus: true,
            textCapitalization: TextCapitalization.sentences,
            textInputAction: TextInputAction.done,
            style: OType.bodySm.copyWith(color: c.text),
            onChanged: _onChanged,
            onSubmitted: (_) => _submit(),
            decoration: InputDecoration(
              labelText: 'Project name',
              errorText: _fieldError,
            ),
          ),
          if (_saveError != null) ...[
            const SizedBox(height: OSpace.s),
            Semantics(
              liveRegion: true,
              child: Text(
                _saveError!,
                key: const Key('v2-project-save-error'),
                style: OType.bodySm.copyWith(color: c.danger),
              ),
            ),
          ],
          const SizedBox(height: OSpace.l),
          OButton(
            key: widget.submitKey,
            label: widget.submitLabel,
            loading: _saving,
            expand: true,
            onPressed: _canSubmit ? _submit : null,
          ),
        ],
      ),
    );
  }
}
