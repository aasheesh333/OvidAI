import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;

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
                      // Search filters the drawer index, so it only exists when
                      // there is an index to filter. Showing it over the
                      // loading or error state would be a field that ignores
                      // every keystroke.
                      if (_w.data.status == V2SidebarStatus.content) ...[
                        const SizedBox(height: OSpace.s),
                        OSearchField(
                          key: const Key('v2-sidebar-search'),
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
        message: _w.data.errorMessage ?? 'Check your connection and try again.',
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
    // Flatten sections into one lazy list: a drawer with hundreds of chats
    // builds only the rows near the viewport instead of every row.
    final entries = <_SidebarEntry>[
      if (data.pinned.isNotEmpty) const _SectionEntry('Pinned'),
      for (final session in data.pinned) _SessionEntry(session),
      if (data.projects.isNotEmpty)
        _SectionEntry(
          'Projects',
          trailing: OIconButton(
            icon: Icons.add_rounded,
            semanticLabel: 'New project',
            size: 18,
            onPressed: _w.onNewProject,
          ),
        ),
      for (final project in data.projects) _ProjectEntry(project),
      if (data.today.isNotEmpty) const _SectionEntry('Today'),
      for (final session in data.today) _SessionEntry(session),
      if (data.yesterday.isNotEmpty) const _SectionEntry('Yesterday'),
      for (final session in data.yesterday) _SessionEntry(session),
      if (data.earlier.isNotEmpty) const _SectionEntry('Earlier'),
      for (final session in data.earlier) _SessionEntry(session),
    ];
    return OFadeSlide(
      child: _sidebarList(entries),
    );
  }

  Widget _sidebarList(List<_SidebarEntry> entries) {
    return ListView.builder(
      key: const Key('v2-sidebar-list'),
      // Keep a screenful of slack so a row that is one flick away still
      // exists for accessibility focus.
      scrollCacheExtent: const ScrollCacheExtent.pixels(1200),
      padding: const EdgeInsets.fromLTRB(OSpace.m, 0, OSpace.m, OSpace.m),
      itemCount: entries.length,
      itemBuilder: (context, index) => _entry(entries[index], index),
    );
  }

  Widget _entry(_SidebarEntry entry, int index) {
    final row = switch (entry) {
      _SectionEntry e => OSectionHeader(
        label: e.label,
        trailing: e.trailing,
        padding: const EdgeInsets.fromLTRB(
          OSpace.s,
          OSpace.l,
          OSpace.s,
          OSpace.xs,
        ),
      ),
      _SessionEntry e => _sessionRow(e.session),
      _ProjectEntry e => _ProjectRow(
        project: e.project,
        onTap: _w.onProjectTap,
        onMemory: _w.onProjectMemory,
      ),
    };
    // Keep the entrance stagger for the first screenful only.
    if (index >= 8) return row;
    final delay = OMotion.stagger * index;
    return OFadeSlide(
      delay: delay > const Duration(milliseconds: 400)
          ? const Duration(milliseconds: 400)
          : delay,
      child: row,
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
  /// title (or the project a chat belongs to). No second screen — the drawer is
  /// where the user already is.
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
        if (seen.add(session.id) && _sessionMatches(session, query)) session,
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

    final entries = <_SidebarEntry>[
      if (sessions.isNotEmpty)
        _SectionEntry(
          sessions.length == 1 ? '1 chat' : '${sessions.length} chats',
        ),
      for (final session in sessions) _SessionEntry(session),
      if (projects.isNotEmpty)
        _SectionEntry(
          projects.length == 1 ? '1 project' : '${projects.length} projects',
        ),
      for (final project in projects) _ProjectEntry(project),
    ];
    return OFadeSlide(child: _sidebarList(entries));
  }

  /// A chat matches on its own title or on the project it lives in, so
  /// searching "Brand Voice" finds the chats filed under that project too.
  static bool _sessionMatches(V2SidebarSession session, String query) {
    if (session.title.toLowerCase().contains(query)) return true;
    final project = session.projectName;
    return project != null && project.toLowerCase().contains(query);
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
                  child: ExcludeSemantics(
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

/// One row of the flattened drawer list.
sealed class _SidebarEntry {
  const _SidebarEntry();
}

final class _SectionEntry extends _SidebarEntry {
  const _SectionEntry(this.label, {this.trailing});

  final String label;
  final Widget? trailing;
}

final class _SessionEntry extends _SidebarEntry {
  const _SessionEntry(this.session);

  final V2SidebarSession session;
}

final class _ProjectEntry extends _SidebarEntry {
  const _ProjectEntry(this.project);

  final V2SidebarProject project;
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
                      child: ExcludeSemantics(
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
                    ExcludeSemantics(
                      child: Text(
                        project.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: OType.bodySm.copyWith(
                          color: c.text,
                          fontWeight: FontWeight.w500,
                        ),
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
              ExcludeSemantics(
                child: Text(
                  project.chatLabel,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: OType.caption.copyWith(color: c.textFaint),
                ),
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
///
/// It is only a control when a handler exists (either the injected callback or
/// a detail payload). Without one it stays an information label instead of
/// rendering a chip that looks tappable but goes nowhere.
class _MemoryChip extends StatelessWidget {
  const _MemoryChip({required this.project, this.onTap});

  final V2SidebarProject project;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    final hasMemory = project.memoryFileCount > 0;
    final fg = hasMemory ? c.accent : c.textFaint;
    final label = 'Memory for ${project.name}, ${project.memorySemanticLabel}';
    final chip = Container(
      key: ValueKey<String>('v2-sidebar-memory-${project.id}'),
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
    );
    final onTap = this.onTap;
    if (onTap == null) {
      // The project row's own label already carries the memory count, so the
      // chip only needs to stay out of the semantics tree and offer no tap.
      return ExcludeSemantics(child: chip);
    }
    return OPressable(onTap: onTap, semanticLabel: label, child: chip);
  }
}
