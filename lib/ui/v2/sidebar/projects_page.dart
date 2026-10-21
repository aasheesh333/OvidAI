import 'package:flutter/material.dart';

import '../../design/o_components.dart';
import '../../design/o_motion.dart';
import '../../design/o_tokens.dart';

// TODO(l10n): route all user-facing copy through the ARB pass.

enum V2ProjectsStatus { loading, content, error }

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
    required this.storageLabel,
    this.shared = false,
    this.memberInitials = const <String>[],
    this.updatedLabel = '',
    this.colorKey = 'violet',
  });

  final String id;
  final String name;
  final int chatCount;
  final String storageLabel;
  final bool shared;
  final List<String> memberInitials;
  final String updatedLabel;
  final String colorKey;

  String get chatLabel => chatCount == 1 ? '1 chat' : '$chatCount chats';
}

/// A draft produced by the New project sheet.
@immutable
class V2ProjectDraft {
  const V2ProjectDraft({required this.name, required this.colorKey});

  final String name;
  final String colorKey;
}

/// Projects list with a shared-memory explainer, filter and New project sheet.
class ProjectsPage extends StatefulWidget {
  const ProjectsPage({
    super.key,
    required this.data,
    this.onProjectTap,
    this.onProjectActions,
    this.onCreateProject,
    this.onRetry,
  });

  final V2ProjectsData data;
  final ValueChanged<V2Project>? onProjectTap;
  final ValueChanged<V2Project>? onProjectActions;
  final ValueChanged<V2ProjectDraft>? onCreateProject;
  final VoidCallback? onRetry;

  @override
  State<ProjectsPage> createState() => _ProjectsPageState();
}

class _ProjectsPageState extends State<ProjectsPage> {
  final _search = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  List<V2Project> get _visible {
    final query = _query.trim().toLowerCase();
    if (query.isEmpty) return widget.data.projects;
    return widget.data.projects
        .where((project) => project.name.toLowerCase().contains(query))
        .toList(growable: false);
  }

  /// Creation is only offered when the caller can persist the draft; otherwise
  /// the sheet would close as if a project had been made.
  bool get _canCreate => widget.onCreateProject != null;

  void _openNewProject() {
    final create = widget.onCreateProject;
    if (create == null) return;
    showOSheet<void>(
      context,
      title: 'New project',
      builder: (sheetContext) =>
          _NewProjectSheet(onCreate: (draft) => create(draft)),
    );
  }

  void _clearSearch() {
    _search.clear();
    setState(() => _query = '');
  }

  @override
  Widget build(BuildContext context) {
    return OScaffold(
      appBar: const OAppBar(title: 'Projects'),
      body: OFadeSlide(
        // The whole page scrolls so the filter, explainer and list still fit
        // when the text is scaled up on a narrow phone.
        child: CustomScrollView(
          slivers: [
            SliverPadding(
              padding: const EdgeInsets.symmetric(horizontal: OSpace.screen),
              sliver: SliverToBoxAdapter(child: _buildHeader(context)),
            ),
            ..._buildBodySlivers(context),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader(BuildContext context) {
    final c = OColors.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: OSpace.s),
        Row(
          children: [
            Expanded(
              child: OSearchField(
                key: const Key('v2-project-filter'),
                controller: _search,
                hint: 'Filter projects',
                onChanged: (value) => setState(() => _query = value),
              ),
            ),
            const SizedBox(width: OSpace.s),
            if (_canCreate)
              OButton(
                label: 'New',
                icon: Icons.add_rounded,
                onPressed: _openNewProject,
              ),
          ],
        ),
        const SizedBox(height: OSpace.l),
        OCard(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: c.accentSoft,
                  borderRadius: BorderRadius.circular(ORadius.m),
                ),
                child: Icon(
                  Icons.folder_special_rounded,
                  size: 24,
                  color: c.accent,
                ),
              ),
              const SizedBox(width: OSpace.m),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Shared project memory',
                      style: OType.bodyStrong.copyWith(color: c.text),
                    ),
                    const SizedBox(height: OSpace.xs),
                    Text(
                      'Group chats that share files and memory.',
                      style: OType.bodySm.copyWith(color: c.textMuted),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: OSpace.m),
      ],
    );
  }

  List<Widget> _buildBodySlivers(BuildContext context) {
    switch (widget.data.status) {
      case V2ProjectsStatus.loading:
        return const [
          SliverFillRemaining(
            hasScrollBody: true,
            child: OSkeletonList(rows: 4),
          ),
        ];
      case V2ProjectsStatus.error:
        return [
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
        if (widget.data.projects.isEmpty) {
          return [
            SliverFillRemaining(
              hasScrollBody: false,
              child: OEmptyState(
                icon: Icons.create_new_folder_outlined,
                title: 'No projects yet',
                message: 'Group chats that share files and memory.',
                action: _canCreate
                    ? OButton(
                        label: 'New project',
                        icon: Icons.add_rounded,
                        onPressed: _openNewProject,
                      )
                    : null,
              ),
            ),
          ];
        }
        final visible = _visible;
        if (visible.isEmpty) {
          return [
            SliverFillRemaining(
              hasScrollBody: false,
              child: OEmptyState(
                compact: true,
                icon: Icons.search_off_rounded,
                title: 'No projects match',
                message: 'Try a different name.',
                action: OButton(label: 'Clear search', onPressed: _clearSearch),
              ),
            ),
          ];
        }
        return [_buildListSliver(visible)];
    }
  }

  Widget _buildListSliver(List<V2Project> visible) {
    const staggeredRows = 8;
    Widget row(V2Project project) => Padding(
      padding: const EdgeInsets.only(bottom: OSpace.m),
      child: _ProjectCard(
        project: project,
        onTap: widget.onProjectTap,
        onActions: widget.onProjectActions,
      ),
    );
    return SliverPadding(
      padding: const EdgeInsets.symmetric(horizontal: OSpace.screen),
      sliver: SliverList(
        delegate: SliverChildBuilderDelegate(
          (context, index) {
            if (index == 0) {
              return OSectionHeader(
                label: 'Projects',
                trailing: OPill(
                  label: '${visible.length}',
                  tone: OPillTone.accent,
                ),
                padding: const EdgeInsets.fromLTRB(0, OSpace.s, 0, OSpace.s),
              );
            }
            final rowIndex = index - 1;
            if (rowIndex >= visible.length) {
              return const SizedBox(height: OSpace.xl);
            }
            final project = visible[rowIndex];
            // Only the first screenful animates; later rows are built lazily
            // as they scroll in, so they must not each start a timer.
            if (rowIndex >= staggeredRows) return row(project);
            final delay = OMotion.stagger * rowIndex;
            return OFadeSlide(
              delay: delay > const Duration(milliseconds: 400)
                  ? const Duration(milliseconds: 400)
                  : delay,
              child: row(project),
            );
          },
          childCount: visible.length + 2,
        ),
      ),
    );
  }
}

class _ProjectCard extends StatelessWidget {
  const _ProjectCard({required this.project, this.onTap, this.onActions});

  final V2Project project;
  final ValueChanged<V2Project>? onTap;
  final ValueChanged<V2Project>? onActions;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    final accent = _projectColor(c, project.colorKey);
    return OCard(
      padding: const EdgeInsets.all(OSpace.m),
      onTap: onTap == null ? null : () => onTap!(project),
      semanticLabel:
          '${project.name}, ${project.chatLabel}, ${project.storageLabel}'
          '${project.shared ? ', shared' : ''}',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: accent.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(ORadius.m),
                ),
                child: Icon(Icons.folder_rounded, size: 22, color: accent),
              ),
              const SizedBox(width: OSpace.m),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Wraps instead of overflowing when the name and pill no
                    // longer fit side by side at large text sizes.
                    Wrap(
                      spacing: OSpace.s,
                      runSpacing: OSpace.xs,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Text(
                          project.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: OType.bodyStrong.copyWith(color: c.text),
                        ),
                        OPill(
                          label: project.shared ? 'Shared' : 'Personal',
                          tone: project.shared
                              ? OPillTone.accent
                              : OPillTone.neutral,
                        ),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${project.chatLabel} · ${project.storageLabel}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: OType.caption.copyWith(color: c.textMuted),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: OSpace.xs),
              if (onActions != null)
                OIconButton(
                  icon: Icons.more_vert_rounded,
                  semanticLabel: 'Project options for ${project.name}',
                  size: 18,
                  onPressed: () => onActions!(project),
                ),
            ],
          ),
          const SizedBox(height: OSpace.m),
          Wrap(
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: OSpace.s,
            runSpacing: OSpace.xs,
            children: [
              _MemberStack(names: project.memberInitials, color: accent),
              if (project.updatedLabel.isNotEmpty)
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.sync_rounded, size: 14, color: c.textFaint),
                    const SizedBox(width: OSpace.xs),
                    Flexible(
                      child: Text(
                        project.updatedLabel,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: OType.caption.copyWith(color: c.textMuted),
                      ),
                    ),
                  ],
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _MemberStack extends StatelessWidget {
  const _MemberStack({required this.names, required this.color});

  final List<String> names;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    // Grow the circles with the text size so initials stay readable.
    final avatar = MediaQuery.textScalerOf(
      context,
    ).scale(28).clamp(28.0, 44.0).toDouble();
    final step = avatar * (20 / 28);
    if (names.isEmpty) {
      return Text(
        'Only you',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: OType.caption.copyWith(color: c.textFaint),
      );
    }
    final shown = names.take(3).toList(growable: false);
    final extra = names.length - shown.length;
    final width = avatar + (shown.length - 1) * step + (extra > 0 ? step : 0.0);
    return SizedBox(
      width: width,
      height: avatar,
      child: Stack(
        children: [
          for (var i = 0; i < shown.length; i++)
            Positioned(
              left: i * step,
              child: OAvatar(initials: shown[i], size: avatar),
            ),
          if (extra > 0)
            Positioned(
              left: shown.length * step,
              child: Container(
                width: avatar,
                height: avatar,
                decoration: BoxDecoration(
                  color: c.surfaceRaised,
                  shape: BoxShape.circle,
                  border: Border.all(color: c.surface, width: 2),
                ),
                alignment: Alignment.center,
                child: Text(
                  '+$extra',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: OType.caption.copyWith(color: c.textMuted),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _NewProjectSheet extends StatefulWidget {
  const _NewProjectSheet({required this.onCreate});

  final ValueChanged<V2ProjectDraft> onCreate;

  @override
  State<_NewProjectSheet> createState() => _NewProjectSheetState();
}

class _NewProjectSheetState extends State<_NewProjectSheet> {
  static const _colorChoices = <(String, String)>[
    ('violet', 'Violet'),
    ('purple', 'Purple'),
    ('emerald', 'Emerald'),
    ('amber', 'Amber'),
    ('coral', 'Coral'),
    ('slate', 'Slate'),
  ];

  final _name = TextEditingController();
  String _colorKey = 'violet';

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    final canCreate = _name.text.trim().isNotEmpty;
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(
        OSpace.l,
        OSpace.s,
        OSpace.l,
        OSpace.l,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            key: const Key('v2-project-name-field'),
            controller: _name,
            autofocus: true,
            maxLength: 40,
            textCapitalization: TextCapitalization.sentences,
            style: OType.bodySm.copyWith(color: c.text),
            onChanged: (_) => setState(() {}),
            decoration: const InputDecoration(
              labelText: 'Project name',
              hintText: 'e.g. Website redesign 2025',
            ),
          ),
          const SizedBox(height: OSpace.s),
          Text('Colour', style: OType.caption.copyWith(color: c.textMuted)),
          const SizedBox(height: OSpace.s),
          Wrap(
            spacing: OSpace.s,
            runSpacing: OSpace.s,
            children: [
              for (final choice in _colorChoices)
                OPressable(
                  key: ValueKey<String>('v2-project-color-${choice.$1}'),
                  onTap: () => setState(() => _colorKey = choice.$1),
                  semanticLabel:
                      '${choice.$2} colour'
                      '${_colorKey == choice.$1 ? ', selected' : ''}',
                  child: SizedBox(
                    width: OSpace.touch,
                    height: OSpace.touch,
                    child: Center(
                      child: Container(
                        width: 36,
                        height: 36,
                        decoration: BoxDecoration(
                          color: _projectColor(c, choice.$1),
                          shape: BoxShape.circle,
                          border: _colorKey == choice.$1
                              ? Border.all(color: c.text, width: 2)
                              : null,
                        ),
                        child: _colorKey == choice.$1
                            ? Icon(
                                Icons.check_rounded,
                                size: 18,
                                color: c.onAccent,
                              )
                            : null,
                      ),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: OSpace.l),
          Container(
            padding: const EdgeInsets.all(OSpace.m),
            decoration: BoxDecoration(
              color: c.surfaceAlt,
              borderRadius: BorderRadius.circular(ORadius.m),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.auto_awesome_rounded, size: 18, color: c.accent),
                const SizedBox(width: OSpace.s),
                Expanded(
                  child: Text(
                    'Chats in this project share files and memory.',
                    style: OType.caption.copyWith(color: c.textMuted),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: OSpace.l),
          OButton(
            key: const Key('v2-create-project'),
            label: 'Create project',
            icon: Icons.add_rounded,
            expand: true,
            onPressed: canCreate
                ? () {
                    final draft = V2ProjectDraft(
                      name: _name.text.trim(),
                      colorKey: _colorKey,
                    );
                    widget.onCreate(draft);
                    Navigator.of(context).pop();
                  }
                : null,
          ),
        ],
      ),
    );
  }
}

Color _projectColor(OColors c, String key) {
  return switch (key) {
    'purple' => c.accentFill,
    'emerald' => c.success,
    'amber' => c.warn,
    'coral' => c.danger,
    'slate' => c.textMuted,
    _ => c.accent,
  };
}
