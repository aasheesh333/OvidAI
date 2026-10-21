import 'package:flutter/material.dart';

import '../../design/o_components.dart';
import '../../design/o_motion.dart';
import '../../design/o_tokens.dart';

// TODO(l10n): move user-facing copy to the ARB files in the next wave.

enum V2TakeControlStatus { ready, loading, ended, error }

/// State for the hand-over sheet. The countdown comes from the live session,
/// so it is injected rather than ticked inside the widget.
@immutable
class V2TakeControlData {
  const V2TakeControlData({
    this.status = V2TakeControlStatus.ready,
    this.countdownLabel = 'Ovid paused · 4:59',
    this.keyboard = false,
    this.trackpad = false,
    this.errorMessage = 'Ovid could not pause the page. Try again.',
    this.pausedItems = const <String>[
      'Clicks and scrolling',
      'Typing and form entries',
      'Opening new pages',
    ],
    this.startWindowLabel = 'Start within 45 s or Ovid keeps driving.',
  });

  final V2TakeControlStatus status;
  final String countdownLabel;
  final bool keyboard;
  final bool trackpad;
  final String errorMessage;

  /// What Ovid stops doing while the person is in control.
  final List<String> pausedItems;

  /// The short window to start before Ovid carries on by itself.
  final String startWindowLabel;
}

/// Bottom sheet that hands the live page to the person for five minutes.
///
/// The widget includes its own scrim so it can be dropped straight into a
/// [Stack] over the browser; [showModalBottomSheet] callers can pass
/// `TakeControlSheet(scrim: false)` instead.
class TakeControlSheet extends StatelessWidget {
  const TakeControlSheet({
    super.key,
    required this.data,
    this.onStart,
    this.onStayWatching,
    this.onToggleKeyboard,
    this.onToggleTrackpad,
    this.onRetry,
    this.scrim = true,
  });

  final V2TakeControlData data;
  final VoidCallback? onStart;
  final VoidCallback? onStayWatching;
  final VoidCallback? onToggleKeyboard;
  final VoidCallback? onToggleTrackpad;
  final VoidCallback? onRetry;
  final bool scrim;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    final maxHeight = MediaQuery.sizeOf(context).height * 0.9;
    final panel = ConstrainedBox(
      constraints: BoxConstraints(maxWidth: 560, maxHeight: maxHeight),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (data.status != V2TakeControlStatus.ended) ...[
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: OSpace.l),
              child: _CountdownPill(label: data.countdownLabel),
            ),
            const SizedBox(height: OSpace.s),
          ],
          Flexible(
            child: Container(
              width: double.infinity,
              decoration: BoxDecoration(
                color: c.surface,
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(ORadius.xl),
                ),
                border: Border.all(color: c.hairline),
              ),
              child: SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(
                    OSpace.xl,
                    OSpace.s,
                    OSpace.xl,
                    OSpace.l,
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 36,
                        height: 4,
                        decoration: BoxDecoration(
                          color: c.hairlineStrong,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                      const SizedBox(height: OSpace.l),
                      Flexible(
                        child: _PanelBody(
                          data: data,
                          onStart: onStart,
                          onStayWatching: onStayWatching,
                          onToggleKeyboard: onToggleKeyboard,
                          onToggleTrackpad: onToggleTrackpad,
                          onRetry: onRetry,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );

    final content = Align(
      alignment: Alignment.bottomCenter,
      child: OFadeSlide(offset: const Offset(0, 0.06), child: panel),
    );

    if (!scrim) return content;
    return Stack(
      children: [
        Positioned.fill(
          // The barrier is a shortcut for "Stay watching"; the visible button
          // carries the action and the label, so the barrier itself is kept out
          // of the semantics tree instead of being announced unlabelled.
          child: ExcludeSemantics(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: onStayWatching,
              child: ColoredBox(color: c.scrim),
            ),
          ),
        ),
        content,
      ],
    );
  }
}

class _CountdownPill extends StatelessWidget {
  const _CountdownPill({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    return Container(
      constraints: const BoxConstraints(minHeight: 36),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: OSpace.xs),
      decoration: BoxDecoration(
        color: c.surfaceRaised,
        borderRadius: BorderRadius.circular(ORadius.pill),
        border: Border.all(color: c.hairline),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.timer_outlined, size: 15, color: c.accent),
          const SizedBox(width: OSpace.s),
          Flexible(
            child: Text(
              label,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: OType.caption.copyWith(
                color: c.text,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _PanelBody extends StatelessWidget {
  const _PanelBody({
    required this.data,
    this.onStart,
    this.onStayWatching,
    this.onToggleKeyboard,
    this.onToggleTrackpad,
    this.onRetry,
  });

  final V2TakeControlData data;
  final VoidCallback? onStart;
  final VoidCallback? onStayWatching;
  final VoidCallback? onToggleKeyboard;
  final VoidCallback? onToggleTrackpad;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    return switch (data.status) {
      V2TakeControlStatus.loading => const SizedBox(
        height: 220,
        child: OLoadingState(label: 'Pausing Ovid…'),
      ),
      V2TakeControlStatus.ended => OEmptyState(
        compact: true,
        icon: Icons.timer_off_outlined,
        title: 'Session ended',
        message:
            'Ovid is back to watching this tab. You can ask to take over '
            'again at any time.',
        action: OButton(label: 'Back to browser', onPressed: onStayWatching),
      ),
      V2TakeControlStatus.error => OErrorState(
        title: 'Could not pause',
        message: data.errorMessage,
        onRetry: onRetry,
      ),
      V2TakeControlStatus.ready => SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(
                color: c.accentSoft,
                borderRadius: BorderRadius.circular(ORadius.l),
              ),
              child: Icon(Icons.front_hand_outlined, size: 28, color: c.accent),
            ),
            const SizedBox(height: OSpace.m),
            Text(
              'Take control',
              textAlign: TextAlign.center,
              style: OType.h1.copyWith(color: c.text),
            ),
            const SizedBox(height: OSpace.s),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 340),
              child: Text(
                'You can tap, type, and scroll just like on your own '
                'phone. Ovid will hold the spot right here.',
                textAlign: TextAlign.center,
                style: OType.bodySm.copyWith(color: c.textMuted),
              ),
            ),
            if (data.pausedItems.isNotEmpty) ...[
              const SizedBox(height: OSpace.m),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(OSpace.m),
                decoration: BoxDecoration(
                  color: c.surfaceAlt,
                  borderRadius: BorderRadius.circular(ORadius.m),
                  border: Border.all(color: c.hairline),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      Icons.pause_circle_outline_rounded,
                      size: 16,
                      color: c.textMuted,
                    ),
                    const SizedBox(width: OSpace.s),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'What pauses',
                            style: OType.label.copyWith(color: c.textMuted),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            data.pausedItems.join(' · '),
                            style: OType.caption.copyWith(color: c.text),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],
            const SizedBox(height: OSpace.m),
            Row(
              children: [
                Expanded(
                  child: _ToolChip(
                    icon: Icons.keyboard_outlined,
                    label: 'Show keyboard',
                    selected: data.keyboard,
                    onTap: onToggleKeyboard,
                  ),
                ),
                const SizedBox(width: OSpace.m),
                Expanded(
                  child: _ToolChip(
                    icon: Icons.mouse_outlined,
                    label: 'Trackpad',
                    selected: data.trackpad,
                    onTap: onToggleTrackpad,
                  ),
                ),
              ],
            ),
            const SizedBox(height: OSpace.m),
            OButton(
              label: 'Start controlling',
              icon: Icons.front_hand_outlined,
              expand: true,
              onPressed: onStart,
            ),
            const SizedBox(height: OSpace.s),
            Text(
              data.startWindowLabel,
              textAlign: TextAlign.center,
              style: OType.caption.copyWith(color: c.warn),
            ),
            const SizedBox(height: OSpace.s),
            OButton(
              label: 'Stay watching',
              variant: OButtonVariant.secondary,
              expand: true,
              onPressed: onStayWatching,
            ),
            const SizedBox(height: OSpace.m),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.info_outline_rounded, size: 16, color: c.textFaint),
                const SizedBox(width: OSpace.s),
                Expanded(
                  child: Text(
                    'Ovid resumes when the timer ends, or when you hand back '
                    'control.',
                    style: OType.caption.copyWith(color: c.textFaint),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    };
  }
}

class _ToolChip extends StatelessWidget {
  const _ToolChip({
    required this.icon,
    required this.label,
    required this.selected,
    this.onTap,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    final enabled = onTap != null;
    return Semantics(
      container: true,
      label: label,
      button: true,
      selected: selected,
      enabled: enabled,
      onTap: onTap,
      child: ExcludeSemantics(
        child: OPressable(
          onTap: onTap,
          child: AnimatedContainer(
            duration: OMotion.fast,
            curve: OMotion.standard,
            height: OSpace.touch,
            padding: const EdgeInsets.symmetric(horizontal: OSpace.m),
            decoration: BoxDecoration(
              color: selected ? c.accentSoft : c.surfaceAlt,
              borderRadius: BorderRadius.circular(ORadius.m),
              border: Border.all(color: selected ? c.accentFill : c.hairline),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(icon, size: 18, color: selected ? c.accent : c.textMuted),
                const SizedBox(width: OSpace.s),
                Flexible(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: OType.label.copyWith(
                      color: selected ? c.accent : c.textMuted,
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
