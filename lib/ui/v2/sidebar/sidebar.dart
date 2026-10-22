import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;

import '../../design/o_components.dart';
import '../../design/o_motion.dart';
import '../../design/o_screen.dart';
import '../../design/o_tokens.dart';
import 'project_detail_page.dart';
import 'sidebar_footer.dart';

// TODO(l10n): route all user-facing copy through the ARB pass.

/// How the sidebar is mounted.
///
/// [drawer] is the phone default: the widget paints inside a [Drawer].
/// [rail] is the tablet/desktop form — a fixed column beside the content,
/// 280 dp at 600 dp+ and 300 dp at 900 dp+. The shell decides which one to
/// pass; the widget never changes mode on its own.
enum SidebarLayout { drawer, rail }

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
    this.activeSessionId,
  });

  final String name;
  final String? initials;
  final String planLabel;

  /// The session the user is currently reading. Its row carries a 2 dp
  /// accent left edge instead of a filled pill.
  final String? activeSessionId;
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
    this.messageText,
  });

  final String id;
  final String title;
  final String modelLabel;
  final String timeLabel;
  final bool pinned;

  /// Project the chat belongs to, when it has one. Never drawn on the row —
  /// a row is title and time — but search matches on it so a project name
  /// finds the chats filed under it.
  final String? projectName;

  /// The latest message text, when the caller has it. Never drawn on the row;
  /// search matches on it so a phrase from inside a chat finds that chat.
  final String? messageText;

  /// The one meta line a row is allowed. Empty when there is no time.
  String? get rowMeta => timeLabel.isEmpty ? null : timeLabel;
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

  /// The single line under a project name: the chat count. Memory stays on
  /// the memory control's spoken label; the row draws nothing else.
  String get countLabel => chatCount == 0 ? 'No chats' : chatLabel;

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
    this.layout = SidebarLayout.drawer,
    this.onProfile,
    this.onNewChat,
    this.onNewProject,
    this.onProjectTap,
    this.onProjectMemory,
    this.onSessionTap,
    this.onSessionActions,
    this.onSessionLongPress,
    this.onSchedule,
    this.onArtifacts,
    this.onSettings,
    this.onRetry,
  });

  final V2SidebarData data;

  /// Defaults to [SidebarLayout.drawer] so the phone shell is unchanged.
  final SidebarLayout layout;

  /// Phone drawer width. The drawer never covers the whole narrow screen:
  /// it shrinks to 86 % of the window below 340 dp. The shell also caps the
  /// [Drawer] it hosts at the same value, so the surface and its host agree.
  static const double drawerWidth = 340;

  /// Share of a narrow window the drawer may occupy.
  static const double drawerWidthFraction = 0.86;

  /// Fixed column widths for [SidebarLayout.rail].
  static const double railWidthTablet = 280;
  static const double railWidthWide = 300;

  /// Rail width for the current window: 280 dp from 600 dp, 300 dp from 900 dp.
  static double railWidth(double screenWidth) =>
      screenWidth >= OBreakpoints.wide ? railWidthWide : railWidthTablet;

  final VoidCallback? onProfile;
  final VoidCallback? onNewChat;
  final VoidCallback? onNewProject;
  final ValueChanged<V2SidebarProject>? onProjectTap;

  /// Fired when the memory control on a project row is tapped. When null and
  /// the project carries [V2SidebarProject.detail], the detail sheet opens
  /// inline.
  final ValueChanged<V2SidebarProject>? onProjectMemory;
  final ValueChanged<V2SidebarSession>? onSessionTap;

  /// Fired by the three-dot control and, when [onSessionLongPress] is null,
  /// by a long press on the row. Delete lives in that sheet, never on the
  /// row itself.
  final ValueChanged<V2SidebarSession>? onSessionActions;

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
    final isRail = widget.layout == SidebarLayout.rail;
    final window = MediaQuery.sizeOf(context).width;
    final width = isRail
        ? Sidebar.railWidth(window)
        : (window * Sidebar.drawerWidthFraction)
              .clamp(0.0, Sidebar.drawerWidth)
              .toDouble();
    return Align(
      alignment: Alignment.topLeft,
      child: SizedBox(
        key: const Key('v2-sidebar-surface'),
        width: width,
        child: Material(
          color: c.surface,
          child: DecoratedBox(
            decoration: BoxDecoration(
              border: isRail
                  ? Border(right: BorderSide(color: c.hairline))
                  : null,
            ),
            child: SafeArea(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _ProfileHeader(data: _w.data, onTap: _w.onProfile),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: OSpace.l),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        OButton(
                          label: 'New chat',
                          icon: Icons.add_rounded,
                          expand: true,
                          onPressed: _w.onNewChat,
                        ),
                        // Search filters the drawer index, so it only exists
                        // when there is an index to filter. Showing it over the
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
                                    onPressed: _clearSearch,
                                  ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(height: OSpace.m),
                  // The fixed block ends with a hairline; the scrolling list
                  // begins below it.
                  Container(height: 1, color: c.hairline),
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
      ),
    );
  }

  void _clearSearch() {
    _search.clear();
    FocusScope.of(context).unfocus();
    setState(() => _query = '');
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
    if (_query.isNotEmpty) return _searchResults();
    if (_w.data.isEmpty) {
      // One line. The New session button above is the only action this zone
      // needs, so the empty state does not repeat it.
      return const OEmptyState(
        compact: true,
        icon: Icons.chat_bubble_outline_rounded,
        title: 'No chats yet',
        message: '',
      );
    }

    final data = _w.data;
    final sessions = _sessions;
    // Two sections, one lazy list: a drawer with hundreds of chats builds
    // only the rows near the viewport instead of every row.
    final entries = <_SidebarEntry>[
      if (data.projects.isNotEmpty || _w.onNewProject != null)
        _SectionEntry(
          'Projects',
          // Hidden, never disabled, when nothing can create a project.
          trailing: _w.onNewProject == null
              ? null
              : OIconButton(
                  icon: Icons.add_rounded,
                  semanticLabel: 'New project',
                  size: 18,
                  onPressed: _w.onNewProject,
                ),
        ),
      for (final project in data.projects) _ProjectEntry(project),
      if (sessions.isNotEmpty) const _SectionEntry('Sessions'),
      for (final session in sessions) _SessionEntry(session),
    ];
    return OFadeSlide(child: _sidebarList(entries));
  }

  /// Every chat in the drawer index, in display order, once. A pinned chat
  /// also present in today's list must not render twice.
  List<V2SidebarSession> get _sessions {
    final data = _w.data;
    final seen = <String>{};
    return <V2SidebarSession>[
      for (final session in <V2SidebarSession>[
        ...data.pinned,
        ...data.today,
        ...data.yesterday,
        ...data.earlier,
      ])
        if (seen.add(session.id)) session,
    ];
  }

  Widget _sidebarList(List<_SidebarEntry> entries) {
    return ListView.builder(
      key: const Key('v2-sidebar-list'),
      // Keep a screenful of slack so a row that is one flick away still
      // exists for accessibility focus.
      scrollCacheExtent: const ScrollCacheExtent.pixels(1200),
      padding: const EdgeInsets.fromLTRB(OSpace.l, 0, OSpace.l, OSpace.m),
      itemCount: entries.length,
      itemBuilder: (context, index) {
        // A row ends with a hairline only when another row follows; a
        // section label is separation enough.
        final followedByRow =
            index + 1 < entries.length && entries[index + 1] is! _SectionEntry;
        return _entry(entries[index], index, showDivider: followedByRow);
      },
    );
  }

  Widget _entry(_SidebarEntry entry, int index, {required bool showDivider}) {
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
      _SessionEntry e => _sessionRow(e.session, showDivider: showDivider),
      _ProjectEntry e => _ProjectRow(
        project: e.project,
        showDivider: showDivider,
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

  Widget _sessionRow(V2SidebarSession session, {required bool showDivider}) =>
      _SessionRow(
        session: session,
        active: session.id == _w.data.activeSessionId,
        showDivider: showDivider,
        onTap: _w.onSessionTap,
        onActions: _w.onSessionActions,
        onLongPress: _w.onSessionLongPress,
      );

  /// Inline search: every chat and project in the drawer index, filtered by
  /// title, the project a chat belongs to, or the message text when the caller
  /// supplied it. No second screen — the drawer is where the user already is.
  Widget _searchResults() {
    final query = _query.toLowerCase();
    final sessions = <V2SidebarSession>[
      for (final session in _sessions)
        if (_sessionMatches(session, query)) session,
    ];
    final projects = <V2SidebarProject>[
      for (final project in _w.data.projects)
        if (project.name.toLowerCase().contains(query)) project,
    ];

    if (sessions.isEmpty && projects.isEmpty) {
      return OEmptyState(
        compact: true,
        icon: Icons.search_off_rounded,
        title: 'No matches',
        message: '',
        action: OButton(
          label: 'Clear search',
          variant: OButtonVariant.ghost,
          onPressed: _clearSearch,
        ),
      );
    }

    // Same order as the unfiltered drawer — projects, then sessions — and a
    // count on each section so the result size is visible before scrolling.
    final entries = <_SidebarEntry>[
      if (projects.isNotEmpty)
        _SectionEntry(
          'Projects',
          trailing: _countPill(
            key: const ValueKey<String>('v2-sidebar-search-projects'),
            count: projects.length,
            noun: 'project',
          ),
        ),
      for (final project in projects) _ProjectEntry(project),
      if (sessions.isNotEmpty)
        _SectionEntry(
          'Sessions',
          trailing: _countPill(
            key: const ValueKey<String>('v2-sidebar-search-sessions'),
            count: sessions.length,
            noun: 'session',
          ),
        ),
      for (final session in sessions) _SessionEntry(session),
    ];
    return OFadeSlide(child: _sidebarList(entries));
  }

  static Widget _countPill({
    required Key key,
    required int count,
    required String noun,
  }) {
    return OPill(
      key: key,
      label: '$count',
      tone: OPillTone.neutral,
      semanticLabel: count == 1 ? '1 $noun' : '$count ${noun}s',
    );
  }

  /// A chat matches on its own title, on the project it lives in (so searching
  /// "Brand Voice" finds the chats filed under that project) or on the message
  /// text when the caller supplied it.
  static bool _sessionMatches(V2SidebarSession session, String query) {
    if (session.title.toLowerCase().contains(query)) return true;
    final project = session.projectName;
    if (project != null && project.toLowerCase().contains(query)) return true;
    final message = session.messageText;
    return message != null && message.toLowerCase().contains(query);
  }
}

class _ProfileHeader extends StatelessWidget {
  const _ProfileHeader({required this.data, this.onTap});

  final V2SidebarData data;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    // One row: avatar, name, plan pill. No presence dot (it never changes)
    // and no chevron (the tap opens the profile, not a menu).
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        OSpace.l,
        OSpace.m,
        OSpace.l,
        OSpace.m,
      ),
      child: OPressable(
        onTap: onTap,
        semanticLabel: 'Profile, ${data.name}, ${data.planLabel}',
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: OSpace.listRow),
          // The pressable owns the spoken row: name and plan are announced
          // once, not once by the label and again by the avatar.
          child: ExcludeSemantics(
            child: Row(
              children: [
                OAvatar(
                  initials: data.initials ?? data.name,
                  size: 40,
                  semanticLabel: data.name,
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
                      OPill(label: data.planLabel, tone: OPillTone.accent),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
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
    required this.active,
    required this.showDivider,
    this.onTap,
    this.onActions,
    this.onLongPress,
  });

  final V2SidebarSession session;

  /// The active chat is marked by a 2 dp accent edge on the left of the row,
  /// not a filled pill: every other row keeps the bare surface.
  final bool active;

  /// Hairline under the row when another row follows it.
  final bool showDivider;
  final ValueChanged<V2SidebarSession>? onTap;
  final ValueChanged<V2SidebarSession>? onActions;
  final ValueChanged<V2SidebarSession>? onLongPress;

  String get _semanticLabel {
    final parts = <String>[
      session.title,
      if (session.pinned) 'Pinned',
      if (session.rowMeta != null) session.rowMeta!,
    ];
    return parts.join(', ');
  }

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    final longPress = onLongPress ?? onActions;
    final meta = session.rowMeta;
    return Container(
      decoration: showDivider
          ? BoxDecoration(
              border: Border(bottom: BorderSide(color: c.hairline)),
            )
          : null,
      child: Stack(
        children: [
          Row(
            children: [
              Expanded(
                child: OPressable(
                  onTap: onTap == null ? null : () => onTap!(session),
                  onLongPress: longPress == null
                      ? null
                      : () => longPress(session),
                  semanticLabel: _semanticLabel,
                  selected: active,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(
                      minHeight: OSpace.listRow,
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: OSpace.s,
                        vertical: OSpace.s,
                      ),
                      // Title and time. Nothing else earns a place on the row.
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
                            if (meta != null) ...[
                              const SizedBox(height: OSpace.xxs),
                              Text(
                                meta,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: OType.caption.copyWith(
                                  color: c.textMuted,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              // A menu button with no handler is removed, not disabled: the
              // row still opens and still long-presses when those are wired.
              if (onActions != null)
                OIconButton(
                  icon: Icons.more_vert_rounded,
                  semanticLabel: 'Chat options for ${session.title}',
                  size: 18,
                  onPressed: () => onActions!(session),
                ),
            ],
          ),
          // The accent edge overlays the row's padding, so an active row and
          // an idle row share the same text start.
          if (active)
            Positioned(
              left: 0,
              top: 0,
              bottom: 0,
              child: Container(
                key: ValueKey<String>('v2-session-active-${session.id}'),
                width: OSpace.xxs,
                color: c.accent,
              ),
            ),
        ],
      ),
    );
  }
}

class _ProjectRow extends StatelessWidget {
  const _ProjectRow({
    required this.project,
    required this.showDivider,
    this.onTap,
    this.onMemory,
  });

  final V2SidebarProject project;

  /// Hairline under the row when another row follows it.
  final bool showDivider;
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
    // Name and chat count. The only trailing control is the one that opens
    // project memory; there is no decorative folder glyph.
    return Container(
      decoration: showDivider
          ? BoxDecoration(
              border: Border(bottom: BorderSide(color: c.hairline)),
            )
          : null,
      child: OPressable(
        onTap: onTap == null ? null : () => onTap!(project),
        // Name and count only: the memory control speaks for itself instead
        // of repeating the file count in the row label.
        semanticLabel: '${project.name}, ${project.countLabel}',
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: OSpace.listRow),
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: OSpace.s,
              vertical: OSpace.s,
            ),
            child: Row(
              children: [
                Expanded(
                  child: ExcludeSemantics(
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
                        const SizedBox(height: OSpace.xxs),
                        Text(
                          project.countLabel,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: OType.caption.copyWith(color: c.textMuted),
                        ),
                      ],
                    ),
                  ),
                ),
                if (canOpenMemory)
                  _ProjectMemoryButton(
                    project: project,
                    onTap: () => _openMemory(context),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The only memory affordance on a project row: a trailing icon, not a second
/// line of chip. It exists only when a handler can actually open something.
class _ProjectMemoryButton extends StatelessWidget {
  const _ProjectMemoryButton({required this.project, required this.onTap});

  final V2SidebarProject project;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return OIconButton(
      key: ValueKey<String>('v2-sidebar-memory-${project.id}'),
      icon: Icons.memory_rounded,
      semanticLabel:
          'Memory for ${project.name}, ${project.memorySemanticLabel}',
      tooltip: 'Memory',
      size: 18,
      onPressed: onTap,
    );
  }
}
