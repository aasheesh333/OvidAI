import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:url_launcher/url_launcher.dart';

import '../core/theme.dart';
import '../core/format.dart';
import '../core/voice_input_service.dart';
import '../core/state.dart';
import '../core/studio_setup_coordinator.dart';
import '../core/native_share.dart';
import 'share_actions.dart';
import 'sandbox_setup.dart';
import 'browser_screen.dart';
import 'sidebar.dart';
import 'settings_screen.dart';
import 'subagent_screen.dart';
import 'transcript_model.dart';
import 'chat_layout.dart';
import 'html_artifact_view.dart';
import '../core/agent_service.dart';
import '../core/commands.dart';
import '../core/device_control_service.dart';
import '../core/mcp_service.dart';
import '../core/plugin_registry.dart';
import '../core/presets.dart';
import '../core/skills.dart';
import '../core/startup_coordinator.dart';
import 'plugins_screen.dart';
import 'startup_progress_panel.dart';
import '../core/diag.dart';
import '../core/ovid_cloud_service.dart';
import 'widgets/aether_primitives.dart';

/// Chat screen — Gemini/DeepSeek grade: reasoning chips, code blocks,
/// in-chat image generation card, model picker, utility input bar.
/// turn-process folding: consecutive assistant tool/reasoning
/// messages collapse into a single expandable strip ("N tool calls ·
/// Thought for a while") that sits right before the final answer.
/// The LAST tool/reasoning run (no text after it yet, or the last tool
/// in a run still in progress) stays unfolded — same as Compact.
/// Read/write transcript for ONE session — the same rendering the main chat
/// uses (folded tool/reasoning strips, streaming bubbles, tool cards).
///
/// The subagent view renders a child session with this, so a subagent's work
/// is shown in full instead of being summarised into one line.
///
/// The subagent transcript uses the same bounded window as the main chat with
/// a larger page, so a long child run is not re-folded in full on every
/// rebuild.
const int _subagentTranscriptPage = 200;

/// Keep the platform's nonlinear accessibility curve, then apply chat zoom.
class _ChatTextScaler extends TextScaler {
  final TextScaler inherited;
  final double zoom;
  const _ChatTextScaler(this.inherited, this.zoom);

  @override
  double scale(double fontSize) => inherited.scale(fontSize) * zoom;

  @override
  double get textScaleFactor => scale(14) / 14;
}

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
        final layout = ChatLayout(
          viewportWidth: MediaQuery.of(context).size.width,
        );
        final window = windowForBounded(
          session.messages,
          pageSize: _subagentTranscriptPage,
          visibleCount: 0,
          showReasoning: AppState.I.showReasoning,
        );
        final items = window.visible;
        // The subagent transcript is bounded; when older rows are omitted,
        // say so instead of silently truncating the child's history.
        final showOlder = window.hasEarlier;
        final count = items.length + (showOlder ? 1 : 0) + (typing ? 1 : 0);
        final list = ListView.builder(
          controller: scrollController,
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
          itemCount: count,
          itemBuilder: (_, i) {
            if (showOlder && i == 0) return const _OlderMessagesIndicator();
            final li = showOlder ? i - 1 : i;
            if (li == items.length) return const _TypingBubble();
            return _buildItem(
              items[li],
              session,
              onAction: () {},
              input: null,
              layout: layout,
            );
          },
        );
        return MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: _ChatTextScaler(
              MediaQuery.textScalerOf(context),
              AppState.I.chatFontScale,
            ),
          ),
          child: Center(
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: layout.contentWidth),
              child: list,
            ),
          ),
        );
      },
    );
  }
}

/// `row-in` / `wide-in` entrance — fade + 8px slide-up, plays ONCE
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

/// `ovid-state-dot-chase` — three pulsing dots used on running tool and
/// reasoning rows. Opacity steps 1 → .6 → .35 → .15 over 1s, staggered so
/// the highlight appears to chase across the dots (matches the reference).
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
    duration: const Duration(milliseconds: 1000),
  )..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  // 4-step opacity ladder from the reference keyframes.
  static const _levels = [1.0, 0.6, 0.35, 0.15];

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 16,
      height: 16,
      child: AnimatedBuilder(
        animation: _c,
        builder: (_, _) {
          return Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              for (var i = 0; i < 3; i++) ...[
                if (i > 0) const SizedBox(width: 2),
                _dot(_levels[(_c.value * 4 + i).floor() % 4]),
              ],
            ],
          );
        },
      ),
    );
  }

  Widget _dot(double op) => Container(
    width: 3.5,
    height: 3.5,
    decoration: BoxDecoration(
      color: widget.color.withValues(alpha: op),
      shape: BoxShape.circle,
    ),
  );
}

/// `ovid-turn-status-shimmer` — a blue gradient sweeps across the status
/// text (base accent with a light highlight), matching the reference's
/// 1.8s linear infinite shimmer.
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
    duration: const Duration(milliseconds: 1800),
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
      builder: (_, child) {
        // A 250%-wide gradient swept right→left over 1.8s.
        final shift = 1.0 - _c.value * 2.5;
        return ShaderMask(
          blendMode: BlendMode.srcIn,
          shaderCallback: (bounds) => LinearGradient(
            begin: Alignment(shift, 0),
            end: Alignment(shift + 1.0, 0),
            colors: const [
              Color(0xFF4176E6),
              Color(0xFF4176E6),
              Color(0xFFD3E2FF),
              Color(0xFF4176E6),
              Color(0xFF4176E6),
            ],
            stops: const [0.0, 0.4, 0.5, 0.6, 1.0],
          ).createShader(bounds),
          child: child,
        );
      },
      child: Text(
        widget.text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: widget.style,
      ),
    );
  }
}

Widget _buildItem(
  ChatItem item,
  dynamic s, {
  required VoidCallback onAction,
  required TextEditingController? input,
  required ChatLayout layout,
}) {
  if (item is SingleItem) {
    return _RowIn(
      child: _MessageView(
        m: item.m,
        session: s,
        msgIndex: item.index,
        onAction: onAction,
        input: input,
        layout: layout,
      ),
    );
  }
  final g = item as FoldedGroup;
  return _RowIn(child: _TurnProcessStrip(group: g.msgs));
}

/// StatsLine parity — pipe-separated line docked above the composer:
/// "3 turns · LLM 12.4s · Input 8.2K tok · Output 1.4K tok".  Hidden
/// when the session has no usage yet (empty-state stays clean).
class _StatsLine extends StatelessWidget {
  const _StatsLine();

  String _fmtTok(int t) => formatCompactCount(t);
  String _fmtCost(double usd) => usd >= 1
      ? '\$${usd.toStringAsFixed(2)}'
      : '\$${usd.toStringAsFixed(usd >= 0.01 ? 3 : 4)}';

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([AppState.I, AgentService.I]),
      builder: (_, _) {
        final s = AppState.I.activeSession;
        if (s == null) return const SizedBox.shrink();
        final analytics = s.analytics;
        // footer ring — % of THIS model's context window in use,
        // measured from the last billed promptTokens (exact) or the
        // chars/4 heuristic fallback.
        final window = AgentService.contextWindowForSession(s);
        final used = analytics.contextTokens > 0
            ? analytics.contextTokens
            : AgentService.I.measuredContextTokens(s);
        final frac = (used / window).clamp(0.0, 1.0);
        final pct = frac * 100;
        if (analytics.turns == 0 && used == 0) return const SizedBox.shrink();
        final ringColor = frac >= 0.8
            ? Aether.dangerC
            : frac >= 0.55
            ? Aether.warnLight
            : Aether.successLight;
        return GestureDetector(
          onTap: () => _showSessionAnalytics(context, s),
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(16, 3, 16, 3),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Flexible(
                  child: Text(
                    [
                      '${analytics.turns} turn${analytics.turns == 1 ? '' : 's'}',
                      if (analytics.llmMs > 0)
                        'LLM ${formatCompactDuration(Duration(milliseconds: analytics.llmMs))}',
                      'Input ${_fmtTok(analytics.inputTokens)} tok · Output ${_fmtTok(analytics.outputTokens)} tok',
                      if (analytics.decodeTokensPerSecond > 0)
                        '${analytics.decodeTokensPerSecond.toStringAsFixed(1)} tok/s',
                      if (analytics.cacheReadTokens > 0)
                        'cache ${_fmtTok(analytics.cacheReadTokens)} tok',
                      if (analytics.averageTtftMs > 0)
                        'ttft ~${analytics.averageTtftMs} ms',
                      if (analytics.estimatedCostUsd > 0)
                        '≈ ${_fmtCost(analytics.estimatedCostUsd)}',
                      if (s.compactedSummary != null) 'compacted',
                    ].join('  |  '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 10.5, color: Aether.textFaint),
                  ),
                ),
                const SizedBox(width: 8),
                // Context ring — 12px arc + % label (the context indicator "% of context used").
                // Tap → full context meter sheet (segmented breakdown).
                Tooltip(
                  message:
                      '${pct.toStringAsFixed(0)}% of ${_fmtTok(window)} context used · '
                      'session input ${_fmtTok(analytics.inputTokens)} · '
                      'session output ${_fmtTok(analytics.outputTokens)} · '
                      'tap for details',
                  child: GestureDetector(
                    onTap: () =>
                        _showContextMeter(context, window: window, used: used),
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
          ),
        );
      },
    );
  }

  void _showSessionAnalytics(BuildContext context, ChatSession session) {
    final a = session.analytics;
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
              Text(
                'Session analytics',
                style: TextStyle(
                  color: Aether.text,
                  fontSize: 17,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                '${session.title} · ${ovidModelLabel(session.model)}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: Aether.textMuted, fontSize: 11),
              ),
              const SizedBox(height: 16),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [
                  _analyticsMetric('Input', '${_fmtTok(a.inputTokens)} tok'),
                  _analyticsMetric('Output', '${_fmtTok(a.outputTokens)} tok'),
                  _analyticsMetric(
                    'Context',
                    '${_fmtTok(a.contextTokens)} / ${_fmtTok(a.contextLimit)}',
                  ),
                  _analyticsMetric('Turns', '${a.turns}'),
                  _analyticsMetric(
                    'Tools',
                    '${a.toolCalls} · ${formatCompactDuration(Duration(milliseconds: a.toolMs))}',
                  ),
                  _analyticsMetric(
                    'TTFT',
                    a.averageTtftMs == 0 ? '—' : '${a.averageTtftMs} ms',
                  ),
                  _analyticsMetric(
                    'Decode',
                    a.decodeTokensPerSecond == 0
                        ? '—'
                        : '${a.decodeTokensPerSecond.toStringAsFixed(1)} tok/s',
                  ),
                  _analyticsMetric(
                    'Est. cost',
                    a.estimatedCostUsd == 0
                        ? '—'
                        : _fmtCost(a.estimatedCostUsd),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Text(
                'Cost is an approximate public list-price estimate. Custom or unknown models show no invented price.',
                style: TextStyle(color: Aether.textFaint, fontSize: 10.5),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _analyticsMetric(String label, String value) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
    decoration: BoxDecoration(
      color: Aether.surfaceAlt,
      borderRadius: BorderRadius.circular(9),
      border: Border.all(color: Aether.hairline),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: TextStyle(color: Aether.textFaint, fontSize: 10)),
        const SizedBox(height: 2),
        Text(
          value,
          style: TextStyle(
            color: Aether.text,
            fontSize: 12,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    ),
  );

  /// Context meter sheet (the context breakdown sheet parity): window usage,
  /// segmented sys/tools/messages bars with a cache-read overlay and a
  /// compaction hint.
  void _showContextMeter(
    BuildContext context, {
    required int window,
    required int used,
  }) {
    final agent = AgentService.I;
    final analytics = AppState.I.activeSession?.analytics;
    final sys = analytics?.contextSystemTokens ?? agent.sessionSystemTokens;
    final tool = analytics?.contextToolTokens ?? agent.sessionToolTokens;
    final msgs = analytics?.contextMessageTokens ?? agent.sessionMessageTokens;
    final cache = analytics?.cacheReadTokens ?? agent.sessionCacheReadTokens;
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
                          ? Aether.warnLight
                          : Aether.successLight,
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
                color: Aether.warnLight,
              ),
              const SizedBox(height: 10),
              _MeterBreakdownBar(
                label: 'Messages',
                value: msgs,
                total: window,
                color: Aether.successLight,
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
          formatCompactCount(value),
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

/// turn-process strip — "N tool calls · Thought for a while" with a
/// chevron; expands to show every folded tool card + reasoning card.
/// Default collapsed (the process strip Compact mode).
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
        // presentation: "{count} subagents (running)".
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
  String? _draftBindScheduledFor;

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
      animation: Listenable.merge([app, AgentService.I]),
      builder: (_, _) {
        final s = app.activeSession;
        // Restore the draft that belongs to THIS session — never leak
        // another session's composer text.
        if (s != null &&
            _boundSessionId != s.id &&
            _draftBindScheduledFor != s.id) {
          _draftBindScheduledFor = s.id;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (_draftBindScheduledFor == s.id) {
              _draftBindScheduledFor = null;
            }
            _bindDraft(s.id);
          });
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
                final dockColumn = Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const _ApprovalDock(),
                    const _GoalBar(),
                    const _TodoDock(),
                    const _StatsLine(),
                    _QueueDock(
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
                    ),
                  ],
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
                      child: LayoutBuilder(
                        builder: (context, chatConstraints) => Column(
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
                                            _pinchStartScale =
                                                app.chatFontScale;
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
                                            data: MediaQuery.of(context)
                                                .copyWith(
                                                  textScaler: _ChatTextScaler(
                                                    MediaQuery.textScalerOf(
                                                      context,
                                                    ),
                                                    app.chatFontScale,
                                                  ),
                                                ),
                                            child: AnimatedBuilder(
                                              animation: AgentService.I,
                                              builder: (_, _) {
                                                final typing = AgentService.I
                                                    .busyFor(s.id);
                                                // Bounded, cached fold (Task 4): the
                                                // folded window is reused across streaming
                                                // tokens; only the message count / last
                                                // message identity / showReasoning / pager
                                                // window can invalidate it.
                                                final window =
                                                    _transcriptWindow(s);
                                                _hasEarlier = window.hasEarlier;
                                                final hiddenMessages =
                                                    window.hiddenMessages;
                                                final items = window.visible;
                                                // "Produced" card — files written by
                                                // this run surface as a card under the
                                                // final answer (tap → Studio).
                                                final produced = AgentService
                                                    .I
                                                    .producedFiles;
                                                final showProduced =
                                                    !typing &&
                                                    produced.isNotEmpty;
                                                // System-prompt disclosure (context
                                                // visibility): only at the top of the
                                                // loaded window so it never shifts the
                                                // paging row.
                                                // SECURITY: the system prompt snapshot
                                                // contains internal agent instructions
                                                // and must never be shown to the user.
                                                final count =
                                                    (hiddenMessages > 0
                                                        ? 1
                                                        : 0) +
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
                                                  padding:
                                                      const EdgeInsets.fromLTRB(
                                                        16,
                                                        8,
                                                        16,
                                                        16,
                                                      ),
                                                   itemCount: count,
                                                   itemBuilder: (_, i) {
                                                     final rowKey = ValueKey(
                                                       _rowKeys[i],
                                                     );
                                                     var idx = i;
                                                    // System prompt row removed —
                                                    // internal instructions are hidden.

                                                    // Next row: paging affordance. The
                                                    // spinner shows only while a page is
                                                    // actually loading — it used to spin
                                                    // forever in any long thread.
                                                    if (hiddenMessages > 0 &&
                                                        idx == 0) {
                                                       return KeyedSubtree(
                                                         key: rowKey,
                                                         child: Center(
                                                           child: Padding(
                                                             padding:
                                                                 const EdgeInsets.all(
                                                                   8,
                                                                 ),
                                                             child: Row(
                                                               mainAxisSize:
                                                                   MainAxisSize
                                                                       .min,
                                                               children: [
                                                              if (_paging) ...[
                                                                SizedBox(
                                                                  width: 12,
                                                                  height: 12,
                                                                  child: CircularProgressIndicator(
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
                                                                  color: Aether
                                                                      .textFaint,
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
                                                                  color: Aether
                                                                      .textFaint,
                                                                ),
                                                              ),
                                                               ],
                                                             ),
                                                           ),
                                                         ),
                                                       );
                                                    }
                                                    final li =
                                                        hiddenMessages > 0
                                                        ? idx - 1
                                                        : idx;
                                                    if (li == items.length) {
                                                       return KeyedSubtree(
                                                         key: rowKey,
                                                         child: typing
                                                             ? const _TypingBubble()
                                                             : _RowIn(
                                                                 child:
                                                                     _ProducedFilesCard(
                                                                       files:
                                                                           produced,
                                                                     ),
                                                               ),
                                                       );
                                                    }
                                                    final item = items[li];
                                                    // The live tail bubble subscribes to
                                                    // AppState so streaming tokens repaint
                                                    // only this row — the rest of the list
                                                    // stays cached.
                                                    if (typing &&
                                                        li ==
                                                            items.length - 1) {
                                                       return KeyedSubtree(
                                                         key: rowKey,
                                                         child: AnimatedBuilder(
                                                           animation: AppState.I,
                                                           builder: (_, _) =>
                                                               _buildItem(
                                                                 item,
                                                                 s,
                                                                 onAction: () =>
                                                                     setState(
                                                                       () {},
                                                                     ),
                                                                 input: _input,
                                                                 layout: layout,
                                                               ),
                                                         ),
                                                       );
                                                     }
                                                     return KeyedSubtree(
                                                       key: rowKey,
                                                       child: _buildItem(
                                                         item,
                                                         s,
                                                         onAction: () =>
                                                             setState(() {}),
                                                         input: _input,
                                                         layout: layout,
                                                       ),
                                                     );
                                                  },
                                                );
                                                return Center(
                                                  child: ConstrainedBox(
                                                    key: const ValueKey(
                                                      'chat-transcript-column',
                                                    ),
                                                    constraints: BoxConstraints(
                                                      maxWidth:
                                                          layout.contentWidth,
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
                                                borderRadius:
                                                    BorderRadius.circular(20),
                                                child: InkWell(
                                                  borderRadius:
                                                      BorderRadius.circular(20),
                                                  onTap: () {
                                                    _scroll.jumpTo(
                                                      _scroll
                                                          .position
                                                          .maxScrollExtent,
                                                    );
                                                  },
                                                  child: const Padding(
                                                    padding:
                                                        EdgeInsets.symmetric(
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
                                // Natural height for ordinary questions/queues. A
                                // single scroll surface bounds unusually long docks,
                                // using the space left below the startup dashboard.
                                maxHeight: math.min(
                                  480,
                                  chatConstraints.maxHeight *
                                      (AgentService.I.pendingApproval != null
                                          ? 0.45
                                          : 0.30),
                                ),
                              ),
                              child: SingleChildScrollView(
                                // A new request starts at the top, even if the user
                                // previously scrolled through queued work.
                                key: ObjectKey(AgentService.I.pendingApproval),
                                child: Center(
                                  child: ConstrainedBox(
                                    constraints: BoxConstraints(
                                      maxWidth: layout.contentWidth,
                                    ),
                                    // Blocking decisions take priority over passive
                                    // status and queued work in this bounded area.
                                    child:
                                        AgentService.I.pendingApproval != null
                                        ? const _ApprovalDock()
                                        : dockColumn,
                                  ),
                                ),
                              ),
                            ),
                            _InputBar(
                              layout: layout,
                              availableHeight: chatConstraints.maxHeight,
                              controller: _input,
                              focusNode: _inputFocus,
                              sessionId: s?.id,
                              coordinator: widget.startupCoordinator,
                              running: s == null
                                  ? false
                                  : AgentService.I.busyFor(s.id),
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
                                void clearSubmitted() => _clearSubmittedDraft(
                                  s.id,
                                  submitted,
                                  version,
                                );
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
                                  final result = await CommandService.I.execute(
                                    t,
                                  );
                                  if (!mounted || !context.mounted) return;
                                  if (result != null) {
                                    if (result.clearInput &&
                                        result.prompt == null) {
                                      clearSubmitted();
                                    }
                                    // popupSelect (the command picker parity): open the overlay picker.
                                    if (AppState.I.activeSessionId != s.id) {
                                      return;
                                    }
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
                                      ScaffoldMessenger.of(
                                        context,
                                      ).showSnackBar(
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
                                  if (AppState.I.activeSessionId != s.id) {
                                    return;
                                  }
                                  // Skill direct invocation: /skill-name [args].
                                  final parsed = parseSkillInvocation(t);
                                  if (parsed != null) {
                                    final resolved = SkillService.I
                                        .resolveForSession(s.id, parsed.token);
                                    if (resolved.isAmbiguous) {
                                      if (context.mounted) {
                                        ScaffoldMessenger.of(
                                          context,
                                        ).showSnackBar(
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
                                      if (!AgentService.I
                                          .isSkillAvailableForSession(
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
                                    AgentService.I.stopRequested(
                                      sessionId: s.id,
                                    );
                                    // fall through to send
                                  } else {
                                    if (_enqueuePrompt(s, t)) clearSubmitted();
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
                        ),
                      ),
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
            for (final m in modeOptionsForPicker())
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
                onTap: () async {
                  Navigator.pop(context);
                  if (m == AgentMode.control) {
                    await _enableControlMode(context);
                  } else {
                    AgentService.I.setMode(m);
                  }
                },
              ),
            const SizedBox(height: 10),
          ],
        ),
      ),
    );
  }

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

  /// Queue ownership transfers synchronously, but enqueue notifies listeners.
  /// Capture the originating list and paths before that notification: a picker
  /// completion or session switch must not change what this send consumes.
  bool _enqueuePrompt(ChatSession session, String text) {
    final app = AppState.I;
    if (!app.sessionAccountReady ||
        app.activeSessionId != session.id ||
        !identical(app.sessionById(session.id), session)) {
      return false;
    }
    final agent = AgentService.I;
    final pending = agent.pendingAttachments;
    final paths = pending.map((a) => a.path).toSet();
    final previousIds = agent.queuedMessageIdsFor(session.id).toSet();
    agent.enqueueMessage(text, sessionId: session.id);
    // enqueue can reject admission. Never clear a rejected draft.
    if (!agent
        .queuedMessageIdsFor(session.id)
        .any((id) => !previousIds.contains(id))) {
      return false;
    }
    pending.removeWhere((a) => paths.contains(a.path));
    app.refresh();
    return true;
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
      if (_enqueuePrompt(session, t)) onAccepted?.call();
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
    // An ADMITTED run owns the staged files from this tick on: runTask
    // snapshots them onto the submitted row synchronously at admission, so
    // the composer's staging area must hand them over now instead of
    // waiting for the first provider response — a mid-run cancel then keeps
    // them on the message row rather than resurrecting them as new chips.
    if (AgentService.I.busyFor(session.id)) {
      AgentService.I.clearAttachment();
    }
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

  void _modelPicker(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) => Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.viewInsetsOf(sheetContext).bottom,
        ),
        child: DraggableScrollableSheet(
          initialChildSize:
              MediaQuery.viewInsetsOf(sheetContext).bottom > 0 ||
                  MediaQuery.textScalerOf(sheetContext).scale(14) > 20
              ? 0.92
              : 0.5,
          minChildSize:
              MediaQuery.viewInsetsOf(sheetContext).bottom > 0 ||
                  MediaQuery.textScalerOf(sheetContext).scale(14) > 20
              ? 0.6
              : 0.32,
          maxChildSize: 0.92,
          snap: true,
          snapSizes:
              MediaQuery.viewInsetsOf(sheetContext).bottom > 0 ||
                  MediaQuery.textScalerOf(sheetContext).scale(14) > 20
              ? const [0.6, 0.92]
              : const [0.5, 0.92],
          builder: (ctx, scrollController) =>
              _ModelPickerSheet(scrollController: scrollController),
        ),
      ),
    );
  }
}

/// Premium-polish model picker.
///
/// Visual language: an [AetherSheet] with a search [AetherField], one
/// [AetherCard] per provider (header = [AetherType.label] eyebrow), each row
/// an [_ModelTile] showing the model name, a `Manual`/`Auto` [AetherPill],
/// and a check when selected. Empty catalogues get an [AetherEmptyState] with
/// a Settings CTA; empty searches get a distinct message. Unconfigured
/// providers surface in a bottom [AetherCard] notice. Ovid Cloud exposes a
/// retry [AetherGhostButton] that calls [OvidCloudService.ensureConnected]
/// with a sanitized status subtitle.
///
/// All selection behaviour (provider seed, model id, effort variant, recents,
/// Studio/Agent integration) remains intact — the sheet still drives
/// [AppState.setModel] via [_ModelTile].
class _ModelPickerSheet extends StatefulWidget {
  final ScrollController scrollController;
  const _ModelPickerSheet({required this.scrollController});

  @override
  State<_ModelPickerSheet> createState() => _ModelPickerSheetState();
}

class _ModelPickerSheetState extends State<_ModelPickerSheet> {
  final TextEditingController _searchCtrl = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  /// Connection errors are already sanitized by OvidCloudService. Preserve
  /// the full actionable message, including retry instructions.
  String _cloudStatus(CloudConnectionState state) => switch (state.status) {
    CloudConnectionStatus.idle =>
      'Built-in account connection. Retry to connect — no API key needed.',
    CloudConnectionStatus.connecting => 'Connecting your account…',
    CloudConnectionStatus.loadingCatalog => 'Connected. Loading model catalog…',
    CloudConnectionStatus.ready => 'Built-in · Connected',
    CloudConnectionStatus.failed =>
      (state.error == null || state.error!.trim().isEmpty)
          ? 'Ovid Cloud connection failed. Tap Retry.'
          : state.error!,
  };

  bool _matchesQuery(String q, String haystack) =>
      q.isEmpty || haystack.toLowerCase().contains(q);

  @override
  Widget build(BuildContext context) {
    final app = AppState.I;
    return AnimatedBuilder(
      animation: Listenable.merge([app, OvidCloudService.I]),
      builder: (_, _) {
        final q = _query.toLowerCase();
        final cloud = OvidCloudService.I;
        final connection = cloud.connectionFor(app);
        final managed = app.providerById(AppState.ovidCloudProviderId);
        final showCloud =
            managed != null &&
            (q.isEmpty ||
                _matchesQuery(q, managed.name) ||
                (connection.status == CloudConnectionStatus.ready &&
                    managed.models.any((m) => _matchesQuery(q, m))));
        final configured = app.providers
            .where((p) => p.id != AppState.ovidCloudProviderId)
            .where((p) => p.hasKey && p.models.isNotEmpty)
            .where(
              (p) =>
                  _matchesQuery(q, p.name) ||
                  p.models.any((m) => _matchesQuery(q, m)),
            )
            .toList();
        final unconfigured = app.providers
            .where((p) => p.id != AppState.ovidCloudProviderId)
            .where((p) => !p.hasKey && p.models.isNotEmpty)
            .toList();
        final unconfiguredMatchesSearch = unconfigured.any(
          (p) =>
              _matchesQuery(q, p.name) ||
              p.models.any((m) => _matchesQuery(q, m)),
        );

        // Recents (current selection + prior selections), filtered by query &
        // Ovid Cloud readiness.
        final allRecents = <({String providerId, String model})>[];
        final session = app.activeSession;
        if (session != null &&
            session.model.isNotEmpty &&
            session.model != 'Select a provider') {
          final pId = session.providerId;
          if (pId != null && pId.isNotEmpty) {
            allRecents.add((providerId: pId, model: session.model));
          }
        }
        for (final r in app.recentModels) {
          if (!allRecents.any(
            (item) => item.providerId == r.providerId && item.model == r.model,
          )) {
            allRecents.add(r);
          }
        }
        final recents = allRecents.where((r) {
          final p = app.providerById(r.providerId);
          if (p == null) return false;
          if (p.id == AppState.ovidCloudProviderId &&
              (connection.status != CloudConnectionStatus.ready ||
                  !p.models.contains(r.model.split('·').first.trim()))) {
            return false;
          }
          if (q.isEmpty) return true;
          final baseModel = r.model.split('·').first.trim();
          return _matchesQuery(q, baseModel) ||
              _matchesQuery(q, r.model) ||
              _matchesQuery(q, p.name);
        }).toList();

        final noConfiguredAtAll =
            managed == null &&
            app.providers
                .where((p) => p.id != AppState.ovidCloudProviderId)
                .where((p) => p.hasKey && p.models.isNotEmpty)
                .isEmpty;
        final searchMissed =
            q.isNotEmpty &&
            !showCloud &&
            configured.isEmpty &&
            recents.isEmpty &&
            !unconfiguredMatchesSearch;

        // The draggable controller must own the only vertical viewport. A
        // generic sheet's outer scroller can otherwise obscure the last rows
        // of this bounded catalogue behind its header and keyboard inset.
        return Material(
          color: Aether.surface,
          borderRadius: const BorderRadius.vertical(
            top: Radius.circular(AetherRadius.rXl),
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 10, 20, 20),
            child: CustomScrollView(
              key: const ValueKey('model-picker-list'),
              controller: widget.scrollController,
              // Search, notices and provider cards share the sheet's real scroll
              // controller, including empty results. Keep normal lazy caching;
              // search filters the catalogue data before rows are built.
              slivers: [
                SliverToBoxAdapter(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Center(
                        child: Container(
                          width: 36,
                          height: 4,
                          decoration: BoxDecoration(
                            color: Aether.hairlineStrong,
                            borderRadius: BorderRadius.circular(
                              AetherRadius.rPill,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 14),
                      Text('Select model', style: AetherType.h2),
                      const SizedBox(height: 16),
                    ],
                  ),
                ),
                SliverToBoxAdapter(
                  child: AetherField(
                    key: const ValueKey('model-picker-search'),
                    label: 'Search',
                    showLabel: false,
                    hint: 'Search models or providers',
                    controller: _searchCtrl,
                    onChanged: (v) => setState(() => _query = v.trim()),
                    prefixIcon: Icon(
                      Icons.search,
                      size: 18,
                      color: Aether.textFaint,
                    ),
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 12,
                    ),
                  ),
                ),
                const SliverToBoxAdapter(child: SizedBox(height: 12)),
                Builder(
                  builder: (_) {
                    // Branch 1: catalogue is empty and no search entered.
                    if (noConfiguredAtAll && !showCloud && q.isEmpty) {
                      return SliverToBoxAdapter(
                        child: AetherEmptyState(
                          icon: Icons.hub_outlined,
                          title: 'No models configured',
                          message:
                              'Add a provider API key in Settings → Providers '
                              'and tap Fetch models, or connect Ovid Cloud for a '
                              'managed catalogue.',
                          action: AetherPrimaryButton(
                            label: 'Open Settings',
                            icon: Icons.settings_outlined,
                            onPressed: () {
                              Navigator.pop(context);
                              Navigator.of(context).push(
                                MaterialPageRoute(
                                  builder: (_) => const SettingsScreen(),
                                ),
                              );
                            },
                          ),
                        ),
                      );
                    }
                    // Branch 2: query matched absolutely nothing.
                    if (searchMissed) {
                      return SliverToBoxAdapter(
                        child: AetherEmptyState(
                          icon: Icons.search_off_outlined,
                          title: 'No matches',
                          message:
                              'Nothing matches "$_query" in your configured '
                              'providers or models. Try a different search.',
                        ),
                      );
                    }
                    return SliverList.list(
                      children: [
                        if (showCloud)
                          _buildOvidCloudCard(
                            context,
                            app: app,
                            cloud: cloud,
                            connection: connection,
                            managed: managed,
                            q: q,
                          ),
                        if (recents.isNotEmpty) ...[
                          const SizedBox(height: 12),
                          _buildRecentsCard(
                            context,
                            app: app,
                            recents: recents,
                          ),
                        ],
                        for (final p in configured) ...[
                          const SizedBox(height: 12),
                          _buildProviderCard(context, p: p, q: q),
                        ],
                        if (unconfiguredMatchesSearch) ...[
                          const SizedBox(height: 12),
                          _buildUnconfiguredNotice(
                            context,
                            unconfigured
                                .where(
                                  (p) =>
                                      _matchesQuery(q, p.name) ||
                                      p.models.any((m) => _matchesQuery(q, m)),
                                )
                                .toList(),
                          ),
                        ],
                      ],
                    );
                  },
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildOvidCloudCard(
    BuildContext context, {
    required AppState app,
    required OvidCloudService cloud,
    required CloudConnectionState connection,
    required ProviderConfig managed,
    required String q,
  }) {
    final ready = connection.status == CloudConnectionStatus.ready;
    final filtered = managed.models
        .where((m) => _matchesQuery(q, m) || _matchesQuery(q, managed.name))
        .toList();
    final body = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            AetherStatusDot(
              color: switch (connection.status) {
                CloudConnectionStatus.ready => Aether.successLight,
                CloudConnectionStatus.failed => Aether.dangerC,
                CloudConnectionStatus.connecting ||
                CloudConnectionStatus.loadingCatalog => Aether.accent,
                CloudConnectionStatus.idle => Aether.textFaint,
              },
              pulsing: connection.loading,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                _cloudStatus(connection),
                style: AetherType.bodyMuted,
              ),
            ),
          ],
        ),
        if (!ready)
          Align(
            alignment: Alignment.centerLeft,
            child: AetherGhostButton(
              key: const ValueKey('cloud-connection-retry'),
              label: connection.loading ? 'Retrying…' : 'Retry',
              icon: Icons.refresh,
              loading: connection.loading,
              onPressed: connection.loading
                  ? null
                  : () => unawaited(cloud.ensureConnected(app: app)),
            ),
          ),
        if (ready && filtered.isNotEmpty) ...[
          const SizedBox(height: 12),
          Divider(height: 1, thickness: 1, color: Aether.hairline),
          const SizedBox(height: 4),
          for (final model in filtered)
            _ModelTile(providerId: managed.id, model: model),
        ],
      ],
    );
    return AetherCard(
      padding: const EdgeInsets.fromLTRB(16, 14, 12, 10),
      title: Wrap(
        spacing: 8,
        runSpacing: 6,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Text(managed.name, style: AetherType.title),
          const AetherPill(label: 'MANAGED', color: Aether.accent),
        ],
      ),
      child: body,
    );
  }

  Widget _buildRecentsCard(
    BuildContext context, {
    required AppState app,
    required List<({String providerId, String model})> recents,
  }) {
    return AetherCard(
      padding: const EdgeInsets.fromLTRB(16, 14, 12, 8),
      title: Row(children: [Text('Recent', style: AetherType.label)]),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final r in recents)
            _ModelTile(
              providerId: r.providerId,
              model: r.model,
              isRecent: true,
            ),
        ],
      ),
    );
  }

  Widget _buildProviderCard(
    BuildContext context, {
    required ProviderConfig p,
    required String q,
  }) {
    final models = p.models
        .where((m) => _matchesQuery(q, m) || _matchesQuery(q, p.name))
        .toList();
    if (models.isEmpty) return const SizedBox.shrink();
    return AetherCard(
      padding: const EdgeInsets.fromLTRB(16, 14, 12, 8),
      title: Wrap(
        spacing: 6,
        runSpacing: 6,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Text(p.name, style: AetherType.title),
          if (p.isFree) ...[
            AetherPill(label: 'FREE', color: Aether.successLight),
          ],
          const AetherPill(label: 'KEY', color: Aether.accent),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final m in models) _ModelTile(providerId: p.id, model: m),
        ],
      ),
    );
  }

  Widget _buildUnconfiguredNotice(
    BuildContext context,
    List<ProviderConfig> unconfigured,
  ) {
    return AetherCard(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      color: Aether.surfaceAlt,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.key_off, size: 18, color: Aether.textFaint),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('Providers awaiting a key', style: AetherType.label),
                const SizedBox(height: 4),
                Text(
                  '${unconfigured.map((p) => p.name).join(', ')} — add API '
                  'keys in Settings → Providers to use these models.',
                  style: AetherType.caption,
                ),
                const SizedBox(height: 10),
                Align(
                  alignment: Alignment.centerLeft,
                  child: AetherGhostButton(
                    label: 'Open Settings',
                    icon: Icons.settings_outlined,
                    onPressed: () {
                      Navigator.pop(context);
                      Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => const SettingsScreen(),
                        ),
                      );
                    },
                  ),
                ),
              ],
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
  final bool isRecent;
  const _ModelTile({
    required this.providerId,
    required this.model,
    this.isRecent = false,
  });

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
    final baseModel = model.split('·').first.trim();
    final currentBase = current.split('·').first.trim();
    final isExactMatch = current == model;
    final selected =
        session?.providerId == providerId &&
        (isExactMatch || currentBase == baseModel);

    final provider = app.providerById(providerId);
    final providerName = provider?.name ?? providerId;

    // Managed Ovid Cloud `auto` rows show an `Auto` pill — every other row
    // (own-key provider or specific cloud model) is manual selection.
    final isAutoRow =
        providerId == AppState.ovidCloudProviderId &&
        baseModel.toLowerCase() == 'auto';
    final AetherPill modePill = isAutoRow
        ? const AetherPill(label: 'Auto', color: Aether.accent)
        : AetherPill(label: 'Manual', color: Aether.textMuted);

    Widget buildCurrentBadge() {
      return Container(
        margin: const EdgeInsets.only(right: 6),
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          color: Aether.accentSoft,
          borderRadius: BorderRadius.circular(4),
        ),
        child: const Text(
          'CURRENT',
          style: TextStyle(
            fontSize: 9.5,
            fontWeight: FontWeight.w700,
            color: Aether.accent,
          ),
        ),
      );
    }

    Widget modelTitle() {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            ovidModelLabel(baseModel),
            style: const TextStyle(fontSize: 13.5),
          ),
          const SizedBox(height: 4),
          Wrap(
            spacing: 6,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [modePill, if (selected && isRecent) buildCurrentBadge()],
          ),
        ],
      );
    }

    if (!supportsEffort) {
      // Wrap in a transparent Material so splash/hover paints without the
      // DecoratedBox of the enclosing AetherCard hiding it.
      return Material(
        color: Colors.transparent,
        child: ListTile(
          dense: true,
          leading: Icon(
            Icons.smart_toy_outlined,
            size: 18,
            color: selected ? Aether.accent : Aether.textMuted,
          ),
          title: modelTitle(),
          subtitle: isRecent
              ? Text(
                  providerName,
                  style: TextStyle(
                    fontSize: 11,
                    color: selected ? Aether.accent : Aether.textFaint,
                  ),
                )
              : null,
          trailing: selected
              ? const Icon(Icons.check, size: 18, color: Aether.accent)
              : null,
          onTap: () {
            app.setModel(providerId, model);
            Navigator.pop(context);
          },
        ),
      );
    }

    final effortVariant = selected && current.contains('·')
        ? current.split('·').last.trim()
        : (model.contains('·') ? model.split('·').last.trim() : null);

    return Material(
      color: Colors.transparent,
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          dense: true,
          tilePadding: const EdgeInsets.symmetric(horizontal: 16),
          childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
          leading: Icon(
            Icons.psychology_outlined,
            size: 18,
            color: selected ? Aether.accent : Aether.textMuted,
          ),
          title: modelTitle(),
          subtitle: isRecent
              ? Text(
                  effortVariant != null
                      ? '$providerName · $effortVariant'
                      : providerName,
                  style: TextStyle(
                    fontSize: 11,
                    color: selected ? Aether.accent : Aether.textFaint,
                  ),
                )
              : (effortVariant != null
                    ? Text(
                        effortVariant,
                        style: const TextStyle(
                          fontSize: 11,
                          color: Aether.accent,
                        ),
                      )
                    : null),
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
                        (v == 'Medium'
                            ? '$baseModel · Medium'
                            : '$baseModel · $v'),
                    onSelected: (_) {
                      app.setModel(
                        providerId,
                        v == 'Medium'
                            ? '$baseModel · Medium'
                            : '$baseModel · $v',
                      );
                      Navigator.pop(context);
                    },
                    showCheckmark: false,
                    selectedColor: Aether.accentSoft,
                    backgroundColor: Aether.surfaceAlt,
                    side: BorderSide(
                      color:
                          current ==
                              (v == 'Medium'
                                  ? '$baseModel · Medium'
                                  : '$baseModel · $v')
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
      ),
    );
  }
}

/// web-IDE home parity (Ovid branding): centered logo, big greeting with
/// a mono pill beside it, then open space down to the composer.  The home layout has
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
            constraints: BoxConstraints(
              minHeight: math.max(0.0, c.maxHeight - 64),
            ),
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
                  // Greeting headline (hero). The former mono "preview" pill
                  // was removed for visual parity.
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

/// Compact, default-collapsed reasoning disclosure — DSH-style geometry.
/// A 28px summary row (leading glyph · truncating title · rotating chevron)
/// expands to a hairline-separated, full-width muted body. The live
/// "Thinking…" shimmer is preserved in the summary while streaming.
class _ReasoningCard extends StatefulWidget {
  final Message m;

  /// When true the card starts expanded (used for the LIVE streaming
  /// message while it thinks). Finalized rows still default to collapsed;
  /// a user tap always wins via [_ReasoningCardState._override].
  final bool expandedByDefault;
  const _ReasoningCard(this.m, {this.expandedByDefault = false});
  @override
  State<_ReasoningCard> createState() => _ReasoningCardState();
}

class _ReasoningCardState extends State<_ReasoningCard> {
  /// null = default (collapsed, unless [expandedByDefault]). Once the user
  /// taps, we lock to their choice.
  bool? _override;

  @override
  Widget build(BuildContext context) {
    final isStreaming = widget.m.thinking;
    final expanded = _override ?? widget.expandedByDefault;
    final hasBody = widget.m.content.trim().isNotEmpty;
    return Container(
      key: const ValueKey('chat-reasoning-disclosure'),
      margin: const EdgeInsets.only(bottom: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          // Compact 33px summary — tap to toggle. A .5px hairline under the
          // row matches the reference; chevron rotates over 0.1s.
          Container(
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(color: Aether.hairlineStrong, width: 0.5),
              ),
            ),
            child: InkWell(
              key: const ValueKey('chat-reasoning-summary'),
              borderRadius: BorderRadius.circular(6),
              onTap: hasBody
                  ? () => setState(() => _override = !expanded)
                  : null,
              child: SizedBox(
                height: 33,
                child: Row(
                  children: [
                    if (isStreaming)
                      const _ChaseDot(Aether.accent)
                    else
                      Icon(
                        Icons.psychology_outlined,
                        size: 15,
                        color: Aether.textMuted,
                      ),
                    const SizedBox(width: 6),
                    if (isStreaming)
                      Expanded(
                        child: _ShimmerText(
                          'Thinking…',
                          style: TextStyle(
                            fontSize: 14,
                            height: 24 / 14,
                            color: Aether.textMuted,
                          ),
                        ),
                      )
                    else
                      Expanded(
                        child: Text(
                          'Thoughts',
                          key: const ValueKey('chat-reasoning-title'),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 14,
                            height: 24 / 14,
                            color: Aether.textMuted,
                          ),
                        ),
                      ),
                    if (hasBody)
                      AnimatedRotation(
                        key: const ValueKey('chat-reasoning-chevron'),
                        turns: expanded ? 0.0 : -0.25,
                        duration: const Duration(milliseconds: 100),
                        child: Icon(
                          Icons.chevron_right,
                          size: 16,
                          color: Aether.textMuted,
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
          // Body — full column width, regular markdown at primary color
          // (the reference shows reasoning at the same 14/24 as prose).
          if (expanded && hasBody)
            Container(
              key: const ValueKey('chat-reasoning-body'),
              width: double.infinity,
              padding: const EdgeInsets.only(top: 8, bottom: 4),
              child: _OvidMarkdown(
                content: widget.m.content,
                fontSize: 14,
                color: Aether.text,
              ),
            ),
        ],
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════
// ToolRow parity — live tool-call cards in the chat transcript.
// Collapsed: 24px row  [14px icon]  Title  ·  summary  [state dot]
//   running → glare-sweep shimmer across the row
//   error   → red state dot replaces the icon
// Expanded: detail body — TerminalBlock (terminal icon tools),
//   DiffBlock (edit/write tools), or a plain IN/OUT body otherwise.
// Icons mirror the web icon set (think/search/browse/edit/terminal/
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
    // "running" affordance: continuous glare sweep (2.6s linear).
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
      key: const ValueKey('chat-tool-disclosure'),
      margin: const EdgeInsets.only(bottom: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Compact 30px summary. The running glare sweep paints over this
          // row via a Stack so it never adds layout height.
          Stack(
            children: [
              InkWell(
                key: const ValueKey('chat-tool-summary'),
                borderRadius: BorderRadius.circular(6),
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
                        _StateDot(Aether.warnLight)
                      else if (running)
                        const _ChaseDot(Aether.accent)
                      else
                        Icon(
                          _iconFor(iconKind),
                          size: 14,
                          color: Aether.textMuted,
                        ),
                      const SizedBox(width: 7),
                      Flexible(
                        child: Text(
                          m.toolTitle ?? m.toolName ?? 'tool',
                          key: const ValueKey('chat-tool-title'),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: failed ? Aether.dangerC : Aether.text,
                          ),
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
                        // (the diff badge diff-row parity) computed from the real diff.
                        if (diffCounts != null) ...[
                          const SizedBox(width: 6),
                          Text(
                            '+${diffCounts.$1} −${diffCounts.$2}',
                            style: TextStyle(
                              fontSize: 10,
                              fontFamily: Aether.mono,
                              color: Aether.successLight,
                            ),
                          ),
                        ],
                      ] else
                        const Spacer(),
                      if (hasDetail)
                        AnimatedRotation(
                          key: const ValueKey('chat-tool-chevron'),
                          turns: _open ? 0.5 : 0.0,
                          duration: const Duration(milliseconds: 150),
                          child: Icon(
                            Icons.expand_more,
                            size: 16,
                            color: Aether.textFaint,
                          ),
                        ),
                      // A subagent card links to the child's OWN session, so the
                      // user can read its full transcript instead of the summary.
                      if (childSessionId != null)
                        InkWell(
                          borderRadius: BorderRadius.circular(6),
                          onTap: () =>
                              SubagentScreen.open(context, childSessionId),
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
              // Glare sweep while running — `ovid-tool-row-sweep` parity:
              // a soft highlight band sweeping the FULL row left→right.
              if (running)
                Positioned.fill(
                  child: IgnorePointer(
                    child: AnimatedBuilder(
                      animation: _sweep,
                      builder: (_, _) {
                        final t = _sweep.value;
                        return DecoratedBox(
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
            ],
          ),
          // A single hairline separates summary from the expanded body.
          if (_open && hasDetail) Container(height: 1, color: Aether.hairline),
          // Expanded detail — Terminal / Diff / plain body.
          if (_open && hasDetail) _DetailBody(m: m),
        ],
      ),
    );
  }
}

/// 8px state dot (the tool status indicator StateDot) — replaces the icon on error/stopped.
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
/// "N more lines" fold toggle (the terminal block TerminalBlock behavior).
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
      key: const ValueKey('chat-tool-body'),
      width: double.infinity,
      padding: const EdgeInsets.only(top: 6, bottom: 6),
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
            constraints: const BoxConstraints(maxHeight: 380),
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(10, 4, 10, 8),
              child: _buildRichDetail(m, isDiff, shown, detail),
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

  Widget _buildRichDetail(
    Message m,
    bool isDiff,
    List<String> shown,
    String detail,
  ) {
    // 1. Model Compare result format: sections starting with "## <model_name>"
    if ((m.toolName ?? '').contains('compare') && detail.contains('## ')) {
      return _ModelCompareView(content: detail);
    }
    // 2. Color Palette result format: hex codes like "#FF5733" or "complementary: #..."
    if ((m.toolName ?? '').contains('color_palette') && detail.contains('#')) {
      return _ColorPaletteView(content: detail);
    }
    // Structured plugin renderers take precedence over the prose fallback.
    // Hook/skill Markdown lists must not be mistaken for file diffs.
    final name = m.toolName ?? '';
    if (name == 'hook' ||
        name.startsWith('hook_') ||
        name.startsWith('hook:') ||
        name == 'skill' ||
        name.startsWith('plugin:') ||
        name.startsWith('plugin_')) {
      return _OvidMarkdown(
        content: detail,
        fontSize: 12,
        color: Aether.textMuted,
      );
    }
    // Default diff or text view
    if (isDiff) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: shown.map((l) => _DiffLine(l)).toList(),
      );
    }
    // Rich tool result: detect JSON, Mermaid, colors, URLs in generic output.
    return _RichToolResult(
      content: shown.join('\n'),
      isError: m.toolState == 'error',
    );
  }
}

/// Rich tool result renderer — detects and renders JSON, Mermaid, hex color
/// swatches, and tappable URLs in generic tool output.
class _RichToolResult extends StatefulWidget {
  final String content;
  final bool isError;
  const _RichToolResult({required this.content, this.isError = false});
  @override
  State<_RichToolResult> createState() => _RichToolResultState();
}

class _RichToolResultState extends State<_RichToolResult> {
  bool _jsonExpanded = true;
  bool _mermaidExpanded = false;

  static final _urlRe = RegExp(r'https?://[^\s)\]}>,"]+', caseSensitive: false);
  static final _hexColorRe = RegExp(r'#([0-9a-fA-F]{6})\b');
  static final _mermaidFenceRe = RegExp(
    r'```mermaid\s*\n([\s\S]*?)```',
    multiLine: true,
  );

  /// Try to parse [text] as JSON (object or array). Returns the pretty-printed
  /// string on success, null otherwise.
  static String? _tryJsonFormat(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return null;
    final first = trimmed[0];
    if (first != '{' && first != '[') return null;
    try {
      final decoded = jsonDecode(trimmed);
      return const JsonEncoder.withIndent('  ').convert(decoded);
    } catch (_) {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final content = widget.content;
    final baseColor = widget.isError ? Aether.dangerC : Aether.text;

    // ── Mermaid fenced block ──
    final mermaidMatch = _mermaidFenceRe.firstMatch(content);
    if (mermaidMatch != null) {
      final mermaidSrc = mermaidMatch.group(1)!.trim();
      final before = content.substring(0, mermaidMatch.start).trim();
      final after = content.substring(mermaidMatch.end).trim();
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (before.isNotEmpty) _plainText(before, baseColor),
          _mermaidBlock(mermaidSrc),
          if (after.isNotEmpty) _plainText(after, baseColor),
        ],
      );
    }

    // ── JSON block ──
    final jsonFormatted = _tryJsonFormat(content);
    if (jsonFormatted != null) {
      return _jsonBlock(jsonFormatted);
    }

    // ── Inline enrichments: colors + URLs ──
    final hasColor = _hexColorRe.hasMatch(content);
    final hasUrl = _urlRe.hasMatch(content);
    if (hasColor || hasUrl) {
      return _enrichedText(
        content,
        baseColor,
        hasColor: hasColor,
        hasUrl: hasUrl,
      );
    }

    // ── Plain fallback ──
    return _plainText(content, baseColor);
  }

  Widget _plainText(String text, Color color) => SelectableText(
    text,
    style: TextStyle(
      fontFamily: Aether.mono,
      fontSize: 11.5,
      height: 1.45,
      color: color,
    ),
  );

  Widget _jsonBlock(String formatted) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          borderRadius: BorderRadius.circular(6),
          onTap: () => setState(() => _jsonExpanded = !_jsonExpanded),
          child: Row(
            children: [
              Icon(Icons.data_object, size: 13, color: Aether.accent),
              const SizedBox(width: 5),
              Text(
                'JSON',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  color: Aether.accent,
                ),
              ),
              const SizedBox(width: 4),
              AnimatedRotation(
                turns: _jsonExpanded ? 0.5 : 0.0,
                duration: const Duration(milliseconds: 150),
                child: Icon(Icons.expand_more, size: 14, color: Aether.accent),
              ),
            ],
          ),
        ),
        if (_jsonExpanded) ...[
          const SizedBox(height: 4),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: Aether.surfaceAlt,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Aether.hairline),
            ),
            child: SelectableText(
              formatted,
              style: TextStyle(
                fontFamily: Aether.mono,
                fontSize: 11,
                height: 1.5,
                color: Aether.text,
              ),
            ),
          ),
        ],
      ],
    );
  }

  Widget _mermaidBlock(String source) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          borderRadius: BorderRadius.circular(6),
          onTap: () => setState(() => _mermaidExpanded = !_mermaidExpanded),
          child: Row(
            children: [
              Icon(Icons.schema_outlined, size: 13, color: Aether.accent),
              const SizedBox(width: 5),
              Text(
                'Mermaid diagram',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  color: Aether.accent,
                ),
              ),
              const SizedBox(width: 4),
              AnimatedRotation(
                turns: _mermaidExpanded ? 0.5 : 0.0,
                duration: const Duration(milliseconds: 150),
                child: Icon(Icons.expand_more, size: 14, color: Aether.accent),
              ),
            ],
          ),
        ),
        if (_mermaidExpanded) ...[
          const SizedBox(height: 4),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: Aether.surfaceAlt,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Aether.hairline),
            ),
            child: SelectableText(
              source,
              style: TextStyle(
                fontFamily: Aether.mono,
                fontSize: 11,
                height: 1.5,
                color: Aether.text,
              ),
            ),
          ),
        ],
      ],
    );
  }

  /// Builds a text block with inline color swatches and tappable URLs.
  Widget _enrichedText(
    String text,
    Color baseColor, {
    required bool hasColor,
    required bool hasUrl,
  }) {
    final lines = const LineSplitter().convert(text);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final line in lines)
          _enrichedLine(line, baseColor, hasColor: hasColor, hasUrl: hasUrl),
      ],
    );
  }

  Widget _enrichedLine(
    String line,
    Color baseColor, {
    required bool hasColor,
    required bool hasUrl,
  }) {
    // Fast path: no enrichments on this line.
    final lineHasColor = hasColor && _hexColorRe.hasMatch(line);
    final lineHasUrl = hasUrl && _urlRe.hasMatch(line);
    if (!lineHasColor && !lineHasUrl) {
      return Text(
        line,
        style: TextStyle(
          fontFamily: Aether.mono,
          fontSize: 11.5,
          height: 1.45,
          color: baseColor,
        ),
      );
    }

    // Build spans with inline swatches / tappable links.
    final spans = <InlineSpan>[];
    var cursor = 0;
    // Merge color and URL matches, sorted by start position.
    final matches = <({int start, int end, String type, String value})>[];
    if (lineHasColor) {
      for (final m in _hexColorRe.allMatches(line)) {
        matches.add((
          start: m.start,
          end: m.end,
          type: 'color',
          value: m.group(0)!,
        ));
      }
    }
    if (lineHasUrl) {
      for (final m in _urlRe.allMatches(line)) {
        matches.add((
          start: m.start,
          end: m.end,
          type: 'url',
          value: m.group(0)!,
        ));
      }
    }
    matches.sort((a, b) => a.start.compareTo(b.start));

    final baseStyle = TextStyle(
      fontFamily: Aether.mono,
      fontSize: 11.5,
      height: 1.45,
      color: baseColor,
    );

    for (final m in matches) {
      if (m.start < cursor) continue; // overlapping
      if (m.start > cursor) {
        spans.add(
          TextSpan(text: line.substring(cursor, m.start), style: baseStyle),
        );
      }
      if (m.type == 'color') {
        spans.add(TextSpan(text: m.value, style: baseStyle));
        // Inline swatch circle.
        Color? c;
        try {
          final raw = m.value.substring(1);
          c = Color(int.parse('FF$raw', radix: 16));
        } catch (e) {
          Diag.swallow('chat_screen.color_parse', e);
        }
        if (c != null) {
          spans.add(
            WidgetSpan(
              alignment: PlaceholderAlignment.middle,
              child: Container(
                width: 12,
                height: 12,
                margin: const EdgeInsets.only(left: 3),
                decoration: BoxDecoration(
                  color: c,
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.white24, width: 0.5),
                ),
              ),
            ),
          );
        }
      } else {
        // Tappable URL.
        spans.add(
          TextSpan(
            text: m.value,
            style: baseStyle.copyWith(
              color: Aether.accent,
              decoration: TextDecoration.underline,
              decorationColor: Aether.accent,
            ),
            recognizer: (TapGestureRecognizer()
              ..onTap = () {
                final uri = Uri.tryParse(m.value);
                if (uri != null) {
                  launchUrl(uri, mode: LaunchMode.externalApplication);
                }
              }),
          ),
        );
      }
      cursor = m.end;
    }
    if (cursor < line.length) {
      spans.add(TextSpan(text: line.substring(cursor), style: baseStyle));
    }

    return Text.rich(TextSpan(children: spans));
  }
}

class _ModelCompareView extends StatefulWidget {
  final String content;
  const _ModelCompareView({required this.content});

  @override
  State<_ModelCompareView> createState() => _ModelCompareViewState();
}

class _ModelCompareViewState extends State<_ModelCompareView> {
  int _selectedTab = 0;

  @override
  Widget build(BuildContext context) {
    // Parse "## <model>\n<output>" blocks
    final sections = <({String model, String output})>[];
    final parts = widget.content.split(RegExp(r'(?=^##\s+)', multiLine: true));
    for (final p in parts) {
      final trimmed = p.trim();
      if (!trimmed.startsWith('## ')) continue;
      final lines = trimmed.split('\n');
      final modelTitle = lines.first.substring(3).trim();
      final body = lines.sublist(1).join('\n').trim();
      sections.add((model: modelTitle, output: body));
    }

    if (sections.isEmpty) {
      return SelectableText(
        widget.content,
        style: TextStyle(fontFamily: Aether.mono, fontSize: 11.5),
      );
    }

    final activeIdx = _selectedTab.clamp(0, sections.length - 1);
    final active = sections[activeIdx];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              for (int i = 0; i < sections.length; i++) ...[
                ChoiceChip(
                  label: Text(
                    sections[i].model,
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: i == activeIdx
                          ? FontWeight.w700
                          : FontWeight.w500,
                    ),
                  ),
                  selected: i == activeIdx,
                  onSelected: (_) => setState(() => _selectedTab = i),
                  selectedColor: Aether.accentSoft,
                  backgroundColor: Aether.surfaceAlt,
                  showCheckmark: false,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
                const SizedBox(width: 6),
              ],
            ],
          ),
        ),
        const SizedBox(height: 8),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: Aether.surfaceAlt,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: Aether.hairline),
          ),
          child: SelectableText(
            active.output,
            style: TextStyle(fontSize: 12, height: 1.5, color: Aether.text),
          ),
        ),
      ],
    );
  }
}

class _ColorPaletteView extends StatelessWidget {
  final String content;
  const _ColorPaletteView({required this.content});

  @override
  Widget build(BuildContext context) {
    final hexMatches = RegExp(
      r'#([0-9a-fA-F]{6}|[0-9a-fA-F]{3})\b',
    ).allMatches(content).map((m) => m.group(0)!).toSet().toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (hexMatches.isNotEmpty) ...[
          Text(
            'Palette Swatches',
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              color: Aether.textMuted,
            ),
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final hex in hexMatches) _buildSwatch(context, hex),
            ],
          ),
          const SizedBox(height: 10),
        ],
        SelectableText(
          content,
          style: TextStyle(
            fontFamily: Aether.mono,
            fontSize: 11.5,
            height: 1.45,
          ),
        ),
      ],
    );
  }

  Widget _buildSwatch(BuildContext context, String hex) {
    Color? color;
    try {
      var raw = hex.replaceAll('#', '');
      if (raw.length == 3) raw = raw.split('').map((c) => '$c$c').join();
      color = Color(int.parse('FF$raw', radix: 16));
    } catch (e) {
      Diag.swallow('chat_screen', e);
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      decoration: BoxDecoration(
        color: Aether.surfaceAlt,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: Aether.hairline),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 14,
            height: 14,
            decoration: BoxDecoration(
              color: color ?? Colors.grey,
              borderRadius: BorderRadius.circular(3),
              border: Border.all(color: Colors.white24, width: 0.5),
            ),
          ),
          const SizedBox(width: 6),
          Text(
            hex,
            style: const TextStyle(fontFamily: Aether.mono, fontSize: 11),
          ),
        ],
      ),
    );
  }
}

/// One diff line — green + / red − like the diff renderer DiffBlock.
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
      child: SelectableText(
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

/// PR25/D5: full-screen diff viewer — the details surface gives its
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

/// compaction row — a faint inline event row, collapsed by default:
/// "↻ Context compacted — N messages (~X tokens)"; tap to view the
/// compacted summary (the compaction viewer "View compaction summary").
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
              child: SelectableText(
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

/// "Produced" parity — card under the final answer listing files the
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

  String _base(String path) => path.contains('/') ? path.split('/').last : path;

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
                style: const TextStyle(fontSize: 11.5, fontFamily: Aether.mono),
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
              Icon(
                Icons.upload_file_outlined,
                size: 13,
                color: Aether.successLight,
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

/// turn-tail row — faint footer under the final assistant answer of a
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
          Expanded(
            child: Text(
              m.content,
              style: TextStyle(fontSize: 10.5, color: Aether.textFaint),
            ),
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
  final TextEditingController? input;
  final ChatLayout layout;
  const _MessageView({
    required this.m,
    required this.session,
    required this.msgIndex,
    required this.onAction,
    required this.input,
    required this.layout,
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
            key: isUser ? ValueKey('chat-user-bubble-$msgIndex') : null,
            margin: const EdgeInsets.only(bottom: 2),
            constraints: BoxConstraints(
              maxWidth: isUser
                  ? layout.userBubbleMaxWidth
                  : layout.contentWidth,
            ),
            child: Column(
              crossAxisAlignment: isUser
                  ? CrossAxisAlignment.end
                  : CrossAxisAlignment.start,
              children: [
                switch (m.kind) {
                  MsgKind.imageGen => _imageGen(context),
                  MsgKind.htmlArtifact => HtmlArtifactView(
                    key: ValueKey('${session.id}:${m.htmlArtifact?.id}'),
                    artifact: m.htmlArtifact,
                    sessionId: session.id as String,
                  ),
                  MsgKind.reasoning => _reasoning(),
                  MsgKind.streaming => _streaming(),
                  MsgKind.tool => _toolCard(),
                  MsgKind.turnTail => _turnTail(),
                  MsgKind.compact => _CompactionRow(m),
                  _ => _text(isUser),
                },
                // Attachment chips under the user bubble (in-chat display).
                if (isUser && m.attachments.isNotEmpty) _attachmentChips(),
              ],
            ),
          ),
          // web-IDE message meta + action row: copy / edit / revert / time.
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
              // A11Y: minimum 48dp tap target per Material guidelines.
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
              child: Icon(icon, size: 15, color: Aether.textFaint),
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
    final canEdit =
        input != null &&
        !session.isSubagent &&
        !AgentService.I.busyFor(session.id);
    if (canEdit && isUser && isLast) {
      add(Icons.edit_outlined, 'Edit & resend', () {
        if (!_stageEdit(context, m.content)) return;
        AppState.I.deleteMessagesFrom(session.id, msgIndex);
        onAction();
      });
      add(Icons.replay_outlined, 'Revert', () {
        if (!_canChangeHistory) return;
        AppState.I.deleteMessagesFrom(session.id, msgIndex);
        onAction();
      });
    }
    // Earlier user messages: edit & resend (truncates conversation).
    if (canEdit && isUser && !isLast) {
      add(Icons.edit_outlined, 'Edit & resend', () {
        _showEditResendDialog(context);
      });
    }
    // message feedback: like/dislike + note on final assistant rows.
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
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
              child: Icon(
                m.feedback == 'up'
                    ? Icons.thumb_up_alt
                    : Icons.thumb_up_alt_outlined,
                size: 15,
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
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
              child: Icon(
                m.feedback == 'down'
                    ? Icons.thumb_down_alt
                    : Icons.thumb_down_alt_outlined,
                size: 15,
                color: m.feedback == 'down' ? Aether.danger : Aether.textFaint,
              ),
            ),
          ),
        ),
      );
    }
    // Branch into a new conversation from this assistant message.
    if (!isUser && m.kind == MsgKind.text && !m.thinking) {
      add(Icons.call_split, 'Branch into a new conversation', () {
        final branch = AppState.I.branchSessionFrom(session.id, msgIndex);
        if (branch != null && context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Branched into a new chat'),
              duration: Duration(milliseconds: 900),
            ),
          );
        }
      });
    }
    // Regenerate: re-send the last user message to get a new response.
    if (canEdit && !isUser && isLast && m.kind == MsgKind.text && !m.thinking) {
      add(Icons.refresh, 'Regenerate', () {
        if (!_canChangeHistory) return;
        // Find the last user message content.
        final msgs = session.messages as List<Message>;
        Message? lastUser;
        for (var i = msgs.length - 1; i >= 0; i--) {
          if (msgs[i].role == 'user') {
            lastUser = msgs[i];
            break;
          }
        }
        if (lastUser == null || lastUser.content.isEmpty) return;
        final provider = AppState.I.providerForSession(session);
        if (provider == null ||
            !provider.isConfigured ||
            !provider.models.contains(session.model.split('·').first.trim())) {
          return;
        }
        if (lastUser.attachments.any(
          (a) => a.path == null || a.path!.isEmpty,
        )) {
          return;
        }
        // Delete from the current assistant message onward and resend.
        AppState.I.deleteMessagesFrom(session.id, msgIndex);
        onAction();
        AgentService.I.runTask(
          lastUser.content,
          sessionId: session.id,
          expandRefsFor: session,
          attachments: [
            for (final a in lastUser.attachments)
              (name: a.name, path: a.path!, size: a.size),
          ],
        );
      });
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 8, top: 2),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          ...items,
          if (!isUser && m.elapsedMs != null)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                formatCompactDuration(Duration(milliseconds: m.elapsedMs!)),
                style: TextStyle(fontSize: 10, color: Aether.textFaint),
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

  bool get _canChangeHistory =>
      input != null &&
      !session.isSubagent &&
      AppState.I.activeSessionId == session.id &&
      identical(AppState.I.sessionById(session.id), session) &&
      !AgentService.I.busyFor(session.id) &&
      msgIndex < session.messages.length &&
      identical(session.messages[msgIndex], m);

  bool _stageEdit(BuildContext context, String text) {
    if (!_canChangeHistory) return false;
    final pending = AgentService.I.pendingAttachments;
    String? error;
    if (input!.text.isNotEmpty || pending.isNotEmpty) {
      error = 'Finish the current draft before editing a message.';
    } else if (m.attachments.length > AgentService.maxAttachments ||
        m.attachments.any((a) => a.path == null || a.path!.isEmpty)) {
      error =
          'The original attachments cannot be restored. The message has been kept.';
    }
    if (error != null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(error)));
      return false;
    }
    // Existing workspace copies remain owned by the session. Transfer all
    // metadata before removing any transcript history; no asynchronous gap.
    pending.addAll([
      for (final a in m.attachments)
        (name: a.name, path: a.path!, size: a.size),
    ]);
    input!.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
    return true;
  }

  /// Optional note attached to a down-vote (the feedback collector feedback note popover).
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
          16,
          16,
          16,
          MediaQuery.of(ctx).viewInsets.bottom + 16,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'What was wrong with this answer?',
              style: const TextStyle(
                fontSize: 14.5,
                fontWeight: FontWeight.w700,
              ),
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

  /// Earlier-message edits transfer to the composer before truncating history.
  void _showEditResendDialog(BuildContext context) {
    final c = TextEditingController(text: m.content);
    final navigator = Navigator.of(context, rootNavigator: true);
    void send(String value) {
      final text = value.trim();
      if (text.isEmpty) {
        navigator.pop();
        return;
      }
      navigator.pop();
      if (!_stageEdit(context, text)) return;
      AppState.I.deleteMessagesFrom(session.id, msgIndex);
      onAction();
    }

    final route = DialogRoute<void>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text(
          'Edit & resend',
          style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
        ),
        content: TextField(
          controller: c,
          autofocus: true,
          maxLines: 6,
          minLines: 1,
          style: const TextStyle(fontSize: 14),
          textInputAction: TextInputAction.done,
          onSubmitted: send,
        ),
        actions: [
          TextButton(onPressed: navigator.pop, child: const Text('Cancel')),
          TextButton(
            onPressed: () => send(c.text),
            child: const Text(
              'Edit in composer',
              style: TextStyle(color: Aether.accent),
            ),
          ),
        ],
      ),
    );
    navigator.push(route);
    // The pop result resolves before the reverse animation removes the field.
    route.completed.whenComplete(c.dispose);
  }

  Widget _text(bool isUser) => Container(
    padding: EdgeInsets.symmetric(
      horizontal: isUser ? 16 : 4,
      vertical: isUser ? 10 : 4,
    ),
    decoration: BoxDecoration(
      // User bubble: solid raised fill, 22px radius, no border. Assistant
      // stays borderless prose. Geometry follows the captured reference.
      color: isUser ? Aether.surfaceAlt : Colors.transparent,
      borderRadius: BorderRadius.circular(22),
    ),
    child: isUser
        ? SelectableText(
            m.content,
            style: TextStyle(fontSize: 14, height: 22 / 14, color: Aether.text),
          )
        : _OvidMarkdown(content: m.content),
  );

  Widget _reasoning() => _ReasoningCard(m);

  /// Live streaming bubble (MsgKind.streaming): answer text renders as
  /// markdown the moment it arrives (never hidden behind a thinking card);
  /// while the model is still thinking, the reasoning card shows expanded
  /// by default so the live thought stream stays visible.
  Widget _streaming() {
    final hasBody = m.content.trim().isNotEmpty;
    final isUser = m.role == 'user';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (hasBody && !m.thinking) _text(isUser),
        if (m.thinking) _ReasoningCard(m, expandedByDefault: true),
      ],
    );
  }

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
                Icon(_attachIcon(a.name), size: 13, color: Aether.accent),
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
      'dart' ||
      'py' ||
      'js' ||
      'ts' ||
      'json' ||
      'yaml' ||
      'yml' ||
      'md' ||
      'txt' ||
      'csv' ||
      'html' ||
      'css' ||
      'sh' => Icons.code,
      _ => Icons.insert_drive_file,
    };
  }

  String _fmtSize(int b) => b >= 1048576
      ? '${(b / 1048576).toStringAsFixed(1)} MB'
      : b >= 1024
      ? '${(b / 1024).toStringAsFixed(0)} KB'
      : '$b B';

  /// ToolRow parity — collapsed 24px row (icon + title · summary)
  /// expanding to a Terminal/Diff/plain detail block.
  Widget _toolCard() => _ToolCard(m);

  /// turn-tail parity — faint footer row (elapsed · stats).
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
          GestureDetector(
            onTap: exists ? () => _showFullscreenImage(context, file) : null,
            child: AspectRatio(
              aspectRatio: 1,
              child: exists
                  ? Image.file(
                      file,
                      fit: BoxFit.cover,
                      cacheWidth: Aether.imageCacheWidth(context),
                      errorBuilder: (_, _, _) => _imageGenFallback(),
                    )
                  : _imageGenFallback(),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SelectableText(
                  m.content,
                  style: TextStyle(fontSize: 12.5, color: Aether.textMuted),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    if (exists) ...[
                      _imageAction(
                        Icons.fullscreen,
                        'Fullscreen',
                        () => _showFullscreenImage(context, file),
                      ),
                      const SizedBox(width: 14),
                      _imageAction(
                        Icons.open_in_new,
                        'Open',
                        () => _openLocalFile(context, m.imagePath!),
                      ),
                      const SizedBox(width: 14),
                      _imageAction(
                        Icons.share_outlined,
                        'Share',
                        () => _shareLocalFile(context, m.imagePath!),
                      ),
                      const SizedBox(width: 14),
                      Text(
                        '${(file.lengthSync() / 1024).toStringAsFixed(0)} KB',
                        style: TextStyle(fontSize: 11, color: Aether.textFaint),
                      ),
                    ] else
                      Text(
                        'image file not in workspace',
                        style: TextStyle(fontSize: 11, color: Aether.textFaint),
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

  /// Fullscreen / Open / Share under a generated image.
  ///
  /// A11Y (2026-09-24): this was a bare 15px icon plus 11px text in a
  /// GestureDetector with no padding — a ~16dp target, a third of the 48dp
  /// Android minimum, and invisible to TalkBack. The visual size is unchanged;
  /// the HIT area and the semantics are what grew.
  Widget _imageAction(IconData icon, String label, VoidCallback onTap) =>
      Semantics(
        button: true,
        label: label,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 12),
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
          ),
        ),
      );

  void _showFullscreenImage(BuildContext context, File file) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        fullscreenDialog: true,
        builder: (ctx) => Scaffold(
          backgroundColor: Colors.black,
          appBar: AppBar(
            backgroundColor: Colors.black,
            elevation: 0,
            iconTheme: const IconThemeData(color: Colors.white),
            actions: [
              IconButton(
                icon: const Icon(Icons.share_outlined, color: Colors.white),
                tooltip: 'Share',
                onPressed: () => _shareLocalFile(ctx, file.path),
              ),
            ],
          ),
          body: Center(
            child: InteractiveViewer(
              panEnabled: true,
              boundaryMargin: const EdgeInsets.all(20),
              minScale: 0.5,
              maxScale: 5.0,
              child: Image.file(
                file,
                cacheWidth: Aether.imageCacheWidth(context),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _shareLocalFile(BuildContext context, String path) async {
    await showNativeShare(context, () => NativeShare.file(path));
  }

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
      animation: Listenable.merge([AgentService.I, AppState.I]),
      builder: (_, _) {
        final atts = AgentService.I.pendingAttachments;
        final sessionId = AppState.I.activeSessionId;
        if (atts.isEmpty) return const SizedBox.shrink();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.only(left: 8, top: 4),
              child: Text(
                '${atts.length}/${AgentService.maxAttachments} files',
                style: TextStyle(fontSize: 11, color: Aether.textMuted),
              ),
            ),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 132),
              child: SingleChildScrollView(
                key: const ValueKey('composer-attachments-scroll'),
                primary: false,
                child: Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final att in atts)
                      Container(
                        constraints: const BoxConstraints(maxWidth: 300),
                        margin: const EdgeInsets.only(top: 6),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 9,
                          vertical: 6,
                        ),
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
                            Icon(
                              _iconFor(att.name),
                              size: 16,
                              color: Aether.accent,
                            ),
                            const SizedBox(width: 7),
                            Flexible(
                              child: Tooltip(
                                message: att.name,
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
                            ),
                            const SizedBox(width: 6),
                            Text(
                              _fmtSize(att.size),
                              style: TextStyle(
                                fontSize: 11,
                                color: Aether.textFaint,
                              ),
                            ),
                            const SizedBox(width: 4),
                            IconButton(
                              tooltip: 'Remove attachment ${att.name}',
                              constraints: const BoxConstraints(
                                minWidth: 48,
                                minHeight: 48,
                              ),
                              onPressed: () {
                                if (AppState.I.activeSessionId == sessionId) {
                                  AgentService.I.removeAttachment(att.path);
                                }
                              },
                              icon: Icon(
                                Icons.close,
                                size: 15,
                                color: Aether.textMuted,
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

/// Voice-input mic (press-to-talk): toggles on-device speech recognition,
/// shows a stop button while listening, and AUTO-SENDS the final
/// transcript (silence auto-stops, or tap stop). Honest no-op with a hint
/// when STT is unavailable.
class _MicButton extends StatefulWidget {
  final TextEditingController controller;

  /// Fired with the full transcribed text when dictation ends, so the
  /// message sends exactly like a typed send.
  final void Function(String text) onSend;
  const _MicButton({required this.controller, required this.onSend});
  @override
  State<_MicButton> createState() => _MicButtonState();
}

class _MicButtonState extends State<_MicButton> {
  bool _listening = false;

  @override
  void dispose() {
    if (_listening) VoiceInputService.I.cancel();
    super.dispose();
  }

  Future<void> _toggle() async {
    final voice = VoiceInputService.I;
    if (_listening) {
      await voice.stop();
      if (mounted) setState(() => _listening = false);
      return;
    }
    final available = await voice.isAvailable();
    if (!mounted) return;
    if (!available) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Speech recognition is not available on this device.'),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }
    final base = widget.controller.text;
    final started = await voice.start((text, isFinal) {
      if (!mounted) return;
      final t = text.trim();
      if (t.isEmpty) return;
      widget.controller.text = base.isEmpty ? t : '$base $t';
      widget.controller.selection = TextSelection.collapsed(
        offset: widget.controller.text.length,
      );
      if (isFinal) {
        // Dictation ended (silence or stop button): release the service
        // flag so the next tap starts fresh, then send like typed text.
        unawaited(voice.stop());
        final full = widget.controller.text.trim();
        if (mounted) setState(() => _listening = false);
        if (full.isNotEmpty) widget.onSend(full);
      }
    });
    if (mounted) setState(() => _listening = started);
  }

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: _listening ? 'Stop dictation' : 'Voice',
      icon: Icon(
        _listening ? Icons.mic : Icons.mic_none,
        size: 20,
        color: _listening ? Aether.accent : Aether.textMuted,
      ),
      onPressed: _toggle,
    );
  }
}

class _InputBar extends StatefulWidget {
  final TextEditingController controller;
  final String? sessionId;

  /// Focus node for the composer text field, owned by the parent screen.
  /// Lets external actions (e.g. the queue dock's "Edit in composer")
  /// hand focus to the composer after moving text into it.
  final FocusNode? focusNode;

  /// Startup coordinator observed so runtime plugin skills mounted by the
  /// `skill.mount` item refresh the slash suggestions without rebuilding the
  /// transcript. Defaults to the process singleton.
  final StartupCoordinator? coordinator;
  final bool running;

  /// Approval takeover: when an approval/question card is pending, the
  /// composer is disabled until the user answers it (the approval takeover parity).
  final bool locked;
  final bool editingQueue;
  final VoidCallback onCancelQueueEdit;

  /// Shared width axis: the composer card is capped to [ChatLayout.composerWidth]
  /// and centered within the chat pane.
  final ChatLayout layout;
  final double availableHeight;
  final VoidCallback onSend;
  const _InputBar({
    required this.controller,
    this.focusNode,
    required this.sessionId,
    required this.running,
    required this.layout,
    required this.availableHeight,
    this.coordinator,
    this.locked = false,
    this.editingQueue = false,
    required this.onCancelQueueEdit,
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

  StartupCoordinator get _coordinator =>
      widget.coordinator ?? StartupCoordinator.I;

  /// Last observed `skill.mount` state, so the composer rebuilds exactly when
  /// runtime skills finish mounting (and not on every startup transition).
  StartupItemState? _skillMountState;

  @override
  void initState() {
    super.initState();
    _skillMountState = _currentSkillMountState();
    _coordinator.addListener(_onStartupChanged);
    controller.addListener(_onTextChanged);
    _onTextChanged();
  }

  @override
  void didUpdateWidget(_InputBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != controller) {
      oldWidget.controller.removeListener(_onTextChanged);
      controller.addListener(_onTextChanged);
    }
    if (oldWidget.controller != controller ||
        oldWidget.sessionId != widget.sessionId) {
      _slashActive = false;
      _slashQuery = '';
      _mentionActive = false;
      _mentionQuery = '';
      _mentionStart = -1;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _onTextChanged();
      });
    }
    if (oldWidget.coordinator != widget.coordinator) {
      (oldWidget.coordinator ?? StartupCoordinator.I).removeListener(
        _onStartupChanged,
      );
      _skillMountState = _currentSkillMountState();
      _coordinator.addListener(_onStartupChanged);
    }
  }

  @override
  void dispose() {
    _coordinator.removeListener(_onStartupChanged);
    controller.removeListener(_onTextChanged);
    super.dispose();
  }

  StartupItemState? _currentSkillMountState() {
    for (final item in _coordinator.snapshot.items) {
      if (item.id == 'skill.mount') return item.state;
    }
    return null;
  }

  void _onStartupChanged() {
    final next = _currentSkillMountState();
    if (next == _skillMountState) return;
    _skillMountState = next;
    if (mounted) setState(() {});
  }

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
    for (final s in SkillService.I.userSkillsForSession(
      widget.sessionId ?? '',
    )) {
      final invocation = s.canonicalId ?? s.name;
      add(
        1,
        '$invocation ${s.name}',
        _SlashSuggestion(
          icon: Icons.auto_fix_high_outlined,
          name: '/$invocation',
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
    final sessionId = widget.sessionId ?? '';
    for (final p in AppState.I.plugins.where((p) {
      if (!p.installed || !p.enabled || p.migrationRequired) return false;
      final runtimeId = p.runtimeId;
      if (runtimeId != null) {
        return PluginContributionRegistry.I.isPluginActiveForSession(
          runtimeId,
          sessionId,
        );
      }
      return p.source == null || AppState.I.legacyPluginExecutionAllowed;
    })) {
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
    final parent = app.sessionById(widget.sessionId);
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
          insert: '@session:${sub.sessionId} ',
          group: 'Subagents',
        ),
      ));
    }
    // ── @file: workspace files (the file reference provider file-reference parity) ──
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
        final parts = query.split('/')..removeWhere((p) => p.isEmpty);
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
            description: isDir
                ? 'directory — @$rel/ to descend'
                : 'workspace file',
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
          description:
              'The agent creates workspace files as it works — '
              'try @session:<id> to cite another chat',
          hint: '',
          insert: '@',
          group: 'Files',
        ),
      ));
    }
    // ── @session: this chat's sessions (the session mention provider session-reference parity) ──
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
        final boundaryOk = at == 0 || ' \n\t([,>'.contains(head[at - 1]);
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
    if (AppState.I.activeSessionId != widget.sessionId) return;
    _onTextChanged();
    if (!_mentionActive && !_slashActive) return;
    if (_mentionActive && _mentionStart >= 0) {
      // Replace just the `@token` under the caret, keeping the rest intact.
      final text = controller.text;
      final sel = controller.selection;
      final caret = sel.isValid ? sel.baseOffset : text.length;
      final start = _mentionStart;
      if (start >= text.length ||
          caret < start ||
          caret > text.length ||
          text[start] != '@') {
        return;
      }
      final insert = s.insert ?? '@${s.name} ';
      final next = text.substring(0, start) + insert + text.substring(caret);
      controller.value = TextEditingValue(
        text: next,
        selection: TextSelection.collapsed(offset: start + insert.length),
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
              'Up to 20 files per message, max 20 MB each',
              () => _pickMedia(sheetCtx),
            ),
            _attachOption(
              sheetCtx,
              Icons.insert_drive_file_outlined,
              'Document',
              'PDF, code, text, CSV · up to 20 files per message',
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
    final sessionId = widget.sessionId;
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
    await _stagePicked(result, sessionId);
  }

  /// Pick a photo/video from the gallery and stage it as an attachment.
  Future<void> _pickMedia(BuildContext sheetCtx) async {
    Navigator.pop(sheetCtx);
    final sessionId = widget.sessionId;
    final result = await FilePicker.platform.pickFiles(
      type: FileType.media,
      allowMultiple: true,
      withData: false,
    );
    await _stagePicked(result, sessionId);
  }

  Future<void> _stagePicked(FilePickerResult? result, String? sessionId) async {
    if (result == null || result.files.isEmpty) return;
    if (sessionId == null) {
      _toast('Select a chat before attaching files.');
      return;
    }
    final files = result.files.where((f) => f.path != null).toList();
    if (files.isEmpty) {
      _toast('Could not access that file.');
      return;
    }
    var ok = 0;
    final errors = <String>[];
    for (final f in files) {
      final err = await AgentService.I.attachFile(
        f.path!,
        f.name,
        sessionId: sessionId,
      );
      if (err != null) {
        errors.add(err);
      } else {
        ok++;
      }
    }
    if (ok == 0) {
      _toast(errors.isEmpty ? 'No files attached.' : errors.first);
    } else if (errors.isEmpty) {
      _toast(
        'Attached $ok file${ok == 1 ? '' : 's'} — sent with your next message.',
      );
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
    // Disposed with the dialog: a leaked controller keeps its listeners and the
    // platform text-input channel alive after the sheet is gone.
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
    ).whenComplete(c.dispose);
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

  /// Line cap for the composer field. The card is capped at half of the
  /// chat pane (which excludes the startup panel), so at large text scales a
  /// fixed 5-line field (a wrapped hint counts toward its height) can be
  /// taller than the card itself and push the field below the viewport.
  /// Derive the cap from the space the card actually leaves for the field.
  int _composerMaxLines(BuildContext context) {
    final preferred = widget.availableHeight < 400 ? 2 : 5;
    // AetherType.body: 14px at 1.5 line height.
    final lineHeight = MediaQuery.textScalerOf(context).scale(14) * 1.5;
    // Card padding (12) + toolbar gap (6) + 48px toolbar + field padding (24).
    final budget = widget.availableHeight * 0.5 - 12 - 6 - 48 - 24;
    final fits = (budget / lineHeight).floor();
    return fits.clamp(1, preferred);
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
        // Symmetric inset centers the composer card on the same axis as the
        // transcript; on a narrow pane the card collapses to the pane width.
        padding: EdgeInsets.only(
          top: 4,
          bottom: 10,
          left: (widget.layout.viewportWidth - widget.layout.composerWidth) / 2,
          right:
              (widget.layout.viewportWidth - widget.layout.composerWidth) / 2,
        ),
        child: Container(
          key: const ValueKey('chat-composer-card'),
          constraints: BoxConstraints(maxHeight: widget.availableHeight * 0.5),
          // Aether composer surface: surfaceAlt fill, rLg radius, hairline
          // border, soft elevation. Content fills top-to-bottom; the toolbar
          // row sits beneath the field so the primary action is always
          // reachable.
          padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
          decoration: BoxDecoration(
            color: Aether.surfaceAlt,
            borderRadius: BorderRadius.circular(AetherRadius.rLg),
            border: Border.all(color: Aether.hairline),
            boxShadow: AetherShadows.shadowS,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                fit: FlexFit.loose,
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // ── Staged attachment preview chips (dismissible) ──
                      const _AttachmentChip(),
                      // ── Slash menu: opens on a bare `/`, fuzzy-ranked, grouped
                      //    into Commands / Skills / MCP tools / Plugins ──
                      if (suggestions.isNotEmpty)
                        Container(
                          margin: const EdgeInsets.fromLTRB(4, 2, 4, 4),
                          constraints: BoxConstraints(
                            maxHeight: math.min(
                              220,
                              widget.availableHeight * 0.25,
                            ),
                          ),
                          decoration: BoxDecoration(
                            color: Aether.surface,
                            borderRadius: BorderRadius.circular(
                              AetherRadius.rMd,
                            ),
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
                                          Icon(
                                            s.icon,
                                            size: 16,
                                            color: Aether.accent,
                                          ),
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
                                                if (s
                                                    .description
                                                    .isNotEmpty) ...[
                                                  const SizedBox(height: 1),
                                                  Text(
                                                    s.description,
                                                    maxLines: 1,
                                                    overflow:
                                                        TextOverflow.ellipsis,
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
                      // ── Composer field — AetherField, multiline, rLg surfaceAlt ──
                      AetherField(
                        fieldKey: const ValueKey('chat-composer'),
                        label: 'Message',
                        showLabel: false,
                        controller: controller,
                        focusNode: widget.focusNode,
                        enabled: !locked,
                        maxLines: _composerMaxLines(context),
                        minLines: 1,
                        radius: AetherRadius.rLg,
                        hint: locked
                            ? 'Answer the approval card above first…'
                            : 'Describe what you want to build…  / commands  @ agents',
                        contentPadding: const EdgeInsets.fromLTRB(
                          14,
                          12,
                          14,
                          12,
                        ),
                        onSubmitted: (_) {
                          if (!locked) onSend();
                        },
                      ),
                      const _ControlServiceNotice(),
                      if (widget.editingQueue)
                        Padding(
                          padding: const EdgeInsets.only(top: 6),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                'Editing queued message · original files retained',
                              ),
                              AetherGhostButton(
                                label: 'Keep as new draft',
                                onPressed: widget.onCancelQueueEdit,
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 6),
              // ── Toolbar row — attach · chips · mic · primary ──
              Row(
                children: [
                  AetherGhostButton(
                    label: 'Attach',
                    tooltip: 'Attach',
                    icon: Icons.add_circle_outline,
                    iconOnly: true,
                    iconSize: 40,
                    onPressed: () => _attachSheet(context),
                  ),
                  // The middle chips (workspace / plan / mode) scroll
                  // horizontally on narrow phones instead of overflowing the
                  // composer row; the mic/send actions stay pinned right.
                  Expanded(
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        children: [
                          // Studio-only sandbox folder selector chip
                          const _StudioFolderChip(),
                          // web-IDE plan chip — amber, only while plan mode is on.
                          const _PlanChip(),
                          // web-IDE mode selector — icon + text chip, opens the mode sheet.
                          const _ModeChip(),
                        ],
                      ),
                    ),
                  ),
                  // Model selector lives in the header AppBar — not duplicated here.
                  _MicButton(
                    controller: controller,
                    onSend: (_) => widget.onSend(),
                  ),
                  const SizedBox(width: 4),
                  // ── Stateful primary / stop button (web-IDE InputBar pattern) ──
                  AnimatedBuilder(
                    animation: Listenable.merge([AgentService.I, controller]),
                    builder: (_, _) {
                      // Per-session run state (never leaked from other
                      // sessions — the multi-session blink fix).
                      final sessionId = widget.sessionId ?? '';
                      final hasSession = widget.sessionId != null;
                      final runningNow =
                          hasSession && AgentService.I.busyFor(sessionId);
                      final hasDraft = controller.text.trim().isNotEmpty;
                      final hasQueued =
                          hasSession &&
                          AgentService.I
                              .queuedMessagesFor(sessionId)
                              .isNotEmpty;
                      void stop() {
                        if (hasSession) {
                          AgentService.I.stopRequested(sessionId: sessionId);
                        } else {
                          AgentService.I.hardStopAll();
                        }
                      }

                      // Match the existing submission handler: files alone
                      // are not a submission, and queue edits retain their
                      // original attachments rather than newly staged files.
                      final canSubmit =
                          hasSession &&
                          AppState.I.activeSessionId == sessionId &&
                          hasDraft &&
                          !locked &&
                          AgentService.I.pendingApproval == null &&
                          (!widget.editingQueue ||
                              AgentService.I.pendingAttachments.isEmpty);
                      final interrupt = AppState.I.sendWhileBusyInterrupt;
                      final actionLabel = widget.editingQueue
                          ? 'Save'
                          : runningNow
                          ? (interrupt ? 'Interrupt and send' : 'Queue')
                          : 'Send';
                      final actionTooltip = widget.editingQueue
                          ? 'Save queued message'
                          : runningNow && !interrupt
                          ? 'Add to queue'
                          : actionLabel;
                      return Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          // Stop remains independent of the draft/save action.
                          if (runningNow)
                            AetherDangerButton(
                              label: 'Stop',
                              tooltip: hasQueued
                                  ? 'Stop session (next queued will run)'
                                  : 'Stop session',
                              icon: Icons.stop_rounded,
                              iconOnly: true,
                              onPressed: stop,
                            ),
                          if (!runningNow ||
                              hasDraft ||
                              widget.editingQueue) ...[
                            if (runningNow) const SizedBox(width: 4),
                            AetherPrimaryButton(
                              label: actionLabel,
                              tooltip: actionTooltip,
                              icon: widget.editingQueue
                                  ? Icons.check
                                  : Icons.arrow_upward,
                              iconOnly: true,
                              onPressed: canSubmit ? onSend : null,
                            ),
                          ],
                        ],
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

/// Minimal "older messages not shown" marker for the bounded subagent
/// transcript (`ChatTranscript`), so a truncated child run is never silent.
class _OlderMessagesIndicator extends StatelessWidget {
  const _OlderMessagesIndicator();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.more_horiz, size: 14, color: Aether.textFaint),
          const SizedBox(width: 6),
          Text(
            'Older messages not shown',
            style: TextStyle(fontSize: 11, color: Aether.textFaint),
          ),
        ],
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

/// web-IDE QueueDock — a strip above the input bar showing queued messages
/// with edit/remove actions. Shown only when [AgentService.queuedMessages]
/// is non-empty.
/// web-IDE GoalBar — the session goal as a strip above the composer dock:
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
          'paused' => Aether.warnLight,
          'blocked' => Aether.danger,
          _ => Aether.successLight, // complete
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
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
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
          16,
          16,
          16,
          MediaQuery.of(ctx).viewInsets.bottom + 16,
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

/// web-IDE TodoDock — live checklist written by todo_write tool.
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
                            valueColor: AlwaysStoppedAnimation(
                              Aether.successLight,
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
                                  ? Aether.successLight
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
  final String? sessionId;
  final VoidCallback onEdited;

  /// Edits queued text in the composer while the service retains its files.
  final void Function(int id, String text) onEditToComposer;
  const _QueueDock({
    this.sessionId,
    required this.onEdited,
    required this.onEditToComposer,
  });

  @override
  Widget build(BuildContext context) {
    final agent = AgentService.I;
    return AnimatedBuilder(
      animation: agent,
      builder: (_, _) {
        final sid = sessionId;
        final queue = sid == null
            ? agent.queuedMessages
            : agent.queuedMessagesFor(sid);
        if (queue.isEmpty) return const SizedBox.shrink();
        final ids = sid == null
            ? const <int>[]
            : agent.queuedMessageIdsFor(sid);
        return SafeArea(
          top: false,
          child: Container(
            margin: const EdgeInsets.fromLTRB(12, 0, 12, 0),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
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
                    Expanded(
                      child: Text(
                        '${queue.length} queued message${queue.length > 1 ? 's' : ''}',
                        style: TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w600,
                          color: Aether.textMuted,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    GestureDetector(
                      onTap: () {
                        for (var i = queue.length - 1; i >= 0; i--) {
                          if (ids.length == queue.length) {
                            agent.removeQueuedMessageById(ids[i]);
                          } else {
                            agent.removeQueuedMessage(i);
                          }
                        }
                        onEdited();
                      },
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 4,
                          vertical: 6,
                        ),
                        child: Text(
                          'Clear all',
                          style: TextStyle(
                            fontSize: 11,
                            color: Aether.textFaint,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 3),
                // Queued message rows — keyed by the message's stable id so
                // a delete/steer/edit never rebinds another row's State.
                // The shared dock owns scrolling; nesting a second viewport
                // here clips rows even when the surrounding chat has room.
                Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (var i = 0; i < queue.length; i++)
                      _QueueRow(
                        key: ValueKey((
                          sid,
                          ids.length == queue.length ? ids[i] : 'q-$i',
                        )),
                        id: ids.length == queue.length ? ids[i] : null,
                        index: i,
                        text: queue[i],
                        onEdited: onEdited,
                        onEditToComposer: onEditToComposer,
                      ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _QueueRow extends StatefulWidget {
  final int? id;
  final int index;
  final String text;
  final VoidCallback onEdited;

  /// Copies this row's text into the composer; saving updates the queue in place.
  final void Function(int id, String text) onEditToComposer;
  const _QueueRow({
    super.key,
    this.id,
    required this.index,
    required this.text,
    required this.onEdited,
    required this.onEditToComposer,
  });

  @override
  State<_QueueRow> createState() => _QueueRowState();
}

/// Action spec for [_QueueRow]'s icon buttons, in left-to-right order.
/// Exposed so tests can assert the row's action order, icons and tooltips
/// without spinning up the whole chat UI.
@visibleForTesting
class QueueRowAction {
  final IconData icon;
  final String tooltip;

  /// Stable id: 'quickSend', 'editInComposer', 'delete'.
  final String action;
  const QueueRowAction(this.icon, this.tooltip, this.action);
}

@visibleForTesting
const queueRowActions = <QueueRowAction>[
  QueueRowAction(
    Icons.fast_forward_outlined,
    'Quick send: stop current run and send this now',
    'quickSend',
  ),
  QueueRowAction(Icons.edit_outlined, 'Edit in composer', 'editInComposer'),
  QueueRowAction(Icons.delete_outline, 'Delete', 'delete'),
];

class _QueueRowState extends State<_QueueRow> {
  void _delete() {
    final agent = AgentService.I;
    final id = widget.id;
    if (id != null) {
      agent.removeQueuedMessageById(id);
    } else {
      agent.removeQueuedMessage(widget.index);
    }
    widget.onEdited();
  }

  /// Quick send: pull this row to the front of the queue and stop the
  /// current run so the message starts immediately.
  void _quickSend() {
    final agent = AgentService.I;
    final id = widget.id;
    if (id != null) {
      agent.quickSendQueuedMessage(id);
    } else {
      // No stable id (index-based row): steer to front, then stop the
      // active session so the head starts now.
      agent.steerQueuedMessage(widget.index);
      final sid = AppState.I.activeSessionId;
      if (sid != null) agent.stopRequested(sessionId: sid);
    }
    widget.onEdited();
  }

  /// Retain the original until the composer can save an edit by stable id.
  void _editToComposer() {
    final text = widget.text;
    final id = widget.id;
    if (id == null) return;
    widget.onEditToComposer(id, text);
    widget.onEdited();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 2),
      child: Row(
        children: [
          Expanded(
            child: Text(
              widget.text,
              style: TextStyle(fontSize: 12.5, color: Aether.text),
            ),
          ),
          // Quick send FIRST: stop the current run and send this queued
          // message right now — it is steered to the front and the stop
          // promotes the queue head immediately.
          _QueueAction(
            icon: queueRowActions[0].icon,
            color: Aether.warn,
            tooltip: queueRowActions[0].tooltip,
            onTap: _quickSend,
          ),
          // The composer saves by stable id, preserving queued attachments.
          _QueueAction(
            icon: queueRowActions[1].icon,
            color: Aether.textMuted,
            tooltip: queueRowActions[1].tooltip,
            onTap: _editToComposer,
          ),
          _QueueAction(
            icon: queueRowActions[2].icon,
            color: Aether.textMuted,
            tooltip: queueRowActions[2].tooltip,
            onTap: _delete,
          ),
        ],
      ),
    );
  }
}

/// A queue-row action with a real 48dp-wide tap target (the old rows used
/// ~26px GestureDetectors, which were easy to miss). The height is NOT
/// pinned — a fixed height would pin every queue row's height; vertical
/// padding keeps the target ~40dp tall while rows size to their text.
class _QueueAction extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String tooltip;
  final VoidCallback onTap;
  const _QueueAction({
    required this.icon,
    required this.color,
    required this.tooltip,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: SizedBox(
          width: 48,
          child: Padding(
            // 12 -> 9 (2026-09-24): a one-line queued message used to cost
            // ~44dp of dock height. Width stays 48 so the tap target is still
            // easy to hit; rows keep sizing to their text.
            padding: const EdgeInsets.symmetric(vertical: 9),
            child: Center(child: Icon(icon, size: 16, color: color)),
          ),
        ),
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
        // The row can be scrolled out and disposed during the await; calling
        // setState then throws "setState() called after dispose()".
        if (!mounted) return;
        setState(() => copied = true);
        Future.delayed(const Duration(seconds: 2), () {
          if (mounted) setState(() => copied = false);
        });
      },
      // A11Y (2026-09-24): vertical padding was 2, giving a ~18dp target.
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
        child: Row(
          children: [
            Icon(
              copied ? Icons.check : Icons.copy_outlined,
              size: 14,
              color: copied ? Aether.successLight : Aether.textFaint,
            ),
            const SizedBox(width: 6),
            Text(
              copied ? 'Copied' : 'Copy',
              style: TextStyle(
                fontSize: 11,
                color: copied ? Aether.successLight : Aether.textFaint,
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
/// the chat stream itself; approvals float above the input (web-IDE style).
/// A background session is waiting on an approval. Tapping Review switches to
/// it, where the normal card renders.
class _OtherSessionsApprovalRow extends StatelessWidget {
  const _OtherSessionsApprovalRow({required this.items});

  final List<({String sessionId, String title, ApprovalRequest request})> items;

  @override
  Widget build(BuildContext context) {
    final first = items.first;
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 0, 12, 6),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: Aether.accent.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Aether.hairline),
      ),
      child: Row(
        children: [
          Icon(
            Icons.notifications_active_outlined,
            size: 16,
            color: Aether.accent,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              items.length == 1
                  ? '"${first.title}" is waiting for approval'
                  : '${items.length} sessions are waiting for approval',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12, color: Aether.text),
            ),
          ),
          TextButton(
            onPressed: () => AppState.I.selectSession(first.sessionId),
            child: const Text('Review', style: TextStyle(fontSize: 12)),
          ),
        ],
      ),
    );
  }
}

class _ApprovalDock extends StatefulWidget {
  const _ApprovalDock();

  @override
  State<_ApprovalDock> createState() => _ApprovalDockState();
}

class _ApprovalDockState extends State<_ApprovalDock> {
  // The scope toggle and the "deny with a note" dialog were removed on
  // 2026-09-24: the card is now exactly Deny / Allow / Always Allow, and
  // grants are per mode + per session by construction, so there is no scope to
  // pick. `AgentService.approve(false, note:)` still exists for programmatic
  // callers.
  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([AgentService.I, AppState.I]),
      builder: (_, _) {
        final req = AgentService.I.pendingApproval;
        if (req == null) {
          // Another session may be waiting on an approval this dock cannot
          // show, because it renders the foreground session's bucket. Say so
          // instead of letting it auto-deny in silence.
          final elsewhere = AgentService.I.pendingApprovalsElsewhere;
          if (elsewhere.isEmpty) return const SizedBox.shrink();
          return _OtherSessionsApprovalRow(items: elsewhere);
        }
        // ── ask_user_question mode — structured Q&A card ──
        if (req.questions != null && req.questions!.isNotEmpty) {
          return _QuestionsCard(req, key: ObjectKey(req));
        }
        // ── Plan exit (exit_plan_mode) — opencode-style switch prompt ──
        // The plan itself lives in the model's message; this asks the single
        // yes/no "switch to the build agent?" question, exactly like
        // opencode's plan_exit tool. There is no plan-review card.
        if (req.tool == 'exit_plan_mode') {
          return _QuestionsCard(req, key: ObjectKey(req));
        }
        // ── Standard approve/deny card: exactly three actions ──
        return Container(
          margin: const EdgeInsets.fromLTRB(12, 0, 12, 6),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: Aether.warnLight.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Aether.warnLight.withValues(alpha: 0.4)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Icon(
                    Icons.warning_amber_rounded,
                    size: 16,
                    color: Aether.warnLight,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: req.tool == 'commit'
                        ? SizedBox(
                            key: const ValueKey('commit-approval-detail'),
                            height: 180,
                            child: Scrollbar(
                              child: SingleChildScrollView(
                                key: ObjectKey(req),
                                child: SelectionArea(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      for (final line in req.detail.split('\n'))
                                        Text(
                                          line,
                                          style: TextStyle(
                                            fontSize: 12,
                                            height: 1.4,
                                            color: Aether.text,
                                            fontFamily: Aether.mono,
                                          ),
                                        ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          )
                        : Text(
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
                  // EXACTLY THREE actions (owner requirement, 2026-09-24):
                  // Deny, Allow, Always Allow. The card used to carry a fourth
                  // "Deny with a note" icon button plus a This session /
                  // All sessions scope row. The note dialog is gone, and the
                  // scope choice is gone with it — grants are now per MODE and
                  // per session by construction, so there is nothing to choose.
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
                      foregroundColor: Aether.successLight,
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      minimumSize: Size.zero,
                    ),
                    child: const Text('Allow', style: TextStyle(fontSize: 12)),
                    onPressed: () => AgentService.I.approve(true),
                  ),
                  if (req.allowAlways)
                    TextButton(
                      style: TextButton.styleFrom(
                        foregroundColor: Aether.accent,
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        minimumSize: Size.zero,
                      ),
                      child: const Text(
                        'Always Allow',
                        style: TextStyle(fontSize: 12),
                      ),
                      // No scope choice: an Always Allow is recorded for THIS
                      // mode and THIS session, persists across restarts, and is
                      // purged when the session is deleted.
                      onPressed: () => AgentService.I.approveAlways(),
                    ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }
}

/// Structured Q&A card for ask_user_question — Gemini-web style with
/// tappable option chips per question and a submit button.
class _QuestionsCard extends StatefulWidget {
  final ApprovalRequest req;
  const _QuestionsCard(this.req, {super.key});

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
              Expanded(
                child: Text(
                  'Questions from the AI',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: Aether.accent,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          // The question list is bounded and scrollable so a tall set of
          // questions never overflows the viewport. Short sets lay out at
          // natural height (no scrolling); only content beyond the cap
          // scrolls. The shared dock scroll surface still bounds the whole
          // card, so the header and the answer action stay reachable.
          ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: math.min(MediaQuery.sizeOf(context).height * 0.5, 360),
            ),
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
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
                        children: [
                          for (final opt in q.options) _optionChip(q, opt),
                        ],
                      ),
                    ],
                    // Free-form "own answer" — for answers the chips don't cover.
                    const SizedBox(height: 6),
                    _ownAnswerField(q),
                    const SizedBox(height: 8),
                  ],
                ],
              ),
            ),
          ),
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
                onPressed: () {
                  if (identical(AgentService.I.pendingApproval, widget.req)) {
                    AgentService.I.approve(false);
                  }
                },
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
                        if (!identical(
                          AgentService.I.pendingApproval,
                          widget.req,
                        )) {
                          return;
                        }
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
        contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
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
          _custom[q.id]?.clear();
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

/// Studio-only sandbox folder chip: visible ONLY when Studio mode is active.
/// Allows picking or clearing the pinned workspace folder right from the chatbox.
class _StudioFolderChip extends StatelessWidget {
  const _StudioFolderChip();

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([AppState.I, AgentService.I]),
      builder: (_, _) {
        final s = AppState.I.activeSession;
        final isStudio =
            AgentService.I.mode == AgentMode.studio ||
            (s?.mode == AgentMode.studio.name);
        if (!isStudio) return const SizedBox.shrink();

        final folder = (s?.workspaceFolder ?? '').trim();
        final repo = (AgentService.I.sessionRepoFull ?? '').trim();
        final hasFolder = folder.isNotEmpty;
        final hasRepo = repo.isNotEmpty;
        // The REPO NAME wins. The folder branch used to come first, and for a
        // registry clone the folder is `<owner>__<repo>__<branch>`, so the chip
        // read `aasheesh333__OvidAI__main` — the owner's username, which is
        // exactly what must not appear here. The folder basename is now only a
        // fallback for a pinned local folder with no repo connected.
        final label = hasRepo
            ? repo.split('/').last
            : (hasFolder ? folder.split('/').last : 'sandbox');
        final isConfigured = hasFolder || hasRepo;

        return Padding(
          padding: const EdgeInsets.only(right: 6),
          child: GestureDetector(
            onTap: () {
              // Open Studio screen directly so user can connect a repo, pick/manage folders, or edit files
              openStudio(context);
            },
            onLongPress: () => _manageWorkspaceFolder(context),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(16),
                color: isConfigured
                    ? Aether.accent.withValues(alpha: 0.12)
                    : Aether.surfaceAlt,
                border: Border.all(
                  color: isConfigured
                      ? Aether.accent.withValues(alpha: 0.5)
                      : Aether.hairline,
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    hasRepo
                        ? Icons.bookmark_border
                        : (hasFolder
                              ? Icons.folder_special_outlined
                              : Icons.folder_outlined),
                    size: 14,
                    color: isConfigured ? Aether.accent : Aether.textMuted,
                  ),
                  const SizedBox(width: 5),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 100),
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                        height: 20 / 13,
                        color: isConfigured ? Aether.accent : Aether.textMuted,
                      ),
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

  Future<void> _manageWorkspaceFolder(BuildContext context) async {
    final s = AppState.I.activeSession;
    if (s == null) return;
    final current = s.workspaceFolder;
    final hasFolder = current != null && current.isNotEmpty;

    final choice = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Aether.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (sheetCtx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SizedBox(height: 14),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 18),
              child: Text(
                'Sandbox folder (Studio)',
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
              ),
            ),
            const SizedBox(height: 4),
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 0, 18, 8),
              child: Text(
                hasFolder ? current : 'Session sandbox (no pinned folder)',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 11.5, color: Aether.textFaint),
              ),
            ),
            ListTile(
              dense: true,
              leading: Icon(
                Icons.drive_file_move_outline,
                size: 19,
                color: Aether.accent,
              ),
              title: const Text(
                'Select working folder',
                style: TextStyle(fontSize: 13.5),
              ),
              onTap: () => Navigator.pop(sheetCtx, 'pick'),
            ),
            if (hasFolder)
              ListTile(
                dense: true,
                leading: Icon(
                  Icons.inventory_2_outlined,
                  size: 19,
                  color: Aether.textMuted,
                ),
                title: const Text(
                  'Reset to session sandbox',
                  style: TextStyle(fontSize: 13.5),
                ),
                onTap: () => Navigator.pop(sheetCtx, 'sandbox'),
              ),
            const SizedBox(height: 10),
          ],
        ),
      ),
    );

    if (choice == null || !context.mounted) return;
    if (choice == 'sandbox') {
      if (!identical(AppState.I.sessionById(s.id), s)) return;
      AppState.I.setSessionWorkspaceFolder(null, sessionId: s.id);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Working in the session sandbox.'),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }

    String? path;
    try {
      path = await FilePicker.platform.getDirectoryPath(
        dialogTitle: 'Select Studio sandbox folder',
      );
    } catch (_) {
      path = null;
    }
    if (path == null || !context.mounted) return;
    final dir = Directory(path);
    if (!dir.existsSync()) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('That folder is not accessible.'),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }

    var writable = false;
    bool probeWritable() {
      Directory? probe;
      try {
        probe = Directory(path!).createTempSync('.ovid_probe-');
        File('${probe.path}/write').writeAsStringSync('ok');
        return true;
      } catch (e) {
        Diag.swallow('chat_screen', e);
        return false;
      } finally {
        if (probe != null) {
          try {
            probe.deleteSync(recursive: true);
          } catch (e) {
            Diag.swallow('chat_screen.probeCleanup', e);
          }
        }
      }
    }

    writable = probeWritable();

    if (!writable) {
      final granted = await AgentService.I.requestAllFilesAccess();
      if (granted) {
        writable = probeWritable();
      }
    }

    if (!context.mounted) return;
    if (!writable) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'That folder is read-only for Ovid Si — grant All Files Access or pick another folder.',
          ),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }

    if (!identical(AppState.I.sessionById(s.id), s)) return;
    AppState.I.setSessionWorkspaceFolder(path, sessionId: s.id);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Working folder: ${path.split('/').last}'),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }
}

/// web-IDE plan chip — amber "Plan" indicator in the composer, visible only
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
        final pending = s?.planModePending;
        // G2: a transition queued for the next turn boundary is still visible —
        // the chip shows the target state with a trailing ellipsis instead of
        // silently ignoring the tap.
        if (!on && pending == null) return const SizedBox.shrink();
        return GestureDetector(
          onTap: () {
            AgentService.I.planMode = false;
          },
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
            decoration: BoxDecoration(
              color: Aether.warnLight.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: Aether.warnLight.withValues(alpha: 0.45),
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.architecture, size: 14, color: Aether.warnLight),
                const SizedBox(width: 6),
                Text(
                  pending == null ? 'Plan' : (pending ? 'Plan…' : 'Plan off…'),
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                    height: 20 / 13,
                    color: Aether.warnLight,
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
      isScrollControlled: true,
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
                'Agent access mode',
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 6),
              for (final m in modeOptionsForPicker())
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
                  onTap: () async {
                    Navigator.pop(context);
                    if (m == AgentMode.control) {
                      await _enableControlMode(context);
                    } else {
                      AgentService.I.setMode(m);
                    }
                  },
                ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }
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

/// ═══════════════ web-IDE style markdown renderer ═══════════════
/// Fenced code blocks → copyable boxes with lang label + copy btn.
/// Diff lines (+/-) inside code get green/red gutter coloring.
/// Resolve a `<font color="...">` value to a [Color]: a small allowlist of
/// names plus `#rgb`/`#rrggbb` hex. Anything else (including injection
/// attempts like `red; background:...`) returns null so the caller falls
/// back to plain body text.
Color? ovidFontColor(String? raw) {
  final v = raw?.trim().toLowerCase() ?? '';
  if (v.isEmpty) return null;
  switch (v) {
    case 'red':
      return Colors.red;
    case 'green':
      return Colors.green;
    case 'blue':
      return Colors.blue;
    case 'orange':
      return Colors.orange;
    case 'purple':
      return Colors.purple;
    case 'yellow':
      return Colors.yellow;
    case 'pink':
      return Colors.pink;
    case 'cyan':
      return Colors.cyan;
  }
  final hex = RegExp(r'^#([0-9a-f]{3}|[0-9a-f]{6})$').firstMatch(v);
  if (hex == null) return null;
  var digits = hex.group(1)!;
  if (digits.length == 3) {
    digits = digits.split('').map((c) => '$c$c').join();
  }
  return Color(int.parse('ff$digits', radix: 16));
}

class _OvidMarkdown extends StatelessWidget {
  final String content;

  /// Body text size / colour. Answers use the defaults; apparatus surfaces
  /// (reasoning, tool detail) pass a smaller, dimmer pair so they read as
  /// secondary.
  final double fontSize;
  final Color? color;
  const _OvidMarkdown({required this.content, this.fontSize = 14, this.color});

  static final _fenceRe = RegExp(r'```(\w*)\n([\s\S]*?)```', multiLine: true);

  /// Model-authored color spans: `<font color="...">text</font>`. Split
  /// before markdown so the color survives (the markdown package leaves
  /// inline HTML as literal text, which no element builder ever sees).
  /// Unknown colors fall back to body text via [ovidFontColor].
  static final _fontRe = RegExp(
    '<font\\s+color="([^"]+)">([\\s\\S]*?)</font>',
    multiLine: true,
  );

  @override
  Widget build(BuildContext context) {
    final parts = <Widget>[];
    void addProse(String text) {
      var last = 0;
      for (final match in _fontRe.allMatches(text)) {
        if (match.start > last) {
          parts.add(_prose(context, text.substring(last, match.start)));
        }
        parts.add(_coloredChunk(match.group(2) ?? '', match.group(1)));
        last = match.end;
      }
      if (last < text.length) {
        parts.add(_prose(context, text.substring(last)));
      }
    }

    var last = 0;
    for (final match in _fenceRe.allMatches(content)) {
      if (match.start > last) {
        addProse(content.substring(last, match.start));
      }
      parts.add(
        _OvidCodeBox(
          lang: match.group(1)?.isEmpty ?? true ? 'code' : match.group(1)!,
          code: match.group(2) ?? '',
        ),
      );
      last = match.end;
    }
    if (last < content.length) {
      addProse(content.substring(last));
    }
    if (parts.isEmpty) addProse(content);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final w in parts)
          Padding(padding: const EdgeInsets.only(bottom: 6), child: w),
      ],
    );
  }

  /// One colored run. Plain selectable text in the resolved color — only
  /// color is honored (no links, scripts, or layout), keeping
  /// model-authored markup safe.
  Widget _coloredChunk(String text, String? colorAttr) {
    if (text.trim().isEmpty) return const SizedBox.shrink();
    final body = color ?? Aether.text;
    return SelectableText(
      text,
      style: TextStyle(
        fontSize: fontSize,
        height: (fontSize + 10) / fontSize,
        color: ovidFontColor(colorAttr) ?? body,
      ),
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
      builders: {'code': _OvidInlineCodeBuilder()},
      styleSheet: MarkdownStyleSheet(
        // Line-heights follow the captured reference: base 24px at 14px,
        // shifting with the content font size (24 + (size - 14)).
        p: TextStyle(
          fontSize: fontSize,
          height: (fontSize + 10) / fontSize,
          color: body,
        ),
        h1: TextStyle(
          fontSize: fontSize + 7,
          height: (fontSize + 16) / (fontSize + 7),
          fontWeight: FontWeight.w700,
          color: body,
        ),
        h2: TextStyle(
          fontSize: fontSize + 5,
          height: (fontSize + 14) / (fontSize + 5),
          fontWeight: FontWeight.w700,
          color: body,
        ),
        h3: TextStyle(
          fontSize: fontSize + 4,
          height: (fontSize + 12) / (fontSize + 4),
          fontWeight: FontWeight.w700,
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
        tableBody: TextStyle(fontSize: fontSize - 1, height: 1.4, color: body),
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
class _OvidCodeBox extends StatelessWidget {
  final String lang;
  final String code;
  const _OvidCodeBox({required this.lang, required this.code});

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
        color: Aether.codeBg,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
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
                    height: 18 / 11,
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
            padding: const EdgeInsets.all(16),
            child: _isDiff
                ? _DiffLines(code: code)
                : SelectableText(
                    code,
                    style: TextStyle(
                      fontFamily: Aether.mono,
                      fontSize: 11,
                      height: 19 / 11,
                      color: Aether.text,
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

/// Diff renderer: +/- lines green/red like web-IDE edits.
class _DiffLines extends StatelessWidget {
  final String code;
  const _DiffLines({required this.code});

  @override
  Widget build(BuildContext context) {
    final lines = code.split('\n');
    return IntrinsicWidth(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final l in lines)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1.5),
              color: l.startsWith('+')
                  ? Aether.successLight.withValues(alpha: 0.10)
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
                      ? Aether.successLight
                      : l.startsWith('-')
                      ? Aether.danger
                      : Aether.textMuted,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Inline `code` — mono, accent-colored chip.
class _OvidInlineCodeBuilder extends MarkdownElementBuilder {
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
      ),
      child: SelectableText(
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
