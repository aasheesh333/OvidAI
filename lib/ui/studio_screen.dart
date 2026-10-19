import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../core/cloud/cloud_agent_facade.dart';
import '../core/cloud/cloud_ws.dart';
import '../core/cloud/models.dart';
import '../core/cloud/studio_files.dart';
import '../core/cloud/studio_remote_client.dart';
import '../core/state.dart';
import '../core/studio_drafts.dart';
import '../core/theme.dart';
import 'studio_editor.dart';
import 'studio_errors.dart';
import 'studio_file_tree.dart';
import 'studio_layout.dart';
import 'trajectory_screen.dart';
import 'widgets/aether_primitives.dart';

// Studio's panes live in their own libraries; re-exported so callers (and the
// existing widget tests) keep reaching them through this one import.
export 'studio_editor.dart' show StudioEditor, StudioEditorTabs;
export 'studio_file_tree.dart' show StudioFileTree;

/// Route name Studio is pushed under (deep links / route-stack inspection).
const String kStudioRouteName = '/studio';

/// Opens Studio over the current route. The ONE entry point every Studio
/// button uses (chat header, composer chip), so they cannot drift apart again
/// (ST-001: every entry point had been swapped for a SnackBar).
Future<void> openStudio(BuildContext context) =>
    Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        settings: const RouteSettings(name: kStudioRouteName),
        builder: (_) => const StudioScreen(),
      ),
    );

/// Studio — a server-side IDE over the user's cloud workspace.
///
/// The workspace is ONE per user and shared by every chat (R2), so Studio is
/// not bound to the active chat: it always shows [kStudioWorkspaceKey]'s
/// bucket and switching chats never swaps files under the editor (ST-016).
///
/// There is deliberately NO terminal (owner directive 2026-10-18): execution
/// is agent-only. The model runs commands in the user's sandbox, and the user
/// follows what happened in the read-only agent activity log (the app bar's
/// "Agent activity" opens it). The gateway refuses every pty_* frame.
///
/// Freshness: the tree and open files reload on open, on app resume, on the
/// refresh button and — debounced — whenever the agent finishes a
/// file-changing tool or a run in any subscribed chat (ST-006).
///
/// The layout is breakpoint-driven ([StudioMetrics]): below 840dp the file
/// tree stops being docked, below 600dp it becomes an overlay.
class StudioScreen extends StatefulWidget {
  const StudioScreen({
    super.key,
    this.workspaceKey = kStudioWorkspaceKey,
    this.agentEvents,
  });

  /// The Studio bucket to show. Production always uses the per-user
  /// workspace; tests bind a fake session.
  final String workspaceKey;

  /// Session events that may change workspace files. Null listens to the
  /// process WebSocket multiplexer ([WsMultiplexer.sessionEvents]).
  final Stream<CloudSessionEvent>? agentEvents;

  @override
  State<StudioScreen> createState() => _StudioScreenState();
}

class _StudioScreenState extends State<StudioScreen>
    with WidgetsBindingObserver {
  /// User's explicit choice for the tree. Null means "use the breakpoint
  /// default", so rotating a phone to tablet width re-docks the tree instead
  /// of fighting the user's last decision on the old geometry.
  bool? _showFilesOverride;

  /// User drag. Null means "use the breakpoint default"; every read goes
  /// back through [StudioMetrics.clampTreeWidth] so a stale drag value can
  /// never starve the editor after a rotation.
  double? _treeWidthOverride;

  /// Whether the bucket holds unsaved editor drafts. Kept in its own
  /// notifier so the guard does not rebuild the screen per token.
  final ValueNotifier<bool> _hasDrafts = ValueNotifier(false);
  bool _leaving = false;

  StreamSubscription<CloudSessionEvent>? _agentEventsSub;

  String get _sid => widget.workspaceKey;
  StudioRemoteClient get _remote => StudioRemoteClient.I;

  void _syncDraftFlag() =>
      _hasDrafts.value = _remote.dirtyFiles(_sid).isNotEmpty;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _remote.tabsFor(_sid).addListener(_syncDraftFlag);
    _syncDraftFlag();
    _agentEventsSub = (widget.agentEvents ?? WsMultiplexer.I.sessionEvents)
        .listen((event) =>
            _remote.noteAgentEvent(_sid, event.type, event.payload));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _refresh();
    });
  }

  @override
  void didUpdateWidget(StudioScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.workspaceKey != widget.workspaceKey) {
      _remote.tabsFor(oldWidget.workspaceKey).removeListener(_syncDraftFlag);
      _remote.tabsFor(_sid).addListener(_syncDraftFlag);
      _syncDraftFlag();
      _refresh();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_agentEventsSub?.cancel());
    _remote.tabsFor(_sid).removeListener(_syncDraftFlag);
    _hasDrafts.dispose();
    // Leaving Studio is a good moment to make sure drafts are on disk.
    unawaited(StudioDraftStore.I.flush());
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Coming back to the app: the agent may have changed files meanwhile.
    if (state == AppLifecycleState.resumed) _refresh();
  }

  /// Every refresh goes through here and the client's single-flight
  /// [StudioRemoteClient.refreshWorkspace] (ST-019). Failures surface in the
  /// one inline status strip — never as a toast (ST-010).
  void _refresh() => unawaited(_remote.refreshWorkspace(_sid));

  /// Back with unsaved drafts: Save all / Discard / Cancel (F-071).
  Future<void> _confirmLeave() async {
    if (_leaving) return;
    final dirty = _remote.dirtyFiles(_sid);
    if (dirty.isEmpty) {
      Navigator.of(context).pop();
      return;
    }
    _leaving = true;
    try {
      final choice = await showStudioUnsavedDialog(
        context,
        dirty,
        title: 'Leave Studio with unsaved changes?',
        saveLabel: dirty.length == 1 ? 'Save' : 'Save all',
      );
      if (!mounted) return;
      switch (choice) {
        case StudioUnsavedChoice.cancel:
          return;
        case StudioUnsavedChoice.discard:
          _remote.discardAllStudioDrafts(_sid);
        case StudioUnsavedChoice.save:
          final failed = await _remote.saveAllStudioDrafts(_sid);
          if (!mounted) return;
          if (failed.isNotEmpty) {
            showStudioToast(
              context,
              failed.length == 1
                  ? 'Could not save ${failed.single.split('/').last}.'
                  : 'Could not save ${failed.length} files.',
              error: true,
            );
            return;
          }
      }
      Navigator.of(context).pop();
    } finally {
      _leaving = false;
    }
  }

  void _openAgentLog() {
    final session = AppState.I.activeSession;
    if (session == null) return;
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => TrajectoryScreen(sessionId: session.id),
    ));
  }

  void _toggleFiles() => setState(() {
        _showFilesOverride = !(_showFilesOverride ?? _treeDefaultFor(context));
      });

  bool _treeDefaultFor(BuildContext context) =>
      MediaQuery.sizeOf(context).width >= StudioMetrics.wideBreakpoint;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _remote,
      builder: (context, _) {
        final compactActions =
            MediaQuery.sizeOf(context).width < StudioMetrics.mediumBreakpoint;
        final noWorkspace = _remote.hasNoWorkspace(_sid);
        // On a compact width the tree is an overlay, so Android's back gesture
        // must dismiss it before it leaves the screen.
        final treeOverlayOpen = compactActions &&
            (_showFilesOverride ?? false) &&
            !noWorkspace;
        return ValueListenableBuilder<bool>(
          valueListenable: _hasDrafts,
          builder: (context, hasDrafts, child) => PopScope(
            canPop: !treeOverlayOpen && !hasDrafts,
            onPopInvokedWithResult: (didPop, _) {
              if (didPop) return;
              if (treeOverlayOpen) {
                setState(() => _showFilesOverride = false);
              } else if (hasDrafts) {
                _confirmLeave();
              }
            },
            child: child!,
          ),
          child: Scaffold(
            backgroundColor: Aether.bg,
            appBar: _appBar(noWorkspace),
            body: SafeArea(
              child: noWorkspace
                  ? _NoWorkspaceView(
                      onRetry: _remote.treeLoading(_sid) ? null : _refresh,
                    )
                  : StudioPaneViewport(
                      // Keep the tab strip and a real editor viewport
                      // reachable even under a long approval or the software
                      // keyboard.
                      minContentHeight: 122 +
                          math.max(1.0,
                                  MediaQuery.textScalerOf(context).scale(1.0)) *
                              kStudioTapTarget,
                      chrome: [
                        _WorkspaceBar(snapshot: _remote.snapshotFor(_sid)),
                        // A run-blocking approval is impossible to miss —
                        // Approve resolves the gate, Decline rejects it.
                        _ApprovalBanner(
                          onDecision: (a, ok) {
                            // Bound to the request the banner rendered: a
                            // stale tap must never resolve the NEXT pending
                            // approval.
                            if (!CloudAgentFacade.I.approveRequest(a, ok)) {
                              return;
                            }
                            if (!ok) {
                              showStudioToast(context, 'Declined ${a.tool}');
                            }
                          },
                        ),
                        _WorkspaceStatus(
                          failure: _remote.treeFailure(_sid),
                          loading: _remote.treeLoading(_sid) &&
                              _remote.snapshotFor(_sid) == null,
                          waking: _remote.isWaking(_sid),
                          wakeTimedOut: _remote.wakeTimedOut(_sid),
                          onRetry: _refresh,
                          onWake: () =>
                              unawaited(_remote.wakeWorkspace(_sid)),
                        ),
                      ],
                      child: LayoutBuilder(builder: _workspace),
                    ),
            ),
          ),
        );
      },
    );
  }

  PreferredSizeWidget _appBar(bool noWorkspace) {
    final showFiles = _showFilesOverride ?? _treeDefaultFor(context);
    final loading = _remote.treeLoading(_sid);
    return AppBar(
      leading: const BackButton(),
      titleSpacing: 0,
      title: Semantics(
        header: true,
        child: const Text(
          'Studio',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: 17),
        ),
      ),
      actions: [
        if (!noWorkspace)
          StudioIconButton(
            icon: showFiles ? Icons.folder_open : Icons.folder_outlined,
            tooltip: showFiles ? 'Hide files' : 'Show files',
            onPressed: _toggleFiles,
          ),
        // The ONE refresh affordance (ST-019).
        StudioIconButton(
          key: studioRefreshKey,
          icon: Icons.refresh_rounded,
          tooltip: 'Refresh files',
          iconSize: 20,
          onPressed: loading ? null : _refresh,
        ),
        // Read-only agent execution log — Studio has no terminal.
        StudioIconButton(
          key: studioAgentLogKey,
          icon: Icons.timeline_outlined,
          tooltip: 'Agent activity',
          iconSize: 20,
          onPressed: AppState.I.activeSession == null ? null : _openAgentLog,
        ),
        const SizedBox(width: 4),
      ],
    );
  }

  /// The tree/editor split for the height that is actually left after the
  /// app bar, workspace bar and any banners.
  Widget _workspace(BuildContext context, BoxConstraints c) {
    final m = StudioMetrics.of(
      c,
      textScale: MediaQuery.textScalerOf(context).scale(1.0),
    );
    final showTree = _showFilesOverride ?? m.treeVisibleByDefault;
    final dockedWidth = m.clampTreeWidth(
      _treeWidthOverride ?? m.treeWidth,
      regionWidth: c.maxWidth - kStudioTapTarget,
    );
    final editor = Column(
      children: [
        StudioEditorTabs(sessionId: _sid),
        Expanded(child: StudioEditor(sessionId: _sid)),
      ],
    );

    final split = Row(
      children: [
        if (showTree && m.treeDocked) ...[
          SizedBox(
            key: studioTreePaneKey,
            width: dockedWidth,
            child: StudioFileTree(sessionId: _sid),
          ),
          StudioPaneDivider(
            key: studioTreeDividerKey,
            onDragDelta: (d) => setState(
              () => _treeWidthOverride = m.clampTreeWidth(
                dockedWidth + d,
                regionWidth: c.maxWidth - kStudioTapTarget,
              ),
            ),
            onReset: () => setState(() => _treeWidthOverride = null),
          ),
        ],
        Expanded(key: studioEditorPaneKey, child: editor),
      ],
    );

    final overlayTree = showTree && m.treeOverlays;
    return Column(
      children: [
        Expanded(
          // Always a Stack with the split as its first child: swapping
          // `Row` ↔ `Stack` here unmounted the editor (undo, find, scroll and
          // the draft state) every time the compact file panel opened or
          // closed (screen review 06 §7 / F-072).
          child: Stack(
            children: [
              split,
              if (overlayTree)
                Positioned.fill(
                  child: GestureDetector(
                    key: studioTreeScrimKey,
                    behavior: HitTestBehavior.opaque,
                    onTap: () => setState(() => _showFilesOverride = false),
                    child: const ColoredBox(color: Color(0x73000000)),
                  ),
                ),
              if (overlayTree)
                Positioned(
                  left: 0,
                  top: 0,
                  bottom: 0,
                  width: math.min(m.treeWidth, c.maxWidth),
                  child: Material(
                    elevation: 8,
                    color: Aether.surface,
                    child: Semantics(
                      label: 'Files panel',
                      container: true,
                      child: SizedBox(
                        key: studioTreePaneKey,
                        child: StudioFileTree(sessionId: _sid),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

/// App-bar refresh (tests target it).
const Key studioRefreshKey = Key('studio-refresh');

/// App-bar "Agent activity" (the read-only execution log).
const Key studioAgentLogKey = Key('studio-agent-log');

/// No server session exists yet, so there is no workspace to show (ST-002).
/// A clear, calm state — not an error.
class _NoWorkspaceView extends StatelessWidget {
  const _NoWorkspaceView({required this.onRetry});

  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.cloud_outlined, size: 32, color: Aether.textMuted),
              const SizedBox(height: 12),
              Semantics(
                header: true,
                child: Text(
                  'No cloud workspace yet',
                  textAlign: TextAlign.center,
                  style: AetherType.title.copyWith(
                    fontSize: 16,
                    color: Aether.text,
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                StudioFailure.forTree(StudioNoWorkspaceException()).message,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 14,
                  height: 1.5,
                  color: Aether.textMuted,
                ),
              ),
              const SizedBox(height: 16),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                alignment: WrapAlignment.center,
                children: [
                  OutlinedButton(
                    onPressed: () => Navigator.of(context).maybePop(),
                    child: const Text('Back to chat'),
                  ),
                  TextButton(
                    onPressed: onRetry,
                    child: const Text('Check again'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The cloud workspace identity bar.
class _WorkspaceBar extends StatelessWidget {
  const _WorkspaceBar({required this.snapshot});

  final StudioTreeSnapshot? snapshot;

  @override
  Widget build(BuildContext context) {
    final scale = MediaQuery.textScalerOf(context).scale(1.0);
    final count = snapshot?.fileCount;
    final label = count == null
        ? 'Your cloud workspace'
        : 'Your cloud workspace · $count ${count == 1 ? 'file' : 'files'}';
    return Semantics(
      label: label,
      container: true,
      child: Container(
        key: studioWorkspaceBarKey,
        constraints: BoxConstraints(minHeight: 40 * math.max(1.0, scale)),
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          color: Aether.surface,
          border: Border(bottom: BorderSide(color: Aether.hairline)),
        ),
        child: Row(
          children: [
            Icon(Icons.cloud_outlined, size: 16, color: Aether.textMuted),
            const SizedBox(width: 8),
            Expanded(
              child: ExcludeSemantics(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: Aether.text,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The ONE inline status surface for workspace loading (ST-009/ST-010):
/// a load error with human copy and Retry, the waking progress of a cold
/// workspace, or its timed-out state. Only errors are live regions (ST-020).
class _WorkspaceStatus extends StatelessWidget {
  const _WorkspaceStatus({
    required this.failure,
    required this.loading,
    required this.waking,
    required this.wakeTimedOut,
    required this.onRetry,
    required this.onWake,
  });

  final Object? failure;
  final bool loading;
  final bool waking;
  final bool wakeTimedOut;
  final VoidCallback onRetry;
  final VoidCallback onWake;

  @override
  Widget build(BuildContext context) {
    final failure = this.failure;
    if (failure != null) {
      return _strip(
        key: studioStatusErrorKey,
        icon: Icons.cloud_off_outlined,
        color: Aether.warn,
        text: StudioFailure.forTree(failure).message,
        live: true,
        action: TextButton(onPressed: onRetry, child: const Text('Retry')),
      );
    }
    if (wakeTimedOut) {
      return _strip(
        key: studioStatusWakeKey,
        icon: Icons.hourglass_bottom_rounded,
        color: Aether.warn,
        text: 'Your workspace is taking longer than usual to wake up.',
        live: true,
        action: TextButton(onPressed: onWake, child: const Text('Try again')),
      );
    }
    if (waking) {
      return _strip(
        key: studioStatusWakeKey,
        progress: true,
        color: Aether.accent,
        text: 'Waking your workspace… Files appear when it is ready.',
      );
    }
    if (loading) {
      return _strip(
        progress: true,
        color: Aether.accent,
        text: 'Loading your files…',
      );
    }
    return const SizedBox.shrink();
  }

  Widget _strip({
    Key? key,
    IconData? icon,
    bool progress = false,
    required Color color,
    required String text,
    bool live = false,
    Widget? action,
  }) {
    return Semantics(
      key: key,
      liveRegion: live,
      container: true,
      child: Container(
        width: double.infinity,
        color: color.withValues(alpha: 0.12),
        padding: const EdgeInsets.only(left: 12, right: 4, top: 4, bottom: 4),
        constraints: const BoxConstraints(minHeight: kStudioTapTarget),
        child: Row(
          children: [
            if (progress)
              const SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            else
              Icon(icon, size: 16, color: color),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                text,
                style: TextStyle(fontSize: 13, color: Aether.text),
              ),
            ),
            ?action,
          ],
        ),
      ),
    );
  }
}

/// Status strip keys (tests target them).
const Key studioStatusErrorKey = Key('studio-status-error');
const Key studioStatusWakeKey = Key('studio-status-wake');

/// Approval banner shown above the Studio workspace whenever the active
/// session has a pending agent approval. Rendered as an [AetherCard] warn
/// surface so a run-blocking gate stands out from informational banners.
class _ApprovalBanner extends StatelessWidget {
  const _ApprovalBanner({required this.onDecision});

  final void Function(ApprovalRequest request, bool ok) onDecision;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: CloudAgentFacade.I,
      builder: (context, _) {
        final a = CloudAgentFacade.I.pendingApproval;
        if (a == null || a.questions != null || a.planBody != null) {
          return const SizedBox.shrink();
        }
        return Semantics(
          liveRegion: true,
          label: 'Approval required for ${a.tool}. ${a.summary}',
          container: true,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 2),
            child: AetherCard(
              color: Aether.warn.withValues(alpha: 0.08),
              padding: const EdgeInsets.all(14),
              title: Wrap(
                spacing: 8,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Icon(Icons.verified_user_outlined,
                      size: 16, color: Aether.warn),
                  const Text('Approval required'),
                  Text(
                    a.tool.toUpperCase(),
                    style: AetherType.label.copyWith(color: Aether.warn),
                  ),
                ],
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    a.summary.isEmpty
                        ? 'The agent is waiting for your decision.'
                        : a.summary,
                    style: AetherType.body,
                  ),
                  if (a.detail.trim().isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: Aether.surfaceAlt,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: Aether.hairline),
                      ),
                      constraints: const BoxConstraints(maxHeight: 160),
                      child: Scrollbar(
                        child: SingleChildScrollView(
                          key: ObjectKey(a),
                          child: Text(
                            a.detail,
                            style: TextStyle(
                              fontFamily: Aether.mono,
                              fontFamilyFallback: kStudioMonoFallback,
                              fontSize: 12,
                              color: Aether.textMuted,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                  const SizedBox(height: 12),
                  Wrap(
                    alignment: WrapAlignment.end,
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      SizedBox(
                        width: 140 *
                            math.max(1.0,
                                MediaQuery.textScalerOf(context).scale(1.0)),
                        child: AetherGhostButton(
                          label: 'Decline',
                          icon: Icons.block,
                          onPressed: () => onDecision(a, false),
                        ),
                      ),
                      SizedBox(
                        width: 140 *
                            math.max(1.0,
                                MediaQuery.textScalerOf(context).scale(1.0)),
                        child: AetherPrimaryButton(
                          label: 'Approve',
                          icon: Icons.check,
                          onPressed: () => onDecision(a, true),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
