import 'dart:convert';
import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:url_launcher/url_launcher.dart';
import '../core/theme.dart';
import '../core/state.dart';
import 'sandbox_setup.dart';
import 'browser_screen.dart';
import 'sidebar.dart';
import 'subagent_screen.dart';
import '../core/agent_service.dart';
import '../core/commands.dart';
import '../core/mcp_service.dart';
import '../core/skills.dart';

/// Chat screen — Gemini/DeepSeek grade: reasoning chips, code blocks,
/// in-chat image generation card, model picker, utility input bar.
/// DSH turn-process folding: consecutive assistant tool/reasoning
/// messages collapse into a single expandable strip ("N tool calls ·
/// Thought for a while") that sits right before the final answer.
/// The LAST tool/reasoning run (no text after it yet, or the last tool
/// in a run still in progress) stays unfolded — same as DSH Compact.
sealed class _ChatItem {}

class _SingleItem extends _ChatItem {
  final Message m;
  final int index;
  _SingleItem(this.m, this.index);
}

class _FoldedGroup extends _ChatItem {
  final List<Message> msgs;
  final List<int> indices;
  _FoldedGroup(this.msgs, this.indices);
}

List<_ChatItem> _foldMessages(List<Message> messages) {
  final showReasoning = AppState.I.showReasoning;
  final out = <_ChatItem>[];
  var i = 0;
  while (i < messages.length) {
    final m = messages[i];
    // Reasoning display toggle (Settings): OFF → skip thinking chips.
    // Data stays in the session; only display is suppressed.
    if (m.kind == MsgKind.reasoning && !showReasoning) {
      i++;
      continue;
    }
    final foldable =
        m.role == 'assistant' &&
        (m.kind == MsgKind.tool || m.kind == MsgKind.reasoning) &&
        !m.thinking;
    if (!foldable) {
      out.add(_SingleItem(m, i));
      i++;
      continue;
    }
    // Collect the foldable run.
    final group = <Message>[];
    final idx = <int>[];
    while (i < messages.length &&
        messages[i].role == 'assistant' &&
        (messages[i].kind == MsgKind.tool ||
            messages[i].kind == MsgKind.reasoning) &&
        !messages[i].thinking) {
      group.add(messages[i]);
      idx.add(i);
      i++;
    }
    // Look ahead: if the NEXT message is assistant text, this group is
    // complete → fold it.  If the group runs to the end (or before a
    // user message), keep it unfolded (still in progress / latest).
    final nextIsAnswer =
        i < messages.length && messages[i].kind == MsgKind.text;
    if (group.length >= 2 && nextIsAnswer) {
      out.add(_FoldedGroup(group, idx));
    } else {
      for (var j = 0; j < group.length; j++) {
        out.add(_SingleItem(group[j], idx[j]));
      }
    }
  }
  return out;
}

/// Read/write transcript for ONE session — the same rendering the main chat
/// uses (folded tool/reasoning strips, streaming bubbles, tool cards).
///
/// The subagent view renders a child session with this, so a subagent's work
/// is shown in full instead of being summarised into one line.
class ChatTranscript extends StatelessWidget {
  final ChatSession session;
  final ScrollController? scrollController;

  /// Show the live status row at the tail (the child is mid-turn).
  final bool typing;
  const ChatTranscript({
    super.key,
    required this.session,
    this.scrollController,
    this.typing = false,
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([AppState.I, AgentService.I]),
      builder: (_, _) {
        final items = _foldMessages(session.messages);
        final count = items.length + (typing ? 1 : 0);
        return MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: TextScaler.linear(AppState.I.chatFontScale),
          ),
          child: ListView.builder(
            controller: scrollController,
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
            itemCount: count,
            itemBuilder: (_, i) {
              if (i == items.length) return const _TypingBubble();
              return _buildItem(
                items[i],
                session,
                onAction: () {},
                input: TextEditingController(),
              );
            },
          ),
        );
      },
    );
  }
}

/// DSH `row-in` / `wide-in` entrance — fade + 8px slide-up, plays ONCE
/// when the widget is inserted (streaming rebuilds don't re-trigger it
/// because the State persists in the ListView element).
class _RowIn extends StatefulWidget {
  final Widget child;
  const _RowIn({required this.child});
  @override
  State<_RowIn> createState() => _RowInState();
}

class _RowInState extends State<_RowIn> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 300),
  );

  @override
  void initState() {
    super.initState();
    _c.forward();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final curved = CurvedAnimation(parent: _c, curve: Curves.easeOutCubic);
    return FadeTransition(
      opacity: curved,
      child: SlideTransition(
        position: Tween<Offset>(
          begin: const Offset(0, 0.04),
          end: Offset.zero,
        ).animate(curved),
        child: widget.child,
      ),
    );
  }
}

/// DSH `dsh-state-dot-chase` — pulsing accent dot used on running tool
/// and reasoning rows instead of a spinner.
class _ChaseDot extends StatefulWidget {
  final Color color;
  const _ChaseDot(this.color);
  @override
  State<_ChaseDot> createState() => _ChaseDotState();
}

class _ChaseDotState extends State<_ChaseDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  )..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (_, _) {
        final phase = 0.5 - (_c.value - 0.5).abs();
        final op = 0.35 + 0.65 * phase * 2;
        final scale = 0.8 + 0.35 * phase * 2;
        return Transform.scale(
          scale: scale,
          child: Container(
            width: 11,
            height: 11,
            decoration: BoxDecoration(
              color: widget.color.withValues(alpha: op.clamp(0.0, 1.0)),
              shape: BoxShape.circle,
            ),
          ),
        );
      },
    );
  }
}

/// DSH `dsh-turn-status-shimmer` — shimmering status text (e.g. the
/// "Thinking…" label on a live reasoning row).
class _ShimmerText extends StatefulWidget {
  final String text;
  final TextStyle style;
  const _ShimmerText(this.text, {required this.style});
  @override
  State<_ShimmerText> createState() => _ShimmerTextState();
}

class _ShimmerTextState extends State<_ShimmerText>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  )..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (_, _) {
        final t = (_c.value * 2) % 1.0;
        final mix = Color.lerp(
          Aether.textMuted,
          Aether.text,
          (0.5 - (t - 0.5).abs()) * 2,
        );
        return Text(
          widget.text,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: widget.style.copyWith(color: mix),
        );
      },
    );
  }
}

Widget _buildItem(
  _ChatItem item,
  dynamic s, {
  required VoidCallback onAction,
  required TextEditingController input,
}) {
  if (item is _SingleItem) {
    return _RowIn(
      child: _MessageView(
        m: item.m,
        session: s,
        msgIndex: item.index,
        onAction: onAction,
        input: input,
      ),
    );
  }
  final g = item as _FoldedGroup;
  return _RowIn(child: _TurnProcessStrip(group: g.msgs));
}

/// DSH StatsLine parity — pipe-separated line docked above the composer:
/// "3 turns · LLM 12.4s · Input 8.2K tok · Output 1.4K tok".  Hidden
/// when the session has no usage yet (empty-state stays clean).
class _StatsLine extends StatelessWidget {
  const _StatsLine();

  String _fmtTok(int t) {
    if (t >= 1000) return '${(t / 1000).toStringAsFixed(1)}K';
    return '$t';
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([AppState.I, AgentService.I]),
      builder: (_, _) {
        final usage = AppState.I.usageLog;
        final s = AppState.I.activeSession;
        if (s == null) return const SizedBox.shrink();
        final today = usage.where((e) {
          final d = e.time;
          final now = DateTime.now();
          return d.year == now.year && d.month == now.month && d.day == now.day;
        }).toList();
        final input = usage.fold<int>(0, (a, e) => a + e.promptTokens);
        final output = usage.fold<int>(0, (a, e) => a + e.completionTokens);
        // DSH footer ring — % of THIS model's context window in use,
        // measured from the last billed promptTokens (exact) or the
        // chars/4 heuristic fallback.
        final window = AgentService.contextWindowForSession(s);
        final used = AgentService.I.measuredContextTokens(s);
        final frac = (used / window).clamp(0.0, 1.0);
        final pct = frac * 100;
        if (usage.isEmpty && used == 0) return const SizedBox.shrink();
        final ringColor = frac >= 0.8
            ? Aether.dangerC
            : frac >= 0.55
            ? Aether.warn
            : Aether.success;
        return Container(
          width: double.infinity,
          padding: const EdgeInsets.fromLTRB(16, 3, 16, 3),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Flexible(
                child: Text(
                  [
                    '${today.length} turn${today.length == 1 ? '' : 's'} today',
                    if (AgentService.I.lastRunElapsedMs != null)
                      'last ${(AgentService.I.lastRunElapsedMs! / 1000).toStringAsFixed(1)}s',
                    'Input ${_fmtTok(input)} tok · Output ${_fmtTok(output)} tok',
                    if (AgentService.I.sessionDecodeTokens > 0)
                      'decode ${_fmtTok(AgentService.I.sessionDecodeTokens)} tok',
                    if (AgentService.I.sessionDecodeTokPerSec > 0)
                      '${AgentService.I.sessionDecodeTokPerSec.toStringAsFixed(1)} tok/s',
                    if (AgentService.I.sessionCacheReadTokens > 0)
                      'cache ${_fmtTok(AgentService.I.sessionCacheReadTokens)} tok',
                    if (AgentService.I.sessionAvgTtftMs > 0)
                      'ttft ~${AgentService.I.sessionAvgTtftMs} ms',
                    if (s.compactedSummary != null) 'compacted',
                  ].join('  |  '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 10.5, color: Aether.textFaint),
                ),
              ),
              const SizedBox(width: 8),
              // Context ring — 12px arc + % label (DSH "% of context used").
              // Tap → full context meter sheet (segmented breakdown).
              Tooltip(
                message:
                    '${pct.toStringAsFixed(0)}% of ${_fmtTok(window)} context used · '
                    'breakdown: sys ${_fmtTok(AgentService.I.sessionSystemTokens)} · '
                    'tool ${_fmtTok(AgentService.I.sessionToolTokens)} · '
                    'msgs ${_fmtTok(AgentService.I.sessionMessageTokens)} · '
                    'tap for details',
                child: GestureDetector(
                  onTap: () => _showContextMeter(
                    context,
                    window: window,
                    used: used,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SizedBox(
                        width: 12,
                        height: 12,
                        child: CircularProgressIndicator(
                          value: frac,
                          strokeWidth: 2,
                          backgroundColor: Aether.hairline,
                          valueColor: AlwaysStoppedAnimation(ringColor),
                          strokeCap: StrokeCap.round,
                        ),
                      ),
                      const SizedBox(width: 5),
                      Text(
                        '${pct.toStringAsFixed(0)}%',
                        style: TextStyle(
                          fontSize: 10.5,
                          fontFamily: Aether.mono,
                          color: ringColor,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  /// Context meter sheet (DSH context-breakdown parity): window usage,
  /// segmented sys/tools/messages bars with a cache-read overlay and a
  /// compaction hint.
  void _showContextMeter(
    BuildContext context, {
    required int window,
    required int used,
  }) {
    final agent = AgentService.I;
    final sys = agent.sessionSystemTokens;
    final tool = agent.sessionToolTokens;
    final msgs = agent.sessionMessageTokens;
    final cache = agent.sessionCacheReadTokens;
    final frac = (used / window).clamp(0.0, 1.0);
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Aether.bg,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Text(
                    'Context',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      color: Aether.text,
                    ),
                  ),
                  const Spacer(),
                  Text(
                    '${_fmtTok(used)} / ${_fmtTok(window)} · '
                    '${(frac * 100).toStringAsFixed(0)}%',
                    style: TextStyle(
                      fontSize: 12,
                      fontFamily: Aether.mono,
                      color: frac >= 0.8
                          ? Aether.dangerC
                          : frac >= 0.55
                          ? Aether.warn
                          : Aether.success,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              _MeterBreakdownBar(
                label: 'System',
                value: sys,
                total: window,
                color: Aether.accent,
              ),
              const SizedBox(height: 10),
              _MeterBreakdownBar(
                label: 'Tools',
                value: tool,
                total: window,
                color: Aether.warn,
              ),
              const SizedBox(height: 10),
              _MeterBreakdownBar(
                label: 'Messages',
                value: msgs,
                total: window,
                color: Aether.success,
              ),
              const SizedBox(height: 14),
              Text(
                [
                  if (cache > 0)
                    'Cache-read: ${_fmtTok(cache)} tok (billed cheaper)',
                  'Compaction triggers automatically near the window limit.',
                ].join('\n'),
                style: TextStyle(fontSize: 11, color: Aether.textFaint),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// One segmented row of the context meter: label + value + a bar showing
/// this bucket's share of the window.
class _MeterBreakdownBar extends StatelessWidget {
  final String label;
  final int value;
  final int total;
  final Color color;
  const _MeterBreakdownBar({
    required this.label,
    required this.value,
    required this.total,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    final frac = total <= 0 ? 0.0 : (value / total).clamp(0.0, 1.0);
    return Row(
      children: [
        SizedBox(
          width: 72,
          child: Text(
            label,
            style: TextStyle(fontSize: 11, color: Aether.textFaint),
          ),
        ),
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: SizedBox(
              height: 8,
              child: LinearProgressIndicator(
                value: frac,
                minHeight: 8,
                backgroundColor: Aether.hairline,
                valueColor: AlwaysStoppedAnimation(color),
              ),
            ),
          ),
        ),
        const SizedBox(width: 8),
        Text(
          value >= 1000
              ? '${(value / 1000).toStringAsFixed(1)}K'
              : '$value',
          style: TextStyle(
            fontSize: 10.5,
            fontFamily: Aether.mono,
            color: Aether.textFaint,
          ),
        ),
      ],
    );
  }
}

/// DSH turn-process strip — "N tool calls · Thought for a while" with a
/// chevron; expands to show every folded tool card + reasoning card.
/// Default collapsed (DSH Compact mode).
class _TurnProcessStrip extends StatefulWidget {
  final List<Message> group;
  const _TurnProcessStrip({required this.group});
  @override
  State<_TurnProcessStrip> createState() => _TurnProcessStripState();
}

class _TurnProcessStripState extends State<_TurnProcessStrip> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final g = widget.group;
    final toolCount = g.where((m) => m.kind == MsgKind.tool).length;
    final hasReasoning = g.any((m) => m.kind == MsgKind.reasoning);
    final subagents = g.where((m) => m.toolName == 'dispatch_agent').length;
    final runningSubagents = g
        .where(
          (m) => m.toolName == 'dispatch_agent' && m.toolState == 'running',
        )
        .length;
    final label = [
      if (subagents > 0)
        // DSH presentation: "{count} subagents (running)".
        '$subagents subagent${subagents == 1 ? '' : 's'}'
            '${runningSubagents > 0 ? ' running' : ''}',
      if (toolCount - subagents > 0)
        '${toolCount - subagents} tool call${toolCount - subagents == 1 ? '' : 's'}',
      if (hasReasoning) 'Thought for a while',
    ].join(' · ');
    return Container(
      margin: const EdgeInsets.only(bottom: 4),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: Aether.hairline)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: () => setState(() => _open = !_open),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 7),
              child: Row(
                children: [
                  Icon(
                    _open
                        ? Icons.keyboard_arrow_down
                        : Icons.keyboard_arrow_right,
                    size: 15,
                    color: Aether.textFaint,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    label.isEmpty ? 'Work done' : label,
                    style: TextStyle(
                      fontSize: 12,
                      color: Aether.textMuted,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (_open)
            ...g.map(
              (m) => Padding(
                padding: const EdgeInsets.only(left: 8),
                child: m.kind == MsgKind.reasoning
                    ? _ReasoningCard(m)
                    : _ToolCard(m),
              ),
            ),
        ],
      ),
    );
  }
}

class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key});
  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen>
    with SingleTickerProviderStateMixin {
  final _input = TextEditingController();
  final _scroll = ScrollController();

  /// DSH-web auto-scroll: when the user is at the bottom, we follow the
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

  // ── Lazy message paging (ChatGPT/Claude style) ──
  // Long threads render ONLY the last [_visibleCount] folded items; a
  // "Load earlier" row at the top pulls in older history on demand, so a
  // 500-message chat never lags the phone (or re-builds on every token).
  static const _pageSize = 40;
  int _visibleCount = _pageSize;
  bool _paging = false; // blocks re-entrant top-of-list pagination
  int _totalItems = 0; // last known full history length (for paging)

  void _bindDraft(String sessionId) {
    if (_boundSessionId == sessionId) return;
    // Save outgoing session's draft.
    if (_boundSessionId != null && _input.text.isNotEmpty) {
      _drafts[_boundSessionId!] = _input.text;
    } else if (_boundSessionId != null) {
      _drafts.remove(_boundSessionId);
    }
    // Restore incoming session's draft.
    final draft = _drafts[sessionId] ?? '';
    if (_input.text != draft) {
      _input.value = TextEditingValue(
        text: draft,
        selection: TextSelection.collapsed(offset: draft.length),
      );
    }
    _boundSessionId = sessionId;
    // Reset scroll-follow state per session so a fresh session starts at
    // the bottom, not mid-stream.
    _atBottom = true;
    _showJumpFab = false;
    _visibleCount = _pageSize; // lazy paging resets per session
  }

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scroll.dispose();
    _input.dispose();
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
    if (!_paging && pos.pixels < 120 && _visibleCount < _totalItems) {
      _paging = true;
      final oldExtent = pos.maxScrollExtent;
      final oldPixels = pos.pixels;
      setState(() => _visibleCount += _pageSize);
      // Keep the viewport pinned to the message the user was reading:
      // prepended items grow maxScrollExtent; compensating by the delta
      // makes the content appear to stay put while history loads above.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scroll.hasClients) {
          final newExtent = _scroll.position.maxScrollExtent;
          _scroll.jumpTo(newExtent - oldExtent + oldPixels);
        }
        _paging = false;
      });
    }
  }

  /// Called from the message-list builder when content changes — keeps the
  /// stream pinned to the bottom if the user was already at the bottom.
  void _maybeJumpToBottom() {
    if (!_atBottom) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      }
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
                      s?.model ?? 'Select model',
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
              // Background jobs badge (DSH jobs header trigger): shows the
              // live job count of THIS session, popover lists producer/label/
              // state/per-second elapsed, with a Kill action per row.
              AnimatedBuilder(
                animation: AgentService.I,
                builder: (_, _) {
                  final jobs = s == null
                      ? const <({int id, String name, String state, int elapsedSec, int outChars})>[]
                      : AgentService.I.jobsFor(s.id);
                  if (jobs.isEmpty) return const SizedBox.shrink();
                  final running =
                      jobs.where((j) => j.state == 'running').length;
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
                      : (a.browserReady ? Aether.success : Aether.textFaint);
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
            child: Column(
              children: [
                Expanded(
                  child: s == null || s.messages.isEmpty
                      ? const _EmptyState()
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
                                // _InputBar (composer chatbox) are outside
                                // this MediaQuery, so they stay fixed.
                                data: MediaQuery.of(context).copyWith(
                                  textScaler: TextScaler.linear(
                                    app.chatFontScale,
                                  ),
                                ),
                                child: AnimatedBuilder(
                                  animation: AgentService.I,
                                  builder: (_, _) {
                                    final typing = AgentService.I.busyFor(s.id);
                                    _maybeJumpToBottom();
                                    // DSH turn-process folding: consecutive
                                    // tool/reasoning items collapse into a
                                    // single strip before the final answer.
                                    final allItems = _foldMessages(s.messages);
                                    // Lazy paging (ChatGPT/Gemini style) —
                                    // render ONLY the newest [_visibleCount]
                                    // folded items; scrolling to the top
                                    // auto-loads the previous page (no tap
                                    // needed, see _onScroll). A 500-message
                                    // chat never lags the phone.
                                    _totalItems = allItems.length;
                                    final hidden =
                                        allItems.length - _visibleCount;
                                    final items = hidden > 0
                                        ? allItems.sublist(
                                            allItems.length - _visibleCount,
                                          )
                                        : allItems;
                                    // DSH "Produced" card — files written by
                                    // this run surface as a card under the
                                    // final answer (tap → Studio).
                                    final produced =
                                        AgentService.I.producedFiles;
                                    final showProduced =
                                        !typing && produced.isNotEmpty;
                                    final count =
                                        (hidden > 0 ? 1 : 0) +
                                        items.length +
                                        (typing ? 1 : 0) +
                                        (showProduced ? 1 : 0);
                                    return ListView.builder(
                                      controller: _scroll,
                                      padding: const EdgeInsets.fromLTRB(
                                        16,
                                        8,
                                        16,
                                        16,
                                      ),
                                      itemCount: count,
                                      itemBuilder: (_, i) {
                                        // Row 0: paging affordance. The
                                        // spinner shows only while a page is
                                        // actually loading — it used to spin
                                        // forever in any long thread.
                                        if (hidden > 0 && i == 0) {
                                          return Center(
                                            child: Padding(
                                              padding: const EdgeInsets.all(8),
                                              child: Row(
                                                mainAxisSize: MainAxisSize.min,
                                                children: [
                                                  if (_paging) ...[
                                                    SizedBox(
                                                      width: 12,
                                                      height: 12,
                                                      child:
                                                          CircularProgressIndicator(
                                                            strokeWidth: 1.5,
                                                            color: Aether
                                                                .textFaint,
                                                          ),
                                                    ),
                                                    const SizedBox(width: 6),
                                                  ] else ...[
                                                    Icon(
                                                      Icons
                                                          .keyboard_arrow_up_rounded,
                                                      size: 14,
                                                      color: Aether.textFaint,
                                                    ),
                                                    const SizedBox(width: 4),
                                                  ],
                                                  Text(
                                                    _paging
                                                        ? 'Loading earlier…'
                                                        : '$hidden earlier '
                                                              'message${hidden == 1 ? '' : 's'} '
                                                              '· scroll up',
                                                    style: TextStyle(
                                                      fontSize: 11,
                                                      color: Aether.textFaint,
                                                    ),
                                                  ),
                                                ],
                                              ),
                                            ),
                                          );
                                        }
                                        final li = hidden > 0 ? i - 1 : i;
                                        if (li == items.length) {
                                          return typing
                                              ? const _TypingBubble()
                                              : _RowIn(
                                                  child: _ProducedFilesCard(
                                                    files: produced,
                                                  ),
                                                );
                                        }
                                        return _buildItem(
                                          items[li],
                                          s,
                                          onAction: () => setState(() {}),
                                          input: _input,
                                        );
                                      },
                                    );
                                  },
                                ),
                              ),
                            ),
                            // DSH-web "jump to latest" pill — only when the
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
                                      borderRadius: BorderRadius.circular(20),
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
                const _GoalBar(),
                const _TodoDock(),
                const _StatsLine(),
                _QueueDock(onEdited: () => setState(() {})),
                const _ApprovalDock(),
                _InputBar(
                  controller: _input,
                  running: s == null ? false : AgentService.I.busyFor(s.id),
                  // DSH approval takeover parity: a pending approval LOCKS
                  // the composer — the user answers the card, not the box.
                  locked: AgentService.I.pendingApproval != null,
                  onSend: () async {
                    final t = _input.text.trim();
                    if (t.isEmpty) return;

                    // ── Composer command system ───────────────────────
                    if (t.startsWith('/')) {
                      final result = await CommandService.I.execute(t);
                      if (result != null) {
                        _input.clear();
                        // popupSelect (DSH parity): open the overlay picker.
                        if (!context.mounted) return;
                        if (result.popup == 'model') {
                          _modelPicker(context);
                          return;
                        }
                        if (result.popup == 'permission') {
                          _showModeSheetFromCommand(context);
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
                        if (prompt != null && prompt.isNotEmpty && context.mounted) {
                          _sendPrompt(context, s, prompt);
                        }
                        return;
                      }
                      // Skill direct invocation: /skill-name [args].
                      final parsed = CommandService.parse(t);
                      if (parsed != null) {
                        final skill = SkillService.I.find(parsed.name);
                        if (skill != null && skill.userInvocable) {
                          _input.clear();
                          final argsText = parsed.args.isEmpty
                              ? ''
                              : '\n\nUser instruction: ${parsed.args}';
                          if (context.mounted) {
                            _sendPrompt(
                              context,
                              s,
                              '<skill_content>\n${skill.content}\n</skill_content>'
                              '$argsText',
                            );
                          }
                          return;
                        }
                      }
                      // Unknown /command falls through to the agent.
                    }

                    // ── DSH-web busy behavior: typing while running queues
                    // the message to auto-run after the current turn. ──
                    if (s != null && AgentService.I.busyFor(s.id)) {
                      AgentService.I.enqueueMessage(t);
                      _input.clear();
                      return;
                    }

                    if (context.mounted) _sendPrompt(context, s, t);
                  },
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// Common send path — validates provider/model and launches the agent.
  /// `/permission` popupSelect: the mode sheet (same rows as the composer
  /// mode chip), command-driven.
  void _showModeSheetFromCommand(BuildContext context) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Aether.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 12),
            const Text(
              'Agent access mode',
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 6),
            for (final m in AgentMode.values)
              ListTile(
                dense: true,
                title: Text(m.label, style: const TextStyle(fontSize: 13.5)),
                subtitle: Text(
                  m.hint,
                  style: TextStyle(fontSize: 11, color: Aether.textMuted),
                ),
                trailing: AgentService.I.mode == m
                    ? Icon(Icons.check, size: 16, color: Aether.accent)
                    : null,
                onTap: () {
                  Navigator.pop(context);
                  AgentService.I.setMode(m);
                },
              ),
            const SizedBox(height: 10),
          ],
        ),
      ),
    );
  }

  void _sendPrompt(BuildContext context, ChatSession? s, String t) {    final app = AppState.I;
    final session = app.activeSession;
    final provider = app.providerForSession(session);
    if (provider == null ||
        session == null ||
        session.model == 'Select a provider') {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text(
            'Select a provider and model before sending.',
          ),
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
        SnackBar(
          content: Text('Add an API key for ${provider.name} first.'),
        ),
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

    app.sendMessage(t);
    _input.clear();
    _drafts.remove(session.id);
    // New user message → snap to bottom so the user sees the answer start.
    _atBottom = true;
    Future.delayed(const Duration(milliseconds: 80), () {
      if (_scroll.hasClients) {
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      }
    });
    // @file/@session references expand into model-visible context blocks
    // (DSH file-reference parity) before the run starts.
    AgentService.I.runTask(t, expandRefsFor: session);
  }

  /// Background jobs popover (DSH ui-jobs): one row per job with label,
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
                      const Icon(Icons.terminal_outlined,
                          size: 16, color: Aether.accent),
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
                        icon: Icon(Icons.close,
                            size: 17, color: Aether.textFaint),
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
                                        'stopping' => Aether.warn,
                                        'pending' => Aether.textFaint,
                                        _ => Aether.success,
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
                                          '${j.state} · ${j.elapsedSec}s · '
                                          '${j.outChars} chars of output',
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
                                      icon: Icon(Icons.stop_circle_outlined,
                                          size: 18, color: Aether.danger),
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

  void _modelPicker(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => DraggableScrollableSheet(
        initialChildSize: 0.5,
        minChildSize: 0.32,
        maxChildSize: 0.92,
        snap: true,
        snapSizes: const [0.5, 0.92],
        builder: (ctx, scrollController) =>
            _ModelPickerSheet(scrollController: scrollController),
      ),
    );
  }
}

/// Half-sheet model picker — rounded top corners, search bar,
/// drag handle to expand to fullscreen.
class _ModelPickerSheet extends StatefulWidget {
  final ScrollController scrollController;
  const _ModelPickerSheet({required this.scrollController});

  @override
  State<_ModelPickerSheet> createState() => _ModelPickerSheetState();
}

class _ModelPickerSheetState extends State<_ModelPickerSheet> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final app = AppState.I;
    final q = _query.toLowerCase();

    return Container(
      decoration: BoxDecoration(
        color: Aether.surface,
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      child: Column(
        children: [
          // Drag handle
          Container(
            margin: const EdgeInsets.only(top: 10, bottom: 4),
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: Aether.hairlineStrong,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(height: 10),
          // Title + search
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 18),
            child: Row(
              children: [
                const Text(
                  'Select model',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                ),
                const Spacer(),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.close, size: 18),
                  onPressed: () => Navigator.pop(context),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 4, 18, 8),
            child: TextField(
              onChanged: (v) => setState(() => _query = v),
              style: const TextStyle(fontSize: 13.5),
              decoration: InputDecoration(
                hintText: 'Search models or providers…',
                prefixIcon: Icon(
                  Icons.search,
                  size: 17,
                  color: Aether.textFaint,
                ),
                isDense: true,
                filled: true,
                fillColor: Aether.surfaceAlt,
                contentPadding: const EdgeInsets.symmetric(vertical: 9),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(color: Aether.hairline),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(color: Aether.hairline),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(color: Aether.accent),
                ),
              ),
            ),
          ),
          // Provider → model list
          Expanded(
            child: AnimatedBuilder(
              animation: app,
              builder: (_, _) {
                // Only show providers that have an API key configured AND
                // at least one model available. Providers without a key
                // are collapsed into a single hint row at the bottom.
                final configured = app.providers
                    .where((p) => p.hasKey && p.models.isNotEmpty)
                    .where(
                      (p) =>
                          q.isEmpty ||
                          p.name.toLowerCase().contains(q) ||
                          p.models.any((m) => m.toLowerCase().contains(q)),
                    )
                    .toList();
                final unconfigured = app.providers
                    .where((p) => !p.hasKey && p.models.isNotEmpty)
                    .toList();
                if (configured.isEmpty && unconfigured.isEmpty) {
                  return Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(
                        'No models yet.\nAdd a key in Settings → Providers and tap Fetch models.',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 12.5,
                          height: 1.6,
                          color: Aether.textMuted,
                        ),
                      ),
                    ),
                  );
                }
                return ListView.builder(
                  controller: widget.scrollController,
                  padding: const EdgeInsets.only(bottom: 20),
                  itemCount: configured.length + (unconfigured.isEmpty ? 0 : 1),
                  itemBuilder: (_, i) {
                    if (i < configured.length) {
                      final p = configured[i];
                      final models = p.models
                          .where(
                            (m) =>
                                q.isEmpty ||
                                p.name.toLowerCase().contains(q) ||
                                m.toLowerCase().contains(q),
                          )
                          .toList();
                      if (models.isEmpty) return const SizedBox.shrink();
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Padding(
                            padding: const EdgeInsets.fromLTRB(18, 14, 18, 4),
                            child: Row(
                              children: [
                                Text(
                                  p.name,
                                  style: TextStyle(
                                    fontSize: 12.5,
                                    fontWeight: FontWeight.w700,
                                    color: Aether.textMuted,
                                  ),
                                ),
                                const SizedBox(width: 8),
                                if (p.isFree)
                                  const Tag(
                                    'FREE',
                                    color: Aether.success,
                                    filled: true,
                                  ),
                                const SizedBox(width: 6),
                                const Tag(
                                  'KEY',
                                  color: Aether.accent,
                                  filled: true,
                                ),
                              ],
                            ),
                          ),
                          for (final m in models)
                            _ModelTile(providerId: p.id, model: m),
                        ],
                      );
                    }
                    // Hint row for providers without keys.
                    return Padding(
                      padding: const EdgeInsets.fromLTRB(18, 20, 18, 8),
                      child: Row(
                        children: [
                          Icon(
                            Icons.key_off,
                            size: 14,
                            color: Aether.textFaint,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              '${unconfigured.map((p) => p.name).join(', ')} — add API keys in Settings → Providers to use these models.',
                              style: TextStyle(
                                fontSize: 11.5,
                                color: Aether.textFaint,
                              ),
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _ModelTile extends StatelessWidget {
  final String providerId;
  final String model;
  const _ModelTile({required this.providerId, required this.model});

  static const _effortModels = [
    'deepseek',
    'gpt',
    'kimi',
    'glm',
    'opus',
    'sonnet',
    'gemini-2.5',
    'qwen3',
    'o4',
    'grok',
    'r1',
  ];
  static const variants = ['Low', 'Medium', 'High'];

  bool get supportsEffort =>
      _effortModels.any((e) => model.toLowerCase().contains(e));

  @override
  Widget build(BuildContext context) {
    final app = AppState.I;
    final session = app.activeSession;
    final current = session?.model ?? '';
    final selected =
        session?.providerId == providerId &&
        (current == model || current.startsWith('$model ·'));

    if (!supportsEffort) {
      return ListTile(
        dense: true,
        leading: Icon(
          Icons.smart_toy_outlined,
          size: 18,
          color: Aether.textMuted,
        ),
        title: Text(model, style: const TextStyle(fontSize: 13.5)),
        trailing: selected
            ? const Icon(Icons.check, size: 18, color: Aether.accent)
            : null,
        onTap: () {
          app.setModel(providerId, model);
          Navigator.pop(context);
        },
      );
    }

    return Theme(
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        dense: true,
        tilePadding: const EdgeInsets.symmetric(horizontal: 16),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
        leading: Icon(
          Icons.psychology_outlined,
          size: 18,
          color: Aether.textMuted,
        ),
        title: Text(model, style: const TextStyle(fontSize: 13.5)),
        subtitle: selected && current.contains('·')
            ? Text(
                current.split('·').last.trim(),
                style: const TextStyle(fontSize: 11, color: Aether.accent),
              )
            : null,
        trailing: selected
            ? const Icon(Icons.check, size: 18, color: Aether.accent)
            : null,
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final v in variants)
                ChoiceChip(
                  label: Text(v, style: const TextStyle(fontSize: 12)),
                  selected:
                      current ==
                      (v == 'Medium' ? '$model · Medium' : '$model · $v'),
                  onSelected: (_) {
                    app.setModel(
                      providerId,
                      v == 'Medium' ? '$model · Medium' : '$model · $v',
                    );
                    Navigator.pop(context);
                  },
                  showCheckmark: false,
                  selectedColor: Aether.accentSoft,
                  backgroundColor: Aether.surfaceAlt,
                  side: BorderSide(
                    color:
                        current ==
                            (v == 'Medium' ? '$model · Medium' : '$model · $v')
                        ? Aether.accent
                        : Aether.hairline,
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(9),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

/// DSH-web home parity (Ovid branding): centered logo, big greeting with
/// a mono pill beside it, then open space down to the composer.  DSH has
/// NO suggestion rows on the home screen — the surface is intentionally
/// empty so the composer is the whole focus.  Entrance: `wide-in` fade+rise.
class _EmptyState extends StatelessWidget {
  const _EmptyState();
  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, c) {
        return SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(22, 40, 22, 24),
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: c.maxHeight - 64),
            child: _RowIn(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  // Brand mark (Ovid identity).
                  Container(
                    width: 52,
                    height: 52,
                    decoration: BoxDecoration(
                      color: Aether.accent,
                      borderRadius: BorderRadius.circular(15),
                    ),
                    child: const Center(
                      child: Text(
                        'O',
                        style: TextStyle(
                          fontSize: 25,
                          fontWeight: FontWeight.w800,
                          color: Colors.white,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 22),
                  // Greeting + mono pill (DSH "What do you want to build? ·
                  // Preview" pattern) in one row so the pill sits beside the
                  // title like DSH, not under it.
                  Wrap(
                    crossAxisAlignment: WrapCrossAlignment.center,
                    spacing: 10,
                    runSpacing: 6,
                    children: [
                      Text(
                        'How can I help?',
                        style: TextStyle(
                          fontSize: 26,
                          fontWeight: FontWeight.w500,
                          height: 32 / 26,
                          letterSpacing: -0.2,
                          color: Aether.text,
                        ),
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 9,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: Aether.accent.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(24),
                        ),
                        child: Text(
                          'preview',
                          style: TextStyle(
                            fontFamily: Aether.mono,
                            fontSize: 12,
                            fontWeight: FontWeight.w500,
                            height: 18 / 12,
                            color: Aether.accent,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Ask, deep-dive, build — the agent runs tools right here.',
                    style: TextStyle(
                      fontSize: 13,
                      height: 1.5,
                      color: Aether.textFaint,
                    ),
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

/// Collapsible thinking/reasoning card — Gemini-web style.
/// Tap the "Thinking…" header to expand/collapse the body.
/// Auto-expands while streaming (m.thinking == true), auto-collapses
/// when the stream completes (m.thinking == false). User toggles persist
/// for the message lifetime.
class _ReasoningCard extends StatefulWidget {
  final Message m;
  const _ReasoningCard(this.m);
  @override
  State<_ReasoningCard> createState() => _ReasoningCardState();
}

class _ReasoningCardState extends State<_ReasoningCard> {
  /// null = follow the streaming state (expanded while thinking, collapsed
  /// when done).  Once the user taps, we lock to their choice.
  bool? _override;

  @override
  Widget build(BuildContext context) {
    final isStreaming = widget.m.thinking;
    // Default: expanded while streaming, collapsed when done — unless the
    // user has explicitly toggled.
    final expanded = _override ?? isStreaming;
    return Container(
      decoration: BoxDecoration(
        color: Aether.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Aether.hairline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          // Header — tap to toggle.
          InkWell(
            borderRadius: const BorderRadius.only(
              topLeft: Radius.circular(10),
              topRight: Radius.circular(10),
            ),
            onTap: () => setState(() => _override = !expanded),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(
                children: [
                  if (isStreaming)
                    const _ChaseDot(Aether.accent)
                  else
                    Icon(
                      expanded
                          ? Icons.keyboard_arrow_down
                          : Icons.keyboard_arrow_right,
                      size: 14,
                      color: Aether.textFaint,
                    ),
                  const SizedBox(width: 8),
                  if (isStreaming)
                    _ShimmerText(
                      'Thinking…',
                      style: TextStyle(
                        fontSize: 12,
                        color: Aether.textMuted,
                        fontWeight: FontWeight.w500,
                      ),
                    )
                  else
                    Text(
                      'Thoughts',
                      style: TextStyle(
                        fontSize: 12,
                        color: Aether.textMuted,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  const Spacer(),
                  if (isStreaming)
                    Text(
                      'live',
                      style: TextStyle(fontSize: 10, color: Aether.textFaint),
                    ),
                ],
              ),
            ),
          ),
          // Body — only when expanded. Reasoning is apparatus, not prose:
          // smaller and dimmer than the answer so it never competes with it.
          if (expanded && widget.m.content.trim().isNotEmpty)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
              child: _DshMarkdown(
                content: widget.m.content,
                fontSize: 12.5,
                color: Aether.textMuted,
              ),
            ),
        ],
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════
// DSH ToolRow parity — live tool-call cards in the chat transcript.
// Collapsed: 24px row  [14px icon]  Title  ·  summary  [state dot]
//   running → glare-sweep shimmer across the row
//   error   → red state dot replaces the icon
// Expanded: detail body — TerminalBlock (terminal icon tools),
//   DiffBlock (edit/write tools), or a plain IN/OUT body otherwise.
// Icons mirror the DSH web icon set (think/search/browse/edit/terminal/
// globe/sparkle/checklist/question/bolt).
// ═══════════════════════════════════════════════════════════════════════
class _ToolCard extends StatefulWidget {
  final Message m;
  const _ToolCard(this.m);
  @override
  State<_ToolCard> createState() => _ToolCardState();
}

class _ToolCardState extends State<_ToolCard>
    with SingleTickerProviderStateMixin {
  bool _open = false;
  late final AnimationController _sweep;

  @override
  void initState() {
    super.initState();
    // DSH "running" affordance: continuous glare sweep (2.6s linear).
    _sweep = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2600),
    );
    if (widget.m.toolState == 'running') _sweep.repeat();
  }

  @override
  void dispose() {
    _sweep.dispose();
    super.dispose();
  }

  static IconData _iconFor(String kind) => switch (kind) {
    'web' => Icons.public,
    'read' => Icons.description_outlined,
    'edit' => Icons.edit_outlined,
    'terminal' => Icons.terminal,
    'code' => Icons.code,
    'search' => Icons.search,
    'sparkle' => Icons.auto_awesome,
    'agent' => Icons.smart_toy_outlined,
    'git' => Icons.source_outlined,
    'goal' => Icons.flag_outlined,
    'schedule' => Icons.schedule_outlined,
    'memory' => Icons.psychology_outlined,
    _ => Icons.bolt_outlined,
  };

  /// PR25/D3: (+added, −removed) counts from the card's real diff body —
  /// null when this card carries no diff (non-edit tools).
  (int, int)? _diffCountsOf(String? detail) {
    final d = (detail ?? '').trim();
    if (!d.startsWith('diff ')) return null;
    var add = 0;
    var rem = 0;
    for (final l in d.split('\n')) {
      if (l.startsWith('+') && !l.startsWith('+++')) add++;
      if (l.startsWith('-') && !l.startsWith('---')) rem++;
    }
    return (add, rem);
  }

  @override
  Widget build(BuildContext context) {
    final m = widget.m;
    final running = m.toolState == 'running';
    if (!running && _sweep.isAnimating) _sweep.stop();
    final failed = m.toolState == 'error';
    final stopped = m.toolState == 'stopped';
    final iconKind = AgentService.toolIcon(m.toolName ?? '');
    final hasDetail = (m.toolDetail ?? '').trim().isNotEmpty;
    // PR25/D3: +N/−M chip data (null for non-diff cards).
    final diffCounts = _diffCountsOf(m.toolDetail);
    // dispatch_agent rows own a real child session — the row becomes a link
    // into that transcript (and the child may still be running).
    final childSessionId = m.toolSessionId;

    return Container(
      margin: const EdgeInsets.only(bottom: 4),
      decoration: BoxDecoration(
        color: Aether.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: failed
              ? Aether.dangerC.withValues(alpha: 0.4)
              : Aether.hairline,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: hasDetail ? () => setState(() => _open = !_open) : null,
            child: SizedBox(
              height: 30,
              child: Row(
                children: [
                  const SizedBox(width: 10),
                  if (failed)
                    _StateDot(Aether.dangerC)
                  else if (m.toolState == 'unknown')
                    _StateDot(Aether.textFaint)
                  else if (stopped)
                    _StateDot(Aether.warn)
                  else if (running)
                    const _ChaseDot(Aether.accent)
                  else
                    Icon(_iconFor(iconKind), size: 14, color: Aether.textMuted),
                  const SizedBox(width: 7),
                  Text(
                    m.toolTitle ?? m.toolName ?? 'tool',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: failed ? Aether.dangerC : Aether.text,
                    ),
                  ),
                  if ((m.toolSummary ?? '').isNotEmpty) ...[
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 7),
                      child: Container(
                        width: 2,
                        height: 2,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: Aether.textFaint,
                        ),
                      ),
                    ),
                    Expanded(
                      child: Text(
                        m.toolSummary!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 11.5,
                          color: failed ? Aether.dangerC : Aether.textMuted,
                          fontFamily: Aether.mono,
                        ),
                      ),
                    ),
                    // PR25/D3: edit cards show a +N/−M line-count chip
                    // (DSH diff-row parity) computed from the real diff.
                    if (diffCounts != null) ...[
                      const SizedBox(width: 6),
                      Text(
                        '+${diffCounts.$1} −${diffCounts.$2}',
                        style: TextStyle(
                          fontSize: 10,
                          fontFamily: Aether.mono,
                          color: Aether.success,
                        ),
                      ),
                    ],
                  ] else
                    const Spacer(),
                  if (hasDetail)
                    Icon(
                      _open
                          ? Icons.keyboard_arrow_down
                          : Icons.keyboard_arrow_right,
                      size: 16,
                      color: Aether.textFaint,
                    ),
                  // A subagent card links to the child's OWN session, so the
                  // user can read its full transcript instead of the summary.
                  if (childSessionId != null)
                    InkWell(
                      borderRadius: BorderRadius.circular(6),
                      onTap: () => SubagentScreen.open(context, childSessionId),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              'Open',
                              style: TextStyle(
                                fontSize: 10.5,
                                fontWeight: FontWeight.w600,
                                color: Aether.accent,
                              ),
                            ),
                            Icon(
                              Icons.open_in_new,
                              size: 12,
                              color: Aether.accent,
                            ),
                          ],
                        ),
                      ),
                    ),
                  const SizedBox(width: 8),
                ],
              ),
            ),
          ),
          // Glare sweep while running — DSH `dsh-tool-row-sweep` parity:
          // a soft highlight band sweeping the FULL row left→right
          // (lifted over the row above via a paint-only translation).
          if (running)
            IgnorePointer(
              child: Transform.translate(
                offset: const Offset(0, -34),
                child: AnimatedBuilder(
                  animation: _sweep,
                  builder: (_, _) {
                    final t = _sweep.value;
                    return Container(
                      height: 30,
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment(-1.2 + 2.4 * t, 0),
                          end: Alignment(-0.7 + 2.4 * t, 0),
                          colors: [
                            Colors.transparent,
                            Aether.accent.withValues(alpha: 0.06),
                            Aether.accent.withValues(alpha: 0.14),
                            Colors.transparent,
                          ],
                          stops: const [0.0, 0.45, 0.55, 1.0],
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),
          // Expanded detail — Terminal / Diff / plain body.
          if (_open && hasDetail) _DetailBody(m: m),
        ],
      ),
    );
  }
}

/// 8px state dot (DSH StateDot) — replaces the icon on error/stopped.
class _StateDot extends StatelessWidget {
  final Color color;
  const _StateDot(this.color);
  @override
  Widget build(BuildContext context) => Container(
    width: 8,
    height: 8,
    decoration: BoxDecoration(shape: BoxShape.circle, color: color),
  );
}

/// Expanded tool body: terminal-style for shell/code/jobs, diff-style for
/// edits/writes, plain mono body otherwise.  16-line cap with a
/// "N more lines" fold toggle (DSH TerminalBlock behavior).
class _DetailBody extends StatefulWidget {
  final Message m;
  const _DetailBody({required this.m});
  @override
  State<_DetailBody> createState() => _DetailBodyState();
}

class _DetailBodyState extends State<_DetailBody> {
  bool _expandedAll = false;
  static const _cap = 16;

  @override
  Widget build(BuildContext context) {
    final m = widget.m;
    final kind = AgentService.toolIcon(m.toolName ?? '');
    final detail = m.toolDetail!.trimRight();
    final lines = const LineSplitter().convert(detail);
    final capped = !_expandedAll && lines.length > _cap;
    final shown = capped ? lines.sublist(lines.length - _cap) : lines;

    final isDiff =
        kind == 'edit' ||
        m.toolName == 'commit' ||
        detail
            .split('\n')
            .take(8)
            .any(
              (l) =>
                  l.startsWith('+ ') ||
                  l.startsWith('- ') ||
                  l.startsWith('+') && !l.startsWith('++') ||
                  l.startsWith('-') && !l.startsWith('--'),
            );
    final isTerminal = kind == 'terminal' || kind == 'code' || kind == 'agent';

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(8, 0, 8, 8),
      decoration: BoxDecoration(
        color: Aether.surfaceAlt,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Aether.hairline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (isTerminal)
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 8, 10, 4),
              child: Text(
                '\$ ${m.toolSummary ?? ''}',
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontFamily: Aether.mono,
                  fontSize: 11.5,
                  color: Aether.textMuted,
                ),
              ),
            ),
          // PR25/D5: diff header — path + counts + full-screen open.
          if (isDiff && detail.startsWith('diff '))
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 8, 10, 0),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      detail.split('\n').first.replaceFirst('diff ', ''),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontFamily: Aether.mono,
                        fontSize: 11,
                        color: Aether.textFaint,
                      ),
                    ),
                  ),
                  InkWell(
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => _DiffViewerScreen(detail: detail),
                      ),
                    ),
                    child: Text(
                      'open full',
                      style: TextStyle(fontSize: 11, color: Aether.accent),
                    ),
                  ),
                ],
              ),
            ),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 340),
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(10, 4, 10, 8),
              child: isDiff
                  ? Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: shown.map((l) => _DiffLine(l)).toList(),
                    )
                  : Text(
                      shown.join('\n'),
                      style: TextStyle(
                        fontFamily: Aether.mono,
                        fontSize: 11.5,
                        height: 1.45,
                        color: m.toolState == 'error'
                            ? Aether.dangerC
                            : Aether.text,
                      ),
                    ),
            ),
          ),
          if (capped)
            InkWell(
              onTap: () => setState(() => _expandedAll = true),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(10, 0, 10, 8),
                child: Text(
                  '… ${lines.length - _cap} more lines (tap to expand)',
                  style: TextStyle(fontSize: 11, color: Aether.accent),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// One diff line — green + / red − like DSH DiffBlock.
class _DiffLine extends StatelessWidget {
  final String line;
  const _DiffLine(this.line);
  @override
  Widget build(BuildContext context) {
    final isAdd = line.startsWith('+') && !line.startsWith('++');
    final isDel = line.startsWith('-') && !line.startsWith('--');
    final color = isAdd
        ? Aether.successC
        : isDel
        ? Aether.dangerC
        : Aether.text;
    final bg = isAdd
        ? Aether.successC.withValues(alpha: 0.08)
        : isDel
        ? Aether.dangerC.withValues(alpha: 0.08)
        : Colors.transparent;
    return Container(
      width: double.infinity,
      color: bg,
      child: Text(
        line,
        style: TextStyle(
          fontFamily: Aether.mono,
          fontSize: 11.5,
          height: 1.45,
          color: color,
        ),
      ),
    );
  }
}

/// PR25/D5: full-screen diff viewer — the details surface DSH gives its
/// diff cards (chat rows cap at 8/16 lines; this shows every hunk with
/// copy).
class _DiffViewerScreen extends StatelessWidget {
  final String detail;
  const _DiffViewerScreen({required this.detail});

  @override
  Widget build(BuildContext context) {
    final lines = const LineSplitter().convert(detail);
    final header = lines.firstOrNull ?? '';
    return Scaffold(
      backgroundColor: Aether.bg,
      appBar: AppBar(
        backgroundColor: Aether.bg,
        title: Text(
          header.replaceFirst('diff ', ''),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 14),
        ),
        actions: [
          IconButton(
            tooltip: 'Copy diff',
            icon: const Icon(Icons.copy, size: 18),
            onPressed: () {
              Clipboard.setData(ClipboardData(text: detail));
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('Diff copied'),
                  duration: Duration(milliseconds: 1200),
                ),
              );
            },
          ),
        ],
      ),
      body: Scrollbar(
        child: ListView.builder(
          padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
          itemCount: lines.length,
          itemBuilder: (_, i) => _DiffLine(lines[i]),
        ),
      ),
    );
  }
}

/// DSH compaction row — a faint inline event row, collapsed by default:
/// "↻ Context compacted — N messages (~X tokens)"; tap to view the
/// compacted summary (DSH "View compaction summary").
class _CompactionRow extends StatefulWidget {
  final Message m;
  const _CompactionRow(this.m);
  @override
  State<_CompactionRow> createState() => _CompactionRowState();
}

class _CompactionRowState extends State<_CompactionRow> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final m = widget.m;
    final hasSummary = (m.toolDetail ?? '').trim().isNotEmpty;
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(6),
            onTap: hasSummary ? () => setState(() => _open = !_open) : null,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Row(
                children: [
                  Icon(
                    _open
                        ? Icons.keyboard_arrow_down
                        : Icons.keyboard_arrow_right,
                    size: 14,
                    color: Aether.textFaint,
                  ),
                  const SizedBox(width: 4),
                  Icon(Icons.compress_outlined, size: 13, color: Aether.accent),
                  const SizedBox(width: 7),
                  Expanded(
                    child: Text(
                      m.content,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11.5,
                        color: Aether.textMuted,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                  if (hasSummary)
                    Text(
                      'View summary',
                      style: TextStyle(fontSize: 10.5, color: Aether.accent),
                    ),
                ],
              ),
            ),
          ),
          if (_open && hasSummary)
            Container(
              width: double.infinity,
              margin: const EdgeInsets.only(bottom: 2),
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Aether.surfaceAlt,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Aether.hairline),
              ),
              child: Text(
                m.toolDetail!,
                style: TextStyle(
                  fontFamily: Aether.mono,
                  fontSize: 11,
                  height: 1.45,
                  color: Aether.textMuted,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// DSH "Produced" parity — card under the final answer listing files the
/// agent created/edited this run.  Tap a file to open it in Studio.
class _ProducedFilesCard extends StatelessWidget {
  final List<({String path, int size})> files;
  const _ProducedFilesCard({required this.files});

  /// Chips shown inline; the rest collapse into a "+N files" chip that
  /// expands the full list in a sheet.
  static const _maxChips = 6;

  String _fmtSize(int b) => b >= 1048576
      ? '${(b / 1048576).toStringAsFixed(1)} MB'
      : b >= 1024
      ? '${(b / 1024).toStringAsFixed(1)} KB'
      : '$b B';

  String _base(String path) =>
      path.contains('/') ? path.split('/').last : path;

  Future<void> _open(BuildContext context, String path) async {
    final messenger = ScaffoldMessenger.of(context);
    final ok = await AgentService.I.openWorkspaceFileInStudio(path);
    if (!context.mounted) return;
    if (!ok) {
      messenger.showSnackBar(
        SnackBar(
          content: Text('Could not open $path'),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }
    openStudio(context);
  }

  void _showAll(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Aether.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (sheetCtx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.symmetric(vertical: 10),
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 10),
              child: Text(
                'Produced ${files.length} file${files.length == 1 ? '' : 's'}',
                style: const TextStyle(
                  fontSize: 14.5,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            for (final f in files)
              ListTile(
                dense: true,
                leading: Icon(
                  Icons.insert_drive_file_outlined,
                  size: 17,
                  color: Aether.accent,
                ),
                title: Text(
                  f.path,
                  style: const TextStyle(
                    fontSize: 12.5,
                    fontFamily: Aether.mono,
                  ),
                ),
                subtitle: Text(
                  _fmtSize(f.size),
                  style: TextStyle(fontSize: 10.5, color: Aether.textFaint),
                ),
                trailing: IconButton(
                  tooltip: 'Show in folder',
                  visualDensity: VisualDensity.compact,
                  icon: Icon(
                    Icons.folder_open_outlined,
                    size: 17,
                    color: Aether.textMuted,
                  ),
                  onPressed: () async {
                    final dir = await AgentService.I.hostDirOf(f.path);
                    if (!sheetCtx.mounted) return;
                    final messenger = ScaffoldMessenger.of(sheetCtx);
                    if (dir == null) {
                      messenger.showSnackBar(
                        SnackBar(
                          content: Text(
                            '${_base(f.path)} is repo-only — not on local disk.',
                          ),
                          behavior: SnackBarBehavior.floating,
                        ),
                      );
                      return;
                    }
                    try {
                      await launchUrl(Uri.file(dir));
                    } catch (_) {
                      messenger.showSnackBar(
                        SnackBar(
                          content: Text('No file manager app to open folders.'),
                          behavior: SnackBarBehavior.floating,
                        ),
                      );
                    }
                  },
                ),
                onTap: () {
                  Navigator.pop(sheetCtx);
                  _open(context, f.path);
                },
              ),
          ],
        ),
      ),
    );
  }

  Widget _chip(
    BuildContext context, {
    required IconData icon,
    required String label,
    String? tooltip,
    String? trailing,
    required VoidCallback onTap,
  }) {
    final chip = InkWell(
      borderRadius: BorderRadius.circular(9),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
        decoration: BoxDecoration(
          color: Aether.surfaceAlt,
          borderRadius: BorderRadius.circular(9),
          border: Border.all(color: Aether.hairline),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 13, color: Aether.accent),
            const SizedBox(width: 6),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 150),
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 11.5,
                  fontFamily: Aether.mono,
                ),
              ),
            ),
            if (trailing != null) ...[
              const SizedBox(width: 6),
              Text(
                trailing,
                style: TextStyle(fontSize: 10, color: Aether.textFaint),
              ),
            ],
          ],
        ),
      ),
    );
    return tooltip == null
        ? chip
        : Tooltip(
            message: tooltip,
            waitDuration: const Duration(milliseconds: 500),
            child: chip,
          );
  }

  @override
  Widget build(BuildContext context) {
    final shown = files.take(_maxChips).toList();
    final rest = files.length - shown.length;
    return Container(
      margin: const EdgeInsets.only(bottom: 8, right: 40),
      padding: const EdgeInsets.fromLTRB(12, 9, 12, 10),
      decoration: BoxDecoration(
        color: Aether.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Aether.hairline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(
                Icons.upload_file_outlined,
                size: 13,
                color: Aether.success,
              ),
              const SizedBox(width: 6),
              Text(
                'Produced · ${files.length} file${files.length == 1 ? '' : 's'}',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.4,
                  color: Aether.textMuted,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          // Chip lane — tapping a chip opens THAT file in Studio (the old
          // rows opened Studio but dropped the path).
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final f in shown)
                _chip(
                  context,
                  icon: Icons.insert_drive_file_outlined,
                  label: _base(f.path),
                  tooltip: f.path,
                  trailing: _fmtSize(f.size),
                  onTap: () => _open(context, f.path),
                ),
              if (rest > 0)
                _chip(
                  context,
                  icon: Icons.more_horiz,
                  label: '+$rest file${rest == 1 ? '' : 's'}',
                  onTap: () => _showAll(context),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

/// DSH turn-tail row — faint footer under the final assistant answer of a
/// turn: elapsed time (+ token stats when available).
class _TurnTailRow extends StatelessWidget {
  final Message m;
  const _TurnTailRow(this.m);
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 2, bottom: 8),
      child: Row(
        children: [
          Icon(Icons.schedule, size: 11, color: Aether.textFaint),
          const SizedBox(width: 4),
          Text(
            m.content,
            style: TextStyle(fontSize: 10.5, color: Aether.textFaint),
          ),
        ],
      ),
    );
  }
}

class _MessageView extends StatelessWidget {
  final Message m;
  final dynamic session; // ChatSession
  final int msgIndex;
  final VoidCallback onAction;
  final TextEditingController input;
  const _MessageView({
    required this.m,
    required this.session,
    required this.msgIndex,
    required this.onAction,
    required this.input,
  });

  @override
  Widget build(BuildContext context) {
    final isUser = m.role == 'user';
    final isLast = msgIndex == session.messages.length - 1;
    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Column(
        crossAxisAlignment: isUser
            ? CrossAxisAlignment.end
            : CrossAxisAlignment.start,
        children: [
          Container(
            margin: const EdgeInsets.only(bottom: 2),
            constraints: BoxConstraints(
              maxWidth: MediaQuery.of(context).size.width * 0.82,
            ),
            child: Column(
              crossAxisAlignment: isUser
                  ? CrossAxisAlignment.end
                  : CrossAxisAlignment.start,
              children: [
                switch (m.kind) {
                  MsgKind.imageGen => _imageGen(context),
                  MsgKind.reasoning => _reasoning(),
                  MsgKind.tool => _toolCard(),
                  MsgKind.turnTail => _turnTail(),
                  MsgKind.compact => _CompactionRow(m),
                  _ => _text(isUser),
                },
                // Attachment chips under the user bubble (in-chat display).
                if (isUser && m.attachments.isNotEmpty)
                  _attachmentChips(),
              ],
            ),
          ),
          // DSH-web message meta + action row: copy / edit / revert / time.
          // (Suppressed on compaction event rows — they are apparatus, not
          // conversation turns.)
          if (!m.thinking && m.kind != MsgKind.compact)
            _actionRow(context, isUser, isLast),
        ],
      ),
    );
  }

  /// Text the copy button puts on the clipboard.
  ///
  /// Tool rows keep their output in `toolDetail` and leave `content` empty,
  /// so copying off `content` alone silently copied nothing while still
  /// reporting success — that was the "copy button does nothing" report.
  String _copyText() {
    final body = m.content.trim();
    final detail = (m.toolDetail ?? '').trim();
    if (m.kind == MsgKind.tool) {
      final head = m.toolSummary?.trim().isNotEmpty == true
          ? '${m.toolName ?? 'tool'} · ${m.toolSummary!.trim()}'
          : (m.toolName ?? 'tool');
      if (detail.isEmpty) return body.isEmpty ? head : body;
      return '$head\n$detail';
    }
    if (body.isNotEmpty) return body;
    return detail;
  }

  Widget _actionRow(BuildContext context, bool isUser, bool isLast) {
    final items = <Widget>[];
    void add(IconData icon, String tip, VoidCallback fn) {
      items.add(
        Tooltip(
          message: tip,
          waitDuration: const Duration(milliseconds: 500),
          child: InkWell(
            borderRadius: BorderRadius.circular(4),
            onTap: fn,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 3),
              child: Icon(icon, size: 13, color: Aether.textFaint),
            ),
          ),
        ),
      );
    }

    final copyText = _copyText();
    if (copyText.isNotEmpty) {
      add(Icons.copy_outlined, 'Copy', () async {
        await Clipboard.setData(ClipboardData(text: copyText));
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Copied to clipboard'),
              duration: Duration(milliseconds: 800),
            ),
          );
        }
      });
    }
    if (isUser && isLast) {
      add(Icons.edit_outlined, 'Edit & resend', () {
        input.text = m.content;
        AppState.I.deleteMessagesFrom(session.id, msgIndex);
        onAction();
      });
      add(Icons.replay_outlined, 'Revert', () {
        AppState.I.deleteMessagesFrom(session.id, msgIndex);
        onAction();
      });
    }
    // DSH message feedback: like/dislike + note on final assistant rows.
    // Re-clicking the same value retracts. A down-vote offers a note.
    if (!isUser && m.kind == MsgKind.text && !m.thinking) {
      items.add(
        Tooltip(
          message: m.feedback == 'up' ? 'Retract like' : 'Good answer',
          waitDuration: const Duration(milliseconds: 500),
          child: InkWell(
            borderRadius: BorderRadius.circular(4),
            onTap: () {
              m.feedback = m.feedback == 'up' ? null : 'up';
              m.feedbackNote = null;
              AppState.I.persistSessions();
              onAction();
            },
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 3),
              child: Icon(
                m.feedback == 'up'
                    ? Icons.thumb_up_alt
                    : Icons.thumb_up_alt_outlined,
                size: 13,
                color: m.feedback == 'up' ? Aether.accent : Aether.textFaint,
              ),
            ),
          ),
        ),
      );
      items.add(
        Tooltip(
          message: m.feedback == 'down' ? 'Retract dislike' : 'Bad answer',
          waitDuration: const Duration(milliseconds: 500),
          child: InkWell(
            borderRadius: BorderRadius.circular(4),
            onTap: () {
              if (m.feedback == 'down') {
                m.feedback = null;
                m.feedbackNote = null;
                AppState.I.persistSessions();
                onAction();
                return;
              }
              m.feedback = 'down';
              _askFeedbackNote(context);
            },
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 3),
              child: Icon(
                m.feedback == 'down'
                    ? Icons.thumb_down_alt
                    : Icons.thumb_down_alt_outlined,
                size: 13,
                color: m.feedback == 'down' ? Aether.danger : Aether.textFaint,
              ),
            ),
          ),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 8, top: 2),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          ...items,
          if (!isUser && m.elapsedMs != null)
            Padding(
              padding: const EdgeInsets.only(left: 4),
              child: Text(
                '${(m.elapsedMs! / 1000).toStringAsFixed(1)}s',
                style: TextStyle(fontSize: 10.5, color: Aether.textFaint),
              ),
            ),
          Padding(
            padding: const EdgeInsets.only(left: 4),
            child: Text(
              _formatTime(m.time),
              style: TextStyle(fontSize: 10.5, color: Aether.textFaint),
            ),
          ),
        ],
      ),
    );
  }

  String _formatTime(DateTime t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  /// Optional note attached to a down-vote (DSH feedback note popover).
  void _askFeedbackNote(BuildContext context) {
    final c = TextEditingController();
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Aether.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => Padding(
        padding: EdgeInsets.fromLTRB(
          16, 16, 16, MediaQuery.of(ctx).viewInsets.bottom + 16,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'What was wrong with this answer?',
              style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 4),
            Text(
              'Optional — the note stays on this device.',
              style: TextStyle(fontSize: 11.5, color: Aether.textMuted),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: c,
              autofocus: true,
              maxLines: 3,
              style: const TextStyle(fontSize: 13),
              decoration: const InputDecoration(
                hintText: 'e.g. wrong API, hallucinated paths…',
              ),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: Aether.accent,
                  padding: const EdgeInsets.symmetric(vertical: 12),
                ),
                onPressed: () {
                  m.feedbackNote = c.text.trim();
                  AppState.I.persistSessions();
                  Navigator.pop(ctx);
                  onAction();
                },
                child: const Text('Save', style: TextStyle(fontSize: 13.5)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _text(bool isUser) => Container(
    padding: EdgeInsets.symmetric(
      horizontal: isUser ? 14 : 4,
      vertical: isUser ? 10 : 4,
    ),
    decoration: BoxDecoration(
      // DSH-web user bubble: a SOFT accent-tinted fill, fully rounded,
      // NO hard border (the bordered "wireframe box" was the visual
      // mismatch the user flagged). Assistant stays borderless prose.
      color: isUser
          ? Aether.accent.withValues(alpha: 0.16)
          : Colors.transparent,
      borderRadius: BorderRadius.circular(18),
    ),
    child: isUser
        ? SelectableText(
            m.content,
            style: TextStyle(fontSize: 14.5, height: 1.5, color: Aether.text),
          )
        : _DshMarkdown(content: m.content),
  );

  Widget _reasoning() => _ReasoningCard(m);

  /// Attachment chips under a user message (paperclip + name + size).
  Widget _attachmentChips() => Padding(
    padding: const EdgeInsets.only(top: 4),
    child: Wrap(
      spacing: 6,
      runSpacing: 4,
      alignment: WrapAlignment.end,
      children: [
        for (final a in m.attachments)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
            decoration: BoxDecoration(
              color: Aether.surfaceRaised,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: Aether.hairline),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  _attachIcon(a.name),
                  size: 13,
                  color: Aether.accent,
                ),
                const SizedBox(width: 5),
                Text(
                  a.name,
                  style: TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w600,
                    color: Aether.text,
                  ),
                ),
                const SizedBox(width: 5),
                Text(
                  _fmtSize(a.size),
                  style: TextStyle(fontSize: 10.5, color: Aether.textFaint),
                ),
              ],
            ),
          ),
      ],
    ),
  );

  IconData _attachIcon(String name) {
    final ext = name.split('.').last.toLowerCase();
    return switch (ext) {
      'png' || 'jpg' || 'jpeg' || 'gif' || 'webp' || 'bmp' => Icons.image,
      'mp4' || 'mov' || 'avi' || 'mkv' || 'webm' => Icons.videocam,
      'mp3' || 'wav' || 'ogg' || 'm4a' || 'flac' => Icons.audio_file,
      'pdf' => Icons.picture_as_pdf,
      'zip' || 'tar' || 'gz' || 'rar' || '7z' => Icons.folder_zip,
      'dart' || 'py' || 'js' || 'ts' || 'json' || 'yaml' || 'yml' ||
      'md' || 'txt' || 'csv' || 'html' || 'css' || 'sh' => Icons.code,
      _ => Icons.insert_drive_file,
    };
  }

  String _fmtSize(int b) => b >= 1048576
      ? '${(b / 1048576).toStringAsFixed(1)} MB'
      : b >= 1024
      ? '${(b / 1024).toStringAsFixed(0)} KB'
      : '$b B';

  /// DSH ToolRow parity — collapsed 24px row (icon + title · summary)
  /// expanding to a Terminal/Diff/plain detail block.
  Widget _toolCard() => _ToolCard(m);

  /// DSH turn-tail parity — faint footer row (elapsed · stats).
  Widget _turnTail() => _TurnTailRow(m);

  Widget _imageGen(BuildContext context) {
    final file = m.imagePath != null ? File(m.imagePath!) : null;
    final exists = file != null && file.existsSync();
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: Aether.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Aether.hairline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // The real generated image, saved in the session workspace.
          AspectRatio(
            aspectRatio: 1,
            child: exists
                ? Image.file(file, fit: BoxFit.cover,
                    errorBuilder: (_, _, _) => _imageGenFallback())
                : _imageGenFallback(),
          ),
          Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  m.content,
                  style: TextStyle(fontSize: 12.5, color: Aether.textMuted),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    if (exists) ...[
                      _imageAction(
                        Icons.open_in_full,
                        'Open',
                        () => _openLocalFile(context, m.imagePath!),
                      ),
                      const SizedBox(width: 14),
                      Text(
                        '${(file.lengthSync() / 1024).toStringAsFixed(0)} KB',
                        style: TextStyle(
                          fontSize: 11,
                          color: Aether.textFaint,
                        ),
                      ),
                    ] else
                      Text(
                        'image file not in workspace',
                        style: TextStyle(
                          fontSize: 11,
                          color: Aether.textFaint,
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _imageGenFallback() => Container(
    color: Aether.surfaceAlt,
    child: const Center(
      child: Icon(Icons.auto_awesome, color: Aether.accent, size: 40),
    ),
  );

  Widget _imageAction(IconData icon, String label, VoidCallback onTap) =>
      GestureDetector(
        onTap: onTap,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 15, color: Aether.accent),
            const SizedBox(width: 4),
            Text(
              label,
              style: TextStyle(fontSize: 11, color: Aether.accent),
            ),
          ],
        ),
      );

  /// Open a local workspace file with the best-matching app.
  void _openLocalFile(BuildContext context, String path) {
    try {
      launchUrl(Uri.file(path));
    } catch (_) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('No app can open ${path.split('/').last}'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }
}

/// One row in the composer slash-suggestion menu.
///
/// Sources: built-in commands, user skills, connected MCP server tools, and
/// installed plugins. Commands/skills insert their `/name`; tools and plugins
/// insert a ready-to-send prompt instead, because they are model tools, not
/// composer commands.
class _SlashSuggestion {
  final IconData icon;
  final String name; // '/help' style for commands, tool name otherwise
  final String description;
  final String hint;

  /// Text written into the composer when picked (defaults to `name `).
  final String? insert;

  /// Group label shown above the first row of each source.
  final String group;
  const _SlashSuggestion({
    required this.icon,
    required this.name,
    required this.description,
    required this.hint,
    this.insert,
    this.group = 'Commands',
  });
}

/// Staged-attachment preview chips shown above the composer text field.
/// Each chip shows file icon + name + size with an ✕ to remove. Hidden
/// when nothing is staged.
class _AttachmentChip extends StatelessWidget {
  const _AttachmentChip();

  IconData _iconFor(String name) {
    final ext = name.contains('.') ? name.split('.').last.toLowerCase() : '';
    const img = {'png', 'jpg', 'jpeg', 'gif', 'webp', 'bmp', 'heic'};
    const vid = {'mp4', 'mov', 'mkv', 'webm', '3gp'};
    const aud = {'mp3', 'wav', 'm4a', 'aac', 'ogg', 'flac'};
    if (img.contains(ext)) return Icons.image_outlined;
    if (vid.contains(ext)) return Icons.videocam_outlined;
    if (aud.contains(ext)) return Icons.audiotrack_outlined;
    if (ext == 'pdf') return Icons.picture_as_pdf_outlined;
    return Icons.insert_drive_file_outlined;
  }

  String _fmtSize(int b) => b >= 1048576
      ? '${(b / 1048576).toStringAsFixed(1)} MB'
      : b >= 1024
      ? '${(b / 1024).toStringAsFixed(0)} KB'
      : '$b B';

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: AgentService.I,
      builder: (_, _) {
        final atts = AgentService.I.pendingAttachments;
        if (atts.isEmpty) return const SizedBox.shrink();
        return Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final att in atts)
              Container(
                margin: const EdgeInsets.only(top: 6),
                padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
                decoration: BoxDecoration(
                  color: Aether.surface,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: Aether.accent.withValues(alpha: 0.4),
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(_iconFor(att.name), size: 16, color: Aether.accent),
                    const SizedBox(width: 7),
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 150),
                      child: Text(
                        att.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      _fmtSize(att.size),
                      style: TextStyle(fontSize: 11, color: Aether.textFaint),
                    ),
                    const SizedBox(width: 4),
                    GestureDetector(
                      onTap: () => AgentService.I.removeAttachment(att.name),
                      child: Icon(
                        Icons.close,
                        size: 15,
                        color: Aether.textMuted,
                      ),
                    ),
                  ],
                ),
              ),
          ],
        );
      },
    );
  }
}

class _InputBar extends StatefulWidget {
  final TextEditingController controller;
  final bool running;

  /// Approval takeover: when an approval/question card is pending, the
  /// composer is disabled until the user answers it (DSH parity).
  final bool locked;
  final VoidCallback onSend;
  const _InputBar({
    required this.controller,
    required this.running,
    this.locked = false,
    required this.onSend,
  });

  @override
  State<_InputBar> createState() => _InputBarState();
}

class _InputBarState extends State<_InputBar> {
  TextEditingController get controller => widget.controller;
  bool get running => widget.running;
  bool get locked => widget.locked;
  VoidCallback get onSend => widget.onSend;

  /// DSH-web rule: running + empty draft = Stop; running + draft = Send
  /// (queue). The queue color (teal) signals "this goes to the queue",
  /// distinct from the normal accent send.
  static const _queueColor = Color(0xFF0E9F9F);

  /// True while the composer is in slash mode (text starts with `/` and the
  /// first token has no space yet). A bare `/` counts — that is the whole
  /// point of the menu.
  bool _slashActive = false;
  String _slashQuery = '';

  /// `@` reference mode: the token under the caret starts with `@`, so the
  /// menu offers this chat's subagents (the model addresses them by id in
  /// send_message / interrupt_agent).
  bool _mentionActive = false;
  String _mentionQuery = '';
  int _mentionStart = -1;

  /// Fuzzy score for [candidate] against [query].
  ///
  /// Returns null when the query is not a subsequence of the candidate.
  /// Lower is better: exact prefix wins, then earlier first match, then
  /// tighter gaps, then shorter candidate.
  static int? _fuzzyScore(String candidate, String query) {
    if (query.isEmpty) return candidate.length;
    final c = candidate.toLowerCase();
    final q = query.toLowerCase();
    if (c.startsWith(q)) return c.length - q.length;
    var score = 1000;
    var ci = 0;
    var lastHit = -1;
    for (var qi = 0; qi < q.length; qi++) {
      final hit = c.indexOf(q[qi], ci);
      if (hit < 0) return null;
      if (qi == 0) {
        score += hit * 4; // reward matches near the start
      } else {
        final gap = hit - lastHit - 1;
        score += gap * 2; // reward tight, adjacent matches
        // Matching right after a separator reads like a word start.
        if (gap == 0 || hit == 0) score -= 1;
      }
      lastHit = hit;
      ci = hit + 1;
    }
    return score + c.length;
  }

  /// Command/skill/tool/plugin suggestions for the current slash input, or
  /// subagent references while in `@` mode.
  List<_SlashSuggestion> get _suggestions {
    if (_mentionActive) return _mentionSuggestions;
    if (!_slashActive) return const [];
    final query = _slashQuery.toLowerCase();
    final scored = <({int score, int order, _SlashSuggestion s})>[];
    var order = 0;
    void add(int groupRank, String haystack, _SlashSuggestion s) {
      final score = _fuzzyScore(haystack, query);
      if (score == null) return;
      scored.add((score: groupRank * 10000 + score, order: order++, s: s));
    }

    for (final c in CommandService.I.commands) {
      add(
        0,
        c.name,
        _SlashSuggestion(
          icon: Icons.terminal_rounded,
          name: '/${c.name}',
          description: c.description,
          hint: c.hint,
        ),
      );
    }
    for (final s in SkillService.I.userSkills) {
      add(
        1,
        s.name,
        _SlashSuggestion(
          icon: Icons.auto_fix_high_outlined,
          name: '/${s.name}',
          description: s.description.isEmpty ? 'Skill' : s.description,
          hint: '',
          group: 'Skills',
        ),
      );
    }
    // Connected MCP server tools — the model can call these, so the composer
    // should be able to point at them too.
    for (final entry in McpService.I.connectedTools.entries) {
      for (final t in entry.value) {
        final desc = (t.description ?? '').trim();
        add(
          2,
          '${entry.key} ${t.name}',
          _SlashSuggestion(
            icon: Icons.extension_outlined,
            name: t.name,
            description: desc.isEmpty
                ? 'MCP tool · ${entry.key}'
                : '${entry.key} · $desc',
            hint: '',
            insert: 'Use the ${entry.key} MCP tool "${t.name}" to ',
            group: 'MCP tools',
          ),
        );
      }
    }
    // Installed + enabled plugins that add agent tools.
    for (final p in AppState.I.plugins.where((p) => p.installed && p.enabled)) {
      add(
        3,
        p.name,
        _SlashSuggestion(
          icon: Icons.widgets_outlined,
          name: p.name,
          description: p.description.isEmpty
              ? '${p.category} plugin'
              : p.description,
          hint: '',
          insert: 'Use the ${p.name} plugin to ',
          group: 'Plugins',
        ),
      );
    }
    scored.sort((a, b) {
      final c = a.score.compareTo(b.score);
      return c != 0 ? c : a.order.compareTo(b.order);
    });
    return [for (final e in scored.take(24)) e.s];
  }

  /// `@` menu: this chat's subagents, so the user can point the parent agent
  /// at a specific child ("@sub-2 stop and summarise").
  List<_SlashSuggestion> get _mentionSuggestions {
    final app = AppState.I;
    final parent = app.activeSession;
    if (parent == null) return const [];
    final agent = AgentService.I;
    final query = _mentionQuery.toLowerCase();
    final scored = <({int score, int order, _SlashSuggestion s})>[];
    var order = 0;
    for (final sub in agent.subagentsOf(parent.id)) {
      final child = app.sessionById(sub.sessionId);
      final label = child?.agentLabel ?? sub.label;
      final live = agent.busyFor(sub.sessionId);
      final state = live ? 'running' : sub.state;
      final score = _fuzzyScore('${sub.id} $label', query);
      if (score == null) continue;
      scored.add((
        score: score,
        order: order++,
        s: _SlashSuggestion(
          icon: Icons.smart_toy_outlined,
          name: sub.id,
          description:
              '$state · ${child?.messages.length ?? 0} rows — '
              '${cleanTruncate(label, 60)}',
          hint: '',
          insert: '@${sub.id} ',
          group: 'Subagents',
        ),
      ));
    }
    // ── @file: workspace files (DSH file-reference parity) ──
    // Files under the active session's workspace; directory descent via
    // the query (type `@src/` to descend into a folder, `@src/ma` to
    // fuzzy-match INSIDE it). The model receives the chip expanded with
    // a section heading at send time.
    var fileHits = 0;
    try {
      final ws = agent.workspaceRootFor(parent);
      // Descent: any `/` in the query means we're INSIDE a subfolder —
      // list that folder (depth-capped) and match on the LAST segment.
      var dir = ws;
      var lastSeg = query;
      if (query.contains('/')) {
        final parts = query.split('/')
          ..removeWhere((p) => p.isEmpty);
        // Walk the leading segments as directories (depth cap 3).
        for (var i = 0; i < parts.length - 1 && i < 3; i++) {
          final next = Directory('${dir.path}/${parts[i]}');
          if (next.existsSync()) dir = next;
        }
        lastSeg = parts.last;
      }
      final entities = dir.listSync(recursive: false);
      for (final e in entities) {
        final base = e.path.split('/').last;
        if (base.startsWith('.')) continue; // .spill etc.
        final isDir = e is Directory;
        final score = _fuzzyScore(base, lastSeg);
        if (score == null) continue;
        fileHits++;
        // Display path relative to the workspace root for descent rows.
        final rel = e.path.startsWith(ws.path) && e.path != ws.path
            ? e.path.substring(ws.path.length + 1)
            : base;
        scored.add((
          score: score,
          order: order++,
          s: _SlashSuggestion(
            icon: isDir
                ? Icons.folder_outlined
                : Icons.insert_drive_file_outlined,
            name: rel,
            description: isDir ? 'directory — @$rel/ to descend' : 'workspace file',
            hint: '',
            insert: '@$rel${isDir ? '/' : ' '}',
            group: 'Files',
          ),
        ));
      }
    } catch (_) {
      // Workspace not ready — files just don't appear.
    }
    // PR23/M2: an EMPTY menu looks like a dead feature — show a hint row
    // explaining what @ can reference instead of rendering nothing.
    if (fileHits == 0 && agent.subagentsOf(parent.id).isEmpty) {
      scored.add((
        score: 999,
        order: order++,
        s: _SlashSuggestion(
          icon: Icons.info_outline,
          name: 'no files yet',
          description: 'The agent creates workspace files as it works — '
              'try @session:<id> to cite another chat',
          hint: '',
          insert: '@',
          group: 'Files',
        ),
      ));
    }
    // ── @session: this chat's sessions (DSH session-reference parity) ──
    for (final s in app.rootSessions.take(30)) {
      if (s.id == parent.id) continue;
      final score = _fuzzyScore('${s.title} ${s.id}', query);
      if (score == null) continue;
      scored.add((
        score: score,
        order: order++,
        s: _SlashSuggestion(
          icon: Icons.chat_bubble_outline,
          name: s.title,
          description: '${s.messages.length} messages · ${s.id}',
          hint: '',
          insert: '@session:${s.id} ',
          group: 'Sessions',
        ),
      ));
    }
    scored.sort((a, b) {
      final c = a.score.compareTo(b.score);
      return c != 0 ? c : a.order.compareTo(b.order);
    });
    return [for (final e in scored.take(14)) e.s];
  }

  void _onTextChanged() {
    final t = controller.text;
    var active = false;
    var query = '';
    if (t.startsWith('/')) {
      final body = t.substring(1);
      final space = body.indexOf(' ');
      // A space closes slash mode: `/compact now` is an argument, not a query.
      if (space < 0) {
        active = true;
        query = body.toLowerCase();
      }
    }
    // `@` reference: look back from the caret to the token start.
    var mention = false;
    var mentionQuery = '';
    var mentionStart = -1;
    final sel = controller.selection;
    final caret = sel.isValid ? sel.baseOffset : t.length;
    if (caret > 0 && caret <= t.length) {
      final head = t.substring(0, caret);
      final at = head.lastIndexOf('@');
      if (at >= 0) {
        final token = head.substring(at + 1);
        // Boundary: @ at start, after whitespace, or after a common
        // enclosing char ( `( [ , >` — chat/prose contexts; `x@` emails
        // still never trigger). PR23/M7.
        final boundaryOk = at == 0 ||
            ' \n\t([,>'.contains(head[at - 1]);
        if (boundaryOk && !token.contains(RegExp(r'\s'))) {
          mention = true;
          mentionQuery = token.toLowerCase();
          mentionStart = at;
        }
      }
    }
    // PR23/M4: include _mentionStart in the change guard — a stale start
    // offset (caret moved to a different @token) corrupts insertion.
    if (active != _slashActive ||
        query != _slashQuery ||
        mention != _mentionActive ||
        mentionQuery != _mentionQuery ||
        mentionStart != _mentionStart) {
      setState(() {
        _slashActive = active;
        _slashQuery = query;
        _mentionActive = mention;
        _mentionQuery = mentionQuery;
        _mentionStart = mentionStart;
      });
    }
  }

  void _applySuggestion(_SlashSuggestion s) {
    if (_mentionActive && _mentionStart >= 0) {
      // Replace just the `@token` under the caret, keeping the rest intact.
      final text = controller.text;
      final sel = controller.selection;
      final caret = sel.isValid ? sel.baseOffset : text.length;
      final insert = s.insert ?? '@${s.name} ';
      final next =
          text.substring(0, _mentionStart) + insert + text.substring(caret);
      controller.text = next;
      controller.selection = TextSelection.collapsed(
        offset: _mentionStart + insert.length,
      );
      setState(() {
        _mentionActive = false;
        _mentionQuery = '';
        _mentionStart = -1;
      });
      return;
    }
    controller.text = s.insert ?? '${s.name} ';
    controller.selection = TextSelection.collapsed(
      offset: controller.text.length,
    );
    setState(() {
      _slashActive = false;
      _slashQuery = '';
    });
  }

  void _attachSheet(BuildContext context) {
    showModalBottomSheet(
      context: context,
      builder: (sheetCtx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 8),
            _attachOption(
              sheetCtx,
              Icons.photo_library_outlined,
              'Photos & videos',
              'Pick from gallery (multiple, max 20 MB each)',
              () => _pickMedia(sheetCtx),
            ),
            _attachOption(
              sheetCtx,
              Icons.insert_drive_file_outlined,
              'Document',
              'PDF, code, text, CSV files',
              () => _pickDocument(sheetCtx),
            ),
            _attachOption(
              sheetCtx,
              Icons.auto_awesome,
              'Generate image',
              'Create with AI in this chat',
              () {
                Navigator.pop(sheetCtx);
                _imagePromptDialog(context);
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  /// Pick a document (PDF/code/text/CSV) and stage it as an attachment.
  Future<void> _pickDocument(BuildContext sheetCtx) async {
    Navigator.pop(sheetCtx);
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const [
        'pdf',
        'txt',
        'md',
        'csv',
        'json',
        'dart',
        'py',
        'js',
        'ts',
        'html',
        'css',
        'xml',
        'yaml',
        'yml',
        'java',
        'kt',
        'c',
        'cpp',
        'h',
        'sh',
        'log',
        'doc',
        'docx',
      ],
      allowMultiple: true,
      withData: false,
    );
    await _stagePicked(result);
  }

  /// Pick a photo/video from the gallery and stage it as an attachment.
  Future<void> _pickMedia(BuildContext sheetCtx) async {
    Navigator.pop(sheetCtx);
    final result = await FilePicker.platform.pickFiles(
      type: FileType.media,
      allowMultiple: true,
      withData: false,
    );
    await _stagePicked(result);
  }

  Future<void> _stagePicked(FilePickerResult? result) async {
    if (result == null || result.files.isEmpty) return;
    final files = result.files.where((f) => f.path != null).toList();
    if (files.isEmpty) {
      _toast('Could not access that file.');
      return;
    }
    var ok = 0;
    final errors = <String>[];
    for (final f in files) {
      final err = await AgentService.I.attachFile(f.path!, f.name);
      if (err != null) {
        errors.add(err);
      } else {
        ok++;
      }
    }
    if (ok == 0) {
      _toast(errors.isEmpty ? 'No files attached.' : errors.first);
    } else if (errors.isEmpty) {
      _toast('Attached $ok file${ok == 1 ? '' : 's'} — sent with your next message.');
    } else {
      _toast('Attached $ok · ${errors.length} skipped (${errors.first})');
    }
  }

  void _toast(String msg) {
    final ctx = _ctx;
    if (ctx == null || !ctx.mounted) return;
    ScaffoldMessenger.of(ctx).showSnackBar(
      SnackBar(
        content: Text(msg),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 2),
      ),
    );
  }

  // The composer needs a context for toasts that outlives the bottom sheet.
  BuildContext? _ctx;

  void _imagePromptDialog(BuildContext context) {
    final c = TextEditingController();
    showDialog<void>(
      context: context,
      builder: (d) => AlertDialog(
        title: const Text('Generate an image', style: TextStyle(fontSize: 16)),
        content: TextField(
          controller: c,
          autofocus: true,
          maxLines: 3,
          minLines: 1,
          decoration: const InputDecoration(
            hintText: 'A minimal mountain wallpaper, 4K…',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(d),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              final prompt = c.text.trim();
              Navigator.pop(d);
              if (prompt.isEmpty) return;
              controller.text = 'Generate an image: $prompt';
              onSend();
            },
            child: const Text('Generate'),
          ),
        ],
      ),
    );
  }

  Widget _attachOption(
    BuildContext context,
    IconData icon,
    String title,
    String sub,
    VoidCallback onTap,
  ) {
    return ListTile(
      leading: Container(
        width: 38,
        height: 38,
        decoration: BoxDecoration(
          color: Aether.surfaceRaised,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Icon(icon, size: 18, color: Aether.textMuted),
      ),
      title: Text(title, style: const TextStyle(fontSize: 14)),
      subtitle: Text(
        sub,
        style: TextStyle(fontSize: 11.5, color: Aether.textFaint),
      ),
      onTap: onTap,
    );
  }

  @override
  Widget build(BuildContext context) {
    _ctx = context; // keep a live context for post-picker toasts
    // Computed once per build — the getter walks commands, skills, MCP tools
    // and plugins, so calling it three times in the tree was wasteful.
    final suggestions = _suggestions;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 10),
        child: Container(
          // DSH composer card: text fills the FULL width on top; the
          // toolbar (attach / mode chip / mic / send-stop) sits on its own
          // row below — the text never shares a row with the mode icon.
          padding: const EdgeInsets.fromLTRB(6, 4, 6, 4),
          decoration: BoxDecoration(
            color: Aether.surfaceAlt,
            borderRadius: BorderRadius.circular(22),
            border: Border.all(color: Aether.hairline),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // ── Staged attachment preview chips (dismissible) ──
              const _AttachmentChip(),
              // ── Slash menu: opens on a bare `/`, fuzzy-ranked, grouped
              //    into Commands / Skills / MCP tools / Plugins ──
              if (suggestions.isNotEmpty)
                Container(
                  margin: const EdgeInsets.fromLTRB(6, 2, 6, 0),
                  constraints: const BoxConstraints(maxHeight: 220),
                  decoration: BoxDecoration(
                    color: Aether.surface,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: Aether.hairline),
                  ),
                  child: ListView.builder(
                    shrinkWrap: true,
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    itemCount: suggestions.length,
                    itemBuilder: (_, i) {
                      final s = suggestions[i];
                      final newGroup =
                          i == 0 || suggestions[i - 1].group != s.group;
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          if (newGroup)
                            Padding(
                              padding: EdgeInsets.fromLTRB(
                                12,
                                i == 0 ? 2 : 8,
                                12,
                                3,
                              ),
                              child: Text(
                                s.group.toUpperCase(),
                                style: TextStyle(
                                  fontSize: 9.5,
                                  fontWeight: FontWeight.w700,
                                  letterSpacing: 1.1,
                                  color: Aether.textFaint,
                                ),
                              ),
                            )
                          else
                            Divider(
                              height: 1,
                              thickness: 0.5,
                              color: Aether.hairline,
                            ),
                          InkWell(
                            onTap: () => _applySuggestion(s),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 8,
                              ),
                              child: Row(
                                children: [
                                  Icon(s.icon, size: 16, color: Aether.accent),
                                  const SizedBox(width: 9),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          s.name,
                                          style: const TextStyle(
                                            fontSize: 13.5,
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                        if (s.description.isNotEmpty) ...[
                                          const SizedBox(height: 1),
                                          Text(
                                            s.description,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: TextStyle(
                                              fontSize: 11,
                                              color: Aether.textFaint,
                                            ),
                                          ),
                                        ],
                                      ],
                                    ),
                                  ),
                                  if (s.hint.isNotEmpty)
                                    Text(
                                      s.hint,
                                      style: TextStyle(
                                        fontSize: 10.5,
                                        color: Aether.textFaint,
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          ),
                        ],
                      );
                    },
                  ),
                ),
              // ── Text area — full card width ──
              TextField(
                controller: controller,
                minLines: 1,
                maxLines: 5,
                // Approval takeover: locked while a card awaits an answer.
                enabled: !locked,
                // DSH composer: 16px input, 24px line-height.
                style: const TextStyle(fontSize: 16, height: 24 / 16),
                decoration: InputDecoration(
                  hintText: locked
                      ? 'Answer the approval card above first…'
                      : 'Describe what you want to build…  / commands  @ agents',
                  hintStyle: const TextStyle(fontSize: 16, height: 24 / 16),
                  filled: false,
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                  disabledBorder: InputBorder.none,
                  contentPadding: const EdgeInsets.fromLTRB(10, 8, 10, 4),
                ),
                onChanged: (_) => _onTextChanged(),
                onSubmitted: (_) {
                  if (!locked) onSend();
                },
              ),
              // ── Toolbar row ──
              Row(
                children: [
                  IconButton(
                    tooltip: 'Attach',
                    icon: Icon(
                      Icons.add_circle_outline,
                      size: 22,
                      color: Aether.textMuted,
                    ),
                    onPressed: () => _attachSheet(context),
                  ),
                  // DSH-web workspace chip — current workspace/repo name.
                  const _WorkspaceChip(),
                  const SizedBox(width: 6),
                  // DSH-web plan chip — amber, only while plan mode is on.
                  const _PlanChip(),
                  // DSH-web mode selector — icon + text chip, opens the mode sheet.
                  const _ModeChip(),
                  // Model selector lives in the header AppBar — not duplicated here.
                  const Spacer(),
                  IconButton(
                    tooltip: 'Voice',
                    icon: Icon(
                      Icons.mic_none,
                      size: 20,
                      color: Aether.textMuted,
                    ),
                    onPressed: () {},
                  ),
                  // ── Stateful primary button (DSH-web InputBar pattern) ──
                  AnimatedBuilder(
                    animation: Listenable.merge([AgentService.I, controller]),
                    builder: (_, _) {
                      // Per-session run state (never leaked from other
                      // sessions — the multi-session blink fix).
                      final runningNow = AgentService.I.busyFor(
                        AppState.I.activeSession?.id ?? '',
                      );
                      final hasDraft = controller.text.trim().isNotEmpty;
                      final IconData icon;
                      final Color bg;
                      final String tip;
                      if (runningNow && !hasDraft) {
                        // Running + empty → STOP (red).
                        icon = Icons.stop_rounded;
                        bg = Colors.redAccent;
                        tip = 'Stop generating';
                      } else if (runningNow && hasDraft) {
                        // Running + draft → SEND-TO-QUEUE (teal).
                        icon = Icons.arrow_upward;
                        bg = _queueColor;
                        tip = 'Add to queue';
                      } else {
                        // Idle → SEND (accent).
                        icon = Icons.arrow_upward;
                        bg = Aether.accent;
                        tip = 'Send';
                      }
                      return Container(
                        decoration: BoxDecoration(
                          color: bg,
                          shape: BoxShape.circle,
                        ),
                        child: IconButton(
                          tooltip: tip,
                          icon: Icon(icon, size: 18, color: Colors.white),
                          onPressed: () {
                            if (runningNow && !hasDraft) {
                              AgentService.I.cancelRun();
                            } else {
                              onSend();
                            }
                          },
                        ),
                      );
                    },
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

class _TypingBubble extends StatelessWidget {
  const _TypingBubble();

  @override
  Widget build(BuildContext context) {
    // Inline parsing status (no bubble/box): a pulsing accent dot + the live
    // status line from the run, so retries/backoffs/compaction are visible
    // instead of a permanent generic label.
    return AnimatedBuilder(
      animation: AgentService.I,
      builder: (_, _) {
        final sid = AppState.I.activeSessionId;
        final status = sid == null ? null : AgentService.I.statusFor(sid);
        final label = (status == null || status.trim().isEmpty)
            ? 'Working…'
            : status.trim();
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 10),
          child: Row(
            children: [
              const _ChaseDot(Aether.accent),
              const SizedBox(width: 10),
              Expanded(
                child: _ShimmerText(
                  label,
                  style: TextStyle(
                    fontSize: 12.5,
                    color: Aether.textMuted,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// DSH-web QueueDock — a strip above the input bar showing queued messages
/// with edit/remove actions. Shown only when [AgentService.queuedMessages]
/// is non-empty.
/// DSH-web GoalBar — the session goal as a strip above the composer dock:
/// objective, round chip, status; edit / pause / resume / clear actions.
/// Renders only while a goal exists. Pause/resume flips the goal status
/// directly; clear marks it complete (the strip then disappears).
class _GoalBar extends StatelessWidget {
  const _GoalBar();

  void _update(ChatSession s, String status) {
    s.goal?['status'] = status;
    AppState.I.persistSessions();
    AppState.I.refresh();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: AppState.I,
      builder: (_, _) {
        final s = AppState.I.activeSession;
        final g = s?.goal;
        if (s == null || g == null) return const SizedBox.shrink();
        final status = g['status'] as String? ?? 'active';
        final objective = g['objective'] as String? ?? '';
        final round = (g['round'] as num?)?.toInt() ?? 0;
        final color = switch (status) {
          'active' => Aether.accent,
          'paused' => Aether.warn,
          'blocked' => Aether.danger,
          _ => Aether.success, // complete
        };
        return Container(
          margin: const EdgeInsets.fromLTRB(12, 0, 12, 4),
          decoration: BoxDecoration(
            color: Aether.surface,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: color.withValues(alpha: 0.4)),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          child: Row(
            children: [
              Icon(Icons.flag_outlined, size: 14, color: color),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  objective,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12.5),
                ),
              ),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 6,
                  vertical: 1,
                ),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  'r$round · $status',
                  style: TextStyle(
                    fontSize: 10.5,
                    fontWeight: FontWeight.w700,
                    color: color,
                  ),
                ),
              ),
              // Pause / resume.
              if (status == 'active' || status == 'paused')
                IconButton(
                  visualDensity: VisualDensity.compact,
                  tooltip: status == 'active' ? 'Pause goal' : 'Resume goal',
                  icon: Icon(
                    status == 'active'
                        ? Icons.pause_outlined
                        : Icons.play_arrow_outlined,
                    size: 16,
                    color: Aether.textMuted,
                  ),
                  onPressed: () =>
                      _update(s, status == 'active' ? 'paused' : 'active'),
                ),
              // Edit objective.
              IconButton(
                visualDensity: VisualDensity.compact,
                tooltip: 'Edit objective',
                icon: Icon(
                  Icons.edit_outlined,
                  size: 15,
                  color: Aether.textMuted,
                ),
                onPressed: () => _editObjective(context, s, objective),
              ),
              // Clear (marks complete — the bar then hides).
              IconButton(
                visualDensity: VisualDensity.compact,
                tooltip: 'Clear goal',
                icon: Icon(
                  Icons.clear_outlined,
                  size: 16,
                  color: Aether.textFaint,
                ),
                onPressed: () => _update(s, 'complete'),
              ),
            ],
          ),
        );
      },
    );
  }

  void _editObjective(BuildContext context, ChatSession s, String current) {
    final c = TextEditingController(text: current);
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Aether.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => Padding(
        padding: EdgeInsets.fromLTRB(
          16, 16, 16, MediaQuery.of(ctx).viewInsets.bottom + 16,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Goal objective',
              style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: c,
              autofocus: true,
              maxLines: 2,
              style: const TextStyle(fontSize: 13),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: Aether.accent,
                  padding: const EdgeInsets.symmetric(vertical: 12),
                ),
                onPressed: () {
                  final v = c.text.trim();
                  if (v.isNotEmpty) {
                    s.goal?['objective'] = v;
                    AppState.I.persistSessions();
                    AppState.I.refresh();
                  }
                  Navigator.pop(ctx);
                },
                child: const Text('Save', style: TextStyle(fontSize: 13.5)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// DSH-web TodoDock — live checklist written by todo_write tool.
/// Shows above the chat input; each item shows status icon + text.
/// Collapsed by default; tap header to expand full list.
class _TodoDock extends StatefulWidget {
  const _TodoDock();

  @override
  State<_TodoDock> createState() => _TodoDockState();
}

class _TodoDockState extends State<_TodoDock> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: AppState.I,
      builder: (_, _) {
        final todos = AppState.I.activeSession?.todos ?? [];
        if (todos.isEmpty) return const SizedBox.shrink();
        final done = todos.where((t) => t['status'] == 'completed').length;
        final inProg = todos.where((t) => t['status'] == 'in_progress').length;
        return Container(
          margin: const EdgeInsets.fromLTRB(12, 0, 12, 4),
          decoration: BoxDecoration(
            color: Aether.surface,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: Aether.hairline),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              InkWell(
                borderRadius: const BorderRadius.only(
                  topLeft: Radius.circular(10),
                  topRight: Radius.circular(10),
                ),
                onTap: () => setState(() => _expanded = !_expanded),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 7,
                  ),
                  child: Row(
                    children: [
                      Icon(
                        _expanded
                            ? Icons.keyboard_arrow_down
                            : Icons.keyboard_arrow_right,
                        size: 14,
                        color: Aether.textFaint,
                      ),
                      const SizedBox(width: 6),
                      const Icon(
                        Icons.checklist_outlined,
                        size: 13,
                        color: Aether.accent,
                      ),
                      const SizedBox(width: 6),
                      Text(
                        'Tasks · $done/${todos.length} done',
                        style: TextStyle(
                          fontSize: 11,
                          color: Aether.textMuted,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      if (inProg > 0) ...[
                        const SizedBox(width: 6),
                        Container(
                          width: 6,
                          height: 6,
                          decoration: const BoxDecoration(
                            shape: BoxShape.circle,
                            color: Aether.accent,
                          ),
                        ),
                        const SizedBox(width: 4),
                        Text(
                          '$inProg active',
                          style: const TextStyle(
                            fontSize: 10,
                            color: Aether.accent,
                          ),
                        ),
                      ],
                      const Spacer(),
                      // Progress bar mini.
                      SizedBox(
                        width: 40,
                        height: 4,
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(2),
                          child: LinearProgressIndicator(
                            value: todos.isEmpty ? 0 : done / todos.length,
                            backgroundColor: Aether.hairline,
                            valueColor: const AlwaysStoppedAnimation(
                              Aether.success,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              if (_expanded)
                Container(
                  constraints: const BoxConstraints(maxHeight: 200),
                  child: ListView.builder(
                    shrinkWrap: true,
                    padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                    itemCount: todos.length,
                    itemBuilder: (_, i) {
                      final t = todos[i];
                      final status = t['status'] ?? 'pending';
                      return Padding(
                        padding: const EdgeInsets.symmetric(vertical: 3),
                        child: Row(
                          children: [
                            Icon(
                              status == 'completed'
                                  ? Icons.check_circle
                                  : status == 'in_progress'
                                  ? Icons.play_circle_outline
                                  : Icons.radio_button_unchecked,
                              size: 14,
                              color: status == 'completed'
                                  ? Aether.success
                                  : status == 'in_progress'
                                  ? Aether.accent
                                  : Aether.textFaint,
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                t['content'] ?? '',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: status == 'completed'
                                      ? Aether.textFaint
                                      : Aether.text,
                                  decoration: status == 'completed'
                                      ? TextDecoration.lineThrough
                                      : null,
                                ),
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

class _QueueDock extends StatelessWidget {
  final VoidCallback onEdited;
  const _QueueDock({required this.onEdited});

  @override
  Widget build(BuildContext context) {
    final agent = AgentService.I;
    return AnimatedBuilder(
      animation: agent,
      builder: (_, _) {
        final queue = agent.queuedMessages;
        if (queue.isEmpty) return const SizedBox.shrink();
        return SafeArea(
          top: false,
          child: Container(
            margin: const EdgeInsets.fromLTRB(12, 0, 12, 0),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: Aether.surface,
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(14),
              ),
              border: Border.all(color: Aether.hairline),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Header row
                Row(
                  children: [
                    Icon(Icons.queue_music, size: 13, color: Aether.textMuted),
                    const SizedBox(width: 6),
                    Text(
                      '${queue.length} queued message${queue.length > 1 ? 's' : ''}',
                      style: TextStyle(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w600,
                        color: Aether.textMuted,
                      ),
                    ),
                    const Spacer(),
                    GestureDetector(
                      onTap: () {
                        for (var i = queue.length - 1; i >= 0; i--) {
                          agent.removeQueuedMessage(i);
                        }
                        onEdited();
                      },
                      child: Text(
                        'Clear all',
                        style: TextStyle(fontSize: 11, color: Aether.textFaint),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                // Queued message rows
                for (var i = 0; i < queue.length; i++)
                  _QueueRow(index: i, text: queue[i], onEdited: onEdited),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _QueueRow extends StatefulWidget {
  final int index;
  final String text;
  final VoidCallback onEdited;
  const _QueueRow({
    required this.index,
    required this.text,
    required this.onEdited,
  });

  @override
  State<_QueueRow> createState() => _QueueRowState();
}

class _QueueRowState extends State<_QueueRow> {
  bool _editing = false;
  late final TextEditingController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: widget.text);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final agent = AgentService.I;
    if (_editing) {
      return Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Row(
          children: [
            Expanded(
              child: TextField(
                controller: _ctrl,
                autofocus: true,
                style: const TextStyle(fontSize: 12.5),
                decoration: InputDecoration(
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 7,
                  ),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: BorderSide(color: Aether.hairline),
                  ),
                ),
                onSubmitted: (v) {
                  agent.editQueuedMessage(widget.index, v);
                  setState(() => _editing = false);
                  widget.onEdited();
                },
              ),
            ),
            IconButton(
              icon: const Icon(Icons.close, size: 15),
              onPressed: () => setState(() => _editing = false),
            ),
          ],
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Row(
        children: [
          Expanded(
            child: Text(
              widget.text,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12.5, color: Aether.text),
            ),
          ),
          // Strict-steer (DSH parity): pull this row to the front so the
          // running turn injects it on the very next request.
          GestureDetector(
            onTap: () {
              agent.steerQueuedMessage(widget.index);
              widget.onEdited();
            },
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
              child: Icon(
                Icons.fast_forward_outlined,
                size: 14,
                color: Aether.accent,
              ),
            ),
          ),
          GestureDetector(
            onTap: () {
              _ctrl.text = widget.text;
              setState(() => _editing = true);
            },
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: 6, vertical: 4),
              child: Icon(
                Icons.edit_outlined,
                size: 14,
                color: Aether.textMuted,
              ),
            ),
          ),
          GestureDetector(
            onTap: () {
              agent.removeQueuedMessage(widget.index);
              widget.onEdited();
            },
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: 6, vertical: 4),
              child: Icon(
                Icons.delete_outline,
                size: 14,
                color: Aether.textMuted,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _CopyButton extends StatefulWidget {
  final String code;
  const _CopyButton({required this.code});
  @override
  State<_CopyButton> createState() => _CopyButtonState();
}

class _CopyButtonState extends State<_CopyButton> {
  bool copied = false;
  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(6),
      onTap: () async {
        await Clipboard.setData(ClipboardData(text: widget.code));
        setState(() => copied = true);
        Future.delayed(const Duration(seconds: 2), () {
          if (mounted) setState(() => copied = false);
        });
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        child: Row(
          children: [
            Icon(
              copied ? Icons.check : Icons.copy_outlined,
              size: 14,
              color: copied ? Aether.success : Aether.textFaint,
            ),
            const SizedBox(width: 6),
            Text(
              copied ? 'Copied' : 'Copy',
              style: TextStyle(
                fontSize: 11,
                color: copied ? Aether.success : Aether.textFaint,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Approval dock — replaces the old _AgentActivityBar under the AppBar.
/// Shown only when a tool needs user confirmation. Live agent log stays in
/// the chat stream itself; approvals float above the input (DSH-web style).
class _ApprovalDock extends StatelessWidget {
  const _ApprovalDock();

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: AgentService.I,
      builder: (_, _) {
        final req = AgentService.I.pendingApproval;
        if (req == null) return const SizedBox.shrink();
        // ── ask_user_question mode — structured Q&A card ──
        if (req.questions != null && req.questions!.isNotEmpty) {
          return _QuestionsCard(req);
        }
        // ── Plan review (exit_plan_mode) — DSH PlanReviewPanel style ──
        if (req.tool == 'exit_plan_mode') {
          return _PlanReviewCard(req);
        }
        // ── Standard approve/deny card ──
        return Container(
          margin: const EdgeInsets.fromLTRB(12, 0, 12, 6),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: Aether.warn.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Aether.warn.withValues(alpha: 0.4)),
          ),
          child: Row(
            children: [
              const Icon(
                Icons.warning_amber_rounded,
                size: 16,
                color: Aether.warn,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  req.detail.isNotEmpty && req.detail != req.summary
                      ? req.detail
                      : req.summary,
                  maxLines: 8,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    height: 1.4,
                    color: Aether.text,
                    fontFamily: Aether.mono,
                  ),
                ),
              ),
              const SizedBox(width: 6),
              TextButton(
                style: TextButton.styleFrom(
                  foregroundColor: Aether.danger,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  minimumSize: Size.zero,
                ),
                child: const Text('Deny', style: TextStyle(fontSize: 12)),
                onPressed: () => AgentService.I.approve(false),
              ),
              TextButton(
                style: TextButton.styleFrom(
                  foregroundColor: Aether.success,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  minimumSize: Size.zero,
                ),
                child: const Text('Allow', style: TextStyle(fontSize: 12)),
                onPressed: () => AgentService.I.approve(true),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// DSH PlanReviewPanel parity — shows the actual plan markdown with
/// Decline / Approve buttons (fixes: the plan was never rendered before).
class _PlanReviewCard extends StatelessWidget {
  final ApprovalRequest req;
  const _PlanReviewCard(this.req);

  /// "Chat about it" — decline WITH feedback so the model revises instead of
  /// guessing why the plan was refused.
  Future<void> _chatAboutIt(BuildContext context) async {
    final c = TextEditingController();
    final note = await showDialog<String>(
      context: context,
      builder: (d) => AlertDialog(
        backgroundColor: Aether.surface,
        title: const Text(
          'Chat about the plan',
          style: TextStyle(fontSize: 15.5),
        ),
        content: TextField(
          controller: c,
          autofocus: true,
          minLines: 2,
          maxLines: 5,
          style: const TextStyle(fontSize: 13.5),
          decoration: const InputDecoration(
            hintText: 'What should change? (sent back to the AI)',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(d),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Aether.accent),
            onPressed: () => Navigator.pop(d, c.text),
            child: const Text('Send'),
          ),
        ],
      ),
    );
    if (note == null) return;
    AgentService.I.approve(false, note: note);
  }

  @override
  Widget build(BuildContext context) {
    // planBody is the raw plan captured when the request was raised — no
    // fragile re-parsing of the framing prose out of `detail`.
    final plan = req.planBody ?? req.detail;

    return Container(
      margin: const EdgeInsets.fromLTRB(12, 0, 12, 6),
      decoration: BoxDecoration(
        color: Aether.accent.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Aether.accent.withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header strip.
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 0),
            child: Row(
              children: [
                _StateDot(Aether.accent),
                const SizedBox(width: 7),
                Text(
                  'Plan review',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: Aether.text,
                  ),
                ),
              ],
            ),
          ),
          // The plan body (markdown).
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 260),
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(12, 6, 12, 6),
              child: _DshMarkdown(content: plan),
            ),
          ),
          const SizedBox(height: 4),
          // Decision row: Chat about it · Decline · Approve.
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  style: TextButton.styleFrom(
                    foregroundColor: Aether.textMuted,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 8,
                    ),
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  onPressed: () => _chatAboutIt(context),
                  child: const Text(
                    'Chat about it',
                    style: TextStyle(fontSize: 12),
                  ),
                ),
                const SizedBox(width: 6),
                OutlinedButton(
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Aether.dangerC,
                    side: BorderSide(
                      color: Aether.dangerC.withValues(alpha: 0.5),
                    ),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 8,
                    ),
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  onPressed: () => AgentService.I.approve(false),
                  child: const Text('Decline', style: TextStyle(fontSize: 12)),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: Aether.accent,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 8,
                    ),
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  onPressed: () => AgentService.I.approve(true),
                  child: const Text('Approve', style: TextStyle(fontSize: 12)),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Structured Q&A card for ask_user_question — Gemini-web style with
/// tappable option chips per question and a submit button.
class _QuestionsCard extends StatefulWidget {
  final ApprovalRequest req;
  const _QuestionsCard(this.req);

  @override
  State<_QuestionsCard> createState() => _QuestionsCardState();
}

class _QuestionsCardState extends State<_QuestionsCard> {
  /// question id → selected option labels (multi → Set, single → 1 elem)
  final Map<String, Set<String>> _selected = {};

  /// question id → free-text "own answer" (overrides chips when non-empty)
  final Map<String, TextEditingController> _custom = {};

  @override
  void dispose() {
    for (final c in _custom.values) {
      c.dispose();
    }
    super.dispose();
  }

  TextEditingController _controllerFor(String id) =>
      _custom.putIfAbsent(id, TextEditingController.new);

  String? _answerFor(UserQuestion q) {
    final custom = _custom[q.id]?.text.trim();
    if (custom != null && custom.isNotEmpty) return custom;
    final sel = _selected[q.id];
    if (sel == null || sel.isEmpty) return null;
    return sel.join(', ');
  }

  bool get _allAnswered {
    for (final q in widget.req.questions!) {
      if (_answerFor(q) == null) return false;
    }
    return true;
  }

  @override
  Widget build(BuildContext context) {
    final qs = widget.req.questions!;
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 0, 12, 6),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Aether.accent.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Aether.accent.withValues(alpha: 0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          const Row(
            children: [
              Icon(Icons.help_outline, size: 14, color: Aether.accent),
              SizedBox(width: 6),
              Text(
                'Questions from the AI',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: Aether.accent,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          for (final q in qs) ...[
            if (q.header != null)
              Padding(
                padding: const EdgeInsets.only(top: 6, bottom: 2),
                child: Text(
                  q.header!,
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w600,
                    color: Aether.textFaint,
                  ),
                ),
              ),
            Text(
              q.question,
              style: TextStyle(fontSize: 13, color: Aether.text),
            ),
            if (q.options.isNotEmpty) ...[
              const SizedBox(height: 6),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [for (final opt in q.options) _optionChip(q, opt)],
              ),
            ],
            // Free-form "own answer" — for answers the chips don't cover.
            const SizedBox(height: 6),
            _ownAnswerField(q),
            const SizedBox(height: 8),
          ],
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                style: TextButton.styleFrom(
                  foregroundColor: Aether.danger,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  minimumSize: Size.zero,
                ),
                child: const Text('Skip', style: TextStyle(fontSize: 12)),
                onPressed: () => AgentService.I.approve(false),
              ),
              const SizedBox(width: 4),
              FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: Aether.accent,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 6,
                  ),
                  minimumSize: Size.zero,
                ),
                onPressed: _allAnswered
                    ? () {
                        for (final q in widget.req.questions!) {
                          final a = _answerFor(q);
                          if (a != null) widget.req.answers[q.id] = a;
                        }
                        AgentService.I.approve(true);
                      }
                    : null,
                child: const Text('Answer', style: TextStyle(fontSize: 12)),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// Free-text field for a question ("your own answer"). Typing here
  /// overrides any selected chip — the user isn't limited to the AI's
  /// preset options.
  Widget _ownAnswerField(UserQuestion q) {
    return TextField(
      controller: _controllerFor(q.id),
      style: TextStyle(fontSize: 12.5, color: Aether.text),
      onChanged: (t) {
        // Typing an own answer overrides chip selection for this question.
        if (t.trim().isNotEmpty) _selected[q.id]?.clear();
        setState(() {});
      },
      decoration: InputDecoration(
        isDense: true,
        hintText: 'Or type your own answer…',
        hintStyle: TextStyle(fontSize: 11.5, color: Aether.textFaint),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 10,
          vertical: 7,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: Aether.hairline),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: Aether.accent),
        ),
      ),
    );
  }

  Widget _optionChip(UserQuestion q, QuestionOption opt) {
    final sel = _selected.putIfAbsent(q.id, () => {});
    final isSel = sel.contains(opt.label);
    return GestureDetector(
      onTap: () {
        setState(() {
          if (q.multi) {
            if (isSel) {
              sel.remove(opt.label);
            } else {
              sel.add(opt.label);
            }
          } else {
            sel
              ..clear()
              ..add(opt.label);
          }
        });
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: isSel
              ? Aether.accent.withValues(alpha: 0.2)
              : Aether.surfaceRaised,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: isSel ? Aether.accent : Aether.hairline),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              opt.label,
              style: TextStyle(
                fontSize: 11,
                fontWeight: isSel ? FontWeight.w600 : FontWeight.normal,
                color: isSel ? Aether.accent : Aether.text,
              ),
            ),
            if (opt.description != null)
              Text(
                opt.description!,
                style: TextStyle(fontSize: 9, color: Aether.textFaint),
              ),
          ],
        ),
      ),
    );
  }
}

/// Permission mode chip (Read-Only / General / Full Access / Studio) —
/// DSH-web dropdown under the input. Tapping cycles; long-press opens sheet.
/// DSH-web workspace chip — shows the active workspace (repo name, or
/// "sandbox" when working in the local sandbox).  Tapping opens Studio.
class _WorkspaceChip extends StatelessWidget {
  const _WorkspaceChip();

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: AppState.I,
      builder: (_, _) {
        final s = AppState.I.activeSession;
        String label = 'sandbox';
        var isFolder = false;
        if (s != null) {
          final folder = s.workspaceFolder;
          if (folder != null && folder.isNotEmpty) {
            label = folder.split('/').last;
            isFolder = true;
          } else {
            final repo = AppState.I.getRepoForSession(s.id);
            if (repo != null && repo.contains('/')) {
              label = repo.split('/').last;
            } else if (repo != null && repo.isNotEmpty) {
              label = repo;
            }
          }
        }
        return GestureDetector(
          onTap: () {
            if (isFolder) {
              _showFolderSheet(context);
            } else {
              openStudio(context);
            }
          },
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: isFolder
                    ? Aether.accent.withValues(alpha: 0.5)
                    : Aether.hairline,
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  isFolder
                      ? Icons.folder_special_outlined
                      : Icons.folder_outlined,
                  size: 14,
                  color: isFolder ? Aether.accent : Aether.textMuted,
                ),
                const SizedBox(width: 6),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 90),
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                      height: 20 / 13,
                      color: isFolder ? Aether.accent : Aether.textMuted,
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  void _showFolderSheet(BuildContext context) {
    final s = AppState.I.activeSession;
    if (s == null) return;
    showModalBottomSheet(
      context: context,
      backgroundColor: Aether.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 12),
            const Text(
              'Working folder',
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 6),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Text(
                s.workspaceFolder ?? '',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 11.5, color: Aether.textFaint),
              ),
            ),
            const SizedBox(height: 6),
            ListTile(
              dense: true,
              leading: const Icon(Icons.drive_file_move_outline, size: 18),
              title: const Text('Change folder', style: TextStyle(fontSize: 13.5)),
              onTap: () {
                Navigator.pop(context);
                // The old flow cleared the pinned folder BEFORE opening the
                // picker, so cancelling the picker silently dropped it.
                // _pickFolderDirect only writes on success.
                _pickFolderDirect(context);
              },
            ),
            ListTile(
              dense: true,
              leading: const Icon(Icons.clear_all_outlined, size: 18),
              title: const Text('Clear folder (sandbox)', style: TextStyle(fontSize: 13.5)),
              onTap: () {
                AppState.I.setSessionWorkspaceFolder(null);
                Navigator.pop(context);
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('Working folder cleared — back to sandbox.'),
                    behavior: SnackBarBehavior.floating,
                  ),
                );
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Future<void> _pickFolderDirect(BuildContext context) async {
    String? path;
    try {
      path = await FilePicker.platform.getDirectoryPath(
        dialogTitle: 'Pick working folder',
      );
    } catch (_) {
      path = null;
    }
    if (path == null) return;
    final dir = Directory(path);
    if (!dir.existsSync()) return;
    var writable = false;
    try {
      final probe = File('$path/.ovid_probe');
      await probe.writeAsString('ok');
      writable = true;
      await probe.delete();
    } catch (_) {}
    if (!writable) {
      final granted = await AgentService.I.requestAllFilesAccess();
      if (!granted) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('That folder is read-only for Ovid.'),
              behavior: SnackBarBehavior.floating,
            ),
          );
        }
        return;
      }
      try {
        final probe = File('$path/.ovid_probe');
        await probe.writeAsString('ok');
        writable = true;
        await probe.delete();
      } catch (_) {
        writable = false;
      }
      if (!writable) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Folder is still read-only — pick a different one.'),
              behavior: SnackBarBehavior.floating,
            ),
          );
        }
        return;
      }
    }
    AppState.I.setSessionWorkspaceFolder(path);
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Working folder: ${path.split('/').last}'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }
}

/// DSH-web plan chip — amber "Plan" indicator in the composer, visible only
/// while plan mode is on for the active session. Tap exits plan mode.
class _PlanChip extends StatelessWidget {
  const _PlanChip();

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: AppState.I,
      builder: (_, _) {
        final s = AppState.I.activeSession;
        final on = s?.planMode ?? false;
        if (!on) return const SizedBox.shrink();
        return GestureDetector(
          onTap: () {
            AgentService.I.planMode = false;
          },
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
            decoration: BoxDecoration(
              color: Aether.warn.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: Aether.warn.withValues(alpha: 0.45)),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.architecture, size: 14, color: Aether.warn),
                const SizedBox(width: 6),
                Text(
                  'Plan',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                    height: 20 / 13,
                    color: Aether.warn,
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _ModeChip extends StatelessWidget {
  const _ModeChip();

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: AgentService.I,
      builder: (_, _) {
        final m = AgentService.I.mode;
        return GestureDetector(
          onTap: () => _showModeSheet(context),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
            decoration: BoxDecoration(
              color: m.color.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: m.color.withValues(alpha: 0.45)),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(m.icon, size: 14, color: m.color),
                const SizedBox(width: 6),
                Text(
                  m.label,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                    height: 20 / 13,
                    color: m.color,
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  void _showModeSheet(BuildContext context) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Aether.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 12),
            const Text(
              'Agent access mode',
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 6),
            for (final m in AgentMode.values)
              ListTile(
                dense: true,
                leading: Icon(m.icon, size: 18, color: m.color),
                title: Text(m.label, style: const TextStyle(fontSize: 13.5)),
                subtitle: Text(
                  m.hint,
                  style: TextStyle(
                    fontSize: 11,
                    color: Aether.textFaint,
                    height: 1.4,
                  ),
                ),
                trailing: AgentService.I.mode == m
                    ? const Icon(Icons.check, size: 18, color: Aether.accent)
                    : null,
                onTap: () {
                  AgentService.I.setMode(m);
                  Navigator.pop(context);
                },
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}

/// ═══════════════ DSH-web style markdown renderer ═══════════════
/// Fenced code blocks → copyable boxes with lang label + copy btn.
/// Diff lines (+/-) inside code get green/red gutter coloring.
class _DshMarkdown extends StatelessWidget {
  final String content;

  /// Body text size / colour. Answers use the defaults; apparatus surfaces
  /// (reasoning, tool detail) pass a smaller, dimmer pair so they read as
  /// secondary.
  final double fontSize;
  final Color? color;
  const _DshMarkdown({required this.content, this.fontSize = 14, this.color});

  static final _fenceRe = RegExp(r'```(\w*)\n([\s\S]*?)```', multiLine: true);

  @override
  Widget build(BuildContext context) {
    final parts = <Widget>[];
    var last = 0;
    for (final match in _fenceRe.allMatches(content)) {
      if (match.start > last) {
        parts.add(_prose(context, content.substring(last, match.start)));
      }
      parts.add(
        _DshCodeBox(
          lang: match.group(1)?.isEmpty ?? true ? 'code' : match.group(1)!,
          code: match.group(2) ?? '',
        ),
      );
      last = match.end;
    }
    if (last < content.length) {
      parts.add(_prose(context, content.substring(last)));
    }
    if (parts.isEmpty) parts.add(_prose(context, content));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final w in parts)
          Padding(padding: const EdgeInsets.only(bottom: 6), child: w),
      ],
    );
  }

  Widget _prose(BuildContext context, String text) {
    if (text.trim().isEmpty) return const SizedBox.shrink();
    final body = color ?? Aether.text;
    return MarkdownBody(
      data: text,
      // Prose is selectable (long-press to select/copy) and links open in the
      // in-app browser, matching a real chat surface.
      selectable: true,
      onTapLink: (text, href, title) => _openLink(context, text, href, title),
      builders: {'code': _DshInlineCodeBuilder()},
      styleSheet: MarkdownStyleSheet(
        p: TextStyle(fontSize: fontSize, height: 1.55, color: body),
        h1: TextStyle(
          fontSize: fontSize + 5,
          fontWeight: FontWeight.w700,
          color: body,
        ),
        h2: TextStyle(
          fontSize: fontSize + 3,
          fontWeight: FontWeight.w700,
          color: body,
        ),
        h3: TextStyle(
          fontSize: fontSize + 1.5,
          fontWeight: FontWeight.w600,
          color: body,
        ),
        strong: TextStyle(fontWeight: FontWeight.w600, color: body),
        em: TextStyle(fontStyle: FontStyle.italic, color: body),
        code: TextStyle(
          fontFamily: Aether.mono,
          fontSize: fontSize - 1.5,
          backgroundColor: Colors.transparent,
          color: Aether.accent,
        ),
        listBullet: TextStyle(fontSize: fontSize, height: 1.5, color: body),
        listIndent: 18,
        blockquoteDecoration: BoxDecoration(
          border: Border(
            left: BorderSide(color: Aether.hairlineStrong, width: 3),
          ),
        ),
        blockquotePadding: const EdgeInsets.only(left: 10),
        // Wide tables used to be squeezed into the viewport and clipped.
        // IntrinsicColumnWidth makes the renderer wrap the table in a
        // horizontal scroller, so columns keep their natural width.
        tableColumnWidth: const IntrinsicColumnWidth(),
        tableCellsPadding: const EdgeInsets.symmetric(
          horizontal: 10,
          vertical: 6,
        ),
        tableBorder: TableBorder.all(color: Aether.hairline, width: 1),
        tableHead: TextStyle(
          fontSize: fontSize - 1,
          fontWeight: FontWeight.w700,
          color: body,
        ),
        tableBody: TextStyle(
          fontSize: fontSize - 1,
          height: 1.4,
          color: body,
        ),
        a: const TextStyle(
          color: Aether.accent,
          decoration: TextDecoration.underline,
        ),
      ),
    );
  }
}

/// Open a markdown link: http(s) in the in-app browser (so the agent and the
/// user share one browsing surface), everything else (mailto:, tel:, custom
/// schemes) through the platform handler. External launches that nothing can
/// handle fall back to the in-app browser so the tap never dies silently.
Future<void> _openLink(
  BuildContext context,
  String text,
  String? href,
  String title,
) async {
  var raw = href?.trim();
  if (raw == null || raw.isEmpty) {
    // Bare-domain text ("example.com", "www.x.dev/y") — open it too.
    final t = text.trim();
    if (t.isEmpty) return;
    final domainLike = RegExp(
      r'^(www\.)?[\w-]+(\.[\w-]+)+(/.*)?$',
    ).firstMatch(t);
    if (domainLike == null) return;
    raw = t.startsWith('www.') ? 'https://$t' : 'https://$t';
  }
  var uri = Uri.tryParse(raw);
  // Schemeless hrefs ("example.com/a") are relative in markdown terms, but
  // browsers expect a scheme — normalize before deciding anything.
  if (uri != null && uri.scheme.isEmpty && uri.host.isNotEmpty) {
    uri = Uri.tryParse('https://$raw');
  }
  if (uri == null) return;
  final messenger = ScaffoldMessenger.of(context);
  void fallback() => launchUrl(uri!, mode: LaunchMode.externalApplication);
  if (uri.scheme == 'http' || uri.scheme == 'https') {
    await BrowserScreen.open(context, url: uri.toString());
    return;
  }
  try {
    final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!ok) {
      // No handler (missing <queries> entry / app not installed) — tell the
      // user instead of swallowing the failure.
      messenger.showSnackBar(
        SnackBar(
          content: Text('No app can open ${uri.scheme} links.'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  } catch (_) {
    try {
      fallback();
    } catch (_) {
      messenger.showSnackBar(
        const SnackBar(
          content: Text('Could not open this link.'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }
}

/// Copyable fenced code box with lang label, copy, and diff coloring.
class _DshCodeBox extends StatelessWidget {
  final String lang;
  final String code;
  const _DshCodeBox({required this.lang, required this.code});

  bool get _isDiff =>
      lang == 'diff' ||
      code
          .split('\n')
          .take(8)
          .any((l) => l.startsWith('+') || l.startsWith('-'));

  @override
  Widget build(BuildContext context) {
    return Container(
      clipBehavior: Clip.antiAlias,
      margin: const EdgeInsets.symmetric(vertical: 4),
      decoration: BoxDecoration(
        color: Aether.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Aether.hairline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
            color: Aether.surfaceAlt,
            child: Row(
              children: [
                Icon(
                  _isDiff ? Icons.difference : Icons.code,
                  size: 13,
                  color: Aether.textFaint,
                ),
                const SizedBox(width: 7),
                Text(
                  lang,
                  style: TextStyle(
                    fontSize: 11,
                    fontFamily: Aether.mono,
                    color: Aether.textMuted,
                  ),
                ),
                const Spacer(),
                _CopyButton(code: code),
              ],
            ),
          ),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: _isDiff
                ? _DiffLines(code: code)
                : Text(
                    code,
                    style: TextStyle(
                      fontFamily: Aether.mono,
                      fontSize: 12,
                      height: 1.55,
                      color: Aether.text,
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

/// Diff renderer: +/- lines green/red like DSH-web edits.
class _DiffLines extends StatelessWidget {
  final String code;
  const _DiffLines({required this.code});

  @override
  Widget build(BuildContext context) {
    final lines = code.split('\n');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final l in lines)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1.5),
            color: l.startsWith('+')
                ? Aether.success.withValues(alpha: 0.10)
                : l.startsWith('-')
                ? Aether.danger.withValues(alpha: 0.10)
                : Colors.transparent,
            child: Text(
              l,
              style: TextStyle(
                fontFamily: Aether.mono,
                fontSize: 12,
                height: 1.5,
                color: l.startsWith('+')
                    ? Aether.success
                    : l.startsWith('-')
                    ? Aether.danger
                    : Aether.textMuted,
              ),
            ),
          ),
      ],
    );
  }
}

/// Inline `code` — mono, accent-colored chip.
class _DshInlineCodeBuilder extends MarkdownElementBuilder {
  @override
  Widget? visitElementAfterWithContext(
    BuildContext context,
    md.Element element,
    TextStyle? preferredStyle,
    TextStyle? parentStyle,
  ) {
    final text =
        element.children?.map((c) => c.textContent).join() ??
        element.textContent;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
      decoration: BoxDecoration(
        color: Aether.surfaceAlt,
        borderRadius: BorderRadius.circular(5),
        border: Border.all(color: Aether.hairline),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontFamily: Aether.mono,
          fontSize: 12,
          color: Aether.text,
        ),
      ),
    );
  }
}
