import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:markdown/markdown.dart' as md;
import '../core/theme.dart';
import '../core/state.dart';
import 'studio_screen.dart';
import 'sandbox_setup.dart';
import 'browser_screen.dart';
import 'sidebar.dart';
import '../core/agent_service.dart';

/// Chat screen — Gemini/DeepSeek grade: reasoning chips, code blocks,
/// in-chat image generation card, model picker, utility input bar.
class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key});
  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen>
    with SingleTickerProviderStateMixin {
  final _input = TextEditingController();
  final _scroll = ScrollController();
  bool _typing = false;

  @override
  Widget build(BuildContext context) {
    final app = AppState.I;
    return AnimatedBuilder(
      animation: app,
      builder: (_, __) {
        final s = app.activeSession;
        final wide = MediaQuery.of(context).size.width >= 840;
        return Scaffold(
          backgroundColor: Aether.bg,
          drawer: wide
              ? null
              : const Drawer(
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
                    child: Text(s?.model ?? 'Select model',
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 14)),
                  ),
                  const SizedBox(width: 4),
                  const Icon(Icons.unfold_more,
                      size: 16, color: Aether.textFaint),
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
              IconButton(
                tooltip: 'Browser — agent & login',
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.public, size: 19),
                onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute(
                        builder: (_) => const BrowserScreen())),
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
                const _AgentActivityBar(),
                Expanded(
                  child: s == null || s.messages.isEmpty
                      ? _EmptyState(onSuggest: (t) {
                        _input.text = t;
                      })
                      : ListView.builder(
                          controller: _scroll,
                          padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                          itemCount:
                              s.messages.length + (_typing ? 1 : 0),
                          itemBuilder: (_, i) => i == s.messages.length
                              ? const _TypingBubble()
                              : _MessageView(m: s.messages[i]),
                        ),
                ),
                _InputBar(
                  controller: _input,
                  onSend: () {
                    final t = _input.text.trim();
                    if (t.isEmpty || _typing) return;

                    // No key anywhere → guide user to Providers instead of failing.
                    final hasAnyKey =
                        AppState.I.providers.any((p) => p.hasKey);
                    if (!hasAnyKey) {
                      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                        content: const Text(
                            'Add an API key first — Settings → Providers → tap a provider'),
                        action: SnackBarAction(
                            label: 'Open',
                            onPressed: () => app.setNav(4)),
                      ));
                      return;
                    }

                    app.sendMessage(t);
                    _input.clear();
                    setState(() => _typing = true);
                    Future.delayed(const Duration(milliseconds: 60), () {
                      if (_scroll.hasClients) {
                        _scroll.jumpTo(_scroll.position.maxScrollExtent);
                      }
                    });
                    // Launch the real agent (BYOK + tool-use, SSE streaming).
                    AgentService.I.runTask(t).whenComplete(() {
                      if (mounted) setState(() => _typing = false);
                    });
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
    showDraggableScrollableSheet(
      context: context,
      isScrollControlled: true,
      initialChildSize: 0.5,
      minChildSize: 0.32,
      maxChildSize: 0.92,
      snap: true,
      snapSizes: const [0.5, 0.92],
      backgroundColor: Colors.transparent,
      builder: (ctx, scrollController) => _ModelPickerSheet(
          scrollController: scrollController),
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
      decoration: const BoxDecoration(
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
            child: Row(children: [
              const Text('Select model',
                  style: TextStyle(
                      fontSize: 16, fontWeight: FontWeight.w700)),
              const Spacer(),
              IconButton(
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.close, size: 18),
                  onPressed: () => Navigator.pop(context)),
            ]),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 4, 18, 8),
            child: TextField(
              onChanged: (v) => setState(() => _query = v),
              style: const TextStyle(fontSize: 13.5),
              decoration: InputDecoration(
                hintText: 'Search models or providers…',
                prefixIcon: const Icon(Icons.search,
                    size: 17, color: Aether.textFaint),
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
              builder: (_, __) {
                final providers = app.providers
                    .where((p) => p.models.isNotEmpty)
                    .where((p) => q.isEmpty ||
                        p.name.toLowerCase().contains(q) ||
                        p.models.any((m) => m.toLowerCase().contains(q)))
                    .toList();
                if (providers.isEmpty) {
                  return Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(
                          'No models yet.\nAdd a key in Settings → Providers and tap Fetch models.',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                              fontSize: 12.5,
                              height: 1.6,
                              color: Aether.textMuted)),
                    ),
                  );
                }
                return ListView.builder(
                  controller: widget.scrollController,
                  padding: const EdgeInsets.only(bottom: 20),
                  itemCount: providers.length,
                  itemBuilder: (_, i) {
                    final p = providers[i];
                    final models = p.models
                        .where((m) => q.isEmpty ||
                            p.name.toLowerCase().contains(q) ||
                            m.toLowerCase().contains(q))
                        .toList();
                    if (models.isEmpty) return const SizedBox.shrink();
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Padding(
                          padding: const EdgeInsets.fromLTRB(18, 14, 18, 4),
                          child: Row(children: [
                            Text(p.name,
                                style: const TextStyle(
                                    fontSize: 12.5,
                                    fontWeight: FontWeight.w700,
                                    color: Aether.textMuted)),
                            const SizedBox(width: 8),
                            if (p.isFree)
                              const Tag('FREE',
                                  color: Aether.success, filled: true),
                            if (p.hasKey) ...[
                              const SizedBox(width: 6),
                              const Tag('KEY',
                                  color: Aether.accent, filled: true),
                            ],
                          ]),
                        ),
                        for (final m in models)
                          _ModelTile(provider: p.name, model: m),
                      ],
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
  final String provider;
  final String model;
  const _ModelTile({required this.provider, required this.model});

  static const _effortModels = [
    'deepseek', 'gpt', 'kimi', 'glm', 'opus', 'sonnet',
    'gemini-2.5', 'qwen3', 'o4', 'grok', 'r1',
  ];
  static const variants = ['Low', 'Medium', 'High'];

  bool get supportsEffort =>
      _effortModels.any((e) => model.toLowerCase().contains(e));

  @override
  Widget build(BuildContext context) {
    final app = AppState.I;
    final current = app.activeSession?.model ?? '';
    final selected = current == model || current.startsWith('$model ·');

    if (!supportsEffort) {
      return ListTile(
        dense: true,
        leading: const Icon(Icons.smart_toy_outlined,
            size: 18, color: Aether.textMuted),
        title: Text(model, style: const TextStyle(fontSize: 13.5)),
        trailing: selected
            ? const Icon(Icons.check, size: 18, color: Aether.accent)
            : null,
        onTap: () {
          app.setModel(provider, model);
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
        leading: const Icon(Icons.psychology_outlined,
            size: 18, color: Aether.textMuted),
        title: Text(model, style: const TextStyle(fontSize: 13.5)),
        subtitle: selected && current.contains('·')
            ? Text(current.split('·').last.trim(),
                style: const TextStyle(
                    fontSize: 11, color: Aether.accent))
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
                  label:
                      Text(v, style: const TextStyle(fontSize: 12)),
                  selected: current == (v == 'Medium' ? '$model · Medium' : '$model · $v'),
                  onSelected: (_) {
                    app.setModel(
                        provider, v == 'Medium' ? '$model · Medium' : '$model · $v');
                    Navigator.pop(context);
                  },
                  showCheckmark: false,
                  selectedColor: Aether.accentSoft,
                  backgroundColor: Aether.surfaceAlt,
                  side: BorderSide(
                      color: current ==
                              (v == 'Medium' ? '$model · Medium' : '$model · $v')
                          ? Aether.accent
                          : Aether.hairline),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(9)),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  final void Function(String)? onSuggest;
  const _EmptyState({this.onSuggest});
  @override
  Widget build(BuildContext context) {
    const suggestions = [
      ('⚡', 'Build a Flutter login screen'),
      ('🧠', 'Explain transformers simply'),
      ('🖼', 'Generate a minimal wallpaper'),
      ('💻', 'Write a Python web scraper'),
    ];
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
                  borderRadius: BorderRadius.circular(16)),
              child: const Center(
                  child: Text('O',
                      style: TextStyle(
                          fontSize: 26,
                          fontWeight: FontWeight.w800,
                          color: Colors.white))),
            ),
            const SizedBox(height: 16),
            const Text('How can I help?',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
            const SizedBox(height: 6),
            const Text('Add an API key in Settings → Providers to get started.',
                style:
                    TextStyle(fontSize: 13, color: Aether.textMuted)),
            const SizedBox(height: 28),
            for (final s in suggestions)
              GestureDetector(
                onTap: () => onSuggest?.call(s.$2),
                child: Container(
                width: 320,
                margin: const EdgeInsets.only(bottom: 8),
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
                decoration: BoxDecoration(
                  color: Aether.surface,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Aether.hairline),
                ),
                child: Row(children: [
                  Text(s.$1, style: const TextStyle(fontSize: 15)),
                  const SizedBox(width: 10),
                  Expanded(
                      child: Text(s.$2,
                          style: const TextStyle(
                              fontSize: 13,
                              color: Aether.textMuted))),
                ]),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _MessageView extends StatelessWidget {
  final Message m;
  const _MessageView({required this.m});

  @override
  Widget build(BuildContext context) {
    final isUser = m.role == 'user';
    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.only(bottom: 12),
        constraints: BoxConstraints(
            maxWidth: MediaQuery.of(context).size.width * 0.82),
        child: switch (m.kind) {
          MsgKind.code => _code(),
          MsgKind.imageGen => _imageGen(),
          MsgKind.reasoning => _reasoning(),
          _ => _text(isUser),
        },
      ),
    );
  }

  Widget _text(bool isUser) => Container(
        padding: EdgeInsets.symmetric(
            horizontal: isUser ? 14 : 4, vertical: isUser ? 11 : 4),
        decoration: BoxDecoration(
          color: isUser ? Aether.surfaceRaised : Colors.transparent,
          borderRadius: BorderRadius.circular(14),
          border: isUser ? Border.all(color: Aether.hairline) : null,
        ),
        child: isUser
            ? Text(m.content,
                style: const TextStyle(
                    fontSize: 14, height: 1.5, color: Aether.text))
            : _DshMarkdown(content: m.content),
      );

  Widget _reasoning() => Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
        decoration: BoxDecoration(
          color: Aether.surface,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: Aether.hairline),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          const SizedBox(
              width: 12,
              height: 12,
              child: CircularProgressIndicator(
                  strokeWidth: 1.5, color: Aether.accent)),
          const SizedBox(width: 9),
          Flexible(
            child: Text(m.content,
                style: const TextStyle(
                    fontSize: 12,
                    fontStyle: FontStyle.italic,
                    color: Aether.textMuted)),
          ),
        ]),
      );

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
              padding: const EdgeInsets.symmetric(
                  horizontal: 12, vertical: 8),
              color: Aether.surfaceAlt,
              child: Row(children: [
                Text(m.lang ?? 'code',
                    style: const TextStyle(
                        fontSize: 11, color: Aether.textMuted)),
                const Spacer(),
                _CopyButton(code: m.content),
              ]),
            ),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.all(12),
              child: Text(m.content,
                  style: const TextStyle(
                      fontFamily: Aether.mono,
                      fontSize: 12,
                      height: 1.55,
                      color: Aether.text)),
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
                    colors: [Color(0xFF1B1F3B), Color(0xFF0E2A4A), Color(0xFF111114)],
                  ),
                ),
                child: const Center(
                    child: Icon(Icons.auto_awesome,
                        color: Aether.accent, size: 40)),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(m.content,
                        style: const TextStyle(
                            fontSize: 12.5,
                            color: Aether.textMuted)),
                    const SizedBox(height: 8),
                    const Row(children: [
                      Icon(Icons.download_outlined,
                          size: 15, color: Aether.textFaint),
                      SizedBox(width: 14),
                      Icon(Icons.refresh,
                          size: 15, color: Aether.textFaint),
                      SizedBox(width: 14),
                      Icon(Icons.open_in_full,
                          size: 14, color: Aether.textFaint),
                    ]),
                  ]),
            ),
          ],
        ),
      );
}

class _InputBar extends StatelessWidget {
  final TextEditingController controller;
  final VoidCallback onSend;
  const _InputBar({required this.controller, required this.onSend});

  void _attachSheet(BuildContext context) {
    showModalBottomSheet(
      context: context,
      builder: (_) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const SizedBox(height: 8),
          _attachOption(context, Icons.photo_library_outlined,
              'Photos & videos', 'Pick from gallery'),
          _attachOption(context, Icons.camera_alt_outlined,
              'Camera', 'Take a photo'),
          _attachOption(context, Icons.insert_drive_file_outlined,
              'Document', 'PDF, code, text files'),
          _attachOption(context, Icons.auto_awesome,
              'Generate image', 'Create with AI in this chat'),
          const SizedBox(height: 8),
        ]),
      ),
    );
  }

  Widget _attachOption(
      BuildContext context, IconData icon, String title, String sub) {
    return ListTile(
      leading: Container(
        width: 38,
        height: 38,
        decoration: BoxDecoration(
            color: Aether.surfaceRaised,
            borderRadius: BorderRadius.circular(10)),
        child: Icon(icon, size: 18, color: Aether.textMuted),
      ),
      title: Text(title, style: const TextStyle(fontSize: 14)),
      subtitle: Text(sub,
          style:
              const TextStyle(fontSize: 11.5, color: Aether.textFaint)),
      onTap: () => Navigator.pop(context),
    );
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 10),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
          decoration: BoxDecoration(
            color: Aether.surfaceAlt,
            borderRadius: BorderRadius.circular(26),
            border: Border.all(color: Aether.hairline),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              IconButton(
                  tooltip: 'Attach',
                  icon: const Icon(Icons.add_circle_outline,
                      size: 22, color: Aether.textMuted),
                  onPressed: () => _attachSheet(context)),
              Expanded(
                child: TextField(
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
                    contentPadding:
                        EdgeInsets.symmetric(horizontal: 4, vertical: 10),
                  ),
                  onSubmitted: (_) => onSend(),
                ),
              ),
              IconButton(
                  tooltip: 'Voice',
                  icon: const Icon(Icons.mic_none,
                      size: 20, color: Aether.textMuted),
                  onPressed: () {}),
              Container(
                decoration: const BoxDecoration(
                    color: Aether.accent, shape: BoxShape.circle),
                child: IconButton(
                  tooltip: 'Send',
                  icon: const Icon(Icons.arrow_upward,
                      size: 18, color: Colors.white),
                  onPressed: onSend,
                ),
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
      vsync: this, duration: const Duration(milliseconds: 1100))
    ..repeat();

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
        padding:
            const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: Aether.surface,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: Aether.hairline),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          for (var i = 0; i < 3; i++)
            AnimatedBuilder(
              animation: c,
              builder: (_, __) {
                final t = (c.value * 3 - i).clamp(0.0, 1.0);
                final op = 0.25 + 0.75 * (t < 0.5 ? t * 2 : (1 - t) * 2);
                return Container(
                  margin: const EdgeInsets.symmetric(horizontal: 2),
                  width: 6,
                  height: 6,
                  decoration: BoxDecoration(
                      color: Aether.accent.withValues(alpha: op),
                      shape: BoxShape.circle),
                );
              },
            ),
        ]),
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

/// Live activity bar — shows the agent's ongoing tool calls
/// (shell / browser / repo / think). Jumps to Studio or Browser on tap.
class _AgentActivityBar extends StatelessWidget {
  const _AgentActivityBar();

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: AgentService.I,
      builder: (_, __) {
        final a = AgentService.I;
        if (!a.busy && a.pendingApproval == null) return const SizedBox.shrink();
        final last =
            a.events.isEmpty ? null : a.events.last;
        final msg = a.pendingApproval?.summary ?? last?.text ?? 'working…';
        final icon = switch (last?.kind) {
          'shell' || 'shellOut' => Icons.terminal,
          'nav' || 'page' => Icons.public,
          'file' => Icons.edit_note,
          'err' => Icons.error_outline,
          _ => Icons.psychology_outlined,
        };
        final approved = a.pendingApproval != null;
        return Material(
          color: approved
              ? Aether.warn.withValues(alpha: 0.10)
              : Aether.accentSoft,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            decoration: BoxDecoration(
              border:
                  Border(bottom: BorderSide(color: Aether.hairline)),
            ),
            child: Row(children: [
              SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(
                    strokeWidth: 1.5, color: approved ? Aether.warn : Aether.accent),
              ),
              const SizedBox(width: 10),
              Icon(icon, size: 14, color: Aether.textMuted),
              const SizedBox(width: 8),
              Expanded(
                child: Text(msg,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 11.5, color: Aether.textMuted,
                        fontFamily: Aether.mono)),
              ),
              if (approved) ...[
                TextButton(
                  style: TextButton.styleFrom(
                      foregroundColor: Aether.danger,
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      minimumSize: Size.zero),
                  child: const Text('Deny', style: TextStyle(fontSize: 11)),
                  onPressed: () => AgentService.I.approve(false),
                ),
                TextButton(
                  style: TextButton.styleFrom(
                      foregroundColor: Aether.success,
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      minimumSize: Size.zero),
                  child: const Text('Allow', style: TextStyle(fontSize: 11)),
                  onPressed: () => AgentService.I.approve(true),
                ),
              ] else if (last?.kind == 'shell' || last?.kind == 'shellOut')
                TextButton(
                  style: TextButton.styleFrom(
                      foregroundColor: Aether.accent,
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      minimumSize: Size.zero),
                  child: const Text('Studio', style: TextStyle(fontSize: 11)),
                  onPressed: () => openStudio(context),
                )
              else if (last?.kind == 'nav' || last?.kind == 'page')
                TextButton(
                  style: TextButton.styleFrom(
                      foregroundColor: Aether.accent,
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      minimumSize: Size.zero),
                  child: const Text('Browser', style: TextStyle(fontSize: 11)),
                  onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => const BrowserScreen())),
                ),
            ]),
          ),
        );
      },
    );
  }
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
        child: Row(children: [
          Icon(copied ? Icons.check : Icons.copy_outlined,
              size: 14,
              color: copied ? Aether.success : Aether.textFaint),
          const SizedBox(width: 6),
          Text(copied ? 'Copied' : 'Copy',
              style: TextStyle(
                  fontSize: 11,
                  color: copied ? Aether.success : Aether.textFaint)),
        ]),
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

  static final _fenceRe =
      RegExp(r'```(\w*)\n([\s\S]*?)```', multiLine: true);

  @override
  Widget build(BuildContext context) {
    final parts = <Widget>[];
    var last = 0;
    for (final match in _fenceRe.allMatches(content)) {
      if (match.start > last) {
        parts.add(_prose(content.substring(last, match.start)));
      }
      parts.add(_DshCodeBox(
          lang: match.group(1)?.isEmpty ?? true ? 'code' : match.group(1)!,
          code: match.group(2) ?? ''));
      last = match.end;
    }
    if (last < content.length) {
      parts.add(_prose(content.substring(last)));
    }
    if (parts.isEmpty) parts.add(_prose(content));
    return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [for (final w in parts) Padding(
            padding: const EdgeInsets.only(bottom: 6), child: w)]);
  }

  Widget _prose(String text) {
    if (text.trim().isEmpty) return const SizedBox.shrink();
    return MarkdownBody(
      data: text,
      builders: {
        'code': _DshInlineCodeBuilder(),
      },
      styleSheet: MarkdownStyleSheet(
        p: const TextStyle(
            fontSize: 14, height: 1.55, color: Aether.text),
        h1: const TextStyle(
            fontSize: 19, fontWeight: FontWeight.w700, color: Aether.text),
        h2: const TextStyle(
            fontSize: 17, fontWeight: FontWeight.w700, color: Aether.text),
        h3: const TextStyle(
            fontSize: 15.5, fontWeight: FontWeight.w600, color: Aether.text),
        strong: const TextStyle(
            fontWeight: FontWeight.w700, color: Aether.text),
        em: const TextStyle(fontStyle: FontStyle.italic, color: Aether.text),
        code: const TextStyle(
            fontFamily: Aether.mono,
            fontSize: 12.5,
            backgroundColor: Colors.transparent,
            color: Aether.accent),
        listBullet: const TextStyle(
            fontSize: 14, height: 1.5, color: Aether.text),
        listIndent: 18,
        blockquoteDecoration: BoxDecoration(
            border: Border(left: BorderSide(
                color: Aether.hairlineStrong, width: 3))),
        blockquotePadding: const EdgeInsets.only(left: 10),
        a: const TextStyle(color: Aether.accent, decoration: TextDecoration.underline),
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
      code.split('\n').take(8).any((l) =>
          l.startsWith('+') || l.startsWith('-'));

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
            child: Row(children: [
              Icon(
                  _isDiff ? Icons.difference : Icons.code,
                  size: 13,
                  color: Aether.textFaint),
              const SizedBox(width: 7),
              Text(lang,
                  style: const TextStyle(
                      fontSize: 11,
                      fontFamily: Aether.mono,
                      color: Aether.textMuted)),
              const Spacer(),
              _CopyButton(code: code),
            ]),
          ),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: _isDiff
                ? _DiffLines(code: code)
                : Text(code,
                    style: const TextStyle(
                        fontFamily: Aether.mono,
                        fontSize: 12,
                        height: 1.55,
                        color: Aether.text)),
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
  Widget visitElementAfterWithContext(BuildContext context, Element element,
      TextStyle? preferredStyle, TextStyle? parentStyle) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
      decoration: BoxDecoration(
        color: Aether.surfaceAlt,
        borderRadius: BorderRadius.circular(5),
        border: Border.all(color: Aether.hairline),
      ),
      child: Text(element.textContent,
          style: TextStyle(
              fontFamily: Aether.mono,
              fontSize: 12,
              color: Aether.text)),
    );
  }
}
