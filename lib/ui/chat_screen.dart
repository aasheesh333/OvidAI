import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:markdown/markdown.dart' as md;
import '../core/theme.dart';
import '../core/state.dart';
import 'sandbox_setup.dart';
import 'browser_screen.dart';
import 'sidebar.dart';
import '../core/agent_service.dart';

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
  final out = <_ChatItem>[];
  var i = 0;
  while (i < messages.length) {
    final m = messages[i];
    final foldable = m.role == 'assistant' &&
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

Widget _buildItem(_ChatItem item, dynamic s,
    {required VoidCallback onAction, required TextEditingController input}) {
  if (item is _SingleItem) {
    return _MessageView(
      m: item.m,
      session: s,
      msgIndex: item.index,
      onAction: onAction,
      input: input,
    );
  }
  final g = item as _FoldedGroup;
  return _TurnProcessStrip(group: g.msgs);
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
      animation: AppState.I,
      builder: (_, _) {
        final usage = AppState.I.usageLog;
        if (usage.isEmpty) return const SizedBox.shrink();
        final today = usage.where((e) {
          final d = e.time;
          final now = DateTime.now();
          return d.year == now.year && d.month == now.month && d.day == now.day;
        }).toList();
        final input = usage.fold<int>(0, (a, e) => a + e.promptTokens);
        final output = usage.fold<int>(0, (a, e) => a + e.completionTokens);
        final parts = <String>[
          '${today.length} turn${today.length == 1 ? '' : 's'} today',
          if (AgentService.I.lastRunElapsedMs != null)
            'last ${(AgentService.I.lastRunElapsedMs! / 1000).toStringAsFixed(1)}s',
          'Input ${_fmtTok(input)} tok · Output ${_fmtTok(output)} tok',
        ];
        return Container(
          width: double.infinity,
          padding: const EdgeInsets.fromLTRB(16, 3, 16, 3),
          alignment: Alignment.center,
          child: Text(
            parts.join('  |  '),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 10.5, color: Aether.textFaint),
          ),
        );
      },
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
    final subagents =
        g.where((m) => m.toolName == 'dispatch_agent').length;
    final label = [
      if (toolCount > 0) '$toolCount tool call${toolCount == 1 ? '' : 's'}',
      if (hasReasoning) 'Thought for a while',
      if (subagents > 0) '$subagents subagent${subagents == 1 ? '' : 's'}',
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
            ...g.map((m) => Padding(
                  padding: const EdgeInsets.only(left: 8),
                  child: m.kind == MsgKind.reasoning
                      ? _ReasoningCard(m)
                      : _ToolCard(m),
                )),
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

  // ── Per-session composer drafts ─────────────────────────────────────
  // Bug fix: the old single controller leaked the draft across sessions —
  // typing in session A, switching to B, then creating a new session kept
  // showing A's text. We stash the current text on session switch and
  // restore the target session's draft (like DeepSeek web / ChatGPT web).
  final Map<String, String> _drafts = {};
  String? _boundSessionId;

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
          WidgetsBinding.instance
              .addPostFrameCallback((_) => _bindDraft(s.id));
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
                  Icon(
                    Icons.unfold_more,
                    size: 16,
                    color: Aether.textFaint,
                  ),
                ],
              ),
            ),
            actions: [
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
                            border: Border.all(
                              color: Aether.bg,
                              width: 1.5,
                            ),
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
                      ? _EmptyState(
                          onSuggest: (t) {
                            _input.text = t;
                          },
                        )
                      : Stack(
                          children: [
                            AnimatedBuilder(
                              animation: AgentService.I,
                              builder: (_, _) {
                                final typing = AgentService.I.busy;
                                _maybeJumpToBottom();
                                // DSH turn-process folding: consecutive
                                // tool/reasoning items collapse into a
                                // single strip before the final answer.
                                final items = _foldMessages(s.messages);
                                return ListView.builder(
                                  controller: _scroll,
                                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                                  itemCount: items.length + (typing ? 1 : 0),
                                  itemBuilder: (_, i) =>
                                      i == items.length
                                          ? const _TypingBubble()
                                          : _buildItem(
                                              items[i], s,
                                              onAction: () => setState(() {}),
                                              input: _input,
                                            ),
                                );
                              },
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
                const _TodoDock(),
                const _StatsLine(),
                _QueueDock(
                  onEdited: () => setState(() {}),
                ),
                const _ApprovalDock(),
                _InputBar(
                  controller: _input,
                  running: AgentService.I.busy,
                  onSend: () {
                    final t = _input.text.trim();
                    if (t.isEmpty) return;

                    // ── DSH-web busy behavior: typing while running queues
                    // the message to auto-run after the current turn. ──
                    if (AgentService.I.busy) {
                      AgentService.I.enqueueMessage(t);
                      _input.clear();
                      return;
                    }

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
                          content: Text(
                            'Add an API key for ${provider.name} first.',
                          ),
                        ),
                      );
                      return;
                    }
                    final selectedModel = session.model.split('·').first.trim();
                    if (!provider.models.contains(selectedModel)) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text(
                            'The selected model is no longer available.',
                          ),
                        ),
                      );
                      return;
                    }

                    app.sendMessage(t);
                    _input.clear();
                    _drafts.remove(session.id);
                    // New user message → snap to bottom so the user sees the
                    // answer start, regardless of where they were scrolled.
                    _atBottom = true;
                    Future.delayed(const Duration(milliseconds: 80), () {
                      if (_scroll.hasClients) {
                        _scroll.jumpTo(_scroll.position.maxScrollExtent);
                      }
                    });
                    // Launch the real agent (BYOK + tool-use, SSE streaming).
                    // AgentService.busy drives the send/stop button + typing
                    // bubble via the AnimatedBuilder below.
                    AgentService.I.runTask(t);
                  },
                ),
              ],
            ),
          ),
        );
      },
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
    final selected = session?.providerId == providerId &&
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
                  selected: current ==
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
                    color: current ==
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

/// 50+ prompt suggestions — 4 random ones show per empty-state render.
const _suggestionPool = [
  ('⚡', 'Build a Flutter login screen'),
  ('🧠', 'Explain transformers simply'),
  ('🖼', 'Generate a minimal wallpaper'),
  ('💻', 'Write a Python web scraper'),
  ('🔍', 'Search the web for today\'s AI news'),
  ('📄', 'Summarize this PDF for me'),
  ('🐛', 'Debug this crash log'),
  ('📊', 'Analyze this CSV and chart the trends'),
  ('🎨', 'Design a color palette for a fintech app'),
  ('🌐', 'Translate this text to French'),
  ('📝', 'Draft a professional email to my manager'),
  ('🧮', 'Solve this calculus problem step by step'),
  ('🚀', 'Explain how rockets work like I\'m 10'),
  ('🔧', 'Refactor this function for readability'),
  ('📱', 'Create an app idea for productivity'),
  ('🗂', 'Organize my project folder structure'),
  ('🔐', 'Explain OAuth 2.0 in simple terms'),
  ('🧪', 'Write unit tests for this class'),
  ('🎯', 'Help me set SMART goals for this month'),
  ('🤖', 'How do neural networks learn?'),
  ('📈', 'Explain the difference between stocks and bonds'),
  ('🎮', 'Design a simple 2D game concept'),
  ('🏠', 'Plan a smart home automation setup'),
  ('✈️', 'Create a 5-day itinerary for Tokyo'),
  ('🍳', 'Give me a recipe using only 5 ingredients'),
  ('📚', 'Recommend 5 books on machine learning'),
  ('🎵', 'Write a haiku about programming'),
  ('🗺', 'Compare Dijkstra vs A* pathfinding'),
  ('💼', 'Review my resume summary'),
  ('🧘', 'Create a 10-minute morning routine'),
  ('🔬', 'Explain CRISPR gene editing'),
  ('📦', 'Write a Dockerfile for a Node app'),
  ('🌊', 'Explain ocean tides simply'),
  ('⚙️', 'Optimize this SQL query'),
  ('🗣', 'Practice Spanish conversation with me'),
  ('🎭', 'Write a short dialogue between two friends'),
  ('📐', 'Calculate the area of this irregular shape'),
  ('🔮', 'Predict 3 AI trends for next year'),
  ('🏃', 'Design a beginner running plan'),
  ('💡', 'Brainstorm 10 startup ideas in health tech'),
  ('📷', 'Explain camera aperture like I\'m new to photography'),
  ('🌍', 'Compare renewable energy sources'),
  ('🛠', 'Fix this TypeScript error'),
  ('🧑‍🏫', 'Teach me binary search with an example'),
  ('📰', 'Summarize the key points of this article'),
  ('🎲', 'Explain probability with dice examples'),
  ('🏗', 'Design a database schema for a blog'),
  ('🌱', 'How do I start composting at home?'),
  ('📅', 'Plan my week around these 5 tasks'),
  ('🔑', 'Generate a secure password policy'),
  ('🧊', 'Explain the water cycle'),
];

class _EmptyState extends StatelessWidget {
  final void Function(String)? onSuggest;
  const _EmptyState({this.onSuggest});
  @override
  Widget build(BuildContext context) {
    final shuffled = [..._suggestionPool]..shuffle();
    final suggestions = shuffled.take(4).toList();
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(
                color: Aether.accent,
                borderRadius: BorderRadius.circular(16),
              ),
              child: const Center(
                child: Text(
                  'O',
                  style: TextStyle(
                    fontSize: 26,
                    fontWeight: FontWeight.w800,
                    color: Colors.white,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 16),
            const Text(
              'How can I help?',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 6),
            Text(
              'Add an API key in Settings → Providers to get started.',
              style: TextStyle(fontSize: 13, color: Aether.textMuted),
            ),
            const SizedBox(height: 28),
            for (final s in suggestions)
              GestureDetector(
                onTap: () => onSuggest?.call(s.$2),
                child: Container(
                  width: 320,
                  margin: const EdgeInsets.only(bottom: 8),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 11,
                  ),
                  decoration: BoxDecoration(
                    color: Aether.surface,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: Aether.hairline),
                  ),
                  child: Row(
                    children: [
                      Text(s.$1, style: const TextStyle(fontSize: 15)),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          s.$2,
                          style: TextStyle(
                            fontSize: 13,
                            color: Aether.textMuted,
                          ),
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
              padding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(
                children: [
                  if (isStreaming)
                    const SizedBox(
                      width: 12,
                      height: 12,
                      child: CircularProgressIndicator(
                        strokeWidth: 1.5,
                        color: Aether.accent,
                      ),
                    )
                  else
                    Icon(
                      expanded
                          ? Icons.keyboard_arrow_down
                          : Icons.keyboard_arrow_right,
                      size: 14,
                      color: Aether.textFaint,
                    ),
                  const SizedBox(width: 8),
                  Text(
                    isStreaming ? 'Thinking…' : 'Thoughts',
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
                      style: TextStyle(
                        fontSize: 10,
                        color: Aether.textFaint,
                      ),
                    ),
                ],
              ),
            ),
          ),
          // Body — only when expanded.
          if (expanded && widget.m.content.trim().isNotEmpty)
            Container(
              width: double.infinity,
              padding:
                  const EdgeInsets.fromLTRB(12, 0, 12, 10),
              child: _DshMarkdown(content: widget.m.content),
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

  @override
  Widget build(BuildContext context) {
    final m = widget.m;
    final running = m.toolState == 'running';
    if (!running && _sweep.isAnimating) _sweep.stop();
    final failed = m.toolState == 'error';
    final stopped = m.toolState == 'stopped';
    final iconKind = AgentService.toolIcon(m.toolName ?? '');
    final hasDetail = (m.toolDetail ?? '').trim().isNotEmpty;

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
                  else if (stopped)
                    _StateDot(Aether.warn)
                  else if (running)
                    SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(
                        strokeWidth: 1.5,
                        color: Aether.accent,
                      ),
                    )
                  else
                    Icon(_iconFor(iconKind),
                        size: 14, color: Aether.textMuted),
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
                  const SizedBox(width: 8),
                ],
              ),
            ),
          ),
          // Glare sweep while running (DSH 300px band).
          if (running)
            AnimatedBuilder(
              animation: _sweep,
              builder: (_, _) => Container(
                height: 1.5,
                margin: const EdgeInsets.symmetric(horizontal: 10),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment(-1 + 2 * _sweep.value, 0),
                    end: Alignment(-0.6 + 2 * _sweep.value, 0),
                    colors: [
                      Colors.transparent,
                      Aether.accent.withValues(alpha: 0.5),
                      Colors.transparent,
                    ],
                  ),
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
    final shown =
        capped ? lines.sublist(lines.length - _cap) : lines;

    final isDiff = kind == 'edit' ||
        m.toolName == 'commit' ||
        detail.split('\n').take(8).any((l) =>
            l.startsWith('+ ') || l.startsWith('- ') ||
            l.startsWith('+') && !l.startsWith('++') ||
            l.startsWith('-') && !l.startsWith('--'));
    final isTerminal =
        kind == 'terminal' || kind == 'code' || kind == 'agent';

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
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 340),
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(10, 4, 10, 8),
              child: isDiff
                  ? Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: shown
                          .map((l) => _DiffLine(l))
                          .toList(),
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
        crossAxisAlignment:
            isUser ? CrossAxisAlignment.end : CrossAxisAlignment.start,
        children: [
          Container(
            margin: const EdgeInsets.only(bottom: 2),
            constraints: BoxConstraints(
              maxWidth: MediaQuery.of(context).size.width * 0.82,
            ),
            child: switch (m.kind) {
              MsgKind.code => _code(),
              MsgKind.imageGen => _imageGen(),
              MsgKind.reasoning => _reasoning(),
              MsgKind.tool => _toolCard(),
              MsgKind.turnTail => _turnTail(),
              _ => _text(isUser),
            },
          ),
          // DSH-web message meta + action row: copy / edit / revert / time.
          if (!m.thinking) _actionRow(context, isUser, isLast),
        ],
      ),
    );
  }

  Widget _actionRow(BuildContext context, bool isUser, bool isLast) {
    final items = <Widget>[];
    void add(IconData icon, String tip, VoidCallback fn) {
      items.add(InkWell(
        borderRadius: BorderRadius.circular(4),
        onTap: fn,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 3),
          child: Icon(icon, size: 13, color: Aether.textFaint),
        ),
      ));
    }

    add(Icons.copy_outlined, 'Copy', () async {
      await Clipboard.setData(ClipboardData(text: m.content));
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Copied to clipboard'),
            duration: Duration(milliseconds: 800),
          ),
        );
      }
    });
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
                style: TextStyle(
                  fontSize: 10.5,
                  color: Aether.textFaint,
                ),
              ),
            ),
          if (isUser)
            Padding(
              padding: const EdgeInsets.only(left: 4),
              child: Text(
                _formatTime(m.time),
                style: TextStyle(
                  fontSize: 10.5,
                  color: Aether.textFaint,
                ),
              ),
            ),
        ],
      ),
    );
  }

  String _formatTime(DateTime t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  Widget _text(bool isUser) => Container(
        padding: EdgeInsets.symmetric(
          horizontal: isUser ? 14 : 4,
          vertical: isUser ? 11 : 4,
        ),
        decoration: BoxDecoration(
          color: isUser ? Aether.surfaceRaised : Colors.transparent,
          borderRadius: BorderRadius.circular(14),
          border: isUser ? Border.all(color: Aether.hairline) : null,
        ),
        child: isUser
            ? Text(
                m.content,
                style: TextStyle(
                  fontSize: 14,
                  height: 1.5,
                  color: Aether.text,
                ),
              )
            : _DshMarkdown(content: m.content),
      );

  Widget _reasoning() => _ReasoningCard(m);

  /// DSH ToolRow parity — collapsed 24px row (icon + title · summary)
  /// expanding to a Terminal/Diff/plain detail block.
  Widget _toolCard() => _ToolCard(m);

  /// DSH turn-tail parity — faint footer row (elapsed · stats).
  Widget _turnTail() => _TurnTailRow(m);

  Widget _code() => Container(
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: Aether.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Aether.hairline),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              color: Aether.surfaceAlt,
              child: Row(
                children: [
                  Text(
                    m.lang ?? 'code',
                    style:
                        TextStyle(fontSize: 11, color: Aether.textMuted),
                  ),
                  const Spacer(),
                  _CopyButton(code: m.content),
                ],
              ),
            ),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.all(12),
              child: Text(
                m.content,
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

  Widget _imageGen() => Container(
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: Aether.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Aether.hairline),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // dummy generated image
            AspectRatio(
              aspectRatio: 1,
              child: Container(
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      Color(0xFF1B1F3B),
                      Color(0xFF0E2A4A),
                      Color(0xFF111114),
                    ],
                  ),
                ),
                child: const Center(
                  child:
                      Icon(Icons.auto_awesome, color: Aether.accent, size: 40),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    m.content,
                    style: TextStyle(
                        fontSize: 12.5, color: Aether.textMuted),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Icon(
                        Icons.download_outlined,
                        size: 15,
                        color: Aether.textFaint,
                      ),
                      SizedBox(width: 14),
                      Icon(Icons.refresh, size: 15, color: Aether.textFaint),
                      SizedBox(width: 14),
                      Icon(Icons.open_in_full,
                          size: 14, color: Aether.textFaint),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      );
}

class _InputBar extends StatelessWidget {
  final TextEditingController controller;
  final bool running;
  final VoidCallback onSend;
  const _InputBar({
    required this.controller,
    required this.running,
    required this.onSend,
  });

  /// DSH-web rule: running + empty draft = Stop; running + draft = Send
  /// (queue). The queue color (teal) signals "this goes to the queue",
  /// distinct from the normal accent send.
  static const _queueColor = Color(0xFF0E9F9F);

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
              'Pick from gallery',
              () => _comingSoon(sheetCtx, 'Photo picking'),
            ),
            _attachOption(
              sheetCtx,
              Icons.camera_alt_outlined,
              'Camera',
              'Take a photo',
              () => _comingSoon(sheetCtx, 'Camera capture'),
            ),
            _attachOption(
              sheetCtx,
              Icons.insert_drive_file_outlined,
              'Document',
              'PDF, code, text files',
              () => _comingSoon(sheetCtx, 'Document attach'),
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

  void _comingSoon(BuildContext ctx, String feature) {
    Navigator.pop(ctx);
    ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(
      content: Text(
          '$feature is coming soon — ask the AI to fetch or create files for now.'),
      behavior: SnackBarBehavior.floating,
    ));
  }

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
              // ── Text area — full card width ──
              TextField(
                controller: controller,
                minLines: 1,
                maxLines: 5,
                style: const TextStyle(fontSize: 14),
                decoration: const InputDecoration(
                  hintText: 'Ask anything…',
                  filled: false,
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                  contentPadding: EdgeInsets.fromLTRB(10, 8, 10, 4),
                ),
                onSubmitted: (_) => onSend(),
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
                  // DSH-web mode selector — icon + text chip, opens the mode sheet.
                  const _ModeChip(),
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
                      final runningNow = AgentService.I.busy;
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

class _TypingBubble extends StatefulWidget {
  const _TypingBubble();
  @override
  State<_TypingBubble> createState() => _TypingBubbleState();
}

class _TypingBubbleState extends State<_TypingBubble>
    with SingleTickerProviderStateMixin {
  late final AnimationController c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  )..repeat();

  @override
  void dispose() {
    c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: Aether.surface,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: Aether.hairline),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var i = 0; i < 3; i++)
              AnimatedBuilder(
                animation: c,
                builder: (_, _) {
                  final t = (c.value * 3 - i).clamp(0.0, 1.0);
                  final op = 0.25 + 0.75 * (t < 0.5 ? t * 2 : (1 - t) * 2);
                  return Container(
                    margin: const EdgeInsets.symmetric(horizontal: 2),
                    width: 6,
                    height: 6,
                    decoration: BoxDecoration(
                      color: Aether.accent.withValues(alpha: op),
                      shape: BoxShape.circle,
                    ),
                  );
                },
              ),
          ],
        ),
      ),
    );
  }
}

/// DSH-web QueueDock — a strip above the input bar showing queued messages
/// with edit/remove actions. Shown only when [AgentService.queuedMessages]
/// is non-empty.
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
        final done =
            todos.where((t) => t['status'] == 'completed').length;
        final inProg =
            todos.where((t) => t['status'] == 'in_progress').length;
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
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
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
                            value: todos.isEmpty
                                ? 0
                                : done / todos.length,
                            backgroundColor: Aether.hairline,
                            valueColor: const AlwaysStoppedAnimation(
                                Aether.success),
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
                    Icon(
                      Icons.queue_music,
                      size: 13,
                      color: Aether.textMuted,
                    ),
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
                        style: TextStyle(
                          fontSize: 11,
                          color: Aether.textFaint,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                // Queued message rows
                for (var i = 0; i < queue.length; i++)
                  _QueueRow(
                    index: i,
                    text: queue[i],
                    onEdited: onEdited,
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

  @override
  Widget build(BuildContext context) {
    // Strip the framing lines _handleExitPlanMode wrapped the plan in.
    var plan = req.detail;
    const prefix = 'AI ka plan:\n\n';
    if (plan.startsWith(prefix)) plan = plan.substring(prefix.length);
    final cut = plan.indexOf('\n\nApprove karne par');
    if (cut > 0) plan = plan.substring(0, cut);

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
          // Buttons.
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                OutlinedButton(
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Aether.dangerC,
                    side: BorderSide(color: Aether.dangerC.withValues(alpha: 0.5)),
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
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
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
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

  bool get _allAnswered {
    for (final q in widget.req.questions!) {
      if (!(_selected[q.id]?.isNotEmpty ?? false)) return false;
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
                children: [
                  for (final opt in q.options)
                    _optionChip(q, opt),
                ],
              ),
            ],
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
                        for (final e in _selected.entries) {
                          widget.req.answers[e.key] = e.value.join(', ');
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
          border: Border.all(
            color: isSel ? Aether.accent : Aether.hairline,
          ),
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
                style: TextStyle(
                  fontSize: 9,
                  color: Aether.textFaint,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Permission mode chip (Read-Only / General / Full Access / Studio) —
/// DSH-web dropdown under the input. Tapping cycles; long-press opens sheet.
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
                Icon(m.icon, size: 12, color: m.color),
                const SizedBox(width: 5),
                Text(
                  m.label,
                  style: TextStyle(
                    fontSize: 10.5,
                    fontWeight: FontWeight.w700,
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
  const _DshMarkdown({required this.content});

  static final _fenceRe = RegExp(r'```(\w*)\n([\s\S]*?)```', multiLine: true);

  @override
  Widget build(BuildContext context) {
    final parts = <Widget>[];
    var last = 0;
    for (final match in _fenceRe.allMatches(content)) {
      if (match.start > last) {
        parts.add(_prose(content.substring(last, match.start)));
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
      parts.add(_prose(content.substring(last)));
    }
    if (parts.isEmpty) parts.add(_prose(content));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final w in parts)
          Padding(padding: const EdgeInsets.only(bottom: 6), child: w),
      ],
    );
  }

  Widget _prose(String text) {
    if (text.trim().isEmpty) return const SizedBox.shrink();
    return MarkdownBody(
      data: text,
      builders: {'code': _DshInlineCodeBuilder()},
      styleSheet: MarkdownStyleSheet(
        p: TextStyle(fontSize: 14, height: 1.55, color: Aether.text),
        h1: TextStyle(
          fontSize: 19,
          fontWeight: FontWeight.w700,
          color: Aether.text,
        ),
        h2: TextStyle(
          fontSize: 17,
          fontWeight: FontWeight.w700,
          color: Aether.text,
        ),
        h3: TextStyle(
          fontSize: 15.5,
          fontWeight: FontWeight.w600,
          color: Aether.text,
        ),
        strong: TextStyle(
          fontWeight: FontWeight.w700,
          color: Aether.text,
        ),
        em: TextStyle(fontStyle: FontStyle.italic, color: Aether.text),
        code: const TextStyle(
          fontFamily: Aether.mono,
          fontSize: 12.5,
          backgroundColor: Colors.transparent,
          color: Aether.accent,
        ),
        listBullet: TextStyle(
          fontSize: 14,
          height: 1.5,
          color: Aether.text,
        ),
        listIndent: 18,
        blockquoteDecoration: BoxDecoration(
          border: Border(
            left: BorderSide(color: Aether.hairlineStrong, width: 3),
          ),
        ),
        blockquotePadding: const EdgeInsets.only(left: 10),
        a: const TextStyle(
          color: Aether.accent,
          decoration: TextDecoration.underline,
        ),
      ),
    );
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
    final text = element.children?.map((c) => c.textContent).join() ??
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
