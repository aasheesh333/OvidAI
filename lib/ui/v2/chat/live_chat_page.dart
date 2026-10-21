import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';

import '../../design/o_components.dart';
import '../../design/o_motion.dart';
import '../../design/o_tokens.dart';
import '../a11y/live_region.dart';
import 'composer_attachments.dart';
import 'composer_mentions.dart';
import 'composer_plus_sheet.dart';
import 'composer_voice.dart';
import 'message_blocks.dart';
import 'model_chip.dart';
import 'permission_sheet.dart';
import 'queue_dock.dart';
import 'transcript_actions.dart';
import 'transcript_tiles.dart';
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
    this.details = const <String>[],
  });

  final String title;
  final String status;
  final double progress;
  final IconData icon;

  /// Extra lines revealed when the row is expanded.
  final List<String> details;
}

class V2LiveArtifact extends V2LiveChatItem {
  const V2LiveArtifact({
    required super.id,
    required this.fileName,
    required this.meta,
    required this.statusLabel,
    required this.previewLabel,
    this.icon = Icons.code_rounded,
    this.href,
  });

  final String fileName;
  final String meta;
  final String statusLabel;
  final String previewLabel;
  final IconData icon;

  /// Where the artifact lives. Null hides the download action instead of
  /// showing one that cannot save anything.
  final String? href;
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
    this.onArtifactTap,
    this.onStartChat,
    this.onRetry,
    this.onAttach,
    this.onPlus,
    this.onMic,
    this.onPermissionTap,
    this.permissionLabel = 'General',
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
    this.imagePicker,
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

  /// Open an artifact's detail. Null falls back to the local detail route with
  /// the transcript's own metadata.
  final ValueChanged<String>? onArtifactTap;

  final VoidCallback? onStartChat;
  final VoidCallback? onRetry;
  final VoidCallback? onAttach;

  /// When supplied, the composer "+" opens the host's plus menu instead of
  /// the file picker. Null keeps the default picker behaviour.
  final VoidCallback? onPlus;

  final VoidCallback? onMic;

  /// Opens the permission sheet. When null the live composer hides the chip
  /// rather than showing one that cannot change anything.
  final VoidCallback? onPermissionTap;

  /// The mode in force for this chat (`General` by default).
  final String permissionLabel;

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

  /// Image-only picker for the plus menu's Photo row.
  final V2ImagePicker? imagePicker;

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
  final Set<String> _expandedTools = <String>{};
  final Set<String> _expandedTranscripts = <String>{};

  final List<V2ComposerAttachment> _attachments = [];
  final Map<String, String> _pickedSessionIds = {};
  final Set<String> _pickedProjectIds = {};

  V2ActiveMention? _mention;
  List<V2MentionCandidate> _mentionCandidates = const [];
  String _lastDraft = '';
  String? _attachmentError;
  bool _syncingDraft = false;

  /// Last asynchronous result, announced through a live region. Cleared after
  /// two seconds so the same result can be announced again.
  String _announcement = '';
  Timer? _announcementTimer;

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
    if (widget.data.queuedCount > oldWidget.data.queuedCount) {
      _announce('Message queued');
    }
    if (oldWidget.data.running && !widget.data.running) {
      _announce('Run finished');
    }
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
    _announcementTimer?.cancel();
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
    final text = _controller.text;
    if (text != _lastDraft) {
      _lastDraft = text;
      widget.onDraftChanged?.call(text);
    }
    final hadMention = _mention != null;
    final previous = _mentionCandidates;
    _refreshMentions();
    // Typing must not rebuild the transcript. The composer listens to the
    // controller for its send state, so only the mention overlay (which lives
    // above the transcript) needs a page build.
    final mentionChanged =
        (_mention != null) != hadMention ||
        !_sameCandidates(previous, _mentionCandidates);
    if (mounted && mentionChanged) setState(() {});
  }

  static bool _sameCandidates(
    List<V2MentionCandidate> a,
    List<V2MentionCandidate> b,
  ) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i].id != b[i].id) return false;
    }
    return true;
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
    await _openPlusMenu();
  }

  /// The composer-owned "+" menu. File and Photo stage real files; the Studio
  /// row opens Studio when the host wired it; Camera is disabled with an
  /// honest reason; Connectors is omitted because this page has no route.
  Future<void> _openPlusMenu() async {
    if (!mounted) return;
    await showV2ComposerPlusSheet(
      context,
      data: const V2ComposerPlusData(
        cameraAvailable: false,
        cameraUnavailableReason: V2ComposerPlusSheet.cameraBuildReason,
        showConnectors: false,
      ),
      onPhoto: () => unawaited(_pickAttachments(images: true)),
      onFile: () => unawaited(_pickAttachments(images: false)),
      onOpenStudio: widget.onStudio,
    );
  }

  Future<void> _pickAttachments({required bool images}) async {
    if (widget.data.running) return;
    if (!images && widget.attachmentPicker == null && widget.onAttach != null) {
      widget.onAttach!();
      return;
    }
    final picker = images
        ? (widget.imagePicker ?? pickV2ImageFiles)
        : (widget.attachmentPicker ?? pickV2AttachmentFiles);
    List<V2ComposerAttachment>? picked;
    try {
      picked = await picker();
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

  void _announce(String message) {
    if (!mounted) return;
    _announcementTimer?.cancel();
    setState(() => _announcement = message);
    _announcementTimer = Timer(const Duration(seconds: 2), () {
      if (mounted) setState(() => _announcement = '');
    });
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
    _announce('Message sent');
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

  void _toggleTool(V2LiveTool item) {
    setState(() {
      if (!_expandedTools.remove(item.id)) _expandedTools.add(item.id);
    });
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

  /// Opens a link from the transcript. The host callback wins; without one the
  /// URL opens in the platform browser, so a link row is never a dead tap.
  Future<void> _openLink(String url) async {
    final handler = widget.onOpenLink;
    if (handler != null) {
      handler(url);
      return;
    }
    // Default: open the real URL with feedback and scheme validation.
    await v2OpenTranscriptLink(context, url);
  }

  /// Downloads (or, without a host downloader, saves) a transcript link.
  Future<void> _downloadLink(String url) async {
    final handler = widget.onDownloadLink;
    if (handler != null) {
      handler(url);
      return;
    }
    // Default: fetch and write a real file, then confirm the saved name.
    await v2SaveTranscriptLink(context, url);
  }

  // Method tear-offs: stable callbacks instead of a fresh closure per row on
  // every build.
  void _handleOpenLink(String url) => unawaited(_openLink(url));
  void _handleDownloadLink(String url) => unawaited(_downloadLink(url));

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
                      onSubmitEnabled: widget.onSubmit != null,
                      attachments: _attachments,
                      attachmentError: _attachmentError,
                      voiceError: _voice.error,
                      listening: _voice.listening,
                      onRemoveAttachment: _removeAttachment,
                      onSend: _send,
                      onStop: widget.onStop,
                      onAttach: _attach,
                      onMic: _toggleVoice,
                      onPermissionTap: widget.onPermissionTap,
                      permissionLabel: widget.permissionLabel,
                    ),
                    OLiveRegion(message: _announcement),
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
    // Lazy list: a 5,000-message session builds only the rows in (and just
    // around) the viewport instead of the whole transcript every frame.
    final firstCount = items.length < 8 ? items.length : 8;
    return ListView.builder(
      key: const ValueKey<String>('v2-live-transcript'),
      padding: const EdgeInsets.fromLTRB(
        OSpace.l,
        OSpace.m,
        OSpace.l,
        OSpace.l,
      ),
      itemCount: items.length,
      itemBuilder: (context, index) {
        final row = Padding(
          padding: const EdgeInsets.only(bottom: OSpace.l),
          child: _buildItem(context, index, items[index]),
        );
        if (index >= firstCount) return row;
        // Keep the short entrance stagger for the first screenful only.
        final delay = OMotion.stagger * index;
        return OFadeSlide(
          delay: delay > const Duration(milliseconds: 400)
              ? const Duration(milliseconds: 400)
              : delay,
          child: row,
        );
      },
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
          onOpenLink: _handleOpenLink,
          onDownloadLink: _handleDownloadLink,
        ),
      ),
      V2LiveThinking message => _AssistantFrame(
        showAvatar: showAvatar,
        child: V2ThinkingTile(
          key: ValueKey('thinking-${message.id}'),
          label: message.label,
          details: message.details,
          expanded: _expandedThinking.contains(message.id),
          onToggle: () => _toggleThinking(message),
        ),
      ),
      V2LiveTool message => _AssistantFrame(
        showAvatar: showAvatar,
        child: V2ToolTile(
          key: ValueKey('tool-${message.id}'),
          title: message.title,
          status: message.status,
          progress: message.progress,
          icon: message.icon,
          details: message.details,
          expanded: _expandedTools.contains(message.id),
          onToggle: () => _toggleTool(message),
        ),
      ),
      V2LiveArtifact message => _AssistantFrame(
        showAvatar: showAvatar,
        child: V2ArtifactTile(
          key: ValueKey('artifact-${message.id}'),
          fileName: message.fileName,
          meta: message.meta,
          statusLabel: message.statusLabel,
          previewLabel: message.previewLabel,
          icon: message.icon,
          onOpen: widget.onArtifactTap != null
              ? () => widget.onArtifactTap!(message.id)
              : () => openV2ArtifactDetail(
                  context,
                  fileName: message.fileName,
                  meta: message.meta,
                  statusLabel: message.statusLabel,
                  previewLabel: message.previewLabel,
                  icon: message.icon,
                ),
          onDownload: widget.onDownload != null
              ? () => widget.onDownload!(message.id)
              : message.href == null
              ? null
              : () => startV2ArtifactDownload(
                  context,
                  message.href!,
                  suggestedName: message.fileName,
                ),
        ),
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
    return Semantics(
      container: true,
      explicitChildNodes: true,
      sortKey: OrdinalSortKey(0),
      child: AppBar(
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
                Semantics(
                  container: true,
                  header: true,
                  child: Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: OType.h3.copyWith(color: c.text),
                  ),
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

class _LiveComposer extends StatelessWidget {
  const _LiveComposer({
    required this.data,
    required this.controller,
    required this.onSubmitEnabled,
    required this.attachments,
    required this.attachmentError,
    required this.voiceError,
    required this.listening,
    required this.onRemoveAttachment,
    required this.onSend,
    required this.onStop,
    required this.onAttach,
    required this.onMic,
    required this.onPermissionTap,
    required this.permissionLabel,
  });

  final V2LiveChatData data;
  final TextEditingController controller;

  /// Whether an attachment-only send is allowed (a rich submit handler).
  final bool onSubmitEnabled;
  final List<V2ComposerAttachment> attachments;
  final String? attachmentError;
  final String? voiceError;
  final bool listening;
  final ValueChanged<V2ComposerAttachment> onRemoveAttachment;
  final VoidCallback onSend;
  final VoidCallback? onStop;
  final VoidCallback? onAttach;
  final VoidCallback? onMic;
  final VoidCallback? onPermissionTap;
  final String permissionLabel;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    final running = data.running;
    final enabled = !running;
    // Read the controller at press time; the field itself listens to it, so
    // typing never has to rebuild the page (or the transcript).
    bool canSendNow() =>
        !running &&
        (controller.text.trim().isNotEmpty ||
            (onSubmitEnabled && attachments.isNotEmpty));
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
                if (onPermissionTap != null)
                  Padding(
                    padding: const EdgeInsets.only(
                      left: OSpace.xs,
                      bottom: OSpace.xs,
                    ),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: V2PermissionChip(
                        label: permissionLabel,
                        onTap: onPermissionTap,
                      ),
                    ),
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
                      child: CallbackShortcuts(
                        bindings: {
                          const SingleActivator(LogicalKeyboardKey.enter): () {
                            if (canSendNow()) onSend();
                          },
                          const SingleActivator(
                            LogicalKeyboardKey.numpadEnter,
                          ): () {
                            if (canSendNow()) onSend();
                          },
                        },
                        child: TextField(
                          controller: controller,
                          enabled: enabled,
                          minLines: 1,
                          maxLines: 3,
                          keyboardType: TextInputType.multiline,
                          textInputAction: TextInputAction.newline,
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
                    ),
                    OIconButton(
                      icon: Icons.add_rounded,
                      semanticLabel: 'Add attachment or action',
                      onPressed: enabled ? onAttach : null,
                    ),
                    const SizedBox(width: OSpace.xs),
                    // Only this button depends on the draft text.
                    ValueListenableBuilder<TextEditingValue>(
                      valueListenable: controller,
                      builder: (context, value, _) {
                        final canSend =
                            !running &&
                            (value.text.trim().isNotEmpty ||
                                (onSubmitEnabled && attachments.isNotEmpty));
                        return _LiveRoundAction(
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
                        );
                      },
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
