import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../core/agent_service.dart';
import '../../core/commands.dart';
import '../../core/diag.dart';
import '../../core/mcp_service.dart';
import '../../core/plugin_registry.dart';
import '../../core/skills.dart';
import '../../core/startup_coordinator.dart';
import '../../core/state.dart';
import '../../core/theme.dart';
import '../../core/voice_input_service.dart';
import '../chat_layout.dart';
import '../sandbox_setup.dart';
import '../widgets/aether_primitives.dart';
import 'sheets.dart';

/// Chat composer — the input bar below the docks: staged-attachment chips,
/// the slash-`/` and `@` suggestion menus, the message field, workspace /
/// plan / mode chips, mic, and the stateful Send / Queue / Stop primary
/// button. Relocated from `chat_screen.dart` unchanged, with two seams the
/// screen still owns passed in: the Control-mode service notice
/// ([ChatComposer.serviceNotice]) and the Control-mode enable flow
/// ([ChatComposer.onEnableControlMode]).

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

class ChatComposer extends StatefulWidget {
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

  /// Optional service notice rendered between the field and the queue-edit
  /// indicator (the chat screen passes its Control-mode notice).
  final Widget? serviceNotice;

  /// Control-mode enable flow (disclosure, battery exemption, accessibility
  /// deep-link), owned by the chat screen and forwarded by the mode sheet.
  final Future<void> Function(BuildContext) onEnableControlMode;
  const ChatComposer({
    super.key,
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
    this.serviceNotice,
    required this.onEnableControlMode,
  });

  @override
  State<ChatComposer> createState() => _ChatComposerState();
}

class _ChatComposerState extends State<ChatComposer> {
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
  void didUpdateWidget(ChatComposer oldWidget) {
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

  /// web-IDE rule: running + empty draft = Stop; running + draft = Send
  /// (queue). The primary send CTA and the danger Stop button handle the
  /// visual signal in the Aether composer — no bespoke teal is needed.

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
                    maxHeight: math.min(220, widget.availableHeight * 0.25),
                  ),
                  decoration: BoxDecoration(
                    color: Aether.surface,
                    borderRadius: BorderRadius.circular(AetherRadius.rMd),
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
              // ── Composer field — AetherField, multiline, rLg surfaceAlt ──
              AetherField(
                fieldKey: const ValueKey('chat-composer'),
                label: 'Message',
                showLabel: false,
                controller: controller,
                focusNode: widget.focusNode,
                enabled: !locked,
                maxLines: widget.availableHeight < 400 ? 2 : 5,
                minLines: 1,
                radius: AetherRadius.rLg,
                hint: locked
                    ? 'Answer the approval card above first…'
                    : 'Describe what you want to build…  / commands  @ agents',
                contentPadding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
                onSubmitted: (_) {
                  if (!locked) onSend();
                },
              ),
              ?widget.serviceNotice,
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
                          _ModeChip(
                            onEnableControl: widget.onEnableControlMode,
                          ),
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

                      if (widget.editingQueue) {
                        return AetherPrimaryButton(
                          label: 'Save',
                          tooltip: 'Save queued message',
                          icon: Icons.check,
                          iconOnly: true,
                          onPressed: onSend,
                        );
                      }
                      if (runningNow && !hasDraft) {
                        // STOP button appears while the agent is running.
                        return AetherDangerButton(
                          label: 'Stop',
                          tooltip: hasQueued
                              ? 'Stop session (next queued will run)'
                              : 'Stop session',
                          icon: Icons.stop_rounded,
                          iconOnly: true,
                          onPressed: stop,
                        );
                      }
                      if (runningNow && hasDraft) {
                        // Running + draft → send to queue — same primary CTA.
                        return AetherPrimaryButton(
                          label: 'Queue',
                          tooltip: 'Add to queue',
                          icon: Icons.arrow_upward,
                          iconOnly: true,
                          onPressed: onSend,
                        );
                      }
                      return AetherPrimaryButton(
                        label: 'Send',
                        tooltip: 'Send',
                        icon: Icons.arrow_upward,
                        iconOnly: true,
                        onPressed: hasDraft || locked ? onSend : onSend,
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
            'That folder is read-only for Ovid — grant All Files Access or pick another folder.',
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

/// web-IDE mode selector — icon + text chip, opens the agent access mode
/// sheet. The Control-mode enable flow is owned by the chat screen and
/// threaded through [onEnableControl].
class _ModeChip extends StatelessWidget {
  final Future<void> Function(BuildContext) onEnableControl;
  const _ModeChip({required this.onEnableControl});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: AgentService.I,
      builder: (_, _) {
        final m = AgentService.I.mode;
        return GestureDetector(
          onTap: () => showAgentModeSheet(
            context,
            onEnableControl: onEnableControl,
          ),
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
}
