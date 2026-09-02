import 'package:flutter/material.dart';

import '../core/agent_service.dart';
import '../core/state.dart';
import '../core/theme.dart';
import 'chat_screen.dart';

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

  @override
  void dispose() {
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _jumpToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      _scroll.jumpTo(_scroll.position.maxScrollExtent);
    });
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty || _sending) return;
    setState(() => _sending = true);
    final status = await AgentService.I.continueSubagent(
      widget.sessionId,
      text,
    );
    if (!mounted) return;
    _input.clear();
    setState(() => _sending = false);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(status), behavior: SnackBarBehavior.floating),
    );
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
            body: Center(
              child: Text(
                'This subagent session is gone.',
                style: TextStyle(fontSize: 13, color: Aether.textFaint),
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
            title: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  s.agentLabel ?? s.title,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 14),
                ),
                _Lineage(sessionId: s.id),
              ],
            ),
            actions: [
              if (children.isNotEmpty)
                _DescendantsButton(sessionId: s.id, count: children.length),
              if (running)
                IconButton(
                  tooltip: 'Stop this subagent',
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(
                    Icons.stop_circle_outlined,
                    size: 20,
                    color: Aether.warn,
                  ),
                  onPressed: () => agent.interruptSubagent(s.id),
                ),
              const SizedBox(width: 6),
            ],
          ),
          body: SafeArea(
            child: Column(
              children: [
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
                  controller: _input,
                  continuable: continuable,
                  running: running,
                  sending: _sending,
                  onSend: _send,
                  onStop: () => agent.interruptSubagent(s.id),
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
    return SizedBox(
      height: 16,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        itemCount: ancestors.length,
        itemBuilder: (_, i) {
          final a = ancestors[i];
          return Row(
            children: [
              InkWell(
                onTap: () {
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
          );
        },
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
      'stopped' || 'stopping' => Aether.warn,
      'failed' => Aether.danger,
      _ => Aether.success,
    };
    final bits = <String>[
      state,
      if (sub != null) '${sub!.elapsed.inSeconds}s',
      '${session.messages.length} rows',
      if (sub != null && sub!.messages.isNotEmpty)
        '${sub!.messages.length} queued',
      session.agentContinuable ? 'continuable' : 'one-shot',
    ];
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.07),
        border: Border(bottom: BorderSide(color: Aether.hairline)),
      ),
      child: Row(
        children: [
          Container(
            width: 7,
            height: 7,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              bits.join(' · '),
              style: TextStyle(fontSize: 11, color: Aether.textMuted),
            ),
          ),
          if (session.agentAllowedTools.isNotEmpty)
            Tooltip(
              message: 'Tools: ${session.agentAllowedTools.join(', ')}',
              child: Icon(Icons.lock_outline, size: 13, color: Aether.textFaint),
            ),
        ],
      ),
    );
  }
}

class _Composer extends StatelessWidget {
  final TextEditingController controller;
  final bool continuable;
  final bool running;
  final bool sending;
  final VoidCallback onSend;
  final VoidCallback onStop;
  const _Composer({
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
    // just a note explaining why (matching the reference product's read-only
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
                  foregroundColor: Aether.warn,
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
                  maxLines: 4,
                  style: const TextStyle(fontSize: 15, height: 22 / 15),
                  decoration: InputDecoration(
                    border: InputBorder.none,
                    isDense: true,
                    hintText: running
                        ? 'Queue a follow-up for this agent…'
                        : 'Send this agent more work…',
                    hintStyle: TextStyle(
                      fontSize: 14,
                      color: Aether.textFaint,
                    ),
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
                  icon: const Icon(
                    Icons.stop_circle_outlined,
                    size: 20,
                    color: Aether.warn,
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
Future<void> showSubagentCatalog(
  BuildContext context,
  String sessionId,
) async {
  await showModalBottomSheet<void>(
    context: context,
    backgroundColor: Aether.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
    ),
    builder: (sheetCtx) => AnimatedBuilder(
      animation: Listenable.merge([AppState.I, AgentService.I]),
      builder: (_, _) {
        final app = AppState.I;
        final children = app.childrenOf(sessionId);
        return SafeArea(
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.symmetric(vertical: 12),
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 2, 18, 8),
                child: Text(
                  children.isEmpty
                      ? 'No subagents yet'
                      : 'Subagents (${children.length})',
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              if (children.isEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(18, 0, 18, 10),
                  child: Text(
                    'Ask the agent to dispatch one for a focused subtask — '
                    'it gets its own transcript and workspace.',
                    style: TextStyle(fontSize: 12, color: Aether.textFaint),
                  ),
                ),
              for (final child in children)
                _CatalogRow(
                  session: child,
                  onOpen: () {
                    Navigator.pop(sheetCtx);
                    SubagentScreen.open(context, child.id);
                  },
                ),
            ],
          ),
        );
      },
    ),
  );
}

class _CatalogRow extends StatelessWidget {
  final ChatSession session;
  final VoidCallback onOpen;
  const _CatalogRow({required this.session, required this.onOpen});

  @override
  Widget build(BuildContext context) {
    final agent = AgentService.I;
    final running = agent.busyFor(session.id);
    final sub = agent.subagentForSession(session.id);
    final state = running ? 'running' : (session.agentState ?? 'finished');
    final color = switch (state) {
      'running' => Aether.accent,
      'stopped' || 'stopping' => Aether.warn,
      'failed' => Aether.danger,
      _ => Aether.success,
    };
    final grandchildren = AppState.I.childrenOf(session.id).length;
    return ListTile(
      dense: true,
      leading: Container(
        width: 9,
        height: 9,
        margin: const EdgeInsets.only(top: 6),
        decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      ),
      title: Text(
        session.agentLabel ?? session.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 13.5),
      ),
      subtitle: Text(
        [
          state,
          if (sub != null) '${sub.elapsed.inSeconds}s',
          '${session.messages.length} rows',
          session.mode,
          if (grandchildren > 0) '$grandchildren sub',
        ].join(' · '),
        style: TextStyle(fontSize: 11, color: Aether.textFaint),
      ),
      trailing: Icon(Icons.chevron_right, size: 17, color: Aether.textFaint),
      onTap: onOpen,
    );
  }
}
