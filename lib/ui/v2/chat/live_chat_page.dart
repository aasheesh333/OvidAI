import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';

import '../../../core/artifact_kind.dart';
import '../../design/o_components.dart';
import '../../design/o_motion.dart';
import '../../design/o_screen.dart';
import '../../design/o_tokens.dart';
import '../a11y/live_region.dart';
import 'chat_error_bar.dart';
import 'composer_attachments.dart';
import 'composer_mentions.dart';
import 'composer_plus_sheet.dart';
import 'composer_row.dart';
import 'composer_voice.dart';
import 'message_blocks.dart';
import 'model_chip.dart';
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

  /// Kept for hosts that log or group by time. The transcript never draws a
  /// per-message timestamp: a message is its text, nothing else.
  final String? timeLabel;
}

class V2LiveAssistantMessage extends V2LiveChatItem {
  const V2LiveAssistantMessage({
    required super.id,
    required this.markdown,
    this.serverMessageId,
  });

  final String markdown;

  /// The server's message id when this row is a stored answer, else null.
  ///
  /// Regenerate and Branch address a message by its server id, so a row the
  /// server does not store (a turn tail, a locally minted row) must not offer
  /// them. Null keeps those actions off the menu; Copy still works.
  final String? serverMessageId;
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

/// A generated file in the transcript. [id] is the artifact's identity: the
/// shell resolves it to the same vault row the library opens, so tapping the
/// row reaches the real detail route instead of launching a bare URL.
class V2LiveArtifact extends V2LiveChatItem {
  const V2LiveArtifact({
    required super.id,
    required this.fileName,
    required this.meta,
    required this.statusLabel,
    required this.previewLabel,
    this.icon = Icons.code_rounded,
    this.href,
    this.kind,
    this.sizeBytes,
    this.downloadUrl,
    this.thumbnail,
    this.content,
  });

  final String fileName;
  final String meta;
  final String statusLabel;
  final String previewLabel;
  final IconData icon;

  /// Where the artifact lives. Null hides the download action instead of
  /// showing one that cannot save anything.
  final String? href;

  /// The coarse type the artifact model reports. Drives the real preview kind
  /// and whether Copy can read text; null falls back to the file name.
  final ArtifactKind? kind;

  /// The file's real size in bytes, when the model knows it.
  final int? sizeBytes;

  /// A URL the row can really save. Null means no download is offered.
  final String? downloadUrl;

  /// Real pixels for an image artifact. Null keeps the type glyph.
  final ImageProvider? thumbnail;

  /// The artifact's text when the host already has it (an inline page). The
  /// detail page and Copy use it; a URL-only file is fetched on demand.
  final String? content;
}

/// What a transcript action really did.
///
/// The host runs the server call and returns this; the page never removes a
/// row on its own. [message] is the copy to show, and is empty when the
/// outcome needs no announcement (a regenerating run shows its own state).
@immutable
class V2MessageActionReport {
  const V2MessageActionReport.done([this.message = '']) : ok = true;
  const V2MessageActionReport.failed(this.message) : ok = false;

  final bool ok;
  final String message;
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
    this.sendError,
    this.onSendErrorAction,
    this.onDismissSendError,
    this.statusLabel = 'Ovid is generating code...',
    this.stopHint = 'Press stop to pause',
    this.draft = '',
    this.composerHint = 'Ask Ovid anything',
    this.emptyTitle = 'Ask Ovid anything',
    this.emptyMessage = 'Replies and files appear here.',
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

  /// A failed send or run, shown above the composer so the transcript stays
  /// visible. Distinct from [errorMessage], which replaces the whole body when
  /// the chat itself could not load.
  final V2ChatError? sendError;
  final VoidCallback? onSendErrorAction;
  final VoidCallback? onDismissSendError;

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

  /// Returns a copy carrying [error] in the composer error slot. Used by the
  /// shell, which owns the facade and therefore the failure state.
  V2LiveChatData copyWithSendError(V2ChatError? error) => V2LiveChatData(
    title: title,
    sessionId: sessionId,
    sessionTitle: sessionTitle,
    modelLabel: modelLabel,
    items: items,
    running: running,
    loading: loading,
    errorMessage: errorMessage,
    sendError: error,
    onSendErrorAction: onSendErrorAction,
    onDismissSendError: onDismissSendError,
    statusLabel: statusLabel,
    stopHint: stopHint,
    draft: draft,
    composerHint: composerHint,
    emptyTitle: emptyTitle,
    emptyMessage: emptyMessage,
    emptyActionLabel: emptyActionLabel,
    queuedCount: queuedCount,
    queuedPreview: queuedPreview,
    autoOnly: autoOnly,
    subagentCount: subagentCount,
  );
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
    this.onRegenerateMessage,
    this.onBranchMessage,
    this.onOpenLink,
    this.onDownloadLink,
    this.onThinkingToggle,
    this.onArtifactTap,
    this.onStartChat,
    this.onRetry,
    this.onSendErrorAction,
    this.onDismissSendError,
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

  /// Run the answer's prompt again on the server, replacing the answer (and
  /// anything after it). Null hides Regenerate. The returned report carries
  /// the real outcome: the page never drops a row before the server agrees.
  final Future<V2MessageActionReport> Function(String serverMessageId)?
  onRegenerateMessage;

  /// Start a new chat seeded with this history, up to the answer. Null hides
  /// Branch from here. The host owns the navigation and reports what happened.
  final Future<V2MessageActionReport> Function(String serverMessageId)?
  onBranchMessage;

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

  /// Runs the action on [V2LiveChatData.sendError].
  final VoidCallback? onSendErrorAction;
  final VoidCallback? onDismissSendError;
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

  /// Owns the transcript viewport so an appended row can follow the tail
  /// without resetting a reader who scrolled up to read earlier messages.
  late final ScrollController _transcriptController;

  /// How close to the bottom still counts as "reading the tail".
  static const double _tailSlop = 96;

  final Set<String> _expandedThinking = <String>{};
  final Set<String> _expandedTools = <String>{};
  final Set<String> _expandedTranscripts = <String>{};

  /// Assistant rows with a server action in flight. The row shows a small
  /// progress glyph in place of its menu button until the host reports back.
  final Set<String> _busyMessageIds = <String>{};

  final List<V2ComposerAttachment> _attachments = [];
  final Map<String, String> _pickedSessionIds = {};
  final Set<String> _pickedProjectIds = {};

  /// Ids the transcript has already shown. An item whose id arrives later (a
  /// new message at the tail) gets a single ≤200 ms fade-in; everything that
  /// was already there stays still, and scrolling never replays it.
  final Set<String> _knownItemIds = <String>{};
  final Set<String> _freshItemIds = <String>{};

  /// Ids present on the first frame: only they get the staggered entrance,
  /// so an appended row never fades twice.
  final Set<String> _initialItemIds = <String>{};
  Timer? _freshTimer;

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
    _transcriptController = ScrollController();
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
    _knownItemIds.addAll(widget.data.items.map((item) => item.id));
    _initialItemIds.addAll(_knownItemIds);
    _refreshMentions();
  }

  @override
  void didUpdateWidget(V2LiveChatPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.data.queuedCount > oldWidget.data.queuedCount) {
      // Say what is waiting, not just that something is. The preview is the
      // queued text the host already has; the count alone is not enough for a
      // screen reader to decide whether to send it now.
      final preview = widget.data.queuedPreview?.trim();
      _announce(
        preview == null || preview.isEmpty
            ? 'Message queued'
            : 'Queued: $preview',
      );
    }
    if (oldWidget.data.running && !widget.data.running) {
      _announce('Run finished');
    }
    // A newly appended row fades in once. Ids the first frame already showed
    // are known, so the initial paint never trips this path.
    final fresh = <V2LiveChatItem>[
      for (final item in widget.data.items)
        if (!_knownItemIds.contains(item.id)) item,
    ];
    if (fresh.isNotEmpty) {
      _knownItemIds.addAll(fresh.map((item) => item.id));
      _freshItemIds.addAll(fresh.map((item) => item.id));
      _freshTimer?.cancel();
      _freshTimer = Timer(OMotion.base + OMotion.stagger, () {
        if (mounted) setState(_freshItemIds.clear);
      });
      final announcement = _newItemAnnouncement(fresh);
      if (announcement != null) _announce(announcement, transient: false);
    }
    // A live run appends rows and grows the streaming tail. Follow it only
    // when the reader was already at the bottom; otherwise leave the offset
    // exactly where they put it.
    final grew = widget.data.items.length > oldWidget.data.items.length;
    final tailChanged =
        widget.data.items.isNotEmpty &&
        oldWidget.data.items.isNotEmpty &&
        !identical(widget.data.items.last, oldWidget.data.items.last);
    if ((grew || tailChanged) && _wasAtTail()) _pinToTail();
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
    _freshTimer?.cancel();
    _transcriptController.dispose();
    if (_voice.listening) unawaited(_voice.cancel());
    _voice
      ..removeListener(_handleVoiceChanged)
      ..dispose();
    _controller.dispose();
    super.dispose();
  }

  /// True when the viewport sits at (or within [_tailSlop] of) the newest row
  /// in the *current* layout. Read before an append is laid out, this is the
  /// reader's intent: following the tail, or deliberately reading further up.
  bool _wasAtTail() {
    if (!_transcriptController.hasClients) return true;
    final position = _transcriptController.position;
    if (!position.hasContentDimensions) return true;
    return position.pixels >= position.maxScrollExtent - _tailSlop;
  }

  /// Keeps the newest row in view after an append, but only for a reader who
  /// was already following the tail. A jump (not an animation) means a
  /// streaming token never fights the scroll physics or loses the offset.
  void _pinToTail() {
    var attempts = 0;
    void settle() {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_transcriptController.hasClients) return;
        final position = _transcriptController.position;
        if (!position.hasContentDimensions) return;
        if (position.maxScrollExtent <= 0) return;
        if (position.pixels < position.maxScrollExtent) {
          _transcriptController.jumpTo(position.maxScrollExtent);
        }
        attempts++;
        if (attempts >= 3) return;
        // A lazy list estimates the extent of rows it has not built yet. The
        // newly built window reports its real height on the next frame, so
        // ask for one more pass instead of stopping short of the tail.
        WidgetsBinding.instance.ensureVisualUpdate();
        settle();
      });
    }

    settle();
  }

  /// The shortest useful spoken cue for an appended row. Thinking and tool
  /// rows are progress, not results, and announcing each one would turn a run
  /// into a stream of interruptions.
  static String? _newItemAnnouncement(List<V2LiveChatItem> fresh) {
    for (final item in fresh.reversed) {
      final label = switch (item) {
        V2LiveAssistantMessage _ => 'Ovid replied',
        V2LiveArtifact _ => 'Artifact ready',
        V2LiveVoiceReply _ => 'Voice reply ready',
        _ => null,
      };
      if (label != null) return label;
    }
    return null;
  }

  /// User and answer rows after [index] — the messages a history edit from
  /// this row would remove. Tool and artifact rows belong to those turns, so
  /// counting them again would overstate the loss.
  static int _messageCountAfter(List<V2LiveChatItem> items, int index) {
    var count = 0;
    for (var i = index + 1; i < items.length; i++) {
      if (items[i] is V2LiveUserMessage ||
          items[i] is V2LiveAssistantMessage) {
        count++;
      }
    }
    return count;
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
      ),
      onPhoto: () => unawaited(_pickAttachments(images: true)),
      onFile: () => unawaited(_pickAttachments(images: false)),
      onOpenStudio: widget.onStudio,
      // The chip's fallback: at 320 dp / 200 % text the row cannot hold it,
      // so the same sheet action keeps permission reachable.
      permissionLabel: widget.permissionLabel,
      onPermission: widget.onPermissionTap,
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

  void _announce(String message, {bool transient = true}) {
    if (!mounted) return;
    _announcementTimer?.cancel();
    _announcementTimer = null;
    setState(() => _announcement = message);
    // New-message cues stay until the next cue replaces them: the same row
    // never needs to be announced twice, and a pending clear would only make
    // a later identical label silent.
    if (!transient) return;
    _announcementTimer = Timer(const Duration(seconds: 2), () {
      if (mounted) setState(() => _announcement = '');
    });
  }

  void _send() {
    final text = _controller.text.trim();
    if (widget.onSubmit == null && widget.onSend == null) return;
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
    // Sending is a deliberate jump to the newest row, even for a reader who
    // had scrolled back: the reply is what they are waiting for.
    _pinToTail();
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

  /// The artifact's real download URL, or null when it has none.
  String? _artifactLink(V2LiveArtifact artifact) {
    final url = artifact.downloadUrl?.trim();
    if (url != null && url.isNotEmpty) return url;
    final href = artifact.href?.trim();
    return href == null || href.isEmpty ? null : href;
  }

  /// Copy needs something real to put on the clipboard: text the host already
  /// has, or a URL whose text can be fetched on demand.
  bool _canCopyArtifact(V2LiveArtifact artifact) =>
      (artifact.content?.trim().isNotEmpty ?? false) ||
      _artifactLink(artifact) != null;

  /// Copies the artifact's text (fetching it when only a URL is known), or its
  /// link, and reports which of those really happened.
  Future<void> _copyArtifact(V2LiveArtifact artifact) async {
    final result = await v2CopyArtifactContent(
      fileName: artifact.fileName,
      content: artifact.content,
      url: _artifactLink(artifact),
      kind: artifact.kind,
    );
    if (!mounted) return;
    final message = switch (result) {
      V2ArtifactCopyResult.text => 'Copied',
      V2ArtifactCopyResult.link => 'Link copied',
      V2ArtifactCopyResult.failed => 'Could not copy',
    };
    _notify(message);
  }

  void _notify(String message) {
    if (!mounted) return;
    ScaffoldMessenger.maybeOf(context)
      ?..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  /// An answer plus its one quiet action affordance: a muted ⋯ at the right
  /// edge. Copy, Branch and Regenerate live in that menu, so the transcript
  /// stays text rather than three rows of buttons.
  Widget _assistantMessage(
    V2LiveAssistantMessage message, {
    required bool isLastAssistant,
    required int laterMessages,
    required int laterRows,
  }) {
    final blocks = V2MessageBlocks(
      markdown: message.markdown,
      onCopyCode: widget.onCopyCode,
      onOpenLink: _handleOpenLink,
      onDownload: _handleDownloadLink,
    );
    final busy = _busyMessageIds.contains(message.id);
    final canBranch =
        message.serverMessageId != null && widget.onBranchMessage != null;
    // Regenerate only on the newest answer of a settled run: an older one
    // would delete everything after it, and a running one would race the live
    // answer.
    final canRegenerate =
        isLastAssistant &&
        !widget.data.running &&
        message.serverMessageId != null &&
        widget.onRegenerateMessage != null;
    if (!canBranch && !canRegenerate && message.markdown.trim().isEmpty) {
      return blocks;
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        blocks,
        Align(
          alignment: Alignment.centerRight,
          child: busy
              ? Semantics(
                  label: 'Working on this message',
                  liveRegion: true,
                  child: const SizedBox(
                    width: OSpace.touch,
                    height: OSpace.touch,
                    child: Center(
                      child: SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    ),
                  ),
                )
              : OIconButton(
                  icon: Icons.more_horiz_rounded,
                  semanticLabel: 'Actions',
                  size: 18,
                  onPressed: () => unawaited(
                    _openMessageActions(
                      message,
                      canRegenerate: canRegenerate,
                      laterMessages: laterMessages,
                      laterRows: laterRows,
                    ),
                  ),
                ),
        ),
      ],
    );
  }

  /// The answer's action menu. Only actions the host really wired appear, so
  /// a row never opens a sheet full of controls that cannot act.
  Future<void> _openMessageActions(
    V2LiveAssistantMessage message, {
    required bool canRegenerate,
    required int laterMessages,
    required int laterRows,
  }) async {
    final canBranch =
        message.serverMessageId != null && widget.onBranchMessage != null;
    final action = await showOSheet<String>(
      context,
      title: 'Actions',
      builder: (sheetContext) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          OListRow(
            title: 'Copy',
            icon: Icons.copy_rounded,
            showChevron: false,
            onTap: () => Navigator.of(sheetContext).pop('copy'),
          ),
          if (canBranch)
            OListRow(
              title: 'Branch',
              subtitle: 'New chat from this point',
              icon: Icons.call_split_rounded,
              showChevron: false,
              onTap: () => Navigator.of(sheetContext).pop('branch'),
            ),
          if (canRegenerate)
            OListRow(
              title: 'Regenerate',
              subtitle: _regenerateSubtitle(laterMessages, laterRows),
              icon: Icons.refresh_rounded,
              showChevron: false,
              onTap: () => Navigator.of(sheetContext).pop('regenerate'),
            ),
          const SizedBox(height: OSpace.s),
        ],
      ),
    );
    if (!mounted || action == null) return;
    switch (action) {
      case 'copy':
        await _copyMessage(message);
      case 'branch':
        await _runMessageAction(message, branch: true);
      case 'regenerate':
        // Regenerating removes the answer, so anything after it goes too. A
        // later message is destructive enough to name the count first.
        if (laterRows > 0) {
          final confirmed = await _confirmRegenerate(laterMessages);
          if (!confirmed || !mounted) return;
        }
        await _runMessageAction(message, branch: false);
    }
  }

  Future<void> _copyMessage(V2LiveAssistantMessage message) async {
    final text = message.markdown.trim();
    if (text.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: text));
    _notify('Copied');
  }

  /// Runs one server action and reports exactly what the host answered.
  /// Nothing is removed here: a failed call leaves the transcript untouched.
  Future<void> _runMessageAction(
    V2LiveAssistantMessage message, {
    required bool branch,
  }) async {
    final serverId = message.serverMessageId;
    final handler = branch
        ? widget.onBranchMessage
        : widget.onRegenerateMessage;
    if (serverId == null || handler == null) return;
    if (!_busyMessageIds.add(message.id)) return;
    setState(() {});
    V2MessageActionReport report;
    try {
      report = await handler(serverId);
    } catch (_) {
      report = const V2MessageActionReport.failed(
        'That did not work. Check your connection and try again.',
      );
    }
    if (!mounted) return;
    setState(() => _busyMessageIds.remove(message.id));
    final text = report.message.trim();
    if (text.isNotEmpty) _notify(text);
    if (report.ok && !branch) _announce('Regenerating this answer');
  }

  /// The menu's one-line warning: name the message count when there is one,
  /// otherwise say that the answer's tail goes with it.
  static String _regenerateSubtitle(int laterMessages, int laterRows) {
    if (laterMessages > 0) {
      return 'Removes this answer and $laterMessages later '
          '${laterMessages == 1 ? 'message' : 'messages'}';
    }
    return laterRows > 0
        ? 'Removes this answer and what follows it'
        : 'Run this prompt again';
  }

  Future<bool> _confirmRegenerate(int later) async {
    final c = OColors.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        scrollable: true,
        title: const Text('Regenerate this answer?'),
        content: Text(
          later > 0
              ? 'This removes this answer and the $later '
                    '${later == 1 ? 'message' : 'messages'} after it, along '
                    'with anything else that follows, then runs the prompt '
                    'again. This cannot be undone.'
              : 'This removes this answer and everything after it, then runs '
                    'the prompt again. This cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          TextButton.icon(
            style: TextButton.styleFrom(foregroundColor: c.danger),
            onPressed: () => Navigator.pop(dialogContext, true),
            icon: const Icon(Icons.refresh_rounded, size: 18),
            label: const Text('Regenerate'),
          ),
        ],
      ),
    );
    return confirmed == true;
  }

  @override
  Widget build(BuildContext context) {
    final data = widget.data;
    final canUseComposer = !data.running && !data.loading;
    return OScaffold(
      appBar: _LiveTopBar(
        // The session name is the useful identity here; the app name is not
        // repeated on every screen. The subtitle is state-only: idle has none.
        title: data.sessionTitle.trim().isEmpty
            ? data.title
            : data.sessionTitle,
        subtitle: data.running ? 'Working' : null,
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
                      // The suggestion sheet shares the transcript's column:
                      // a tablet does not stretch a phone menu edge to edge.
                      child: Align(
                        alignment: Alignment.bottomCenter,
                        child: ConstrainedBox(
                          constraints: BoxConstraints(
                            maxWidth: OResponsive.of(context).maxContentWidth,
                          ),
                          child: V2MentionSuggestions(
                            candidates: _mentionCandidates,
                            onSelect: _insertMention,
                          ),
                        ),
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
                child: Align(
                  alignment: Alignment.topCenter,
                  // The composer shares the transcript's column, so a tablet
                  // does not stretch the input across the window.
                  child: ConstrainedBox(
                    key: const ValueKey('v2-live-composer-column'),
                    constraints: BoxConstraints(
                      maxWidth: OResponsive.of(context).maxContentWidth,
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        // A failed send sits here, not over the transcript: the
                        // user keeps their place and can retry in context.
                        if (data.sendError != null)
                          V2ChatErrorBar(
                            error: data.sendError!,
                            onAction: widget.onSendErrorAction,
                            onDismiss: widget.onDismissSendError,
                          ),
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
                          sendEnabled:
                              widget.onSubmit != null || widget.onSend != null,
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
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBody(BuildContext context) {
    final data = widget.data;
    if (data.loading) {
      // The skeleton lives in the same column as the transcript, so a tablet
      // does not paint placeholder rows across the whole window.
      return Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: OResponsive.of(context).maxContentWidth,
          ),
          child: const OSkeletonList(rows: 5),
        ),
      );
    }
    if (data.errorMessage != null) {
      return OErrorState(message: data.errorMessage!, onRetry: widget.onRetry);
    }
    if (data.items.isEmpty) {
      return _LiveEmptyState(data: data, onStart: widget.onStartChat);
    }

    final items = data.items;
    final gutter = OResponsive.of(context).gutter;
    // Regenerate is safe on the newest stored answer only: an older one would
    // also delete every message the user has read since. A run-failure note or
    // a system tail is not an answer the server can re-run, so it never owns
    // the action. One reverse scan keeps the lazy list from doing that work
    // per row.
    var lastAssistant = -1;
    for (var i = items.length - 1; i >= 0; i--) {
      final item = items[i];
      if (item is V2LiveAssistantMessage && item.serverMessageId != null) {
        lastAssistant = i;
        break;
      }
    }
    // Lazy list: a 5,000-message session builds only the rows in (and just
    // around) the viewport instead of the whole transcript every frame.
    final firstCount = items.length < 6 ? items.length : 6;
    return Align(
      alignment: Alignment.topCenter,
      // At 600 dp+ the transcript keeps a readable line length and centres.
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: OResponsive.of(context).maxContentWidth,
        ),
        child: ListView.builder(
          key: const ValueKey<String>('v2-live-transcript'),
          controller: _transcriptController,
          padding: EdgeInsets.fromLTRB(gutter, OSpace.l, gutter, OSpace.xl),
          itemCount: items.length,
          itemBuilder: (context, index) {
            final item = items[index];
            final isLastAssistant = index == lastAssistant;
            // What a regenerate from this answer would also remove. Only the
            // newest answer can be regenerated, so only it pays for the scan.
            final laterMessages = isLastAssistant
                ? _messageCountAfter(items, index)
                : 0;
            // Files and tool rows after the answer are deleted with it too,
            // even when no later message exists.
            final laterRows = isLastAssistant ? items.length - index - 1 : 0;
            final hasActions =
                item is V2LiveAssistantMessage &&
                item.markdown.trim().isNotEmpty;
            final row = Padding(
              // The id is the row's identity: a rebuild reuses the element
              // instead of re-creating it, and a host that prepends history
              // cannot shift state onto the wrong message.
              key: ValueKey('live-item-${item.id}'),
              padding: EdgeInsets.only(
                // An answer's action menu is its footer: it already adds the
                // 48 dp control box, so the row's own gap shrinks to keep the
                // transcript's rhythm.
                bottom: hasActions ? OSpace.s : OSpace.xl,
              ),
              child: _buildItem(
                context,
                item,
                isTail: index == items.length - 1,
                isLastAssistant: isLastAssistant,
                laterMessages: laterMessages,
                laterRows: laterRows,
              ),
            );
            // A message that just arrived fades in once, in under 200 ms.
            if (_freshItemIds.contains(item.id)) {
              return _FadeInOnce(child: row);
            }
            if (index >= firstCount || !_initialItemIds.contains(item.id)) {
              return row;
            }
            // A short entrance for the first screenful only. Delay plus
            // duration stays within 200 ms, so the transcript is still before
            // the user can read past the first row.
            final stagger = OMotion.stagger * index;
            final delay = stagger > const Duration(milliseconds: 80)
                ? const Duration(milliseconds: 80)
                : stagger;
            return OFadeSlide(
              duration: OMotion.base - delay,
              delay: delay,
              child: row,
            );
          },
        ),
      ),
    );
  }

  Widget _buildItem(
    BuildContext context,
    V2LiveChatItem item, {
    required bool isTail,
    required bool isLastAssistant,
    required int laterMessages,
    required int laterRows,
  }) {
    // The transcript is the screen. A message is text on the background or a
    // gentle bubble — no avatar, no header row, no timestamp line.
    return switch (item) {
      V2LiveUserMessage message => _UserBubble(item: message),
      // Assistant answers render full-width in the content column: plain text
      // on the page background, not a card. Their actions hide in a small
      // menu so the answer itself stays chromeless.
      V2LiveAssistantMessage message => _assistantMessage(
        message,
        isLastAssistant: isLastAssistant,
        laterMessages: laterMessages,
        laterRows: laterRows,
      ),
      V2LiveThinking message => V2ThinkingTile(
        key: ValueKey('thinking-${message.id}'),
        label: message.label,
        details: message.details,
        expanded: _expandedThinking.contains(message.id),
        // The live tail of an active run shimmers; a finished thought does not.
        running: widget.data.running && isTail,
        onToggle: () => _toggleThinking(message),
      ),
      V2LiveTool message => V2ToolTile(
        key: ValueKey('tool-${message.id}'),
        title: message.title,
        status: message.status,
        progress: message.progress,
        icon: message.icon,
        details: message.details,
        expanded: _expandedTools.contains(message.id),
        onToggle: () => _toggleTool(message),
      ),
      V2LiveArtifact message => V2ArtifactTile(
        key: ValueKey('artifact-${message.id}'),
        fileName: message.fileName,
        meta: message.meta,
        statusLabel: message.statusLabel,
        previewLabel: message.previewLabel,
        icon: message.icon,
        thumbnail: message.thumbnail,
        copyText: v2ArtifactIsTextual(message.fileName, kind: message.kind),
        onOpen: widget.onArtifactTap != null
            ? () => widget.onArtifactTap!(message.id)
            : () => openV2ArtifactDetail(
                context,
                fileName: message.fileName,
                meta: message.meta,
                previewLabel: message.previewLabel,
                icon: message.icon,
                kind: message.kind,
                sizeBytes: message.sizeBytes,
                downloadUrl: _artifactLink(message),
                content: message.content,
                thumbnail: message.thumbnail,
              ),
        onCopy: _canCopyArtifact(message)
            ? () => unawaited(_copyArtifact(message))
            : null,
        onDownload: widget.onDownload != null
            ? () => widget.onDownload!(message.id)
            : _artifactLink(message) == null
            ? null
            : () => startV2ArtifactDownload(
                context,
                _artifactLink(message)!,
                suggestedName: message.fileName,
              ),
      ),
      V2LiveVoiceReply message => V2VoiceReplyCard(
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
    };
  }
}

/// Title, one line of copy and the single next action. No icon medallion and
/// no explanatory paragraph.
class _LiveEmptyState extends StatelessWidget {
  const _LiveEmptyState({required this.data, required this.onStart});

  final V2LiveChatData data;
  final VoidCallback? onStart;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(OSpace.xl),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 360),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Semantics(
                container: true,
                header: true,
                child: Text(
                  data.emptyTitle,
                  textAlign: TextAlign.center,
                  style: OType.h2.copyWith(color: c.text),
                ),
              ),
              const SizedBox(height: OSpace.s),
              Text(
                data.emptyMessage,
                textAlign: TextAlign.center,
                style: OType.bodySm.copyWith(color: c.textMuted),
              ),
              if (onStart != null) ...[
                const SizedBox(height: OSpace.l),
                OButton(label: data.emptyActionLabel, onPressed: onStart),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// The one-shot entrance for a message that just arrived: a 200 ms fade, then
/// the wrapper is gone. Honour reduced motion by skipping the fade entirely.
class _FadeInOnce extends StatelessWidget {
  const _FadeInOnce({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (OMove.reduced(context)) return child;
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 0, end: 1),
      duration: OMotion.base,
      curve: OMotion.standard,
      child: child,
      builder: (context, value, child) =>
          Opacity(opacity: value, alwaysIncludeSemantics: true, child: child),
    );
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

  /// State only (`Working` while a run is active). Null when idle, so the
  /// header is a single line.
  final String? subtitle;
  final String modelLabel;
  final bool autoOnly;
  final int subagentCount;
  final VoidCallback? onMenu;
  final VoidCallback? onModelChipTap;
  final VoidCallback? onStudio;
  final VoidCallback? onBrowser;
  final VoidCallback? onMore;

  @override
  // One quiet bar: no hairline under it — the transcript separates itself.
  Size get preferredSize => Size.fromHeight(subtitle == null ? 56 : 74);

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        // The budget is the space this bar actually got, not the window: at
        // 600 dp the shell keeps its 280 dp rail, so the header has 320 dp and
        // two actions overflowed it by 16 dp at 200 % text.
        final wideHeader = !OBreakpoints.isCompact(constraints.maxWidth);
        final showStudio = wideHeader && onStudio != null;
        final showBrowser = wideHeader && onBrowser != null;
        final showMore = onMore != null;
        final actionCount =
            (showStudio ? 1 : 0) + (showBrowser ? 1 : 0) + (showMore ? 1 : 0);
        final leadingWidth = onMenu == null ? 0.0 : OSpace.touch;
        // Leave the title at least one 48 dp target beside the chip: the chip
        // ellipsizes its label instead of pushing the title off the bar.
        final titleBudget =
            constraints.maxWidth -
            leadingWidth -
            actionCount * OSpace.touch -
            OSpace.xs;
        final chipWidth = titleBudget - OSpace.s - OSpace.touch;
        return _buildBar(
          context,
          c,
          showStudio: showStudio,
          showBrowser: showBrowser,
          showMore: showMore,
          // No handler means no menu to open: a grey chip that says
          // "unavailable" is still a control that cannot act.
          showChip: onModelChipTap != null && chipWidth >= OSpace.touch,
          chipWidth: chipWidth,
        );
      },
    );
  }

  Widget _buildBar(
    BuildContext context,
    OColors c, {
    required bool showStudio,
    required bool showBrowser,
    required bool showMore,
    required bool showChip,
    required double chipWidth,
  }) {
    return Semantics(
      container: true,
      explicitChildNodes: true,
      sortKey: OrdinalSortKey(0),
      child: AppBar(
        automaticallyImplyLeading: false,
        titleSpacing: 0,
        leadingWidth: OSpace.touch,
        // Above 600 dp the rail replaces the drawer, so the shell passes no
        // handler: drawing the glyph anyway would be a dead control.
        leading: onMenu == null
            ? null
            : OIconButton(
                icon: Icons.menu_rounded,
                semanticLabel: 'Open menu',
                onPressed: onMenu,
              ),
        title: MediaQuery.withClampedTextScaling(
          maxScaleFactor: 1.3,
          child: Row(
            children: [
              // The chip keeps its intrinsic width; the title takes the rest.
              // Squeezing the chip below its icons is what overflowed at 320 dp.
              if (showChip) ...[
                ConstrainedBox(
                  constraints: BoxConstraints(
                    maxWidth: chipWidth > v2ModelChipMaxWidth
                        ? v2ModelChipMaxWidth
                        : chipWidth,
                  ),
                  child: V2ModelChip(
                    label: modelLabel,
                    autoOnly: autoOnly,
                    subagentCount: subagentCount,
                    onTap: onModelChipTap,
                  ),
                ),
                const SizedBox(width: OSpace.s),
              ],
              Expanded(
                // Idle is a single line. The state subtitle ("Working") is the
                // only reason the title ever needs a second line.
                child: subtitle == null
                    ? Semantics(
                        container: true,
                        header: true,
                        child: Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: OType.h2.copyWith(color: c.text),
                        ),
                      )
                    : Column(
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
                              style: OType.h2.copyWith(color: c.text),
                            ),
                          ),
                          Text(
                            subtitle!,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: OType.caption.copyWith(color: c.textMuted),
                          ),
                        ],
                      ),
              ),
            ],
          ),
        ),
        actions: [
          // Studio and Browser are header shortcuts, not the only way to
          // reach those surfaces. A host that did not wire them gets no glyph
          // rather than a grey one.
          if (showStudio)
            OIconButton(
              icon: Icons.terminal_rounded,
              semanticLabel: 'Open Studio',
              onPressed: onStudio,
            ),
          if (showBrowser)
            OIconButton(
              icon: Icons.public_rounded,
              semanticLabel: 'Open Browser',
              onPressed: onBrowser,
            ),
          if (showMore)
            OIconButton(
              icon: Icons.more_vert_rounded,
              semanticLabel: 'More options',
              onPressed: onMore,
            ),
          const SizedBox(width: OSpace.xs),
        ],
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
    final time = item.timeLabel?.trim() ?? '';
    // The transcript never draws a timestamp, but the time the host already
    // holds is still useful to a screen reader. One node keeps the speaker,
    // the time and the text in reading order.
    final spoken = time.isEmpty
        ? 'You. ${item.text}'
        : 'You, $time. ${item.text}';
    return LayoutBuilder(
      builder: (context, constraints) {
        // 78 % of the column on a phone, 560 dp absolute cap on a tablet.
        final cap = constraints.maxWidth * 0.78;
        return Semantics(
          container: true,
          label: spoken,
          excludeSemantics: true,
          child: Align(
            alignment: Alignment.centerRight,
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: cap > 560 ? 560 : cap),
              // A gentle filled bubble on the page background: no border, no
              // shadow, no header and no timestamp.
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: OSpace.l,
                  vertical: OSpace.m,
                ),
                decoration: BoxDecoration(
                  color: c.surfaceAlt,
                  borderRadius: BorderRadius.circular(ORadius.l),
                ),
                child: Text(
                  item.text,
                  style: OType.body.copyWith(color: c.text),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _LiveComposer extends StatelessWidget {
  const _LiveComposer({
    required this.data,
    required this.controller,
    required this.onSubmitEnabled,
    required this.sendEnabled,
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

  /// Whether any send handler exists at all. A composer with no owner must not
  /// accept text and then announce that it was sent.
  final bool sendEnabled;
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
    // A run pauses the composer (its one action is Stop); a history that is
    // still loading has no owner to send to yet. Both are temporary states.
    final enabled = !running && !data.loading;
    // Read the controller at press time; the field itself listens to it, so
    // typing never has to rebuild the page (or the transcript).
    bool canSendNow() =>
        enabled &&
        sendEnabled &&
        (controller.text.trim().isNotEmpty ||
            (onSubmitEnabled && attachments.isNotEmpty));
    return Padding(
      padding: const EdgeInsets.fromLTRB(OSpace.l, 0, OSpace.l, OSpace.s),
      child: Container(
        padding: const EdgeInsets.all(OSpace.s),
        decoration: BoxDecoration(
          color: c.surface,
          borderRadius: BorderRadius.circular(ORadius.xl),
          border: Border.all(color: c.hairline),
        ),
        child: Column(
          key: const ValueKey('v2-live-composer-stack'),
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
            // One row: plus, permission, field, mic, send. Nothing else. The
            // running status lives in the field's hint so it never becomes a
            // second row above the input.
            V2ComposerRow(
              field: Padding(
                padding: const EdgeInsets.symmetric(horizontal: OSpace.xs),
                child: CallbackShortcuts(
                  bindings: {
                    const SingleActivator(LogicalKeyboardKey.enter): () {
                      if (canSendNow()) onSend();
                    },
                    const SingleActivator(LogicalKeyboardKey.numpadEnter): () {
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
                      hintText: running ? data.statusLabel : data.composerHint,
                      hintStyle: OType.bodySm.copyWith(color: c.textFaint),
                      hintMaxLines: 1,
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
              send: ValueListenableBuilder<TextEditingValue>(
                valueListenable: controller,
                builder: (context, value, _) {
                  final canSend =
                      enabled &&
                      sendEnabled &&
                      (value.text.trim().isNotEmpty ||
                          (onSubmitEnabled && attachments.isNotEmpty));
                  return _LiveRoundAction(
                    icon: running
                        ? Icons.stop_rounded
                        : Icons.arrow_upward_rounded,
                    label: running ? 'Stop' : 'Send',
                    // The host's own words for stopping, spoken only: the
                    // visible control is the icon and its label.
                    hint: running ? data.stopHint : null,
                    danger: running,
                    onPressed: running
                        ? onStop
                        : canSend
                        ? onSend
                        : null,
                  );
                },
              ),
              onPlus: enabled ? onAttach : null,
              onMic: enabled ? onMic : null,
              listening: listening,
              permissionLabel: permissionLabel,
              onPermission: onPermissionTap,
            ),
          ],
        ),
      ),
    );
  }
}

class _LiveRoundAction extends StatelessWidget {
  const _LiveRoundAction({
    required this.icon,
    required this.label,
    required this.onPressed,
    this.hint,
    this.danger = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onPressed;

  /// Spoken context for a control whose label is deliberately terse (the
  /// host's stop hint). Never drawn.
  final String? hint;
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
      hint: hint,
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
