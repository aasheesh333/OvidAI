import 'dart:async';

import 'package:flutter/material.dart';

import '../../design/o_components.dart';
import '../../design/o_motion.dart';
import '../../design/o_tokens.dart';
import 'composer_attachments.dart';
import 'composer_mentions.dart';
import 'composer_voice.dart';
import 'message_blocks.dart';
import 'model_chip.dart';
import 'queue_dock.dart';
import 'voice_reply_card.dart';

// TODO(l10n): move user-facing copy to ARB keys in the localization pass.

/// Base type for every row in a live chat transcript.
sealed class V2LiveChatItem {
  const V2LiveChatItem({required this.id});

  final String id;
}

class V2LiveUserMessage extends V2LiveChatItem {
  const V2LiveUserMessage({
    required super.id,
    required this.text,
    this.timeLabel,
  });

  final String text;
  final String? timeLabel;
}

class V2LiveAssistantMessage extends V2LiveChatItem {
  const V2LiveAssistantMessage({required super.id, required this.markdown});

  final String markdown;
}

class V2LiveThinking extends V2LiveChatItem {
  const V2LiveThinking({
    required super.id,
    required this.label,
    required this.details,
  });

  final String label;
  final List<String> details;
}

class V2LiveTool extends V2LiveChatItem {
  const V2LiveTool({
    required super.id,
    required this.title,
    required this.status,
    required this.progress,
    this.icon = Icons.language_rounded,
  });

  final String title;
  final String status;
  final double progress;
  final IconData icon;
}

class V2LiveArtifact extends V2LiveChatItem {
  const V2LiveArtifact({
    required super.id,
    required this.fileName,
    required this.meta,
    required this.statusLabel,
    required this.previewLabel,
    this.icon = Icons.code_rounded,
  });

  final String fileName;
  final String meta;
  final String statusLabel;
  final String previewLabel;
  final IconData icon;
}

/// A spoken answer with the visual summary card that backs it up.
class V2LiveVoiceReply extends V2LiveChatItem {
  const V2LiveVoiceReply({required super.id, required this.reply});

  final V2VoiceReplyData reply;
}

/// Immutable view data for an active chat.
@immutable
class V2LiveChatData {
  const V2LiveChatData({
    this.title = 'Ovid Si',
    this.sessionId,
    this.sessionTitle = 'Chat',
    this.modelLabel = 'Auto',
    this.items = const [],
    this.running = false,
    this.loading = false,
    this.errorMessage,
    this.statusLabel = 'Ovid is generating code...',
    this.stopHint = 'Press stop to pause',
    this.draft = '',
    this.composerHint = 'Ask Ovid to do anything...',
    this.emptyTitle = 'No messages yet',
    this.emptyMessage = 'Ask Ovid to build something and it will show up here.',
    this.emptyActionLabel = 'Start a chat',
    this.queuedCount = 0,
    this.queuedPreview,
    this.autoOnly = false,
    this.subagentCount = 0,
  }) : assert(subagentCount >= 0, 'subagentCount cannot be negative');

  final String title;
  final String? sessionId;
  final String sessionTitle;
  final String modelLabel;
  final List<V2LiveChatItem> items;
  final bool running;
  final bool loading;
  final String? errorMessage;
  final String statusLabel;
  final String stopHint;
  final String draft;
  final String composerHint;
  final String emptyTitle;
  final String emptyMessage;
  final String emptyActionLabel;

  /// Messages waiting for the active run to finish.
  final int queuedCount;

  /// Preview of the next queued message. Null/empty omits the preview line.
  final String? queuedPreview;

  /// Free and Go are Auto-only. The model chip shows a lock and speaks
  /// "Auto only"; it stays tappable so the upgrade menu can open.
  final bool autoOnly;

  /// Subagents launched in this session, shown as a badge on the model chip.
  final int subagentCount;
}

/// A live transcript with thinking, tools, markdown and generated artifacts.
class V2LiveChatPage extends StatefulWidget {
  const V2LiveChatPage({
    super.key,
    required this.data,
    this.onMenu,
    this.onModelChipTap,
    this.onStudio,
    this.onBrowser,
    this.onMore,
    this.onSend,
    this.onStop,
    this.onDownload,
    this.onCopyCode,
    this.onOpenLink,
    this.onDownloadLink,
    this.onThinkingToggle,
    this.onStartChat,
    this.onRetry,
    this.onAttach,
    this.onPlus,
    this.onMic,
    this.onDraftChanged,
    this.onSendQueuedNow,
    this.onDismissQueued,
    this.onSubmit,
    this.onVoicePlay,
    this.onVoiceSeek,
    this.onVoiceAction,
    this.onVoiceTranscriptToggle,
    this.mentionSource,
    this.attachmentPicker,
    this.voiceService,
    this.voiceLanguage,
  });

  final V2LiveChatData data;
  final VoidCallback? onMenu;
  final VoidCallback? onModelChipTap;
  final VoidCallback? onStudio;
  final VoidCallback? onBrowser;
  final VoidCallback? onMore;
  final ValueChanged<String>? onSend;
  final VoidCallback? onStop;
  final ValueChanged<String>? onDownload;

  /// Copy the text of a code block in an assistant message.
  final ValueChanged<String>? onCopyCode;

  /// Open an image or non-download link from an assistant message.
  final ValueChanged<String>? onOpenLink;

  /// Download an artifact or download link from an assistant message.
  final ValueChanged<String>? onDownloadLink;

  final void Function(String id, bool expanded)? onThinkingToggle;
  final VoidCallback? onStartChat;
  final VoidCallback? onRetry;
  final VoidCallback? onAttach;

  /// When supplied, the composer "+" opens the host's plus menu instead of
  /// the file picker. Null keeps the default picker behaviour.
  final VoidCallback? onPlus;

  final VoidCallback? onMic;
  final ValueChanged<String>? onDraftChanged;

  /// Send the queued message immediately by cancelling the active run. This
  /// is the same behaviour as [onStop]; when null the dock falls back to it.
  final VoidCallback? onSendQueuedNow;

  /// Remove the queued message without sending it.
  final VoidCallback? onDismissQueued;

  /// Rich send callback: text, staged files and the ids the draft references.
  /// When provided it replaces [onSend].
  final ValueChanged<V2ComposerSubmission>? onSubmit;

  /// Play or pause a voice reply, by item id.
  final ValueChanged<String>? onVoicePlay;

  /// Seek inside a voice reply, by item id and position.
  final void Function(String id, Duration position)? onVoiceSeek;

  /// Open the next action attached to a voice reply's visual card.
  final ValueChanged<String>? onVoiceAction;

  /// The transcript was expanded or collapsed for a voice reply.
  final void Function(String id, bool expanded)? onVoiceTranscriptToggle;

  /// `@` suggestion source. Defaults to the live root chats and projects.
  final V2MentionSource? mentionSource;

  /// File picker seam. Defaults to the platform picker; when [onAttach] is
  /// set and no picker is injected, the host keeps handling attachment
  /// selection (legacy wiring).
  final V2AttachmentPicker? attachmentPicker;

  /// Voice seam. When set (or when [onMic] is null) the composer owns
  /// dictation; otherwise [onMic] keeps the host in control.
  final V2VoiceService? voiceService;

  /// Voice-first language id (`hi`, `hinglish`, `pa`, `ta`). Defaults to the
  /// device language, falling back to English.
  final String? voiceLanguage;

  @override
  State<V2LiveChatPage> createState() => _V2LiveChatPageState();
}

class _V2LiveChatPageState extends State<V2LiveChatPage> {
  late final TextEditingController _controller;
  late final V2VoiceDictation _voice;
  final Set<String> _expandedThinking = <String>{};
  final Set<String> _expandedTranscripts = <String>{};

  final List<V2ComposerAttachment> _attachments = [];
  final Map<String, String> _pickedSessionIds = {};
  final Set<String> _pickedProjectIds = {};

  V2ActiveMention? _mention;
  List<V2MentionCandidate> _mentionCandidates = const [];
  String _lastDraft = '';
  String? _attachmentError;
  bool _syncingDraft = false;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.data.draft);
    _lastDraft = _controller.text;
    _controller.addListener(_handleControllerChanged);
    _voice = V2VoiceDictation(
      service: widget.voiceService,
      localeId: V2VoiceLocales.localeFor(
        widget.voiceLanguage ?? V2VoiceLocales.deviceLanguage(),
      ),
    )..onTranscript = _applyVoiceTranscript;
    _voice.addListener(_handleVoiceChanged);
    _refreshMentions();
  }

  @override
  void didUpdateWidget(V2LiveChatPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.data.draft != oldWidget.data.draft &&
        widget.data.draft != _controller.text) {
      _syncingDraft = true;
      _controller.text = widget.data.draft;
      _controller.selection = TextSelection.collapsed(
        offset: _controller.text.length,
      );
      _syncingDraft = false;
      _lastDraft = _controller.text;
      _refreshMentions();
    }
  }

  @override
  void dispose() {
    if (_voice.listening) unawaited(_voice.cancel());
    _voice
      ..removeListener(_handleVoiceChanged)
      ..dispose();
    _controller.dispose();
    super.dispose();
  }

  V2MentionSource get _mentionSource =>
      widget.mentionSource ??
      v2DefaultMentionSource ??
      const V2EmptyMentionSource();

  void _handleControllerChanged() {
    if (_syncingDraft) return;
    _refreshMentions();
    final text = _controller.text;
    if (text != _lastDraft) {
      _lastDraft = text;
      widget.onDraftChanged?.call(text);
    }
    if (mounted) setState(() {});
  }

  void _refreshMentions() {
    final active = v2ActiveMention(_controller.text, _controller.selection);
    if (active == null) {
      _mention = null;
      _mentionCandidates = const [];
      return;
    }
    _mention = active;
    _mentionCandidates = _mentionSource.search(active.query, limit: 5);
  }

  void _handleVoiceChanged() {
    if (mounted) setState(() {});
  }

  void _applyVoiceTranscript(String text) {
    if (!mounted) return;
    _controller.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
  }

  void _insertMention(V2MentionCandidate candidate) {
    final active = _mention;
    if (active == null) return;
    final text = _controller.text;
    final start = active.start.clamp(0, text.length);
    final end = active.end.clamp(start, text.length);
    final next =
        '${text.substring(0, start)}${candidate.token}${text.substring(end)}';
    final caret = start + candidate.token.length;
    if (candidate.isProject) {
      _pickedProjectIds.add(candidate.id);
    } else {
      _pickedSessionIds[V2MentionTokens.sanitizeTitle(
            candidate.title,
          ).toLowerCase()] =
          candidate.id;
    }
    _controller.value = TextEditingValue(
      text: next,
      selection: TextSelection.collapsed(offset: caret),
    );
    setState(() {
      _mention = null;
      _mentionCandidates = const [];
    });
  }

  Future<void> _attach() async {
    if (widget.data.running) return;
    if (widget.onPlus != null) {
      widget.onPlus!();
      return;
    }
    final picker = widget.attachmentPicker;
    if (picker == null && widget.onAttach != null) {
      widget.onAttach!();
      return;
    }
    List<V2ComposerAttachment>? picked;
    try {
      picked = await (picker ?? pickV2AttachmentFiles)();
    } catch (_) {
      if (mounted) {
        setState(() {
          _attachmentError = 'Could not open the file picker. Try again.';
        });
      }
      return;
    }
    if (!mounted || picked == null) return;
    final batch = V2AttachmentRules.accept(
      existing: _attachments,
      incoming: picked,
    );
    setState(() {
      _attachments.addAll(batch.accepted);
      _attachmentError = batch.message;
    });
  }

  void _removeAttachment(V2ComposerAttachment attachment) {
    setState(() {
      _attachments.removeWhere((row) => row.sameFile(attachment));
      _attachmentError = null;
    });
  }

  Future<void> _toggleVoice() async {
    if (widget.data.running) return;
    if (widget.voiceService == null && widget.onMic != null) {
      widget.onMic!();
      return;
    }
    _voice.clearError();
    await _voice.toggle(_controller.text);
  }

  void _send() {
    final text = _controller.text.trim();
    if (text.isEmpty && _attachments.isEmpty) return;
    if (text.isEmpty && widget.onSubmit == null) return;
    if (_voice.listening) unawaited(_voice.stop());
    final refs = v2MentionRefsIn(
      text,
      source: _mentionSource,
      pickedSessionIds: _pickedSessionIds,
      pickedProjectIds: _pickedProjectIds,
      currentSessionId: widget.data.sessionId,
    );
    final submission = V2ComposerSubmission(
      text: text,
      attachments: List.unmodifiable(_attachments),
      sessionRefs: refs.sessionRefs,
      projectRefs: refs.projectRefs,
    );
    if (widget.onSubmit != null) {
      widget.onSubmit!(submission);
    } else {
      widget.onSend?.call(text);
    }
    _clearComposer();
  }

  void _clearComposer() {
    _syncingDraft = true;
    _controller.clear();
    _syncingDraft = false;
    _lastDraft = '';
    widget.onDraftChanged?.call('');
    _voice.clearError();
    setState(() {
      _attachments.clear();
      _attachmentError = null;
      _pickedSessionIds.clear();
      _pickedProjectIds.clear();
      _mention = null;
      _mentionCandidates = const [];
    });
  }

  void _toggleThinking(V2LiveThinking item) {
    final expanded = !_expandedThinking.contains(item.id);
    setState(() {
      if (expanded) {
        _expandedThinking.add(item.id);
      } else {
        _expandedThinking.remove(item.id);
      }
    });
    widget.onThinkingToggle?.call(item.id, expanded);
  }

  void _toggleTranscript(V2LiveVoiceReply item, bool expanded) {
    setState(() {
      if (expanded) {
        _expandedTranscripts.add(item.id);
      } else {
        _expandedTranscripts.remove(item.id);
      }
    });
    widget.onVoiceTranscriptToggle?.call(item.id, expanded);
  }

  @override
  Widget build(BuildContext context) {
    final data = widget.data;
    final canUseComposer = !data.running && !data.loading;
    return OScaffold(
      appBar: _LiveTopBar(
        title: data.title,
        subtitle: data.sessionTitle,
        modelLabel: data.modelLabel,
        autoOnly: data.autoOnly,
        subagentCount: data.subagentCount,
        onMenu: widget.onMenu,
        onModelChipTap: widget.onModelChipTap,
        onStudio: widget.onStudio,
        onBrowser: widget.onBrowser,
        onMore: widget.onMore,
      ),
      body: LayoutBuilder(
        builder: (context, constraints) => Column(
          children: [
            Expanded(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  _buildBody(context),
                  if (_mention != null && canUseComposer)
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 0,
                      child: V2MentionSuggestions(
                        candidates: _mentionCandidates,
                        onSelect: _insertMention,
                      ),
                    ),
                ],
              ),
            ),
            ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: constraints.maxHeight * 0.62,
              ),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (data.queuedCount > 0)
                      V2QueueDock(
                        count: data.queuedCount,
                        preview: data.queuedPreview ?? '',
                        onSendNow: widget.onSendQueuedNow ?? widget.onStop,
                        onDismiss: widget.onDismissQueued,
                      ),
                    _LiveComposer(
                      data: data,
                      controller: _controller,
                      canSend:
                          !data.running &&
                          (_controller.text.trim().isNotEmpty ||
                              (widget.onSubmit != null &&
                                  _attachments.isNotEmpty)),
                      attachments: _attachments,
                      attachmentError: _attachmentError,
                      voiceError: _voice.error,
                      listening: _voice.listening,
                      onRemoveAttachment: _removeAttachment,
                      onSend: _send,
                      onStop: widget.onStop,
                      onAttach: _attach,
                      onPlus: widget.onPlus,
                      onMic: _toggleVoice,
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

  Widget _buildBody(BuildContext context) {
    final data = widget.data;
    if (data.loading) return const OSkeletonList(rows: 5);
    if (data.errorMessage != null) {
      return OErrorState(message: data.errorMessage!, onRetry: widget.onRetry);
    }
    if (data.items.isEmpty) {
      return OEmptyState(
        icon: Icons.forum_outlined,
        title: data.emptyTitle,
        message: data.emptyMessage,
        action: OButton(
          label: data.emptyActionLabel,
          onPressed: widget.onStartChat,
        ),
      );
    }

    final items = data.items;
    final firstCount = items.length < 8 ? items.length : 8;
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(
        OSpace.l,
        OSpace.m,
        OSpace.l,
        OSpace.l,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          OStagger(
            children: [
              for (var i = 0; i < firstCount; i++)
                Padding(
                  padding: const EdgeInsets.only(bottom: OSpace.l),
                  child: _buildItem(context, i, items[i]),
                ),
            ],
          ),
          for (var i = firstCount; i < items.length; i++)
            Padding(
              padding: const EdgeInsets.only(bottom: OSpace.l),
              child: _buildItem(context, i, items[i]),
            ),
        ],
      ),
    );
  }

  Widget _buildItem(BuildContext context, int index, V2LiveChatItem item) {
    final items = widget.data.items;
    final showAvatar = index == 0 || items[index - 1] is V2LiveUserMessage;
    return switch (item) {
      V2LiveUserMessage message => _UserBubble(item: message),
      V2LiveAssistantMessage message => _AssistantFrame(
        showAvatar: showAvatar,
        child: _AssistantBubble(
          item: message,
          onCopyCode: widget.onCopyCode,
          onOpenLink: widget.onOpenLink,
          onDownloadLink: widget.onDownloadLink,
        ),
      ),
      V2LiveThinking message => _AssistantFrame(
        showAvatar: showAvatar,
        child: _ThinkingRow(
          item: message,
          expanded: _expandedThinking.contains(message.id),
          onTap: () => _toggleThinking(message),
        ),
      ),
      V2LiveTool message => _AssistantFrame(
        showAvatar: showAvatar,
        child: _ToolCard(item: message),
      ),
      V2LiveArtifact message => _AssistantFrame(
        showAvatar: showAvatar,
        child: _ArtifactCard(item: message, onDownload: widget.onDownload),
      ),
      V2LiveVoiceReply message => _AssistantFrame(
        showAvatar: showAvatar,
        child: V2VoiceReplyCard(
          key: ValueKey('voice-reply-${message.id}'),
          data: message.reply,
          transcriptExpanded: _expandedTranscripts.contains(message.id),
          onPlay: widget.onVoicePlay == null
              ? null
              : () => widget.onVoicePlay!(message.id),
          onSeek: widget.onVoiceSeek == null
              ? null
              : (position) => widget.onVoiceSeek!(message.id, position),
          onOpenAction: widget.onVoiceAction == null
              ? null
              : () => widget.onVoiceAction!(message.id),
          onToggleTranscript: message.reply.hasTranscript
              ? (expanded) => _toggleTranscript(message, expanded)
              : null,
        ),
      ),
    };
  }
}

class _LiveTopBar extends StatelessWidget implements PreferredSizeWidget {
  const _LiveTopBar({
    required this.title,
    required this.subtitle,
    required this.modelLabel,
    required this.autoOnly,
    required this.subagentCount,
    required this.onMenu,
    required this.onModelChipTap,
    required this.onStudio,
    required this.onBrowser,
    required this.onMore,
  });

  final String title;
  final String subtitle;
  final String modelLabel;
  final bool autoOnly;
  final int subagentCount;
  final VoidCallback? onMenu;
  final VoidCallback? onModelChipTap;
  final VoidCallback? onStudio;
  final VoidCallback? onBrowser;
  final VoidCallback? onMore;

  @override
  Size get preferredSize => const Size.fromHeight(57);

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    return AppBar(
      automaticallyImplyLeading: false,
      titleSpacing: 0,
      leadingWidth: OSpace.touch,
      leading: OIconButton(
        icon: Icons.menu_rounded,
        semanticLabel: 'Open menu',
        onPressed: onMenu,
      ),
      title: Row(
        children: [
          Flexible(
            flex: 3,
            child: V2ModelChip(
              label: modelLabel,
              autoOnly: autoOnly,
              subagentCount: subagentCount,
              enabled: onModelChipTap != null,
              onTap: onModelChipTap,
            ),
          ),
          const SizedBox(width: OSpace.xs),
          Flexible(
            flex: 2,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: OType.h3.copyWith(color: c.text),
                ),
                Text(
                  subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: OType.caption.copyWith(color: c.textMuted),
                ),
              ],
            ),
          ),
        ],
      ),
      actions: [
        OIconButton(
          icon: Icons.terminal_rounded,
          semanticLabel: 'Open Studio',
          onPressed: onStudio,
        ),
        OIconButton(
          icon: Icons.public_rounded,
          semanticLabel: 'Open Browser',
          onPressed: onBrowser,
        ),
        OIconButton(
          icon: Icons.more_vert_rounded,
          semanticLabel: 'More options',
          onPressed: onMore,
        ),
        const SizedBox(width: OSpace.xs),
      ],
      bottom: PreferredSize(
        preferredSize: const Size.fromHeight(1),
        child: Divider(height: 1, color: c.hairline),
      ),
    );
  }
}

class _UserBubble extends StatelessWidget {
  const _UserBubble({required this.item});

  final V2LiveUserMessage item;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    return Align(
      alignment: Alignment.centerRight,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: MediaQuery.sizeOf(context).width * 0.84,
            ),
            child: Container(
              padding: const EdgeInsets.all(OSpace.l),
              decoration: BoxDecoration(
                color: c.surfaceRaised,
                borderRadius: const BorderRadius.only(
                  topLeft: Radius.circular(ORadius.l),
                  topRight: Radius.circular(ORadius.s),
                  bottomLeft: Radius.circular(ORadius.l),
                  bottomRight: Radius.circular(ORadius.l),
                ),
                border: Border.all(color: c.hairline),
              ),
              child: Text(item.text, style: OType.body.copyWith(color: c.text)),
            ),
          ),
          if (item.timeLabel != null) ...[
            const SizedBox(height: OSpace.xs),
            Padding(
              padding: const EdgeInsets.only(right: OSpace.xs),
              child: Text(
                item.timeLabel!,
                style: OType.caption.copyWith(color: c.textFaint),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _AssistantFrame extends StatelessWidget {
  const _AssistantFrame({required this.showAvatar, required this.child});

  final bool showAvatar;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (showAvatar)
          Container(
            width: 32,
            height: 32,
            margin: const EdgeInsets.only(top: 2),
            decoration: BoxDecoration(
              color: c.surfaceRaised,
              shape: BoxShape.circle,
              border: Border.all(color: c.hairline),
            ),
            child: Icon(Icons.auto_awesome_rounded, size: 16, color: c.accent),
          )
        else
          const SizedBox(width: 32),
        const SizedBox(width: OSpace.s),
        Expanded(child: child),
      ],
    );
  }
}

class _AssistantBubble extends StatelessWidget {
  const _AssistantBubble({
    required this.item,
    this.onCopyCode,
    this.onOpenLink,
    this.onDownloadLink,
  });

  final V2LiveAssistantMessage item;
  final ValueChanged<String>? onCopyCode;
  final ValueChanged<String>? onOpenLink;
  final ValueChanged<String>? onDownloadLink;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    return Container(
      padding: const EdgeInsets.all(OSpace.l),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: const BorderRadius.only(
          topLeft: Radius.circular(ORadius.s),
          topRight: Radius.circular(ORadius.l),
          bottomLeft: Radius.circular(ORadius.l),
          bottomRight: Radius.circular(ORadius.l),
        ),
        border: Border.all(color: c.hairline),
      ),
      child: V2MessageBlocks(
        markdown: item.markdown,
        onCopyCode: onCopyCode,
        onOpenLink: onOpenLink,
        onDownload: onDownloadLink,
      ),
    );
  }
}

class _ThinkingRow extends StatelessWidget {
  const _ThinkingRow({
    required this.item,
    required this.expanded,
    required this.onTap,
  });

  final V2LiveThinking item;
  final bool expanded;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    return Material(
      color: c.surfaceAlt,
      borderRadius: BorderRadius.circular(ORadius.m),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(ORadius.m),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: OSpace.touch),
          child: Padding(
            padding: const EdgeInsets.all(OSpace.m),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.psychology_rounded, size: 18, color: c.accent),
                    const SizedBox(width: OSpace.s),
                    Expanded(
                      child: Text(
                        item.label,
                        style: OType.caption.copyWith(
                          color: c.textMuted,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                    AnimatedRotation(
                      turns: expanded ? 0.25 : 0,
                      duration: OMotion.fast,
                      child: Icon(
                        Icons.chevron_right_rounded,
                        size: 18,
                        color: c.textFaint,
                      ),
                    ),
                  ],
                ),
                if (expanded) ...[
                  const SizedBox(height: OSpace.s),
                  for (final detail in item.details)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: Text(
                        detail,
                        style: OType.caption.copyWith(color: c.textMuted),
                      ),
                    ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ToolCard extends StatelessWidget {
  const _ToolCard({required this.item});

  final V2LiveTool item;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    return Container(
      padding: const EdgeInsets.all(OSpace.m),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(ORadius.l),
        border: Border.all(color: c.hairline),
      ),
      child: Column(
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 30,
                height: 30,
                decoration: BoxDecoration(
                  color: c.surfaceAlt,
                  borderRadius: BorderRadius.circular(ORadius.s),
                ),
                child: Icon(item.icon, size: 17, color: c.success),
              ),
              const SizedBox(width: OSpace.s),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: OType.bodySm.copyWith(
                        color: c.text,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Row(
                      children: [
                        OPulse(
                          child: Container(
                            width: 6,
                            height: 6,
                            decoration: BoxDecoration(
                              color: c.success,
                              shape: BoxShape.circle,
                            ),
                          ),
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            item.status,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: OType.caption.copyWith(color: c.success),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: OSpace.m),
          OProgressBar(value: item.progress),
        ],
      ),
    );
  }
}

class _ArtifactCard extends StatelessWidget {
  const _ArtifactCard({required this.item, required this.onDownload});

  final V2LiveArtifact item;
  final ValueChanged<String>? onDownload;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(ORadius.l),
        border: Border.all(color: c.hairline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.all(OSpace.m),
            color: c.surfaceAlt,
            child: Row(
              children: [
                Container(
                  width: 32,
                  height: 32,
                  decoration: BoxDecoration(
                    color: c.accentSoft,
                    borderRadius: BorderRadius.circular(ORadius.s),
                  ),
                  child: Icon(item.icon, size: 17, color: c.accent),
                ),
                const SizedBox(width: OSpace.s),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        item.fileName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: OType.bodySm.copyWith(
                          color: c.text,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      Text(
                        item.meta,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: OType.caption.copyWith(color: c.textMuted),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: OSpace.s),
                OPill(
                  label: item.statusLabel,
                  tone: OPillTone.success,
                  dot: true,
                ),
              ],
            ),
          ),
          Container(
            height: 148,
            color: c.codeBg,
            alignment: Alignment.center,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(item.icon, size: 34, color: c.accent),
                const SizedBox(height: OSpace.s),
                Text(
                  item.previewLabel,
                  textAlign: TextAlign.center,
                  style: OType.caption.copyWith(color: c.textMuted),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(OSpace.m),
            child: Row(
              children: [
                Expanded(
                  child: OButton(
                    label: 'Download',
                    icon: Icons.download_rounded,
                    onPressed: onDownload == null
                        ? null
                        : () => onDownload!(item.id),
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

class _LiveComposer extends StatelessWidget {
  const _LiveComposer({
    required this.data,
    required this.controller,
    required this.canSend,
    required this.attachments,
    required this.attachmentError,
    required this.voiceError,
    required this.listening,
    required this.onRemoveAttachment,
    required this.onSend,
    required this.onStop,
    required this.onAttach,
    required this.onPlus,
    required this.onMic,
  });

  final V2LiveChatData data;
  final TextEditingController controller;
  final bool canSend;
  final List<V2ComposerAttachment> attachments;
  final String? attachmentError;
  final String? voiceError;
  final bool listening;
  final ValueChanged<V2ComposerAttachment> onRemoveAttachment;
  final VoidCallback onSend;
  final VoidCallback? onStop;
  final VoidCallback? onAttach;
  final VoidCallback? onPlus;
  final VoidCallback? onMic;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    final running = data.running;
    final enabled = !running;
    return Padding(
      padding: const EdgeInsets.fromLTRB(OSpace.l, 0, OSpace.l, OSpace.s),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (running)
            Padding(
              padding: const EdgeInsets.only(bottom: OSpace.s),
              child: Row(
                children: [
                  OPulse(
                    child: Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                        color: c.accentFill,
                        shape: BoxShape.circle,
                      ),
                    ),
                  ),
                  const SizedBox(width: OSpace.s),
                  Expanded(
                    flex: 3,
                    child: Text(
                      data.statusLabel,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: OType.caption.copyWith(color: c.textMuted),
                    ),
                  ),
                  const SizedBox(width: OSpace.s),
                  Flexible(
                    flex: 2,
                    child: Text(
                      data.stopHint,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.end,
                      style: OType.caption.copyWith(color: c.textFaint),
                    ),
                  ),
                ],
              ),
            ),
          Container(
            padding: const EdgeInsets.all(OSpace.s),
            decoration: BoxDecoration(
              color: c.surface,
              borderRadius: BorderRadius.circular(ORadius.xl),
              border: Border.all(color: c.hairline),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (attachments.isNotEmpty)
                  V2AttachmentChips(
                    attachments: attachments,
                    enabled: enabled,
                    onRemove: onRemoveAttachment,
                  ),
                if (attachmentError != null)
                  V2ComposerNotice(message: attachmentError!),
                if (voiceError != null)
                  V2ComposerNotice(
                    message: voiceError!,
                    icon: Icons.mic_off_rounded,
                  ),
                Row(
                  children: [
                    OIconButton(
                      icon: listening
                          ? Icons.mic_rounded
                          : Icons.mic_none_rounded,
                      semanticLabel: listening
                          ? 'Stop voice input'
                          : 'Voice input',
                      active: listening,
                      onPressed: enabled ? onMic : null,
                    ),
                    Expanded(
                      child: TextField(
                        controller: controller,
                        enabled: enabled,
                        minLines: 1,
                        maxLines: 3,
                        keyboardType: TextInputType.multiline,
                        style: OType.bodySm.copyWith(color: c.text),
                        decoration: InputDecoration(
                          hintText: running
                              ? 'Generating components...'
                              : data.composerHint,
                          hintStyle: OType.bodySm.copyWith(color: c.textFaint),
                          filled: false,
                          isDense: true,
                          border: InputBorder.none,
                          enabledBorder: InputBorder.none,
                          focusedBorder: InputBorder.none,
                          disabledBorder: InputBorder.none,
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: OSpace.xs,
                            vertical: 12,
                          ),
                        ),
                      ),
                    ),
                    OIconButton(
                      icon: onPlus != null
                          ? Icons.add_rounded
                          : Icons.attach_file_rounded,
                      semanticLabel: onPlus != null
                          ? 'Add attachment or action'
                          : 'Attach a file',
                      onPressed: enabled ? onAttach : null,
                    ),
                    const SizedBox(width: OSpace.xs),
                    _LiveRoundAction(
                      icon: running
                          ? Icons.stop_rounded
                          : Icons.arrow_upward_rounded,
                      label: running ? 'Stop' : 'Send',
                      danger: running,
                      onPressed: running
                          ? onStop
                          : canSend
                          ? onSend
                          : null,
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
}

class _LiveRoundAction extends StatelessWidget {
  const _LiveRoundAction({
    required this.icon,
    required this.label,
    required this.onPressed,
    this.danger = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onPressed;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    final enabled = onPressed != null;
    final background = !enabled
        ? c.surfaceRaised
        : danger
        ? c.danger
        : c.accentFill;
    final foreground = !enabled
        ? c.textFaint
        : danger
        ? c.onDanger
        : c.onAccent;
    return Semantics(
      label: label,
      button: true,
      enabled: enabled,
      child: SizedBox(
        width: OSpace.touch,
        height: OSpace.touch,
        child: Material(
          color: background,
          shape: const CircleBorder(),
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: onPressed,
            child: Icon(icon, size: 22, color: foreground),
          ),
        ),
      ),
    );
  }
}
