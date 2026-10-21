import 'package:flutter/material.dart';

import '../../design/o_components.dart';
import '../../design/o_motion.dart';
import '../../design/o_tokens.dart';

// TODO(l10n): move user-facing copy to ARB keys in the localization pass.

/// The queued-message dock that sits directly above the composer.
///
/// While the main agent is working, messages typed in the composer wait here
/// instead of starting a second run. The dock shows how many messages are
/// waiting and a preview of the oldest one. "Send now" is the same action as
/// Stop: it cancels the current turn and dispatches the queued message
/// immediately. Dismiss removes the queued message without sending it.
///
/// Purely presentational: the host owns the queue and supplies the callbacks.
class V2QueueDock extends StatelessWidget {
  const V2QueueDock({
    super.key,
    required this.count,
    required this.preview,
    this.onSendNow,
    this.onDismiss,
  });

  /// Number of messages waiting in the queue. Must be at least one.
  final int count;

  /// Preview of the next message, shown over at most two lines.
  final String preview;

  /// Cancels the active run and sends the queued message immediately.
  final VoidCallback? onSendNow;

  /// Removes the queued message without sending it.
  final VoidCallback? onDismiss;

  /// "1 queued message" / "3 queued messages".
  static String countLabel(int count) =>
      count == 1 ? '1 queued message' : '$count queued messages';

  @override
  Widget build(BuildContext context) {
    if (count <= 0) return const SizedBox.shrink();
    final c = OColors.of(context);
    final body = preview.trim();
    return Padding(
      padding: const EdgeInsets.fromLTRB(OSpace.l, 0, OSpace.l, OSpace.s),
      child: OFadeSlide(
        child: Container(
          padding: const EdgeInsets.fromLTRB(
            OSpace.m,
            OSpace.s,
            OSpace.xs,
            OSpace.m,
          ),
          decoration: BoxDecoration(
            color: c.surfaceAlt,
            borderRadius: BorderRadius.circular(ORadius.l),
            border: Border.all(color: c.hairline),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Icon(Icons.queue_rounded, size: 18, color: c.accent),
                  const SizedBox(width: OSpace.s),
                  Expanded(
                    child: Semantics(
                      liveRegion: true,
                      child: Text(
                        countLabel(count),
                        style: OType.label.copyWith(
                          color: c.text,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                  if (onDismiss != null)
                    OIconButton(
                      icon: Icons.close_rounded,
                      semanticLabel: 'Dismiss queued message',
                      onPressed: onDismiss,
                    ),
                ],
              ),
              if (body.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(
                    left: 26,
                    right: OSpace.s,
                    bottom: OSpace.xs,
                  ),
                  child: Text(
                    body,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: OType.bodySm.copyWith(color: c.textMuted),
                  ),
                ),
              Padding(
                padding: const EdgeInsets.only(right: OSpace.s),
                child: Align(
                  alignment: Alignment.centerRight,
                  child: OButton(
                    label: 'Send now',
                    icon: Icons.send_rounded,
                    variant: OButtonVariant.secondary,
                    onPressed: onSendNow,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
