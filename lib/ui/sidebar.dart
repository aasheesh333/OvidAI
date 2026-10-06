import 'package:flutter/material.dart';

import '../core/connection_service.dart';
import '../core/firebase_service.dart';
import '../core/theme.dart';
import '../core/state.dart';
import '../core/agent_service.dart';
import 'billing_screen.dart';
import 'memory_screen.dart';
import 'profile_avatar.dart';
import 'trajectory_screen.dart';
import 'schedule_screen.dart';
import 'conversation_share_sheet.dart';
import 'widgets/aether_primitives.dart';

/// Decoupled push targets for destinations whose screens sit OUTSIDE the
/// sidebar's compilable import graph. The sidebar is intentionally a
/// leaf library: importing Studio/Plugins/Settings here would drag the
/// whole Studio terminal stack into every sidebar widget test. Instead
/// [OvidShell] — which already imports those screens — registers the
/// real push closures once at startup, and the nav rows call
/// [SidebarNav.push]. Before registration (sidebar-only tests, or a
/// ChatScreen built without the shell) a tap is a safe no-op: the row
/// still renders and stays enabled.
typedef SidebarNavPush = void Function(BuildContext context);

final class SidebarNav {
  SidebarNav._();

  /// Studio (code & terminal) — registered by the shell via `openStudio`.
  static const studio = 'studio';

  /// Plugins & marketplaces.
  static const plugins = 'plugins';

  /// Settings root.
  static const settings = 'settings';

  static final Map<String, SidebarNavPush> _pushers = {};

  /// Registers [push] for [destination]. Called once by the shell.
  static void register(String destination, SidebarNavPush push) {
    _pushers[destination] = push;
  }

  /// Pushes [destination] when a pusher is registered; no-op otherwise.
  static void push(BuildContext context, String destination) {
    _pushers[destination]?.call(context);
  }

  /// Test seam: forget every registration.
  @visibleForTesting
  static void debugClear() {
    _pushers.clear();
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
///
/// 2026-10-06 v2 nav restructure: the footer is now ONE consistent
/// ghost-row navigation band with the six destinations — Chat, Studio,
/// Activity (the trajectory event ledger), Library (memories), Money
/// (plans & billing), Plugins — plus Schedule and Settings. Every row is
/// the same [_SidebarNavRow] (icon disc + label + chevron, hover tint on
/// wide pointers). Session-gated rows never disable silently: the
/// chevron swaps to a visible "Needs a chat" marker and the tooltip
/// explains why. The narrow-screen [Drawer] that hosts this sidebar is
/// declared exactly once — inside ChatScreen's own Scaffold; the shell
/// only embeds the sidebar directly in wide mode.
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

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final app = AppState.I;
    return Container(
      width: 288,
      color: Aether.surface,
      child: SafeArea(
        child: CustomScrollView(
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          slivers: [
            SliverToBoxAdapter(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
            // Gradient brand/profile header — avatar + name + plan pill
            // sit together, with the "Ovid" wordmark anchoring the top row
            // (the sidebar brand parity).
            _SidebarHeader(isDrawer: widget.isDrawer),

            const SizedBox(height: 14),

            // New chat button — now the Aether primary CTA. Label text
            // 'New session' is preserved verbatim so existing finders keep
            // working (sidebar_no_repo_labels_test).
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: SizedBox(
                width: double.infinity,
                child: AetherPrimaryButton(
                  label: 'New session',
                  icon: Icons.add,
                  onPressed: () {
                    app.newSession();
                    // Only the drawer is a route; in wide mode maybePop
                    // would pop the app itself.
                    if (widget.isDrawer) Navigator.maybePop(context);
                  },
                ),
              ),
            ),
            const SizedBox(height: 14),

            // Search — filters the session list live (the session index parity).
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: TextField(
                controller: _searchController,
                onChanged: (v) => setState(() => _query = v.trim()),
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
                    borderRadius: BorderRadius.circular(AetherRadius.rMd),
                    borderSide: BorderSide(color: Aether.hairline),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(AetherRadius.rMd),
                    borderSide: BorderSide(color: Aether.hairline),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(AetherRadius.rMd),
                    borderSide: BorderSide(color: Aether.accent, width: 1.2),
                  ),
                  suffixIcon: _query.isEmpty
                      ? null
                        : IconButton(
                          tooltip: 'Clear session search',
                          visualDensity: VisualDensity.compact,
                          icon: const Icon(Icons.close, size: 14),
                          onPressed: () {
                            _searchController.clear();
                            setState(() => _query = '');
                          },
                        ),
                ),
              ),
            ),
            const SizedBox(height: 16),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Text(
                'SESSIONS',
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1.4,
                  color: Aether.textFaint,
                ),
              ),
            ),
            const SizedBox(height: 6),
                ],
              ),
            ),

            // Sessions list
            AnimatedBuilder(
                animation: app,
                builder: (_, _) {
                  final q = _query.toLowerCase();
                  // Subagent sessions are apparatus, not chats — they are
                  // reached from the parent's subagent card / catalog, never
                  // from the sidebar.
                  final roots = app.rootSessions;
                  final visible = q.isEmpty
                      ? roots
                      : roots
                            .where(
                              (s) =>
                                  s.title.toLowerCase().contains(q) ||
                                  s.model.toLowerCase().contains(q),
                            )
                            .toList();
                  if (visible.isEmpty) {
                    return SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                      child: Text(
                        q.isEmpty ? 'No sessions yet' : 'No sessions match "$_query"',
                        style: TextStyle(fontSize: 12, color: Aether.textFaint),
                      ),
                      ),
                    );
                  }
                  // Sessions list — flat, in stored order. No grouping
                  // headers: the sidebar deliberately shows no repo or
                  // workspace labels (user decision 2026-09-24); the repo
                  // name still appears in the studio chatbox folder chip.
                  return SliverList.builder(
                    itemCount: visible.length,
                    itemBuilder: (_, i) {
                      final s = visible[i];
                      return Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        child: _SessionTile(
                        session: s,
                        active: s.id == app.activeSessionId,
                        isDrawer: widget.isDrawer,
                        ),
                      );
                    },
                  );
                },
            ),

            SliverFillRemaining(
              hasScrollBody: false,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
            Divider(height: 1, thickness: 1, color: Aether.hairline),
            const SizedBox(height: 4),

            // ── Destination nav band (v2, 2026-10-06) ──────────────────
            // Chat / Studio / Activity / Library / Money / Plugins plus
            // Schedule and Settings — every row is the same compact ghost
            // nav row ([_SidebarNavRow]), so the footer reads as a single
            // consistent navigation band instead of bespoke rows. Gated
            // destinations (Activity, Schedule) explain their disabled
            // state instead of silently greying out.
            AnimatedBuilder(
              animation: app,
              builder: (_, _) {
                final sid = app.activeSessionId;
                final hasSession = sid != null;
                void push(Widget screen) {
                  Navigator.of(
                    context,
                  ).push(MaterialPageRoute(builder: (_) => screen));
                }

                return Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Chat — home destination. Narrow: the drawer IS a
                    // route, so closing it reveals the chat. Wide: pop any
                    // pushed screen back to the embedded chat.
                    _SidebarNavRow(
                      navKey: const ValueKey('sidebar-nav-chat'),
                      icon: Icons.chat_bubble_outline,
                      label: 'Chat',
                      enabled: true,
                      onTap: () {
                        if (widget.isDrawer) {
                          Navigator.maybePop(context);
                        } else {
                          Navigator.of(
                            context,
                          ).popUntil((route) => route.isFirst);
                        }
                      },
                    ),
                    // Studio/Plugins/Settings push through [SidebarNav]:
                    // their screens live outside this library's compilable
                    // graph; the shell registers the real closures.
                    _SidebarNavRow(
                      navKey: const ValueKey('sidebar-nav-studio'),
                      icon: Icons.code,
                      label: 'Studio',
                      enabled: true,
                      onTap: () => SidebarNav.push(context, SidebarNav.studio),
                    ),
                    // Activity — the trajectory event ledger (PR27/B2:
                    // trajectory lives in the sidebar footer, not the chat
                    // header). The caption keeps the legacy label so the
                    // destination is self-describing; the row is gated on
                    // an active session because pushing with an empty id
                    // lands on a confusing empty ledger.
                    _SidebarNavRow(
                      navKey: const ValueKey('sidebar-nav-activity'),
                      icon: Icons.timeline_outlined,
                      label: 'Activity',
                      caption: 'Trajectory — event ledger',
                      enabled: hasSession,
                      disabledHint: 'Start a chat to view activity',
                      onTap: hasSession
                          ? () => push(TrajectoryScreen(sessionId: sid))
                          : null,
                    ),
                    _SidebarNavRow(
                      navKey: const ValueKey('sidebar-nav-library'),
                      icon: Icons.menu_book_outlined,
                      label: 'Library',
                      enabled: true,
                      onTap: () => push(const MemoryScreen()),
                    ),
                    // Money — plans & billing (mirrors the canonical
                    // `/money` route in lib/core/router.dart).
                    _SidebarNavRow(
                      navKey: const ValueKey('sidebar-nav-money'),
                      icon: Icons.payments_outlined,
                      label: 'Money',
                      enabled: true,
                      onTap: () => push(const BillingScreen()),
                    ),
                    _SidebarNavRow(
                      navKey: const ValueKey('sidebar-nav-plugins'),
                      icon: Icons.extension_outlined,
                      label: 'Plugins',
                      enabled: true,
                      onTap: () =>
                          SidebarNav.push(context, SidebarNav.plugins),
                    ),
                    _SidebarNavRow(
                      navKey: const ValueKey('sidebar-nav-schedule'),
                      icon: Icons.schedule_outlined,
                      label: 'Schedule',
                      enabled: hasSession,
                      disabledHint: 'Start a chat to schedule runs',
                      onTap: hasSession
                          ? () => push(ScheduleScreen(sessionId: sid))
                          : null,
                    ),
                    // Settings at the very bottom — DeepSeek style.
                    _SidebarNavRow(
                      navKey: const ValueKey('sidebar-nav-settings'),
                      icon: Icons.settings_outlined,
                      label: 'Settings',
                      enabled: true,
                      onTap: () =>
                          SidebarNav.push(context, SidebarNav.settings),
                    ),
                    const SizedBox(height: 6),
                  ],
                );
              },
            ),
                ],
              ),
            ),
          ],
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
  const _SidebarHeader({required this.isDrawer});

  final bool isDrawer;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        const Positioned.fill(
          child: AetherGradientHeader(child: SizedBox.shrink()),
        ),
        Padding(
        padding: const EdgeInsets.fromLTRB(20, 14, 12, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Container(
                  width: 30,
                  height: 30,
                  decoration: BoxDecoration(
                    color: Aether.accent,
                    borderRadius: BorderRadius.circular(9),
                    boxShadow: AetherShadows.shadowS,
                  ),
                  child: const Center(
                    child: Text(
                      'O',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w800,
                        color: Colors.white,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                const Expanded(child: Text(
                  'Ovid',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                  ),
                )),
                const SizedBox(width: 8),
                // brand/connection parity — live connection chip.
                if (MediaQuery.textScalerOf(context).scale(14) <= 20)
                  const _ConnectionChip(),
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
            if (MediaQuery.textScalerOf(context).scale(14) > 20) ...[
              const SizedBox(height: 6),
              const _ConnectionChip(),
            ],
            const SizedBox(height: 10),
            // Identity row — avatar + name + email + plan pill. All of this
            // rebuilds when the Firebase user swaps or the Ovid Cloud tier
            // mint lands.
            AnimatedBuilder(
              animation: Listenable.merge([
                FirebaseService.I,
                AppState.I,
              ]),
              builder: (_, _) {
                final fb = FirebaseService.I;
                final signedIn = fb.isSignedIn;
                final name = signedIn
                    ? (fb.displayName?.trim().isNotEmpty == true
                        ? fb.displayName!.trim()
                        : (fb.email ?? 'Signed in'))
                    : 'You';
                final sub = signedIn
                    ? (fb.email ?? 'Signed in')
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
                              fontSize: 11,
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
    final label = switch (tier) {
      '3x' => 'Plus · 3×',
      '7x' => 'Pro · 7×',
      '15x' => 'Max · 15×',
      _ => 'Free plan',
    };
    return AetherPill(
      label: label,
      color: paid ? Aether.accent : Aether.textMuted,
      filled: true,
      icon: paid ? Icons.workspace_premium_outlined : Icons.circle_outlined,
    );
  }
}

/// Compact ghost nav row shared by every destination in the footer band
/// (Chat / Studio / Activity / Library / Money / Plugins / Schedule /
/// Settings). The row keeps the DeepSeek-style icon disc, honours Aether
/// hover tinting via Material/InkWell (the wide-pointer hover highlight),
/// and dims when disabled.
///
/// Disabled is never silent: the trailing chevron swaps to a visible
/// "Needs a chat" marker and the tooltip carries [disabledHint], so the
/// enabled state is always explained. An optional [caption] renders a
/// second, quieter line under the label (Activity uses it to keep the
/// legacy "Trajectory — event ledger" name visible).
class _SidebarNavRow extends StatelessWidget {
  const _SidebarNavRow({
    required this.icon,
    required this.label,
    required this.enabled,
    required this.onTap,
    this.navKey,
    this.caption,
    this.disabledHint,
  });

  final IconData icon;
  final String label;
  final bool enabled;
  final VoidCallback? onTap;

  /// Finder key stamped on the row's [InkWell] so tests can assert the
  /// enabled state (`onTap != null`) per destination.
  final Key? navKey;

  /// Optional second line under the label (e.g. the legacy ledger name).
  final String? caption;

  /// Why the row is disabled — surfaced via tooltip and, when disabled,
  /// a visible trailing marker. Null means "never disabled".
  final String? disabledHint;

  @override
  Widget build(BuildContext context) {
    final fg = enabled ? Aether.textMuted : Aether.textFaint;
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 2, 8, 2),
      child: Tooltip(
        message: enabled ? (caption ?? label) : (disabledHint ?? label),
        waitDuration: const Duration(milliseconds: 500),
        child: Material(
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(10),
          child: InkWell(
            key: navKey,
            borderRadius: BorderRadius.circular(10),
            hoverColor: Aether.surfaceAlt,
            onTap: enabled ? onTap : null,
            child: Opacity(
              opacity: enabled ? 1.0 : 0.55,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 9,
                ),
                child: Row(
                  children: [
                    CircleAvatar(
                      radius: 13,
                      backgroundColor: Aether.surfaceRaised,
                      child: Icon(icon, size: 15, color: fg),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 13, color: fg),
                          ),
                          if (caption != null) ...[
                            const SizedBox(height: 1),
                            Text(
                              caption!,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 10.5,
                                color: Aether.textFaint,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                    if (!enabled && disabledHint != null)
                      Text(
                        'Needs a chat',
                        maxLines: 1,
                        style: TextStyle(
                          fontSize: 9.5,
                          fontWeight: FontWeight.w600,
                          color: Aether.textFaint,
                        ),
                      )
                    else
                      Icon(
                        Icons.chevron_right,
                        size: 16,
                        color: Aether.textFaint,
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _SessionTile extends StatefulWidget {
  final ChatSession session;
  final bool active;
  final bool isDrawer;
  const _SessionTile({
    required this.session,
    required this.active,
    required this.isDrawer,
  });

  @override
  State<_SessionTile> createState() => _SessionTileState();
}

class _SessionTileState extends State<_SessionTile> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final app = AppState.I;
    final session = widget.session;
    final active = widget.active;
    return AnimatedBuilder(
      animation: AgentService.I,
      builder: (_, _) {
        final running = AgentService.I.busyFor(session.id);
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
          onDismissed: (_) => app.deleteSession(session.id),
          background: Container(
            alignment: Alignment.centerRight,
            padding: const EdgeInsets.only(right: 20),
            decoration: BoxDecoration(
              color: Aether.danger.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(10),
            ),
            child: const Icon(
              Icons.delete_outline,
              color: Aether.danger,
              size: 18,
            ),
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
                border: active
                    ? Border.all(color: Aether.hairlineStrong)
                    : null,
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
                              session.messages.any(
                                    (m) => m.kind == MsgKind.imageGen,
                                  )
                                  ? Icons.image_outlined
                                  : Icons.chat_bubble_outline,
                              size: 14,
                              color: active
                                  ? Aether.accent
                                  : Aether.textFaint,
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Column(
                                crossAxisAlignment:
                                    CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    session.title,
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
                                          session.model,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                            fontSize: 10.5,
                                            color: Aether.textFaint,
                                          ),
                                        ),
                                      ),
                                      if (running) ...[
                                        const SizedBox(width: 4),
                                        Container(
                                          width: 6,
                                          height: 6,
                                          decoration: const BoxDecoration(
                                            shape: BoxShape.circle,
                                            color: Aether.accent,
                                          ),
                                        ),
                                        const SizedBox(width: 3),
                                        Text(
                                          'running',
                                          style: TextStyle(
                                            fontSize: 9.5,
                                            color: Aether.accent,
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                      ],
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
                    icon: const Icon(
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
      },
    );
  }

  /// Delete confirmation dialog shared by the swipe gesture (via
  /// [confirmDismiss]) and the delete button. Returns true when the user
  /// confirmed; the caller performs the deletion.
  Future<bool> _askDeleteConfirmed(BuildContext context) async {
    final session = widget.session;
    // Deleting a running chat stops its agent — say so in the dialog.
    final running = AgentService.I.busyFor(session.id);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('Delete ${session.title}?'),
        content: Text(
          running
              ? 'This chat is running — deleting it stops the agent. '
                    'This chat cannot be recovered.'
              : 'This chat cannot be recovered.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Delete', style: TextStyle(color: Aether.danger)),
          ),
        ],
      ),
    );
    return confirmed == true;
  }

  Future<void> _confirmDelete(BuildContext context) async {
    if (await _askDeleteConfirmed(context)) {
      AppState.I.deleteSession(widget.session.id);
    }
  }

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
                showConversationShareSheet(context, session);
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
              leading: const Icon(
                Icons.auto_awesome_outlined,
                size: 19,
                color: Aether.accent,
              ),
              title: const Text(
                'Regenerate title',
                style: TextStyle(fontSize: 13.5),
              ),
              onTap: () {
                Navigator.pop(sheetCtx);
                _regenerateTitle(context);
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _regenerateTitle(BuildContext context) async {
    final session = widget.session;
    final messenger = ScaffoldMessenger.of(context);
    final previous = session.title;
    messenger.showSnackBar(
      const SnackBar(
        content: Text('Generating title…'),
        duration: Duration(seconds: 2),
      ),
    );
    await AgentService.I.regenerateSessionTitle(session);
    if (session.title == previous) {
      messenger.hideCurrentSnackBar();
      messenger.showSnackBar(
        const SnackBar(content: Text('Could not generate a title')),
      );
    }
  }

  void _rename(BuildContext context) {
    final session = widget.session;
    final c = TextEditingController(text: session.title);
    void save(String value) {
      AppState.I.renameSession(session.id, value.trim());
      Navigator.pop(context);
    }
    // Dialog controllers were leaked: each rename left a TextEditingController
    // (and its listeners plus platform text-input resources) alive forever.
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text(
          'Rename session',
          style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
        ),
        content: TextField(
          controller: c,
          autofocus: true,
          style: const TextStyle(fontSize: 14),
          // The IME action key used to be a dead end: it showed a return key
          // that did nothing, so the user had to reach for Save.
          textInputAction: TextInputAction.done,
          onSubmitted: save,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => save(c.text),
            child: const Text('Save', style: TextStyle(color: Aether.accent)),
          ),
        ],
      ),
    ).whenComplete(c.dispose);
  }
}

/// Live connection-status chip beside the brand row (the connection chip parity).
/// Green dot = online, red = offline, grey pulse = checking.
/// Tap re-probes (also the "reset handling" affordance).
class _ConnectionChip extends StatelessWidget {
  const _ConnectionChip();

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: ConnectionService.I,
      builder: (_, _) {
        final c = ConnectionService.I;
        final color = switch (c.status) {
          ConnectionStatus.online => Aether.successLight,
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
          label: 'Connection status — tap to re-check',
          child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => c.probe(),
          child: Tooltip(
            message: 'Connection: $label — tap to re-check',
            waitDuration: const Duration(milliseconds: 500),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 11),
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
                  const SizedBox(width: 5),
                  Text(
                    label,
                    style: TextStyle(
                      fontSize: 10.5,
                      fontWeight: FontWeight.w600,
                      color: color,
                    ),
                  ),
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
