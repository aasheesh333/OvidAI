import 'package:flutter/material.dart';

import '../../design/o_components.dart';
import '../../design/o_motion.dart';
import '../../design/o_tokens.dart';
import 'project_detail_page.dart';
import 'sidebar_footer.dart';

// TODO(l10n): route all user-facing copy through the ARB pass.

enum V2SidebarStatus { loading, content, error }

/// Immutable view data for the navigation drawer.
@immutable
class V2SidebarData {
  const V2SidebarData({
    required this.name,
    this.initials,
    this.planLabel = 'Free plan',
    this.pinned = const <V2SidebarSession>[],
    this.projects = const <V2SidebarProject>[],
    this.today = const <V2SidebarSession>[],
    this.yesterday = const <V2SidebarSession>[],
    this.earlier = const <V2SidebarSession>[],
    this.scheduleNextRun,
    this.status = V2SidebarStatus.content,
    this.errorMessage,
  });

  final String name;
  final String? initials;
  final String planLabel;
  final List<V2SidebarSession> pinned;
  final List<V2SidebarProject> projects;
  final List<V2SidebarSession> today;
  final List<V2SidebarSession> yesterday;
  final List<V2SidebarSession> earlier;

  /// Short "next run" line under the Schedule footer item, e.g.
  /// "Next run 9:00 AM". Omitted when null or empty.
  final String? scheduleNextRun;
  final V2SidebarStatus status;
  final String? errorMessage;

  bool get isEmpty =>
      pinned.isEmpty &&
      projects.isEmpty &&
      today.isEmpty &&
      yesterday.isEmpty &&
      earlier.isEmpty;
}

@immutable
class V2SidebarSession {
  const V2SidebarSession({
    required this.id,
    required this.title,
    required this.modelLabel,
    this.timeLabel = '',
    this.pinned = false,
    this.projectName,
  });

  final String id;
  final String title;
  final String modelLabel;
  final String timeLabel;
  final bool pinned;

  /// Project the chat belongs to, when it has one.
  final String? projectName;

  String get meta {
    final parts = <String>[
      if (modelLabel.isNotEmpty) modelLabel,
      if (timeLabel.isNotEmpty) timeLabel,
    ];
    return parts.join(' · ');
  }
}

@immutable
class V2SidebarProject {
  const V2SidebarProject({
    required this.id,
    required this.name,
    required this.chatCount,
    this.memoryFileCount = 0,
    this.detail,
  });

  final String id;
  final String name;
  final int chatCount;

  /// Number of memory files the project keeps.
  final int memoryFileCount;

  /// Detail payload for the memory sheet. When supplied, tapping the memory
  /// chip opens the sheet without the caller wiring another callback.
  final V2ProjectDetailData? detail;

  String get chatLabel => chatCount == 1 ? '1 chat' : '$chatCount chats';

  String get memoryLabel => switch (memoryFileCount) {
    0 => 'No memory',
    1 => '1 file',
    final count => '$count files',
  };

  String get memorySemanticLabel => switch (memoryFileCount) {
    0 => 'No memory files',
    1 => '1 memory file',
    final count => '$count memory files',
  };
}

/// The navigation drawer: profile, quick actions, pinned chats, projects and
/// the day's chats. All state arrives through [data]; all actions leave through
/// callbacks.
class Sidebar extends StatefulWidget {
  const Sidebar({
    super.key,
    required this.data,
    this.onProfile,
    this.onNewChat,
    this.onNewProject,
    this.onProjectTap,
    this.onProjectMemory,
    this.onSessionTap,
    this.onSessionActions,
    this.onSessionDelete,
    this.onSessionLongPress,
    this.onSchedule,
    this.onArtifacts,
    this.onSettings,
    this.onRetry,
  });

  final V2SidebarData data;
  final VoidCallback? onProfile;
  final VoidCallback? onNewChat;
  final VoidCallback? onNewProject;
  final ValueChanged<V2SidebarProject>? onProjectTap;

  /// Fired when the memory chip on a project row is tapped. When null and the
  /// project carries [V2SidebarProject.detail], the detail sheet opens inline.
  final ValueChanged<V2SidebarProject>? onProjectMemory;
  final ValueChanged<V2SidebarSession>? onSessionTap;

  /// Fired by the three-dot control and, when [onSessionLongPress] is null,
  /// by a long press on the row.
  final ValueChanged<V2SidebarSession>? onSessionActions;

  /// Fired by the inline delete control on a chat row.
  final ValueChanged<V2SidebarSession>? onSessionDelete;
  final ValueChanged<V2SidebarSession>? onSessionLongPress;
  final VoidCallback? onSchedule;
  final VoidCallback? onArtifacts;
  final VoidCallback? onSettings;
  final VoidCallback? onRetry;

  @override
  State<Sidebar> createState() => _SidebarState();
}

class _SidebarState extends State<Sidebar> {
  final _search = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Sidebar get _w => widget;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    return Align(
      alignment: Alignment.topLeft,
      child: SizedBox(
        width: 340,
        child: Material(
          color: c.surface,
          child: SafeArea(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _ProfileHeader(data: _w.data, onTap: _w.onProfile),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: OSpace.m),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      OButton(
                        label: 'New session',
                        icon: Icons.add_rounded,
                        expand: true,
                        onPressed: _w.onNewChat,
                      ),
                      const SizedBox(height: OSpace.s),
                      OSearchField(
                        controller: _search,
                        hint: 'Search',
                        onChanged: (value) =>
                            setState(() => _query = value.trim()),
                        trailing: _query.isEmpty
                            ? null
                            : OIconButton(
                                icon: Icons.close_rounded,
                                semanticLabel: 'Clear search',
                                tooltip: 'Clear search',
                                onPressed: () {
                                  _search.clear();
                                  setState(() => _query = '');
                                },
                              ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: OSpace.xs),
                Expanded(child: _buildBody(context)),
                SidebarFooter(
                  onSchedule: _w.onSchedule,
                  onArtifacts: _w.onArtifacts,
                  onSettings: _w.onSettings,
                  scheduleNextRun: _w.data.scheduleNextRun,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildBody(BuildContext context) {
    if (_w.data.status == V2SidebarStatus.loading) {
      return const OSkeletonList(rows: 5);
    }
    if (_w.data.status == V2SidebarStatus.error) {
      return OErrorState(
        title: 'Chats did not load',
        message:
            _w.data.errorMessage ?? 'Check your connection and try again.',
        onRetry: _w.onRetry,
      );
    }
    if (_query.isNotEmpty) return _searchResults(context);
    if (_w.data.isEmpty) {
      return OEmptyState(
        compact: true,
        icon: Icons.chat_bubble_outline_rounded,
        title: 'No chats yet',
        message: 'Start a new session and it will show up here.',
        action: OButton(
          label: 'New session',
          icon: Icons.add_rounded,
          onPressed: _w.onNewChat,
        ),
      );
    }

    final data = _w.data;
    return OFadeSlide(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(OSpace.m, 0, OSpace.m, OSpace.m),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (data.pinned.isNotEmpty)
              _Section(
                label: 'Pinned',
                children: [
                  for (final session in data.pinned) _sessionRow(session),
                ],
              ),
            if (data.projects.isNotEmpty)
              _Section(
                label: 'Projects',
                headerTrailing: OIconButton(
                  icon: Icons.add_rounded,
                  semanticLabel: 'New project',
                  size: 18,
                  onPressed: _w.onNewProject,
                ),
                children: [
                  for (final project in data.projects)
                    _ProjectRow(
                      project: project,
                      onTap: _w.onProjectTap,
                      onMemory: _w.onProjectMemory,
                    ),
                ],
              ),
            if (data.today.isNotEmpty)
              _Section(
                label: 'Today',
                children: [
                  for (final session in data.today) _sessionRow(session),
                ],
              ),
            if (data.yesterday.isNotEmpty)
              _Section(
                label: 'Yesterday',
                children: [
                  for (final session in data.yesterday) _sessionRow(session),
                ],
              ),
            if (data.earlier.isNotEmpty)
              _Section(
                label: 'Earlier',
                children: [
                  for (final session in data.earlier) _sessionRow(session),
                ],
              ),
          ],
        ),
      ),
    );
  }

  Widget _sessionRow(V2SidebarSession session) => _SessionRow(
    session: session,
    onTap: _w.onSessionTap,
    onActions: _w.onSessionActions,
    onDelete: _w.onSessionDelete,
    onLongPress: _w.onSessionLongPress,
  );

  /// Inline search: every chat and project in the drawer index, filtered by
  /// title. No second screen — the drawer is where the user already is.
  Widget _searchResults(BuildContext context) {
    final query = _query.toLowerCase();
    final data = _w.data;
    final seen = <String>{};
    final sessions = <V2SidebarSession>[
      for (final session in <V2SidebarSession>[
        ...data.pinned,
        ...data.today,
        ...data.yesterday,
        ...data.earlier,
      ])
        if (seen.add(session.id) && session.title.toLowerCase().contains(query))
          session,
    ];
    final projects = <V2SidebarProject>[
      for (final project in data.projects)
        if (project.name.toLowerCase().contains(query)) project,
    ];

    if (sessions.isEmpty && projects.isEmpty) {
      return OEmptyState(
        compact: true,
        icon: Icons.search_off_rounded,
        title: 'No matches',
        message: 'Try a different word from the chat title or project name.',
        action: OButton(
          label: 'Clear search',
          variant: OButtonVariant.ghost,
          onPressed: () {
            _search.clear();
            setState(() => _query = '');
          },
        ),
      );
    }

    return OFadeSlide(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(OSpace.m, 0, OSpace.m, OSpace.m),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (sessions.isNotEmpty)
              _Section(
                label: sessions.length == 1
                    ? '1 chat'
                    : '${sessions.length} chats',
                children: [
                  for (final session in sessions) _sessionRow(session),
                ],
              ),
            if (projects.isNotEmpty)
              _Section(
                label: projects.length == 1
                    ? '1 project'
                    : '${projects.length} projects',
                children: [
                  for (final project in projects)
                    _ProjectRow(
                      project: project,
                      onTap: _w.onProjectTap,
                      onMemory: _w.onProjectMemory,
                    ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}

class _ProfileHeader extends StatelessWidget {
  const _ProfileHeader({required this.data, this.onTap});

  final V2SidebarData data;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    return Padding(
      padding: const EdgeInsets.all(OSpace.m),
      child: OPressable(
        onTap: onTap,
        semanticLabel: 'Profile, ${data.name}, ${data.planLabel}',
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: OSpace.listRow),
          child: Padding(
            padding: const EdgeInsets.all(OSpace.s),
            child: Row(
              children: [
                Stack(
                  clipBehavior: Clip.none,
                  children: [
                    OAvatar(
                      initials: data.initials ?? data.name,
                      size: 40,
                      semanticLabel: data.name,
                    ),
                    Positioned(
                      right: 0,
                      bottom: 0,
                      child: Container(
                        width: 10,
                        height: 10,
                        decoration: BoxDecoration(
                          color: c.success,
                          shape: BoxShape.circle,
                          border: Border.all(color: c.surface, width: 2),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(width: OSpace.m),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        data.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: OType.bodyStrong.copyWith(color: c.text),
                      ),
                      const SizedBox(height: OSpace.xs),
                      _PlanPill(label: data.planLabel),
                    ],
                  ),
                ),
                Icon(Icons.expand_more_rounded, size: 20, color: c.textMuted),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _PlanPill extends StatelessWidget {
  const _PlanPill({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    return Container(
      constraints: const BoxConstraints(minHeight: 24),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
      decoration: BoxDecoration(
        color: c.accentSoft,
        borderRadius: BorderRadius.circular(ORadius.pill),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: OType.caption.copyWith(
                color: c.accent,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({
    required this.label,
    required this.children,
    this.headerTrailing,
  });

  final String label;
  final List<Widget> children;
  final Widget? headerTrailing;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        OSectionHeader(
          label: label,
          trailing: headerTrailing,
          padding: const EdgeInsets.fromLTRB(
            OSpace.s,
            OSpace.l,
            OSpace.s,
            OSpace.xs,
          ),
        ),
        OStagger(children: children),
      ],
    );
  }
}

class _SessionRow extends StatelessWidget {
  const _SessionRow({
    required this.session,
    this.onTap,
    this.onActions,
    this.onDelete,
    this.onLongPress,
  });

  final V2SidebarSession session;
  final ValueChanged<V2SidebarSession>? onTap;
  final ValueChanged<V2SidebarSession>? onActions;
  final ValueChanged<V2SidebarSession>? onDelete;
  final ValueChanged<V2SidebarSession>? onLongPress;

  String get _semanticLabel {
    final parts = <String>[
      session.title,
      if (session.projectName != null && session.projectName!.isNotEmpty)
        session.projectName!,
      if (session.pinned) 'Pinned',
      if (session.meta.isNotEmpty) session.meta,
    ];
    return parts.join(', ');
  }

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    final longPress = onLongPress ?? onActions;
    final projectName = session.projectName;
    return Row(
      children: [
        Expanded(
          child: OPressable(
            onTap: onTap == null ? null : () => onTap!(session),
            onLongPress: longPress == null ? null : () => longPress(session),
            semanticLabel: _semanticLabel,
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: OSpace.listRow),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: OSpace.s,
                  vertical: OSpace.s,
                ),
                child: Row(
                  children: [
                    if (session.pinned) ...[
                      Icon(
                        Icons.push_pin_rounded,
                        key: ValueKey<String>('v2-session-pin-${session.id}'),
                        size: 18,
                        color: c.accent,
                      ),
                      const SizedBox(width: OSpace.s),
                    ],
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            session.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: OType.bodySm.copyWith(
                              color: c.text,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                          if (projectName != null &&
                              projectName.isNotEmpty) ...[
                            const SizedBox(height: 2),
                            Row(
                              children: [
                                Icon(
                                  Icons.folder_rounded,
                                  size: 13,
                                  color: c.textFaint,
                                ),
                                const SizedBox(width: OSpace.xs),
                                Flexible(
                                  child: Text(
                                    projectName,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: OType.caption.copyWith(
                                      color: c.textMuted,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ],
                          if (session.meta.isNotEmpty) ...[
                            const SizedBox(height: 2),
                            Text(
                              session.meta,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: OType.caption.copyWith(color: c.textMuted),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        if (onDelete != null)
          OIconButton(
            icon: Icons.delete_outline_rounded,
            semanticLabel: 'Delete chat ${session.title}',
            size: 18,
            onPressed: () => onDelete!(session),
          ),
        OIconButton(
          icon: Icons.more_vert_rounded,
          semanticLabel: 'Chat options for ${session.title}',
          size: 18,
          onPressed: onActions == null ? null : () => onActions!(session),
        ),
      ],
    );
  }
}

class _ProjectRow extends StatelessWidget {
  const _ProjectRow({required this.project, this.onTap, this.onMemory});

  final V2SidebarProject project;
  final ValueChanged<V2SidebarProject>? onTap;
  final ValueChanged<V2SidebarProject>? onMemory;

  void _openMemory(BuildContext context) {
    if (onMemory != null) {
      onMemory!(project);
      return;
    }
    final detail = project.detail;
    if (detail != null) showProjectDetailSheet(context, data: detail);
  }

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    final canOpenMemory = onMemory != null || project.detail != null;
    return OPressable(
      onTap: onTap == null ? null : () => onTap!(project),
      semanticLabel:
          '${project.name}, ${project.chatLabel}, ${project.memorySemanticLabel}',
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: OSpace.listRow),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: OSpace.s,
            vertical: OSpace.s,
          ),
          child: Row(
            children: [
              Icon(Icons.folder_rounded, size: 20, color: c.accent),
              const SizedBox(width: OSpace.s),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      project.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: OType.bodySm.copyWith(
                        color: c.text,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    const SizedBox(height: 2),
                    _MemoryChip(
                      project: project,
                      onTap: canOpenMemory ? () => _openMemory(context) : null,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: OSpace.s),
              Text(
                project.chatLabel,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: OType.caption.copyWith(color: c.textFaint),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Small "memory files" affordance under a project name. Grows with the text
/// scale so the count is never clipped at 200 %.
class _MemoryChip extends StatelessWidget {
  const _MemoryChip({required this.project, this.onTap});

  final V2SidebarProject project;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    final hasMemory = project.memoryFileCount > 0;
    final fg = hasMemory ? c.accent : c.textFaint;
    return OPressable(
      onTap: onTap,
      semanticLabel:
          'Memory for ${project.name}, ${project.memorySemanticLabel}',
      child: Container(
        constraints: const BoxConstraints(minHeight: 22),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        decoration: BoxDecoration(
          color: hasMemory ? c.accentSoft : c.surfaceAlt,
          borderRadius: BorderRadius.circular(ORadius.pill),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.memory_rounded, size: 13, color: fg),
            const SizedBox(width: OSpace.xs),
            Flexible(
              child: Text(
                project.memoryLabel,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: OType.caption.copyWith(
                  color: fg,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
