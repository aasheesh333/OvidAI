import 'package:flutter/material.dart';

import '../../design/o_components.dart';
import '../../design/o_motion.dart';
import '../../design/o_tokens.dart';

// TODO(l10n): extract this banner's English copy during the ARB pass.

enum V2CollabTurnBannerStatus {
  loading,
  empty,
  error,
  ready,

  /// The live socket is opening; no one may send yet.
  connecting,

  /// The socket dropped. The room is readable, but sending stays locked.
  disconnected,
}

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
/// owns the callbacks. A request is in flight from the moment the action is
/// pressed until the host answers; a refusal is shown in the banner instead of
/// disappearing into a toast. The countdown itself is owned by the page: this
/// banner must not announce every passing second.
class CollabTurnBanner extends StatefulWidget {
  const CollabTurnBanner({
    super.key,
    required this.data,
    this.onRequestTurn,
    this.onRequestTurnAsync,
    this.onViewQueue,
    this.onRetry,
  });

  final V2CollabTurnBannerData data;

  /// Legacy synchronous request. Kept for hosts that already mutate their own
  /// state in the callback.
  final VoidCallback? onRequestTurn;

  /// Real request path. The returned string is a refusal reason, or null when
  /// the request was accepted. The banner disables itself while the future is
  /// pending and announces the refusal when it lands.
  final Future<String?> Function()? onRequestTurnAsync;

  /// Retained for hosts that open the full member list. The one-line banner
  /// has no queue affordance.
  final VoidCallback? onViewQueue;

  final VoidCallback? onRetry;

  @override
  State<CollabTurnBanner> createState() => _CollabTurnBannerState();
}

class _CollabTurnBannerState extends State<CollabTurnBanner> {
  bool _requesting = false;
  bool _accepted = false;
  String? _refusal;

  bool get _hasRequestHandler =>
      widget.onRequestTurn != null || widget.onRequestTurnAsync != null;

  @override
  void didUpdateWidget(covariant CollabTurnBanner oldWidget) {
    super.didUpdateWidget(oldWidget);
    final old = oldWidget.data;
    final data = widget.data;
    // A new holder or a new turn starts a new request cycle. An accepted local
    // request remains visible until the host's projection catches up.
    if (old.holderName != data.holderName || old.isMyTurn != data.isMyTurn) {
      _accepted = false;
      _refusal = null;
    }
    if (data.turnRequested && !old.turnRequested) {
      _accepted = false;
      _refusal = null;
    }
    if (data.status != old.status &&
        data.status != V2CollabTurnBannerStatus.ready) {
      _refusal = null;
    }
  }

  Future<void> _request() async {
    if (_requesting || !_hasRequestHandler) return;
    final async = widget.onRequestTurnAsync;
    final sync = widget.onRequestTurn;
    if (async == null) {
      sync?.call();
      return;
    }
    setState(() {
      _requesting = true;
      _refusal = null;
    });
    try {
      final reason = await async();
      if (!mounted) return;
      final trimmed = reason?.trim();
      setState(() {
        if (trimmed == null || trimmed.isEmpty) {
          _accepted = true;
        } else {
          _refusal = trimmed;
        }
      });
    } catch (error) {
      if (!mounted) return;
      final reason = error is String && error.trim().isNotEmpty
          ? error.trim()
          : 'Could not request the turn.';
      setState(() => _refusal = reason);
    } finally {
      if (mounted) setState(() => _requesting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return switch (widget.data.status) {
      V2CollabTurnBannerStatus.loading => const _Banner(
        child: OSkeleton(width: 180, height: 16),
      ),
      V2CollabTurnBannerStatus.error => _line(
        context,
        icon: Icons.error_outline_rounded,
        text: widget.data.errorMessage,
        danger: true,
        action: widget.onRetry == null
            ? null
            : _ActionText(label: 'Retry', onPressed: widget.onRetry),
      ),
      V2CollabTurnBannerStatus.connecting => _line(
        context,
        icon: Icons.wifi_tethering_rounded,
        text: 'Connecting',
        semanticLabel: 'Connecting. Your messages are locked.',
      ),
      V2CollabTurnBannerStatus.disconnected => _line(
        context,
        icon: Icons.cloud_off_rounded,
        text: 'Disconnected',
        danger: true,
        semanticLabel: 'Disconnected. Your messages are locked.',
        action: widget.onRetry == null
            ? null
            : _ActionText(label: 'Retry', onPressed: widget.onRetry),
      ),
      V2CollabTurnBannerStatus.empty || V2CollabTurnBannerStatus.ready =>
        widget.data.isMyTurn
            ? _myTurn(context)
            : (widget.data.hasTurn ? _holderTurn(context) : _freeTurn(context)),
    };
  }

  Widget _freeTurn(BuildContext context) {
    // A free turn still has a request in flight: asking twice must not look
    // like an untouched control.
    final Widget? action;
    if (_requesting) {
      action = const _RequestingAction();
    } else if (_accepted || widget.data.turnRequested) {
      action = const _StatusText(label: 'In queue');
    } else {
      action = _requestAction(label: 'Take turn');
    }
    return _line(
      context,
      icon: Icons.hourglass_bottom_rounded,
      text: 'Turn is free',
      action: action,
    );
  }

  Widget _myTurn(BuildContext context) {
    final time = widget.data.timeLeftLabel.trim();
    final text = time.isEmpty ? 'Your turn' : 'Your turn · $time';
    return _line(
      context,
      icon: Icons.pan_tool_alt_rounded,
      text: text,
      accent: true,
      semanticLabel: 'Your turn. Send a message.',
    );
  }

  Widget _holderTurn(BuildContext context) {
    final data = widget.data;
    final time = data.timeLeftLabel.trim();
    final text = time.isEmpty
        ? '${data.holderName} has the turn'
        : '${data.holderName} · $time';
    final Widget? action;
    if (_requesting) {
      action = const _RequestingAction();
    } else if (_accepted || data.turnRequested) {
      action = const _StatusText(label: 'In queue');
    } else {
      action = _requestAction(label: 'Request turn');
    }
    final position = data.myPositionLabel;
    final spoken = ['${data.holderName} has the turn', ?position].join('. ');
    return _line(
      context,
      icon: Icons.hourglass_bottom_rounded,
      text: text,
      semanticLabel: spoken,
      action: action,
    );
  }

  Widget? _requestAction({required String label}) {
    if (_requesting) return const _RequestingAction();
    if (!_hasRequestHandler) return null;
    return _ActionText(label: label, onPressed: _request);
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
    final color = danger ? c.danger : (accent ? c.accent : c.textMuted);
    final refusal = _refusal?.trim();
    final base = (semanticLabel ?? text).trim();
    final spoken = refusal == null || refusal.isEmpty
        ? base
        : '${base.endsWith('.') ? base : '$base.'} $refusal';
    return _Banner(
      footer: refusal == null ? null : _RefusalLine(message: refusal),
      child: Semantics(
        container: true,
        explicitChildNodes: true,
        liveRegion: true,
        label: spoken,
        child: Row(
          children: [
            ExcludeSemantics(child: Icon(icon, size: 18, color: color)),
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
            if (action != null) ...[const SizedBox(width: OSpace.xs), action],
          ],
        ),
      ),
    );
  }
}

/// Inline refusal. The banner's live region carries the full sentence; this
/// visible copy is capped at two lines so a long server reason cannot grow the
/// header without bound.
class _RefusalLine extends StatelessWidget {
  const _RefusalLine({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    return ExcludeSemantics(
      child: Text(
        message,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: OType.caption.copyWith(color: c.danger),
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
            maxWidth: 160,
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: OSpace.s),
            child: Center(
              widthFactor: 1,
              // A control label must stay whole: at 200 % text the 160 dp cap
              // would ellipsize it to "Request tu…". Scale the word down
              // instead; the spoken label is unaffected.
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  label,
                  maxLines: 1,
                  softWrap: false,
                  style: OType.label.copyWith(color: c.accent),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The in-flight state of a turn request: a 48 dp target-sized spinner, so the
/// row does not jump when the action turns into progress.
class _RequestingAction extends StatelessWidget {
  const _RequestingAction();

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    return Semantics(
      label: 'Requesting turn',
      child: ExcludeSemantics(
        child: SizedBox(
          width: OSpace.touch,
          height: OSpace.touch,
          child: Center(
            child: SizedBox(
              width: 18,
              height: 18,
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

class _StatusText extends StatelessWidget {
  const _StatusText({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    return Semantics(
      label: label,
      child: ExcludeSemantics(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: OSpace.s),
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: OType.caption.copyWith(color: c.textMuted),
          ),
        ),
      ),
    );
  }
}

class _Banner extends StatelessWidget {
  const _Banner({required this.child, this.footer});

  final Widget child;
  final Widget? footer;

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
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Align(alignment: Alignment.centerLeft, child: child),
          if (footer != null) ...[const SizedBox(height: OSpace.xxs), footer!],
        ],
      ),
    );
  }
}
