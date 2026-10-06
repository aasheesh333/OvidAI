import 'package:flutter/material.dart';

import '../core/format.dart';

import '../core/agent_service.dart';
import '../core/state.dart';
import '../core/theme.dart';
import 'chat_screen.dart';
import 'widgets/aether_primitives.dart';

/// Subagent session view — the child's OWN transcript.
///
/// A subagent is a real session, so this screen reuses the chat transcript
/// (streaming bubbles, reasoning cards, tool cards, produced files) and adds
/// the parent-side apparatus around it:
///   • a lineage breadcrumb back to the root chat,
///   • a descendants menu when the child dispatched its own agents,
///   • a status strip (state · elapsed · queued follow-ups),
///   • a composer that is read-only for a finished one-shot child and live
///     (with its own Stop) for a continuable one.
class SubagentScreen extends StatefulWidget {
  final String sessionId;
  const SubagentScreen({super.key, required this.sessionId});

  /// Open [sessionId]'s transcript. Safe to call with a stale id — it shows
  /// a "gone" state instead of crashing.
  static Future<void> open(BuildContext context, String sessionId) =>
      Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => SubagentScreen(sessionId: sessionId)),
      );

  @override
  State<SubagentScreen> createState() => _SubagentScreenState();
}

class _SubagentScreenState extends State<SubagentScreen> {
  final _input = TextEditingController();
  final _scroll = ScrollController();
  bool _sending = false;
  bool _firstJumpDone = false;

  @override
  void dispose() {
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _jumpToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      final pos = _scroll.position;
      if (!_firstJumpDone) {
        // First layout: start at the latest output like before.
        _firstJumpDone = true;
        _scroll.jumpTo(pos.maxScrollExtent);
        return;
      }
      // Follow-mode: only yank to the bottom when the user is already
      // near it — never steal the scroll position while they're reading
      // earlier output (mirrors the chat screen's _atBottom follow logic).
      if (pos.maxScrollExtent - pos.pixels > 48) return;
      _scroll.jumpTo(pos.maxScrollExtent);
    });
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty || _sending) return;
    setState(() => _sending = true);
    try {
      final status = await AgentService.I.continueSubagent(
        widget.sessionId,
        text,
        userReferences: true,
      );
      if (!mounted) return;
      // Refusals are also returned as status strings. Keep the user's draft
      // unless the service actually accepted it, including edits during await.
      if ((status.startsWith('queued as the next turn for ') ||
              status.startsWith('resumed ')) &&
          _input.text.trim() == text) {
        _input.clear();
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(status), behavior: SnackBarBehavior.floating),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not send follow-up: $e')),
      );
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([AppState.I, AgentService.I]),
      builder: (_, _) {
        final app = AppState.I;
        final s = app.sessionById(widget.sessionId);
        if (s == null) {
          return Scaffold(
            backgroundColor: Aether.bg,
            appBar: AppBar(
              leading: const BackButton(),
              title: const Text('Subagent'),
            ),
            body: SingleChildScrollView(
              child: AetherEmptyState(
                icon: Icons.account_tree_outlined,
                title: 'This subagent session is gone.',
              ),
            ),
          );
        }
        final agent = AgentService.I;
        final sub = agent.subagentForSession(s.id);
        final running = agent.busyFor(s.id);
        final children = app.childrenOf(s.id);
        final state = running ? 'running' : (s.agentState ?? 'finished');
        final continuable = s.agentContinuable;
        _jumpToBottom();

        return Scaffold(
          backgroundColor: Aether.bg,
          appBar: AppBar(
            leading: const BackButton(),
            title: Tooltip(
              message: s.agentLabel ?? s.title,
              child: Text(
                s.agentLabel ?? s.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 14),
              ),
            ),
            actions: [
              if (children.isNotEmpty)
                _DescendantsButton(sessionId: s.id, count: children.length),
              if (running)
                IconButton(
                  tooltip: 'Stop this subagent',
                  visualDensity: VisualDensity.compact,
                  icon: Icon(
                    Icons.stop_circle_outlined,
                    size: 20,
                    color: Aether.warnLight,
                  ),
                  onPressed: () => agent.stopSubagentRun(s.id),
                ),
              const SizedBox(width: 6),
            ],
          ),
          body: SafeArea(
            child: Column(
              children: [
                _Lineage(sessionId: s.id),
                _StatusStrip(session: s, state: state, sub: sub),
                Expanded(
                  child: s.messages.isEmpty
                      ? Center(
                          child: Text(
                            running ? 'Starting…' : 'No activity recorded.',
                            style: TextStyle(
                              fontSize: 12.5,
                              color: Aether.textFaint,
                            ),
                          ),
                        )
                      : ChatTranscript(
                          session: s,
                          scrollController: _scroll,
                          typing: running,
                        ),
                ),
                _Composer(
                  maxLines: MediaQuery.sizeOf(context).height -
                              MediaQuery.viewInsetsOf(context).bottom < 480
                      ? 2
                      : 4,
                  controller: _input,
                  continuable: continuable,
                  running: running,
                  sending: _sending,
                  onSend: _send,
                  onStop: () => agent.stopSubagentRun(s.id),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// Breadcrumb from the root chat down to this session. Tapping an ancestor
/// walks back up (subagent ancestors push their own view; the root chat pops
/// to the chat screen).
class _Lineage extends StatelessWidget {
  final String sessionId;
  const _Lineage({required this.sessionId});

  @override
  Widget build(BuildContext context) {
    final chain = AppState.I.lineageOf(sessionId);
    if (chain.length < 2) return const SizedBox.shrink();
    final ancestors = chain.sublist(0, chain.length - 1);
    return SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [for (final a in ancestors)
            Row(
            children: [
              TextButton(
                onPressed: () {
                  if (a.isSubagent) {
                    SubagentScreen.open(context, a.id);
                  } else {
                    AppState.I.selectSession(a.id);
                    Navigator.of(context).popUntil((r) => r.isFirst);
                  }
                },
                child: Text(
                  a.agentLabel ?? a.title,
                  style: TextStyle(fontSize: 10.5, color: Aether.textFaint),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 3),
                child: Icon(
                  Icons.chevron_right,
                  size: 11,
                  color: Aether.textFaint,
                ),
              ),
            ],
            ),
          ],
        ),
    );
  }
}

class _DescendantsButton extends StatelessWidget {
  final String sessionId;
  final int count;
  const _DescendantsButton({required this.sessionId, required this.count});

  @override
  Widget build(BuildContext context) {
    return Stack(
      alignment: Alignment.center,
      children: [
        IconButton(
          tooltip: 'Subagents of this agent',
          visualDensity: VisualDensity.compact,
          icon: const Icon(Icons.account_tree_outlined, size: 19),
          onPressed: () => showSubagentCatalog(context, sessionId),
        ),
        Positioned(
          top: 8,
          right: 8,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
            decoration: BoxDecoration(
              color: Aether.accent,
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text(
              '$count',
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
  }
}

class _StatusStrip extends StatelessWidget {
  final ChatSession session;
  final String state;
  final SubagentInfo? sub;
  const _StatusStrip({
    required this.session,
    required this.state,
    required this.sub,
  });

  @override
  Widget build(BuildContext context) {
    final color = switch (state) {
      'running' => Aether.accent,
      'stopped' || 'stopping' => Aether.warnLight,
      'failed' => Aether.danger,
      _ => Aether.successLight,
    };
    final bits = <String>[
      if (sub != null) formatCompactDuration(sub!.elapsed),
      '${session.messages.length} rows',
      if (sub != null && sub!.messages.isNotEmpty)
        '${sub!.messages.length} queued',
      session.agentContinuable ? 'continuable' : 'one-shot',
    ];
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.07),
        border: Border(bottom: BorderSide(color: Aether.hairline)),
      ),
      child: Wrap(
        spacing: 8,
        runSpacing: 4,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          AetherStatusDot(
            key: const ValueKey('subagent-status-dot'),
            color: color,
            pulsing: state == 'running',
            size: 8,
          ),
          AetherPill(label: state, color: color, filled: true),
          Text(
              bits.join(' · '),
              style: TextStyle(fontSize: 11, color: Aether.textMuted),
          ),
          if (session.agentAllowedTools.isNotEmpty)
            Tooltip(
              message: 'Tools: ${session.agentAllowedTools.join(', ')}',
              child: Icon(
                Icons.lock_outline,
                size: 13,
                color: Aether.textFaint,
              ),
            ),
        ],
      ),
    );
  }
}

class _Composer extends StatelessWidget {
  final int maxLines;
  final TextEditingController controller;
  final bool continuable;
  final bool running;
  final bool sending;
  final VoidCallback onSend;
  final VoidCallback onStop;
  const _Composer({
    required this.maxLines,
    required this.controller,
    required this.continuable,
    required this.running,
    required this.sending,
    required this.onSend,
    required this.onStop,
  });

  @override
  Widget build(BuildContext context) {
    // A finished one-shot child is a completed execution record: no composer,
    // just a note explaining why (matching the subagent viewer read-only
    // child composer).
    if (!continuable) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
        decoration: BoxDecoration(
          border: Border(top: BorderSide(color: Aether.hairline)),
        ),
        child: Row(
          children: [
            Icon(Icons.history_toggle_off, size: 15, color: Aether.textFaint),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                running
                    ? 'This agent runs to completion — it takes no follow-ups.'
                    : 'Completed execution record — read only.',
                style: TextStyle(fontSize: 11.5, color: Aether.textFaint),
              ),
            ),
            if (running)
              TextButton(
                style: TextButton.styleFrom(
                  foregroundColor: Aether.warnLight,
                  minimumSize: Size.zero,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 6,
                  ),
                ),
                onPressed: onStop,
                child: const Text('Stop', style: TextStyle(fontSize: 12)),
              ),
          ],
        ),
      );
    }
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 10),
        child: Container(
          padding: const EdgeInsets.fromLTRB(12, 4, 6, 4),
          decoration: BoxDecoration(
            color: Aether.surfaceAlt,
            borderRadius: BorderRadius.circular(22),
            border: Border.all(color: Aether.hairline),
          ),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: controller,
                  minLines: 1,
                  // Keep the composer usable above a phone keyboard at large
                  // text sizes; the field itself scrolls longer drafts.
                  maxLines: maxLines,
                  style: const TextStyle(fontSize: 15, height: 22 / 15),
                  decoration: InputDecoration(
                    border: InputBorder.none,
                    isDense: true,
                    hintText: running
                        ? 'Queue a follow-up for this agent…'
                        : 'Send this agent more work…',
                    hintStyle: TextStyle(fontSize: 14, color: Aether.textFaint),
                  ),
                  onSubmitted: (_) => onSend(),
                ),
              ),
              // Running children keep an independent Stop next to Send, so a
              // follow-up and a stop are both one tap away.
              if (running)
                IconButton(
                  tooltip: 'Stop',
                  visualDensity: VisualDensity.compact,
                  icon: Icon(
                    Icons.stop_circle_outlined,
                    size: 20,
                    color: Aether.warnLight,
                  ),
                  onPressed: onStop,
                ),
              IconButton(
                tooltip: running ? 'Queue' : 'Send',
                visualDensity: VisualDensity.compact,
                icon: sending
                    ? const SizedBox(
                        width: 15,
                        height: 15,
                        child: CircularProgressIndicator(
                          strokeWidth: 1.6,
                          color: Aether.accent,
                        ),
                      )
                    : Icon(
                        running ? Icons.playlist_add : Icons.arrow_upward,
                        size: 19,
                        color: Aether.accent,
                      ),
                onPressed: sending ? null : onSend,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Bottom sheet listing the subagents dispatched by [sessionId] — state,
/// elapsed time, transcript size, and a tap to open each child.
Future<void> showSubagentCatalog(BuildContext context, String sessionId) async {
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Aether.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
    ),
    builder: (sheetCtx) => SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(sheetCtx).height * .85,
        ),
        child: SubagentListView(
          sessionId: sessionId,
          shrinkWrap: true,
          onOpenChild: (_, child) {
            Navigator.pop(sheetCtx);
            SubagentScreen.open(context, child.id);
          },
        ),
      ),
    ),
  );
}

/// Live list of the subagents dispatched by [sessionId]: one premium card per
/// child (status dot + pill, runtime, one-line summary, ghost Stop for running
/// children) or a calm empty state. Shared by [showSubagentCatalog] and the
/// Activity hub's Agents tab. Tapping a card resolves through
/// [SubagentScreen.open] unless [onOpenChild] overrides it.
class SubagentListView extends StatelessWidget {
  final String sessionId;
  final bool shrinkWrap;
  final void Function(BuildContext context, ChatSession child)? onOpenChild;
  const SubagentListView({
    super.key,
    required this.sessionId,
    this.shrinkWrap = false,
    this.onOpenChild,
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([AppState.I, AgentService.I]),
      builder: (_, _) {
        final children = AppState.I.childrenOf(sessionId);
        if (children.isEmpty) {
          return const SingleChildScrollView(
            child: Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: AetherEmptyState(
                key: ValueKey('subagent-catalog-empty'),
                icon: Icons.account_tree_outlined,
                title: 'No subagents yet',
                message:
                    'Ask the agent to dispatch one for a focused subtask — '
                    'it gets its own transcript and workspace.',
              ),
            ),
          );
        }
        return ListView(
          shrinkWrap: shrinkWrap,
          padding: const EdgeInsets.symmetric(vertical: 14),
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 2, 20, 10),
              child: AetherSectionTitle(
                eyebrow: 'Subagents (${children.length})',
              ),
            ),
            for (final child in children)
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 0, 14, 10),
                child: _CatalogCard(
                  session: child,
                  onOpen: () {
                    final override = onOpenChild;
                    if (override != null) {
                      override(context, child);
                    } else {
                      SubagentScreen.open(context, child.id);
                    }
                  },
                ),
              ),
          ],
        );
      },
    );
  }
}

/// Premium catalog row: an [AetherCard] with the child's name, a status pill,
/// its elapsed runtime, and a ghost "stop" button for running children. Tapping
/// the card opens the child's transcript — the dispatch navigation contract is
/// preserved: open always resolves through [SubagentScreen.open].
class _CatalogCard extends StatelessWidget {
  final ChatSession session;
  final VoidCallback onOpen;
  const _CatalogCard({required this.session, required this.onOpen});

  @override
  Widget build(BuildContext context) {
    final agent = AgentService.I;
    final running = agent.busyFor(session.id);
    final sub = agent.subagentForSession(session.id);
    final state = running ? 'running' : (session.agentState ?? 'finished');
    final color = switch (state) {
      'running' => Aether.accent,
      'stopped' || 'stopping' => Aether.warnLight,
      'failed' => Aether.danger,
      _ => Aether.successLight,
    };
    final grandchildren = AppState.I.childrenOf(session.id).length;
    final runtime = sub != null
        ? formatCompactDuration(sub.elapsed)
        : '—';
    final subtitleBits = <String>[
      '${session.messages.length} rows',
      session.mode,
      if (grandchildren > 0) '$grandchildren sub',
    ];
    return InkWell(
      onTap: onOpen,
      borderRadius: BorderRadius.circular(AetherRadius.rLg),
      child: AetherCard(
        padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
        child: Row(
          children: [
            AetherStatusDot(
              color: color,
              pulsing: running,
              size: 9,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                          session.agentLabel ?? session.title,
                          style: AetherType.title.copyWith(fontSize: 13.5),
                        ),
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 8,
                    runSpacing: 6,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      AetherPill(
                        label: state,
                        color: color,
                        filled: true,
                      ),
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                      Icon(
                        Icons.schedule,
                        size: 11,
                        color: Aether.textFaint,
                      ),
                      const SizedBox(width: 3),
                      Text(
                        runtime,
                        style: AetherType.caption.copyWith(
                          fontFamily: 'JetBrainsMono',
                        ),
                      ),
                      ],
                      ),
                      if (running)
                        AetherGhostButton(
                          key: ValueKey('subagent-stop-${session.id}'),
                          label: 'Stop',
                          icon: Icons.stop_circle_outlined,
                          onPressed: () => agent.stopSubagentRun(session.id),
                        ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(subtitleBits.join(' · '), style: AetherType.caption),
                ],
              ),
            ),
            if (!running)
              Icon(
                Icons.chevron_right,
                size: 18,
                color: Aether.textFaint,
              ),
          ],
        ),
      ),
    );
  }
}
