import 'package:flutter/material.dart';

import '../../design/o_components.dart';
import '../../design/o_motion.dart';
import '../../design/o_tokens.dart';

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
  });

  final String id;
  final String title;
  final String modelLabel;
  final String timeLabel;
  final bool pinned;

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
  });

  final String id;
  final String name;
  final int chatCount;

  String get chatLabel => chatCount == 1 ? '1 chat' : '$chatCount chats';
}

/// The navigation drawer: profile, quick actions, pinned chats, projects and
/// the day's chats. All state arrives through [data]; all actions leave through
/// callbacks.
class Sidebar extends StatelessWidget {
  const Sidebar({
    super.key,
    required this.data,
    this.onProfile,
    this.onNewChat,
    this.onSearch,
    this.onNewProject,
    this.onProjectTap,
    this.onSessionTap,
    this.onSessionActions,
    this.onSessionLongPress,
    this.onSchedule,
    this.onArtifacts,
    this.onSettings,
    this.onRetry,
  });

  final V2SidebarData data;
  final VoidCallback? onProfile;
  final VoidCallback? onNewChat;
  final VoidCallback? onSearch;
  final VoidCallback? onNewProject;
  final ValueChanged<V2SidebarProject>? onProjectTap;
  final ValueChanged<V2SidebarSession>? onSessionTap;

  /// Fired by the three-dot control and, when [onSessionLongPress] is null,
  /// by a long press on the row.
  final ValueChanged<V2SidebarSession>? onSessionActions;
  final ValueChanged<V2SidebarSession>? onSessionLongPress;
  final VoidCallback? onSchedule;
  final VoidCallback? onArtifacts;
  final VoidCallback? onSettings;
  final VoidCallback? onRetry;

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
                _ProfileHeader(data: data, onTap: onProfile),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: OSpace.m),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      OButton(
                        label: 'New chat',
                        icon: Icons.add_rounded,
                        expand: true,
                        onPressed: onNewChat,
                      ),
                      const SizedBox(height: OSpace.s),
                      _SearchEntry(onTap: onSearch),
                    ],
                  ),
                ),
                const SizedBox(height: OSpace.xs),
                Expanded(child: _buildBody(context)),
                _Footer(
                  onSchedule: onSchedule,
                  onArtifacts: onArtifacts,
                  onSettings: onSettings,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildBody(BuildContext context) {
    if (data.status == V2SidebarStatus.loading) {
      return const OSkeletonList(rows: 5);
    }
    if (data.status == V2SidebarStatus.error) {
      return OErrorState(
        title: 'Chats did not load',
        message: data.errorMessage ?? 'Check your connection and try again.',
        onRetry: onRetry,
      );
    }
    if (data.isEmpty) {
      return OEmptyState(
        compact: true,
        icon: Icons.chat_bubble_outline_rounded,
        title: 'No chats yet',
        message: 'Start a new chat and it will show up here.',
        action: OButton(
          label: 'New chat',
          icon: Icons.add_rounded,
          onPressed: onNewChat,
        ),
      );
    }

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
                  for (final session in data.pinned)
                    _SessionRow(
                      session: session,
                      onTap: onSessionTap,
                      onActions: onSessionActions,
                      onLongPress: onSessionLongPress,
                    ),
                ],
              ),
            if (data.projects.isNotEmpty)
              _Section(
                label: 'Projects',
                headerTrailing: OIconButton(
                  icon: Icons.add_rounded,
                  semanticLabel: 'New project',
                  size: 18,
                  onPressed: onNewProject,
                ),
                children: [
                  for (final project in data.projects)
                    _ProjectRow(project: project, onTap: onProjectTap),
                ],
              ),
            if (data.today.isNotEmpty)
              _Section(
                label: 'Today',
                children: [
                  for (final session in data.today)
                    _SessionRow(
                      session: session,
                      onTap: onSessionTap,
                      onActions: onSessionActions,
                      onLongPress: onSessionLongPress,
                    ),
                ],
              ),
            if (data.yesterday.isNotEmpty)
              _Section(
                label: 'Yesterday',
                children: [
                  for (final session in data.yesterday)
                    _SessionRow(
                      session: session,
                      onTap: onSessionTap,
                      onActions: onSessionActions,
                      onLongPress: onSessionLongPress,
                    ),
                ],
              ),
            if (data.earlier.isNotEmpty)
              _Section(
                label: 'Earlier',
                children: [
                  for (final session in data.earlier)
                    _SessionRow(
                      session: session,
                      onTap: onSessionTap,
                      onActions: onSessionActions,
                      onLongPress: onSessionLongPress,
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
      padding: const EdgeInsets.fromLTRB(
        OSpace.m,
        OSpace.m,
        OSpace.m,
        OSpace.m,
      ),
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

/// Accent pill for the plan name. Unlike a fixed-height badge it grows with
/// the text scale so the label is never clipped at 200 %.
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

class _SearchEntry extends StatelessWidget {
  const _SearchEntry({this.onTap});

  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    return OPressable(
      onTap: onTap,
      semanticLabel: 'Search',
      child: Container(
        height: OSpace.touch,
        padding: const EdgeInsets.symmetric(horizontal: OSpace.m),
        decoration: BoxDecoration(
          color: c.surfaceAlt,
          borderRadius: BorderRadius.circular(ORadius.m),
          border: Border.all(color: c.hairline),
        ),
        child: Row(
          children: [
            Icon(Icons.search_rounded, size: 20, color: c.textFaint),
            const SizedBox(width: OSpace.s),
            Flexible(
              child: Text(
                'Search',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: OType.bodySm.copyWith(color: c.textMuted),
              ),
            ),
          ],
        ),
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
    this.onLongPress,
  });

  final V2SidebarSession session;
  final ValueChanged<V2SidebarSession>? onTap;
  final ValueChanged<V2SidebarSession>? onActions;
  final ValueChanged<V2SidebarSession>? onLongPress;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    final longPress = onLongPress ?? onActions;
    return Row(
      children: [
        Expanded(
          child: OPressable(
            onTap: onTap == null ? null : () => onTap!(session),
            onLongPress: longPress == null ? null : () => longPress(session),
            semanticLabel: session.meta.isEmpty
                ? session.title
                : '${session.title}, ${session.meta}',
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
                      Icon(Icons.push_pin_rounded, size: 18, color: c.accent),
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
  const _ProjectRow({required this.project, this.onTap});

  final V2SidebarProject project;
  final ValueChanged<V2SidebarProject>? onTap;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    return OPressable(
      onTap: onTap == null ? null : () => onTap!(project),
      semanticLabel: '${project.name}, ${project.chatLabel}',
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

class _Footer extends StatelessWidget {
  const _Footer({this.onSchedule, this.onArtifacts, this.onSettings});

  final VoidCallback? onSchedule;
  final VoidCallback? onArtifacts;
  final VoidCallback? onSettings;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    // Three columns fit at the default text size. Once the text is scaled up
    // the labels no longer fit side by side, so the items stack as full-width
    // rows instead of being truncated.
    final stacked = MediaQuery.textScalerOf(context).scale(12) > 15;
    final items = <Widget>[
      _FooterItem(
        icon: Icons.calendar_today_rounded,
        label: 'Schedule',
        onTap: onSchedule,
        stacked: stacked,
      ),
      _FooterItem(
        icon: Icons.inventory_2_outlined,
        label: 'Artifacts',
        onTap: onArtifacts,
        stacked: stacked,
      ),
      _FooterItem(
        icon: Icons.settings_outlined,
        label: 'Settings',
        onTap: onSettings,
        stacked: stacked,
      ),
    ];
    return Container(
      padding: const EdgeInsets.fromLTRB(
        OSpace.s,
        OSpace.s,
        OSpace.s,
        OSpace.s,
      ),
      decoration: BoxDecoration(
        color: c.surface,
        border: Border(top: BorderSide(color: c.hairline)),
      ),
      child: stacked
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (var i = 0; i < items.length; i++) ...[
                  if (i > 0) const SizedBox(height: OSpace.xs),
                  items[i],
                ],
              ],
            )
          : Row(children: [for (final item in items) Expanded(child: item)]),
    );
  }
}

class _FooterItem extends StatelessWidget {
  const _FooterItem({
    required this.icon,
    required this.label,
    this.onTap,
    this.stacked = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final bool stacked;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    final text = Text(
      label,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: OType.caption.copyWith(color: c.textMuted),
    );
    return OPressable(
      onTap: onTap,
      semanticLabel: label,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: OSpace.touch),
        child: Padding(
          padding: stacked
              ? const EdgeInsets.symmetric(
                  horizontal: OSpace.s,
                  vertical: OSpace.xs,
                )
              : const EdgeInsets.symmetric(vertical: OSpace.xs),
          child: stacked
              ? Row(
                  children: [
                    Icon(icon, size: 20, color: c.textMuted),
                    const SizedBox(width: OSpace.s),
                    Flexible(child: text),
                  ],
                )
              : Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(icon, size: 20, color: c.textMuted),
                    const SizedBox(height: OSpace.xs),
                    text,
                  ],
                ),
        ),
      ),
    );
  }
}
