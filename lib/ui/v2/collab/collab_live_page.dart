import 'dart:async';

import 'package:flutter/material.dart';

import '../../design/o_components.dart';
import '../../design/o_motion.dart';
import '../../design/o_screen.dart';
import '../../design/o_tokens.dart';
import '../a11y/live_region.dart';
import 'turn_banner.dart';

// TODO(l10n): extract this screen's English copy during the ARB pass.

const String _endedTitle = 'Chat ended';

enum V2CollabLiveStatus {
  loading,
  empty,
  error,
  ready,

  /// The creator ended the session. The transcript stays readable, but the
  /// room accepts no more messages.
  ended,
}

/// Honest transport state for the live room. The screen trusts this instead of
/// inferring presence from the last render.
enum V2CollabLiveConnection { connecting, connected, disconnected }

enum V2CollabMessageKind { person, agent }

/// A person shown in the transcript.
@immutable
class V2CollabParticipant {
  const V2CollabParticipant({
    required this.id,
    required this.name,
    this.initials,
  });

  final String id;
  final String name;
  final String? initials;
}

/// One message in the shared live transcript.
@immutable
class V2CollabMessage {
  const V2CollabMessage({
    required this.id,
    required this.speakerName,
    required this.timeLabel,
    required this.text,
    this.kind = V2CollabMessageKind.person,
    this.initials,
    this.isTurnHolder = false,
    this.agentStatus,
    this.toolName,
    this.toolResult,
    this.artifactName,
    this.artifactId,
    this.authorId,
    this.canReport = false,
    this.canRemove = false,
  });

  final String id;

  /// Sender name captured with the message. It is never looked up from the
  /// current roster, so a rename or removal cannot orphan old rows.
  final String speakerName;

  final String timeLabel;
  final String text;
  final V2CollabMessageKind kind;
  final String? initials;

  /// True when this person is the one currently sending.
  final bool isTurnHolder;

  /// Small status line for an agent message, for example "Testing endpoints".
  final String? agentStatus;

  final String? toolName;
  final String? toolResult;
  final String? artifactName;
  final String? artifactId;
  final String? authorId;
  final bool canReport;
  final bool canRemove;
}

/// Immutable state for [CollabLivePage].
@immutable
class V2CollabLivePageData {
  const V2CollabLivePageData({
    this.title = 'Team chat',
    this.subtitle,
    this.selfName = '',
    this.participants = const [],
    required this.totalMembers,
    this.typingName,
    required this.turnHolderName,
    required this.turnTimeLeftLabel,
    this.queueLabel,
    this.turnQueue = const [],
    this.messages = const [],
    required this.creatorPaysStorage,
    this.capacity = 50,
    this.isMyTurn = false,
    this.turnRequested = false,
    this.status = V2CollabLiveStatus.ready,
    this.errorMessage = 'We could not load this live chat.',
    this.endedMessage = 'This live chat has ended.',
    this.connection = V2CollabLiveConnection.connected,
    this.turnStartedAt,
    this.pendingAttachmentNames = const [],
    this.sending = false,
  }) : assert(totalMembers >= 0, 'totalMembers cannot be negative'),
       assert(capacity >= 0, 'capacity cannot be negative');

  final String title;

  /// Retained for hosts. The header always states the member count derived
  /// from [totalMembers] so presence cannot drift from the projection.
  final String? subtitle;

  /// Display name of the person using this device. Retained for hosts; the
  /// composer no longer repeats it as an avatar.
  final String selfName;

  final List<V2CollabParticipant> participants;
  final int totalMembers;

  /// Name of the person typing, or null when nobody is typing. Retained for
  /// hosts; the minimal transcript does not render presence.
  final String? typingName;

  final String turnHolderName;
  final String turnTimeLeftLabel;

  /// Human-readable queue position, for example "Queue position #3".
  final String? queueLabel;

  /// Names waiting for the turn, in order.
  final List<String> turnQueue;

  final List<V2CollabMessage> messages;
  final bool creatorPaysStorage;

  /// Hard cap on active members, including the creator.
  final int capacity;

  /// True only when fresh server state has no active full-run lease, so this
  /// device may admit a turn. Any active lease locks every sender.
  final bool isMyTurn;

  final bool turnRequested;
  final V2CollabLiveStatus status;
  final String errorMessage;

  /// Shown when the creator ended the session.
  final String endedMessage;

  /// Live transport state. `connecting` and `disconnected` both lock the
  /// composer, even when the last projection said it was this device's turn.
  final V2CollabLiveConnection connection;

  /// Server-stamped lease start, when one exists. It is not a deadline and
  /// never causes a local expiry or send unlock.
  final DateTime? turnStartedAt;

  /// Real files staged for the next server admission. No upload or acceptance
  /// is claimed until the corresponding `/turns` response succeeds.
  final List<String> pendingAttachmentNames;

  /// True while this device's send is in flight. Locks the composer without
  /// waiting for the next projection frame.
  final bool sending;
}

/// A shared live chat: one turn line, the transcript, the gated composer.
class CollabLivePage extends StatefulWidget {
  const CollabLivePage({
    super.key,
    required this.data,
    this.onOpenMembers,
    this.onRequestTurn,
    this.onRequestTurnAsync,
    this.onSend,
    this.onSendAsync,
    this.onAttach,
    this.onRemoveAttachment,
    this.onReportMessage,
    this.onRemoveMessage,
    this.onOpenArtifact,
    this.onRetry,
  });

  final V2CollabLivePageData data;
  final VoidCallback? onOpenMembers;

  /// Legacy synchronous turn request. Prefer [onRequestTurnAsync]; both are
  /// accepted so hosts can migrate without widening their own interface.
  final VoidCallback? onRequestTurn;

  /// The real turn request. A returned string is a refusal reason.
  final Future<String?> Function()? onRequestTurnAsync;

  /// Sends the typed draft. Only offered while fresh server state has no
  /// active lease and the socket is connected.
  final ValueChanged<String>? onSend;

  /// Async send path. When provided it wins over [onSend], keeps the draft on
  /// failure and shows the in-flight state while the future is pending.
  final Future<void> Function(String)? onSendAsync;

  final VoidCallback? onAttach;
  final ValueChanged<int>? onRemoveAttachment;
  final ValueChanged<V2CollabMessage>? onReportMessage;
  final ValueChanged<V2CollabMessage>? onRemoveMessage;

  final ValueChanged<String>? onOpenArtifact;
  final VoidCallback? onRetry;

  @override
  State<CollabLivePage> createState() => _CollabLivePageState();
}

class _CollabLivePageState extends State<CollabLivePage> {
  Timer? _announcementTimer;
  String _announcement = '';

  @override
  void didUpdateWidget(covariant CollabLivePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    _announceChanges(oldWidget.data, widget.data);
  }

  @override
  void dispose() {
    _announcementTimer?.cancel();
    super.dispose();
  }

  V2CollabLivePageData get _data => widget.data;

  bool get _hasHandler => widget.onSend != null || widget.onSendAsync != null;

  void _announceChanges(V2CollabLivePageData old, V2CollabLivePageData data) {
    if (old.status != data.status && data.status == V2CollabLiveStatus.ended) {
      _announce('Chat ended');
    }
    if (old.connection != data.connection) {
      _announce(switch (data.connection) {
        V2CollabLiveConnection.connecting => 'Connecting',
        V2CollabLiveConnection.connected => 'Connected',
        V2CollabLiveConnection.disconnected => 'Disconnected. Messages locked.',
      });
    }
    if (old.totalMembers != data.totalMembers) {
      final verb = data.totalMembers > old.totalMembers ? 'joined' : 'left';
      _announce('Member $verb. ${data.totalMembers} members.');
    }
  }

  void _announce(String message) {
    if (!mounted || message.isEmpty) return;
    _announcementTimer?.cancel();
    setState(() => _announcement = message);
    _announcementTimer = Timer(const Duration(seconds: 2), () {
      if (mounted) setState(() => _announcement = '');
    });
  }

  String? get _memberSubtitle {
    // A closed room has no live presence left to state.
    if (_data.status == V2CollabLiveStatus.ended) return null;
    final total = _data.totalMembers;
    if (total <= 0) return null;
    final capacity = _data.capacity;
    if (capacity > 0 && capacity != total) {
      return '$total of $capacity members';
    }
    return total == 1 ? '1 member' : '$total members';
  }

  V2CollabTurnBannerStatus get _bannerStatus {
    switch (_data.connection) {
      case V2CollabLiveConnection.connecting:
        return V2CollabTurnBannerStatus.connecting;
      case V2CollabLiveConnection.disconnected:
        return V2CollabTurnBannerStatus.disconnected;
      case V2CollabLiveConnection.connected:
        return _data.isMyTurn || _data.turnHolderName.trim().isNotEmpty
            ? V2CollabTurnBannerStatus.ready
            : V2CollabTurnBannerStatus.empty;
    }
  }

  V2CollabTurnBannerData get _bannerData {
    return V2CollabTurnBannerData(
      status: _bannerStatus,
      holderName: _data.turnHolderName,
      timeLeftLabel: _data.turnTimeLeftLabel,
      isMyTurn: _data.isMyTurn,
      turnRequested: _data.turnRequested,
      queue: [
        for (final name in _data.turnQueue)
          V2CollabTurnWaiter(
            name: name,
            isYou: _data.selfName.isNotEmpty && name == _data.selfName,
          ),
      ],
      queueLabel: _data.queueLabel,
    );
  }

  bool get _composerEnabled =>
      _data.connection == V2CollabLiveConnection.connected &&
      !_data.sending &&
      _data.isMyTurn;

  String? get _lockReason {
    if (_data.connection == V2CollabLiveConnection.connecting) {
      return 'Connecting';
    }
    if (_data.connection == V2CollabLiveConnection.disconnected) {
      return 'No connection';
    }
    if (_data.sending) return 'Sending';
    if (!_data.isMyTurn) return 'Wait for the turn';
    return null;
  }

  Widget _transcript(List<V2CollabMessage> messages, double gutter) {
    return ListView.builder(
      key: const ValueKey<String>('v2-collab-transcript'),
      padding: EdgeInsets.fromLTRB(gutter, OSpace.s, gutter, OSpace.l),
      itemCount: messages.length,
      itemBuilder: (context, index) {
        final message = messages[index];
        return Padding(
          key: ValueKey<String>('collab-message-${message.id}'),
          padding: const EdgeInsets.only(bottom: OSpace.l),
          child: _MessageTile(
            message: message,
            onReport: !message.canReport || widget.onReportMessage == null
                ? null
                : () => widget.onReportMessage!(message),
            onRemove: !message.canRemove || widget.onRemoveMessage == null
                ? null
                : () => widget.onRemoveMessage!(message),
            onOpenArtifact: widget.onOpenArtifact,
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return OScreen(
      title: _data.title,
      subtitle: _memberSubtitle,
      actions: [
        if (widget.onOpenMembers != null)
          OIconButton(
            icon: Icons.group_rounded,
            semanticLabel: 'Members',
            onPressed: widget.onOpenMembers,
          ),
      ],
      padding: false,
      child: switch (_data.status) {
        V2CollabLiveStatus.loading => _loading(context),
        V2CollabLiveStatus.error => _error(context),
        V2CollabLiveStatus.ended => _ended(context),
        V2CollabLiveStatus.empty || V2CollabLiveStatus.ready => _ready(context),
      },
    );
  }

  Widget _loading(BuildContext context) {
    return Column(
      children: [
        if (_data.connection != V2CollabLiveConnection.connected)
          _connectionBanner(context),
        const Expanded(child: OSkeletonList(rows: 5)),
        OLiveRegion(message: _announcement),
      ],
    );
  }

  Widget _error(BuildContext context) {
    return Column(
      children: [
        if (_data.connection != V2CollabLiveConnection.connected)
          _connectionBanner(context),
        Expanded(
          child: OErrorState(
            message: _data.errorMessage,
            onRetry: widget.onRetry,
          ),
        ),
        OLiveRegion(message: _announcement),
      ],
    );
  }

  Widget _ended(BuildContext context) {
    final messages = _data.messages;
    if (messages.isEmpty) {
      return Column(
        children: [
          Expanded(
            child: OEmptyState(
              icon: Icons.lock_outline_rounded,
              title: _endedTitle,
              message: _data.endedMessage,
            ),
          ),
          OLiveRegion(message: _announcement),
        ],
      );
    }
    final gutter = OResponsive.of(context).gutter;
    return Column(
      children: [
        Padding(
          padding: EdgeInsets.fromLTRB(gutter, OSpace.m, gutter, OSpace.s),
          child: _EndedNotice(title: _endedTitle, message: _data.endedMessage),
        ),
        // The room is closed, but what was said stays readable.
        Expanded(child: _transcript(messages, gutter)),
        OLiveRegion(message: _announcement),
      ],
    );
  }

  Widget _connectionBanner(BuildContext context) {
    final connecting = _data.connection == V2CollabLiveConnection.connecting;
    final gutter = OResponsive.of(context).gutter;
    return Padding(
      padding: EdgeInsets.fromLTRB(gutter, OSpace.m, gutter, OSpace.s),
      child: CollabTurnBanner(
        data: V2CollabTurnBannerData(
          status: connecting
              ? V2CollabTurnBannerStatus.connecting
              : V2CollabTurnBannerStatus.disconnected,
        ),
        onRetry: connecting ? null : widget.onRetry,
      ),
    );
  }

  Widget _ready(BuildContext context) {
    final gutter = OResponsive.of(context).gutter;
    final messages = _data.messages;
    return Column(
      children: [
        Padding(
          padding: EdgeInsets.fromLTRB(gutter, OSpace.m, gutter, OSpace.s),
          child: CollabTurnBanner(
            data: _bannerData,
            onRequestTurn: widget.onRequestTurn,
            onRequestTurnAsync: widget.onRequestTurnAsync,
            onViewQueue: widget.onOpenMembers,
            onRetry: widget.onRetry,
          ),
        ),
        Expanded(
          child: messages.isEmpty
              ? const OEmptyState(
                  icon: Icons.forum_outlined,
                  title: 'No messages yet',
                  message: 'Start the conversation.',
                )
              : _transcript(messages, gutter),
        ),
        if (_hasHandler)
          _ComposerDock(
            data: _data,
            enabled: _composerEnabled,
            lockReason: _lockReason,
            onSend: widget.onSend,
            onSendAsync: widget.onSendAsync,
            onAttach: widget.onAttach,
            onRemoveAttachment: widget.onRemoveAttachment,
            onAnnounce: _announce,
          ),
        OLiveRegion(message: _announcement),
      ],
    );
  }
}

class _MessageTile extends StatelessWidget {
  const _MessageTile({
    required this.message,
    this.onReport,
    this.onRemove,
    this.onOpenArtifact,
  });

  final V2CollabMessage message;
  final VoidCallback? onReport;
  final VoidCallback? onRemove;
  final ValueChanged<String>? onOpenArtifact;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    final agent = message.kind == V2CollabMessageKind.agent;
    final nameColor = agent ? c.accent : c.text;
    final rawName = message.speakerName.trim();
    final name = rawName.isEmpty ? (agent ? 'Ovid' : 'Member') : rawName;
    final time = message.timeLabel.trim();
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (agent)
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: c.accentSoft,
              shape: BoxShape.circle,
              border: Border.all(color: c.hairline),
            ),
            child: Icon(Icons.psychology_rounded, size: 19, color: c.accent),
          )
        else
          // Decorative: the sender name is the next node in reading order, so
          // labelling the avatar too would say the name twice.
          ExcludeSemantics(
            child: OAvatar(initials: message.initials ?? name, size: 36),
          ),
        const SizedBox(width: OSpace.s),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Flexible(
                    child: Text(
                      name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: OType.bodySm.copyWith(
                        color: nameColor,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  if (time.isNotEmpty) ...[
                    const SizedBox(width: OSpace.s),
                    Flexible(
                      child: Text(
                        time,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: OType.caption.copyWith(color: c.textFaint),
                      ),
                    ),
                  ],
                  if (onReport != null)
                    OIconButton(
                      icon: Icons.flag_outlined,
                      semanticLabel: 'Report message',
                      onPressed: onReport,
                    ),
                  if (onRemove != null)
                    OIconButton(
                      icon: Icons.delete_outline_rounded,
                      semanticLabel: 'Remove message',
                      onPressed: onRemove,
                    ),
                  if (message.isTurnHolder) ...[
                    const SizedBox(width: OSpace.s),
                    ExcludeSemantics(
                      child: Icon(
                        Icons.bolt_rounded,
                        size: 14,
                        color: c.accent,
                      ),
                    ),
                  ],
                ],
              ),
              const SizedBox(height: OSpace.xxs),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(OSpace.m),
                decoration: BoxDecoration(
                  color: agent ? c.surfaceRaised : c.surfaceAlt,
                  borderRadius: BorderRadius.circular(ORadius.m),
                  border: Border.all(color: c.hairline),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (agent && message.toolName != null) ...[
                      Row(
                        children: [
                          Icon(
                            Icons.check_circle_rounded,
                            size: 15,
                            color: c.success,
                          ),
                          const SizedBox(width: OSpace.s),
                          Expanded(
                            child: Text(
                              message.toolName!,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: OType.mono.copyWith(color: c.textMuted),
                            ),
                          ),
                          if (message.toolResult != null)
                            Flexible(
                              child: Text(
                                message.toolResult!,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: OType.caption.copyWith(
                                  color: c.success,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                        ],
                      ),
                      const SizedBox(height: OSpace.s),
                    ],
                    Text(
                      message.text,
                      style: OType.bodySm.copyWith(color: c.text),
                    ),
                    if (agent && message.artifactName != null) ...[
                      const SizedBox(height: OSpace.s),
                      _ArtifactRow(
                        name: message.artifactName!,
                        onOpen: message.artifactId == null ||
                                message.artifactId!.isEmpty ||
                                onOpenArtifact == null
                            ? null
                            : () => onOpenArtifact!(message.artifactId!),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// The artifact row inside an agent message. It only advertises "Open" when a
/// real handler exists.
class _ArtifactRow extends StatelessWidget {
  const _ArtifactRow({required this.name, this.onOpen});

  final String name;
  final VoidCallback? onOpen;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    final row = Container(
      constraints: const BoxConstraints(minHeight: OSpace.touch),
      padding: const EdgeInsets.symmetric(horizontal: OSpace.s),
      decoration: BoxDecoration(
        color: c.surfaceAlt,
        borderRadius: BorderRadius.circular(ORadius.s),
        border: Border.all(color: c.hairline),
      ),
      child: Row(
        children: [
          Icon(Icons.data_object_rounded, size: 15, color: c.textMuted),
          const SizedBox(width: OSpace.s),
          Expanded(
            child: Text(
              name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: OType.mono.copyWith(color: c.textMuted),
            ),
          ),
          if (onOpen != null)
            Icon(Icons.chevron_right_rounded, size: 18, color: c.accent),
        ],
      ),
    );
    if (onOpen == null) return row;
    return OPressable(onTap: onOpen, semanticLabel: 'Open $name', child: row);
  }
}

class _ComposerDock extends StatefulWidget {
  const _ComposerDock({
    required this.data,
    required this.enabled,
    required this.lockReason,
    this.onSend,
    this.onSendAsync,
    this.onAttach,
    this.onRemoveAttachment,
    this.onAnnounce,
  });

  final V2CollabLivePageData data;

  /// True only when the socket is connected, no send is in flight and this
  /// device holds the turn.
  final bool enabled;

  /// Why the composer is locked, when it is. Shown as the field hint and read
  /// by the composer's semantics group.
  final String? lockReason;

  final ValueChanged<String>? onSend;
  final Future<void> Function(String)? onSendAsync;
  final VoidCallback? onAttach;
  final ValueChanged<int>? onRemoveAttachment;
  final ValueChanged<String>? onAnnounce;

  @override
  State<_ComposerDock> createState() => _ComposerDockState();
}

class _ComposerDockState extends State<_ComposerDock> {
  final TextEditingController _controller = TextEditingController();
  bool _hasText = false;
  bool _sending = false;
  String? _sendError;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  bool get _busy => _sending || widget.data.sending;

  bool get _canSend => widget.enabled && !_busy && _hasText;

  String get _hint {
    if (_busy) return 'Sending';
    return widget.lockReason ?? 'Message';
  }

  String get _composerLabel {
    if (_busy) return 'Sending your message.';
    if (!widget.enabled) {
      return 'Composer locked. ${widget.lockReason ?? 'Wait for the turn'}.';
    }
    return 'Composer ready. Your turn.';
  }

  String get _sendLabel {
    if (_busy) return 'Sending';
    if (!widget.enabled) {
      final reason = widget.lockReason?.toLowerCase();
      return reason == null ? 'Send, locked' : 'Send, $reason';
    }
    return 'Send message';
  }

  void _handleChanged(String value) {
    final hasText = value.trim().isNotEmpty;
    if (hasText != _hasText) setState(() => _hasText = hasText);
  }

  void _send() {
    if (!_canSend) return;
    final text = _controller.text.trim();
    if (text.isEmpty) return;
    final async = widget.onSendAsync;
    if (async == null) {
      widget.onSend?.call(text);
      _clearDraft();
      return;
    }
    setState(() {
      _sending = true;
      _sendError = null;
    });
    unawaited(_finishSend(async(text)));
  }

  Future<void> _finishSend(Future<void> pending) async {
    try {
      await pending;
      if (!mounted) return;
      _clearDraft();
    } catch (error) {
      if (!mounted) return;
      final reason = error is String && error.trim().isNotEmpty
          ? error.trim()
          : 'Could not send. Try again.';
      setState(() => _sendError = reason);
      widget.onAnnounce?.call(reason);
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  void _clearDraft() {
    _controller.clear();
    setState(() {
      _hasText = false;
      _sendError = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    final gutter = OResponsive.of(context).gutter;
    return Container(
      padding: EdgeInsets.fromLTRB(gutter, OSpace.s, gutter, OSpace.l),
      decoration: BoxDecoration(
        color: c.bg,
        border: Border(top: BorderSide(color: c.hairline)),
      ),
      child: Semantics(
        container: true,
        explicitChildNodes: true,
        label: _composerLabel,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_sendError != null) ...[
              Semantics(
                container: true,
                liveRegion: true,
                label: _sendError!,
                child: ExcludeSemantics(
                  child: Text(
                    _sendError!,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: OType.caption.copyWith(color: c.danger),
                  ),
                ),
              ),
              const SizedBox(height: OSpace.s),
            ],
            if (widget.data.pendingAttachmentNames.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: OSpace.s),
                child: Wrap(
                  spacing: OSpace.xs,
                  runSpacing: OSpace.xs,
                  children: [
                    for (var index = 0;
                        index < widget.data.pendingAttachmentNames.length;
                        index++)
                      InputChip(
                        label: Text(widget.data.pendingAttachmentNames[index]),
                        onDeleted: _busy || widget.onRemoveAttachment == null
                            ? null
                            : () => widget.onRemoveAttachment!(index),
                      ),
                  ],
                ),
              ),
            Container(
              padding: const EdgeInsets.only(left: OSpace.m, right: OSpace.xxs),
              decoration: BoxDecoration(
                color: c.surfaceAlt,
                borderRadius: BorderRadius.circular(ORadius.m),
                border: Border.all(color: c.hairline),
              ),
              child: Row(
                children: [
                  if (widget.onAttach != null)
                    OIconButton(
                      icon: Icons.attach_file_rounded,
                      semanticLabel: 'Attach files',
                      onPressed: _busy || !widget.enabled ? null : widget.onAttach,
                    ),
                  Expanded(
                    child: TextField(
                      controller: _controller,
                      enabled: widget.enabled && !_busy,
                      minLines: 1,
                      maxLines: 4,
                      textInputAction: TextInputAction.send,
                      onChanged: _handleChanged,
                      onSubmitted: (_) => _canSend ? _send() : null,
                      style: OType.bodySm.copyWith(
                        color: widget.enabled && !_busy ? c.text : c.textFaint,
                      ),
                      decoration: InputDecoration(
                        isDense: true,
                        border: InputBorder.none,
                        hintText: _hint,
                        hintStyle: OType.bodySm.copyWith(
                          color: widget.enabled && !_busy
                              ? c.textMuted
                              : c.textFaint,
                        ),
                      ),
                    ),
                  ),
                  if (_busy)
                    const _SendingIndicator()
                  else
                    OIconButton(
                      icon: Icons.send_rounded,
                      semanticLabel: _sendLabel,
                      onPressed: _canSend ? _send : null,
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SendingIndicator extends StatelessWidget {
  const _SendingIndicator();

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    return Semantics(
      label: 'Sending',
      child: ExcludeSemantics(
        child: SizedBox(
          width: OSpace.touch,
          height: OSpace.touch,
          child: Center(
            child: SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: c.textMuted,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The room is closed. What was said stays readable; nothing may be sent.
class _EndedNotice extends StatelessWidget {
  const _EndedNotice({required this.title, required this.message});

  final String title;
  final String message;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    return Container(
      key: const ValueKey('v2-collab-ended-notice'),
      width: double.infinity,
      padding: const EdgeInsets.symmetric(
        horizontal: OSpace.m,
        vertical: OSpace.s,
      ),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(ORadius.m),
        border: Border.all(color: c.hairline),
      ),
      // Not a live region: the page's single [OLiveRegion] already announces
      // "Chat ended" on the transition, so this node only has to read well
      // when the room is opened after it closed.
      child: Semantics(
        container: true,
        label: '$title. $message',
        child: ExcludeSemantics(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: OType.label.copyWith(color: c.text)),
              const SizedBox(height: OSpace.xxs),
              Text(message, style: OType.caption.copyWith(color: c.textMuted)),
            ],
          ),
        ),
      ),
    );
  }
}
