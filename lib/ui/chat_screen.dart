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
import '../core/cloud/agent_surface.dart';
import '../core/cloud/cloud_agent_facade.dart';
import '../core/cloud/cloud_errors.dart';
import '../core/cloud/cloud_rest.dart' show CloudApiException;
import '../core/cloud/event_projection.dart' show kArtifactRowTool;
import '../core/cloud/cloud_session_store.dart';
import '../core/cloud/models.dart';
import '../core/model_limits.dart';
import 'content_report_sheet.dart';
import '../core/format.dart';
import '../core/voice_input_service.dart';
import '../core/state.dart';
import '../core/native_share.dart';
import 'share_actions.dart';
import 'auth_screen.dart';
import 'billing_screen.dart';
import 'browser_screen.dart';
import 'sidebar.dart';
import 'settings_screen.dart';
import 'studio_screen.dart' show openStudio;
import 'subagent_screen.dart';
import 'transcript_model.dart';
import 'chat_layout.dart';
import 'html_artifact_view.dart';
import 'link_safety.dart';
import '../core/url_safety.dart';
import '../core/connection_service.dart';
import '../core/commands.dart';
import '../core/presets.dart';
import '../core/composer_drafts.dart';
import '../core/diag.dart';
import '../core/firebase_service.dart';
import '../core/ovid_cloud_service.dart';
import 'widgets/aether_confirm.dart';
import 'widgets/aether_primitives.dart';
import 'widgets/attachment_tiles.dart';
import 'chat_overflow_menu.dart';
import 'artifact_preview.dart';
import '../core/session_artifacts.dart';
import '../l10n/l10n.dart';
import 'widgets/chat_tool_visuals.dart';
import 'widgets/code_highlight.dart';

/// Composer/attachment cap. The local service owned this constant; it is a
/// plain UI limit now that the thin client uploads to the server.
const _maxChatAttachments = 20;

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

  // A new scaler is built on every rebuild; value equality keeps MediaQuery
  // from treating that as a text-scale change that relayouts every message.
  @override
  bool operator ==(Object other) =>
      other is _ChatTextScaler &&
      other.inherited == inherited &&
      other.zoom == zoom;

  @override
  int get hashCode => Object.hash(inherited, zoom);
}

/// P8 Task 19 — the cloud facade is the only agent implementation.
AgentSurface get _agent => CloudAgentFacade.I;

class ChatTranscript extends StatefulWidget {
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

  /// Transcript build counter for rebuild-scope tests (debug builds only).
  @visibleForTesting
  static int debugBuildCount = 0;

  @override
  State<ChatTranscript> createState() => _ChatTranscriptState();
}

class _ChatTranscriptState extends State<ChatTranscript> {
  /// Cumulative number of folded items requested; grows by one page per
  /// "Load earlier" tap so the start of a long child run stays reachable.
  int _visibleCount = _subagentTranscriptPage;

  @override
  void didUpdateWidget(covariant ChatTranscript oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.session.id != widget.session.id) {
      _visibleCount = _subagentTranscriptPage;
    }
  }

  void _loadEarlier() {
    setState(() => _visibleCount += _subagentTranscriptPage);
  }

  @override
  Widget build(BuildContext context) {
    final session = widget.session;
    final scrollController = widget.scrollController;
    final typing = widget.typing;
    // Structural changes and tool output arrive through AppState; streamed
    // text through this session's own live ticks. Agent-wide notifications
    // and other sessions' streams no longer rebuild the transcript (busy and
    // typing come from the parent).
    return AnimatedBuilder(
      animation: Listenable.merge([
        AppState.I,
        _agent.liveBubbleTicksFor(session.id),
      ]),
      builder: (_, _) {
        assert(() {
          ChatTranscript.debugBuildCount++;
          return true;
        }());
        final layout = ChatLayout(
          viewportWidth: MediaQuery.sizeOf(context).width,
        );
        final window = windowForBounded(
          session.messages,
          pageSize: _subagentTranscriptPage,
          visibleCount: _visibleCount,
          showReasoning: AppState.I.showReasoning,
        );
        final items = window.visible;
        // The subagent transcript is paged; when older rows are omitted,
        // offer "Load earlier" instead of silently truncating the history.
        final showOlder = window.hasEarlier;
        final count = items.length + (showOlder ? 1 : 0) + (typing ? 1 : 0);
        final list = ListView.builder(
          controller: scrollController,
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
          itemCount: count,
          itemBuilder: (_, i) {
            if (showOlder && i == 0) {
              return _OlderMessagesIndicator(
                hiddenMessages: window.hiddenMessages,
                onLoadEarlier: _loadEarlier,
              );
            }
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
///
/// [fromUser] rows (the message the user just sent) slide in from the right
/// with a slight scale-up, the way the Claude app "drops" a sent bubble into
/// the thread; assistant rows rise from below.
class _RowIn extends StatefulWidget {
  final Widget child;
  final bool fromUser;
  const _RowIn({required this.child, this.fromUser = false});
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
    final slid = SlideTransition(
      position: Tween<Offset>(
        begin: widget.fromUser
            ? const Offset(0.05, 0.02)
            : const Offset(0, 0.04),
        end: Offset.zero,
      ).animate(curved),
      child: widget.child,
    );
    return FadeTransition(
      opacity: curved,
      child: widget.fromUser
          ? ScaleTransition(
              alignment: Alignment.bottomRight,
              scale: Tween<double>(begin: 0.96, end: 1).animate(curved),
              child: slid,
            )
          : slid,
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
      fromUser: item.m.role == 'user',
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

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([AppState.I, _agent]),
      builder: (_, _) {
        final s = AppState.I.activeSession;
        if (s == null) return const SizedBox.shrink();
        final analytics = s.analytics;
        // footer ring — % of THIS model's context window in use,
        // measured from the last billed promptTokens (exact) or the
        // chars/4 heuristic fallback.
        final window = ModelLimits.effectiveContextWindow(
          AppState.I.contextWindowOverride,
          ModelLimits.contextWindowFor(s.model, s.providerId),
        );
        final used = analytics.contextTokens > 0
            ? analytics.contextTokens
            : _agent.measuredContextTokens(s);
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
                        'cached ${analytics.cachedPercent.toStringAsFixed(0)}%',
                      if (analytics.averageTtftMs > 0)
                        'ttft ~${analytics.averageTtftMs} ms',
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
                  _analyticsMetric(
                    'Cached',
                    a.cacheReadTokens > 0 || a.cacheWriteTokens > 0
                        ? '${a.cachedPercent.toStringAsFixed(0)}% of input tokens'
                        : '—',
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
                ],
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
    final agent = _agent;
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
  const ChatScreen({super.key});

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

  /// True while a composer slash command is executing. Guards against a
  /// double Send running `/compact`, `/clear` or `/new` twice and drives the
  /// Send button's busy state.
  bool _executingCommand = false;
  String? _draftBindScheduledFor;

  void _recordDraftEdit() {
    if (_observedDraftText == _input.text) return;
    _observedDraftText = _input.text;
    final sid = _boundSessionId;
    if (sid != null && !_restoringDraft) {
      _draftVersions[sid] = (_draftVersions[sid] ?? 0) + 1;
      // Mirror to durable storage (debounced) so a long prompt survives
      // process death, a phone call or the OS reclaiming the app.
      ComposerDraftStore.I.put(sid, _input.text);
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
    ComposerDraftStore.I.remove(sid);
  }

  // ── Lazy message paging (ChatGPT/Claude style) ──
  // Long threads render ONLY the last [_visibleCount] folded items; a
  // "Load earlier" row at the top pulls in older history on demand, so a
  // 500-message chat never lags the phone (or re-builds on every token).
  static const _pageSize = 40;
  int _visibleCount = _pageSize;
  bool _paging = false; // blocks re-entrant top-of-list pagination
  bool _hasEarlier = false; // older messages exist above the visible window
  int _hiddenMessages = 0; // raw messages folded above the visible window

  // ── Older server pages (chat P1: history past the first page) ──
  // The pager above widens ONLY the in-memory window; once the newest
  // server page is fully revealed, `_hasEarlier` goes false even though the
  // server holds older pages — a 500-message chat was unreachable past the
  // first 50. When the in-memory reserve is about to exhaust (or already
  // has), the next server page is fetched ONE page at a time through the
  // store's `before:` path (prepend + offline cache write); the projection
  // grows above the visible window and the keyed anchor absorbs the shift.
  bool _loadingEarlier = false; // single-flight: one server page in flight
  bool _canPageServer = false; // active chat may hold an older server page

  /// Session ids whose older-page fetch came back empty: the server's
  /// beginning is loaded, so the pager stops hitting the wire.
  final Set<String> _serverTranscriptComplete = <String>{};

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
    // Restore incoming session's draft (memory first, then the durable copy
    // written before the process was last killed).
    final draft =
        _drafts[sessionId] ?? ComposerDraftStore.I.draftFor(sessionId) ?? '';
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

  @override
  void initState() {
    super.initState();
    // The local approval gate (and its UI-mounted counter) died with the
    // retired service; server approvals are resolved by the facade.
    _input.addListener(_recordDraftEdit);
    _scroll.addListener(_onScroll);
    _fallbackNotice = AppState.I.ovidCloudModelFallbackNotice
      ..addListener(_showModelFallbackNotice);
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _showModelFallbackNotice(),
    );
    unawaited(
      ComposerDraftStore.I.load().then((_) => _restorePersistedDraft()),
    );
    ConnectionService.I.addListener(_onConnectivityForHistory);
    unawaited(_bootCloud());
  }

  /// CH-035: a history page that failed while offline (or on a transient
  /// 5xx) is retried as soon as Ovid is reachable again — never a
  /// permanent empty chat.
  bool _wasOfflineForHistory = false;
  void _onConnectivityForHistory() {
    final offline = ConnectionService.I.offline;
    final cameBack = _wasOfflineForHistory && !offline;
    _wasOfflineForHistory = offline;
    if (!cameBack || !mounted) return;
    final active = AppState.I.activeSessionId;
    if (active != null && _cloudTranscriptsFailed.contains(active)) {
      unawaited(_loadCloudTranscript(active, force: true));
    }
  }

  /// P8 Task 10 boot path (binding carries from Task 9):
  ///
  ///  * await [CloudSessionStore.ready] — the sync getters are empty until
  ///    the persisted map/outbox load completes;
  ///  * flush the outbox AFTER ready, unconditionally — the facade only
  ///    flushes on a TRUE→FALSE offline EDGE, so a launch that is ALREADY
  ///    online would otherwise strand a persisted outbox (I-2);
  ///  * reconcile the session list while online (server rows become
  ///    ChatSessions, the sidebar reads them);
  ///  * load the active session's transcript, which also refreshes the
  ///    offline READ CACHE so a cold start shows the latest turn.
  Future<void> _bootCloud() async {
    final store = CloudSessionStore.I;
    await store.ready;
    if (!mounted) return;
    unawaited(store.flushOutbox());
    if (!store.offline) {
      try {
        await store.refreshSessions();
      } catch (e) {
        Diag.swallow('chat_screen.bootCloud', e);
      }
      // SE-005 / R1: the server enforces the Settings memory switches on
      // every run — make sure it has the user's current choice.
      unawaited(CloudAgentFacade.I.syncPreferences());
    }
    if (!mounted) return;
    final active = AppState.I.activeSessionId;
    if (active != null) unawaited(_loadCloudTranscript(active));
  }

  /// Server transcripts already loaded in this screen instance — live WS
  /// events keep them fresh after the first page.
  final Set<String> _cloudTranscriptsLoaded = <String>{};

  /// First history pages that FAILED (offline, 5xx): the chat shows
  /// "Couldn't load this chat" with Retry instead of an empty chat (CH-035).
  final Set<String> _cloudTranscriptsFailed = <String>{};

  /// First history pages in flight (the chat shows a loading state).
  final Set<String> _cloudTranscriptsLoading = <String>{};

  /// Pages the active session's transcript through the store (seed + cache
  /// write). Marked loaded only on success; a failure for a known server
  /// session is remembered and retried (Retry button, reconnect). A
  /// local-only session (never sent) has no server transcript.
  Future<void> _loadCloudTranscript(String sessionId, {bool force = false}) async {
    if (!mounted) return;
    if (!force && _cloudTranscriptsLoaded.contains(sessionId)) return;
    if (!_cloudTranscriptsLoading.add(sessionId)) return;
    final store = CloudSessionStore.I;
    var known = false;
    try {
      await store.ready;
      known = store.knownServerIdFor(sessionId) != null;
      final serverId = store.serverIdFor(sessionId) ?? sessionId;
      await store.loadTranscript(serverId);
      _cloudTranscriptsLoaded.add(sessionId);
      _cloudTranscriptsFailed.remove(sessionId);
    } catch (e) {
      Diag.swallow('chat_screen.loadCloudTranscript', e);
      if (known) {
        _cloudTranscriptsFailed.add(sessionId);
      } else {
        // A chat that never reached the server has no history to load.
        _cloudTranscriptsLoaded.add(sessionId);
      }
    } finally {
      _cloudTranscriptsLoading.remove(sessionId);
      if (mounted) setState(() {});
    }
  }

  /// EM-010: one pending auto-create at a time.
  bool _autoSessionScheduled = false;

  /// Fetches the next OLDER server page for the active session's transcript
  /// (chat P1: history past the first server page was unreachable — the
  /// pager only widened the in-memory window). One page per call,
  /// single-flight via [_loadingEarlier]; the store's `before:` path
  /// prepends into the projection and the offline cache, and the window
  /// cache re-folds over the grown list so the pager keeps widening.
  ///
  /// The `before` cursor is the oldest loaded server row's id (the wire
  /// takes a message UUID). Local-only chats, offline, and transcripts
  /// already paged to the server's beginning decline without a request.
  Future<void> _loadEarlierServerPage() async {
    if (_loadingEarlier) return;
    final sessionId = AppState.I.activeSessionId;
    if (sessionId == null) return;
    if (!_cloudTranscriptsLoaded.contains(sessionId)) return;
    if (_serverTranscriptComplete.contains(sessionId)) return;
    final store = CloudSessionStore.I;
    await store.ready;
    // Re-check after the await: the user may have switched sessions, and a
    // scroll-event burst may have raced a second call past the entry guard
    // while this one was suspended (both then set the flag below).
    if (_loadingEarlier) return;
    if (AppState.I.activeSessionId != sessionId) return;
    // Offline: paging needs the REST link — skip silently (nothing to show
    // rather than an error); the next top-of-list approach retries.
    if (store.offline) return;
    final serverId = store.knownServerIdFor(sessionId);
    if (serverId == null) return; // local-only chat: no server history
    final loaded = CloudAgentFacade.I.transcriptFor(serverId);
    if (loaded == null || loaded.isEmpty) return;
    // Rich rows (tool cards, segments, chips) carry no server id: the
    // cursor is the oldest SERVER message (Wave 1b).
    final before = CloudAgentFacade.I.oldestServerMessageId(serverId);
    if (before == null) return;

    _loadingEarlier = true;
    if (mounted) setState(() {}); // "Loading earlier…" affordance row
    // Keyed anchor across the async prepend: capture the top visible row
    // now, restore it after the page lands (Task 7 machinery, plus the
    // index shift a prepend causes — see [_restoreAnchor]).
    final anchor = _captureTopAnchor();
    final head = loaded.first; // identity marker: measures the prepend
    var failed = false;
    try {
      await store.loadTranscript(serverId, before: before);
    } catch (e) {
      // The loaded window is untouched (the store prepends only on
      // success): the chat stays usable and a later top-of-list approach
      // retries.
      failed = true;
      Diag.swallow('chat_screen.loadEarlierServerPage', e);
    }
    final after =
        CloudAgentFacade.I.transcriptFor(serverId) ?? const <Message>[];
    if (!failed && (after.isEmpty || CloudAgentFacade.I.oldestServerMessageId(serverId) == before)) {
      // Nothing older came back: the server's beginning is loaded.
      _serverTranscriptComplete.add(sessionId);
    }
    // A prepend shifts every loaded row's absolute index — and with it the
    // anchor key — by exactly the number of prepended messages.
    var keyShift = 0;
    for (var i = 0; i < after.length; i++) {
      if (identical(after[i], head)) {
        keyShift = i;
        break;
      }
    }
    if (mounted) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        // Never fight a session switch: the rows on screen belong to
        // whatever chat is active now.
        if (!mounted || AppState.I.activeSessionId != sessionId) return;
        _restoreAnchor(anchor, keyShift: keyShift);
      });
    }
    _loadingEarlier = false;
    if (mounted) setState(() {}); // drop the affordance / spinner
  }

  ValueNotifier<String?>? _fallbackNotice;

  /// One-time "`model` is no longer available — switched to Auto".
  void _showModelFallbackNotice() {
    final notice = _fallbackNotice;
    final message = notice?.value;
    if (!mounted || notice == null || message == null) return;
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) return;
    notice.value = null;
    messenger.showSnackBar(SnackBar(content: Text(message)));
  }

  /// Applies the durable draft once it has loaded, unless the user already
  /// started typing or the session's draft is held in memory.
  void _restorePersistedDraft() {
    final sid = _boundSessionId;
    if (!mounted || sid == null || _drafts.containsKey(sid)) return;
    if (_input.text.isNotEmpty) return;
    final draft = ComposerDraftStore.I.draftFor(sid);
    if (draft == null || draft.isEmpty) return;
    _restoringDraft = true;
    _input.value = TextEditingValue(
      text: draft,
      selection: TextSelection.collapsed(offset: draft.length),
    );
    _restoringDraft = false;
  }

  @override
  void dispose() {
    ConnectionService.I.removeListener(_onConnectivityForHistory);
    _fallbackNotice?.removeListener(_showModelFallbackNotice);
    unawaited(ComposerDraftStore.I.flush());
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
    if (!_paging && pos.pixels < 120 && (_hasEarlier || _canPageServer)) {
      if (!_hasEarlier) {
        // The in-memory window is exhausted; the server may still hold
        // older pages (the guard chain inside declines local-only chats,
        // offline, and completed transcripts without touching the wire).
        unawaited(_loadEarlierServerPage());
        return;
      }
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
        // This widen consumes the last of the in-memory reserve — start the
        // next server page NOW so the prepend lands before the user hits
        // the dead end (single-flight inside; no prefetch storm).
        if (_hiddenMessages <= _pageSize) {
          unawaited(_loadEarlierServerPage());
        }
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _restoreAnchor(anchor);
          _paging = false;
        });
      });
    }
  }

  /// The transcript list the chat renders (P8 Task 10): the facade's live
  /// projection — cloud sessions keep `ChatSession.messages` empty, so
  /// message actions that mutate local history decline gracefully
  /// (`_canChangeHistory` finds no rows).
  List<Message> _messagesOf(ChatSession s) =>
      CloudAgentFacade.I.transcriptFor(s.id) ?? s.messages;

  /// The bounded folded window for [s], recomputed only when its inputs
  /// change (Task 4). Streaming token appends mutate the live message in
  /// place, so the identity/last-kind checks keep the cache warm across
  /// tokens and the full history is never re-folded.
  TranscriptWindow _transcriptWindow(ChatSession s) {
    final showReasoning = AppState.I.showReasoning;
    final compact = !AppState.I.conversationFull;
    final messages = _messagesOf(s);
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
  /// its first message. A server-page prepend shifts every loaded row's
  /// index by the number of prepended messages, so a key captured before a
  /// prepend must be restored at `key + shift` — see [_restoreAnchor].
  Object _itemKey(ChatItem item) =>
      item is SingleItem ? item.index : (item as FoldedGroup).indices.first;

  /// The top-of-list paging affordance: "N earlier messages · scroll up"
  /// while folded rows sit above the window, spinner + "Loading earlier…"
  /// while the in-memory widen or an older server page is loading — the
  /// spinner shows only while a page is actually loading (it used to spin
  /// forever in any long thread). An exhausted in-memory window renders the
  /// row only while its older server page is in flight, never as a dead end.
  Widget _pagingAffordanceRow(int hiddenMessages) {
    final loadingEarlier = _paging || _loadingEarlier;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (loadingEarlier) ...[
              SizedBox(
                width: 12,
                height: 12,
                child: CircularProgressIndicator(
                  strokeWidth: 1.5,
                  color: Aether.textFaint,
                ),
              ),
              const SizedBox(width: 6),
            ] else ...[
              Icon(
                Icons.keyboard_arrow_up_rounded,
                size: 14,
                color: Aether.textFaint,
              ),
              const SizedBox(width: 4),
            ],
            Text(
              loadingEarlier
                  ? 'Loading earlier…'
                  : '$hiddenMessages earlier '
                        'message${hiddenMessages == 1 ? '' : 's'} '
                        '· scroll up',
              style: TextStyle(fontSize: 11, color: Aether.textFaint),
            ),
          ],
        ),
      ),
    );
  }

  /// Row keys for the window currently rendered. Row 0 is the paging
  /// affordance when it is shown (folded history or an older server page in
  /// flight); the tail row is the typing/produced card. Message rows carry
  /// their [_itemKey].
  List<Object> _computeRowKeys(
    TranscriptWindow window,
    bool typing,
    bool showProduced, {
    bool showAffordance = false,
  }) {
    final keys = <Object>[];
    if (showAffordance) keys.add(_affordanceRowKey);
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
  ///
  /// [keyShift] is the number of messages a server-page prepend inserted
  /// above the window: keys are absolute message indices, so the anchor
  /// row's key moved by exactly that many (the widen path passes 0 —
  /// growing [_visibleCount] never changes indices).
  void _restoreAnchor(_ScrollAnchor? anchor, {int keyShift = 0}) {
    if (anchor == null || !mounted || !_scroll.hasClients) return;
    final key = _shiftedAnchorKey(anchor.key, keyShift);
    final offset = _anchorLayoutOffset(key);
    if (offset != null) {
      _jumpToOffset(offset - anchor.viewportOffset);
      return;
    }
    transcriptAnchorFallbackObserver?.call();
    final delta = _scroll.position.maxScrollExtent - anchor.maxScrollExtent;
    _jumpToOffset(anchor.pixels + delta);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      final retry = _anchorLayoutOffset(key);
      if (retry != null) _jumpToOffset(retry - anchor.viewportOffset);
    });
  }

  /// The anchor key rebased onto the shifted indices a prepend produced.
  /// Non-message keys (affordance / tail sentinels) never shift.
  Object _shiftedAnchorKey(Object key, int keyShift) =>
      keyShift > 0 && key is int ? key + keyShift : key;

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
      animation: Listenable.merge([app, _agent]),
      builder: (_, _) {
        final s = app.activeSession;
        // EM-010: a signed-in user always has a chat to type into. A fresh
        // account (or a deleted active chat) gets a new local chat on the
        // spot; the server session is created by the first send.
        if (s == null && app.sessionAccountReady && !_autoSessionScheduled) {
          _autoSessionScheduled = true;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            _autoSessionScheduled = false;
            if (!mounted) return;
            final a = AppState.I;
            if (a.activeSession == null && a.sessionAccountReady) {
              a.newSession();
            }
          });
        }
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
            // CH-014: the chat we are leaving drops its live subscription
            // (once its work settles); the one we open (re)subscribes.
            final previous = _boundSessionId;
            if (previous != null && previous != s.id) {
              CloudAgentFacade.I.releaseSession(previous);
            }
            CloudAgentFacade.I.activateSession(s.id);
            _bindDraft(s.id);
            // Thin client: the newly active session's server transcript is
            // paged (seed + offline cache write) the first time it opens.
            unawaited(_loadCloudTranscript(s.id));
          });
        }
        final wide = MediaQuery.sizeOf(context).width >= 840;
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
            // A11Y: a labelled button with a 48dp-tall hit area.
            title: Semantics(
              button: true,
              label: 'Change model',
              child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => _modelPicker(context),
              child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 48, minWidth: 48),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Flexible(
                    child: Text(
                      // Never "Select model" (owner directive 2026-10-18):
                      // an empty/sentinel model means Auto is in effect.
                      s?.model == null ||
                              s!.model.trim().isEmpty ||
                              s.model == 'Select a provider'
                          ? 'Auto'
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
              ),
            ),
            // Exactly three header actions (owner ask): Studio, Browser and
            // a ⋮ overflow that holds everything else the header used to
            // show (share, new chat, background jobs) plus the chat-level
            // actions (rename, artifacts, trajectory, usage, delete).
            actions: [
              IconButton(
                key: const ValueKey('chat-header-studio'),
                tooltip: context.l10n.chatHeaderStudio,
                icon: const Icon(Icons.code, size: 19),
                onPressed: () => openStudio(context),
              ),
              // Browser button — P8 Task 16: the on-device WebView browser is
              // gone, so this always opens the cloud screencast viewer.
              IconButton(
                key: const ValueKey('chat-header-browser'),
                tooltip: context.l10n.chatHeaderBrowser,
                icon: const Icon(Icons.public, size: 19),
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => BrowserScreen(sessionId: s?.id),
                  ),
                ),
              ),
              ChatOverflowMenu(
                session: s,
                onJobs: (id) => _showJobsPopover(context, id),
              ),
              const SizedBox(width: 4),
            ],
          ),
          body: SafeArea(
            child: LayoutBuilder(
              builder: (context, constraints) {
                // The pane width already excludes the persistent sidebar when
                // the shell renders it (ChatScreen lives in the Expanded slot),
                // so the shared axis is derived from the actual chat pane.
                final layout = ChatLayout(viewportWidth: constraints.maxWidth);
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
                    // The offline prompt outbox chip and the cloud
                    // error-envelope row (402/409/503).
                    _CloudOutboxChip(
                      sessionId: AppState.I.activeSessionId,
                    ),
                    _CloudErrorRow(
                      sessionId: AppState.I.activeSessionId,
                      onRetry: _retryFailedCloudPrompt,
                      onPickModel: () => _modelPicker(context),
                    ),
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
                            _agent.pendingAttachments.isNotEmpty) {
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
                    Expanded(
                      child: LayoutBuilder(
                        builder: (context, chatConstraints) => Column(
                          children: [
                            Expanded(
                              child: s == null || _messagesOf(s).isEmpty
                                  ? (s != null &&
                                          _cloudTranscriptsFailed
                                              .contains(s.id)
                                      ? _HistoryLoadFailed(
                                          loading: _cloudTranscriptsLoading
                                              .contains(s.id),
                                          onRetry: () => unawaited(
                                            _loadCloudTranscript(
                                              s.id,
                                              force: true,
                                            ),
                                          ),
                                        )
                                      : const _EmptyState())
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
                                              animation: _agent,
                                              builder: (_, _) {
                                                final typing =
                                                    _agent.busyFor(s.id);
                                                // Bounded, cached fold (Task 4): the
                                                // folded window is reused across streaming
                                                // tokens; only the message count / last
                                                // message identity / showReasoning / pager
                                                // window can invalidate it.
                                                final window =
                                                    _transcriptWindow(s);
                                                _hasEarlier = window.hasEarlier;
                                                _hiddenMessages =
                                                    window.hiddenMessages;
                                                // Older server pages exist as
                                                // soon as the in-memory window
                                                // runs dry — the fetch itself
                                                // re-checks offline / cursor /
                                                // completeness.
                                                _canPageServer =
                                                    _cloudTranscriptsLoaded
                                                        .contains(s.id) &&
                                                    !_serverTranscriptComplete
                                                        .contains(s.id);
                                                final hiddenMessages =
                                                    window.hiddenMessages;
                                                final items = window.visible;
                                                // "Produced" card — files written by
                                                // this run surface as a card under the
                                                // final answer (tap → Studio).
                                                // P8 Task 10: on-device
                                                // workspace files only — the
                                                // thin client has no local
                                                // produced-files channel (the
                                                // `hostDirOf` share action
                                                // below is unreachable there).
                                                // Produced files are a
                                                // local-workspace concept and
                                                // the thin client has none
                                                // (P8 Task 19).
                                                final produced = const <({
                                                  String path,
                                                  int size
                                                })>[];
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
                                                // The paging affordance also
                                                // renders while an older
                                                // server page is in flight, so
                                                // an exhausted in-memory
                                                // window shows "Loading
                                                // earlier…" instead of a dead
                                                // end at the top of the list.
                                                final showAffordance =
                                                    hiddenMessages > 0 ||
                                                    _loadingEarlier;
                                                final count =
                                                    (showAffordance
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
                                                  showAffordance: showAffordance,
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

                                                    // Next row: paging affordance
                                                    // (see
                                                    // [_pagingAffordanceRow]).
                                                    if (showAffordance &&
                                                        idx == 0) {
                                                      return KeyedSubtree(
                                                        key: rowKey,
                                                        child:
                                                            _pagingAffordanceRow(
                                                          hiddenMessages,
                                                        ),
                                                      );
                                                    }
                                                    final li =
                                                        showAffordance
                                                        ? idx - 1
                                                        : idx;
                                                    if (li == items.length) {
                                                      return KeyedSubtree(
                                                        key: rowKey,
                                                        child: typing
                                                            ? const _TypingBubble()
                                                            : _RowIn(
                                                                child: _ProducedFilesCard(
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
                                                          animation:
                                                              Listenable.merge([
                                                                AppState.I,
                                                                _agent
                                                                    .liveBubbleTicksFor(
                                                                        s.id),
                                                              ]),
                                                          builder: (_, _) {
                                                            // Streaming ticks rebuild only
                                                            // this row, so keep following
                                                            // the tip from here too.
                                                            _maybeFollowTip();
                                                            return _buildItem(
                                                              item,
                                                              s,
                                                              onAction: () =>
                                                                  setState(
                                                                    () {},
                                                                  ),
                                                              input: _input,
                                                              layout: layout,
                                                            );
                                                          },
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
                                                  child: Padding(
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
                                      (_agent.pendingApproval != null
                                          ? 0.45
                                          : 0.30),
                                ),
                              ),
                              child: SingleChildScrollView(
                                // A new request starts at the top, even if the user
                                // previously scrolled through queued work.
                                key: ObjectKey(_agent.pendingApproval),
                                child: Center(
                                  child: ConstrainedBox(
                                    constraints: BoxConstraints(
                                      maxWidth: layout.contentWidth,
                                    ),
                                    // Blocking decisions take priority over passive
                                    // status and queued work in this bounded area.
                                    // The dock renders for the foreground
                                    // session's own prompt OR a background
                                    // session's (its elsewhere row switches to
                                    // that chat, where the card renders).
                                    child:
                                        (_agent.pendingApproval != null ||
                                                _agent
                                                    .pendingApprovalsElsewhere
                                                    .isNotEmpty)
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
                              running: s == null
                                  ? false
                                  : _agent.busyFor(s.id),
                              // approval takeover parity: a pending approval LOCKS
                              // the composer — the user answers the card, not the box.
                              locked: _agent.pendingApproval != null,
                              editingQueue: _queueEdits.containsKey(s?.id),
                              commandBusy: _executingCommand,
                              onCancelQueueEdit: () => setState(() {
                                _queueEdits.remove(s?.id);
                              }),
                              onSend: () async {
                                if (s == null ||
                                    _boundSessionId != s.id ||
                                    AppState.I.activeSessionId != s.id ||
                                    _agent.pendingApproval != null ||
                                    _executingCommand) {
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
                                  final agent = _agent;
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
                                  setState(() => _executingCommand = true);
                                  final CommandResult? result;
                                  try {
                                    result = await CommandService.I.execute(t);
                                  } finally {
                                    if (mounted) {
                                      setState(() => _executingCommand = false);
                                    }
                                  }
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
                                  // Unknown /command falls through to the agent.
                                }

                                // ── web-IDE busy behavior: typing while running either
                                // queues the message (default) or interrupts the current
                                // run and sends immediately, per the user's setting.
                                // `busyFor` also covers a send whose POST has not
                                // landed yet, so a double-tap queues instead of
                                // dispatching a second run (double spend). ──
                                var interrupt = false;
                                if (_agent.busyFor(s.id)) {
                                  if (AppState.I.sendWhileBusyInterrupt) {
                                    // CH-044: stop the current run AND send
                                    // now — the server queues this run right
                                    // behind the one being cancelled.
                                    _agent.stopRequested(
                                      sessionId: s.id,
                                    );
                                    interrupt = true;
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
                                    interrupt: interrupt,
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
    final sessionId = AppState.I.activeSessionId;
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
                title: Text(
                  m.label,
                  style: TextStyle(
                    fontSize: 13.5,
                    color: _skipsApprovals(m) ? Aether.dangerC : null,
                  ),
                ),
                subtitle: _accessModeSubtitle(
                  m,
                  TextStyle(fontSize: 11, color: Aether.textMuted),
                ),
                trailing: _agent.mode == m
                    ? Icon(Icons.check, size: 16, color: Aether.accent)
                    : null,
                onTap: () async {
                  Navigator.pop(context);
                  await _pickAccessMode(context, m, sessionId);
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
                      ? Icon(Icons.check, size: 16, color: Aether.accent)
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
  /// Capture the originating session before that notification: a picker
  /// completion or session switch must not change what this send consumes.
  bool _enqueuePrompt(ChatSession session, String text) {
    final app = AppState.I;
    if (!app.sessionAccountReady ||
        app.activeSessionId != session.id ||
        !identical(app.sessionById(session.id), session)) {
      return false;
    }
    final agent = _agent;
    final previousIds = agent.queuedMessageIdsFor(session.id).toSet();
    agent.enqueueMessage(text, sessionId: session.id);
    // enqueue can reject admission. Never clear a rejected draft.
    if (!agent
        .queuedMessageIdsFor(session.id)
        .any((id) => !previousIds.contains(id))) {
      return false;
    }
    // The facade owns the staged-file transfer: enqueue snapshots the
    // composer's files onto the queued row ("the queued message keeps its
    // original attachments") and clears its staging list, so anything
    // staged afterwards belongs to the next message.
    app.refresh();
    return true;
  }

  void _sendPrompt(
    BuildContext context,
    ChatSession? s,
    String t, {
    VoidCallback? onAccepted,
    bool interrupt = false,
  }) {
    final app = AppState.I;
    final session = s;
    if (session == null ||
        app.activeSessionId != session.id ||
        !identical(app.sessionById(session.id), session)) {
      return;
    }
    // P8 Task 20: the local provider/run arm is gone. There is no local
    // provider validation — the run is admitted server-side and the facade
    // owns staging.
    unawaited(_sendCloudPrompt(session, t,
        onAccepted: onAccepted, interrupt: interrupt));
  }

  /// Sessions the user @-tagged in [text] (`@[Chat title]`, inserted by the
  /// @ menu): their server ids ride the send so the agent sees THOSE chats'
  /// context for this turn only (owner rule R1). Unsynced chats are skipped;
  /// the server also resolves the tag by title.
  static List<String> sessionRefsIn(String text, String currentSessionId) {
    final store = CloudSessionStore.I;
    final refs = <String>[];
    for (final match in _sessionTag.allMatches(text)) {
      final title = match.group(1)!.trim().toLowerCase();
      for (final candidate in AppState.I.sessions) {
        if (candidate.id == currentSessionId) continue;
        if (candidate.title.trim().toLowerCase() != title) continue;
        final serverId = store.knownServerIdFor(candidate.id);
        if (serverId != null && !refs.contains(serverId)) refs.add(serverId);
      }
      if (refs.length >= 5) break;
    }
    return refs;
  }

  static final RegExp _sessionTag = RegExp(r'@\[([^\]\n]{1,120})\]');

  /// Cloud send path. The facade shows the prompt as a pending row at once
  /// and makes it durable in the outbox before anything touches the
  /// network, so the composer clears as soon as the prompt is safe
  /// (`onQueued`) — never lost on a timeout, 429, 401 or process death
  /// (CH-009, CH-011). Failures render on the row ("Not sent" + Retry) and
  /// in the error row with the right action.
  Future<void> _sendCloudPrompt(
    ChatSession session,
    String text, {
    VoidCallback? onAccepted,
    bool interrupt = false,
  }) async {
    final facade = CloudAgentFacade.I;
    if (!interrupt && facade.busyFor(session.id)) {
      if (_enqueuePrompt(session, text)) onAccepted?.call();
      return;
    }
    // CH-013: the first prompt titles the chat BEFORE the send, so the
    // server session is created with it (and an existing server session is
    // renamed) — the server's "New chat" never overwrites a real title.
    if (CloudSessionStore.isPlaceholderTitle(session.title)) {
      session.title = AppState.autoTitle(text);
      session.touch();
      AppState.I.refresh();
      CloudAgentFacade.renameSessionIfInstalled(session.id, session.title);
    }
    var queued = false;
    await facade.runTask(
      text,
      sessionId: session.id,
      sessionRefs: sessionRefsIn(text, session.id),
      onQueued: () {
        queued = true;
        onAccepted?.call();
        // New user message → snap to bottom so the user sees it at once.
        _atBottom = true;
        Future.delayed(const Duration(milliseconds: 80), () {
          if (_scroll.hasClients) {
            _scroll.jumpTo(_scroll.position.maxScrollExtent);
          }
        });
      },
    );
    if (!mounted) return;
    if (!queued) {
      // The prompt never left the composer (no chat yet, …): keep the
      // draft; the error row explains.
      _lastFailedCloudPrompt[session.id] = text;
    } else {
      _lastFailedCloudPrompt.remove(session.id);
    }
  }

  /// Drafts that could not even be queued, per session (CH-046 keying).
  final Map<String, String> _lastFailedCloudPrompt = <String, String>{};

  /// The error row's Retry: a refused prompt is re-delivered with its SAME
  /// clientMsgId (CH-010); a failed RUN re-sends the last prompt.
  Future<void> _retryFailedCloudPrompt() async {
    final session = AppState.I.activeSession;
    if (session == null) return;
    final facade = CloudAgentFacade.I;
    for (final entry in CloudSessionStore.I.outboxFor(session.id)) {
      if (entry.failed) {
        await facade.retryPendingSend(entry.clientMsgId);
        return;
      }
    }
    if (CloudSessionStore.I.outboxFor(session.id).isNotEmpty) {
      await CloudSessionStore.I.flushOutbox();
      return;
    }
    if (facade.canRetryLastPrompt(session.id)) {
      await facade.retryLastPrompt(session.id);
      return;
    }
    final text = _lastFailedCloudPrompt.remove(session.id);
    if (text != null) await _sendCloudPrompt(session, text);
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
        animation: _agent,
        builder: (_, _) {
          final jobs = _agent.jobsFor(sessionId);
          return SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
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
                                      onPressed: () => _agent
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
        // `auto` is a server-side alias and the last-good catalog is
        // persisted, so both stay visible whatever the connection state.
        final cloudModels = managed == null
            ? const <String>[]
            : <String>{'auto', ...managed.models}.toList();
        final showCloud =
            managed != null &&
            (q.isEmpty ||
                _matchesQuery(q, managed.name) ||
                cloudModels.any((m) => _matchesQuery(q, m)));
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
        // the Ovid Cloud catalog.
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
              !cloudModels.contains(r.model.split('·').first.trim())) {
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
                            models: cloudModels,
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
    required List<String> models,
    required String q,
  }) {
    final ready = connection.status == CloudConnectionStatus.ready;
    final failed = connection.status == CloudConnectionStatus.failed;
    // Only a mint in flight makes the key (and so every row) unusable.
    final selectable = connection.status != CloudConnectionStatus.connecting;
    final filtered = models
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
        if (failed) ...[
          const SizedBox(height: 4),
          Text(
            'Catalog may be out of date · Retry',
            key: const ValueKey('cloud-catalog-stale'),
            style: AetherType.caption,
          ),
        ],
        if (!ready)
          Wrap(
            spacing: 8,
            children: [
              AetherGhostButton(
                key: const ValueKey('cloud-connection-retry'),
                label: connection.loading ? 'Retrying…' : 'Retry',
                icon: Icons.refresh,
                loading: connection.loading,
                onPressed: connection.loading
                    ? null
                    : () => unawaited(cloud.ensureConnected(app: app)),
              ),
              if (connection.mintStatus == MintStatus.sessionExpired)
                AetherGhostButton(
                  key: const ValueKey('cloud-connection-sign-out'),
                  label: 'Sign out',
                  icon: Icons.logout,
                  onPressed: () {
                    Navigator.pop(context);
                    unawaited(FirebaseService.I.signOut());
                  },
                ),
            ],
          ),
        if (filtered.isNotEmpty) ...[
          const SizedBox(height: 12),
          Divider(height: 1, thickness: 1, color: Aether.hairline),
          const SizedBox(height: 4),
          for (final model in filtered)
            _ModelTile(
              providerId: managed.id,
              model: model,
              enabled: selectable,
            ),
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
          AetherPill(label: 'MANAGED', color: Aether.accent),
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
          AetherPill(label: 'KEY', color: Aether.accent),
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
  final bool enabled;
  const _ModelTile({
    required this.providerId,
    required this.model,
    this.isRecent = false,
    this.enabled = true,
  });

  static const variants = ['Low', 'Medium', 'High'];

  bool get supportsEffort => modelSupportsReasoningEffort(model);

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
        ? AetherPill(label: 'Auto', color: Aether.accent)
        : AetherPill(label: 'Manual', color: Aether.textMuted);

    Widget buildCurrentBadge() {
      return Container(
        margin: const EdgeInsets.only(right: 6),
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          color: Aether.accentSoft,
          borderRadius: BorderRadius.circular(4),
        ),
        child: Text(
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
          enabled: enabled,
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
              ? Icon(Icons.check, size: 18, color: Aether.accent)
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
          enabled: enabled,
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
                        style: TextStyle(
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
                      color: Aether.signalRed,
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
                    'Ask, research, build. Ovid works on it in the cloud.',
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

/// Session-local thinking timeline of a live bubble.
///
/// The agent streams reasoning into the SAME message that later becomes the
/// answer, so once the answer starts the reasoning text is no longer on the
/// message. The UI records when thinking started/ended and the last
/// reasoning text it showed, so the finished answer can keep a collapsed
/// "Thought for 6s" block above it (Claude-app parity) without changing the
/// persisted transcript shape. Lost on restart by design: persisted rows
/// carry their own reasoning messages.
class _ThinkClock {
  DateTime start;
  DateTime? end;
  String snapshot = '';
  _ThinkClock(this.start);

  static final Expando<_ThinkClock> _clocks = Expando('think-clock');

  static _ThinkClock? of(Message m) => _clocks[m];

  /// Called from the bubble's build: cheap, idempotent bookkeeping.
  static void observe(Message m) {
    final c = _clocks[m];
    if (m.thinking) {
      final clock = c ?? (_clocks[m] = _ThinkClock(DateTime.now()));
      if (m.content.isNotEmpty) clock.snapshot = m.content;
      return;
    }
    if (c != null && c.end == null) c.end = DateTime.now();
  }

  Duration? get duration => end?.difference(start);
}

/// Compact human duration for the thinking label ("4s", "1m 12s").
String _thinkDuration(Duration d) {
  final s = d.inSeconds < 1 ? 1 : d.inSeconds;
  if (s < 60) return '${s}s';
  final m = s ~/ 60;
  final r = s % 60;
  return r == 0 ? '${m}m' : '${m}m ${r}s';
}

/// Compact, default-collapsed reasoning disclosure — DSH-style geometry.
/// A 33px summary row (leading glyph · truncating title · rotating chevron)
/// expands to a hairline-separated, full-width muted body.
///
/// Claude-style states:
///   • live: chase dots + shimmering "Thinking… 4s" (seconds tick live);
///   • done: "Thought for 6s" (or "Thoughts" when the duration is unknown);
///   • the body opens/closes with a short size animation.
class _ReasoningCard extends StatefulWidget {
  final Message m;

  /// When true the card starts expanded (used for the LIVE streaming
  /// message while it thinks). Finalized rows still default to collapsed;
  /// a user tap always wins via [_ReasoningCardState._override].
  final bool expandedByDefault;

  /// Reasoning text to show instead of `m.content` (the recorded snapshot
  /// of a bubble that has since turned into the answer).
  final String? contentOverride;

  /// Thinking duration when known from the live timeline.
  final Duration? duration;
  const _ReasoningCard(
    this.m, {
    this.expandedByDefault = false,
    this.contentOverride,
    this.duration,
  });
  @override
  State<_ReasoningCard> createState() => _ReasoningCardState();
}

class _ReasoningCardState extends State<_ReasoningCard> {
  /// null = default (collapsed, unless [expandedByDefault]). Once the user
  /// taps, we lock to their choice.
  bool? _override;
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _syncTicker();
  }

  @override
  void didUpdateWidget(covariant _ReasoningCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncTicker();
  }

  /// A 1 s ticker only while thinking, so the live seconds advance even
  /// when no token arrives; stopped (and never created) otherwise.
  void _syncTicker() {
    final live = widget.m.thinking && widget.contentOverride == null;
    if (live && _tick == null) {
      _tick = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() {});
      });
    } else if (!live) {
      _tick?.cancel();
      _tick = null;
    }
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  Duration? _doneDuration() {
    if (widget.duration != null) return widget.duration;
    final m = widget.m;
    if (m.kind == MsgKind.reasoning && m.elapsedMs != null) {
      return Duration(milliseconds: m.elapsedMs!);
    }
    return _ThinkClock.of(m)?.duration;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final isStreaming = widget.m.thinking && widget.contentOverride == null;
    final expanded = _override ?? widget.expandedByDefault;
    final body = widget.contentOverride ?? widget.m.content;
    final hasBody = body.trim().isNotEmpty;
    final liveStart = _ThinkClock.of(widget.m)?.start;
    final liveLabel = liveStart == null
        ? l10n.chatThinking
        : l10n.chatThinkingFor(
            _thinkDuration(DateTime.now().difference(liveStart)),
          );
    final done = _doneDuration();
    final doneLabel = done == null
        ? l10n.chatThoughts
        : l10n.chatThoughtFor(_thinkDuration(done));
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
            child: Semantics(
              button: hasBody,
              expanded: hasBody ? expanded : null,
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
                        _ChaseDot(Aether.accent)
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
                            liveLabel,
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
                            doneLabel,
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
          ),
          // Body — full column width, muted markdown with a left rule (the
          // Claude app's thinking quote), opening with a short size tween.
          AnimatedSize(
            duration: Aether.motionFast,
            curve: Aether.ease,
            alignment: Alignment.topLeft,
            child: expanded && hasBody
                ? Container(
                    key: const ValueKey('chat-reasoning-body'),
                    width: double.infinity,
                    margin: const EdgeInsets.only(top: 8, bottom: 4, left: 7),
                    padding: const EdgeInsets.only(left: 12),
                    decoration: BoxDecoration(
                      border: Border(
                        left: BorderSide(
                          color: Aether.hairlineStrong,
                          width: 2,
                        ),
                      ),
                    ),
                    child: _OvidMarkdown(
                      content: body,
                      fontSize: 13.5,
                      color: Aether.textMuted,
                    ),
                  )
                : const SizedBox(width: double.infinity),
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

  /// Nested inside a subagent card: never re-nests a dispatch row and skips
  /// the inline artifact card (the parent card links the transcript).
  final bool nested;
  const _ToolCard(this.m, {super.key, this.nested = false});
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
    // Subagents render as a nested, collapsible card (Claude Code parity).
    if (m.toolName == 'dispatch_agent' && !widget.nested) {
      return _SubagentCard(m);
    }
    final running = m.toolState == 'running';
    if (!running && _sweep.isAnimating) _sweep.stop();
    if (running && !_sweep.isAnimating) _sweep.repeat();
    final failed = m.toolState == 'error';
    final hasDetail = (m.toolDetail ?? '').trim().isNotEmpty;
    // PR25/D3: +N/−M chip data (null for non-diff cards).
    final diffCounts = _diffCountsOf(m.toolDetail);
    // A nested dispatch row (inside a subagent card) still links its child.
    final childSessionId = m.toolSessionId;
    // A whole-file write leaves an artifact card under its row.
    final artifact = widget.nested || m.toolName != 'file_write'
        ? null
        : generatedFileArtifactOf(
            m,
            sessionId: AppState.I.activeSessionId ?? '',
            sessionTitle: AppState.I.activeSession?.title ?? '',
          );

    return Container(
      key: const ValueKey('chat-tool-disclosure'),
      margin: const EdgeInsets.only(bottom: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Compact 30px Claude-Code row: [type glyph] Title · summary
          // [+N −M] [status] [chevron]. The running glare sweep paints over
          // this row via a Stack so it never adds layout height.
          Stack(
            children: [
              Semantics(
                button: hasDetail,
                expanded: hasDetail ? _open : null,
                child: InkWell(
                  key: const ValueKey('chat-tool-summary'),
                  borderRadius: BorderRadius.circular(6),
                  onTap: hasDetail
                      ? () => setState(() => _open = !_open)
                      : null,
                  child: SizedBox(
                    height: 30,
                    child: Row(
                      children: [
                        const SizedBox(width: 10),
                        Icon(
                          chatToolIcon(m.toolName ?? ''),
                          key: ValueKey(
                            'chat-tool-icon-${chatToolFamily(m.toolName ?? '')}',
                          ),
                          size: 14,
                          color: failed ? Aether.dangerC : Aether.textMuted,
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
                                color: failed
                                    ? Aether.dangerC
                                    : Aether.textMuted,
                                fontFamily: Aether.mono,
                              ),
                            ),
                          ),
                          // PR25/D3: edit cards show a +N/−M line-count chip
                          // computed from the real diff.
                          if (diffCounts != null) ...[
                            const SizedBox(width: 6),
                            Text.rich(
                              TextSpan(
                                children: [
                                  TextSpan(
                                    text: '+${diffCounts.$1}',
                                    style: TextStyle(
                                      color: Aether.successLight,
                                    ),
                                  ),
                                  const TextSpan(text: ' '),
                                  TextSpan(
                                    text: '−${diffCounts.$2}',
                                    style: TextStyle(color: Aether.danger),
                                  ),
                                ],
                              ),
                              style: const TextStyle(
                                fontSize: 10,
                                fontFamily: Aether.mono,
                              ),
                            ),
                          ],
                        ] else
                          const Spacer(),
                        const SizedBox(width: 6),
                        ToolStatusBadge(state: m.toolState, size: 13),
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
                        // A nested subagent row links to the child's OWN
                        // session, so its full transcript stays reachable.
                        if (childSessionId != null)
                          IconButton(
                            tooltip: context.l10n.subagentOpenTranscript,
                            visualDensity: VisualDensity.compact,
                            iconSize: 14,
                            onPressed: () =>
                                SubagentScreen.open(context, childSessionId),
                            icon: Icon(Icons.open_in_new, color: Aether.accent),
                          ),
                        const SizedBox(width: 8),
                      ],
                    ),
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
          // Expanded detail — a hairline, then Input / Output (Terminal /
          // Diff / highlighted code / plain body), opening with a size tween.
          AnimatedSize(
            duration: Aether.motionFast,
            curve: Aether.ease,
            alignment: Alignment.topLeft,
            child: _open && hasDetail
                ? Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(height: 1, color: Aether.hairline),
                      _DetailBody(m: m),
                    ],
                  )
                : const SizedBox(width: double.infinity),
          ),
          if (artifact != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 2, 0, 6),
              child: ArtifactCard(artifact: artifact),
            ),
        ],
      ),
    );
  }
}

/// Claude-Code-style subagent card: a nested, collapsible surface with the
/// agent's name and task, live status (spinner · tool count · elapsed) and
/// the subagent's OWN tool rows, read live from its child session.
///
/// Open while the subagent runs (so its progress is visible), collapsed once
/// it finished; a tap always wins. Only the latest [_maxRows] tool rows are
/// built, so a long child run never inflates the parent transcript.
class _SubagentCard extends StatefulWidget {
  final Message m;
  const _SubagentCard(this.m);
  @override
  State<_SubagentCard> createState() => _SubagentCardState();
}

class _SubagentCardState extends State<_SubagentCard> {
  static const _maxRows = 6;
  bool? _override;
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _syncTicker();
  }

  @override
  void didUpdateWidget(covariant _SubagentCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncTicker();
  }

  /// Elapsed seconds advance live only while the subagent runs.
  void _syncTicker() {
    final running = widget.m.toolState == 'running';
    if (running && _tick == null) {
      _tick = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() {});
      });
    } else if (!running) {
      _tick?.cancel();
      _tick = null;
    }
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  Map<String, dynamic> _input() {
    final raw = widget.m.toolInput;
    if (raw == null || raw.isEmpty) return const {};
    try {
      final d = jsonDecode(raw);
      return d is Map<String, dynamic> ? d : const {};
    } catch (e) {
      Diag.swallow('chat.subagentCard.input', e);
      return const {};
    }
  }

  static String? _str(Map<String, dynamic> j, List<String> keys) {
    for (final k in keys) {
      final v = j[k];
      if (v is String && v.trim().isNotEmpty) return v.trim();
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final m = widget.m;
    final input = _input();
    // Wave 1b: the child's live transcript comes from its own cloud
    // session (the facade watches it while the subagent runs).
    final childId = m.toolSessionId;
    final childRows = childId == null
        ? const <Message>[]
        : (CloudAgentFacade.I.transcriptFor(childId) ??
              AppState.I.sessionById(childId)?.messages ??
              const <Message>[]);
    final running = m.toolState == 'running';
    final name =
        _str(input, const ['agentType', 'subagent_type', 'agent', 'name']) ??
        (m.toolTitle?.trim().isNotEmpty == true ? m.toolTitle!.trim() : null) ??
        l10n.subagentDefaultName;
    final task =
        _str(input, const ['objective', 'prompt', 'message']) ??
        (m.toolSummary ?? '').trim();
    final tools = <Message>[
      for (final cm in childRows)
        if (cm.kind == MsgKind.tool) cm,
    ];
    // The live activity line: "CodeSubagent: Editing lib/main.dart…".
    final activity = running
        ? CloudAgentFacade.I.subagentActivityLine(m)
        : null;
    final status = switch (m.toolState) {
      'running' => l10n.subagentStatusRunning,
      'error' => l10n.subagentStatusFailed,
      'stopped' => l10n.subagentStatusStopped,
      _ => l10n.subagentStatusDone,
    };
    final end = running
        ? DateTime.now()
        : (childRows.isNotEmpty ? childRows.last.time : null);
    final elapsed = end?.difference(m.time);
    final meta = [
      if (activity != null && activity != name)
        '${activity.substring(activity.indexOf(':') + 1).trim()}…'
      else
        status,
      l10n.subagentToolUses(tools.length),
      if (elapsed != null && elapsed.inSeconds > 0)
        formatCompactDuration(elapsed),
    ].join(' · ');
    final open = _override ?? running;
    final shown = tools.length > _maxRows
        ? tools.sublist(tools.length - _maxRows)
        : tools;
    final failed = m.toolState == 'error';
    return Container(
      key: const ValueKey('chat-subagent-card'),
      margin: const EdgeInsets.only(bottom: 6, top: 2),
      decoration: BoxDecoration(
        color: Aether.surface,
        borderRadius: BorderRadius.circular(AetherRadius.rMd),
        border: Border.all(
          color: running
              ? Aether.accent.withValues(alpha: 0.35)
              : Aether.hairline,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Semantics(
            button: true,
            expanded: open,
            label: l10n.subagentCardSemantics(name, status),
            child: InkWell(
              key: const ValueKey('chat-subagent-header'),
              onTap: () {
                setState(() => _override = !open);
                // A finished subagent's work loads on first expand (its
                // child session is not watched after a reload).
                final id = m.toolSessionId;
                if (!open && id != null && childRows.isEmpty) {
                  unawaited(CloudAgentFacade.I.openSubagentTranscript(id));
                }
              },
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 48),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(10, 8, 6, 8),
                  child: Row(
                    children: [
                      Container(
                        width: 26,
                        height: 26,
                        decoration: BoxDecoration(
                          color: failed
                              ? Aether.danger.withValues(alpha: 0.12)
                              : Aether.accentSoft,
                          shape: BoxShape.circle,
                        ),
                        child: Center(
                          child: running
                              ? _ChaseDot(Aether.accent)
                              : Icon(
                                  Icons.account_tree_outlined,
                                  size: 14,
                                  color: failed ? Aether.danger : Aether.accent,
                                ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: ExcludeSemantics(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                name,
                                key: const ValueKey('chat-subagent-name'),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                  color: Aether.text,
                                ),
                              ),
                              if (task.isNotEmpty)
                                Text(
                                  task,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 12,
                                    height: 1.35,
                                    color: Aether.textMuted,
                                  ),
                                ),
                              const SizedBox(height: 2),
                              running
                                  ? _ShimmerText(
                                      meta,
                                      style: const TextStyle(fontSize: 11),
                                    )
                                  : Text(
                                      meta,
                                      key: const ValueKey(
                                        'chat-subagent-status',
                                      ),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        fontSize: 11,
                                        color: failed
                                            ? Aether.danger
                                            : Aether.textFaint,
                                      ),
                                    ),
                            ],
                          ),
                        ),
                      ),
                      ToolStatusBadge(state: m.toolState),
                      AnimatedRotation(
                        turns: open ? 0.5 : 0.0,
                        duration: const Duration(milliseconds: 150),
                        child: Icon(
                          Icons.expand_more,
                          size: 18,
                          color: Aether.textFaint,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          AnimatedSize(
            duration: Aether.motionFast,
            curve: Aether.ease,
            alignment: Alignment.topCenter,
            child: !open
                ? const SizedBox(width: double.infinity)
                : Container(
                    key: const ValueKey('chat-subagent-body'),
                    decoration: BoxDecoration(
                      border: Border(top: BorderSide(color: Aether.hairline)),
                    ),
                    padding: const EdgeInsets.fromLTRB(6, 6, 6, 4),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (tools.length > shown.length)
                          Padding(
                            padding: const EdgeInsets.fromLTRB(10, 2, 10, 4),
                            child: Text(
                              l10n.subagentEarlierTools(
                                tools.length - shown.length,
                              ),
                              style: TextStyle(
                                fontSize: 11,
                                color: Aether.textFaint,
                              ),
                            ),
                          ),
                        if (shown.isEmpty)
                          Padding(
                            padding: const EdgeInsets.fromLTRB(10, 6, 10, 6),
                            child: Text(
                              l10n.subagentNoToolsYet,
                              style: TextStyle(
                                fontSize: 12,
                                color: Aether.textFaint,
                              ),
                            ),
                          ),
                        // A left rule nests the child rows under the card.
                        for (final t in shown)
                          Container(
                            margin: const EdgeInsets.only(left: 6),
                            decoration: BoxDecoration(
                              border: Border(
                                left: BorderSide(
                                  color: Aether.hairlineStrong,
                                  width: 1.5,
                                ),
                              ),
                            ),
                            child: _ToolCard(
                              t,
                              key: ObjectKey(t),
                              nested: true,
                            ),
                          ),
                        if (m.toolSessionId != null)
                          Align(
                            alignment: Alignment.centerLeft,
                            child: TextButton.icon(
                              key: const ValueKey('chat-subagent-open'),
                              onPressed: () => SubagentScreen.open(
                                context,
                                m.toolSessionId!,
                              ),
                              icon: const Icon(Icons.open_in_new, size: 14),
                              label: Text(
                                l10n.subagentOpenTranscript,
                                style: const TextStyle(fontSize: 12),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
          ),
        ],
      ),
    );
  }
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
    final kind = toolIconFor(m.toolName ?? '');
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

    final inputRows = isTerminal ? const <(String, String)>[] : _inputRows(m);
    return Container(
      key: const ValueKey('chat-tool-body'),
      width: double.infinity,
      padding: const EdgeInsets.only(top: 6, bottom: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Input — the small identifying args recorded at dispatch (path,
          // command, url, query …), never file bodies.
          if (inputRows.isNotEmpty) ...[
            _sectionLabel(context.l10n.toolDetailInput),
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 0, 10, 4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final (k, v) in inputRows)
                    Text.rich(
                      TextSpan(
                        children: [
                          TextSpan(
                            text: '$k  ',
                            style: TextStyle(color: Aether.textFaint),
                          ),
                          TextSpan(text: v),
                        ],
                      ),
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontFamily: Aether.mono,
                        fontSize: 11.5,
                        color: Aether.textMuted,
                      ),
                    ),
                ],
              ),
            ),
          ],
          // Output header with a copy action for the full result.
          Row(
            children: [
              Expanded(child: _sectionLabel(context.l10n.toolDetailOutput)),
              Tooltip(
                message: context.l10n.toolDetailCopy,
                child: _CopyButton(code: detail),
              ),
              const SizedBox(width: 2),
            ],
          ),
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

  Widget _sectionLabel(String text) => Padding(
    padding: const EdgeInsets.fromLTRB(10, 4, 10, 2),
    child: Text(
      text.toUpperCase(),
      style: TextStyle(
        fontSize: 10,
        fontWeight: FontWeight.w700,
        letterSpacing: 0.6,
        color: Aether.textFaint,
      ),
    ),
  );

  /// `key value` pairs of the tool's recorded input (at most six).
  static List<(String, String)> _inputRows(Message m) {
    final raw = m.toolInput;
    if (raw == null || raw.trim().isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return const [];
      return [
        for (final e in decoded.entries.take(6))
          if (e.value != null && '${e.value}'.trim().isNotEmpty)
            (
              '${e.key}',
              e.value is String ? e.value as String : jsonEncode(e.value),
            ),
      ];
    } catch (e) {
      Diag.swallow('chat.toolDetail.input', e);
      return const [];
    }
  }

  /// Language of a read tool's file for highlighting, or null.
  static String? _codeLangOf(Message m) {
    if (chatToolFamily(m.toolName ?? '') != 'read') return null;
    final path = toolInputPath(m.toolInput);
    if (path == null) return null;
    final kind = artifactKindFor(path);
    if (kind != ArtifactKind.code && kind != ArtifactKind.html) return null;
    return artifactExtension(path);
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
    // A read of a source file: syntax-highlighted like the code viewer.
    final lang = _codeLangOf(m);
    if (lang != null && m.toolState != 'error') {
      return SelectableText.rich(
        highlightCode(
          shown.join('\n'),
          lang: lang,
          style: TextStyle(
            fontFamily: Aether.mono,
            fontSize: 11.5,
            height: 1.5,
            color: Aether.text,
          ),
        ),
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

  /// Link recognizers created by the current build. Owned here so they are
  /// disposed when the spans are rebuilt or the card goes away instead of
  /// leaking one per URL per build.
  final List<TapGestureRecognizer> _recognizers = [];

  void _disposeRecognizers() {
    for (final r in _recognizers) {
      r.dispose();
    }
    _recognizers.clear();
  }

  @override
  void dispose() {
    _disposeRecognizers();
    super.dispose();
  }

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
    _disposeRecognizers();
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
        // Tappable URL. Tool output is attacker-influenced (web fetch, MCP,
        // shell): never launch on one tap. The confirm sheet shows the real,
        // decoded host with any `user@` prefix stripped.
        final url = m.value;
        final recognizer = TapGestureRecognizer()
          ..onTap = () => _openToolOutputLink(context, url);
        _recognizers.add(recognizer);
        spans.add(
          TextSpan(
            text: m.value,
            style: baseStyle.copyWith(
              color: Aether.accent,
              decoration: TextDecoration.underline,
              decorationColor: Aether.accent,
            ),
            recognizer: recognizer,
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
                      _open ? 'Hide' : 'What was kept',
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

/// "Produced" parity — artifact cards under the final answer for the files
/// the agent created/edited this run. Tap a card to preview the file (the
/// preview offers "Open in Studio" for workspace files).
class _ProducedFilesCard extends StatelessWidget {
  final List<({String path, int size})> files;
  const _ProducedFilesCard({required this.files});

  String _fmtSize(int b) => b >= 1048576
      ? '${(b / 1048576).toStringAsFixed(1)} MB'
      : b >= 1024
      ? '${(b / 1024).toStringAsFixed(1)} KB'
      : '$b B';

  String _base(String path) => path.contains('/') ? path.split('/').last : path;

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
                // "Show in folder" handed Android a file:// URI (throws on
                // API 24+, result ignored). Share the file through the
                // FileProvider instead; tapping the row opens it in Studio.
                trailing: IconButton(
                  tooltip: 'Share file',
                  visualDensity: VisualDensity.compact,
                  icon: Icon(
                    Icons.share_outlined,
                    size: 17,
                    color: Aether.textMuted,
                  ),
                  onPressed: () {
                    // Produced files live server-side on the thin client
                    // (P8 Task 19): there is no local host path to share.
                  },
                ),
                onTap: () {
                  Navigator.pop(sheetCtx);
                  openArtifactPreview(context, _artifactOf(f));
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

  /// The produced file as an artifact of the active chat (workspace path).
  SessionArtifact _artifactOf(({String path, int size}) f) {
    final s = AppState.I.activeSession;
    return SessionArtifact(
      id: '${s?.id ?? ''}:gen:${f.path}',
      name: _base(f.path),
      path: f.path,
      size: f.size,
      sessionId: s?.id ?? '',
      sessionTitle: s?.title ?? '',
      time: DateTime.now(),
      origin: ArtifactOrigin.generated,
      kind: artifactKindFor(f.path),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    // Artifact cards (Claude-style) for the first few files; the rest fold
    // into a "+N more files" chip that lists everything in a sheet.
    const cards = 4;
    final shown = files.take(cards).toList();
    final rest = files.length - shown.length;
    return Container(
      key: const ValueKey('chat-produced-card'),
      margin: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 2, bottom: 6),
            child: Row(
              children: [
                Icon(
                  Icons.auto_awesome_rounded,
                  size: 13,
                  color: Aether.accent,
                ),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    l10n.chatProducedFiles(files.length),
                    style: TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w600,
                      color: Aether.textMuted,
                    ),
                  ),
                ),
              ],
            ),
          ),
          for (final f in shown)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: ArtifactCard(
                artifact: _artifactOf(f),
                subtitle: '${f.path} · ${_fmtSize(f.size)}',
              ),
            ),
          if (rest > 0)
            _chip(
              context,
              icon: Icons.more_horiz,
              label: l10n.chatProducedMore(rest),
              onTap: () => _showAll(context),
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

/// CH-019: the ONE surface of a run-level failure — plain copy, the raw
/// server text behind Details, and the action that helps: Retry (re-runs
/// the prompt in place) or Pick model for provider failures.
class _RunFailedRow extends StatefulWidget {
  const _RunFailedRow({
    required this.message,
    required this.sessionId,
    required this.latest,
  });

  final Message message;
  final String sessionId;

  /// Only the newest failure offers Retry.
  final bool latest;

  @override
  State<_RunFailedRow> createState() => _RunFailedRowState();
}

class _RunFailedRowState extends State<_RunFailedRow> {
  bool _details = false;
  bool _retrying = false;

  Future<void> _retry() async {
    setState(() => _retrying = true);
    try {
      await CloudAgentFacade.I.retryFailedRun(widget.sessionId);
    } catch (e) {
      if (mounted) {
        final text = e is CloudApiException
            ? cloudErrorCopy(e.code, message: e.message).text
            : 'That did not work. Check your connection and try again.';
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(text)));
      }
    } finally {
      if (mounted) setState(() => _retrying = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final m = widget.message;
    final code = m.toolSummary ?? '';
    final detail = (m.toolDetail ?? '').trim();
    final busy = _agent.busyFor(widget.sessionId);
    final pickModel = code.startsWith('model_');
    return Semantics(
      liveRegion: true,
      child: Container(
        key: const ValueKey('run-failed-row'),
        margin: const EdgeInsets.only(top: 2, bottom: 8),
        padding: const EdgeInsets.fromLTRB(10, 8, 6, 4),
        decoration: BoxDecoration(
          color: Aether.danger.withValues(alpha: 0.06),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: Aether.danger.withValues(alpha: 0.35)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.error_outline, size: 15, color: Aether.danger),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    m.content,
                    style: TextStyle(fontSize: 13, color: Aether.text),
                  ),
                ),
              ],
            ),
            if (_details && detail.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(23, 4, 4, 0),
                child: SelectableText(
                  detail,
                  style: TextStyle(fontSize: 12, color: Aether.textMuted),
                ),
              ),
            Wrap(
              alignment: WrapAlignment.end,
              children: [
                if (detail.isNotEmpty)
                  TextButton(
                    onPressed: () => setState(() => _details = !_details),
                    child: Text(_details ? 'Hide details' : 'Details'),
                  ),
                if (pickModel && widget.latest)
                  TextButton(
                    onPressed: () => ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text(
                          'Pick another model from the model menu at the top, '
                          'then tap Retry.',
                        ),
                      ),
                    ),
                    child: const Text('Pick model'),
                  ),
                if (widget.latest)
                  TextButton(
                    key: const ValueKey('run-failed-retry'),
                    onPressed: busy || _retrying ? null : () => unawaited(_retry()),
                    child: Text(_retrying ? 'Retrying…' : 'Retry'),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// CH-004: the files the agent created in this turn, as artifact chips —
/// tapping one opens the preview (the URL is re-minted first, so an old
/// chat's chips still open after their presigned links expired).
class _ArtifactChips extends StatelessWidget {
  const _ArtifactChips({required this.message, required this.sessionId});

  final Message message;
  final String sessionId;

  @override
  Widget build(BuildContext context) {
    final session = AppState.I.sessionById(sessionId);
    return Padding(
      key: const ValueKey('chat-artifact-chips'),
      padding: const EdgeInsets.only(top: 2, bottom: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final a in message.attachments)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: ArtifactCard(
                artifact: SessionArtifact(
                  id: 'art:${cloudArtifactIdOf(a.url) ?? a.name}',
                  name: a.name,
                  sessionId: sessionId,
                  sessionTitle: session?.title ?? '',
                  time: message.time,
                  origin: ArtifactOrigin.generated,
                  kind: artifactKindFor(a.name),
                  url: a.url,
                  size: a.size,
                ),
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
                if (m.toolName == kArtifactRowTool)
                  _ArtifactChips(message: m, sessionId: session.id as String)
                else
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
                  _ => _answer(isUser),
                },
                // Attachment chips under the user bubble (in-chat display).
                if (isUser && m.attachments.isNotEmpty)
                  _attachmentTiles(context),
                // Delivery state of a prompt the server has not confirmed
                // yet (CH-009 / CH-011).
                if (isUser &&
                    CloudAgentFacade.pendingClientMsgIdOf(m) != null)
                  _PendingSendStatus(message: m),
              ],
            ),
          ),
          // web-IDE message meta + action row: copy / edit / revert / time.
          // (Suppressed on compaction event rows — they are apparatus, not
          // conversation turns.)
          if (!m.thinking &&
              m.kind != MsgKind.compact &&
              m.kind != MsgKind.turnTail &&
              m.toolName != kArtifactRowTool)
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
    // Secondary actions (Branch, Revert) live in a "More actions" menu so
    // the row fits on a phone with full 48dp targets.
    final overflow = <(IconData, String, VoidCallback)>[];
    // A11Y: every action is a 48x48dp target (Play pre-launch scanner,
    // Material guidance); the Tooltip supplies the semantics label.
    Widget target(String tip, VoidCallback fn, Widget icon) => Tooltip(
      message: tip,
      waitDuration: const Duration(milliseconds: 500),
      child: InkWell(
        borderRadius: BorderRadius.circular(24),
        onTap: fn,
        child: SizedBox(width: 48, height: 48, child: Center(child: icon)),
      ),
    );
    void add(IconData icon, String tip, VoidCallback fn) {
      items.add(target(tip, fn, Icon(icon, size: 16, color: Aether.textFaint)));
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
    // Play AI-Generated Content policy: flag offensive AI output in-app.
    if (!isUser && isReportableAiMessage(m)) {
      add(Icons.flag_outlined, 'Report', () {
        unawaited(reportAiMessage(context, m, model: session.model));
      });
    }
    // CT-004 / CH-024: history edits are real server operations, offered
    // only on rows the server stores and only while nothing runs.
    final serverRow = CloudAgentFacade.isServerMessage(m);
    final canEdit =
        input != null &&
        !session.isSubagent &&
        serverRow &&
        CloudAgentFacade.I.canEditHistory(session.id as String);
    if (canEdit && isUser) {
      add(Icons.edit_outlined, 'Edit & resend', () {
        _showEditResendDialog(context);
      });
      overflow.add((
        Icons.delete_outline,
        'Delete from here',
        () => unawaited(_confirmDeleteFrom(context)),
      ));
    }
    // CH-029: thumbs feedback is not offered — there is no server feedback
    // route yet, and a like that is never sent or kept would be a lie.
    // Branch into a new chat from this answer (server-side copy).
    if (!isUser && serverRow && !m.thinking && !session.isSubagent) {
      overflow.add((
        Icons.call_split,
        'Branch into a new chat',
        () => unawaited(_branch(context)),
      ));
    }
    // Regenerate the newest answer (server re-run of its prompt).
    if (canEdit && !isUser && _isLatestAnswer()) {
      add(Icons.refresh, 'Regenerate', () => unawaited(_regenerate(context)));
    }
    if (overflow.isNotEmpty) {
      items.add(
        PopupMenuButton<VoidCallback>(
          tooltip: 'More actions',
          child: SizedBox(
            width: 48,
            height: 48,
            child: Icon(Icons.more_horiz, size: 18, color: Aether.textFaint),
          ),
          onSelected: (fn) => fn(),
          itemBuilder: (_) => [
            for (final (icon, label, fn) in overflow)
              PopupMenuItem(
                value: fn,
                child: Row(
                  children: [
                    Icon(icon, size: 18, color: Aether.textMuted),
                    const SizedBox(width: 12),
                    Flexible(child: Text(label)),
                  ],
                ),
              ),
          ],
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 8, top: 2),
      // Wrap, not Row: 48dp targets plus the timestamp must not overflow a
      // narrow bubble at large text scales.
      child: Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
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

  /// Edit & resend: the edited prompt replaces this one; everything after
  /// it is removed on the server first (CT-004).
  void _showEditResendDialog(BuildContext context) {
    final c = TextEditingController(text: m.content);
    final navigator = Navigator.of(context, rootNavigator: true);
    final later = _laterServerRows();
    Future<void> send(String value) async {
      final text = value.trim();
      navigator.pop();
      if (text.isEmpty) return;
      try {
        await CloudAgentFacade.I.editAndResend(session.id as String, m, text);
        onAction();
      } catch (e) {
        if (context.mounted) _historyError(context, e);
      }
    }

    final route = DialogRoute<void>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text(
          'Edit & resend',
          style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: c,
              autofocus: true,
              maxLines: 6,
              minLines: 1,
              style: const TextStyle(fontSize: 14),
              textInputAction: TextInputAction.done,
              onSubmitted: send,
            ),
            if (later > 0) ...[
              const SizedBox(height: 12),
              Text(
                'This also removes the $later message${later == 1 ? '' : 's'} '
                'after it. This cannot be undone.',
                key: const ValueKey('edit-resend-removal-count'),
                style: TextStyle(fontSize: 12.5, color: Aether.danger),
              ),
            ],
          ],
        ),
        actions: [
          TextButton(onPressed: navigator.pop, child: const Text('Cancel')),
          TextButton(
            key: const ValueKey('edit-resend-send'),
            onPressed: () => send(c.text),
            child: Text(
              later > 0 ? 'Send & remove $later' : 'Send',
              style: TextStyle(
                color: later > 0 ? Aether.danger : Aether.accent,
              ),
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

  /// The collapsed "Thought for Ns" block a live bubble leaves above its
  /// answer once thinking ended (see [_ThinkClock]); empty otherwise.
  List<Widget> _thoughtAbove() {
    final clock = _ThinkClock.of(m);
    if (clock == null ||
        clock.end == null ||
        clock.snapshot.trim().isEmpty ||
        !AppState.I.showReasoning) {
      return const [];
    }
    return [
      _ReasoningCard(
        m,
        contentOverride: clock.snapshot,
        duration: clock.duration,
      ),
    ];
  }

  /// A finished assistant answer, with its thinking block above when the
  /// live timeline recorded one.
  Widget _answer(bool isUser) {
    if (isUser) return _text(isUser);
    _ThinkClock.observe(m);
    final thought = _thoughtAbove();
    if (thought.isEmpty) return _text(isUser);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [...thought, _text(isUser)],
    );
  }

  /// Live streaming bubble (MsgKind.streaming): answer text renders as
  /// markdown the moment it arrives (never hidden behind a thinking card);
  /// while the model is still thinking, the reasoning card shows expanded
  /// by default so the live thought stream stays visible. Once the answer
  /// streams, a soft pulsing caret marks the growing edge.
  Widget _streaming() {
    _ThinkClock.observe(m);
    final hasBody = m.content.trim().isNotEmpty;
    final isUser = m.role == 'user';
    final live =
        hasBody && !m.thinking && _agent.busyFor(session.id as String);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (!m.thinking) ..._thoughtAbove(),
        if (hasBody && !m.thinking) _text(isUser),
        if (live) const _StreamingCaret(),
        if (m.thinking) _ReasoningCard(m, expandedByDefault: true),
      ],
    );
  }

  /// Compact attachment tiles under a user message: a thumbnail grid for
  /// images (opening the fullscreen viewer) and fixed-width file cards whose
  /// names ellipsize in the middle, so long names never wrap or overflow.
  Widget _attachmentTiles(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 6),
    child: TranscriptAttachments(
      items: [
        for (final a in m.attachments)
          AttachmentTileData(name: a.name, size: a.size, path: a.path),
      ],
      onOpenImage: (path) => _showFullscreenImage(context, File(path)),
    ),
  );

  /// ToolRow parity — collapsed 24px row (icon + title · summary)
  /// expanding to a Terminal/Diff/plain detail block.
  Widget _toolCard() => _ToolCard(m);

  /// turn-tail parity — faint footer row (elapsed · stats).
  Widget _turnTail() => m.toolName == 'run_failed'
      ? _RunFailedRow(
          message: m,
          sessionId: session.id as String,
          latest: _isLatestRow(),
        )
      : _TurnTailRow(m);

  /// The projection rows this view indexes into (cloud sessions keep
  /// `ChatSession.messages` empty).
  List<Message> _rows() =>
      CloudAgentFacade.I.transcriptFor(session.id as String) ??
      (session.messages as List<Message>);

  /// True when nothing but turn tails follows this row.
  bool _isLatestRow() {
    final rows = _rows();
    final i = rows.indexOf(m);
    if (i < 0) return false;
    for (var j = i + 1; j < rows.length; j++) {
      if (rows[j].kind != MsgKind.turnTail) return false;
    }
    return true;
  }

  /// True when [m] is the newest server-stored answer (Regenerate).
  bool _isLatestAnswer() {
    final rows = _rows();
    final i = rows.indexOf(m);
    if (i < 0) return false;
    for (var j = i + 1; j < rows.length; j++) {
      final r = rows[j];
      if (CloudAgentFacade.isServerMessage(r) ||
          CloudAgentFacade.pendingClientMsgIdOf(r) != null) {
        return false;
      }
    }
    return true;
  }

  /// Server-stored rows after [m] — what a history edit from here removes.
  int _laterServerRows() {
    final rows = _rows();
    final i = rows.indexOf(m);
    if (i < 0) return 0;
    var n = 0;
    for (var j = i + 1; j < rows.length; j++) {
      if (CloudAgentFacade.isServerMessage(rows[j])) n++;
    }
    return n;
  }

  void _historyError(BuildContext context, Object e) {
    if (!context.mounted) return;
    final text = e is CloudApiException
        ? (e.code == 'session_busy'
              ? 'A task is still running in this chat. Stop it first.'
              : cloudErrorCopy(e.code, message: e.message).text)
        : 'That did not work. Check your connection and try again.';
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _confirmDeleteFrom(BuildContext context) async {
    final later = _laterServerRows();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete this message?'),
        content: Text(
          later > 0
              ? 'This deletes it and the $later message${later == 1 ? '' : 's'} '
                    'after it, on every device. This cannot be undone.'
              : 'This deletes it on every device. This cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            key: const ValueKey('confirm-delete-from'),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text('Delete', style: TextStyle(color: Aether.danger)),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await CloudAgentFacade.I.deleteFrom(session.id as String, m);
      onAction();
    } catch (e) {
      if (context.mounted) _historyError(context, e);
    }
  }

  Future<void> _regenerate(BuildContext context) async {
    try {
      await CloudAgentFacade.I.regenerate(session.id as String, m);
      onAction();
    } catch (e) {
      if (context.mounted) _historyError(context, e);
    }
  }

  Future<void> _branch(BuildContext context) async {
    try {
      final id = await CloudAgentFacade.I.branchFrom(session.id as String, m);
      AppState.I.selectSession(id);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Branched into a new chat'),
            duration: Duration(milliseconds: 1200),
          ),
        );
      }
    } catch (e) {
      if (context.mounted) _historyError(context, e);
    }
  }

  Widget _imageGen(BuildContext context) {
    final path = m.imagePath;
    if (path == null) return _imageGenCard(context, null, false, null);
    // The file is stat'ed asynchronously and POSITIVE results are cached —
    // never existsSync/lengthSync inside build on every rebuild. A notFound
    // stat is never cached (a generated image can land in the workspace
    // after the row first renders); see _ImageFileInfoState.
    return _ImageFileInfo(
      path: path,
      builder: (context, exists, size) =>
          _imageGenCard(context, File(path), exists, size),
    );
  }

  Widget _imageGenCard(
    BuildContext context,
    File? file,
    bool exists,
    int? size,
  ) {
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
            onTap: exists ? () => _showFullscreenImage(context, file!) : null,
            child: AspectRatio(
              aspectRatio: 1,
              child: exists
                  ? Image.file(
                      file!,
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
                        () => _showFullscreenImage(context, file!),
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
                      if (size != null) ...[
                        const SizedBox(width: 14),
                        Text(
                          '${(size / 1024).toStringAsFixed(0)} KB',
                          style: TextStyle(
                            fontSize: 11,
                            color: Aether.textFaint,
                          ),
                        ),
                      ],
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
    child: Center(
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

  void _showFullscreenImage(BuildContext context, File file) =>
      _openFullscreenImage(context, file);

  Future<void> _shareLocalFile(BuildContext context, String path) async {
    await showNativeShare(context, () => NativeShare.file(path));
  }

  /// Open a local workspace file with the best-matching app via the
  /// FileProvider (a `file://` URI throws on Android 7+). Awaited, with a
  /// snackbar when nothing can open it.
  Future<void> _openLocalFile(BuildContext context, String path) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await NativeShare.open(path, mime: _imageMime(path));
    } catch (_) {
      messenger.showSnackBar(
        SnackBar(
          content: Text('No app can open ${path.split('/').last}'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  static String? _imageMime(String path) {
    final ext = path.split('.').last.toLowerCase();
    return switch (ext) {
      'png' => 'image/png',
      'jpg' || 'jpeg' => 'image/jpeg',
      'gif' => 'image/gif',
      'webp' => 'image/webp',
      'bmp' => 'image/bmp',
      _ => null,
    };
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

/// Staged attachments above the composer text field: one horizontal row of
/// compact tiles (image thumbnails, file cards) with a 48dp × each, plus a
/// placeholder while picked files are still being copied. Hidden when empty.
class _AttachmentChip extends StatelessWidget {
  const _AttachmentChip();

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([_agent, AppState.I]),
      builder: (context, _) {
        final atts = _agent.pendingAttachments;
        final staging = _agent.stagingAttachmentCount;
        final sessionId = AppState.I.activeSessionId;
        if (atts.isEmpty && staging == 0) return const SizedBox.shrink();
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: ComposerAttachmentRow(
            scrollKey: const ValueKey('composer-attachments-scroll'),
            items: [
              for (final a in atts)
                AttachmentTileData(name: a.name, size: a.size, path: a.path),
            ],
            staging: staging,
            max: _maxChatAttachments,
            onOpenImage: (path) => _openFullscreenImage(context, File(path)),
            onRemove: (a) {
              if (AppState.I.activeSessionId == sessionId && a.path != null) {
                _agent.removeAttachment(a.path!);
              }
            },
          ),
        );
      },
    );
  }
}

/// Fullscreen, zoomable image viewer with a Share action (generated images
/// and image attachments in the composer and transcript).
void _openFullscreenImage(BuildContext context, File file) {
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
              onPressed: () =>
                  showNativeShare(ctx, () => NativeShare.file(file.path)),
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

/// Voice-input mic (press-to-talk): toggles on-device speech recognition,
/// shows a stop button while listening, and INSERTS the final transcript
/// into the composer (silence auto-stops, or tap stop) for the user to review
/// and send; dictation never sends on its own. Honest no-op with a hint when
/// STT is unavailable.
class _MicButton extends StatefulWidget {
  final TextEditingController controller;

  /// False while an approval locks the composer or no chat is selected; an
  /// in-progress dictation is cancelled so it cannot overwrite the field.
  final bool enabled;
  const _MicButton({required this.controller, this.enabled = true});
  @override
  State<_MicButton> createState() => _MicButtonState();
}

class _MicButtonState extends State<_MicButton> {
  bool _listening = false;

  @override
  void didUpdateWidget(covariant _MicButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.enabled && _listening) {
      VoiceInputService.I.cancel();
      _listening = false;
    }
  }

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
    if (!widget.enabled) return;
    final base = widget.controller.text;
    final started = await voice.start((text, isFinal) {
      if (!mounted || !widget.enabled) return;
      final t = text.trim();
      if (t.isEmpty) return;
      widget.controller.text = base.isEmpty ? t : '$base $t';
      widget.controller.selection = TextSelection.collapsed(
        offset: widget.controller.text.length,
      );
      if (isFinal) {
        // Dictation ended (silence or stop button): release the service
        // flag so the next tap starts fresh. The transcript stays in the
        // composer for review — recognition errors are never auto-sent.
        unawaited(voice.stop());
        if (mounted) setState(() => _listening = false);
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
      onPressed: widget.enabled ? _toggle : null,
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

  final bool running;

  /// Approval takeover: when an approval/question card is pending, the
  /// composer is disabled until the user answers it (the approval takeover parity).
  final bool locked;
  final bool editingQueue;

  /// A slash command is executing: Send is disabled and shows a spinner.
  final bool commandBusy;
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
    this.locked = false,
    this.editingQueue = false,
    this.commandBusy = false,
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

  @override
  void initState() {
    super.initState();
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
  }

  @override
  void dispose() {
    _mentionFilesTimer?.cancel();
    controller.removeListener(_onTextChanged);
    super.dispose();
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

  /// `@file` listing cache. Listing a workspace used to run synchronously
  /// inside build on every composer rebuild, freezing typing in large
  /// workspaces. Now one folder is listed at a time, asynchronously, after a
  /// short debounce and capped at [_mentionFileCap] entries.
  static const _mentionFileDebounce = Duration(milliseconds: 120);
  String? _mentionFilesKey;
  ({String root, List<FileSystemEntity> entries})? _mentionFiles;
  String? _mentionFilesPendingKey;
  Timer? _mentionFilesTimer;

  /// Cached entries for [parent]'s workspace folder at [leading], or null
  /// while that folder is still loading (a load is scheduled).
  ({String root, List<FileSystemEntity> entries})? _mentionFilesFor(
    ChatSession parent,
    List<String> leading,
  ) {
    final key = [
      parent.id,
      parent.workspaceFolder ?? '',
      ...leading.take(3),
    ].join('\u0000');
    if (key == _mentionFilesKey) return _mentionFiles;
    if (key != _mentionFilesPendingKey) {
      _mentionFilesPendingKey = key;
      _mentionFilesTimer?.cancel();
      _mentionFilesTimer = Timer(
        _mentionFileDebounce,
        () => unawaited(_loadMentionFiles(key, parent, leading)),
      );
    }
    return null;
  }

  Future<void> _loadMentionFiles(
    String key,
    ChatSession parent,
    List<String> leading,
  ) async {
    // The thin client has no local workspace (P8 Task 19), so `@file:` rows
    // never list. Resolve the state row so the menu stops loading.
    if (!mounted || key != _mentionFilesPendingKey) return;
    setState(() {
      _mentionFilesKey = key;
      _mentionFiles = (root: '', entries: const <FileSystemEntity>[]);
      _mentionFilesPendingKey = null;
    });
  }

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
    final agent = _agent;
    var query = _mentionQuery.toLowerCase();
    // File rows insert `@file:<rel>`; strip the prefix so descending into
    // an inserted `@file:src/` keeps matching inside that folder.
    if (query.startsWith('file:')) query = query.substring('file:'.length);
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
    // The listing itself is loaded off the build path (debounced, async,
    // capped) and cached per folder; build only filters the cached entries.
    final parts = query.split('/')..removeWhere((p) => p.isEmpty);
    final descending = query.contains('/');
    final lastSeg = descending ? (parts.isEmpty ? '' : parts.last) : query;
    final leading = descending && parts.isNotEmpty
        ? parts.sublist(0, parts.length - 1)
        : const <String>[];
    final listing = _mentionFilesFor(parent, leading);
    if (listing != null) {
      final wsPath = listing.root;
      for (final e in listing.entries) {
        final base = e.path.split('/').last;
        if (base.startsWith('.')) continue; // .spill etc.
        final isDir = e is Directory;
        final score = _fuzzyScore(base, lastSeg);
        if (score == null) continue;
        fileHits++;
        // Display path relative to the workspace root for descent rows.
        final rel = e.path.startsWith(wsPath) && e.path != wsPath
            ? e.path.substring(wsPath.length + 1)
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
            // Explicit `@file:` so the reference always resolves to this
            // workspace entry, never to a chat whose title contains it.
            // Paths with whitespace are quoted to stay one token.
            insert: rel.contains(RegExp(r'\s'))
                ? '@"file:$rel" '
                : '@file:$rel${isDir ? '/' : ' '}',
            group: 'Files',
          ),
        ));
      }
    }
    // PR23/M2: an EMPTY menu looks like a dead feature — show a hint row
    // explaining what @ can reference instead of rendering nothing.
    if (listing != null &&
        fileHits == 0 &&
        agent.subagentsOf(parent.id).isEmpty) {
      scored.add((
        score: 999,
        order: order++,
        s: _SlashSuggestion(
          icon: Icons.info_outline,
          name: 'no files yet',
          description:
              'The agent creates workspace files as it works. '
              'Type @ and pick a chat to include its context.',
          hint: '',
          insert: '@',
          group: 'Files',
        ),
      ));
    }
    // ── @[chat title]: include another chat's context in THIS message only
    // (owner rule R1 — chats never see each other unless tagged, or unless
    // "Share session memory" is on). The server resolves the tag.
    for (final s in app.rootSessions.take(30)) {
      if (s.id == parent.id) continue;
      final title = s.title.replaceAll(RegExp(r'[\[\]\n]'), ' ').trim();
      if (title.isEmpty || CloudSessionStore.isPlaceholderTitle(title)) {
        continue;
      }
      final score = _fuzzyScore(title, query);
      if (score == null) continue;
      scored.add((
        score: score,
        order: order++,
        s: _SlashSuggestion(
          icon: Icons.chat_bubble_outline,
          name: title,
          description: "Include this chat's context in your message",
          hint: '',
          insert: '@[$title] ',
          group: 'Chats',
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
        // A fresh `@` re-lists the workspace (the agent may have added files).
        if (mention && !_mentionActive) {
          _mentionFilesKey = null;
          _mentionFiles = null;
          _mentionFilesPendingKey = null;
        }
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
              'Up to 20 files per message, max 25 MB each',
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
      final err = await _agent.attachFile(
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
    // Disposed once the dialog route is fully gone (after its exit
    // animation, which still builds the field): a leaked controller keeps its
    // listeners and the platform text-input channel alive.
    final route = DialogRoute<void>(
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
              _sendImagePrompt(context, prompt);
            },
            child: const Text('Generate'),
          ),
        ],
      ),
    );
    Navigator.of(context).push(route);
    route.completed.whenComplete(c.dispose);
  }

  /// Sends `Generate an image: …` through the normal send path without
  /// losing the user's draft: the composer value is saved first and put
  /// back whether the send was accepted (the image prompt was consumed) or
  /// refused (the image prompt is still in the field).
  void _sendImagePrompt(BuildContext context, String prompt) {
    if (widget.locked || widget.sessionId == null) return;
    if (widget.editingQueue) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Finish editing the queued message before generating an image.',
          ),
        ),
      );
      return;
    }
    final saved = controller.value;
    final imageText = 'Generate an image: $prompt';
    controller.value = TextEditingValue(
      text: imageText,
      selection: TextSelection.collapsed(offset: imageText.length),
    );
    // Plain text never awaits inside the send path, so the outcome is known
    // when onSend returns.
    onSend();
    if (controller.text.isEmpty || controller.text == imageText) {
      controller.value = saved;
    }
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
                    // Nothing can be attached while an approval locks the
                    // composer or before a chat exists.
                    onPressed: widget.locked || widget.sessionId == null
                        ? null
                        : () => _attachSheet(context),
                  ),
                  // The middle chips (workspace / plan / mode) scroll
                  // horizontally on narrow phones instead of overflowing the
                  // composer row; the mic/send actions stay pinned right.
                  Expanded(
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        children: [
                          // Studio mode: one chip that opens Studio.
                          const _StudioChip(),
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
                    enabled: !widget.locked && widget.sessionId != null,
                  ),
                  const SizedBox(width: 4),
                  // ── Stateful primary / stop button (web-IDE InputBar pattern) ──
                  AnimatedBuilder(
                    animation: Listenable.merge([
                      _agent,
                      controller,
                      ConnectionService.I,
                    ]),
                    builder: (_, _) {
                      // Per-session run state (never leaked from other
                      // sessions — the multi-session blink fix).
                      final sessionId = widget.sessionId ?? '';
                      final hasSession = widget.sessionId != null;
                      final runningNow =
                          hasSession && _agent.busyFor(sessionId);
                      final hasDraft = controller.text.trim().isNotEmpty;
                      final hasQueued =
                          hasSession &&
                          _agent
                              .queuedMessagesFor(sessionId)
                              .isNotEmpty;
                      void stop() {
                        if (hasSession) {
                          _agent.stopRequested(sessionId: sessionId);
                        } else {
                          _agent.hardStopAll();
                        }
                      }

                      // Match the existing submission handler: files alone
                      // are not a submission, and queue edits retain their
                      // original attachments rather than newly staged files.
                      // Offline (CH-035 / SH-011): Send stays enabled — the
                      // prompt goes into the outbox and its row says it
                      // will send when Ovid is reachable again.
                      final offline =
                          ConnectionService.I.offline && !widget.editingQueue;
                      final canSubmit =
                          hasSession &&
                          AppState.I.activeSessionId == sessionId &&
                          hasDraft &&
                          !locked &&
                          !widget.commandBusy &&
                          _agent.pendingApproval == null &&
                          (!widget.editingQueue ||
                              _agent.pendingAttachments.isEmpty);
                      final interrupt = AppState.I.sendWhileBusyInterrupt;
                      final stopping = hasSession &&
                          CloudAgentFacade.I.stoppingFor(sessionId);
                      final actionLabel = widget.editingQueue
                          ? 'Save'
                          : runningNow
                          ? (interrupt ? 'Stop and send' : 'Queue')
                          : 'Send';
                      final actionTooltip = !hasSession
                          ? 'Preparing your chat…'
                          : offline && !runningNow
                          ? "Send (you're offline — it sends when you're back)"
                          : widget.editingQueue
                          ? 'Save queued message'
                          : runningNow && !interrupt
                          ? 'Add to queue'
                          : actionLabel;
                      return Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          // Stop remains independent of the draft/save action
                          // and stays pinned in the rightmost slot: the Queue
                          // button sits to its LEFT, so when queueing clears
                          // the draft (and the Queue button vanishes), Stop
                          // never slides under the finger that just queued.
                          // A repeat tap must not stop the run.
                          if (!runningNow ||
                              hasDraft ||
                              widget.editingQueue) ...[
                            AetherPrimaryButton(
                              label: actionLabel,
                              tooltip: actionTooltip,
                              icon: widget.editingQueue
                                  ? Icons.check
                                  : Icons.arrow_upward,
                              iconOnly: true,
                              loading: widget.commandBusy,
                              onPressed: canSubmit ? onSend : null,
                            ),
                            if (runningNow) const SizedBox(width: 4),
                          ],
                          if (runningNow)
                            AetherDangerButton(
                              label: stopping ? 'Stopping…' : 'Stop',
                              tooltip: stopping
                                  ? 'Stopping…'
                                  : hasQueued
                                  ? 'Stop session (next queued will run)'
                                  : 'Stop session',
                              icon: Icons.stop_rounded,
                              iconOnly: true,
                              loading: stopping,
                              // CH-044: one cancel per run.
                              onPressed: stopping ? null : stop,
                            ),
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

/// "Load earlier" control for the paged subagent transcript
/// (`ChatTranscript`), so a truncated child run is never silent and its
/// start stays reachable.
class _OlderMessagesIndicator extends StatelessWidget {
  final int hiddenMessages;
  final VoidCallback onLoadEarlier;

  const _OlderMessagesIndicator({
    required this.hiddenMessages,
    required this.onLoadEarlier,
  });

  @override
  Widget build(BuildContext context) {
    final label = hiddenMessages == 1
        ? '1 earlier message'
        : '$hiddenMessages earlier messages';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Center(
        child: TextButton.icon(
          onPressed: onLoadEarlier,
          icon: Icon(Icons.expand_less, size: 16, color: Aether.textMuted),
          label: Text(
            'Load earlier · $label',
            style: TextStyle(fontSize: 12, color: Aether.textMuted),
          ),
        ),
      ),
    );
  }
}

/// Pulsing caret at the growing edge of a streaming answer (Claude-app
/// parity). Purely decorative: excluded from semantics.
class _StreamingCaret extends StatefulWidget {
  const _StreamingCaret();
  @override
  State<_StreamingCaret> createState() => _StreamingCaretState();
}

class _StreamingCaretState extends State<_StreamingCaret>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 650),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: Padding(
      key: const ValueKey('chat-streaming-caret'),
      padding: const EdgeInsets.only(left: 6, top: 2, bottom: 4),
      child: FadeTransition(
        opacity: Tween<double>(begin: 0.25, end: 1).animate(_c),
        child: Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(
            color: Aether.accent,
            shape: BoxShape.circle,
          ),
        ),
      ),
    ),
  );
}

class _TypingBubble extends StatelessWidget {
  const _TypingBubble();

  @override
  Widget build(BuildContext context) {
    // Inline parsing status (no bubble/box): a pulsing accent dot + the live
    // status line from the run, so retries/backoffs/compaction are visible
    // instead of a permanent generic label.
    return AnimatedBuilder(
      animation: _agent,
      builder: (_, _) {
        final sid = AppState.I.activeSessionId;
        // Response-timeout watchdog (facade.stalledFor): swap the generic
        // label for the explicit "Still working…" once the run has been
        // silent for the whole response-wait window. Chosen as the least
        // invasive surfacing — the typing bubble already re-renders on
        // every facade notify, so the stalled state rides the same rebuild
        // with no new widget, timer or screen the composer has to own.
        final stalled = sid != null && _agent.stalledFor(sid);
        final status = sid == null ? null : _agent.statusFor(sid);
        final label = stalled
            ? 'Still working…'
            : (status == null || status.trim().isEmpty)
                ? 'Working…'
                : status.trim();
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 10),
          child: Row(
            children: [
              _ChaseDot(Aether.accent),
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
/// with edit/remove actions. Shown only when the facade reports queued
/// messages.
/// web-IDE GoalBar — the session goal as a strip above the composer dock:
/// objective, round chip, status; edit / pause / resume / clear actions.
/// Renders only while an unfinished goal exists (a `complete` goal is
/// hidden). Pause/resume flips the goal status directly; Clear removes the
/// goal via [AppState.clearGoal] with an Undo snack bar.
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
        // A finished goal is history, not a live strip.
        if (status == 'complete') return const SizedBox.shrink();
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
              // Clear removes the goal; Undo puts it back.
              IconButton(
                visualDensity: VisualDensity.compact,
                tooltip: 'Clear goal',
                icon: Icon(
                  Icons.clear_outlined,
                  size: 16,
                  color: Aether.textFaint,
                ),
                onPressed: () {
                  final sessionId = s.id;
                  final cleared = AppState.I.clearGoal(sessionId);
                  if (cleared == null) return;
                  showUndoSnackBar(
                    ScaffoldMessenger.of(context),
                    message: 'Goal cleared',
                    onUndo: () => AppState.I.restoreGoal(sessionId, cleared),
                  );
                },
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
                      Icon(
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
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: Aether.accent,
                          ),
                        ),
                        const SizedBox(width: 4),
                        Text(
                          '$inProg active',
                          style: TextStyle(
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

/// P8 Task 10 — offline prompt outbox chip: prompts composed while offline
/// (or queued before the process died) render here until the reconnect
/// flush sends them. Read-only; the flush is automatic on the
/// offline→online edge and at boot.
class _CloudOutboxChip extends StatelessWidget {
  const _CloudOutboxChip({this.sessionId});

  final String? sessionId;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: CloudSessionStore.I,
      builder: (_, _) {
        final sid = sessionId;
        final entries = sid == null
            ? const <OutboxEntry>[]
            : CloudSessionStore.I.outboxFor(sid);
        if (entries.isEmpty) return const SizedBox.shrink();
        return Padding(
          key: const ValueKey('cloud-outbox-chip'),
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
          child: Container(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
            decoration: BoxDecoration(
              color: Aether.surface,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Aether.warnLight.withValues(alpha: 0.4)),
            ),
            child: Row(
              children: [
                Icon(
                  Icons.cloud_upload_outlined,
                  size: 15,
                  color: Aether.warnLight,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    CloudSessionStore.I.offline
                        ? '${entries.length} message${entries.length == 1 ? '' : 's'} '
                            'waiting · sends automatically when you are back online'
                        : '${entries.length} message${entries.length == 1 ? '' : 's'} '
                            'waiting to send',
                    style: TextStyle(fontSize: 11.5, color: Aether.textMuted),
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

/// The cloud error row (Wave 1a — CH-019 / CH-031): every send or run
/// failure renders as plain language from the shared copy table
/// (`cloudErrorCopy`) with the ONE action that helps — Retry (same
/// clientMsgId for a refused prompt), Sign in, Open Plans (with a live
/// allowance-reset countdown), or Pick a model. Raw server text only
/// appears under "Details". A 409 `run_conflict` stays a silent refresh.
class _CloudErrorRow extends StatefulWidget {
  const _CloudErrorRow({this.sessionId, this.onRetry, this.onPickModel});

  final String? sessionId;
  final Future<void> Function()? onRetry;
  final VoidCallback? onPickModel;

  @override
  State<_CloudErrorRow> createState() => _CloudErrorRowState();
}

class _CloudErrorRowState extends State<_CloudErrorRow> {
  /// A 409 `run_conflict` refresh is fired once per recorded error.
  String? _conflictRefreshedKey;
  bool _showDetails = false;

  /// Re-renders the allowance countdown every 30 s while it is visible.
  Timer? _ticker;

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  void _ensureTicker(bool needed) {
    if (needed && _ticker == null) {
      _ticker = Timer.periodic(const Duration(seconds: 30), (_) {
        if (mounted) setState(() {});
      });
    } else if (!needed && _ticker != null) {
      _ticker?.cancel();
      _ticker = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([CloudAgentFacade.I, CloudSessionStore.I]),
      builder: (_, _) {
        final facade = CloudAgentFacade.I;
        final store = CloudSessionStore.I;
        final sid = widget.sessionId;
        final run = sid == null ? null : facade.runStateFor(sid);
        final code = run?.lastErrorCode;
        // A refused queued prompt of THIS chat surfaces through the same
        // row when no session-scoped error is recorded.
        OutboxEntry? refused;
        if (code == null && sid != null) {
          for (final entry in store.outboxFor(sid)) {
            if (entry.failed) {
              refused = entry;
              break;
            }
          }
        }
        final effectiveCode = code ?? refused?.failedCode;
        final message = code != null
            ? (run?.lastErrorMessage ?? '')
            : (refused?.failedMessage ?? '');
        final resetsAt = code != null
            ? (sid == null ? null : facade.errorResetsAtFor(sid))
            : store.outboxErrorResetsAt;
        if (effectiveCode == null) {
          _ensureTicker(false);
          return const SizedBox.shrink();
        }
        if (effectiveCode == 'run_conflict') {
          // Silent state refresh: the server already accepted the prompt.
          final key = '$effectiveCode:$message';
          if (_conflictRefreshedKey != key) {
            _conflictRefreshedKey = key;
            unawaited(
              CloudSessionStore.I.ready
                  .then((_) => CloudSessionStore.I.refreshSessions())
                  .catchError((Object e) {}),
            );
          }
          return const SizedBox.shrink();
        }
        final copy = cloudErrorCopy(
          effectiveCode,
          message: message,
          resetsAt: resetsAt,
        );
        _ensureTicker(resetsAt != null);
        Widget action(String label, VoidCallback onTap, {Key? key}) =>
            TextButton(key: key, onPressed: onTap, child: Text(label));
        final actions = <Widget>[
          switch (copy.action) {
            CloudErrorAction.retry when widget.onRetry != null => action(
                'Retry',
                () => unawaited(widget.onRetry!()),
                key: const ValueKey('cloud-error-retry'),
              ),
            CloudErrorAction.signIn => action(
                'Sign in',
                () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const AuthScreen()),
                ),
                key: const ValueKey('cloud-error-sign-in'),
              ),
            CloudErrorAction.openPlans => action(
                'Plans',
                () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const BillingScreen()),
                ),
                key: const ValueKey('cloud-error-plans'),
              ),
            CloudErrorAction.pickModel when widget.onPickModel != null =>
              action(
                'Pick model',
                widget.onPickModel!,
                key: const ValueKey('cloud-error-pick-model'),
              ),
            _ => const SizedBox.shrink(),
          },
          if (refused != null)
            action(
              'Discard',
              () => unawaited(facade.discardPendingSend(refused!.clientMsgId)),
              key: const ValueKey('cloud-error-discard'),
            )
          else
            action(
              'Dismiss',
              () {
                if (code != null && sid != null) facade.clearErrorFor(sid);
                CloudSessionStore.I.clearOutboxError();
              },
              key: const ValueKey('cloud-error-dismiss'),
            ),
        ];
        return Padding(
          key: const ValueKey('cloud-error-row'),
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
          child: Container(
            padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
            decoration: BoxDecoration(
              color: Aether.danger.withValues(alpha: 0.06),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Aether.danger.withValues(alpha: 0.4)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.error_outline, size: 15, color: Aether.danger),
                    const SizedBox(width: 8),
                    Expanded(
                      child: GestureDetector(
                        onTap: copy.detail == null
                            ? null
                            : () => setState(() => _showDetails = !_showDetails),
                        child: Text(
                          copy.text,
                          style: TextStyle(fontSize: 11.5, color: Aether.text),
                        ),
                      ),
                    ),
                  ],
                ),
                if (_showDetails && copy.detail != null)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(23, 4, 4, 0),
                    child: SelectableText(
                      copy.detail!,
                      style: TextStyle(
                        fontSize: 10.5,
                        color: Aether.textMuted,
                      ),
                    ),
                  ),
                Wrap(
                  alignment: WrapAlignment.end,
                  children: [
                    if (copy.detail != null)
                      action(
                        _showDetails ? 'Hide details' : 'Details',
                        () => setState(() => _showDetails = !_showDetails),
                      ),
                    ...actions,
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

/// The status line under a user row the server has not confirmed yet:
/// "Sending…", "Retrying…", "Waiting for connection — sends automatically"
/// or "Not sent" with Retry / Discard (CH-009, CH-011).
class _PendingSendStatus extends StatelessWidget {
  const _PendingSendStatus({required this.message});

  final Message message;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([CloudAgentFacade.I, CloudSessionStore.I]),
      builder: (_, _) {
        final facade = CloudAgentFacade.I;
        final state = facade.pendingStateOf(message);
        if (state == null) return const SizedBox.shrink();
        final id = CloudAgentFacade.pendingClientMsgIdOf(message)!;
        final (label, color) = switch (state) {
          PendingSendState.sending => ('Sending…', Aether.textFaint),
          PendingSendState.retrying =>
            ('Retrying — Ovid is not answering yet…', Aether.warnLight),
          PendingSendState.waitingForNetwork =>
            ("Waiting for connection — sends when you're back online",
                Aether.warnLight),
          PendingSendState.failed => ('Not sent', Aether.danger),
        };
        return Padding(
          key: ValueKey('pending-send-$id'),
          padding: const EdgeInsets.only(top: 2, right: 4),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (state == PendingSendState.failed)
                Icon(Icons.error_outline, size: 12, color: color)
              else
                Icon(Icons.schedule, size: 12, color: color),
              const SizedBox(width: 4),
              Flexible(
                child: Text(
                  label,
                  style: TextStyle(fontSize: 11, color: color),
                ),
              ),
              if (state == PendingSendState.failed) ...[
                TextButton(
                  key: ValueKey('pending-retry-$id'),
                  onPressed: () => unawaited(facade.retryPendingSend(id)),
                  child: const Text('Retry'),
                ),
                TextButton(
                  key: ValueKey('pending-discard-$id'),
                  onPressed: () => unawaited(facade.discardPendingSend(id)),
                  child: const Text('Discard'),
                ),
              ] else if (state != PendingSendState.sending)
                TextButton(
                  key: ValueKey('pending-discard-$id'),
                  onPressed: () => unawaited(facade.discardPendingSend(id)),
                  child: const Text('Discard'),
                ),
            ],
          ),
        );
      },
    );
  }
}

/// CH-035: the first history page failed — say so and offer Retry instead
/// of an empty chat that looks like lost history.
class _HistoryLoadFailed extends StatelessWidget {
  const _HistoryLoadFailed({required this.onRetry, required this.loading});

  final VoidCallback onRetry;
  final bool loading;

  @override
  Widget build(BuildContext context) {
    return Center(
      key: const ValueKey('chat-history-load-failed'),
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.cloud_off_outlined, size: 28, color: Aether.textFaint),
            const SizedBox(height: 10),
            Text(
              "Couldn't load this chat",
              style: TextStyle(fontSize: 15, color: Aether.text),
            ),
            const SizedBox(height: 4),
            Text(
              'Check your connection. Your messages are safe on Ovid.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: Aether.textMuted),
            ),
            const SizedBox(height: 12),
            loading
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : TextButton(
                    key: const ValueKey('chat-history-retry'),
                    onPressed: onRetry,
                    child: const Text('Retry'),
                  ),
          ],
        ),
      ),
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
    final agent = _agent;
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
                    // Full 48dp target; clearing is undoable (queued text
                    // and files come back with their original ids).
                    TextButton(
                      style: TextButton.styleFrom(
                        minimumSize: const Size(48, 48),
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        foregroundColor: Aether.textMuted,
                      ),
                      onPressed: () {
                        if (sid == null) {
                          for (var i = queue.length - 1; i >= 0; i--) {
                            agent.removeQueuedMessage(i);
                          }
                          onEdited();
                          return;
                        }
                        final taken = agent.takeQueuedMessages(sid);
                        onEdited();
                        if (taken.isEmpty) return;
                        showUndoSnackBar(
                          ScaffoldMessenger.of(context),
                          message:
                              'Cleared ${taken.length} queued message${taken.length == 1 ? '' : 's'}',
                          duration: const Duration(seconds: 6),
                          onUndo: () => agent.restoreQueuedMessages(sid, taken),
                        );
                      },
                      child: const Text(
                        'Clear all',
                        style: TextStyle(fontSize: 12),
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
    final agent = _agent;
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
    final agent = _agent;
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
  // pick. `CloudAgentFacade.approveRequest(..., note:)` remains the
  // programmatic path.

  /// Taps that land this soon after a NEW request replaces the card are
  /// ignored: a double-tap on Allow, or a tap aimed at the previous card,
  /// must not approve a request the user has not had a chance to read.
  static const _armDelay = Duration(milliseconds: 300);

  /// Details longer than this are shown in a scrollable box with a
  /// "Show all (N lines)" toggle instead of being clamped.
  static const _detailPreviewLines = 8;

  ApprovalRequest? _shown;
  bool _armed = false;
  bool _expanded = false;
  Timer? _armTimer;

  @override
  void dispose() {
    _armTimer?.cancel();
    super.dispose();
  }

  /// Called from build: (re)arms the tap guard whenever a different request
  /// is rendered. Only mutates plain fields; the timer's setState runs later.
  void _track(ApprovalRequest req) {
    if (identical(req, _shown)) return;
    _shown = req;
    _armed = false;
    _expanded = false;
    _armTimer?.cancel();
    _armTimer = Timer(_armDelay, () {
      if (mounted) setState(() => _armed = true);
    });
  }

  /// Resolves exactly the request [req] the card rendered — never whatever
  /// happens to be pending by the time the tap is delivered.
  void _decide(ApprovalRequest req, {required bool ok, bool always = false}) {
    if (!_armed || !identical(req, _shown)) return;
    if (always) {
      _agent.approveAlwaysRequest(req);
    } else {
      _agent.approveRequest(req, ok);
    }
  }

  static String _toolLabel(String tool) {
    final words = tool
        .replaceAll(RegExp(r'[_\-.]+'), ' ')
        .trim()
        .split(RegExp(r'\s+'))
        .where((w) => w.isNotEmpty)
        .toList();
    if (words.isEmpty) return 'Approval needed';
    final first = words.first;
    words[0] = first[0].toUpperCase() + first.substring(1);
    return words.join(' ');
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([_agent, AppState.I]),
      builder: (_, _) {
        final req = _agent.pendingApproval;
        if (req == null) {
          // Another session may be waiting on an approval this dock cannot
          // show, because it renders the foreground session's bucket. Say so
          // instead of letting it auto-deny in silence.
          final elsewhere = _agent.pendingApprovalsElsewhere;
          if (elsewhere.isEmpty) return const SizedBox.shrink();
          return _OtherSessionsApprovalRow(items: elsewhere);
        }
        // ── ask_user_question mode — structured Q&A card ──
        if (req.questions != null && req.questions!.isNotEmpty) {
          return _QuestionsCard(req, key: ObjectKey(req));
        }
        // ── Plan exit (exit_plan_mode) and every other cloud prompt — the
        // standard card ──
        // The cloud gate's `approval_requested` payload carries no structured
        // questions (only summary/detail/allowAlways), so the plan-exit
        // prompt renders as the standard Allow/Deny card: the summary asks
        // "switch to the build agent?", the detail carries the plan recap,
        // and the decision vocabulary is the wire's allow/deny/always. The
        // Q&A card above stays reserved for a prompt that actually ships a
        // question set.
        _track(req);
        return _standardCard(context, req);
      },
    );
  }

  Widget _standardCard(BuildContext context, ApprovalRequest req) {
    // Title says WHICH tool is asking; the monospace box below shows exactly
    // what will run. When there is no separate detail, the summary itself is
    // the thing being approved, so it goes in the (never clamped) box.
    // CH-017: a plan prompt is a plan review, not a generic tool ask.
    final isPlan = req.kind == 'plan';
    final hasDetail = req.detail.isNotEmpty && req.detail != req.summary;
    final title = isPlan
        ? 'Review the plan'
        : hasDetail && req.summary.trim().isNotEmpty
        ? req.summary.trim()
        : _toolLabel(req.tool);
    final body = isPlan
        ? (req.planBody ?? req.detail)
        : hasDetail
        ? req.detail
        : req.summary;
    // While the answer travels to the server the card stays, disabled.
    final sending = req.sending;
    final lines = body.split('\n');
    final long = lines.length > _detailPreviewLines;
    final isCommit = req.tool == 'commit';
    final screenH = MediaQuery.sizeOf(context).height;
    final maxBoxH = _expanded ? math.max(180.0, screenH * 0.5) : 180.0;
    final monoStyle = TextStyle(
      fontSize: 12,
      height: 1.4,
      color: Aether.text,
      fontFamily: Aether.mono,
    );

    final buttonText = const TextStyle(fontSize: 13);
    final deny = OutlinedButton(
      key: const ValueKey('approval-deny'),
      style: OutlinedButton.styleFrom(
        foregroundColor: Aether.dangerC,
        side: BorderSide(color: Aether.dangerC.withValues(alpha: 0.6)),
        minimumSize: const Size(64, 48),
        padding: const EdgeInsets.symmetric(horizontal: 12),
      ),
      onPressed: sending ? null : () => _decide(req, ok: false),
      child: Text(isPlan ? 'Keep planning' : 'Deny', style: buttonText),
    );
    final allow = FilledButton(
      key: const ValueKey('approval-allow'),
      style: FilledButton.styleFrom(
        backgroundColor: Aether.successLight,
        foregroundColor: Colors.white,
        minimumSize: const Size(64, 48),
        padding: const EdgeInsets.symmetric(horizontal: 12),
      ),
      onPressed: sending ? null : () => _decide(req, ok: true),
      child: Text(isPlan ? 'Approve plan' : 'Allow', style: buttonText),
    );
    // No scope choice: an Always Allow is recorded for THIS mode and THIS
    // session, persists across restarts, and is purged when the session is
    // deleted.
    final always = req.allowAlways && !isPlan
        ? TextButton(
            key: const ValueKey('approval-always'),
            style: TextButton.styleFrom(
              foregroundColor: Aether.accentC,
              minimumSize: const Size(64, 48),
              padding: const EdgeInsets.symmetric(horizontal: 12),
            ),
            onPressed: sending
                ? null
                : () => _decide(req, ok: true, always: true),
            child: Text(
              'Always Allow',
              textAlign: TextAlign.center,
              style: buttonText,
            ),
          )
        : null;

    return Container(
      margin: const EdgeInsets.fromLTRB(12, 0, 12, 6),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
      decoration: BoxDecoration(
        color: Aether.warnLight.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Aether.warnLight.withValues(alpha: 0.4)),
      ),
      child: Semantics(
        container: true,
        liveRegion: true,
        label: 'Approval required: $title',
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 1),
                  child: Icon(
                    isPlan
                        ? Icons.map_outlined
                        : Icons.warning_amber_rounded,
                    size: 16,
                    color: Aether.warnLight,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                      color: Aether.text,
                    ),
                  ),
                ),
              ],
            ),
            if (body.trim().isNotEmpty) ...[
              const SizedBox(height: 6),
              // Detail on its own full-width row (never squeezed beside the
              // buttons) and never clamped: anything past the box height
              // scrolls, so every byte being approved is reachable.
              ConstrainedBox(
                key: ValueKey(
                  isCommit ? 'commit-approval-detail' : 'approval-detail',
                ),
                constraints: BoxConstraints(maxHeight: maxBoxH),
                child: Scrollbar(
                  child: SingleChildScrollView(
                    key: ObjectKey(req),
                    child: SelectionArea(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          for (final line in lines)
                            Text(line, style: monoStyle),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              if (long)
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton(
                    style: TextButton.styleFrom(
                      foregroundColor: Aether.textMuted,
                      minimumSize: const Size(48, 40),
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                    ),
                    onPressed: () => setState(() => _expanded = !_expanded),
                    child: Text(
                      _expanded
                          ? 'Show less'
                          : 'Show all (${lines.length} lines)',
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
                ),
            ],
            if (req.expiresAt != null && !sending)
              _ApprovalCountdown(expiresAt: req.expiresAt!),
            if (sending)
              Padding(
                key: const ValueKey('approval-sending'),
                padding: const EdgeInsets.only(top: 6),
                child: Row(
                  children: [
                    SizedBox(
                      width: 12,
                      height: 12,
                      child: CircularProgressIndicator(
                        strokeWidth: 1.5,
                        color: Aether.textMuted,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      'Sending your answer…',
                      style: TextStyle(fontSize: 12, color: Aether.textMuted),
                    ),
                  ],
                ),
              ),
            const SizedBox(height: 8),
            // Full-width action row. Narrow widths (or large text) move
            // Always Allow onto its own row so Deny / Allow keep a wide,
            // well-separated 48dp target.
            LayoutBuilder(
              builder: (context, constraints) {
                final scale = MediaQuery.textScalerOf(context).scale(1);
                final oneRow =
                    always == null || constraints.maxWidth / scale >= 300;
                if (oneRow) {
                  return Row(
                    children: [
                      Expanded(child: deny),
                      if (always != null) ...[
                        const SizedBox(width: 8),
                        Expanded(child: always),
                      ],
                      const SizedBox(width: 8),
                      Expanded(child: allow),
                    ],
                  );
                }
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        Expanded(child: deny),
                        const SizedBox(width: 8),
                        Expanded(child: allow),
                      ],
                    ),
                    const SizedBox(height: 4),
                    always,
                  ],
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

/// CH-017: the server auto-denies an unanswered prompt at `expiresAt`; the
/// card says how long is left (ticking) instead of failing silently.
class _ApprovalCountdown extends StatefulWidget {
  const _ApprovalCountdown({required this.expiresAt});

  final DateTime expiresAt;

  @override
  State<_ApprovalCountdown> createState() => _ApprovalCountdownState();
}

class _ApprovalCountdownState extends State<_ApprovalCountdown> {
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() {});
      if (!widget.expiresAt.isAfter(DateTime.now())) _tick?.cancel();
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final left = widget.expiresAt.difference(DateTime.now());
    final String text;
    if (left.isNegative || left == Duration.zero) {
      text = 'Timed out: the request was denied.';
    } else {
      final m = left.inMinutes;
      final sec = (left.inSeconds % 60).toString().padLeft(2, '0');
      text = 'Denied automatically in $m:$sec if you do not answer.';
    }
    return Padding(
      key: const ValueKey('approval-countdown'),
      padding: const EdgeInsets.only(top: 6),
      child: Text(
        text,
        style: TextStyle(fontSize: 12, color: Aether.textMuted),
      ),
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
          Row(
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
                  // P8 Task 10: re-pointed off the legacy no-arg `approve`
                  // onto the surface's approveRequest flow so the questions
                  // card stays answerable on the facade (the member itself
                  // dies with Task 19).
                  if (identical(_agent.pendingApproval, widget.req)) {
                    _agent.approveRequest(widget.req, false);
                  }
                },
              ),
              const SizedBox(width: 4),
              FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: Aether.accentFill,
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
                          _agent.pendingApproval,
                          widget.req,
                        )) {
                          return;
                        }
                        for (final q in widget.req.questions!) {
                          final a = _answerFor(q);
                          if (a != null) widget.req.answers[q.id] = a;
                        }
                        // P8 Task 10: same re-point as the Skip action.
                        _agent.approveRequest(widget.req, true);
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
          borderSide: BorderSide(color: Aether.inputBorder),
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

/// Studio-mode composer chip: opens Studio (the user's cloud workspace).
///
/// It used to be a "Sandbox folder (Studio)" picker that pinned a PHONE
/// folder the cloud agent never saw (CH-027 / ST-012 / CT-008) — and a reset
/// then deleted that folder recursively (CH-026). Studio is server-side now;
/// there is no device folder to pick.
class _StudioChip extends StatelessWidget {
  const _StudioChip();

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([AppState.I, _agent]),
      builder: (_, _) {
        final s = AppState.I.activeSession;
        final isStudio =
            _agent.mode == AgentMode.studio ||
            (s?.mode == AgentMode.studio.name);
        if (!isStudio) return const SizedBox.shrink();
        return Padding(
          padding: const EdgeInsets.only(right: 6),
          child: Tooltip(
            message: 'Open Studio',
            child: InkWell(
              key: const ValueKey('composer-studio-chip'),
              borderRadius: BorderRadius.circular(16),
              onTap: () => openStudio(context),
              child: Container(
                constraints: const BoxConstraints(minHeight: 32),
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(16),
                  color: Aether.accent.withValues(alpha: 0.12),
                  border: Border.all(
                    color: Aether.accent.withValues(alpha: 0.5),
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.code, size: 14, color: Aether.accent),
                    const SizedBox(width: 5),
                    Text(
                      'Studio',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                        height: 20 / 13,
                        color: Aether.accent,
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
            _agent.planMode = false;
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
      animation: _agent,
      builder: (_, _) {
        final m = _agent.mode;
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
    final sessionId = AppState.I.activeSessionId;
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
                  leading: Icon(
                    m.icon,
                    size: 18,
                    color: _skipsApprovals(m) ? Aether.dangerC : m.color,
                  ),
                  title: Text(
                    m.label,
                    style: TextStyle(
                      fontSize: 13.5,
                      color: _skipsApprovals(m) ? Aether.dangerC : null,
                    ),
                  ),
                  subtitle: _accessModeSubtitle(
                    m,
                    TextStyle(
                      fontSize: 11,
                      color: Aether.textFaint,
                      height: 1.4,
                    ),
                  ),
                  trailing: _agent.mode == m
                      ? Icon(Icons.check, size: 18, color: Aether.accent)
                      : null,
                  onTap: () async {
                    Navigator.pop(context);
                    await _pickAccessMode(context, m, sessionId);
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

/// Modes that skip every app-level approval prompt. They get a danger
/// accent and an explicit "Tools run without asking" line in both access-mode
/// sheets, and a confirmation before they are switched on.
bool _skipsApprovals(AgentMode m) => m == AgentMode.drive;

Widget _accessModeSubtitle(AgentMode m, TextStyle base) {
  if (!_skipsApprovals(m)) return Text(m.hint, style: base);
  return Text.rich(
    TextSpan(
      style: base,
      children: [
        TextSpan(
          text: 'Tools run without asking. ',
          style: TextStyle(color: Aether.dangerC, fontWeight: FontWeight.w600),
        ),
        TextSpan(text: m.hint),
      ],
    ),
  );
}

/// Sessions (this process) where the user already confirmed Full Access.
/// Re-confirmation is still required while a run is active in the session.
final Set<String> _fullAccessConfirmedSessions = <String>{};

@visibleForTesting
void debugResetFullAccessConfirmations() =>
    _fullAccessConfirmedSessions.clear();

/// The single path both access-mode sheets use to apply a pick. Switching to
/// Full Access is confirmed the first time per session and whenever a run is
/// in progress there (it takes effect on that run's next tool call), and the
/// change is pinned to the composer's [sessionId] so a background run's
/// session is never the one modified.
Future<void> _pickAccessMode(
  BuildContext context,
  AgentMode m,
  String? sessionId,
) async {
  final session = AppState.I.sessionById(sessionId);
  final current = AgentMode.values.firstWhere(
    (x) => x.name == session?.mode,
    orElse: () => _agent.mode,
  );
  if (_skipsApprovals(m) && current != m) {
    final key = sessionId ?? '';
    final running = sessionId != null && _agent.busyFor(sessionId);
    if (running || !_fullAccessConfirmedSessions.contains(key)) {
      if (!context.mounted) return;
      final ok = await showDialog<bool>(
        context: context,
        builder: (d) => AlertDialog(
          key: const ValueKey('full-access-confirm'),
          title: const Text('Switch to Full Access?'),
          content: SingleChildScrollView(
            child: Text(
              'Ovid will run commands and change files without asking. '
              'Destructive commands still ask.'
              '${running ? '\n\nA task is running in this chat. The change '
                        'applies from its next tool call.' : ''}',
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(d, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: Aether.dangerC,
                foregroundColor: Colors.white,
              ),
              onPressed: () => Navigator.pop(d, true),
              child: const Text('Switch to Full Access'),
            ),
          ],
        ),
      );
      if (ok != true) return;
      _fullAccessConfirmedSessions.add(key);
    }
  }
  if (sessionId != null) {
    // The chat may have been deleted while the dialog was open.
    if (AppState.I.sessionById(sessionId) == null) return;
    _agent.setMode(m, sessionId: sessionId);
  } else {
    _agent.setMode(m);
  }
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
      // Prose is selectable (long-press to select/copy) and web links open in
      // the system browser, matching the cloud viewer's read-only contract.
      selectable: true,
      onTapLink: (text, href, title) => _openLink(context, text, href, title),
      // Never the package default (Image.network on render / Image.file for
      // any path): remote images wait for a tap, see [safeMarkdownImage].
      imageBuilder: safeMarkdownImage,
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
        a: TextStyle(
          color: Aether.accent,
          decoration: TextDecoration.underline,
        ),
      ),
    );
  }
}

/// Open a URL found in tool output — only after the user has seen its real
/// host in the confirm sheet. http(s) only; userinfo is stripped.
Future<void> _openToolOutputLink(BuildContext context, String raw) async {
  final link = safeLinkFrom(raw, webOnly: true);
  if (link == null) return;
  final messenger = ScaffoldMessenger.maybeOf(context);
  final choice = await confirmLinkSheet(context, link);
  if (choice != LinkChoice.open) return;
  try {
    final ok = await launchUrl(link.uri, mode: LaunchMode.externalApplication);
    if (!ok) throw StateError('not launched');
  } catch (_) {
    messenger?.showSnackBar(
      const SnackBar(
        content: Text('Could not open this link.'),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }
}

/// Open a markdown link: http(s) through the SYSTEM browser (the cloud
/// viewer is a read-only screencast with no navigate op), everything else
/// (mailto:, tel:, custom schemes) through the platform handler.
///
/// Model-authored links are attacker-influenced, so a confirm sheet with the
/// real host comes first whenever the link could deceive: a non-http(s)
/// scheme (it triggers another app), a `user@` prefix, an internationalized
/// host, or link text that names a different site than the href.
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
    raw = 'https://$t';
  }
  var uri = Uri.tryParse(raw);
  // Schemeless hrefs ("example.com/a") are relative in markdown terms, but
  // browsers expect a scheme — normalize before deciding anything.
  if (uri != null && uri.scheme.isEmpty && uri.host.isNotEmpty) {
    uri = Uri.tryParse('https://$raw');
  }
  if (uri == null) return;
  final link = safeLinkFrom(uri.toString());
  if (link == null) return;
  final messenger = ScaffoldMessenger.of(context);
  final needsConfirm =
      !link.isWeb ||
      link.hadUserInfo ||
      link.isIdn ||
      linkTextMisleads(text, link);
  if (needsConfirm) {
    final choice = await confirmLinkSheet(context, link, linkText: text);
    if (choice != LinkChoice.open || !context.mounted) return;
  }
  if (link.isWeb) {
    // The on-device browser was removed (P8 Task 16), and the cloud viewer
    // is a READ-ONLY screencast with no navigate op — opening it on a link
    // tap would show the agent's last page, not the tapped URL. So every
    // build opens the link in the SYSTEM browser; the header button still
    // opens the cloud viewer.
    try {
      final ok = await launchUrl(
        link.uri,
        mode: LaunchMode.externalApplication,
      );
      if (!ok) throw StateError('not launched');
    } catch (_) {
      messenger.showSnackBar(
        const SnackBar(
          content: Text('Could not open this link.'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
    return;
  }
  try {
    final ok = await launchUrl(link.uri, mode: LaunchMode.externalApplication);
    if (!ok) {
      // No handler (missing <queries> entry / app not installed) — tell the
      // user instead of swallowing the failure.
      messenger.showSnackBar(
        SnackBar(
          content: Text('No app can open ${link.uri.scheme} links.'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  } catch (_) {
    messenger.showSnackBar(
      const SnackBar(
        content: Text('Could not open this link.'),
        behavior: SnackBarBehavior.floating,
      ),
    );
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
                // Syntax-highlighted (keywords, strings, comments, numbers,
                // types) via the shared dependency-free highlighter.
                : SelectableText.rich(
                    highlightCode(
                      code,
                      lang: lang,
                      style: TextStyle(
                        fontFamily: Aether.mono,
                        fontSize: 11,
                        height: 19 / 11,
                        color: Aether.text,
                      ),
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
final Map<String, ({bool exists, int size})> _imageFileInfoCache = {};
const _imageFileInfoCacheCap = 512;

class _ImageFileInfo extends StatefulWidget {
  const _ImageFileInfo({required this.path, required this.builder});

  final String path;
  final Widget Function(BuildContext context, bool exists, int? size) builder;

  @override
  State<_ImageFileInfo> createState() => _ImageFileInfoState();
}

class _ImageFileInfoState extends State<_ImageFileInfo> {
  ({bool exists, int size})? _info;

  /// Pending delayed re-stat while the row is mounted and the file has not
  /// arrived yet (see [_stat]) — cancelled on dispose or a path change.
  Timer? _recheck;

  @override
  void initState() {
    super.initState();
    _resolve();
  }

  @override
  void didUpdateWidget(_ImageFileInfo oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.path != widget.path) _resolve();
  }

  @override
  void dispose() {
    _recheck?.cancel();
    super.dispose();
  }

  void _resolve() {
    final path = widget.path;
    _recheck?.cancel();
    _recheck = null;
    final cached = _imageFileInfoCache[path];
    if (cached != null) {
      // Only POSITIVE results are cached (see the write below), so a cache
      // hit is always trusted.
      _info = cached;
      return;
    }
    _stat(path);
  }

  void _stat(String path) {
    // Synchronous stat: [build] must stay pure (the constraint the header
    // comment pins), but the lifecycle entry points may stat directly —
    // statSync is metadata-only (microseconds) and runs in initState,
    // didUpdateWidget and the 5s re-arm below, never per rebuild. The old
    // async stat never completed under the widget-test binding's fake-async
    // zone, leaving every row stuck on the optimistic `exists ?? true`
    // default — the tests only ever asserted the PENDING state.
    ({bool exists, int size}) info;
    try {
      final stat = File(path).statSync();
      info = (
        exists: stat.type != FileSystemEntityType.notFound,
        size: stat.size,
      );
    } catch (_) {
      info = (exists: false, size: 0);
    }
    if (info.exists) {
      if (_imageFileInfoCache.length >= _imageFileInfoCacheCap) {
        _imageFileInfoCache.remove(_imageFileInfoCache.keys.first);
      }
      _imageFileInfoCache[path] = info;
    } else if (mounted && widget.path == path) {
      // A notFound stat is a POINT IN TIME, never a verdict: generated
      // images land in the workspace after the row first renders, so a
      // negative result is never cached. While the row stays mounted the
      // stat repeats every 5s (bounded: only built rows poll, and dispose
      // cancels); once the file lands, the positive result is cached and the
      // polling stops for good.
      _recheck = Timer(const Duration(seconds: 5), () {
        _recheck = null;
        if (mounted && widget.path == path) _stat(path);
      });
    }
    if (mounted && widget.path == path) setState(() => _info = info);
  } // ignore: unnecessary_setstate_in_tests

  @override
  Widget build(BuildContext context) {
    final info = _info;
    return widget.builder(context, info?.exists ?? true, info?.size);
  }
}
