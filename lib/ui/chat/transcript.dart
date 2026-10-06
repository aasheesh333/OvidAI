import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:url_launcher/url_launcher.dart';

import '../../core/agent_service.dart';
import '../../core/diag.dart';
import '../../core/format.dart';
import '../../core/native_share.dart';
import '../../core/state.dart';
import '../../core/theme.dart';
import '../browser_screen.dart';
import '../chat_layout.dart';
import '../html_artifact_view.dart';
import '../sandbox_setup.dart';
import '../share_actions.dart';
import '../subagent_screen.dart';
import '../transcript_model.dart';
import '../widgets/aether_primitives.dart';

/// Chat transcript — the single home of every transcript row system.
///
/// Two layers, one file:
///
/// 1. The shared Aether row primitives ([AetherSurface], [ChatMessageRow],
///    [ChatToolCallCard]) — the wave-2 Aether rendering of message and
///    tool-call rows on the shared [ChatLayout] width axis. They used to
///    live in `chat_layout.dart`; that file now owns only the width axis
///    and re-exports these from here.
/// 2. The production transcript: [ChatTranscript] (the read-only bounded
///    transcript the subagent view reuses), the live row widgets the chat
///    screen builds through [buildChatTranscriptItem], and the markdown
///    renderer ([ovidFontColor] and friends). Rendering and behavior are
///    unchanged — this is a pure relocation from `chat_screen.dart`.
///
/// turn-process folding: consecutive assistant tool/reasoning
/// messages collapse into a single expandable strip ("N tool calls ·
/// Thought for a while") that sits right before the final answer.
/// The LAST tool/reasoning run (no text after it yet, or the last tool
/// in a run still in progress) stays unfolded — same as Compact.

/// The subagent transcript page size — a larger page than the main chat's,
/// so a long child run is not re-folded in full on every rebuild.
const int _subagentTranscriptPage = 200;

// ═══════════════════════════════════════════════════════════════════════
// Wave-2 UI redesign — Aether transcript primitives.
//
// These moved here from `chat_layout.dart` so all transcript rows share one
// home. [ChatLayout] itself stays behind as the pure width axis (behavior
// pinned by test/chat_layout_test.dart) and re-exports the widgets below.
// ═══════════════════════════════════════════════════════════════════════

/// Low-level Aether surface: rounded corner, hairline border, soft shadow.
///
/// Base container for transcript message rows. [AetherCard] is deliberately
/// NOT used for plain messages — rows need a bare padded surface, not
/// header/footer section chrome. The construction mirrors [AetherCard]'s
/// surface treatment so rows and cards read as one material.
class AetherSurface extends StatelessWidget {
  final Widget child;
  final EdgeInsets padding;
  final Color? color;
  final double radius;

  const AetherSurface({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
    this.color,
    this.radius = AetherRadius.rLg,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(color: Aether.hairline),
        boxShadow: AetherShadows.shadowS,
      ),
      clipBehavior: Clip.antiAlias,
      child: Material(
        color: color ?? Aether.surface,
        borderRadius: BorderRadius.circular(radius),
        child: Padding(padding: padding, child: child),
      ),
    );
  }
}

/// One transcript message row on the shared [ChatLayout] width axis.
///
/// User rows align right and cap at [ChatLayout.userBubbleMaxWidth] on an
/// accent-tinted [AetherSurface]; assistant rows align left and cap at
/// [ChatLayout.contentWidth] on the plain surface. An optional [statusLabel]
/// renders as an [AetherPill] above the bubble (streaming/thinking state);
/// [footer] is the per-message action-row slot underneath.
class ChatMessageRow extends StatelessWidget {
  final ChatLayout layout;
  final bool isUser;
  final Widget child;

  /// Key applied to the bubble surface so callers/tests can pin geometry
  /// (e.g. `ValueKey('chat-user-bubble-$msgIndex')`).
  final Key? bubbleKey;
  final String? statusLabel;
  final Color? statusColor;
  final Widget? footer;

  const ChatMessageRow({
    super.key,
    required this.layout,
    required this.isUser,
    required this.child,
    this.bubbleKey,
    this.statusLabel,
    this.statusColor,
    this.footer,
  });

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Column(
        crossAxisAlignment: isUser
            ? CrossAxisAlignment.end
            : CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (statusLabel != null) ...[
            AetherPill(
              label: statusLabel!,
              color: statusColor ?? Aether.accent,
            ),
            const SizedBox(height: 6),
          ],
          ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: isUser
                  ? layout.userBubbleMaxWidth
                  : layout.contentWidth,
            ),
            child: AetherSurface(
              key: bubbleKey,
              color: isUser ? Aether.accentSoft : Aether.surface,
              child: DefaultTextStyle.merge(
                style: AetherType.body,
                child: child,
              ),
            ),
          ),
          ?footer,
        ],
      ),
    );
  }
}

/// Live/final state of a tool-call bubble, mirrored from the transcript's
/// `toolState` strings ('running'/'error'/'stopped'/'unknown', else done).
enum ChatToolState { running, done, error, stopped, unknown }

/// Tool-call bubble: an [AetherCard] whose header carries the tool icon,
/// title, and one-line summary, with the [state] shown as a trailing
/// [AetherPill]. When [detail] is present the card body discloses the full
/// detail in a mono code block on tap.
class ChatToolCallCard extends StatefulWidget {
  final ChatToolState state;
  final IconData icon;
  final String title;
  final String? summary;
  final String? detail;

  const ChatToolCallCard({
    super.key,
    required this.state,
    required this.title,
    this.icon = Icons.bolt_outlined,
    this.summary,
    this.detail,
  });

  /// Human label for [state] shown in the trailing [AetherPill].
  static String stateLabel(ChatToolState state) => switch (state) {
    ChatToolState.running => 'Running',
    ChatToolState.done => 'Done',
    ChatToolState.error => 'Error',
    ChatToolState.stopped => 'Stopped',
    ChatToolState.unknown => 'Unknown',
  };

  /// Pill color for [state]; matches the transcript's state-dot palette.
  static Color stateColor(ChatToolState state) => switch (state) {
    ChatToolState.running => Aether.accent,
    ChatToolState.done => Aether.successC,
    ChatToolState.error => Aether.dangerC,
    ChatToolState.stopped => Aether.warnLight,
    ChatToolState.unknown => Aether.textFaint,
  };

  @override
  State<ChatToolCallCard> createState() => _ChatToolCallCardState();
}

class _ChatToolCallCardState extends State<ChatToolCallCard> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final hasDetail = (widget.detail ?? '').trim().isNotEmpty;
    return AetherCard(
      padding: const EdgeInsets.all(12),
      title: Row(
        children: [
          Icon(widget.icon, size: 14, color: Aether.textMuted),
          const SizedBox(width: 7),
          Flexible(
            child: Text(
              widget.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AetherType.title.copyWith(fontSize: 12),
            ),
          ),
          if ((widget.summary ?? '').isNotEmpty) ...[
            const SizedBox(width: 7),
            Flexible(
              child: Text(
                widget.summary!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 11.5,
                  color: Aether.textMuted,
                  fontFamily: Aether.mono,
                ),
              ),
            ),
          ],
        ],
      ),
      trailing: AetherPill(
        label: ChatToolCallCard.stateLabel(widget.state),
        color: ChatToolCallCard.stateColor(widget.state),
      ),
      child: hasDetail
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                InkWell(
                  key: const ValueKey('chat-tool-card-toggle'),
                  borderRadius: BorderRadius.circular(6),
                  onTap: () => setState(() => _open = !_open),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text('Details', style: AetherType.label),
                        const SizedBox(width: 4),
                        AnimatedRotation(
                          turns: _open ? 0.5 : 0.0,
                          duration: const Duration(milliseconds: 150),
                          child: Icon(
                            Icons.expand_more,
                            size: 16,
                            color: Aether.textFaint,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                if (_open)
                  Container(
                    width: double.infinity,
                    margin: const EdgeInsets.only(top: 4),
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: Aether.codeBg,
                      borderRadius: BorderRadius.circular(AetherRadius.rSm),
                    ),
                    child: Text(
                      widget.detail!,
                      style: AetherType.mono.copyWith(color: Aether.textMuted),
                    ),
                  ),
              ],
            )
          : const SizedBox.shrink(),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════
// Production transcript (relocated from `chat_screen.dart`, unchanged).
// ═══════════════════════════════════════════════════════════════════════

/// Keep the platform's nonlinear accessibility curve, then apply chat zoom.
class ChatTextScaler extends TextScaler {
  final TextScaler inherited;
  final double zoom;
  const ChatTextScaler(this.inherited, this.zoom);

  @override
  double scale(double fontSize) => inherited.scale(fontSize) * zoom;

  @override
  double get textScaleFactor => scale(14) / 14;
}

/// Read-only transcript for ONE session — the same rendering the main chat
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
            if (li == items.length) return const TypingBubble();
            return buildChatTranscriptItem(
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
            textScaler: ChatTextScaler(
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
class TranscriptRowIn extends StatefulWidget {
  final Widget child;
  const TranscriptRowIn({super.key, required this.child});
  @override
  State<TranscriptRowIn> createState() => TranscriptRowInState();
}

class TranscriptRowInState extends State<TranscriptRowIn> with SingleTickerProviderStateMixin {
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

Widget buildChatTranscriptItem(
  ChatItem item,
  dynamic s, {
  required VoidCallback onAction,
  required TextEditingController? input,
  required ChatLayout layout,
}) {
  if (item is SingleItem) {
    return TranscriptRowIn(
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
  return TranscriptRowIn(child: _TurnProcessStrip(group: g.msgs));
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

/// web-IDE home parity (Ovid branding): centered logo, big greeting with
/// a mono pill beside it, then open space down to the composer.  The home layout has
/// NO suggestion rows on the home screen — the surface is intentionally
/// empty so the composer is the whole focus.  Entrance: `wide-in` fade+rise.
class ChatEmptyState extends StatelessWidget {
  const ChatEmptyState({super.key});
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
            child: TranscriptRowIn(
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
    if (name == 'hook' || name.startsWith('hook_') ||
        name.startsWith('hook:') || name == 'skill' ||
        name.startsWith('plugin:') || name.startsWith('plugin_')) {
      return _OvidMarkdown(content: detail, fontSize: 12, color: Aether.textMuted);
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

  static final _urlRe = RegExp(
    r'https?://[^\s)\]}>,"]+',
    caseSensitive: false,
  );
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
      return _enrichedText(content, baseColor, hasColor: hasColor, hasUrl: hasUrl);
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
        for (final line in lines) _enrichedLine(line, baseColor, hasColor: hasColor, hasUrl: hasUrl),
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
        matches.add((start: m.start, end: m.end, type: 'color', value: m.group(0)!));
      }
    }
    if (lineHasUrl) {
      for (final m in _urlRe.allMatches(line)) {
        matches.add((start: m.start, end: m.end, type: 'url', value: m.group(0)!));
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
        spans.add(TextSpan(text: line.substring(cursor, m.start), style: baseStyle));
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
          spans.add(WidgetSpan(
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
          ));
        }
      } else {
        // Tappable URL.
        spans.add(TextSpan(
          text: m.value,
          style: baseStyle.copyWith(
            color: Aether.accent,
            decoration: TextDecoration.underline,
            decorationColor: Aether.accent,
          ),
          recognizer: (TapGestureRecognizer()
            ..onTap = () {
              final uri = Uri.tryParse(m.value);
              if (uri != null) launchUrl(uri, mode: LaunchMode.externalApplication);
            }),
        ));
      }
      cursor = m.end;
    }
    if (cursor < line.length) {
      spans.add(TextSpan(text: line.substring(cursor), style: baseStyle));
    }

    return Text.rich(
      TextSpan(children: spans),
    );
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
class ProducedFilesCard extends StatelessWidget {
  final List<({String path, int size})> files;
  const ProducedFilesCard({super.key, required this.files});

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
        if (lastUser.attachments.any((a) => a.path == null || a.path!.isEmpty)) {
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
          TextButton(
            onPressed: navigator.pop,
            child: const Text('Cancel'),
          ),
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

class TypingBubble extends StatelessWidget {
  const TypingBubble({super.key});

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
