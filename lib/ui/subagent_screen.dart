import 'package:flutter/material.dart';

import '../core/cloud/cloud_agent_facade.dart';
import '../core/state.dart';
import '../core/theme.dart';
import 'widgets/aether_primitives.dart';
import 'widgets/chat_tool_visuals.dart';
import 'widgets/read_only_markdown.dart';

/// A subagent's own transcript (Wave 1b): the child cloud session the
/// orchestrator delegated to — its brief, every tool it ran and its report —
/// read live from the facade while it works and paged from the server once
/// it finished.
class SubagentScreen extends StatefulWidget {
  final String sessionId;
  const SubagentScreen({super.key, required this.sessionId});

  /// Open [sessionId]'s transcript. Safe to call with a stale id — it shows
  /// an honest empty state instead of crashing.
  static Future<void> open(BuildContext context, String sessionId) =>
      Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => SubagentScreen(sessionId: sessionId)),
      );

  @override
  State<SubagentScreen> createState() => _SubagentScreenState();
}

class _SubagentScreenState extends State<SubagentScreen> {
  late final Future<void> _loading;

  @override
  void initState() {
    super.initState();
    _loading = CloudAgentFacade.I.openSubagentTranscript(widget.sessionId);
  }

  @override
  Widget build(BuildContext context) {
    final facade = CloudAgentFacade.I;
    return Scaffold(
      backgroundColor: Aether.bg,
      appBar: AppBar(
        leading: const BackButton(),
        title: Text(
          AppState.I.sessionById(widget.sessionId)?.agentLabel ?? 'Subagent',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        backgroundColor: Aether.bg,
        elevation: 0,
        scrolledUnderElevation: 0,
      ),
      body: FutureBuilder<void>(
        future: _loading,
        builder: (context, snap) => AnimatedBuilder(
          animation: facade,
          builder: (context, _) {
            final rows = facade.transcriptFor(widget.sessionId) ??
                const <Message>[];
            if (rows.isEmpty) {
              if (snap.connectionState != ConnectionState.done) {
                return const Center(child: CircularProgressIndicator());
              }
              return const AetherEmptyState(
                key: ValueKey('subagent-empty'),
                icon: Icons.account_tree_outlined,
                title: 'Nothing to show yet',
                message: 'This subagent has not recorded any work, or its '
                    'transcript could not be loaded. Check your connection '
                    'and open it again.',
              );
            }
            return ListView(
              key: const ValueKey('subagent-transcript'),
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
              children: [
                for (final m in rows)
                  if (m.kind != MsgKind.streaming || m.content.isNotEmpty)
                    _SubagentRow(m),
                if (facade.busyFor(widget.sessionId))
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      'Working…',
                      style: TextStyle(color: Aether.textMuted, fontSize: 13),
                    ),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _SubagentRow extends StatelessWidget {
  const _SubagentRow(this.m);

  final Message m;

  @override
  Widget build(BuildContext context) {
    if (m.kind == MsgKind.tool) {
      final failed = m.toolState == 'error';
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          children: [
            Icon(
              chatToolIcon(m.toolName ?? ''),
              size: 15,
              color: failed ? Aether.dangerC : Aether.textMuted,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                [
                  m.toolTitle ?? m.toolName ?? 'Tool',
                  if ((m.toolSummary ?? '').isNotEmpty) m.toolSummary!,
                ].join(' · '),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 13,
                  color: failed ? Aether.dangerC : Aether.text,
                ),
              ),
            ),
            const SizedBox(width: 6),
            ToolStatusBadge(state: m.toolState, size: 13),
          ],
        ),
      );
    }
    if (m.role == 'user') {
      return Container(
        margin: const EdgeInsets.symmetric(vertical: 6),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Aether.surfaceAlt,
          borderRadius: BorderRadius.circular(12),
        ),
        child: SelectableText(
          m.content,
          style: TextStyle(fontSize: 13.5, color: Aether.text),
        ),
      );
    }
    if (m.content.trim().isEmpty) return const SizedBox.shrink();
    final faint = m.kind == MsgKind.turnTail;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: faint
          ? Text(
              m.content,
              style: TextStyle(fontSize: 12.5, color: Aether.textMuted),
            )
          : ReadOnlyMarkdown(m.content, fontSize: 14),
    );
  }
}

