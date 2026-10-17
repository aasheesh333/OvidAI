import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../core/agent_service.dart';
import '../core/cloud/studio_files.dart';
import '../core/cloud/studio_remote_client.dart';
import '../core/github_service.dart';
import '../core/state.dart';
import '../core/studio_drafts.dart';
import '../core/theme.dart';
import 'github_login_sheet.dart';
import 'studio_editor.dart';
import 'studio_errors.dart';
import 'studio_file_tree.dart';
import 'studio_layout.dart';
import 'studio_terminal_tabs.dart';
import 'widgets/aether_primitives.dart';

// Studio's panes live in their own libraries; re-exported so callers (and the
// existing widget tests) keep reaching them through this one import.
export 'studio_editor.dart' show StudioEditor, StudioEditorTabs;
export 'studio_file_tree.dart' show StudioFileTree;
export 'studio_terminal_tabs.dart'
    show StudioTerminalTabs, studioTerminalStopKey;

/// Test seam: overrides the GitHub login prompt so host widget tests can
/// assert the Studio auth gate without starting a real device flow.
/// Production is null (the real modal bottom sheet).
@visibleForTesting
void Function(BuildContext context)? studioLoginPromptOverrideForTest;

/// Studio — remote coding workspace: the P7 file tree/editor over the cloud
/// workspace API plus the P2 terminal channel.
///
/// Local git UI (branch chips, sync progress, commit staging, credential env)
/// is GONE: the server owns the workspace and the git tools. The layout is
/// breakpoint-driven ([StudioMetrics]): below 840dp the file tree stops being
/// docked, below 600dp it becomes an overlay, and on a short viewport the
/// terminal collapses rather than squeezing the editor below a usable height.
class StudioScreen extends StatefulWidget {
  /// Set when Studio is opened by a setup flow. [_handleInitialAuth] then
  /// fires the one-time GitHub login prompt from its own branch instead of
  /// the regular path, so the sheet can never pop twice.
  final bool postInstallGithubPrompt;
  const StudioScreen({super.key, this.postInstallGithubPrompt = false});
  @override
  State<StudioScreen> createState() => _StudioScreenState();
}

class _StudioScreenState extends State<StudioScreen> {
  /// User's explicit choice for the tree. Null means "use the breakpoint
  /// default", so rotating a phone to tablet width re-docks the tree instead
  /// of fighting the user's last decision on the old geometry.
  bool? _showFilesOverride;

  /// User drags. Null means "use the breakpoint default"; every read goes
  /// back through [StudioMetrics.clampTreeWidth] / [clampTerminalHeight] so a
  /// stale drag value can never starve the editor after a rotation.
  double? _treeWidthOverride;
  double? _terminalHeightOverride;
  bool? _terminalCollapsedOverride;

  bool _refreshing = false;
  bool _handledInitialAuth = false;
  String _sessionId = '';

  /// Whether the active Studio bucket holds unsaved editor drafts. Kept in
  /// its own notifier so the guard does not rebuild the screen per token.
  final ValueNotifier<bool> _hasDrafts = ValueNotifier(false);
  bool _leaving = false;

  String get _sid => _sessionId;
  StudioRemoteClient get _remote => StudioRemoteClient.I;

  late final Listenable _sessionSignals =
      Listenable.merge([AppState.I, GitHubService.I, _remote, _hasDrafts]);

  void _syncDraftFlag() =>
      _hasDrafts.value = _remote.dirtyFiles(_sid).isNotEmpty;

  @override
  void initState() {
    super.initState();
    _sessionId = AppState.I.activeSession?.id ?? '';
    GitHubService.I.addListener(_handleInitialAuth);
    AppState.I.addListener(_onWorkspaceChanged);
    _remote.tabsFor(_sid).addListener(_syncDraftFlag);
    _syncDraftFlag();
    unawaited(GitHubService.I.retryRestoreFromUi());
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _handleInitialAuth();
      _refreshTree();
    });
  }

  @override
  void dispose() {
    GitHubService.I.removeListener(_handleInitialAuth);
    AppState.I.removeListener(_onWorkspaceChanged);
    _remote.tabsFor(_sid).removeListener(_syncDraftFlag);
    _hasDrafts.dispose();
    // Leaving Studio is a good moment to make sure drafts are on disk.
    unawaited(StudioDraftStore.I.flush());
    super.dispose();
  }

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
              'Could not save ${failed.length} file(s)',
              detail: failed.join(', '),
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

  void _onWorkspaceChanged() {
    final next = AppState.I.activeSession?.id ?? '';
    if (next == _sessionId) return;
    _remote.tabsFor(_sid).removeListener(_syncDraftFlag);
    setState(() => _sessionId = next);
    _remote.tabsFor(_sid).addListener(_syncDraftFlag);
    _syncDraftFlag();
    unawaited(_refreshTree());
  }

  void _handleInitialAuth() {
    final github = GitHubService.I;
    if (!mounted || _handledInitialAuth) return;
    if (widget.postInstallGithubPrompt) {
      if (github.isInitializing) return;
      _handledInitialAuth = true;
      if (!github.isLoggedIn) {
        (studioLoginPromptOverrideForTest ?? showGithubLoginSheet)(context);
      }
      return;
    }
    if (github.isLoggedIn) {
      if (github.isInitializing || github.login == null) return;
      _handledInitialAuth = true;
      return;
    }
    if (github.isInitializing) return;
    // A failed storage read is not a sign-out; retryRestoreFromUi() may
    // recover it seconds later.
    if (github.restoreFailed) return;
    _handledInitialAuth = true;
    (studioLoginPromptOverrideForTest ?? showGithubLoginSheet)(context);
  }

  /// Refreshes the P7 workspace tree (the <100 ms manifest path).
  Future<void> _refreshTree() async {
    if (_sid.isEmpty || _refreshing) return;
    setState(() => _refreshing = true);
    final snapshot = await _remote.syncStudioTabs(_sid);
    if (!mounted) return;
    setState(() => _refreshing = false);
    if (snapshot == null && _remote.treeError(_sid) != null) {
      showStudioToast(
        context,
        'Could not load the workspace tree',
        detail: _remote.treeError(_sid),
        error: true,
      );
    }
  }

  void _toggleFiles() => setState(() {
        _showFilesOverride = !(_showFilesOverride ?? _treeDefaultFor(context));
      });

  bool _treeDefaultFor(BuildContext context) =>
      MediaQuery.sizeOf(context).width >= StudioMetrics.wideBreakpoint;

  @override
  Widget build(BuildContext context) {
    if (_sid.isEmpty) return const _NoSessionStudio();
    return AnimatedBuilder(
      animation: _sessionSignals,
      builder: (context, _) {
        final compactActions =
            MediaQuery.sizeOf(context).width < StudioMetrics.mediumBreakpoint;
        // On a compact width the tree is an overlay, so Android's back gesture
        // must dismiss it before it leaves the screen.
        final treeOverlayOpen = compactActions && (_showFilesOverride ?? false);
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
            appBar: _appBar(compactActions),
            body: SafeArea(
              child: StudioPaneViewport(
                // Keep the tab strip, a real editor viewport and terminal chrome
                // reachable even under a long approval or the software keyboard.
                minContentHeight: 122 +
                    math.max(1.0, MediaQuery.textScalerOf(context).scale(1.0)) *
                        (kStudioTapTarget +
                            (_terminalCollapsedOverride == false
                                ? StudioMetrics.collapsedBarHeight +
                                    StudioMetrics.commandRowHeight
                                : StudioMetrics.collapsedBarHeight)),
                chrome: [
                  _WorkspaceBar(
                    snapshot: _remote.snapshotFor(_sid),
                    loading: _remote.treeLoading(_sid),
                    onRefresh: _refreshing ? null : _refreshTree,
                  ),
                  // A run-blocking approval is impossible to miss — Approve
                  // resolves the gate, Decline rejects it.
                  _ApprovalBanner(
                    onDecision: (a, ok) {
                      // Bound to the request the banner rendered: a stale tap
                      // must never resolve the NEXT pending approval.
                      if (!AgentService.I.approveRequest(a, ok)) return;
                      if (!ok) {
                        showStudioToast(context, 'Declined ${a.tool}');
                      }
                    },
                  ),
                  if (_remote.treeError(_sid) != null)
                    _TreeErrorBanner(
                      detail: _remote.treeError(_sid),
                      onRetry: _refreshing ? null : _refreshTree,
                    ),
                  if (_refreshing)
                    const _StatusBanner('Loading cloud workspace…'),
                ],
                child: LayoutBuilder(builder: _workspace),
              ),
            ),
          ),
        );
      },
    );
  }

  PreferredSizeWidget _appBar(bool compactActions) {
    final showFiles = _showFilesOverride ?? _treeDefaultFor(context);
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
        StudioIconButton(
          icon: showFiles ? Icons.folder_open : Icons.folder_outlined,
          tooltip: 'Toggle files',
          onPressed: _toggleFiles,
        ),
        StudioIconButton(
          icon: Icons.sync_rounded,
          tooltip: 'Refresh workspace',
          iconSize: 18,
          color: Aether.accent,
          onPressed: _refreshing ? null : _refreshTree,
        ),
        _AccountChip(compact: compactActions),
        const _AuthBadge(),
        const SizedBox(width: 4),
      ],
    );
  }

  /// The tree/editor/terminal split for the height that is actually left
  /// after the app bar, workspace bar and any banners.
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
    // An explicit collapse wins; otherwise a viewport too short for both
    // panes collapses the terminal instead of squeezing the editor.
    final collapsed = _terminalCollapsedOverride ?? !m.terminalFits;
    final requestedTerminalHeight = collapsed
        ? StudioMetrics.collapsedBarHeight * m.textScale
        : m.resolveTerminalHeight(
            _terminalHeightOverride ?? m.terminalHeight,
            regionHeight: c.maxHeight,
          );
    final terminalHeight = math.min(
        requestedTerminalHeight,
        math.max(
            0.0, c.maxHeight - (kStudioTapTarget * m.textScale + 122)));

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
        SizedBox(
          key: studioTerminalPaneKey,
          height: terminalHeight,
          child: StudioTerminalTabs(
            sessionId: _sid,
            collapsed: collapsed,
            onToggleCollapse: () => setState(
              () => _terminalCollapsedOverride = !collapsed,
            ),
            onResizeDrag: collapsed
                ? null
                : (d) => setState(
                      () => _terminalHeightOverride = m.resolveTerminalHeight(
                        terminalHeight - d,
                        regionHeight: c.maxHeight,
                      ),
                    ),
          ),
        ),
      ],
    );
  }
}

class _NoSessionStudio extends StatelessWidget {
  const _NoSessionStudio();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Aether.bg,
      appBar: AppBar(title: const Text('Studio')),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            'Open a chat to use Studio.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 15, color: Aether.textMuted),
          ),
        ),
      ),
    );
  }
}

/// The cloud workspace identity bar (replaces the deleted local repo bar).
class _WorkspaceBar extends StatelessWidget {
  const _WorkspaceBar({
    required this.snapshot,
    required this.loading,
    required this.onRefresh,
  });

  final StudioTreeSnapshot? snapshot;
  final bool loading;
  final VoidCallback? onRefresh;

  @override
  Widget build(BuildContext context) {
    final scale = MediaQuery.textScalerOf(context).scale(1.0);
    final state = snapshot?.state ?? (loading ? 'hydrating' : 'unknown');
    final label = snapshot == null
        ? (loading ? 'Loading workspace…' : 'Cloud workspace')
        : 'Cloud workspace · $state · ${snapshot!.fileCount} files';
    return Semantics(
      label: label,
      container: true,
      child: Container(
        key: studioRepoBarKey,
        constraints: BoxConstraints(minHeight: 48 * math.max(1.0, scale)),
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
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                  color: Aether.text,
                ),
              ),
            ),
            if (snapshot != null)
              Tag(
                snapshot!.source == 'manifest' ? 'MANIFEST' : 'LIVE',
                color: Aether.textMuted,
              ),
            StudioIconButton(
              icon: Icons.refresh,
              tooltip: 'Refresh workspace',
              iconSize: 18,
              onPressed: onRefresh,
            ),
          ],
        ),
      ),
    );
  }
}

/// Workspace tree failure: a human sentence, with the raw text demoted to a
/// secondary line and a real 44dp retry.
class _TreeErrorBanner extends StatelessWidget {
  const _TreeErrorBanner({required this.detail, required this.onRetry});

  final String? detail;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      liveRegion: true,
      label: 'Could not load the workspace tree.',
      container: true,
      child: Container(
        width: double.infinity,
        color: Aether.warn.withValues(alpha: 0.12),
        padding: const EdgeInsets.only(left: 12, right: 2, top: 2, bottom: 2),
        child: Row(
          children: [
            Icon(Icons.cloud_off_outlined, size: 16, color: Aether.warn),
            const SizedBox(width: 8),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Could not load the workspace tree',
                      style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                        color: Aether.warn,
                      ),
                    ),
                    if (detail != null && detail!.isNotEmpty)
                      Text(
                        StudioFailure.of(StateError(detail!)).message,
                        style: TextStyle(
                          fontSize: kStudioMinFontSize,
                          color: Aether.textFaint,
                        ),
                      ),
                  ],
                ),
              ),
            ),
            StudioIconButton(
              icon: Icons.refresh,
              tooltip: 'Retry',
              iconSize: 18,
              onPressed: onRetry,
            ),
          ],
        ),
      ),
    );
  }
}

class _StatusBanner extends StatelessWidget {
  const _StatusBanner(this.label);
  final String label;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      liveRegion: true,
      label: label,
      container: true,
      child: Container(
        width: double.infinity,
        color: Aether.accent.withValues(alpha: 0.12),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        child: Row(
          children: [
            const SizedBox(
              width: 13,
              height: 13,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: 9),
            Expanded(
              child: Text(
                label,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12, color: Aether.text),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// GitHub connection state.
///
/// This used to be a bare 9×9px colour-only dot: green/amber/red with no
/// shape, no text and no semantics, so it was invisible to a screen reader
/// and unreadable for anyone with a colour vision deficiency. Each state now
/// has its own silhouette, a semantics label and a tooltip.
class _AuthBadge extends StatelessWidget {
  const _AuthBadge();

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: GitHubService.I,
      builder: (context, _) {
        final gh = GitHubService.I;
        final loggedIn = gh.isLoggedIn;
        final unknown = !loggedIn && (gh.restoreFailed || gh.isInitializing);

        final IconData icon;
        final Color color;
        final String label;
        if (loggedIn) {
          icon = Icons.check_circle;
          color = Aether.success;
          label = 'Signed in to GitHub';
        } else if (unknown) {
          icon = Icons.hourglass_top;
          color = Aether.warn;
          label = 'Checking your GitHub sign-in…';
        } else {
          icon = Icons.cancel;
          color = Aether.danger;
          label = 'Not signed in to GitHub';
        }

        return Semantics(
          liveRegion: true,
          label: label,
          child: Tooltip(
            message: label,
            child: SizedBox(
              width: 30,
              height: kStudioTapTarget,
              child: Center(child: Icon(icon, size: 16, color: color)),
            ),
          ),
        );
      },
    );
  }
}

/// ── GitHub account chip with avatar, login name, and sign-out menu ──
class _AccountChip extends StatelessWidget {
  const _AccountChip({required this.compact});

  /// Below 600dp the chip drops its login text and chevron: the app bar has
  /// back + title + tree toggle + refresh + auth badge to fit as well.
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: GitHubService.I,
      builder: (_, _) {
        final gh = GitHubService.I;
        if (!gh.isLoggedIn) {
          return const SizedBox.shrink();
        }
        return PopupMenuButton<String>(
          tooltip: 'GitHub account',
          padding: EdgeInsets.zero,
          position: PopupMenuPosition.under,
          onSelected: (v) {
            if (v == 'signout') _confirmSignOut(context, gh);
          },
          itemBuilder: (_) => [
            PopupMenuItem(
              enabled: false,
              child: Row(
                children: [
                  _Avatar(url: gh.avatarUrl, size: 24),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          gh.name ?? gh.login ?? '',
                          style: const TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        Text(
                          '@${gh.login ?? ''}',
                          style: TextStyle(
                            fontSize: kStudioMinFontSize,
                            color: Aether.textFaint,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const PopupMenuDivider(height: 6),
            PopupMenuItem(
              value: 'signout',
              child: Row(
                children: [
                  Icon(Icons.logout, size: 16, color: Aether.danger),
                  const SizedBox(width: 8),
                  Text(
                    'Sign out',
                    style: TextStyle(fontSize: 12.5, color: Aether.danger),
                  ),
                ],
              ),
            ),
          ],
          child: Semantics(
            button: true,
            label: 'GitHub account ${gh.login ?? ''}',
            child: ConstrainedBox(
              constraints: const BoxConstraints(
                minWidth: kStudioTapTarget,
                minHeight: kStudioTapTarget,
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _Avatar(url: gh.avatarUrl, size: 20),
                    if (!compact) ...[
                      const SizedBox(width: 6),
                      Flexible(
                        child: Text(
                          gh.login ?? '',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 12,
                            color: Aether.textMuted,
                          ),
                        ),
                      ),
                      Icon(
                        Icons.expand_more,
                        size: 15,
                        color: Aether.textFaint,
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

  void _confirmSignOut(BuildContext context, GitHubService gh) {
    showDialog(
      context: context,
      builder: (d) => AlertDialog(
        title: const Text(
          'Sign out of GitHub?',
          style: TextStyle(fontSize: 15),
        ),
        content: const Text(
          'The repo connection will be cleared. Your GitHub access token is '
          'removed from this device only.',
          style: TextStyle(fontSize: 12.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(d),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () async {
              Navigator.pop(d);
              try {
                await gh.signOut();
              } catch (e) {
                if (!context.mounted) return;
                showStudioToast(
                  context,
                  'Signed out, but the saved token could not be removed.',
                  detail: StudioFailure.of(e).detail,
                  error: true,
                );
              }
            },
            child: Text('Sign out', style: TextStyle(color: Aether.danger)),
          ),
        ],
      ),
    );
  }
}

class _Avatar extends StatelessWidget {
  final String? url;
  final double size;
  const _Avatar({required this.url, required this.size});

  @override
  Widget build(BuildContext context) {
    if (url == null || url!.isEmpty) {
      return Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: Aether.surfaceRaised,
          shape: BoxShape.circle,
        ),
        child: Icon(
          Icons.person_outline,
          size: size * 0.55,
          color: Aether.textMuted,
        ),
      );
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(size / 2),
      child: Image.network(
        url!,
        width: size,
        height: size,
        fit: BoxFit.cover,
        cacheWidth: Aether.imageCacheWidth(context, logicalWidth: size),
        errorBuilder: (_, _, _) => Container(
          width: size,
          height: size,
          color: Aether.surfaceRaised,
          child: Icon(
            Icons.person_outline,
            size: size * 0.55,
            color: Aether.textMuted,
          ),
        ),
      ),
    );
  }
}

/// Approval banner shown above the Studio workspace whenever the active
/// session has a pending agent approval. Rendered as an [AetherCard] warn
/// surface so a run-blocking gate stands out from informational banners.
class _ApprovalBanner extends StatelessWidget {
  const _ApprovalBanner({required this.onDecision});

  final void Function(ApprovalRequest request, bool ok) onDecision;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: AgentService.I,
      builder: (context, _) {
        final a = AgentService.I.pendingApproval;
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
