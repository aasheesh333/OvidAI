import 'package:flutter/material.dart';

import '../../design/o_components.dart';
import '../../design/o_motion.dart';
import '../../design/o_tokens.dart';

// TODO(l10n): move user-facing copy to ARB keys in the localization pass.

/// The queued-message dock that sits directly above the composer.
///
/// While the main agent is working, messages typed in the composer wait here
/// instead of starting a second run. The dock is one line: how many are
/// waiting, "Send now" and dismiss. "Send now" is the same action as Stop: it
/// cancels the current turn and dispatches the queued message immediately.
///
/// Purely presentational: the host owns the queue and supplies the callbacks.
class V2QueueDock extends StatelessWidget {
  const V2QueueDock({
    super.key,
    required this.count,
    this.preview = '',
    this.onSendNow,
    this.onDismiss,
  });

  /// Number of messages waiting in the queue. Must be at least one.
  final int count;

  /// No longer drawn. Kept so existing hosts keep compiling; the dock shows a
  /// count, not a preview paragraph.
  final String preview;

  /// Cancels the active run and sends the queued message immediately.
  final VoidCallback? onSendNow;

  /// Removes the queued message without sending it.
  final VoidCallback? onDismiss;

  /// "1 queued" / "3 queued".
  static String countLabel(int count) => count == 1 ? '1 queued' : '$count queued';

  @override
  Widget build(BuildContext context) {
    if (count <= 0) return const SizedBox.shrink();
    final c = OColors.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(OSpace.l, 0, OSpace.l, OSpace.s),
      child: OFadeSlide(
        child: Container(
          constraints: const BoxConstraints(minHeight: OSpace.touch),
          padding: const EdgeInsets.only(left: OSpace.m, right: OSpace.xs),
          decoration: BoxDecoration(
            color: c.surfaceAlt,
            borderRadius: BorderRadius.circular(ORadius.pill),
            border: Border.all(color: c.hairline),
          ),
          child: Row(
            children: [
              Expanded(
                child: Semantics(
                  liveRegion: true,
                  child: Text(
                    countLabel(count),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: OType.label.copyWith(
                      color: c.text,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
              if (onSendNow != null)
                Flexible(child: _SendNow(onPressed: onSendNow!)),
              if (onDismiss != null)
                OIconButton(
                  icon: Icons.close_rounded,
                  semanticLabel: 'Dismiss queued message',
                  onPressed: onDismiss,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Compact "Send now" action that ellipsizes rather than overflowing the one
/// line dock at 320 dp / 200 % text.
class _SendNow extends StatelessWidget {
  const _SendNow({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    return Semantics(
      button: true,
      enabled: true,
      label: 'Send now',
      excludeSemantics: true,
      onTap: onPressed,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onPressed,
          borderRadius: BorderRadius.circular(ORadius.pill),
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              minHeight: OSpace.touch,
              minWidth: OSpace.touch,
            ),
            child: Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: OSpace.s),
                child: Text(
                  'Send now',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: OType.label.copyWith(
                    color: c.accent,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
