import 'package:flutter/material.dart';

import '../../design/o_components.dart';
import '../../design/o_tokens.dart';

// TODO(l10n): move user-facing copy to the ARB files in the next wave.

/// The bottom control bar of the live browser.
///
/// It is presentational: the page injects the current state and every
/// callback. The bar groups the actions that belong to the live picture:
///
///  * Ovid's tab history (back / forward);
///  * the human-input tools (take control, keyboard, trackpad);
///  * the announced frame rate and the headless countdown.
///
/// Every control keeps a 48 × 48 dp target and a tooltip plus screen-reader
/// label. A tool whose callback is null is not rendered at all: the bar only
/// shows actions this build can actually perform. History controls are the
/// exception — they stay visible but disabled while there is nowhere to go.
class BrowserControlBar extends StatelessWidget {
  const BrowserControlBar({
    super.key,
    this.controlling = false,
    this.keyboard = false,
    this.trackpad = false,
    this.canGoBack = false,
    this.canGoForward = false,
    this.fpsLabel = '3–5 fps',
    this.countdownLabel = '',
    this.showTakeControlLabel = false,
    this.onTakeControl,
    this.onReleaseControl,
    this.onToggleKeyboard,
    this.onToggleTrackpad,
    this.onBack,
    this.onForward,
    this.takeControlLabel = 'Take control',
    this.releaseControlLabel = 'Return control',
    this.showKeyboardLabel = 'Show keyboard',
    this.hideKeyboardLabel = 'Hide keyboard',
    this.showTrackpadLabel = 'Show trackpad',
    this.hideTrackpadLabel = 'Hide trackpad',
    this.backLabel = 'Back',
    this.forwardLabel = 'Forward',
    this.fpsSemanticLabel = 'Live frame rate',
    this.countdownSemanticLabel = 'Time until the live view goes headless',
    this.semanticLabel = 'Browser controls',
  });

  /// Stable keys for integration tests and a11y probes.
  static const barKey = ValueKey<String>('browser-control-bar');
  static const takeControlKey = ValueKey<String>('browser-control-take');
  static const keyboardKey = ValueKey<String>('browser-control-keyboard');
  static const trackpadKey = ValueKey<String>('browser-control-trackpad');
  static const backKey = ValueKey<String>('browser-control-back');
  static const forwardKey = ValueKey<String>('browser-control-forward');
  static const fpsKey = ValueKey<String>('browser-control-fps');
  static const countdownKey = ValueKey<String>('browser-control-countdown');

  /// True while this person holds the page. The take-control button then
  /// becomes "Return control" and the input tools stay enabled.
  final bool controlling;

  final bool keyboard;
  final bool trackpad;

  /// False when the tab has no history in that direction. The control stays
  /// in place and is announced as disabled.
  final bool canGoBack;
  final bool canGoForward;

  /// Product hint for the screencast cadence, e.g. `3–5 fps`.
  final String fpsLabel;

  /// Countdown copy while the live view is still open, e.g.
  /// `Headless in 45 s`. Empty hides the chip.
  final String countdownLabel;

  /// When true the take-control action renders as a labelled primary button
  /// instead of an icon. The page uses this when a custom viewport cannot show
  /// the built-in tap-to-control overlay.
  final bool showTakeControlLabel;

  final VoidCallback? onTakeControl;
  final VoidCallback? onReleaseControl;
  final VoidCallback? onToggleKeyboard;
  final VoidCallback? onToggleTrackpad;
  final VoidCallback? onBack;
  final VoidCallback? onForward;

  final String takeControlLabel;
  final String releaseControlLabel;
  final String showKeyboardLabel;
  final String hideKeyboardLabel;
  final String showTrackpadLabel;
  final String hideTrackpadLabel;
  final String backLabel;
  final String forwardLabel;
  final String fpsSemanticLabel;
  final String countdownSemanticLabel;
  final String semanticLabel;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    return Semantics(
      key: barKey,
      container: true,
      label: semanticLabel,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: c.surface,
          border: Border(top: BorderSide(color: c.hairline)),
        ),
        child: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
              OSpace.m,
              OSpace.s,
              OSpace.m,
              OSpace.s,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _StatusLine(
                  fpsLabel: fpsLabel,
                  countdownLabel: countdownLabel,
                  fpsSemanticLabel: fpsSemanticLabel,
                  countdownSemanticLabel: countdownSemanticLabel,
                  takeControl: _takeControl(context),
                ),
                if (_tools(context) case final tools?) ...[
                  const SizedBox(height: OSpace.xs),
                  tools,
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget? _takeControl(BuildContext context) {
    final label = controlling ? releaseControlLabel : takeControlLabel;
    final icon = controlling
        ? Icons.front_hand_rounded
        : Icons.front_hand_outlined;
    final onPressed = controlling ? onReleaseControl : onTakeControl;
    // Nothing to hand over and nothing to hand back: no control at all.
    if (onPressed == null) return null;
    if (showTakeControlLabel) {
      return OButton(
        key: takeControlKey,
        label: label,
        icon: icon,
        variant: controlling
            ? OButtonVariant.secondary
            : OButtonVariant.primary,
        onPressed: onPressed,
      );
    }
    return OIconButton(
      key: takeControlKey,
      icon: icon,
      semanticLabel: label,
      tooltip: label,
      active: controlling,
      onPressed: onPressed,
    );
  }

  /// The tool row, or null when this build has no tool to offer. History
  /// stays visible while there is a history handler so the bar keeps its
  /// shape; input tools appear only when they can actually drive the page.
  Widget? _tools(BuildContext context) {
    final children = <Widget>[
      if (onBack != null)
        OIconButton(
          key: backKey,
          icon: Icons.arrow_back_rounded,
          semanticLabel: backLabel,
          tooltip: backLabel,
          onPressed: canGoBack ? onBack : null,
        ),
      if (onForward != null)
        OIconButton(
          key: forwardKey,
          icon: Icons.arrow_forward_rounded,
          semanticLabel: forwardLabel,
          tooltip: forwardLabel,
          onPressed: canGoForward ? onForward : null,
        ),
      if (onToggleKeyboard != null)
        OIconButton(
          key: keyboardKey,
          icon: keyboard ? Icons.keyboard_hide_rounded : Icons.keyboard_rounded,
          semanticLabel: keyboard ? hideKeyboardLabel : showKeyboardLabel,
          tooltip: keyboard ? hideKeyboardLabel : showKeyboardLabel,
          active: keyboard,
          onPressed: onToggleKeyboard,
        ),
      if (onToggleTrackpad != null)
        OIconButton(
          key: trackpadKey,
          icon: trackpad ? Icons.touch_app_rounded : Icons.mouse_outlined,
          semanticLabel: trackpad ? hideTrackpadLabel : showTrackpadLabel,
          tooltip: trackpad ? hideTrackpadLabel : showTrackpadLabel,
          active: trackpad,
          onPressed: onToggleTrackpad,
        ),
    ];
    if (children.isEmpty) return null;
    return Wrap(children: children);
  }
}

/// The top line: frame rate, headless countdown and the hand-over control.
/// A [Wrap] keeps it readable at 320 dp and 200 % text instead of clipping.
class _StatusLine extends StatelessWidget {
  const _StatusLine({
    required this.fpsLabel,
    required this.countdownLabel,
    required this.fpsSemanticLabel,
    required this.countdownSemanticLabel,
    required this.takeControl,
  });

  final String fpsLabel;
  final String countdownLabel;
  final String fpsSemanticLabel;
  final String countdownSemanticLabel;
  final Widget? takeControl;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: OSpace.s,
      runSpacing: OSpace.xs,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        if (fpsLabel.isNotEmpty)
          _InfoChip(
            key: BrowserControlBar.fpsKey,
            icon: Icons.speed_rounded,
            label: fpsLabel,
            semanticLabel: '$fpsSemanticLabel, $fpsLabel',
          ),
        if (countdownLabel.isNotEmpty)
          _InfoChip(
            key: BrowserControlBar.countdownKey,
            icon: Icons.timer_outlined,
            label: countdownLabel,
            semanticLabel: '$countdownSemanticLabel, $countdownLabel',
            tone: _ChipTone.warn,
          ),
        ?takeControl,
      ],
    );
  }
}

enum _ChipTone { neutral, warn }

class _InfoChip extends StatelessWidget {
  const _InfoChip({
    super.key,
    required this.icon,
    required this.label,
    required this.semanticLabel,
    this.tone = _ChipTone.neutral,
  });

  final IconData icon;
  final String label;
  final String semanticLabel;
  final _ChipTone tone;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    final foreground = tone == _ChipTone.warn ? c.warn : c.textMuted;
    final background = tone == _ChipTone.warn
        ? c.warn.withValues(alpha: 0.10)
        : c.surfaceAlt;
    return Semantics(
      container: true,
      label: semanticLabel,
      child: ExcludeSemantics(
        child: Container(
          constraints: const BoxConstraints(minHeight: 32),
          padding: const EdgeInsets.symmetric(
            horizontal: OSpace.s,
            vertical: OSpace.xs,
          ),
          decoration: BoxDecoration(
            color: background,
            borderRadius: BorderRadius.circular(ORadius.pill),
            border: Border.all(
              color: tone == _ChipTone.warn
                  ? c.warn.withValues(alpha: 0.35)
                  : c.hairline,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 14, color: foreground),
              const SizedBox(width: OSpace.xs),
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: OType.caption.copyWith(
                    color: foreground,
                    fontWeight: FontWeight.w600,
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
