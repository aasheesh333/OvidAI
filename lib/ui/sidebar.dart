import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../core/connection_service.dart';
import '../core/firebase_service.dart';
import '../core/session_history_store.dart';
import '../core/theme.dart';
import '../core/ovid_cloud_service.dart';
import '../core/state.dart';
import '../core/cloud/agent_surface.dart';
import '../core/cloud/cloud_agent_facade.dart';
import '../core/cloud/cloud_session_store.dart';
import '../core/cloud/models.dart';
import '../core/cloud/projects.dart';
import 'profile_avatar.dart';
import 'projects_section.dart';
import 'settings_screen.dart';
import 'trajectory_screen.dart';
import 'artifacts_screen.dart';
import '../l10n/l10n.dart';
import 'schedule_screen.dart';
import 'session_actions.dart';
import 'conversation_share_sheet.dart';
import 'widgets/aether_primitives.dart';
import 'widgets/ovid_mark.dart';

/// What one sidebar row shows. Value-equal, so a refresh that changes
/// nothing a row displays (a streamed token, a tool event) is a no-op.
@immutable
class SessionSummary {
  const SessionSummary({
    required this.session,
    required this.id,
    required this.title,
    required this.model,
    required this.hasImage,
    required this.lastActivityAt,
    required this.projectId,
  });

  factory SessionSummary.of(ChatSession session) => SessionSummary(
    session: session,
    id: session.id,
    title: session.title,
    model: session.model,
    hasImage: session.hasImage,
    lastActivityAt: session.lastActivityAt,
    projectId: session.projectId,
  );

  /// The live session, for row actions (delete, share, rename).
  final ChatSession session;
  final String id;
  final String title;
  final String model;
  final bool hasImage;

  /// W1: project membership (null = ungrouped). Included in equality so a
  /// move regroups the row on the next rebuild.
  final String? projectId;

  /// Drives recency order and the date headers (F-046).
  final DateTime lastActivityAt;

  @override
  bool operator ==(Object other) =>
      other is SessionSummary &&
      identical(other.session, session) &&
      other.id == id &&
      other.title == title &&
      other.model == model &&
      other.hasImage == hasImage &&
      other.projectId == projectId &&
      other.lastActivityAt == lastActivityAt;

  @override
  int get hashCode => Object.hash(id, title, model, hasImage, projectId, lastActivityAt);
}

/// List-slot key for a session row. Its own type, so it never collides with
/// the row's inner `Dismissible` key (`ValueKey(session.id)`).
class _SessionRowKey extends ValueKey<String> {
  const _SessionRowKey(super.value);
}

/// P8 Task 19 — the facade is the only agent implementation, so the sidebar
/// reads busy/title state straight off it.
AgentSurface get _agent => CloudAgentFacade.I;

/// The sidebar's list state: root-session rows, most recent activity first
/// (F-046), plus the active id.
@immutable
class SidebarSessions {
  const SidebarSessions(this.items, this.activeId);

  final List<SessionSummary> items;
  final String? activeId;
}

/// Narrow view of [AppState] for the session list. It recomputes the row
/// summaries on each [AppState] notification but only notifies its own
/// listeners when membership, order, a title/model/icon or the active chat
/// changed. Busy dots are per row ([CloudAgentFacade.busyListenable]).
class SidebarSessionsNotifier extends ValueNotifier<SidebarSessions> {
  SidebarSessionsNotifier() : super(_compute()) {
    AppState.I.addListener(sync);
  }

  static SidebarSessions _compute() {
    final app = AppState.I;
    // Subagent sessions are apparatus, not chats — they are reached from the
    // parent's subagent card / catalog, never from the sidebar.
    return SidebarSessions([
      // Chats in their Undo window are already gone from the list
      // (optimistic delete).
      for (final s in app.rootSessionsByRecency)
        if (!app.isSessionDeletionPending(s.id)) SessionSummary.of(s),
    ], app.activeSessionId);
  }

  void sync() {
    final next = _compute();
    if (next.activeId == value.activeId &&
        listEquals(next.items, value.items)) {
      return;
    }
    value = next;
  }

  @override
  void dispose() {
    AppState.I.removeListener(sync);
    super.dispose();
  }
}

/// Sessions sidebar — DeepSeek-style harness: auto-named sessions,
/// search, new session, swipe to delete, long-press rename.
///
/// 2026-10-04 polish: rebuilt on top of the Aether primitive library.
/// The gradient header hosts the user avatar, display name and the live
/// plan pill; nav rows are compact ghost rows with icon + label; the
/// session rows render as flat, hover-aware rows (no card chrome); the
/// "New chat" affordance is now [AetherPrimaryButton]. All existing
/// semantics (string labels, tooltips, keys, swipe/rename behaviour) are
/// preserved so sidebar regression suites keep passing.
class SessionsSidebar extends StatefulWidget {
  /// True when hosted inside a [Drawer] (narrow screens). In wide mode the
  /// sidebar is embedded directly in a Row — there popping the route would
  /// exit the app, so navigation taps must not call `maybePop`.
  final bool isDrawer;

  const SessionsSidebar({super.key, this.isDrawer = true});

  @override
  State<SessionsSidebar> createState() => _SessionsSidebarState();
}

class _SessionsSidebarState extends State<SessionsSidebar> {
  String _query = '';
  final TextEditingController _searchController = TextEditingController();
  final SidebarSessionsNotifier _sessions = SidebarSessionsNotifier();

  /// W1: projects the user has expanded (session rows render nested).
  final Set<String> _expandedProjects = <String>{};

  /// P8 Task 10: the session list is the store's reconciliation output —
  /// refresh it once at mount (offline: the list renders from the local cache
  /// read-only, spec §12).
  @override
  void initState() {
    super.initState();
    unawaited(
      CloudSessionStore.I.ready.then((_) async {
        if (CloudSessionStore.I.offline) return;
        await CloudSessionStore.I.refreshSessions();
        await ProjectsController.I.refresh();
      }).catchError((Object _) {}),
    );
  }

  /// Pull-to-refresh (thin client): re-walks the gateway's session pages
  /// into AppState; the notifier the rows already listen to re-renders.
  Future<void> _refreshCloudSessions() async {
    final store = CloudSessionStore.I;
    final messenger = ScaffoldMessenger.maybeOf(context);
    await store.ready;
    if (store.offline) {
      // Read-only cache while offline (spec §12) — say so (SH-017).
      messenger?.showSnackBar(
        const SnackBar(
          content: Text("You're offline — showing chats saved on this device."),
        ),
      );
      return;
    }
    try {
      await store.refreshSessions();
      await ProjectsController.I.refresh();
    } catch (_) {
      // The last reconciled list stays; the failure is no longer silent.
      messenger?.showSnackBar(
        const SnackBar(content: Text("Couldn't refresh your chats. Try again.")),
      );
    }
  }

  /// Message-content search (F-047) runs 200 ms after the last keystroke;
  /// title matches render immediately.
  static const contentSearchDebounce = Duration(milliseconds: 200);
  Timer? _contentDebounce;
  int _contentSearchSeq = 0;
  String _contentQuery = '';
  List<SessionContentHit> _contentHits = const [];

  void _onQueryChanged(String value) {
    // Typing also re-reads the sessions, so an edit that skipped
    // AppState.refresh still shows up.
    _sessions.sync();
    final q = value.trim();
    setState(() => _query = q);
    _contentDebounce?.cancel();
    final seq = ++_contentSearchSeq;
    if (q.isEmpty) {
      setState(() {
        _contentQuery = '';
        _contentHits = const [];
      });
      return;
    }
    _contentDebounce = Timer(contentSearchDebounce, () async {
      List<SessionContentHit> hits;
      try {
        hits = await AppState.I.searchSessionContent(q);
      } catch (_) {
        hits = const [];
      }
      if (!mounted || seq != _contentSearchSeq) return;
      setState(() {
        _contentQuery = q;
        _contentHits = hits;
      });
    });
  }

  Future<void> _navigateFromSidebar(
    BuildContext context,
    WidgetBuilder builder,
  ) async {
    if (widget.isDrawer) await Navigator.maybePop(context);
    if (!context.mounted) return;
    await Navigator.of(context).push(MaterialPageRoute(builder: builder));
  }

  // ── W1 project actions ──────────────────────────────────────────────────

  Future<void> _createProject(BuildContext context) async {
    final name = await showProjectNameDialog(
      context,
      title: 'New project',
      confirmLabel: 'Create',
    );
    if (name == null || !context.mounted) return;
    final created = await ProjectsController.I.create(name);
    if (!context.mounted) return;
    if (created == null) {
      _showProjectError(context);
    } else {
      setState(() => _expandedProjects.add(created.id));
    }
  }

  Future<void> _renameProject(BuildContext context, ProjectDto project) async {
    final name = await showProjectNameDialog(
      context,
      title: 'Rename project',
      initial: project.name,
    );
    if (name == null || !context.mounted) return;
    final ok = await ProjectsController.I.rename(project.id, name);
    if (!context.mounted || ok) return;
    _showProjectError(context);
  }

  Future<void> _deleteProject(BuildContext context, ProjectDto project) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(
          'Delete "${project.name}"?',
          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
        ),
        content: const Text(
          'Chats in this project stay in your sidebar. Its project memory '
          'and file counts are removed.',
          style: TextStyle(fontSize: 13),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text('Delete', style: TextStyle(color: Aether.danger)),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    final ok = await ProjectsController.I.delete(project.id);
    if (!context.mounted) return;
    if (ok) {
      setState(() => _expandedProjects.remove(project.id));
    } else {
      _showProjectError(context);
    }
  }

  void _showProjectError(BuildContext context) {
    final message = ProjectsController.I.error ?? 'Could not update projects.';
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  @override
  void dispose() {
    _contentDebounce?.cancel();
    _searchController.dispose();
    _sessions.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final app = AppState.I;
    return Container(
      width: 288,
      color: Aether.surface,
      child: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            // Reserve room for sessions when landscape, keyboard avoidance or
            // larger text leaves too little height for the full profile/nav.
            // (Raised with the fourth footer row, Artifacts.)
            final compact =
                constraints.maxHeight <
                620 + (MediaQuery.textScalerOf(context).scale(13) - 13) * 16;
            return Column(
              children: [
                Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Gradient brand/profile header — avatar + name + plan pill
                    // sit together, with the "Ovid" wordmark anchoring the top row
                    // (the sidebar brand parity).
                    _SidebarHeader(isDrawer: widget.isDrawer, compact: compact),

                    SizedBox(height: compact ? 4 : 14),

                    // New chat button — now the Aether primary CTA. "Chat" is
                    // the only product noun; the legacy "session" label is gone.
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Stack(
                        children: [
                          SizedBox(
                            width: double.infinity,
                            child: AetherPrimaryButton(
                              label: 'New chat',
                              icon: Icons.add,
                              onPressed: () {
                                app.newSession();
                                // Only the drawer is a route; in wide mode
                                // maybePop would pop the app itself.
                                if (widget.isDrawer) Navigator.maybePop(context);
                              },
                            ),
                          ),
                          // W1: the always-available way to start a project,
                          // even before the first one exists (the Projects
                          // section below appears once there is one). An
                          // overlay, not a Row sibling: narrowing the CTA
                          // wraps its label in the very-short layouts and
                          // steals the session viewport.
                          Positioned(
                            right: 4,
                            top: 0,
                            bottom: 0,
                            child: Center(
                              child: Tooltip(
                                message: 'New project',
                                child: InkWell(
                                  key: const ValueKey('sidebar-new-project'),
                                  borderRadius: BorderRadius.circular(8),
                                  onTap: () => _createProject(context),
                                  child: SizedBox(
                                    width: 30,
                                    height: 30,
                                    child: Icon(
                                      Icons.create_new_folder_outlined,
                                      size: 18,
                                      color: Colors.white,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    SizedBox(height: compact ? 4 : 14),

                    // Search — filters the session list live (the session index parity).
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: TextField(
                        controller: _searchController,
                        onChanged: _onQueryChanged,
                        style: const TextStyle(fontSize: 13),
                        decoration: InputDecoration(
                          hintText: 'Search sessions',
                          prefixIcon: Icon(
                            Icons.search,
                            size: 16,
                            color: Aether.textFaint,
                          ),
                          isDense: true,
                          filled: true,
                          fillColor: Aether.surfaceAlt,
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(
                              AetherRadius.rMd,
                            ),
                            borderSide: BorderSide(color: Aether.inputBorder),
                          ),
                          enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(
                              AetherRadius.rMd,
                            ),
                            borderSide: BorderSide(color: Aether.inputBorder),
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(
                              AetherRadius.rMd,
                            ),
                            borderSide: BorderSide(
                              color: Aether.accent,
                              width: 1.2,
                            ),
                          ),
                          suffixIcon: _query.isEmpty
                              ? null
                              : IconButton(
                                  tooltip: 'Clear session search',
                                  visualDensity: VisualDensity.compact,
                                  icon: const Icon(Icons.close, size: 14),
                                  onPressed: () {
                                    _searchController.clear();
                                    _onQueryChanged('');
                                  },
                                ),
                        ),
                      ),
                    ),
                    SizedBox(height: compact ? 4 : 16),
                    if (!compact)
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 20),
                        child: Text(
                          'SESSIONS',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 1.4,
                            color: Aether.textFaint,
                          ),
                        ),
                      ),
                    const SizedBox(height: 6),
                  ],
                ),

                // Only sessions scroll; search and navigation stay reachable
                // regardless of the session count or filter results.
                Expanded(
                  child: ValueListenableBuilder<SidebarSessions>(
                    valueListenable: _sessions,
                    builder: (_, data, _) {
                      final q = _query.toLowerCase();
                      // Rows arrive most-recent-activity first (F-046).
                      // Titles match instantly; message bodies follow from
                      // the debounced content search. Model names are not
                      // matched (searching "gpt" listed every chat).
                      // W1: when browsing (no search), project chats render
                      // nested under their project; the main list keeps only
                      // ungrouped chats. Searching looks across everything.
                      final visible = q.isEmpty
                          ? data.items
                                .where((s) => s.projectId == null)
                                .toList()
                          : data.items
                                .where(
                                  (s) => s.title.toLowerCase().contains(q),
                                )
                                .toList();
                      final byId = <String, SessionSummary>{
                        for (final s in data.items) s.id: s,
                      };
                      final shown = {for (final s in visible) s.id};
                      final contentRows = <(SessionSummary, SessionContentHit)>[
                        if (q.isNotEmpty && _contentQuery == _query)
                          for (final hit in _contentHits)
                            if (byId[hit.sessionId] case final s?
                                when shown.add(s.id))
                              (s, hit),
                      ];
                      if (visible.isEmpty &&
                          contentRows.isEmpty &&
                          !(q.isEmpty &&
                              ProjectsController.I.projects.isNotEmpty)) {
                        if (q.isNotEmpty) {
                          return Padding(
                            padding: const EdgeInsets.all(16),
                            child: Text(
                              'No sessions match "$_query"',
                              style: TextStyle(
                                fontSize: 12,
                                color: Aether.textFaint,
                              ),
                            ),
                          );
                        }
                        // Loading vs offline vs failed vs truly empty are
                        // different states, and the empty state is pullable
                        // too (SH-017).
                        return RefreshIndicator(
                          onRefresh: _refreshCloudSessions,
                          child: SidebarEmptyState(
                            store: CloudSessionStore.I,
                            onRetry: _refreshCloudSessions,
                          ),
                        );
                      }
                      // No repo or workspace labels (user decision
                      // 2026-09-24); only recency headers when not searching.
                      // A lone group header ("Today" above every chat) adds
                      // no information; show headers once chats span two or
                      // more groups.
                      final now = DateTime.now();
                      final groups = q.isEmpty
                          ? [
                              for (final s in visible)
                                sessionRecencyGroup(s.lastActivityAt, now),
                            ]
                          : const <String>[];
                      final grouped = groups.toSet().length > 1;
                      // Sections: one per recency group (or a single
                      // headerless one), then the "In messages" section.
                      // Each section is a lazy sliver list under a pinned
                      // header, so the current group's label stays visible
                      // while scrolling and is pushed off by the next one.
                      final sections =
                          <(String?, List<SessionSummary>, bool)>[];
                      for (var i = 0; i < visible.length; i++) {
                        final label = grouped ? groups[i] : null;
                        if (sections.isEmpty ||
                            (grouped && sections.last.$1 != label)) {
                          sections.add((label, <SessionSummary>[], false));
                        }
                        sections.last.$2.add(visible[i]);
                      }
                      final hits = <String, SessionContentHit>{};
                      if (contentRows.isNotEmpty) {
                        final hitRows = <SessionSummary>[];
                        for (final (s, hit) in contentRows) {
                          hits[s.id] = hit;
                          hitRows.add(s);
                        }
                        sections.add(('In messages', hitRows, true));
                      }
                      final headerExtent =
                          MediaQuery.textScalerOf(context).scale(10.5) * 1.35 +
                          14;
                      Widget sectionSliver(
                        (String?, List<SessionSummary>, bool) section,
                      ) {
                        final (label, items, isHits) = section;
                        final indexById = <String, int>{
                          for (var i = 0; i < items.length; i++) items[i].id: i,
                        };
                        // Lazy: only visible rows are built, so thousands of
                        // chats cost the same as a screenful.
                        final list = SliverList.builder(
                          itemCount: items.length,
                          findChildIndexCallback: isHits
                              ? null
                              : (key) => key is _SessionRowKey
                                    ? indexById[key.value]
                                    : null,
                          itemBuilder: (_, i) {
                            final summary = items[i];
                            if (isHits) {
                              return _ContentHitTile(
                                session: summary.session,
                                hit: hits[summary.id]!,
                                isDrawer: widget.isDrawer,
                              );
                            }
                            return Padding(
                              key: _SessionRowKey(summary.id),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                              ),
                              child: _SessionTile(
                                summary: summary,
                                active: summary.id == data.activeId,
                                isDrawer: widget.isDrawer,
                              ),
                            );
                          },
                        );
                        if (label == null) return list;
                        return SliverMainAxisGroup(
                          slivers: [
                            SliverPersistentHeader(
                              pinned: true,
                              delegate: _RecencyHeaderDelegate(
                                label: label,
                                extent: headerExtent,
                              ),
                            ),
                            list,
                          ],
                        );
                      }

                      final scrollView = CustomScrollView(
                        keyboardDismissBehavior:
                            ScrollViewKeyboardDismissBehavior.onDrag,
                        slivers: [
                          // W1 Projects section above the sessions (owner
                          // spec §3 Screen 4). Hidden while searching so
                          // every matching chat is reachable.
                          if (q.isEmpty)
                            SliverToBoxAdapter(
                              child: AnimatedBuilder(
                                animation: ProjectsController.I,
                                builder: (_, _) {
                                  final projects =
                                      ProjectsController.I.projects;
                                  // No projects → no section at all: the
                                  // constrained/short layouts keep their
                                  // whole viewport for sessions, and the CTA
                                  // row above already offers "New project".
                                  if (projects.isEmpty) {
                                    return const SizedBox.shrink();
                                  }
                                  final tiles = <String, List<Widget>>{};
                                  for (final project in projects) {
                                    final projectSessions = data.items
                                        .where((s) => s.projectId == project.id)
                                        .toList();
                                    tiles[project.id] = [
                                      for (final summary in projectSessions)
                                        Padding(
                                          key: _SessionRowKey(summary.id),
                                          padding: const EdgeInsets.only(
                                            left: 20,
                                          ),
                                          child: _SessionTile(
                                            summary: summary,
                                            active:
                                                summary.id == data.activeId,
                                            isDrawer: widget.isDrawer,
                                          ),
                                        ),
                                    ];
                                  }
                                  return ProjectsSection(
                                    projects: projects,
                                    expanded: _expandedProjects,
                                    sessionTiles: tiles,
                                    onToggle: (id) => setState(() {
                                      if (!_expandedProjects.remove(id)) {
                                        _expandedProjects.add(id);
                                      }
                                    }),
                                    onCreate: () => _createProject(context),
                                    onRename: (project) =>
                                        _renameProject(context, project),
                                    onDelete: (project) =>
                                        _deleteProject(context, project),
                                    compact: compact,
                                  );
                                },
                              ),
                            ),
                          for (final section in sections)
                            sectionSliver(section),
                        ],
                      );
                      // P8 Task 10: pull-to-refresh reconciles the gateway's
                      // session list.
                      return RefreshIndicator(
                        onRefresh: _refreshCloudSessions,
                        child: scrollView,
                      );
                    },
                  ),
                ),

                Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Divider(height: 1, thickness: 1, color: Aether.hairline),
                    const SizedBox(height: 4),

                    // Schedule / Trajectory / Settings — all three render as the
                    // same compact ghost nav row, so the footer reads as a single
                    // consistent navigation band instead of three bespoke rows.
                    AnimatedBuilder(
                      animation: app,
                      builder: (_, _) {
                        final hasSession = app.activeSessionId != null;
                        final rows = [
                          _SidebarNavRow(
                            compact: compact,
                            icon: Icons.schedule_outlined,
                            label: 'Schedule',
                            // Always available: with no chat open it lists
                            // every schedule (Wave 5).
                            enabled: true,
                            onTap: () => _navigateFromSidebar(
                              context,
                              (_) => ScheduleScreen(
                                sessionId: app.activeSessionId,
                              ),
                            ),
                          ),
                          // PR27/B2: trajectory moved here from the chat header
                          // (the header keeps only jobs + studio + browser).
                          // Disabled when there is no active session — pushing
                          // with an empty id lands on a confusing empty ledger.
                          _SidebarNavRow(
                            compact: compact,
                            icon: Icons.timeline_outlined,
                            label: 'Trajectory — event ledger',
                            enabled: hasSession,
                            onTap: hasSession
                                ? () {
                                    final sid = app.activeSessionId ?? '';
                                    _navigateFromSidebar(
                                      context,
                                      (_) => TrajectoryScreen(sessionId: sid),
                                    );
                                  }
                                : null,
                          ),
                          // Artifacts: uploads + generated files, scoped to
                          // the active chat with an "All chats" toggle.
                          _SidebarNavRow(
                            key: const ValueKey('sidebar-artifacts'),
                            compact: compact,
                            icon: Icons.folder_copy_outlined,
                            label: context.l10n.artifactsTitle,
                            enabled: true,
                            onTap: () => _navigateFromSidebar(
                              context,
                              (_) => ArtifactsScreen(
                                sessionId: app.activeSessionId,
                              ),
                            ),
                          ),
                          // Settings at the very bottom — DeepSeek style.
                          _SidebarNavRow(
                            compact: compact,
                            icon: Icons.settings_outlined,
                            label: 'Settings',
                            enabled: true,
                            onTap: () => _navigateFromSidebar(
                              context,
                              (_) => const SettingsScreen(),
                            ),
                          ),
                        ];
                        return Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (compact)
                              Row(
                                mainAxisAlignment:
                                    MainAxisAlignment.spaceEvenly,
                                children: rows,
                              )
                            else
                              ...rows,
                            const SizedBox(height: 6),
                          ],
                        );
                      },
                    ),
                  ],
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// Sidebar date group for [at] relative to [now] (F-046).
@visibleForTesting
String sessionRecencyGroup(DateTime at, DateTime now) {
  final today = DateTime(now.year, now.month, now.day);
  final local = at.toLocal();
  final day = DateTime(local.year, local.month, local.day);
  final age = today.difference(day).inDays;
  if (age <= 0) return 'Today';
  if (age == 1) return 'Yesterday';
  if (age < 7) return 'Previous 7 days';
  return 'Older';
}

/// Pinned header for one recency section: opaque so rows scroll under it.
class _RecencyHeaderDelegate extends SliverPersistentHeaderDelegate {
  _RecencyHeaderDelegate({required this.label, required this.extent});

  final String label;
  final double extent;

  @override
  double get minExtent => extent;

  @override
  double get maxExtent => extent;

  @override
  Widget build(BuildContext context, double shrinkOffset, bool overlaps) =>
      ClipRect(
        child: ColoredBox(
          color: Aether.surface,
          child: _RecencyHeader(label: label),
        ),
      );

  @override
  bool shouldRebuild(_RecencyHeaderDelegate old) =>
      old.label != label || old.extent != extent;
}

class _RecencyHeader extends StatelessWidget {
  const _RecencyHeader({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) => Semantics(
    header: true,
    child: Padding(
      padding: const EdgeInsets.fromLTRB(20, 10, 20, 4),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12.5,
            fontWeight: FontWeight.w600,
            color: Aether.textFaint,
          ),
        ),
      ),
    ),
  );
}

/// A message-body search result: chat title plus the matching excerpt with
/// the FTS match highlighted.
class _ContentHitTile extends StatelessWidget {
  const _ContentHitTile({
    required this.session,
    required this.hit,
    required this.isDrawer,
  });

  final ChatSession session;
  final SessionContentHit hit;
  final bool isDrawer;

  @override
  Widget build(BuildContext context) {
    final base = TextStyle(fontSize: 12.5, color: Aether.textMuted);
    final spans = <TextSpan>[];
    final parts = hit.snippet
        .replaceAll('\n', ' ')
        .split(SessionHistoryRepository.highlightStart);
    for (var i = 0; i < parts.length; i++) {
      if (i == 0) {
        spans.add(TextSpan(text: parts[i]));
        continue;
      }
      final end = parts[i].indexOf(SessionHistoryRepository.highlightEnd);
      if (end < 0) {
        spans.add(TextSpan(text: parts[i]));
        continue;
      }
      spans.add(
        TextSpan(
          text: parts[i].substring(0, end),
          style: TextStyle(
            color: Aether.text,
            fontWeight: FontWeight.w700,
            backgroundColor: Aether.accent.withValues(alpha: 0.18),
          ),
        ),
      );
      spans.add(TextSpan(text: parts[i].substring(end + 1)));
    }
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1.5),
      child: InkWell(
        key: ValueKey('content-hit-${session.id}'),
        borderRadius: BorderRadius.circular(10),
        onTap: () {
          AppState.I.selectSession(session.id);
          if (isDrawer) Navigator.maybePop(context);
        },
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 9, 12, 9),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                session.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 13, color: Aether.text),
              ),
              const SizedBox(height: 2),
              Text.rich(
                TextSpan(style: base, children: spans),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Gradient header: brand wordmark + close affordance (drawer only), then
/// a profile row with avatar, display name, email/signed-out hint, and the
/// live Ovid Cloud plan pill. Rebuilds when FirebaseService or AppState
/// publish identity/tier changes.
class _SidebarHeader extends StatelessWidget {
  const _SidebarHeader({required this.isDrawer, this.compact = false});

  final bool isDrawer;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        const Positioned.fill(
          child: AetherGradientHeader(child: SizedBox.shrink()),
        ),
        Padding(
          padding: EdgeInsets.fromLTRB(
            20,
            compact ? 4 : 14,
            12,
            compact ? 4 : 12,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  OvidMark(
                    size: 30,
                    variant: Aether.dark
                        ? OvidMarkVariant.reversed
                        : OvidMarkVariant.primary,
                  ),
                  const SizedBox(width: 10),
                  Expanded(child: OvidWordmark(size: 16, onDark: Aether.dark)),
                  const SizedBox(width: 8),
                  // brand/connection parity — live connection chip.
                  if (MediaQuery.textScalerOf(context).scale(14) <= 20)
                    const _ConnectionChip()
                  else if (compact)
                    // Compact large-text header has no room for the label
                    // row below; keep the status visible as a dot.
                    const _ConnectionChip(dotOnly: true),
                  // No close button in wide mode: the sidebar is embedded,
                  // not a route — popping here would exit the app.
                  if (isDrawer)
                    IconButton(
                      tooltip: 'Close sidebar',
                      visualDensity: VisualDensity.compact,
                      icon: const Icon(Icons.chevron_left, size: 20),
                      onPressed: () => Navigator.maybePop(context),
                    ),
                ],
              ),
              if (!compact &&
                  MediaQuery.textScalerOf(context).scale(14) > 20) ...[
                const SizedBox(height: 6),
                const _ConnectionChip(),
              ],
              if (!compact) ...[
                const SizedBox(height: 10),
                // Identity row — avatar + name + email + plan pill. All of this
                // rebuilds when the Firebase user swaps or the Ovid Cloud tier
                // mint lands.
                AnimatedBuilder(
                  animation: Listenable.merge([FirebaseService.I, AppState.I]),
                  builder: (_, _) {
                    final fb = FirebaseService.I;
                    final signedIn = fb.isSignedIn;
                    final name = signedIn ? fb.accountLabel : 'You';
                    final sub = signedIn
                        ? fb.accountDetail
                        : 'Sign in to your account';
                    return Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        ProfileAvatar(
                          photoUrl: fb.photoUrl,
                          radius: 20,
                          displayName: signedIn ? name : null,
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontSize: 13.5,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                sub,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 12,
                                  color: Aether.textFaint,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    );
                  },
                ),
                const SizedBox(height: 6),
                AnimatedBuilder(
                  animation: AppState.I,
                  builder: (_, _) => _PlanPill(tier: AppState.I.ovidCloudTier),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

/// Reads the current Ovid Cloud tier (free/3x/7x/15x) and renders an
/// [AetherPill] themed per plan. Free is a quiet neutral pill; paid tiers
/// pick up the accent colour so the badge is visibly earned.
class _PlanPill extends StatelessWidget {
  const _PlanPill({required this.tier});

  final String tier;

  @override
  Widget build(BuildContext context) {
    final paid = tier != 'free';
    // Names and multipliers from the server plan table (SH-006).
    final label = paid
        ? '${ovidPlanName(tier)} · ${ovidMultiplierLabel(ovidPlanMultiplier(tier))}'
        : 'Free plan';
    return AetherPill(
      label: label,
      color: paid ? Aether.accent : Aether.textMuted,
      filled: true,
      icon: paid ? Icons.workspace_premium_outlined : Icons.circle_outlined,
    );
  }
}

/// Compact ghost nav row shared by Schedule / Trajectory / Settings. The
/// row keeps the DeepSeek-style icon disc, honours Aether hover tinting
/// via Material/InkWell, and dims when disabled.
class _SidebarNavRow extends StatelessWidget {
  const _SidebarNavRow({
    super.key,
    required this.icon,
    required this.label,
    required this.enabled,
    required this.onTap,
    this.compact = false,
  });

  final IconData icon;
  final String label;
  final bool enabled;
  final VoidCallback? onTap;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final fg = enabled ? Aether.textMuted : Aether.textFaint;
    if (compact) {
      return IconButton(
        tooltip: label,
        onPressed: enabled ? onTap : null,
        icon: Icon(icon, color: fg),
        constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
      );
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 2, 8, 2),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          hoverColor: Aether.surfaceAlt,
          onTap: enabled ? onTap : null,
          child: Opacity(
            opacity: enabled ? 1.0 : 0.5,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              child: Row(
                children: [
                  CircleAvatar(
                    radius: 13,
                    backgroundColor: Aether.surfaceRaised,
                    child: Icon(icon, size: 15, color: fg),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      label,
                      style: TextStyle(fontSize: 13, color: fg),
                    ),
                  ),
                  Icon(Icons.chevron_right, size: 16, color: Aether.textFaint),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Session-row build counter for rebuild-scope tests (debug builds only).
@visibleForTesting
abstract final class SessionTileDebug {
  static int buildCount = 0;
  static void reset() => buildCount = 0;
}

class _SessionTile extends StatefulWidget {
  final SessionSummary summary;
  final bool active;
  final bool isDrawer;
  const _SessionTile({
    required this.summary,
    required this.active,
    required this.isDrawer,
  });

  ChatSession get session => summary.session;

  @override
  State<_SessionTile> createState() => _SessionTileState();
}

class _SessionTileState extends State<_SessionTile> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    assert(() {
      SessionTileDebug.buildCount++;
      return true;
    }());
    final app = AppState.I;
    final summary = widget.summary;
    final session = widget.session;
    final active = widget.active;
    final bg = active
        ? Aether.surfaceRaised
        : _hover
        ? Aether.surfaceAlt
        : Colors.transparent;
    return Dismissible(
      key: ValueKey(session.id),
      direction: DismissDirection.endToStart,
      // Swipe delete must confirm like the delete button does — an
      // accidental swipe used to delete the chat with no way back.
      confirmDismiss: (_) => _askDeleteConfirmed(context),
      onDismissed: (_) => _deleteWithUndo(context),
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 20),
        decoration: BoxDecoration(
          color: Aether.danger.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Icon(Icons.delete_outline, color: Aether.danger, size: 18),
      ),
      child: MouseRegion(
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          margin: const EdgeInsets.symmetric(vertical: 1.5),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(10),
            border: active ? Border.all(color: Aether.hairlineStrong) : null,
          ),
          child: Row(
            children: [
              Expanded(
                child: InkWell(
                  borderRadius: BorderRadius.circular(10),
                  onTap: () {
                    app.selectSession(session.id);
                    // Only the drawer is a route; in wide mode maybePop
                    // would pop the app itself.
                    if (widget.isDrawer) Navigator.maybePop(context);
                  },
                  onLongPress: () => _showActions(context),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(12, 11, 4, 11),
                    child: Row(
                      children: [
                        Icon(
                          summary.hasImage
                              ? Icons.image_outlined
                              : Icons.chat_bubble_outline,
                          size: 14,
                          color: active ? Aether.accent : Aether.textFaint,
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                summary.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 13,
                                  fontWeight: active
                                      ? FontWeight.w600
                                      : FontWeight.w400,
                                  color: active
                                      ? Aether.text
                                      : Aether.textMuted,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Row(
                                children: [
                                  Expanded(
                                    child: Text(
                                      ovidModelLabel(summary.model),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        fontSize: 12.5,
                                        color: Aether.textFaint,
                                      ),
                                    ),
                                  ),
                                  _RunningBadge(sessionId: session.id),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              IconButton(
                tooltip: 'Session actions',
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.more_horiz, size: 18),
                onPressed: () => _showActions(context),
              ),
              IconButton(
                tooltip: 'Delete chat',
                visualDensity: VisualDensity.compact,
                icon: Icon(
                  Icons.delete_outline,
                  size: 17,
                  color: Aether.danger,
                ),
                onPressed: () => _confirmDelete(context),
              ),
              const SizedBox(width: 4),
            ],
          ),
        ),
      ),
    );
  }

  /// Delete confirmation dialog shared by the swipe gesture (via
  /// [confirmDismiss]) and the delete button. Returns true when the user
  /// confirmed; the caller performs the deletion.
  Future<bool> _askDeleteConfirmed(BuildContext context) =>
      askDeleteSessionConfirmed(context, widget.session);

  Future<void> _confirmDelete(BuildContext context) =>
      confirmAndDeleteSession(context, widget.session);

  /// Optimistic delete with a 5 s undo (see [deleteSessionWithUndo]).
  void _deleteWithUndo(BuildContext context) =>
      deleteSessionWithUndo(context, widget.session.id);

  void _showActions(BuildContext context) {
    final session = widget.session;
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Aether.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (sheetCtx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              dense: true,
              leading: const Icon(Icons.ios_share_outlined, size: 19),
              title: const Text(
                'Share conversation',
                style: TextStyle(fontSize: 13.5),
              ),
              onTap: () {
                Navigator.pop(sheetCtx);
                // Cloud rows keep session.messages empty — share the
                // facade's live projection (the overflow-menu parity).
                showConversationShareSheet(
                  context,
                  session,
                  messages: CloudAgentFacade.I.transcriptFor(session.id),
                );
              },
            ),
            ListTile(
              dense: true,
              leading: Icon(
                Icons.edit_outlined,
                size: 19,
                color: Aether.textMuted,
              ),
              title: const Text('Rename', style: TextStyle(fontSize: 13.5)),
              onTap: () {
                Navigator.pop(sheetCtx);
                _rename(context);
              },
            ),
            ListTile(
              dense: true,
              leading: Icon(
                Icons.create_new_folder_outlined,
                size: 19,
                color: Aether.textMuted,
              ),
              title: const Text(
                'Add to Project',
                style: TextStyle(fontSize: 13.5),
              ),
              onTap: () {
                Navigator.pop(sheetCtx);
                _addToProject(context);
              },
            ),
            // P8 Task 20: title generation is a server concern and the facade
            // member is inert until the owning server task wires it, so the
            // action is not offered.
          ],
        ),
      ),
    );
  }

  void _rename(BuildContext context) =>
      showRenameSessionDialog(context, widget.session);

  /// W1 "Add to Project": pick a project (or "No project") and move the chat.
  Future<void> _addToProject(BuildContext context) async {
    final controller = ProjectsController.I;
    if (!controller.loadedOnce && !controller.loading) {
      await controller.refresh();
    }
    if (!context.mounted) return;
    final selection = await showAddToProjectSheet(
      context,
      sessionTitle: widget.session.title,
      projects: controller.projects,
      currentProjectId: widget.session.projectId,
    );
    if (selection == null || !context.mounted) return;
    if (selection.projectId == widget.session.projectId) return;
    final ok = await controller.moveSession(
      widget.session.id,
      selection.projectId,
    );
    if (!context.mounted || ok) return;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(
        content: Text(
          controller.error ?? 'Could not move this chat to that project.',
        ),
      ),
    );
  }
}

/// "● running" suffix on a session row. Listens to that session's busy flag
/// only, so the row itself never rebuilds while a reply streams.
class _RunningBadge extends StatelessWidget {
  const _RunningBadge({required this.sessionId});

  final String sessionId;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: _agent.busyListenable(sessionId),
      builder: (_, running, _) {
        if (!running) return const SizedBox.shrink();
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(width: 4),
            Container(
              width: 6,
              height: 6,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Aether.accent,
              ),
            ),
            const SizedBox(width: 3),
            Text(
              'running',
              style: TextStyle(
                fontSize: 12.5,
                color: Aether.accent,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        );
      },
    );
  }
}

/// Live connection-status chip beside the brand row (the connection chip parity).
/// Green dot = online, red = offline, grey pulse = checking.
/// Tap re-probes (also the "reset handling" affordance).
class _ConnectionChip extends StatelessWidget {
  const _ConnectionChip({this.dotOnly = false});

  /// Dot without the text label (compact large-text header).
  final bool dotOnly;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: ConnectionService.I,
      builder: (_, _) {
        final c = ConnectionService.I;
        final color = switch (c.status) {
          ConnectionStatus.online => Aether.success,
          ConnectionStatus.offline => Aether.danger,
          ConnectionStatus.checking => Aether.textFaint,
        };
        final label = switch (c.status) {
          ConnectionStatus.online => 'online',
          ConnectionStatus.offline => 'offline',
          ConnectionStatus.checking => '…',
        };
        // A11Y (2026-09-24): a 6px dot plus 10.5px text with 3dp vertical
        // padding made this ~18dp tall and tappable — well under the 48dp
        // minimum, and it had no semantic label. The chip looks the same; the
        // hit area is now opaque and padded, and it announces itself.
        return Semantics(
          button: true,
          label: 'Connection status: $label — tap to re-check',
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => c.probe(),
            child: Tooltip(
              message: 'Connection: $label — tap to re-check',
              waitDuration: const Duration(milliseconds: 500),
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 9,
                  vertical: 11,
                ),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: color.withValues(alpha: 0.4)),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 6,
                      height: 6,
                      decoration: BoxDecoration(
                        color: color,
                        shape: BoxShape.circle,
                      ),
                    ),
                    if (!dotOnly) ...[
                      const SizedBox(width: 5),
                      Text(
                        label,
                        style: TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w600,
                          color: color,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// The session list's empty area (SH-017): a first sync in flight shows a
/// loading row, offline says the list is the device cache, a failed sync
/// offers Retry, and only a completed sync with no chats says "No chats yet".
/// Always scrollable so pull-to-refresh works on an empty list.
class SidebarEmptyState extends StatelessWidget {
  const SidebarEmptyState({
    super.key,
    required this.store,
    required this.onRetry,
  });

  final CloudSessionStore store;
  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([store, store.connection]),
      builder: (context, _) {
        final style = TextStyle(fontSize: 12, color: Aether.textFaint);
        final Widget body;
        // The connectivity probe, not the WS link: the socket is still
        // connecting during the very first sync.
        if (store.connection.offline) {
          body = Text(
            "You're offline. Chats saved on this device appear here; "
            'pull down to retry when you are back online.',
            key: const ValueKey('sidebar-empty-offline'),
            style: style,
          );
        } else if (store.lastSyncError != null && !store.syncing) {
          body = Column(
            key: const ValueKey('sidebar-empty-error'),
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text("Couldn't load your chats.", style: style),
              TextButton(onPressed: onRetry, child: const Text('Retry')),
            ],
          );
        } else if (store.syncing || !store.hasSynced) {
          body = Row(
            key: const ValueKey('sidebar-empty-loading'),
            children: [
              const SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              const SizedBox(width: 10),
              Text('Loading your chats…', style: style),
            ],
          );
        } else {
          body = Text(
            'No chats yet. Start one with New chat.',
            key: const ValueKey('sidebar-empty-none'),
            style: style,
          );
        }
        return ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.all(16),
          children: [body],
        );
      },
    );
  }
}
