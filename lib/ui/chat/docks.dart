import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/agent_service.dart';
import '../../core/format.dart';
import '../../core/state.dart';
import '../../core/theme.dart';
import 'sheets.dart';

/// Chat docks — the strip between the transcript and the composer:
/// goal, todo, stats, queue, and approval. Relocated from
/// `chat_screen.dart` and unified:
///
/// * Every dock card renders on the ONE shared [ChatDockCard] chrome
///   (rounded surface, hairline border, compact padding); each dock keeps
///   its exact look through the card's color knobs.
/// * [ChatDocks] caps the strip at two visible docks. Actionable docks
///   (approval, then queue) are always pinned; informational docks beyond
///   the cap fold into a single expandable activity dock, so a busy
///   session never crowds the composer.

/// The single dock card: rounded surface, hairline border, compact
/// padding. Color knobs reproduce each dock's own look.
class ChatDockCard extends StatelessWidget {
  final Widget child;

  /// Surface fill; defaults to [Aether.surface].
  final Color? color;

  /// Border color; defaults to [Aether.hairline].
  final Color? borderColor;
  final double radius;
  final BorderRadius? borderRadius;
  final EdgeInsets margin;
  final EdgeInsets padding;

  const ChatDockCard({
    super.key,
    required this.child,
    this.color,
    this.borderColor,
    this.radius = 12,
    this.borderRadius,
    this.margin = const EdgeInsets.fromLTRB(12, 0, 12, 4),
    this.padding = const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: margin,
      padding: padding,
      decoration: BoxDecoration(
        color: color ?? Aether.surface,
        borderRadius: borderRadius ?? BorderRadius.circular(radius),
        border: Border.all(color: borderColor ?? Aether.hairline),
      ),
      child: child,
    );
  }
}

/// Dock strip above the composer: goal / todo / stats / queue / approval.
///
/// At most two docks are visible at once. Approval and queue docks are
/// actionable, so they always stay pinned; informational docks (goal,
/// todo, stats) fill the remaining slots and the rest fold into one
/// expandable activity dock. With two or fewer active docks the strip is
/// exactly the pre-cap column.
class ChatDocks extends StatelessWidget {
  final String? sessionId;
  final VoidCallback onEdited;

  /// Edits queued text in the composer while the service retains its files.
  final void Function(int id, String text) onEditToComposer;

  const ChatDocks({
    super.key,
    this.sessionId,
    required this.onEdited,
    required this.onEditToComposer,
  });

  static const _dockMargin = EdgeInsets.fromLTRB(12, 0, 12, 4);
  static const _overflowMargin = EdgeInsets.only(bottom: 4);

  /// Mirrors [_StatsLine]'s own visibility rule so the cap counts only
  /// docks that would actually render.
  bool _statsActive(ChatSession s) {
    final analytics = s.analytics;
    final used = analytics.contextTokens > 0
        ? analytics.contextTokens
        : AgentService.I.measuredContextTokens(s);
    return !(analytics.turns == 0 && used == 0);
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([AppState.I, AgentService.I]),
      builder: (_, _) {
        final app = AppState.I;
        final agent = AgentService.I;
        final s = app.activeSession;
        // Column order is the pre-cap order: goal, todo, stats, then the
        // actionable queue and approval docks closest to the composer.
        final informational = <Widget Function(EdgeInsets margin)>[
          if (s?.goal != null) (margin) => _GoalBar(margin: margin),
          if ((s?.todos ?? []).isNotEmpty) (margin) => _TodoDock(margin: margin),
          if (s != null && _statsActive(s)) (_) => const _StatsLine(),
        ];
        final actionable = <Widget>[];
        final sid = sessionId;
        final queue = sid == null
            ? agent.queuedMessages
            : agent.queuedMessagesFor(sid);
        if (queue.isNotEmpty) {
          actionable.add(
            _QueueDock(
              sessionId: sid,
              onEdited: onEdited,
              onEditToComposer: onEditToComposer,
            ),
          );
        }
        if (agent.pendingApproval != null ||
            agent.pendingApprovalsElsewhere.isNotEmpty) {
          actionable.add(const _ApprovalDock());
        }
        final freeSlots = actionable.length >= 2 ? 0 : 2 - actionable.length;
        if (informational.length <= freeSlots) {
          // Uncapped: exactly the pre-cap column.
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final dock in informational) dock(_dockMargin),
              ...actionable,
            ],
          );
        }
        final shown = informational.take(freeSlots);
        final overflow = informational.skip(freeSlots).toList();
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final dock in shown) dock(_dockMargin),
            _ActivityDock(
              count: overflow.length,
              children: [
                for (final dock in overflow) dock(_overflowMargin),
              ],
            ),
            ...actionable,
          ],
        );
      },
    );
  }
}

/// The overflow dock: informational docks beyond the two-dock cap fold
/// into this one expandable card so the strip stays two cards tall.
class _ActivityDock extends StatefulWidget {
  final int count;
  final List<Widget> children;
  const _ActivityDock({required this.count, required this.children});

  @override
  State<_ActivityDock> createState() => _ActivityDockState();
}

class _ActivityDockState extends State<_ActivityDock> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    return ChatDockCard(
      padding: EdgeInsets.zero,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          InkWell(
            key: const ValueKey('chat-activity-dock-toggle'),
            borderRadius: const BorderRadius.vertical(
              top: Radius.circular(12),
            ),
            onTap: () => setState(() => _open = !_open),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
              child: Row(
                children: [
                  Icon(
                    _open
                        ? Icons.keyboard_arrow_down
                        : Icons.keyboard_arrow_right,
                    size: 14,
                    color: Aether.textFaint,
                  ),
                  const SizedBox(width: 6),
                  const Icon(
                    Icons.pending_actions_outlined,
                    size: 13,
                    color: Aether.accent,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      'Activity · ${widget.count}',
                      style: TextStyle(
                        fontSize: 11,
                        color: Aether.textMuted,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (_open)
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 0, 10, 6),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: widget.children,
              ),
            ),
        ],
      ),
    );
  }
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
          onTap: () => showSessionMetricsSheet(context, s),
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
                    onTap: () => showSessionMetricsSheet(context, s),
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
}


/// web-IDE QueueDock — a strip above the input bar showing queued messages
/// with edit/remove actions. Shown only when [AgentService.queuedMessages]
/// is non-empty.
/// web-IDE GoalBar — the session goal as a strip above the composer dock:
/// objective, round chip, status; edit / pause / resume / clear actions.
/// Renders only while a goal exists. Pause/resume flips the goal status
/// directly; clear marks it complete (the strip then disappears).
class _GoalBar extends StatelessWidget {
  const _GoalBar({this.margin = const EdgeInsets.fromLTRB(12, 0, 12, 4)});

  /// Outer margin — the activity dock tightens it for overflow rows.
  final EdgeInsets margin;

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
        return ChatDockCard(
          margin: margin,
          radius: 10,
          borderColor: color.withValues(alpha: 0.4),
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
  const _TodoDock({this.margin = const EdgeInsets.fromLTRB(12, 0, 12, 4)});

  /// Outer margin — the activity dock tightens it for overflow rows.
  final EdgeInsets margin;

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
        return ChatDockCard(
          margin: widget.margin,
          radius: 10,
          padding: EdgeInsets.zero,
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
          child: ChatDockCard(
            margin: const EdgeInsets.fromLTRB(12, 0, 12, 0),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
            borderRadius: const BorderRadius.vertical(
              top: Radius.circular(14),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Header row
                Row(
                  children: [
                    Icon(Icons.queue_music, size: 13, color: Aether.textMuted),
                    const SizedBox(width: 6),
                    Expanded(child: Text(
                      '${queue.length} queued message${queue.length > 1 ? 's' : ''}',
                      style: TextStyle(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w600,
                        color: Aether.textMuted,
                      ),
                    )),
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
                // Guardrail: the rows scroll inside ~24% of the available
                // height instead of growing until the composer is pushed
                // off-screen. (The dock sits in a min-sized Column, so the
                // incoming maxHeight is unbounded — fall back to the
                // viewport height, which is always finite.)
                //
                // 2026-09-24: was 38%, which made the dock dominate the
                // screen. Rows still auto-size to their text — only the
                // ceiling and the chrome shrank.
                LayoutBuilder(
                  builder: (context, constraints) {
                    final reference = constraints.maxHeight.isFinite
                        ? constraints.maxHeight
                        : MediaQuery.sizeOf(context).height;
                    return ConstrainedBox(
                      constraints: BoxConstraints(maxHeight: reference * 0.24),
                      child: SingleChildScrollView(
                        child: Column(
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
                      ),
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
    return ChatDockCard(
      color: Aether.accent.withValues(alpha: 0.08),
      margin: const EdgeInsets.fromLTRB(12, 0, 12, 6),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
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
        return ChatDockCard(
          color: Aether.warnLight.withValues(alpha: 0.08),
          borderColor: Aether.warnLight.withValues(alpha: 0.4),
          margin: const EdgeInsets.fromLTRB(12, 0, 12, 6),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
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
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      for (final line in req.detail.split('\n'))
                                        Text(line, style: TextStyle(
                                          fontSize: 12, height: 1.4,
                                          color: Aether.text, fontFamily: Aether.mono,
                                        )),
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
    return ChatDockCard(
      color: Aether.accent.withValues(alpha: 0.06),
      borderColor: Aether.accent.withValues(alpha: 0.3),
      margin: const EdgeInsets.fromLTRB(12, 0, 12, 6),
      padding: const EdgeInsets.all(12),
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
          // The question list is bounded and scrollable so a tall set of
          // questions never overflows the viewport (header + actions stay
          // fixed; only the questions scroll).
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
