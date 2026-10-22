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

  /// Share of the turn still left. Retained for hosts; the one-line banner
  /// shows the label, not a progress bar.
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

  /// Retained for callers that used to render the queue. The banner is one
  /// line, so the queue lives on the members page.
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

/// One status line for the shared turn: who holds it, how long is left and the
/// single action available (ask for the turn).
///
/// Presentational only: the live adapter passes [V2CollabTurnBannerData] and
/// owns the callbacks. The queue, countdown bar and rule paragraphs belong to
/// the members page, not here.
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

  /// Retained for hosts that open the full member list. The one-line banner
  /// has no queue affordance.
  final VoidCallback? onViewQueue;

  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    return switch (data.status) {
      V2CollabTurnBannerStatus.loading => const _Banner(
        child: OSkeleton(width: 180, height: 16),
      ),
      V2CollabTurnBannerStatus.error => _line(
        context,
        icon: Icons.error_outline_rounded,
        text: data.errorMessage,
        danger: true,
        action: onRetry == null
            ? null
            : _ActionText(label: 'Retry', onPressed: onRetry),
      ),
      V2CollabTurnBannerStatus.empty => _freeTurn(context),
      V2CollabTurnBannerStatus.ready =>
        data.hasTurn ? _turn(context) : _freeTurn(context),
    };
  }

  Widget _freeTurn(BuildContext context) {
    return _line(
      context,
      icon: Icons.hourglass_bottom_rounded,
      text: 'Turn is free',
      action: onRequestTurn == null
          ? null
          : _ActionText(
              label: 'Request turn',
              onPressed: onRequestTurn,
            ),
    );
  }

  Widget _turn(BuildContext context) {
    final time = data.timeLeftLabel.trim();
    final text = data.isMyTurn
        ? (time.isEmpty ? 'Your turn' : 'Your turn · $time')
        : (time.isEmpty
              ? '${data.holderName} has the turn'
              : '${data.holderName} · $time');
    final Widget? action;
    if (data.isMyTurn) {
      action = null;
    } else if (data.turnRequested) {
      action = Text(
        'In queue',
        style: OType.caption.copyWith(color: OColors.of(context).textMuted),
      );
    } else if (onRequestTurn != null) {
      action = _ActionText(label: 'Request turn', onPressed: onRequestTurn);
    } else {
      action = null;
    }
    return _line(
      context,
      icon: data.isMyTurn
          ? Icons.pan_tool_alt_rounded
          : Icons.hourglass_bottom_rounded,
      text: text,
      accent: data.isMyTurn,
      action: action,
      semanticLabel: [
        text,
        if (data.myPositionLabel != null) data.myPositionLabel!,
      ].join('. '),
    );
  }

  Widget _line(
    BuildContext context, {
    required IconData icon,
    required String text,
    Widget? action,
    bool accent = false,
    bool danger = false,
    String? semanticLabel,
  }) {
    final c = OColors.of(context);
    final color = danger
        ? c.danger
        : (accent ? c.accent : c.textMuted);
    return _Banner(
      child: Semantics(
        container: true,
        explicitChildNodes: true,
        label: semanticLabel ?? text,
        child: Row(
          children: [
            ExcludeSemantics(
              child: Icon(icon, size: 18, color: color),
            ),
            const SizedBox(width: OSpace.s),
            Expanded(
              child: ExcludeSemantics(
                child: Text(
                  text,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: OType.bodySm.copyWith(
                    color: danger ? c.danger : c.text,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
            if (action != null) ...[
              const SizedBox(width: OSpace.xs),
              action,
            ],
          ],
        ),
      ),
    );
  }
}

/// Text action that can shrink: the label ellipsizes instead of pushing the
/// status line past the screen edge at 200 % text.
class _ActionText extends StatelessWidget {
  const _ActionText({required this.label, required this.onPressed});

  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    return Semantics(
      button: true,
      enabled: onPressed != null,
      label: label,
      onTap: onPressed,
      excludeSemantics: true,
      child: OPressable(
        onTap: onPressed,
        child: ConstrainedBox(
          constraints: const BoxConstraints(
            minHeight: OSpace.touch,
            maxWidth: 120,
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: OSpace.s),
            child: Center(
              widthFactor: 1,
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: OType.label.copyWith(color: c.accent),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Banner extends StatelessWidget {
  const _Banner({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    return Container(
      constraints: const BoxConstraints(minHeight: OSpace.touch),
      padding: const EdgeInsets.symmetric(
        horizontal: OSpace.m,
        vertical: OSpace.xs,
      ),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(ORadius.m),
        border: Border.all(color: c.hairline),
      ),
      child: Align(
        alignment: Alignment.centerLeft,
        heightFactor: 1,
        child: child,
      ),
    );
  }
}
