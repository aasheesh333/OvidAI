import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../core/agent_service.dart';
import '../core/commands.dart';
import '../core/device_control_service.dart';
import '../core/diag.dart';
import '../core/format.dart';
import '../core/presets.dart';
import '../core/skills.dart';
import '../core/startup_coordinator.dart';
import '../core/state.dart';
import '../core/studio_setup_coordinator.dart';
import '../core/theme.dart';
import 'browser_screen.dart';
import 'chat/composer.dart';
import 'chat/docks.dart';
import 'chat/sheets.dart';
import 'chat/transcript.dart';
import 'chat_layout.dart';
import 'plugins_screen.dart';
import 'sandbox_setup.dart';
import 'sidebar.dart';
import 'startup_progress_panel.dart';
import 'transcript_model.dart';

/// Public seams that moved into `chat/` — re-exported so existing imports
/// of this library keep working.
export 'chat/docks.dart' show QueueRowAction, queueRowActions;
export 'chat/transcript.dart' show ChatTranscript, ovidFontColor;

/// Chat screen — Gemini/DeepSeek grade: reasoning chips, code blocks,
/// in-chat image generation card, model picker, utility input bar.
///
/// This file is the screen shell only: the scaffold, AppBar, transcript
/// list with lazy paging and keyed scroll anchoring, per-session composer
/// drafts, and the Control-mode enable flow. The building blocks live in
/// `chat/`:
///
/// * `chat/transcript.dart` — every transcript row (messages, tool cards,
///   artifacts, markdown) plus the read-only [ChatTranscript].
/// * `chat/composer.dart` — the input bar: attachment chips, slash/`@`
///   menus, Send/Queue/Stop.
/// * `chat/docks.dart` — goal/todo/stats/queue/approval docks (two
///   visible, overflow in one expandable activity dock).
/// * `chat/sheets.dart` — model picker, agent access mode, session
///   metrics.

class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key, this.startupCoordinator});

  /// Startup coordinator rendered by the readiness dashboard. Defaults to
  /// the process singleton; tests inject an isolated instance.
  final StartupCoordinator? startupCoordinator;

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

/// Optional diagnostic observer invoked when the keyed anchor row is not built
/// after a prepend and the coarse extent-delta fallback runs. `null` in
/// production, so the restore path stays free of global side effects; tests
/// inject a counter to prove the fallback was exercised. Not read by any
/// production code path.
void Function()? transcriptAnchorFallbackObserver;

/// A keyed scroll anchor: the transcript item key that was at the top of the
/// viewport when a page of older history began loading, plus the offset it had
/// from the viewport top (and the scroll metrics at capture time, used only
/// for the coarse out-of-cache fallback).
class _ScrollAnchor {
  final Object key;
  final double viewportOffset;
  final double pixels;
  final double maxScrollExtent;

  const _ScrollAnchor({
    required this.key,
    required this.viewportOffset,
    required this.pixels,
    required this.maxScrollExtent,
  });
}

class _ChatScreenState extends State<ChatScreen>
    with SingleTickerProviderStateMixin {
  final _input = TextEditingController();
  final _scroll = ScrollController();

  /// Focus node for the composer text field: the queue dock's "Edit in
  /// composer" action moves a queued message into the composer and hands
  /// it focus so the user can edit and resend immediately.
  final _inputFocus = FocusNode();

  /// web-IDE auto-scroll: when the user is at the bottom, we follow the
  /// stream; as soon as they scroll up we stop moving; when they return to
  /// the bottom we resume following.
  bool _atBottom = true;
  bool _showJumpFab = false;

  // ── Pinch-to-zoom on the message list ──
  // Two-finger pinch scales ONLY the chat content fonts (header + composer
  // chatbox stay fixed). We track the scale at gesture start so each pinch
  // is relative, then persist the result. Width stays responsive — text
  // reflows, never horizontal-scrolls.
  double _pinchStartScale = 1.0;

  // ── Per-session composer drafts ─────────────────────────────────────
  // Bug fix: the old single controller leaked the draft across sessions —
  // typing in session A, switching to B, then creating a new session kept
  // showing A's text. We stash the current text on session switch and
  // restore the target session's draft (like DeepSeek web / ChatGPT web).
  final Map<String, String> _drafts = {};
  String? _boundSessionId;
  final Map<String, int> _draftVersions = {};
  bool _restoringDraft = false;
  String _observedDraftText = '';
  final Map<String, ({int id, String original})> _queueEdits = {};

  void _recordDraftEdit() {
    if (_observedDraftText == _input.text) return;
    _observedDraftText = _input.text;
    final sid = _boundSessionId;
    if (sid != null && !_restoringDraft) {
      _draftVersions[sid] = (_draftVersions[sid] ?? 0) + 1;
    }
  }

  void _clearSubmittedDraft(String sid, String text, int version) {
    if (!mounted || (_draftVersions[sid] ?? 0) != version) return;
    if (_boundSessionId == sid) {
      if (_input.text != text) return;
      _input.clear();
    } else if (_drafts[sid] != text) {
      return;
    }
    _drafts.remove(sid);
  }

  // ── Lazy message paging (ChatGPT/Claude style) ──
  // Long threads render ONLY the last [_visibleCount] folded items; a
  // "Load earlier" row at the top pulls in older history on demand, so a
  // 500-message chat never lags the phone (or re-builds on every token).
  static const _pageSize = 40;
  int _visibleCount = _pageSize;
  bool _paging = false; // blocks re-entrant top-of-list pagination
  bool _hasEarlier = false; // older messages exist above the visible window

  // ── Keyed scroll anchoring (Task 7) ──
  // Paging older history records the top visible item's key + offset before
  // the window grows, then restores that item to the same offset afterwards,
  // so prepended rows never jump the viewport. Tip-follow keeps an at-bottom
  // user pinned; a scrolled-up user is never moved.

  /// Row keys for the transcript list currently on screen: index = ListView
  /// row, value = the item's stable key (its first message index) or a
  /// sentinel for the non-message rows (paging affordance / typing / produced
  /// card). Used to locate the anchored row after a prepend.
  List<Object> _rowKeys = const [];
  static const Object _affordanceRowKey = 'transcript-affordance';
  static const Object _tailRowKey = 'transcript-tail';

  /// True while a post-frame bottom-follow jump is already scheduled. Bursts
  /// of rebuilds within one frame are collapsed into a single jump.
  bool _followScheduled = false;

  // ── Windowed transcript cache (Task 4) ──
  // The folded window is recomputed only when the session, message count, the
  // identity/kind/thinking of the last message, `showReasoning`, or the pager
  // window changes. Streaming token appends mutate the live message's content
  // in place, so they never invalidate the fold.
  TranscriptWindow? _windowCache;
  String? _windowSessionId;
  int _windowCount = -1;
  Message? _windowLast;
  MsgKind? _windowLastKind;
  bool _windowLastThinking = false;
  bool _windowShowReasoning = false;
  bool _windowCompact = true;
  int _windowVisibleCount = -1;

  // NOTE: the ListView is intentionally NOT memoized by widget identity.
  // Doing so froze per-row UI state (a like/dislike tap mutates `m.feedback`
  // and calls setState, but the memo fast-path returned the identical list
  // and the icon never repainted). The expensive part — folding the history —
  // is cached above; the cheap list rebuild is left to Flutter.

  void _bindDraft(String sessionId) {
    if (!mounted || AppState.I.activeSessionId != sessionId) return;
    if (_boundSessionId == sessionId) return;
    // Save outgoing session's draft.
    if (_boundSessionId != null && _input.text.isNotEmpty) {
      _drafts[_boundSessionId!] = _input.text;
    } else if (_boundSessionId != null) {
      _drafts.remove(_boundSessionId);
    }
    // Restore incoming session's draft.
    final draft = _drafts[sessionId] ?? '';
    _restoringDraft = true;
    if (_input.text != draft) {
      _input.value = TextEditingValue(
        text: draft,
        selection: TextSelection.collapsed(offset: draft.length),
      );
    }
    _boundSessionId = sessionId;
    _restoringDraft = false;
    // Reset scroll-follow state per session so a fresh session starts at
    // the bottom, not mid-stream.
    _atBottom = true;
    _showJumpFab = false;
    _visibleCount = _pageSize; // lazy paging resets per session
    _followScheduled = false; // tip-follow re-arms for the new transcript
  }

  void _openPlugins(BuildContext context, {String? focusCanonicalId}) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => PluginsScreen(focusCanonicalId: focusCanonicalId),
      ),
    );
  }

  @override
  void initState() {
    super.initState();
    // An approval UI is now mounted: tool approval cards are answerable.
    // (AgentService.approvalUiReady gates the fail-closed grace in _askUser.)
    // Counted, not a bool: during a navigation overlap this screen's initState
    // can run before the outgoing one's dispose, and a plain flag would be
    // cleared by that dispose while a visible UI is still here to answer.
    AgentService.markApprovalUiMounted();
    _input.addListener(_recordDraftEdit);
    _scroll.addListener(_onScroll);
  }

  @override
  void dispose() {
    // One fewer approval UI able to answer.
    AgentService.markApprovalUiDisposed();
    _scroll.dispose();
    _input.dispose();
    _inputFocus.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    final pos = _scroll.position;
    // 24px dead-zone treats "almost at bottom" as at bottom.
    final atBottom = pos.maxScrollExtent - pos.pixels < 24;
    if (atBottom != _atBottom) {
      setState(() {
        _atBottom = atBottom;
        _showJumpFab = !atBottom;
      });
    }
    // ChatGPT/Gemini-style lazy paging: scroll to the top and more history
    // slides in automatically — no "Show earlier" tapping.
    if (!_paging && pos.pixels < 120 && _hasEarlier) {
      _paging = true;
      // Keyed anchor (Task 7): capture the top visible message AFTER the new
      // scroll offset has laid out (this listener runs before that layout),
      // then grow the window. Once the prepend lays out, restore that same
      // message to the same offset instead of trusting the maxScrollExtent
      // delta (which also moves when the tip streams).
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_scroll.hasClients) {
          _paging = false;
          return;
        }
        final anchor = _captureTopAnchor();
        setState(() => _visibleCount += _pageSize);
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _restoreAnchor(anchor);
          _paging = false;
        });
      });
    }
  }

  /// The bounded folded window for [s], recomputed only when its inputs
  /// change (Task 4). Streaming token appends mutate the live message in
  /// place, so the identity/last-kind checks keep the cache warm across
  /// tokens and the full history is never re-folded.
  TranscriptWindow _transcriptWindow(ChatSession s) {
    final showReasoning = AppState.I.showReasoning;
    final compact = !AppState.I.conversationFull;
    final messages = s.messages;
    final count = messages.length;
    final last = count == 0 ? null : messages.last;
    final lastKind = last?.kind;
    final lastThinking = last?.thinking ?? false;
    if (_windowCache == null ||
        _windowSessionId != s.id ||
        _windowCount != count ||
        !identical(_windowLast, last) ||
        _windowLastKind != lastKind ||
        _windowLastThinking != lastThinking ||
        _windowShowReasoning != showReasoning ||
        _windowCompact != compact ||
        _windowVisibleCount != _visibleCount) {
      _windowCache = windowForBounded(
        messages,
        pageSize: _pageSize,
        visibleCount: _visibleCount,
        showReasoning: showReasoning,
        compact: compact,
      );
      _windowSessionId = s.id;
      _windowCount = count;
      _windowLast = last;
      _windowLastKind = lastKind;
      _windowLastThinking = lastThinking;
      _windowShowReasoning = showReasoning;
      _windowCompact = compact;
      _windowVisibleCount = _visibleCount;
    }
    return _windowCache!;
  }

  /// Stable key for a folded transcript item: the absolute message index of
  /// its first message. Prepending older history does not change it, so the
  /// same key identifies the same row before and after a page loads.
  Object _itemKey(ChatItem item) =>
      item is SingleItem ? item.index : (item as FoldedGroup).indices.first;

  /// Row keys for the window currently rendered. Row 0 is the paging
  /// affordance when history is hidden; the tail row is the typing/produced
  /// card. Message rows carry their [_itemKey].
  List<Object> _computeRowKeys(
    TranscriptWindow window,
    bool typing,
    bool showProduced,
  ) {
    final keys = <Object>[];
    if (window.hiddenMessages > 0) keys.add(_affordanceRowKey);
    for (final item in window.visible) {
      keys.add(_itemKey(item));
    }
    if (typing || showProduced) keys.add(_tailRowKey);
    return keys;
  }

  /// The `RenderSliverList` backing the transcript, or null before layout.
  RenderSliverMultiBoxAdaptor? _transcriptSliver() {
    if (!_scroll.hasClients) return null;
    final context = _scroll.position.context.storageContext;
    return _findSliver(context.findRenderObject());
  }

  RenderSliverMultiBoxAdaptor? _findSliver(RenderObject? node) {
    if (node == null) return null;
    if (node is RenderSliverMultiBoxAdaptor) return node;
    RenderSliverMultiBoxAdaptor? found;
    node.visitChildren((child) {
      found ??= _findSliver(child);
    });
    return found;
  }

  /// Records the top visible message row and its offset from the viewport
  /// top. Skips the paging affordance / tail rows so the anchor is always a
  /// real transcript item.
  _ScrollAnchor? _captureTopAnchor() {
    if (!_scroll.hasClients) return null;
    final sliver = _transcriptSliver();
    if (sliver == null) return null;
    final pixels = _scroll.position.pixels;
    RenderBox? candidate;
    RenderBox? child = sliver.firstChild;
    while (child != null) {
      final row = sliver.indexOf(child);
      if (row >= 0 && row < _rowKeys.length) {
        final key = _rowKeys[row];
        if (key != _affordanceRowKey && key != _tailRowKey) {
          final offset = sliver.childScrollOffset(child);
          if (offset != null) {
            if (offset <= pixels) {
              candidate = child;
            } else {
              candidate ??= child;
              break;
            }
          }
        }
      }
      child = sliver.childAfter(child);
    }
    if (candidate == null) return null;
    final row = sliver.indexOf(candidate);
    final offset = sliver.childScrollOffset(candidate);
    if (row < 0 || row >= _rowKeys.length || offset == null) return null;
    return _ScrollAnchor(
      key: _rowKeys[row],
      viewportOffset: offset - pixels,
      pixels: pixels,
      maxScrollExtent: _scroll.position.maxScrollExtent,
    );
  }

  /// Layout offset of the row carrying [key], or null when it is outside the
  /// sliver's built (visible + cache) range.
  double? _anchorLayoutOffset(Object key) {
    final sliver = _transcriptSliver();
    if (sliver == null) return null;
    RenderBox? child = sliver.firstChild;
    while (child != null) {
      final row = sliver.indexOf(child);
      if (row >= 0 && row < _rowKeys.length && _rowKeys[row] == key) {
        return sliver.childScrollOffset(child);
      }
      child = sliver.childAfter(child);
    }
    return null;
  }

  void _jumpToOffset(double target) {
    if (!_scroll.hasClients) return;
    final pos = _scroll.position;
    _scroll.jumpTo(target.clamp(pos.minScrollExtent, pos.maxScrollExtent));
  }

  /// Restores the anchored row to the viewport offset it had before the
  /// prepend. If a very large prepend pushed it beyond the built cache, make
  /// a coarse extent-delta jump to bring it back into range and re-locate the
  /// keyed row on the next frame for the exact restore.
  void _restoreAnchor(_ScrollAnchor? anchor) {
    if (anchor == null || !mounted || !_scroll.hasClients) return;
    final offset = _anchorLayoutOffset(anchor.key);
    if (offset != null) {
      _jumpToOffset(offset - anchor.viewportOffset);
      return;
    }
    transcriptAnchorFallbackObserver?.call();
    final delta = _scroll.position.maxScrollExtent - anchor.maxScrollExtent;
    _jumpToOffset(anchor.pixels + delta);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      final retry = _anchorLayoutOffset(anchor.key);
      if (retry != null) _jumpToOffset(retry - anchor.viewportOffset);
    });
  }

  /// Called from the message-list builder on every rebuild — keeps the stream
  /// pinned to the bottom while the user is at the bottom.
  ///
  /// The jump is NOT gated on a tip key/count signature: a live stream mutates
  /// the last message IN PLACE (`AppState.refresh()` per token), so the folded
  /// window's key and row count stay constant even though the rendered height
  /// grows every token. A signature-only gate stopped following mid-stream and
  /// let new tokens scroll off-screen (Task 7 review I1). Instead, schedule a
  /// post-frame jump whenever [_atBottom] is true; [_followScheduled] collapses
  /// redundant schedules within a frame, and the callback re-checks [_atBottom]
  /// so a user who scrolls up is never yanked to the bottom.
  void _maybeFollowTip() {
    if (!_atBottom) return;
    if (_followScheduled) return;
    _followScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _followScheduled = false;
      if (!mounted || !_scroll.hasClients) return;
      // Re-check: the user may have scrolled up before the frame settled.
      if (!_atBottom) return;
      _scroll.jumpTo(_scroll.position.maxScrollExtent);
    });
  }

  @override
  Widget build(BuildContext context) {
    final app = AppState.I;
    return AnimatedBuilder(
      animation: app,
      builder: (_, _) {
        final s = app.activeSession;
        // Restore the draft that belongs to THIS session — never leak
        // another session's composer text.
        if (s != null) {
          WidgetsBinding.instance.addPostFrameCallback((_) => _bindDraft(s.id));
        }
        final wide = MediaQuery.of(context).size.width >= 840;
        return Scaffold(
          backgroundColor: Aether.bg,
          drawer: wide
              ? null
              : Drawer(
                  width: 288,
                  backgroundColor: Aether.surface,
                  child: SessionsSidebar(),
                ),
          appBar: AppBar(
            automaticallyImplyLeading: !wide,
            title: GestureDetector(
              onTap: () => _modelPicker(context),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                   Flexible(
                    child: Text(
                       s?.model == null || s!.model.trim().isEmpty
                           ? 'Select model'
                           : ovidModelLabel(s.model),
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 14),
                    ),
                  ),
                  const SizedBox(width: 4),
                  Icon(Icons.unfold_more, size: 16, color: Aether.textFaint),
                ],
              ),
            ),
            actions: [
              // PR27/B1: the subagents + trajectory icons moved OFF the
              // header (user ask) — subagents live on the subagent screen
              // (chat "Open" links + the catalog sheet from a chat row),
              // trajectory in the sidebar footer next to Settings.
              // Background jobs badge (the job indicator header trigger): shows the
              // live job count of THIS session, popover lists producer/label/
              // state/per-second elapsed, with a Kill action per row.
              AnimatedBuilder(
                animation: AgentService.I,
                builder: (_, _) {
                  final jobs = s == null
                      ? const <
                          ({
                            int id,
                            String name,
                            String state,
                            int elapsedSec,
                            int outChars,
                          })
                        >[]
                      : AgentService.I.jobsFor(s.id);
                  if (jobs.isEmpty) return const SizedBox.shrink();
                  final running = jobs
                      .where((j) => j.state == 'running')
                      .length;
                  return Stack(
                    alignment: Alignment.center,
                    children: [
                      IconButton(
                        tooltip: 'Background jobs',
                        visualDensity: VisualDensity.compact,
                        icon: const Icon(Icons.terminal_outlined, size: 19),
                        onPressed: () => _showJobsPopover(context, s!.id),
                      ),
                      Positioned(
                        top: 8,
                        right: 6,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 4,
                            vertical: 1,
                          ),
                          decoration: BoxDecoration(
                            color: running > 0
                                ? Aether.accent
                                : Aether.textFaint,
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(
                            '${jobs.length}',
                            style: const TextStyle(
                              fontSize: 8.5,
                              fontWeight: FontWeight.w700,
                              color: Colors.white,
                            ),
                          ),
                        ),
                      ),
                    ],
                  );
                },
              ),
              IconButton(
                tooltip: 'Studio — code & terminal',
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.code, size: 19),
                onPressed: () => openStudio(context),
              ),
              // Browser button with agent-activity status dot (top-right).
              AnimatedBuilder(
                animation: AgentService.I,
                builder: (_, _) {
                  final a = AgentService.I;
                  final dotColor = a.browserBusy
                      ? Aether.accent
                      : (a.browserReady
                            ? Aether.successLight
                            : Aether.textFaint);
                  return Stack(
                    alignment: Alignment.center,
                    children: [
                      IconButton(
                        tooltip: 'Browser — agent & login',
                        visualDensity: VisualDensity.compact,
                        icon: const Icon(Icons.public, size: 19),
                        onPressed: () => Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => const BrowserScreen(),
                          ),
                        ),
                      ),
                      Positioned(
                        top: 10,
                        right: 10,
                        child: Container(
                          width: 7,
                          height: 7,
                          decoration: BoxDecoration(
                            color: dotColor,
                            shape: BoxShape.circle,
                            border: Border.all(color: Aether.bg, width: 1.5),
                          ),
                        ),
                      ),
                    ],
                  );
                },
              ),
              IconButton(
                tooltip: 'New session',
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.edit_square, size: 18),
                onPressed: app.newSession,
              ),
              const SizedBox(width: 6),
            ],
          ),
          body: SafeArea(
            child: LayoutBuilder(
              builder: (context, constraints) {
                // The pane width already excludes the persistent sidebar when
                // the shell renders it (ChatScreen lives in the Expanded slot),
                // so the shared axis is derived from the actual chat pane.
                final layout = ChatLayout(viewportWidth: constraints.maxWidth);
                // Reserve most of a short viewport for the composer/docks so
                // an expanded dashboard can never crowd them off-screen at
                // large text scales. The panel still scrolls internally.
                final panelCap = math.min(240.0, constraints.maxHeight * 0.25);
                // Docks share the same centered content column as the
                // transcript so the whole chat reads as one axis.
                final dockColumn = ChatDocks(
                  sessionId: AppState.I.activeSessionId,
                  onEdited: () => setState(() {}),
                  onEditToComposer: (id, text) {
                    if (s == null ||
                        _boundSessionId != s.id ||
                        AppState.I.activeSessionId != s.id) {
                      return;
                    }
                    if (_input.text.isNotEmpty ||
                        AgentService.I.pendingAttachments.isNotEmpty) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text(
                            'Finish the current draft before editing a queued message.',
                          ),
                        ),
                      );
                      return;
                    }
                    setState(() {
                      _queueEdits[s.id] = (id: id, original: text);
                      _input.value = TextEditingValue(
                        text: text,
                        selection: TextSelection.collapsed(
                          offset: text.length,
                        ),
                      );
                    });
                    _inputFocus.requestFocus();
                  },
                );
                return Column(
                  children: [
                    // Non-blocking startup readiness dashboard, pinned just
                    // below the app header. Its own AnimatedBuilder observes
                    // the coordinator so startup transitions never rebuild the
                    // transcript or the composer.
                    ConstrainedBox(
                      constraints: BoxConstraints(maxHeight: panelCap),
                      child: SingleChildScrollView(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            StartupProgressPanel(
                              coordinator: widget.startupCoordinator,
                              onOpenPlugins: (canonicalId) => _openPlugins(
                                context,
                                focusCanonicalId: canonicalId,
                              ),
                              onInstallSandbox: () => openStudio(context),
                              sandboxInstalled: AppState.I.sandboxInstalled,
                            ),
                            const _RuntimeInstallBanner(),
                          ],
                        ),
                      ),
                    ),
                    Expanded(
                      child: s == null || s.messages.isEmpty
                          ? const ChatEmptyState()
                          : Stack(
                              children: [
                                // Pinch-to-zoom: scales message text only.
                                GestureDetector(
                                  behavior: HitTestBehavior.translucent,
                                  onScaleStart: (d) {
                                    _pinchStartScale = app.chatFontScale;
                                  },
                                  onScaleUpdate: (d) {
                                    // Only react to genuine 2-finger pinch
                                    // (pointerCount >= 2), not 1-finger scroll.
                                    if (d.pointerCount < 2) return;
                                    app.setChatFontScale(
                                      _pinchStartScale * d.scale,
                                    );
                                  },
                                  child: MediaQuery(
                                    // Apply the font scale to the message list
                                    // subtree ONLY. The AppBar (header) and the
                                    // ChatComposer (composer chatbox) are outside
                                    // this MediaQuery, so they stay fixed.
                                    data: MediaQuery.of(context).copyWith(
                                      textScaler: ChatTextScaler(
                                        MediaQuery.textScalerOf(context),
                                        app.chatFontScale,
                                      ),
                                    ),
                                    child: AnimatedBuilder(
                                      animation: AgentService.I,
                                      builder: (_, _) {
                                        final typing = AgentService.I.busyFor(
                                          s.id,
                                        );
                                        // Bounded, cached fold (Task 4): the
                                        // folded window is reused across streaming
                                        // tokens; only the message count / last
                                        // message identity / showReasoning / pager
                                        // window can invalidate it.
                                        final window = _transcriptWindow(s);
                                        _hasEarlier = window.hasEarlier;
                                        final hiddenMessages =
                                            window.hiddenMessages;
                                        final items = window.visible;
                                        // "Produced" card — files written by
                                        // this run surface as a card under the
                                        // final answer (tap → Studio).
                                        final produced =
                                            AgentService.I.producedFiles;
                                        final showProduced =
                                            !typing && produced.isNotEmpty;
                                        // System-prompt disclosure (context
                                        // visibility): only at the top of the
                                        // loaded window so it never shifts the
                                        // paging row.
                                        // SECURITY: the system prompt snapshot
                                        // contains internal agent instructions
                                        // and must never be shown to the user.
                                        final count =
                                            (hiddenMessages > 0 ? 1 : 0) +
                                            items.length +
                                            (typing ? 1 : 0) +
                                            (showProduced ? 1 : 0);
                                        // Keyed anchor (Task 7): keep the row-key
                                        // map current for capture/restore, then
                                        // follow the tip only when it changed.
                                        _rowKeys = _computeRowKeys(
                                          window,
                                          typing,
                                          showProduced,
                                        );
                                        _maybeFollowTip();
                                        final list = ListView.builder(
                                          key: const ValueKey(
                                            'chat-transcript-list',
                                          ),
                                          controller: _scroll,
                                          padding: const EdgeInsets.fromLTRB(
                                            16,
                                            8,
                                            16,
                                            16,
                                          ),
                                          itemCount: count,
                                          itemBuilder: (_, i) {
                                            var idx = i;
                                            // System prompt row removed —
                                            // internal instructions are hidden.

                                            // Next row: paging affordance. The
                                            // spinner shows only while a page is
                                            // actually loading — it used to spin
                                            // forever in any long thread.
                                            if (hiddenMessages > 0 &&
                                                idx == 0) {
                                              return Center(
                                                child: Padding(
                                                  padding: const EdgeInsets.all(
                                                    8,
                                                  ),
                                                  child: Row(
                                                    mainAxisSize:
                                                        MainAxisSize.min,
                                                    children: [
                                                      if (_paging) ...[
                                                        SizedBox(
                                                          width: 12,
                                                          height: 12,
                                                          child:
                                                              CircularProgressIndicator(
                                                                strokeWidth:
                                                                    1.5,
                                                                color: Aether
                                                                    .textFaint,
                                                              ),
                                                        ),
                                                        const SizedBox(
                                                          width: 6,
                                                        ),
                                                      ] else ...[
                                                        Icon(
                                                          Icons
                                                              .keyboard_arrow_up_rounded,
                                                          size: 14,
                                                          color:
                                                              Aether.textFaint,
                                                        ),
                                                        const SizedBox(
                                                          width: 4,
                                                        ),
                                                      ],
                                                      Text(
                                                        _paging
                                                            ? 'Loading earlier…'
                                                            : '$hiddenMessages earlier '
                                                                  'message${hiddenMessages == 1 ? '' : 's'} '
                                                                  '· scroll up',
                                                        style: TextStyle(
                                                          fontSize: 11,
                                                          color:
                                                              Aether.textFaint,
                                                        ),
                                                      ),
                                                    ],
                                                  ),
                                                ),
                                              );
                                            }
                                            final li = hiddenMessages > 0
                                                ? idx - 1
                                                : idx;
                                            if (li == items.length) {
                                              return typing
                                                  ? const TypingBubble()
                                                  : TranscriptRowIn(
                                                      child: ProducedFilesCard(
                                                        files: produced,
                                                      ),
                                                    );
                                            }
                                            final item = items[li];
                                            // The live tail bubble subscribes to
                                            // AppState so streaming tokens repaint
                                            // only this row — the rest of the list
                                            // stays cached.
                                            if (typing &&
                                                li == items.length - 1) {
                                              return AnimatedBuilder(
                                                animation: AppState.I,
                                                builder: (_, _) => buildChatTranscriptItem(
                                                  item,
                                                  s,
                                                  onAction: () =>
                                                      setState(() {}),
                                                  input: _input,
                                                  layout: layout,
                                                ),
                                              );
                                            }
                                            return buildChatTranscriptItem(
                                              item,
                                              s,
                                              onAction: () => setState(() {}),
                                              input: _input,
                                              layout: layout,
                                            );
                                          },
                                        );
                                        return Center(
                                          child: ConstrainedBox(
                                            key: const ValueKey(
                                              'chat-transcript-column',
                                            ),
                                            constraints: BoxConstraints(
                                              maxWidth: layout.contentWidth,
                                            ),
                                            child: list,
                                          ),
                                        );
                                      },
                                    ),
                                  ),
                                ),
                                // web-IDE "jump to latest" pill — only when the
                                // user scrolled up while content keeps streaming.
                                if (_showJumpFab)
                                  Positioned(
                                    bottom: 12,
                                    right: 12,
                                    child: Semantics(
                                      button: true,
                                      label: 'Jump to latest',
                                      child: Material(
                                        color: Aether.surface,
                                        elevation: 2,
                                        borderRadius: BorderRadius.circular(20),
                                        child: InkWell(
                                          borderRadius: BorderRadius.circular(
                                            20,
                                          ),
                                          onTap: () {
                                            _scroll.jumpTo(
                                              _scroll.position.maxScrollExtent,
                                            );
                                          },
                                          child: const Padding(
                                            padding: EdgeInsets.symmetric(
                                              horizontal: 10,
                                              vertical: 6,
                                            ),
                                            child: Icon(
                                              Icons.arrow_downward,
                                              size: 16,
                                              color: Aether.accent,
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                    ),
                    ConstrainedBox(
                      constraints: BoxConstraints(
                        maxHeight: constraints.maxHeight * 0.15,
                      ),
                      child: SingleChildScrollView(
                        child: Center(
                          child: ConstrainedBox(
                            constraints: BoxConstraints(
                              maxWidth: layout.contentWidth,
                            ),
                            child: dockColumn,
                          ),
                        ),
                      ),
                    ),
                    ChatComposer(
                      layout: layout,
                      availableHeight: constraints.maxHeight,
                      controller: _input,
                      focusNode: _inputFocus,
                      sessionId: s?.id,
                      coordinator: widget.startupCoordinator,
                      serviceNotice: const _ControlServiceNotice(),
                      onEnableControlMode: _enableControlMode,
                      running: s == null ? false : AgentService.I.busyFor(s.id),
                      // approval takeover parity: a pending approval LOCKS
                      // the composer — the user answers the card, not the box.
                      locked: AgentService.I.pendingApproval != null,
                      editingQueue: _queueEdits.containsKey(s?.id),
                      onCancelQueueEdit: () => setState(() {
                        _queueEdits.remove(s?.id);
                      }),
                      onSend: () async {
                        if (s == null ||
                            _boundSessionId != s.id ||
                            AppState.I.activeSessionId != s.id ||
                            AgentService.I.pendingApproval != null) {
                          return;
                        }
                        final submitted = _input.text;
                        final version = _draftVersions[s.id] ?? 0;
                        void clearSubmitted() =>
                            _clearSubmittedDraft(s.id, submitted, version);
                        final t = submitted.trim();
                        if (t.isEmpty) return;
                        final edit = _queueEdits[s.id];
                        if (edit != null) {
                          final agent = AgentService.I;
                          final index = agent
                              .queuedMessageIdsFor(s.id)
                              .indexOf(edit.id);
                          final queue = agent.queuedMessagesFor(s.id);
                          if (index < 0 ||
                              index >= queue.length ||
                              queue[index] != edit.original) {
                            setState(() => _queueEdits.remove(s.id));
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text(
                                  'The queued message changed or already started. Your draft has been kept.',
                                ),
                              ),
                            );
                            return;
                          }
                          if (agent.pendingAttachments.isNotEmpty) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text(
                                  'Remove newly staged files before saving. The queued message keeps its original attachments.',
                                ),
                              ),
                            );
                            return;
                          }
                          agent.editQueuedMessageById(edit.id, t);
                          setState(() => _queueEdits.remove(s.id));
                          clearSubmitted();
                          return;
                        }

                        // ── Composer command system ───────────────────────
                        if (t.startsWith('/')) {
                          final result = await CommandService.I.execute(t);
                          if (!mounted || !context.mounted) return;
                          if (result != null) {
                            if (result.clearInput && result.prompt == null) {
                              clearSubmitted();
                            }
                            // popupSelect (the command picker parity): open the overlay picker.
                            if (AppState.I.activeSessionId != s.id) return;
                            if (result.popup == 'model') {
                              _modelPicker(context);
                              return;
                            }
                            if (result.popup == 'permission') {
                              _showModeSheetFromCommand(context);
                              return;
                            }
                            if (result.popup == 'controlDisclosure') {
                              await _enableControlMode(context);
                              return;
                            }
                            if (result.popup == 'preset') {
                              _showPresetSheetFromCommand(context);
                              return;
                            }
                            if (result.feedback != null &&
                                result.feedback!.isNotEmpty &&
                                context.mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text(result.feedback!),
                                  behavior: SnackBarBehavior.floating,
                                ),
                              );
                            }
                            final prompt = result.prompt;
                            if (prompt != null &&
                                prompt.isNotEmpty &&
                                context.mounted) {
                              _sendPrompt(
                                context,
                                s,
                                prompt,
                                onAccepted: result.clearInput
                                    ? clearSubmitted
                                    : null,
                              );
                            }
                            return;
                          }
                          if (AppState.I.activeSessionId != s.id) return;
                          // Skill direct invocation: /skill-name [args].
                          final parsed = parseSkillInvocation(t);
                          if (parsed != null) {
                            final resolved = SkillService.I.resolveForSession(
                              s.id,
                              parsed.token,
                            );
                            if (resolved.isAmbiguous) {
                              if (context.mounted) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                    content: Text(
                                      'Ambiguous skill. Choose exactly one: '
                                      '${resolved.options.join(', ')}',
                                    ),
                                    behavior: SnackBarBehavior.floating,
                                  ),
                                );
                              }
                              return;
                            }
                            final skill = resolved.unique;
                            if (skill != null && skill.userInvocable) {
                              if (!AgentService.I.isSkillAvailableForSession(
                                skill,
                                s.id,
                              )) {
                                return;
                              }
                              final content =
                                  AgentService.substituteCommandArguments(
                                    skill.content,
                                    parsed.args,
                                  );
                              final argsText =
                                  AgentService.commandArgumentTrailer(
                                    skill.content,
                                    parsed.args,
                                    'User instruction',
                                  );
                              if (context.mounted) {
                                _sendPrompt(
                                  context,
                                  s,
                                  '<skill_content>\n$content\n</skill_content>'
                                  '$argsText',
                                  onAccepted: clearSubmitted,
                                );
                              }
                              return;
                            }
                          }
                          // Unknown /command falls through to the agent.
                        }

                        // ── web-IDE busy behavior: typing while running either
                        // queues the message (default) or interrupts the current
                        // run and sends immediately, per the user's setting. ──
                        if (AgentService.I.busyFor(s.id)) {
                          if (AppState.I.sendWhileBusyInterrupt) {
                            AgentService.I.stopRequested(sessionId: s.id);
                            // fall through to send
                          } else {
                            AgentService.I.enqueueMessage(t, sessionId: s.id);
                            AgentService.I.clearAttachment();
                            clearSubmitted();
                            return;
                          }
                        }

                        if (context.mounted) {
                          _sendPrompt(
                            context,
                            s,
                            t,
                            onAccepted: clearSubmitted,
                          );
                        }
                      },
                    ),
                  ],
                );
              },
            ),
          ),
        );
      },
    );
  }

  /// Common send path — validates provider/model and launches the agent.
  /// `/permission` popupSelect: the mode sheet (same rows as the composer
  /// mode chip), command-driven.
  void _showModeSheetFromCommand(BuildContext context) =>
      showAgentModeSheet(context, onEnableControl: _enableControlMode);

  /// `/preset` popupSelect: the preset sheet (same rows as the registry),
  /// command-driven. Tapping a row applies it through the same
  /// `/preset <id>` path, so sheet and command stay one code path.
  void _showPresetSheetFromCommand(BuildContext context) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Aether.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (_) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 12),
              const Text(
                'Agent preset',
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 6),
              for (final p in PresetRegistry.all)
                ListTile(
                  dense: true,
                  title: Text(p.label, style: const TextStyle(fontSize: 13.5)),
                  subtitle: Text(
                    p.description,
                    style: TextStyle(fontSize: 11, color: Aether.textMuted),
                  ),
                  trailing: AppState.I.activeSession?.presetId == p.id
                      ? const Icon(Icons.check, size: 16, color: Aether.accent)
                      : null,
                  onTap: () async {
                    Navigator.pop(context);
                    final result = await CommandService.I.execute(
                      '/preset ${p.id}',
                    );
                    if (!context.mounted) return;
                    final fb = result?.feedback;
                    if (fb != null && fb.isNotEmpty) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(fb),
                          behavior: SnackBarBehavior.floating,
                        ),
                      );
                    }
                  },
                ),
              const SizedBox(height: 10),
            ],
          ),
        ),
      ),
    );
  }

  void _sendPrompt(
    BuildContext context,
    ChatSession? s,
    String t, {
    VoidCallback? onAccepted,
  }) {
    final app = AppState.I;
    final session = s;
    if (session == null ||
        app.activeSessionId != session.id ||
        !identical(app.sessionById(session.id), session)) {
      return;
    }
    final provider = app.providerForSession(session);
    if (provider == null || session.model == 'Select a provider') {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('Select a provider and model before sending.'),
          action: SnackBarAction(
            label: 'Select',
            onPressed: () => _modelPicker(context),
          ),
        ),
      );
      return;
    }
    if (!provider.isConfigured) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Add an API key for ${provider.name} first.')),
      );
      return;
    }
    final selectedModel = session.model.split('·').first.trim();
    if (!provider.models.contains(selectedModel)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('The selected model is no longer available.'),
        ),
      );
      return;
    }

    final agent = AgentService.I;
    if (agent.busyFor(session.id)) {
      agent.enqueueMessage(t, sessionId: session.id);
      agent.clearAttachment();
      onAccepted?.call();
      return;
    }
    app.sendMessage(t);
    onAccepted?.call();
    // New user message → snap to bottom so the user sees the answer start.
    _atBottom = true;
    Future.delayed(const Duration(milliseconds: 80), () {
      if (_scroll.hasClients) {
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      }
    });
    // @file/@session references expand into model-visible context blocks
    // (the composer mention expander file-reference parity) before the run starts.
    AgentService.I.runTask(t, sessionId: session.id, expandRefsFor: session);
  }

  /// Background jobs popover (the jobs panel ui-jobs): one row per job with label,
  /// state dot, per-second elapsed, output size, and a Kill action.
  void _showJobsPopover(BuildContext context, String sessionId) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Aether.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => AnimatedBuilder(
        animation: AgentService.I,
        builder: (_, _) {
          final jobs = AgentService.I.jobsFor(sessionId);
          return SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Icon(
                        Icons.terminal_outlined,
                        size: 16,
                        color: Aether.accent,
                      ),
                      const SizedBox(width: 8),
                      const Text(
                        'Background jobs',
                        style: TextStyle(
                          fontSize: 14.5,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const Spacer(),
                      IconButton(
                        visualDensity: VisualDensity.compact,
                        icon: Icon(
                          Icons.close,
                          size: 17,
                          color: Aether.textFaint,
                        ),
                        onPressed: () => Navigator.pop(ctx),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  if (jobs.isEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 18),
                      child: Text(
                        'No background jobs in this session.',
                        style: TextStyle(
                          fontSize: 12.5,
                          color: Aether.textMuted,
                        ),
                      ),
                    )
                  else
                    Flexible(
                      child: ListView(
                        shrinkWrap: true,
                        children: [
                          for (final j in jobs)
                            Padding(
                              padding: const EdgeInsets.symmetric(vertical: 4),
                              child: Row(
                                children: [
                                  Container(
                                    width: 7,
                                    height: 7,
                                    decoration: BoxDecoration(
                                      shape: BoxShape.circle,
                                      color: switch (j.state) {
                                        'running' => Aether.accent,
                                        'stopping' => Aether.warnLight,
                                        'pending' => Aether.textFaint,
                                        _ => Aether.successLight,
                                      },
                                    ),
                                  ),
                                  const SizedBox(width: 10),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          '#${j.id} ${j.name}',
                                          style: const TextStyle(
                                            fontSize: 13,
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                        Text(
                                          '${j.state} · ${formatCompactDuration(Duration(seconds: j.elapsedSec))} · '
                                          '${j.outChars} chars',
                                          style: TextStyle(
                                            fontSize: 11,
                                            color: Aether.textMuted,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  if (j.state == 'running' ||
                                      j.state == 'stopping')
                                    IconButton(
                                      tooltip: 'Kill job',
                                      visualDensity: VisualDensity.compact,
                                      icon: Icon(
                                        Icons.stop_circle_outlined,
                                        size: 18,
                                        color: Aether.danger,
                                      ),
                                      onPressed: () => AgentService.I
                                          .killJobFor(sessionId, j.id),
                                    ),
                                ],
                              ),
                            ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  void _modelPicker(BuildContext context) => showModelPickerSheet(context);
}

Future<void> _enableControlMode(BuildContext context) async {
  final app = AppState.I;
  // Show the disclosure only once. After acceptance, switching to Control
  // must not re-prompt.
  if (!app.controlDisclosureAccepted) {
    final accepted = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Enable Control mode'),
        content: const SingleChildScrollView(
          child: Text(kControlModeDisclosure),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Not now'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Enable Control'),
          ),
        ],
      ),
    );
    if (accepted != true) return;
    app.controlDisclosureAccepted = true;
  }
  AgentService.I.setMode(AgentMode.control);
  // If the accessibility service is enabled but unbound after an app
  // restart, absorb the OS rebind window now (pure wait, no programmatic
  // toggle) — control mode must not need a manual off/on toggle to start
  // working.
  unawaited(DeviceControlService.I.refreshServiceBinding());
  // Battery exemption once: control mode means permanent presence, which
  // Doze/OEM killers will end without the exemption. Asked only on first
  // enable, and only when not already exempt — never a nag.
  if (!app.controlBatteryPromptShown) {
    await app.markControlBatteryPromptShown();
    bool exempt = true;
    try {
      exempt = (await DeviceControlService.I.backgroundHealth()).batteryExempt;
    } catch (e) {
      Diag.swallow('chat_screen', e);
    }
    if (!exempt) {
      try {
        await AgentService.I.requestBatteryExemption();
      } catch (e) {
        Diag.swallow('chat_screen', e);
      }
    }
  }
  // Control mode survives the background only through the persistent
  // notification (Android mandates it for a foreground service). If the
  // user turned notifications off, say so once with a one-tap fix instead
  // of letting control runs die silently in the background.
  if (!app.notificationsEnabled && context.mounted) {
    final enable = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: const Text('Keep Ovid alive in the background?'),
        content: const Text(
          'Control mode drives your device while the app is backgrounded. '
          'Android only allows that with a persistent notification. Turn '
          'notifications on so runs survive the background.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(d, false),
            child: const Text('Not now'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(d, true),
            child: const Text('Turn on'),
          ),
        ],
      ),
    );
    if (enable == true) {
      await app.setNotificationsEnabled(true);
    }
  }
  // Only deep-link to Settings when the accessibility service is not yet
  // enabled — an already-granted service must not re-open Settings.
  var enabled = false;
  try {
    enabled = await DeviceControlService.I.isEnabled();
  } catch (e) {
    Diag.swallow('chat_screen', e);
  }
  if (enabled) return;
  try {
    await DeviceControlService.I.openAccessibilitySettings();
  } catch (_) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Could not open Accessibility Settings. Use the inline retry.',
          ),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }
}

class _ControlServiceNotice extends StatefulWidget {
  const _ControlServiceNotice();
  @override
  State<_ControlServiceNotice> createState() => _ControlServiceNoticeState();
}

class _ControlServiceNoticeState extends State<_ControlServiceNotice>
    with WidgetsBindingObserver {
  bool? _enabled;

  /// Four-state native binding status. `_enabled` alone is NOT enough: it is a
  /// Settings-level check, so it stays true when Android has the service
  /// switched on but has never rebound it after a force-stop — the exact state
  /// where Control mode is broken and this notice used to stay silent.
  String? _serviceState;
  String? _error;
  Timer? _retryTimer;
  bool? _batteryExempt;
  String _manufacturer = '';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (AgentService.I.mode == AgentMode.control) {
      _refresh();
    }
  }

  @override
  void dispose() {
    _retryTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed &&
        AgentService.I.mode == AgentMode.control) {
      _refresh(isResume: true);
    }
  }

  Future<void> _refresh({bool isResume = false}) async {
    if (AgentService.I.mode != AgentMode.control) return;
    _retryTimer?.cancel();
    final enabled = await DeviceControlService.I.isEnabled().catchError(
      (_) => false,
    );
    final state = await DeviceControlService.I.serviceState().catchError(
      (_) => 'disabled',
    );
    if (!mounted) return;
    if (mounted) {
      setState(() {
        _enabled = enabled;
        _serviceState = state;
      });
    }
    if (isResume && !enabled && _enabled != true) {
      // Retry once after 600ms on resume in case the OS is still binding the service
      _retryTimer = Timer(const Duration(milliseconds: 600), () async {
        if (!mounted || AgentService.I.mode != AgentMode.control) return;
        final retryEnabled = await DeviceControlService.I
            .isEnabled()
            .catchError((_) => false);
        if (mounted) setState(() => _enabled = retryEnabled);
      });
    }
    await _refreshHealth();
  }

  /// Background-health snapshot for OEM-killer guidance. Fail-closed toward
  /// silence: an unreadable state hides the guidance row instead of nagging.
  Future<void> _refreshHealth() async {
    try {
      final health = await DeviceControlService.I.backgroundHealth();
      if (!mounted || AgentService.I.mode != AgentMode.control) return;
      setState(() {
        _batteryExempt = health.batteryExempt;
        _manufacturer = health.manufacturer;
      });
    } catch (e) {
      Diag.swallow('chat_screen', e);
    }
  }

  Future<void> _retry() async {
    try {
      await DeviceControlService.I.openAccessibilitySettings();
      if (mounted) setState(() => _error = null);
    } catch (_) {
      if (mounted) {
        setState(() => _error = 'Could not open Accessibility Settings.');
      }
    }
    await _refresh();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: AgentService.I,
    builder: (_, _) {
      if (_enabled == null) {
        _refresh();
      }
      if (AgentService.I.mode != AgentMode.control) {
        return const SizedBox.shrink();
      }
      final showOffWarning = _enabled == false;
      // Enabled in Settings but Android is not going to rebind it. Needs a
      // different message and the same Settings action — "wait, it will bind
      // on its own" is false in this state.
      final showStaleWarning =
          _enabled == true && _serviceState == DeviceControlService.staleState;
      // OEM-killer guidance: service is up, but this ROM kills background
      // apps without the battery exemption. Pixel-class ROMs never match.
      final showHealthGuidance =
          _enabled == true &&
          _batteryExempt == false &&
          DeviceControlService.isKillerOem(_manufacturer);
      if (!showOffWarning && !showStaleWarning && !showHealthGuidance) {
        return const SizedBox.shrink();
      }
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (showOffWarning)
            Row(
              children: [
                Icon(
                  Icons.warning_amber_rounded,
                  size: 15,
                  color: Aether.warnLight,
                ),
                const SizedBox(width: 5),
                Expanded(
                  child: Text(
                    'Control service is off',
                    style: TextStyle(fontSize: 11, color: Aether.warnLight),
                  ),
                ),
                TextButton(
                  onPressed: _retry,
                  child: const Text('Open Accessibility Settings'),
                ),
              ],
            ),
          if (showStaleWarning)
            Row(
              children: [
                Icon(
                  Icons.sync_problem_rounded,
                  size: 15,
                  color: Aether.warnLight,
                ),
                const SizedBox(width: 5),
                Expanded(
                  child: Text(
                    'On in Settings but Android has not restarted it — '
                    'toggle it off and on',
                    style: TextStyle(fontSize: 11, color: Aether.warnLight),
                  ),
                ),
                TextButton(
                  onPressed: _retry,
                  child: const Text('Open Accessibility Settings'),
                ),
              ],
            ),
          if (showHealthGuidance)
            Row(
              children: [
                Icon(
                  Icons.battery_alert_outlined,
                  size: 15,
                  color: Aether.warnLight,
                ),
                const SizedBox(width: 5),
                Expanded(
                  child: Text(
                    'This device may kill Ovid in the background — exempt it to stay present',
                    style: TextStyle(fontSize: 11, color: Aether.warnLight),
                  ),
                ),
                TextButton(
                  onPressed: () async {
                    try {
                      await AgentService.I.requestBatteryExemption();
                    } catch (e) {
                      Diag.swallow('chat_screen', e);
                    }
                    await _refreshHealth();
                  },
                  child: const Text('Fix'),
                ),
              ],
            ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(left: 20),
              child: Text(
                _error!,
                style: TextStyle(fontSize: 11, color: Aether.danger),
              ),
            ),
        ],
      );
    },
  );
}

/// Background runtime-install banner (first launch only).
///
/// The setup gate installs just the native sandbox core so the app opens
/// fast; Node.js/Python finish here in the background. The banner shows
/// live installer output, is dismissible while running (the install
/// continues), and offers Retry on failure. It observes [AppState] through
/// its own AnimatedBuilder so installer progress never rebuilds the chat
/// transcript or the composer.
class _RuntimeInstallBanner extends StatelessWidget {
  const _RuntimeInstallBanner();

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: AppState.I,
      builder: (context, _) {
        final app = AppState.I;
        if (!app.showRuntimeInstallBanner) return const SizedBox.shrink();
        final failed = app.runtimeInstallState == RuntimeInstallState.failed;
        final progress = app.runtimeInstallProgress;
        return Container(
          margin: const EdgeInsets.fromLTRB(12, 0, 12, 6),
          padding: const EdgeInsets.fromLTRB(12, 9, 8, 9),
          decoration: BoxDecoration(
            color: Aether.surface,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: failed ? Aether.danger : Aether.accent,
              width: 1,
            ),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  if (!failed)
                    const SizedBox(
                      width: 15,
                      height: 15,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  else
                    const Icon(
                      Icons.warning_amber_rounded,
                      size: 17,
                      color: Aether.danger,
                    ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      failed
                          ? 'Background setup needs attention'
                          : 'Setting up Node.js + Python…',
                      style: const TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  if (failed)
                    TextButton(
                      onPressed: () => unawaited(
                        StudioSetupCoordinator.I.retryFromRuntimeBanner(),
                      ),
                      style: TextButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        minimumSize: const Size(0, 30),
                      ),
                      child: const Text(
                        'Retry',
                        style: TextStyle(fontSize: 12),
                      ),
                    ),
                  IconButton(
                    onPressed: app.dismissRuntimeInstallBanner,
                    icon: const Icon(Icons.close, size: 16),
                    color: Aether.textFaint,
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.all(4),
                    constraints: const BoxConstraints(),
                    tooltip: failed ? 'Dismiss' : 'Hide (keeps installing)',
                  ),
                ],
              ),
              if (progress >= 0 && !failed) ...[
                const SizedBox(height: 7),
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: progress.clamp(0.0, 1.0),
                    minHeight: 4,
                    backgroundColor: Aether.surfaceAlt,
                    valueColor: const AlwaysStoppedAnimation(Aether.accent),
                  ),
                ),
              ],
              if (app.runtimeInstallLine.isNotEmpty) ...[
                const SizedBox(height: 5),
                  Text(
                    app.runtimeInstallLine,
                  style: TextStyle(
                    fontFamily: Aether.mono,
                    fontSize: 10.5,
                    height: 1.5,
                    color: Aether.textFaint,
                  ),
                ),
              ],
              if (!failed)
                Padding(
                  padding: const EdgeInsets.only(top: 3),
                  child: Text(
                    'Chat works meanwhile — agent tools that need Node/Python will install them on demand.',
                    style: TextStyle(fontSize: 10.5, color: Aether.textFaint),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}
