import 'package:flutter/material.dart';

import '../../design/o_components.dart';
import '../../design/o_motion.dart';
import '../../design/o_tokens.dart';

// TODO(l10n): extract this banner's English copy during the ARB pass.

enum V2CollabTurnBannerStatus { loading, empty, error, ready }

/// One person waiting for the turn in a shared live chat.
@immutable
class V2CollabTurnWaiter {
  const V2CollabTurnWaiter({
    required this.name,
    this.initials,
    this.isYou = false,
    this.waitLabel,
  });

  final String name;
  final String? initials;

  /// True for the person using this device, highlighted in the queue.
  final bool isYou;

  /// Optional short estimate, for example "about 40s".
  final String? waitLabel;
}

/// Immutable state for [CollabTurnBanner].
///
/// [queue] holds the people waiting, in order; the person at index 0 sends
/// next. [holderName] and [timeLeftLabel] describe the current turn.
@immutable
class V2CollabTurnBannerData {
  const V2CollabTurnBannerData({
    this.status = V2CollabTurnBannerStatus.ready,
    this.holderName = '',
    this.timeLeftLabel = '',
    this.timeLeftFraction,
    this.isMyTurn = false,
    this.turnRequested = false,
    this.queue = const [],
    this.queueLabel,
    this.maxVisibleQueue = 4,
    this.errorMessage = 'We could not load the turn.',
  }) : assert(
         timeLeftFraction == null ||
             (timeLeftFraction >= 0 && timeLeftFraction <= 1),
         'timeLeftFraction is a 0–1 share of the turn',
       ),
       assert(maxVisibleQueue > 0, 'Show at least one waiter');

  final V2CollabTurnBannerStatus status;

  /// Display name of the person currently sending, empty when the turn is
  /// free.
  final String holderName;

  /// Human label for the remaining time, for example "24s left in turn".
  final String timeLeftLabel;

  /// Share of the turn still left, used by the progress bar. Null hides it.
  final double? timeLeftFraction;

  /// True when this device holds the turn.
  final bool isMyTurn;

  /// True after this device asked for the turn and is waiting.
  final bool turnRequested;

  /// People waiting for the turn, in order. The current holder is not
  /// included.
  final List<V2CollabTurnWaiter> queue;

  /// Optional wiring label such as "About 1m 12s until your turn".
  final String? queueLabel;

  /// Queue rows rendered before collapsing into a "+N more" row.
  final int maxVisibleQueue;

  final String errorMessage;

  bool get hasTurn => holderName.trim().isNotEmpty;

  int get waitingCount => queue.length;

  /// The rows the banner actually renders.
  List<V2CollabTurnWaiter> get visibleQueue =>
      queue.take(maxVisibleQueue).toList(growable: false);

  /// Waiters hidden behind the "+N more" row.
  int get hiddenQueueCount {
    final hidden = queue.length - visibleQueue.length;
    return hidden < 0 ? 0 : hidden;
  }

  /// 1-based place in line for this device, or null when not waiting.
  int? get myPosition {
    final index = queue.indexWhere((waiter) => waiter.isYou);
    return index < 0 ? null : index + 1;
  }

  String? get myPositionLabel {
    final position = myPosition;
    if (position == null) return queueLabel;
    if (position == 1) return 'You are next in line.';
    return 'You are #$position in line.';
  }
}

/// Shows whose turn it is, the time left, the people waiting, the request-turn
/// control and the one-message-at-a-time rule.
///
/// Presentational only: the live adapter passes [V2CollabTurnBannerData] and
/// owns the callbacks.
class CollabTurnBanner extends StatelessWidget {
  const CollabTurnBanner({
    super.key,
    required this.data,
    this.onRequestTurn,
    this.onViewQueue,
    this.onRetry,
  });

  final V2CollabTurnBannerData data;
  final VoidCallback? onRequestTurn;

  /// Opens the full member/queue list. Only offered when the queue is longer
  /// than the visible rows.
  final VoidCallback? onViewQueue;

  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    return OFadeSlide(
      child: OCard(
        accent: data.status == V2CollabTurnBannerStatus.ready && data.isMyTurn,
        padding: const EdgeInsets.all(OSpace.l),
        child: switch (data.status) {
          V2CollabTurnBannerStatus.loading => _loading(context),
          V2CollabTurnBannerStatus.error => _error(context),
          V2CollabTurnBannerStatus.empty => _freeTurn(context),
          V2CollabTurnBannerStatus.ready =>
            data.hasTurn ? _ready(context) : _freeTurn(context),
        },
      ),
    );
  }

  Widget _loading(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: const [
        Row(
          children: [
            OSkeleton(width: 36, height: 36, radius: ORadius.m),
            SizedBox(width: OSpace.m),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  OSkeleton(width: 76, height: 11),
                  SizedBox(height: OSpace.s),
                  OSkeleton(width: 132, height: 16),
                ],
              ),
            ),
          ],
        ),
        SizedBox(height: OSpace.l),
        OSkeleton(width: double.infinity, height: 6, radius: ORadius.pill),
        SizedBox(height: OSpace.l),
        OSkeleton(width: 96, height: 11),
        SizedBox(height: OSpace.s),
        OSkeleton(width: double.infinity, height: 32, radius: ORadius.s),
      ],
    );
  }

  Widget _error(BuildContext context) {
    final c = OColors.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.error_outline_rounded, size: 20, color: c.danger),
            const SizedBox(width: OSpace.s),
            Expanded(
              child: Text(
                data.errorMessage,
                style: OType.bodySm.copyWith(color: c.text),
              ),
            ),
          ],
        ),
        const SizedBox(height: OSpace.m),
        OButton(
          label: 'Try again',
          icon: Icons.refresh_rounded,
          variant: OButtonVariant.secondary,
          onPressed: onRetry,
        ),
      ],
    );
  }

  Widget _freeTurn(BuildContext context) {
    final c = OColors.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _TurnGlyph(active: data.isMyTurn),
            const SizedBox(width: OSpace.m),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    data.isMyTurn ? 'Your turn' : 'Turn is free',
                    style: OType.overline.copyWith(color: c.textMuted),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    data.isMyTurn
                        ? (data.queue.isEmpty
                              ? 'Nobody is waiting after you.'
                              : '${data.waitingCount} '
                                    '${data.waitingCount == 1 ? 'person is' : 'people are'} '
                                    'waiting next.')
                        : 'Nobody is sending right now.',
                    style: OType.bodySm.copyWith(
                      color: c.text,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: OSpace.m),
        Text(
          data.isMyTurn
              ? 'Send one message. The turn then moves to the next person.'
              : 'Take the turn to send the next message. One person sends at a time.',
          style: OType.caption.copyWith(color: c.textMuted),
        ),
        const SizedBox(height: OSpace.m),
        OButton(
          label: data.isMyTurn ? 'You have the turn' : 'Take the turn',
          icon: data.isMyTurn
              ? Icons.check_rounded
              : Icons.pan_tool_alt_rounded,
          variant: data.isMyTurn
              ? OButtonVariant.secondary
              : OButtonVariant.primary,
          onPressed: data.isMyTurn ? null : onRequestTurn,
          semanticLabel: data.isMyTurn
              ? 'Your turn. Send your message.'
              : 'Take the turn to send the next message',
          expand: true,
        ),
        if (data.queue.isNotEmpty) ...[
          const SizedBox(height: OSpace.m),
          Divider(color: c.hairline, height: 1),
          const SizedBox(height: OSpace.m),
          _queue(context),
        ],
        const SizedBox(height: OSpace.m),
        const _OneAtATimeNote(),
      ],
    );
  }

  Widget _ready(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        _header(context),
        if (data.timeLeftFraction != null) ...[
          const SizedBox(height: OSpace.m),
          Semantics(
            label: data.timeLeftLabel,
            excludeSemantics: true,
            child: OProgressBar(value: data.timeLeftFraction!),
          ),
        ],
        const SizedBox(height: OSpace.m),
        _requestControl(context),
        const SizedBox(height: OSpace.m),
        Divider(color: OColors.of(context).hairline, height: 1),
        const SizedBox(height: OSpace.m),
        _queue(context),
        const SizedBox(height: OSpace.m),
        const _OneAtATimeNote(),
      ],
    );
  }

  Widget _header(BuildContext context) {
    final c = OColors.of(context);
    // The countdown changes every second, so only the holder is a stable
    // announcement. Marking the whole header as a live region would make a
    // screen reader repeat the banner on every tick.
    final identity = Semantics(
      container: true,
      label: data.isMyTurn
          ? 'Your turn, ${data.holderName}'
          : '${data.holderName} has the turn',
      excludeSemantics: true,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _TurnGlyph(active: data.isMyTurn),
          const SizedBox(width: OSpace.m),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  data.isMyTurn ? 'Your turn' : 'Current turn',
                  style: OType.overline.copyWith(
                    color: data.isMyTurn ? c.accent : c.textMuted,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  data.isMyTurn ? '${data.holderName} (you)' : data.holderName,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: OType.h3.copyWith(color: c.text),
                ),
              ],
            ),
          ),
        ],
      ),
    );

    final time = _TimeLeftPill(
      label: data.timeLeftLabel,
      urgent: data.timeLeftFraction != null && data.timeLeftFraction! <= 0.2,
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        // The countdown cannot sit beside the name on a 320 dp phone at
        // 200 % text without squeezing the name to nothing.
        final stacked =
            constraints.maxWidth < 280 ||
            MediaQuery.textScalerOf(context).scale(1) > 1.3;
        if (stacked) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              identity,
              const SizedBox(height: OSpace.s),
              time,
            ],
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(child: identity),
            const SizedBox(width: OSpace.s),
            time,
          ],
        );
      },
    );
  }

  Widget _requestControl(BuildContext context) {
    final c = OColors.of(context);
    final held = data.isMyTurn;
    final waiting = !held && data.turnRequested;
    final label = held
        ? 'You have the turn'
        : waiting
        ? 'In queue'
        : 'Request turn';
    final semanticLabel = held
        ? 'Your turn. Send your message.'
        : waiting
        ? 'In queue. You asked to send next.'
        : 'Request the turn to send a message';
    final position = held ? null : data.myPositionLabel;

    final button = OButton(
      label: label,
      icon: held || waiting ? Icons.check_rounded : Icons.pan_tool_alt_rounded,
      variant: held || waiting
          ? OButtonVariant.secondary
          : OButtonVariant.primary,
      onPressed: held || waiting ? null : onRequestTurn,
      semanticLabel: semanticLabel,
      expand: true,
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        button,
        if (position != null) ...[
          const SizedBox(height: OSpace.s),
          Text(position, style: OType.caption.copyWith(color: c.textMuted)),
        ],
      ],
    );
  }

  Widget _queue(BuildContext context) {
    final c = OColors.of(context);
    final visible = data.visibleQueue;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Wrap(
          spacing: OSpace.s,
          runSpacing: OSpace.xs,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text('Waiting', style: OType.overline.copyWith(color: c.textMuted)),
            if (data.waitingCount > 0)
              OPill(
                label:
                    '${data.waitingCount} ${data.waitingCount == 1 ? 'person' : 'people'}',
              ),
          ],
        ),
        const SizedBox(height: OSpace.s),
        if (visible.isEmpty)
          Text(
            'Nobody else is waiting. Request the turn to go next.',
            style: OType.caption.copyWith(color: c.textFaint),
          )
        else ...[
          for (var i = 0; i < visible.length; i++) ...[
            _QueueRow(position: i + 1, waiter: visible[i]),
            if (i < visible.length - 1) const SizedBox(height: OSpace.xs),
          ],
          if (data.hiddenQueueCount > 0) ...[
            const SizedBox(height: OSpace.s),
            Wrap(
              spacing: OSpace.s,
              runSpacing: OSpace.xs,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text(
                  '+${data.hiddenQueueCount} more waiting',
                  style: OType.caption.copyWith(color: c.textMuted),
                ),
                if (onViewQueue != null)
                  OButton(
                    label: 'View all',
                    variant: OButtonVariant.ghost,
                    onPressed: onViewQueue,
                    semanticLabel:
                        'View all ${data.waitingCount} people waiting for the turn',
                  ),
              ],
            ),
          ],
        ],
      ],
    );
  }
}

class _TurnGlyph extends StatelessWidget {
  const _TurnGlyph({required this.active});

  final bool active;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    return Container(
      width: 36,
      height: 36,
      decoration: BoxDecoration(
        color: active ? c.accentFill : c.accentSoft,
        borderRadius: BorderRadius.circular(ORadius.m),
      ),
      child: Icon(
        active ? Icons.pan_tool_alt_rounded : Icons.hourglass_bottom_rounded,
        size: 19,
        color: active ? c.onAccent : c.accent,
      ),
    );
  }
}

class _TimeLeftPill extends StatelessWidget {
  const _TimeLeftPill({required this.label, required this.urgent});

  final String label;
  final bool urgent;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    final fg = urgent ? c.warn : c.textMuted;
    return Container(
      constraints: const BoxConstraints(minHeight: 24),
      padding: const EdgeInsets.symmetric(
        horizontal: OSpace.s,
        vertical: OSpace.xs,
      ),
      decoration: BoxDecoration(
        color: urgent ? c.warn.withValues(alpha: 0.12) : c.surfaceAlt,
        borderRadius: BorderRadius.circular(ORadius.pill),
        border: Border.all(color: c.hairline),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.timer_outlined, size: 14, color: fg),
          const SizedBox(width: OSpace.xs),
          Flexible(
            child: Text(
              label,
              style: OType.caption.copyWith(
                color: fg,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _QueueRow extends StatelessWidget {
  const _QueueRow({required this.position, required this.waiter});

  final int position;
  final V2CollabTurnWaiter waiter;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    final name = Text(
      waiter.name,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: OType.bodySm.copyWith(
        color: waiter.isYou ? c.accent : c.text,
        fontWeight: waiter.isYou ? FontWeight.w600 : FontWeight.w400,
      ),
    );
    return Semantics(
      label: [
        'Number $position in line: ${waiter.name}',
        if (waiter.isYou) 'you',
        if (waiter.waitLabel != null) waiter.waitLabel!,
      ].join(', '),
      excludeSemantics: true,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Container(
              constraints: const BoxConstraints(minWidth: 22, minHeight: 22),
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: waiter.isYou ? c.accentSoft : c.surfaceAlt,
                borderRadius: BorderRadius.circular(ORadius.pill),
              ),
              child: Text(
                '$position',
                style: OType.caption.copyWith(
                  color: waiter.isYou ? c.accent : c.textMuted,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const SizedBox(width: OSpace.s),
            OAvatar(
              initials: waiter.initials ?? waiter.name,
              size: 28,
              semanticLabel: waiter.name,
            ),
            const SizedBox(width: OSpace.s),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Wrap(
                    spacing: OSpace.xs,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      name,
                      if (waiter.isYou)
                        Text(
                          '(you)',
                          style: OType.caption.copyWith(color: c.accent),
                        ),
                    ],
                  ),
                  if (waiter.waitLabel != null)
                    Text(
                      waiter.waitLabel!,
                      style: OType.caption.copyWith(color: c.textFaint),
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

class _OneAtATimeNote extends StatelessWidget {
  const _OneAtATimeNote();

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(Icons.lock_clock_rounded, size: 16, color: c.accent),
        const SizedBox(width: OSpace.s),
        Expanded(
          child: Text(
            'One message at a time. When a message sends, the turn passes to '
            'the next person in line.',
            style: OType.caption.copyWith(color: c.textMuted),
          ),
        ),
      ],
    );
  }
}
