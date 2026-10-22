import 'package:flutter/material.dart';

import '../../design/o_components.dart';
import '../../design/o_motion.dart';
import '../../design/o_screen.dart';
import '../../design/o_tokens.dart';
import 'turn_banner.dart';

// TODO(l10n): extract this screen's English copy during the ARB pass.

enum V2CollabLiveStatus { loading, empty, error, ready }

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
  });

  final String id;
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
  });

  final String title;
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

  /// True when this device holds the turn, so sending is allowed. While
  /// another member's output runs every other send stays disabled.
  final bool isMyTurn;

  final bool turnRequested;
  final V2CollabLiveStatus status;
  final String errorMessage;
}

/// A shared live chat: one status line, the transcript, the composer.
class CollabLivePage extends StatelessWidget {
  const CollabLivePage({
    super.key,
    required this.data,
    this.onOpenMembers,
    this.onRequestTurn,
    this.onSend,
    this.onOpenArtifact,
    this.onRetry,
  });

  final V2CollabLivePageData data;
  final VoidCallback? onOpenMembers;
  final VoidCallback? onRequestTurn;

  /// Sends the typed draft. Only offered while
  /// [V2CollabLivePageData.isMyTurn].
  final ValueChanged<String>? onSend;
  final ValueChanged<String>? onOpenArtifact;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    return OScreen(
      title: data.title,
      actions: [
        if (onOpenMembers != null)
          OIconButton(
            icon: Icons.group_rounded,
            semanticLabel: 'Members',
            onPressed: onOpenMembers,
          ),
      ],
      padding: false,
      child: switch (data.status) {
        V2CollabLiveStatus.loading => const OSkeletonList(rows: 5),
        V2CollabLiveStatus.error => OErrorState(
          message: data.errorMessage,
          onRetry: onRetry,
        ),
        V2CollabLiveStatus.empty => _empty(context),
        V2CollabLiveStatus.ready =>
          data.messages.isEmpty ? _empty(context) : _ready(context),
      },
    );
  }

  Widget _empty(BuildContext context) {
    return OEmptyState(
      icon: Icons.forum_outlined,
      title: 'No messages yet',
      message: 'Messages appear here.',
      action: onRequestTurn == null
          ? null
          : OButton(
              label: 'Request turn',
              icon: Icons.pan_tool_alt_rounded,
              onPressed: onRequestTurn,
            ),
    );
  }

  /// Maps the page's turn fields onto the shared one-line banner.
  V2CollabTurnBannerData get _turnBannerData => V2CollabTurnBannerData(
    holderName: data.turnHolderName,
    timeLeftLabel: data.turnTimeLeftLabel,
    isMyTurn: data.isMyTurn,
    turnRequested: data.turnRequested,
    queue: [
      for (final name in data.turnQueue)
        V2CollabTurnWaiter(
          name: name,
          isYou: data.selfName.isNotEmpty && name == data.selfName,
        ),
    ],
    queueLabel: data.queueLabel,
  );

  Widget _ready(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            OSpace.l,
            OSpace.m,
            OSpace.l,
            OSpace.s,
          ),
          child: CollabTurnBanner(
            data: _turnBannerData,
            onRequestTurn: onRequestTurn,
          ),
        ),
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.fromLTRB(
              OSpace.l,
              OSpace.s,
              OSpace.l,
              OSpace.l,
            ),
            itemCount: data.messages.length,
            itemBuilder: (context, index) {
              final message = data.messages[index];
              return Padding(
                padding: const EdgeInsets.only(bottom: OSpace.l),
                child: _MessageTile(
                  message: message,
                  onOpenArtifact: onOpenArtifact,
                ),
              );
            },
          ),
        ),
        _ComposerDock(data: data, onSend: onSend),
      ],
    );
  }
}

class _MessageTile extends StatelessWidget {
  const _MessageTile({required this.message, this.onOpenArtifact});

  final V2CollabMessage message;
  final ValueChanged<String>? onOpenArtifact;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    final agent = message.kind == V2CollabMessageKind.agent;
    final nameColor = agent ? c.accent : c.text;
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
          OAvatar(
            initials: message.initials ?? message.speakerName,
            size: 36,
            semanticLabel: message.speakerName,
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
                      message.speakerName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: OType.bodySm.copyWith(
                        color: nameColor,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  const SizedBox(width: OSpace.s),
                  Text(
                    message.timeLabel,
                    style: OType.caption.copyWith(color: c.textFaint),
                  ),
                  if (message.isTurnHolder) ...[
                    const SizedBox(width: OSpace.s),
                    Icon(
                      Icons.bolt_rounded,
                      size: 14,
                      color: c.accent,
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
                            Text(
                              message.toolResult!,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: OType.caption.copyWith(
                                color: c.success,
                                fontWeight: FontWeight.w600,
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
                        onOpen: onOpenArtifact == null
                            ? null
                            : () => onOpenArtifact!(message.artifactName!),
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
    return OPressable(
      onTap: onOpen,
      semanticLabel: 'Open $name',
      child: row,
    );
  }
}

class _ComposerDock extends StatefulWidget {
  const _ComposerDock({required this.data, this.onSend});

  final V2CollabLivePageData data;
  final ValueChanged<String>? onSend;

  @override
  State<_ComposerDock> createState() => _ComposerDockState();
}

class _ComposerDockState extends State<_ComposerDock> {
  final TextEditingController _controller = TextEditingController();
  bool _hasText = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  bool get _canSend =>
      widget.data.isMyTurn && widget.onSend != null && _hasText;

  void _send() {
    final text = _controller.text.trim();
    if (text.isEmpty || !widget.data.isMyTurn) return;
    widget.onSend?.call(text);
    _controller.clear();
    setState(() => _hasText = false);
  }

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    return Container(
      padding: const EdgeInsets.fromLTRB(
        OSpace.l,
        OSpace.s,
        OSpace.l,
        OSpace.l,
      ),
      decoration: BoxDecoration(
        color: c.bg,
        border: Border(top: BorderSide(color: c.hairline)),
      ),
      child: Container(
        padding: const EdgeInsets.only(left: OSpace.m, right: OSpace.xxs),
        decoration: BoxDecoration(
          color: c.surfaceAlt,
          borderRadius: BorderRadius.circular(ORadius.m),
          border: Border.all(color: c.hairline),
        ),
        child: Row(
          children: [
            Expanded(
              child: TextField(
                controller: _controller,
                enabled: widget.data.isMyTurn,
                minLines: 1,
                maxLines: 4,
                textInputAction: TextInputAction.send,
                onChanged: (value) {
                  final hasText = value.trim().isNotEmpty;
                  if (hasText != _hasText) setState(() => _hasText = hasText);
                },
                onSubmitted: (_) => _canSend ? _send() : null,
                style: OType.bodySm.copyWith(
                  color: widget.data.isMyTurn ? c.text : c.textFaint,
                ),
                decoration: InputDecoration(
                  isDense: true,
                  border: InputBorder.none,
                  hintText: widget.data.isMyTurn
                      ? 'Message'
                      : 'Wait for the turn',
                  hintStyle: OType.bodySm.copyWith(
                    color: widget.data.isMyTurn ? c.textMuted : c.textFaint,
                  ),
                ),
              ),
            ),
            OIconButton(
              icon: Icons.send_rounded,
              semanticLabel: widget.data.isMyTurn
                  ? 'Send message'
                  : 'Send, wait for the turn',
              onPressed: _canSend ? _send : null,
            ),
          ],
        ),
      ),
    );
  }
}
