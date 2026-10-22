import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';

import '../../design/o_components.dart';
import '../../design/o_motion.dart';
import '../../design/o_screen.dart';
import '../../design/o_tokens.dart';
import '../a11y/live_region.dart';
import 'composer_attachments.dart';
import 'composer_mentions.dart';
import 'composer_plus_sheet.dart';
import 'composer_row.dart';
import 'composer_voice.dart';
import 'model_chip.dart';
import 'queue_dock.dart';

// TODO(l10n): move user-facing copy to ARB keys in the localization pass.

/// A tappable starting point on the empty chat screen.
@immutable
class V2ChatSuggestion {
  const V2ChatSuggestion({
    required this.title,
    required this.subtitle,
    required this.icon,
  });

  final String title;
  final String subtitle;
  final IconData icon;
}

enum V2ChatState { empty, loading, running, planLimited, offline, error }

/// Immutable view data for the home chat screen. The wiring owns the live
/// session, network and model state.
@immutable
class V2ChatPageData {
  const V2ChatPageData({
    this.title = 'Ovid Si',
    this.sessionId,
    this.modelLabel = 'Auto',
    this.tokensLabel = '50M tokens left today',
    this.fastAgentLabel = 'Fast agent',
    this.headline = 'What should we build?',
    this.subtitle = 'Ask anything. Ovid works in the background.',
    this.draft = '',
    this.state = V2ChatState.empty,
    this.suggestions = const [
      V2ChatSuggestion(
        title: 'Build a landing page',
        subtitle: 'React & Tailwind components',
        icon: Icons.web_rounded,
      ),
      V2ChatSuggestion(
        title: 'Research a topic',
        subtitle: 'Deep web synthesis & citations',
        icon: Icons.auto_awesome_rounded,
      ),
      V2ChatSuggestion(
        title: 'Fix a repo bug',
        subtitle: 'Git branch integration',
        icon: Icons.bug_report_rounded,
      ),
    ],
    this.queuedCount = 0,
    this.queuedPreview,
    this.autoOnly = false,
    this.subagentCount = 0,
    this.limitResetLabel = 'Resets in 6h 12m',
    this.errorMessage =
        'Ovid could not load this chat. Check your connection and try again.',
    this.permissionLabel = 'General',
    this.composerHint = 'Ask Ovid to do anything...',
    this.offlineTitle = "You're offline",
    this.offlineMessage = 'Messages will send when you reconnect.',
  }) : assert(subagentCount >= 0, 'subagentCount cannot be negative');

  final String title;
  final String? sessionId;
  final String modelLabel;
  final String tokensLabel;
  final String fastAgentLabel;
  final String headline;

  /// Kept for hosts that compose their own empty state. The page renders one
  /// short line under the wordmark ([headline]) and no paragraph.
  final String subtitle;
  final String draft;
  final V2ChatState state;
  final List<V2ChatSuggestion> suggestions;
  final int queuedCount;

  /// Text of the next queued message. When null or empty the dock still shows
  /// the count but omits the preview line.
  final String? queuedPreview;

  /// Free and Go are Auto-only. The model chip shows a lock and speaks
  /// "Auto only"; it stays tappable so the upgrade menu can open.
  final bool autoOnly;

  /// Subagents launched in this session, shown as a badge on the model chip.
  final int subagentCount;

  final String limitResetLabel;
  final String errorMessage;
  final String permissionLabel;
  final String composerHint;
  final String offlineTitle;
  final String offlineMessage;
}

/// The core chat home screen: top bar, empty state, suggestions and composer.
class V2ChatPage extends StatefulWidget {
  const V2ChatPage({
    super.key,
    required this.data,
    this.onMenu,
    this.onModelChipTap,
    this.onStudio,
    this.onBrowser,
    this.onMore,
    this.onSuggestionTap,
    this.onSend,
    this.onStop,
    this.onAttach,
    this.onPlus,
    this.onPermissionTap,
    this.onMic,
    this.onRetry,
    this.onSeePlans,
    this.onDraftChanged,
    this.onSendQueuedNow,
    this.onDismissQueued,
    this.onSubmit,
    this.mentionSource,
    this.attachmentPicker,
    this.imagePicker,
    this.voiceService,
    this.voiceLanguage,
  });

  final V2ChatPageData data;
  final VoidCallback? onMenu;
  final VoidCallback? onModelChipTap;
  final VoidCallback? onStudio;
  final VoidCallback? onBrowser;
  final VoidCallback? onMore;
  final ValueChanged<V2ChatSuggestion>? onSuggestionTap;
  final ValueChanged<String>? onSend;
  final VoidCallback? onStop;
  final VoidCallback? onAttach;

  /// When supplied, the composer "+" opens the host's plus menu instead of
  /// the file picker. Null keeps the default picker behaviour.
  final VoidCallback? onPlus;

  final VoidCallback? onPermissionTap;
  final VoidCallback? onMic;
  final VoidCallback? onRetry;
  final VoidCallback? onSeePlans;
  final ValueChanged<String>? onDraftChanged;

  /// Send the queued message immediately by cancelling the active run. This
  /// is the same behaviour as [onStop]; when null the dock falls back to it.
  final VoidCallback? onSendQueuedNow;

  /// Remove the queued message without sending it.
  final VoidCallback? onDismissQueued;

  /// Rich send callback: text, staged files and the ids the draft references.
  /// When provided it replaces [onSend].
  final ValueChanged<V2ComposerSubmission>? onSubmit;

  /// `@` suggestion source. Defaults to the live root chats and projects.
  final V2MentionSource? mentionSource;

  /// File picker seam. Defaults to the platform picker; when [onAttach] is
  /// set and no picker is injected, the host keeps handling attachment
  /// selection (legacy wiring).
  final V2AttachmentPicker? attachmentPicker;

  /// Image-only picker for the plus menu's Photo row. Defaults to the
  /// platform image picker.
  final V2ImagePicker? imagePicker;

  /// Voice seam. When set (or when [onMic] is null) the composer owns
  /// dictation; otherwise [onMic] keeps the host in control.
  final V2VoiceService? voiceService;

  /// Voice-first language id (`hi`, `hinglish`, `pa`, `ta`). Defaults to the
  /// device language, falling back to English.
  final String? voiceLanguage;

  @override
  State<V2ChatPage> createState() => _V2ChatPageState();
}

class _V2ChatPageState extends State<V2ChatPage> {
  late final TextEditingController _controller;
  late final V2VoiceDictation _voice;

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
  void didUpdateWidget(V2ChatPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.data.queuedCount > oldWidget.data.queuedCount) {
      _announce('Message queued');
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

  void _setDraft(String value) {
    _controller.value = TextEditingValue(
      text: value,
      selection: TextSelection.collapsed(offset: value.length),
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
    if (_locked || _running) return;
    if (widget.onPlus != null) {
      widget.onPlus!();
      return;
    }
    await _openPlusMenu();
  }

  /// The composer owns the "+" menu when the host does not supply one. Every
  /// row it shows performs a real action: File and Photo stage files, and the
  /// blocked Studio row opens Studio (when the host wired it). Camera has no
  /// capture implementation in this build, so it is disabled with an honest
  /// reason instead of opening a gallery picker that pretends to be a camera.
  /// Connectors has no route here, so the row is omitted rather than dead.
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
      // The chip's fallback: at 320 dp / 200 % text the row cannot hold it,
      // so the same sheet action keeps permission reachable.
      permissionLabel: widget.data.permissionLabel,
      onPermission: widget.onPermissionTap,
    );
  }

  Future<void> _pickAttachments({required bool images}) async {
    if (_locked || _running) return;
    // Legacy host wiring: when a host supplies `onAttach` and no picker, the
    // host owns file selection. Images always use the composer's picker
    // because the host seam has no image variant.
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
    if (_locked || _running) return;
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

  bool get _locked => widget.data.state == V2ChatState.planLimited;
  bool get _running => widget.data.state == V2ChatState.running;
  bool get _canSend =>
      !_locked &&
      !_running &&
      (widget.onSubmit != null || widget.onSend != null) &&
      (_controller.text.trim().isNotEmpty ||
          (widget.onSubmit != null && _attachments.isNotEmpty));

  @override
  Widget build(BuildContext context) {
    final data = widget.data;
    return OScaffold(
      appBar: _ChatTopBar(
        title: data.title,
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
                  OAnimatedSwap(
                    child: KeyedSubtree(
                      key: ValueKey(data.state),
                      child: _buildBody(context),
                    ),
                  ),
                  if (_mention != null && !_locked && !_running)
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
            // At 320 dp / 200 % text the composer plus chips and notices can
            // be taller than the screen. Cap the dock and let it scroll
            // instead of overflowing the transcript.
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
                    _Composer(
                      data: data,
                      controller: _controller,
                      canSend: _canSend,
                      running: _running,
                      locked: _locked,
                      attachments: _attachments,
                      attachmentError: _attachmentError,
                      voiceError: _voice.error,
                      listening: _voice.listening,
                      onRemoveAttachment: _removeAttachment,
                      onSend: _send,
                      onStop: widget.onStop,
                      onAttach: _attach,
                      onPermissionTap: widget.onPermissionTap,
                      onMic: _toggleVoice,
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
    switch (data.state) {
      case V2ChatState.loading:
        return const OSkeletonList(rows: 5);
      case V2ChatState.error:
        return OErrorState(message: data.errorMessage, onRetry: widget.onRetry);
      case V2ChatState.planLimited:
        return OEmptyState(
          icon: Icons.hourglass_top_rounded,
          title: 'Daily limit reached',
          message:
              "You've used all 50M free tokens for today. ${data.limitResetLabel}.",
          action: OButton(
            label: 'See plans',
            icon: Icons.bolt_rounded,
            onPressed: widget.onSeePlans,
          ),
        );
      case V2ChatState.running:
        return _RunningState(onStop: widget.onStop);
      case V2ChatState.empty:
      case V2ChatState.offline:
        return _HomeContent(
          data: data,
          offline: data.state == V2ChatState.offline,
          onSuggestionTap: (suggestion) {
            _setDraft(suggestion.title);
            widget.onSuggestionTap?.call(suggestion);
          },
          onRetry: widget.onRetry,
        );
    }
  }
}

class _ChatTopBar extends StatelessWidget implements PreferredSizeWidget {
  const _ChatTopBar({
    required this.title,
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
  final String modelLabel;
  final bool autoOnly;
  final int subagentCount;
  final VoidCallback? onMenu;
  final VoidCallback? onModelChipTap;
  final VoidCallback? onStudio;
  final VoidCallback? onBrowser;
  final VoidCallback? onMore;

  @override
  // One quiet bar: no hairline under it.
  Size get preferredSize => const Size.fromHeight(56);

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        // The budget is the space this bar actually got, not the window: at
        // 600 dp the shell keeps its 280 dp rail, so the header has 320 dp and
        // two actions overflowed it by 16 dp at 200 % text.
        final wideHeader = !OBreakpoints.isCompact(constraints.maxWidth);
        return _buildBar(context, c, wideHeader: wideHeader);
      },
    );
  }

  Widget _buildBar(
    BuildContext context,
    OColors c, {
    required bool wideHeader,
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
              // The chip keeps its intrinsic width; the title expands into the
              // free space and ellipsizes instead of squeezing the chip.
              V2ModelChip(
                label: modelLabel,
                autoOnly: autoOnly,
                subagentCount: subagentCount,
                enabled: onModelChipTap != null,
                onTap: onModelChipTap,
              ),
              const SizedBox(width: OSpace.s),
              Expanded(
                child: Semantics(
                  container: true,
                  header: true,
                  child: Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: OType.h2.copyWith(color: c.text),
                  ),
                ),
              ),
            ],
          ),
        ),
        actions: [
          if (wideHeader) ...[
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
          ],
          if (onMore != null)
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

class _HomeContent extends StatelessWidget {
  const _HomeContent({
    required this.data,
    required this.offline,
    required this.onSuggestionTap,
    required this.onRetry,
  });

  final V2ChatPageData data;
  final bool offline;
  final ValueChanged<V2ChatSuggestion> onSuggestionTap;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    // Same capped column as the transcript, so the home state centres on a
    // tablet instead of stretching the wordmark and chips. The cap comes from
    // the breakpoint (640 at 600 dp, 720 at 900 dp), never a fixed number.
    return OContent(
      alignment: Alignment.topCenter,
      child: SingleChildScrollView(
        padding: const EdgeInsets.only(top: OSpace.xl, bottom: OSpace.l),
        child: OFadeSlide(
          duration: OMotion.base,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (offline) ...[
                _OfflineBanner(data: data, onRetry: onRetry),
                const SizedBox(height: OSpace.xl),
              ],
              // The empty state is the brand: the wordmark, one short line and
              // three starting points. No icon circle, no paragraph.
              Text(
                data.title,
                textAlign: TextAlign.center,
                style: OType.h2.copyWith(color: c.text),
              ),
              const SizedBox(height: OSpace.s),
              Text(
                data.headline,
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: OType.bodySm.copyWith(color: c.textMuted),
              ),
              const SizedBox(height: OSpace.xl),
              // Three starting points at most, as chips: one line each, no
              // card subtitles and no trailing arrow.
              Wrap(
                alignment: WrapAlignment.center,
                spacing: OSpace.s,
                runSpacing: OSpace.s,
                children: [
                  for (final suggestion in data.suggestions.take(3))
                    OChip(
                      label: suggestion.title,
                      icon: suggestion.icon,
                      onTap: () => onSuggestionTap(suggestion),
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

class _OfflineBanner extends StatelessWidget {
  const _OfflineBanner({required this.data, required this.onRetry});

  final V2ChatPageData data;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    return Container(
      padding: const EdgeInsets.all(OSpace.m),
      decoration: BoxDecoration(
        color: c.warn.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(ORadius.l),
        border: Border.all(color: c.warn.withValues(alpha: 0.28)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.cloud_off_rounded, size: 20, color: c.warn),
          const SizedBox(width: OSpace.s),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  data.offlineTitle,
                  style: OType.label.copyWith(color: c.text),
                ),
                const SizedBox(height: OSpace.xxs),
                Text(
                  data.offlineMessage,
                  style: OType.caption.copyWith(color: c.textMuted),
                ),
                if (data.queuedCount > 0) ...[
                  const SizedBox(height: OSpace.xxs),
                  Text(
                    data.queuedCount == 1
                        ? '1 message is waiting to send.'
                        : '${data.queuedCount} messages are waiting to send.',
                    style: OType.caption.copyWith(color: c.warn),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: OSpace.s),
          OButton(
            label: 'Retry',
            variant: OButtonVariant.ghost,
            onPressed: onRetry,
          ),
        ],
      ),
    );
  }
}

class _RunningState extends StatelessWidget {
  const _RunningState({required this.onStop});

  final VoidCallback? onStop;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(OSpace.xl),
        child: OFadeSlide(
          duration: OMotion.base,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              OPulse(
                child: Container(
                  width: 14,
                  height: 14,
                  decoration: BoxDecoration(
                    color: c.accentFill,
                    shape: BoxShape.circle,
                  ),
                ),
              ),
              const SizedBox(height: OSpace.l),
              Text(
                'Ovid is working',
                textAlign: TextAlign.center,
                style: OType.h2.copyWith(color: c.text),
              ),
              const SizedBox(height: OSpace.l),
              OButton(
                label: 'Stop',
                variant: OButtonVariant.danger,
                onPressed: onStop,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Composer extends StatelessWidget {
  const _Composer({
    required this.data,
    required this.controller,
    required this.canSend,
    required this.running,
    required this.locked,
    required this.attachments,
    required this.attachmentError,
    required this.voiceError,
    required this.listening,
    required this.onRemoveAttachment,
    required this.onSend,
    required this.onStop,
    required this.onAttach,
    required this.onPermissionTap,
    required this.onMic,
  });

  final V2ChatPageData data;
  final TextEditingController controller;
  final bool canSend;
  final bool running;
  final bool locked;
  final List<V2ComposerAttachment> attachments;
  final String? attachmentError;
  final String? voiceError;
  final bool listening;
  final ValueChanged<V2ComposerAttachment> onRemoveAttachment;
  final VoidCallback onSend;
  final VoidCallback? onStop;
  final VoidCallback? onAttach;
  final VoidCallback? onPermissionTap;
  final VoidCallback? onMic;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    final enabled = !locked && !running;
    return Align(
      alignment: Alignment.topCenter,
      // The input never grows past the transcript column on a tablet.
      child: ConstrainedBox(
        key: const ValueKey('v2-chat-composer-column'),
        constraints: BoxConstraints(
          maxWidth: OResponsive.of(context).maxContentWidth,
        ),
        child: Container(
          margin: const EdgeInsets.fromLTRB(OSpace.l, 0, OSpace.l, OSpace.s),
          padding: const EdgeInsets.all(OSpace.s),
          decoration: BoxDecoration(
            color: c.surface,
            borderRadius: BorderRadius.circular(ORadius.xl),
            border: Border.all(color: c.hairline),
          ),
          child: Column(
            key: const ValueKey('v2-chat-composer-stack'),
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
              // One row: plus, permission, field, mic, send. Nothing else.
              V2ComposerRow(
                field: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: OSpace.xs),
                  child: CallbackShortcuts(
                    bindings: {
                      const SingleActivator(LogicalKeyboardKey.enter): () {
                        if (canSend) onSend();
                      },
                      const SingleActivator(LogicalKeyboardKey.numpadEnter): () {
                        if (canSend) onSend();
                      },
                    },
                    child: TextField(
                      controller: controller,
                      enabled: enabled,
                      minLines: 1,
                      maxLines: 3,
                      keyboardType: TextInputType.multiline,
                      textInputAction: TextInputAction.newline,
                      style: OType.body.copyWith(color: c.text),
                      decoration: InputDecoration(
                        hintText: running
                            ? 'Ovid is working...'
                            : locked
                            ? 'Upgrade to keep building'
                            : data.composerHint,
                        hintStyle: OType.body.copyWith(color: c.textFaint),
                        filled: false,
                        isDense: true,
                        border: InputBorder.none,
                        enabledBorder: InputBorder.none,
                        focusedBorder: InputBorder.none,
                        disabledBorder: InputBorder.none,
                        contentPadding: const EdgeInsets.symmetric(
                          vertical: 12,
                        ),
                      ),
                    ),
                  ),
                ),
                send: _RoundAction(
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
                onPlus: enabled ? onAttach : null,
                onMic: enabled ? onMic : null,
                listening: listening,
                permissionLabel: data.permissionLabel,
                onPermission: onPermissionTap,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _RoundAction extends StatelessWidget {
  const _RoundAction({
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
