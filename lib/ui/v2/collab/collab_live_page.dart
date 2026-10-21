import 'package:flutter/material.dart';

import '../../design/o_components.dart';
import '../../design/o_motion.dart';
import '../../design/o_tokens.dart';

// TODO(l10n): extract this screen's English copy during the ARB pass.

enum V2CollabLiveStatus { loading, empty, error, ready }

enum V2CollabMessageKind { person, agent }

/// A person shown in the avatar cluster.
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
    this.messages = const [],
    required this.creatorPaysStorage,
    this.turnRequested = false,
    this.status = V2CollabLiveStatus.ready,
    this.errorMessage = 'We could not load this live chat.',
  });

  final String title;
  final String? subtitle;

  /// Display name of the person using this device, shown in the composer.
  final String selfName;

  final List<V2CollabParticipant> participants;
  final int totalMembers;

  /// Name of the person typing, or null when nobody is typing.
  final String? typingName;

  final String turnHolderName;
  final String turnTimeLeftLabel;
  final String? queueLabel;
  final List<V2CollabMessage> messages;
  final bool creatorPaysStorage;
  final bool turnRequested;
  final V2CollabLiveStatus status;
  final String errorMessage;
}

/// A shared live chat with turn-based sending.
class CollabLivePage extends StatelessWidget {
  const CollabLivePage({
    super.key,
    required this.data,
    this.onOpenMembers,
    this.onRequestTurn,
    this.onOpenArtifact,
    this.onRetry,
  });

  final V2CollabLivePageData data;
  final VoidCallback? onOpenMembers;
  final VoidCallback? onRequestTurn;
  final ValueChanged<String>? onOpenArtifact;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    return OScaffold(
      appBar: OAppBar(title: data.title, subtitle: data.subtitle),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
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
        ),
      ),
    );
  }

  Widget _empty(BuildContext context) {
    return OEmptyState(
      icon: Icons.forum_outlined,
      title: 'No messages yet',
      message:
          'When someone sends a message it shows here. Only one person can send at a time.',
      action: OButton(
        label: 'Request turn',
        icon: Icons.pan_tool_alt_rounded,
        onPressed: onRequestTurn,
      ),
    );
  }

  Widget _ready(BuildContext context) {
    final c = OColors.of(context);
    final transcript = ListView(
      padding: const EdgeInsets.fromLTRB(
        OSpace.l,
        OSpace.m,
        OSpace.l,
        OSpace.l,
      ),
      children: [
        OFadeSlide(
          child: OStagger(
            children: [
              _SessionCard(data: data, onOpenMembers: onOpenMembers),
              if (data.typingName != null) ...[
                const SizedBox(height: OSpace.m),
                _TypingBanner(name: data.typingName!),
              ],
              const SizedBox(height: OSpace.l),
              _PinnedRule(c: c),
              const SizedBox(height: OSpace.l),
              for (final message in data.messages) ...[
                _MessageTile(message: message, onOpenArtifact: onOpenArtifact),
                const SizedBox(height: OSpace.l),
              ],
              Center(
                child: _StoragePill(
                  totalMembers: data.totalMembers,
                  creatorPaysStorage: data.creatorPaysStorage,
                ),
              ),
            ],
          ),
        ),
      ],
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        return Column(
          children: [
            Expanded(child: transcript),
            // At large text sizes the dock can grow past the viewport. Cap it
            // and let it scroll instead of overflowing the page.
            ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: constraints.maxHeight * 0.6,
              ),
              child: SingleChildScrollView(
                child: _ComposerDock(data: data, onRequestTurn: onRequestTurn),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _SessionCard extends StatelessWidget {
  const _SessionCard({required this.data, this.onOpenMembers});

  final V2CollabLivePageData data;
  final VoidCallback? onOpenMembers;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    final heading = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                color: c.success,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: OSpace.s),
            Flexible(
              child: Text(
                'Live now',
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
        const SizedBox(height: OSpace.xs),
        Text(
          'Turn floor: ${data.turnHolderName}',
          style: OType.bodySm.copyWith(
            color: c.text,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
    final members = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _AvatarCluster(
          people: data.participants,
          total: data.totalMembers,
          onTap: onOpenMembers,
        ),
        OIconButton(
          icon: Icons.group_rounded,
          semanticLabel: 'View members',
          onPressed: onOpenMembers,
        ),
      ],
    );

    return OCard(
      child: LayoutBuilder(
        builder: (context, constraints) {
          // Four avatars plus the member button leave too little room for the
          // heading on small phones and at large text sizes.
          final tight =
              constraints.maxWidth < 270 ||
              MediaQuery.textScalerOf(context).scale(12) > 16;
          if (tight) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                heading,
                const SizedBox(height: OSpace.s),
                Align(alignment: Alignment.centerLeft, child: members),
              ],
            );
          }
          return Row(
            children: [
              Expanded(child: heading),
              const SizedBox(width: OSpace.s),
              members,
            ],
          );
        },
      ),
    );
  }
}

class _AvatarCluster extends StatelessWidget {
  const _AvatarCluster({required this.people, required this.total, this.onTap});

  final List<V2CollabParticipant> people;
  final int total;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    final shown = people.take(4).toList();
    final extra = total - shown.length;
    final width = 24.0 * shown.length + 34;
    return OPressable(
      onTap: onTap,
      semanticLabel: 'Open the member list, $total members',
      child: SizedBox(
        width: width,
        height: OSpace.touch,
        child: Center(
          child: SizedBox(
            width: width,
            height: 34,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                for (var i = 0; i < shown.length; i++)
                  Positioned(
                    left: i * 24.0,
                    top: 0,
                    child: OAvatar(
                      initials: shown[i].initials ?? shown[i].name,
                      size: 34,
                      semanticLabel: shown[i].name,
                    ),
                  ),
                if (extra > 0)
                  Positioned(
                    left: shown.length * 24.0,
                    top: 0,
                    child: Container(
                      width: 34,
                      height: 34,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: c.accentSoft,
                        shape: BoxShape.circle,
                        border: Border.all(color: c.surface),
                      ),
                      child: Text(
                        '+$extra',
                        style: OType.caption.copyWith(
                          color: c.accent,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _TypingBanner extends StatelessWidget {
  const _TypingBanner({required this.name});

  final String name;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: OSpace.m,
        vertical: OSpace.s,
      ),
      decoration: BoxDecoration(
        color: c.surfaceAlt,
        borderRadius: BorderRadius.circular(ORadius.m),
      ),
      child: Row(
        children: [
          OPulse(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (var i = 0; i < 3; i++) ...[
                  Container(
                    width: 5,
                    height: 5,
                    decoration: BoxDecoration(
                      color: c.accent,
                      shape: BoxShape.circle,
                    ),
                  ),
                  if (i < 2) const SizedBox(width: OSpace.xs),
                ],
              ],
            ),
          ),
          const SizedBox(width: OSpace.s),
          Expanded(
            child: Text(
              '$name is typing…',
              style: OType.bodySm.copyWith(color: c.textMuted),
            ),
          ),
          const OPill(label: 'Live', tone: OPillTone.success, dot: true),
        ],
      ),
    );
  }
}

class _PinnedRule extends StatelessWidget {
  const _PinnedRule({required this.c});

  final OColors c;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: OSpace.m,
          vertical: OSpace.s,
        ),
        decoration: BoxDecoration(
          color: c.surfaceRaised,
          borderRadius: BorderRadius.circular(ORadius.pill),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.lock_clock_rounded, size: 16, color: c.accent),
            const SizedBox(width: OSpace.xs),
            Flexible(
              child: Text(
                'Only one person can send at a time',
                textAlign: TextAlign.center,
                style: OType.caption.copyWith(color: c.textMuted),
              ),
            ),
          ],
        ),
      ),
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
    if (message.kind == V2CollabMessageKind.agent) {
      return _AgentMessage(message: message, onOpenArtifact: onOpenArtifact);
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        OAvatar(
          initials: message.initials ?? message.speakerName,
          size: 40,
          semanticLabel: message.speakerName,
        ),
        const SizedBox(width: OSpace.s),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Wrap(
                spacing: OSpace.s,
                runSpacing: OSpace.xs,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Text(
                    message.speakerName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: OType.bodySm.copyWith(
                      color: c.text,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  Text(
                    message.timeLabel,
                    style: OType.caption.copyWith(color: c.textFaint),
                  ),
                  if (message.isTurnHolder)
                    const OPill(label: 'Sending now', tone: OPillTone.accent),
                ],
              ),
              const SizedBox(height: OSpace.xs),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(OSpace.m),
                decoration: BoxDecoration(
                  color: c.surfaceAlt,
                  borderRadius: const BorderRadius.only(
                    topLeft: Radius.circular(4),
                    topRight: Radius.circular(ORadius.l),
                    bottomLeft: Radius.circular(ORadius.l),
                    bottomRight: Radius.circular(ORadius.l),
                  ),
                  border: Border.all(color: c.hairline),
                ),
                child: Text(
                  message.text,
                  style: OType.bodySm.copyWith(color: c.text),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _AgentMessage extends StatelessWidget {
  const _AgentMessage({required this.message, this.onOpenArtifact});

  final V2CollabMessage message;
  final ValueChanged<String>? onOpenArtifact;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: c.accentSoft,
            shape: BoxShape.circle,
            border: Border.all(color: c.hairline),
          ),
          child: Icon(Icons.psychology_rounded, size: 20, color: c.accent),
        ),
        const SizedBox(width: OSpace.s),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Wrap(
                spacing: OSpace.s,
                runSpacing: OSpace.xs,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Text(
                    message.speakerName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: OType.bodySm.copyWith(
                      color: c.accent,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  if (message.agentStatus != null)
                    Text(
                      message.agentStatus!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: OType.caption.copyWith(color: c.textMuted),
                    ),
                  Text(
                    message.timeLabel,
                    style: OType.caption.copyWith(color: c.textFaint),
                  ),
                ],
              ),
              const SizedBox(height: OSpace.xs),
              Container(
                padding: const EdgeInsets.all(OSpace.m),
                decoration: BoxDecoration(
                  color: c.surfaceRaised,
                  borderRadius: BorderRadius.circular(ORadius.l),
                  border: Border.all(color: c.hairline),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (message.toolName != null) ...[
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: OSpace.s,
                          vertical: OSpace.s,
                        ),
                        decoration: BoxDecoration(
                          color: c.codeBg,
                          borderRadius: BorderRadius.circular(ORadius.s),
                        ),
                        child: Row(
                          children: [
                            Icon(
                              Icons.check_circle_rounded,
                              size: 16,
                              color: c.success,
                            ),
                            const SizedBox(width: OSpace.s),
                            Expanded(
                              child: Text(
                                message.toolName!,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: OType.mono.copyWith(color: c.text),
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
                      ),
                      const SizedBox(height: OSpace.s),
                    ],
                    Text(
                      message.text,
                      style: OType.bodySm.copyWith(color: c.text),
                    ),
                    if (message.artifactName != null) ...[
                      const SizedBox(height: OSpace.s),
                      OPressable(
                        onTap: onOpenArtifact == null
                            ? null
                            : () => onOpenArtifact!(message.artifactName!),
                        semanticLabel: 'Open ${message.artifactName}',
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(
                            minHeight: OSpace.touch,
                          ),
                          child: Container(
                            padding: const EdgeInsets.all(OSpace.s),
                            decoration: BoxDecoration(
                              color: c.surfaceAlt,
                              borderRadius: BorderRadius.circular(ORadius.s),
                              border: Border.all(color: c.hairline),
                            ),
                            child: Row(
                              children: [
                                Icon(
                                  Icons.data_object_rounded,
                                  size: 16,
                                  color: c.textMuted,
                                ),
                                const SizedBox(width: OSpace.s),
                                Expanded(
                                  child: Text(
                                    message.artifactName!,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: OType.mono.copyWith(
                                      color: c.textMuted,
                                    ),
                                  ),
                                ),
                                Text(
                                  'Open',
                                  style: OType.caption.copyWith(
                                    color: c.accent,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                Icon(
                                  Icons.arrow_forward_rounded,
                                  size: 14,
                                  color: c.accent,
                                ),
                              ],
                            ),
                          ),
                        ),
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

class _StoragePill extends StatelessWidget {
  const _StoragePill({
    required this.totalMembers,
    required this.creatorPaysStorage,
  });

  final int totalMembers;
  final bool creatorPaysStorage;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    final storage = creatorPaysStorage
        ? 'Creator pays storage'
        : 'Storage is shared';
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: OSpace.m,
        vertical: OSpace.s,
      ),
      decoration: BoxDecoration(
        color: c.surfaceAlt,
        borderRadius: BorderRadius.circular(ORadius.pill),
        border: Border.all(color: c.hairline),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.group_work_rounded, size: 16, color: c.textMuted),
          const SizedBox(width: OSpace.xs),
          Flexible(
            child: Text(
              '$totalMembers members · $storage',
              textAlign: TextAlign.center,
              style: OType.caption.copyWith(color: c.textMuted),
            ),
          ),
        ],
      ),
    );
  }
}

class _ComposerDock extends StatelessWidget {
  const _ComposerDock({required this.data, this.onRequestTurn});

  final V2CollabLivePageData data;
  final VoidCallback? onRequestTurn;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    return Container(
      padding: const EdgeInsets.fromLTRB(
        OSpace.l,
        OSpace.m,
        OSpace.l,
        OSpace.l,
      ),
      decoration: BoxDecoration(
        color: c.surface,
        border: Border(top: BorderSide(color: c.hairline)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: OSpace.s,
            runSpacing: OSpace.s,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.hourglass_bottom_rounded, size: 18, color: c.warn),
                  const SizedBox(width: OSpace.s),
                  Flexible(
                    child: Text(
                      '${data.turnHolderName} is sending… '
                      '(${data.turnTimeLeftLabel})',
                      style: OType.caption.copyWith(color: c.textMuted),
                    ),
                  ),
                ],
              ),
              OButton(
                label: data.turnRequested ? 'Turn requested' : 'Request turn',
                icon: data.turnRequested
                    ? Icons.check_rounded
                    : Icons.pan_tool_alt_rounded,
                variant: data.turnRequested
                    ? OButtonVariant.secondary
                    : OButtonVariant.primary,
                onPressed: onRequestTurn,
              ),
            ],
          ),
          const SizedBox(height: OSpace.s),
          Container(
            padding: const EdgeInsets.all(OSpace.xs),
            decoration: BoxDecoration(
              color: c.surfaceAlt,
              borderRadius: BorderRadius.circular(ORadius.m),
              border: Border.all(color: c.hairline),
            ),
            child: Row(
              children: [
                OAvatar(
                  initials: data.selfName.isEmpty ? 'You' : data.selfName,
                  size: 36,
                  semanticLabel: 'You',
                ),
                const SizedBox(width: OSpace.s),
                Expanded(
                  child: Text(
                    'Wait for the turn',
                    style: OType.bodySm.copyWith(color: c.textFaint),
                  ),
                ),
                OIconButton(
                  icon: Icons.send_rounded,
                  semanticLabel: 'Send, wait for the turn',
                  onPressed: null,
                ),
              ],
            ),
          ),
          if (data.queueLabel != null) ...[
            const SizedBox(height: OSpace.s),
            Text(
              data.queueLabel!,
              style: OType.caption.copyWith(color: c.textFaint),
            ),
          ],
        ],
      ),
    );
  }
}
