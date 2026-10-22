import 'package:flutter/material.dart';

import '../../design/o_components.dart';
import '../../design/o_motion.dart';
import '../../design/o_tokens.dart';

// TODO(l10n): move user-facing copy to the ARB files in the next wave.

/// The browser's floating control dock, shown over the bottom of the frame
/// while the person holds the page.
///
/// Icon-only: back / forward / keyboard / return control. The page passes
/// only the callbacks this build can really perform, and the dock renders
/// only those controls — a history arrow appears when there is history,
/// never as a disabled placeholder.
class BrowserControlBar extends StatelessWidget {
  const BrowserControlBar({
    super.key,
    this.controlling = false,
    this.keyboard = false,
    this.canGoBack = false,
    this.canGoForward = false,
    this.onTakeControl,
    this.onReleaseControl,
    this.onToggleKeyboard,
    this.onBack,
    this.onForward,
  });

  /// Stable keys for integration tests and a11y probes. [takeControlKey]
  /// marks whichever hand-over control is on screen: the pill while watching,
  /// the return-control button while controlling.
  static const barKey = ValueKey<String>('browser-control-bar');
  static const takeControlKey = ValueKey<String>('browser-control-take');
  static const keyboardKey = ValueKey<String>('browser-control-keyboard');
  static const backKey = ValueKey<String>('browser-control-back');
  static const forwardKey = ValueKey<String>('browser-control-forward');

  /// True while this person holds the page. The dock is only mounted then.
  final bool controlling;

  final bool keyboard;

  /// History availability. An arrow is only shown when it can act.
  final bool canGoBack;
  final bool canGoForward;

  final VoidCallback? onTakeControl;
  final VoidCallback? onReleaseControl;
  final VoidCallback? onToggleKeyboard;
  final VoidCallback? onBack;
  final VoidCallback? onForward;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    final children = <Widget>[
      if (onBack != null && canGoBack)
        OIconButton(
          key: backKey,
          icon: Icons.arrow_back_rounded,
          semanticLabel: 'Back',
          tooltip: 'Back',
          onPressed: onBack,
        ),
      if (onForward != null && canGoForward)
        OIconButton(
          key: forwardKey,
          icon: Icons.arrow_forward_rounded,
          semanticLabel: 'Forward',
          tooltip: 'Forward',
          onPressed: onForward,
        ),
      if (onToggleKeyboard != null)
        OIconButton(
          key: keyboardKey,
          icon: keyboard ? Icons.keyboard_hide_rounded : Icons.keyboard_rounded,
          semanticLabel: keyboard ? 'Hide keyboard' : 'Show keyboard',
          tooltip: keyboard ? 'Hide keyboard' : 'Show keyboard',
          active: keyboard,
          onPressed: onToggleKeyboard,
        ),
      if (onReleaseControl != null)
        OIconButton(
          key: takeControlKey,
          icon: Icons.front_hand_rounded,
          semanticLabel: 'Return control',
          tooltip: 'Return control',
          active: true,
          onPressed: onReleaseControl,
        ),
    ];

    // Nothing this build can do: no dock at all, rather than an empty strip.
    if (children.isEmpty) return const SizedBox.shrink();

    return Semantics(
      key: barKey,
      container: true,
      label: 'Browser controls',
      child: Container(
        decoration: _overlayDecoration(c),
        child: Row(mainAxisSize: MainAxisSize.min, children: children),
      ),
    );
  }
}

/// The one pill over the picture: the way to take the page while watching.
/// Once the server hands control over, the dock replaces it.
class BrowserTakeControlPill extends StatelessWidget {
  const BrowserTakeControlPill({super.key, this.onPressed});

  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    // Chrome over the picture, not content: clamp the label the same way the
    // address pill is clamped, so a 200 % text scale can never push the pill
    // past the frame.
    return MediaQuery.withClampedTextScaling(
      maxScaleFactor: 1.3,
      child: Tooltip(
        message: 'Take control',
        child: OPressable(
          key: BrowserControlBar.takeControlKey,
          onTap: onPressed,
          semanticLabel: 'Take control',
          child: Container(
            height: OSpace.touch,
            padding: const EdgeInsets.symmetric(horizontal: OSpace.l),
            decoration: _overlayDecoration(c),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.front_hand_outlined, size: 18, color: c.text),
                const SizedBox(width: OSpace.s),
                Text(
                  'Take control',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: OType.label.copyWith(color: c.text),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// One shared floating-chrome treatment: a raised pill that stays readable
/// over any page the stream paints.
BoxDecoration _overlayDecoration(OColors c) {
  // Flat system: the dock is separated from the page by a hairline, not by a
  // drop shadow.
  return BoxDecoration(
    color: c.surface,
    borderRadius: BorderRadius.circular(ORadius.pill),
    border: Border.all(color: c.hairlineStrong),
  );
}
