import 'package:flutter/material.dart';

import '../../design/o_components.dart';
import '../../design/o_tokens.dart';

// TODO(l10n): move user-facing copy to the ARB files in the next wave.

/// The bottom control bar of the live browser.
///
/// It is presentational and deliberately small: one row of icon controls, no
/// captions, no status chips. The page passes only the callbacks this build
/// can really perform, and the bar renders only those controls — a history
/// arrow appears when there is history, never as a disabled placeholder.
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

  /// Stable keys for integration tests and a11y probes.
  static const barKey = ValueKey<String>('browser-control-bar');
  static const takeControlKey = ValueKey<String>('browser-control-take');
  static const keyboardKey = ValueKey<String>('browser-control-keyboard');
  static const backKey = ValueKey<String>('browser-control-back');
  static const forwardKey = ValueKey<String>('browser-control-forward');

  /// True while this person holds the page. The hand-over control then
  /// becomes "Return control".
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
      if ((controlling ? onReleaseControl : onTakeControl) != null)
        OIconButton(
          key: takeControlKey,
          icon: controlling
              ? Icons.front_hand_rounded
              : Icons.front_hand_outlined,
          semanticLabel: controlling ? 'Return control' : 'Take control',
          tooltip: controlling ? 'Return control' : 'Take control',
          active: controlling,
          onPressed: controlling ? onReleaseControl : onTakeControl,
        ),
    ];

    // Nothing this build can do: no bar at all, rather than an empty strip.
    if (children.isEmpty) return const SizedBox.shrink();

    return Semantics(
      key: barKey,
      container: true,
      label: 'Browser controls',
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: c.surface,
          border: Border(top: BorderSide(color: c.hairline)),
        ),
        child: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: OSpace.m,
              vertical: OSpace.s,
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: children,
            ),
          ),
        ),
      ),
    );
  }
}
