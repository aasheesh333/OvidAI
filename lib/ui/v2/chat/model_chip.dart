import 'package:flutter/material.dart';

import '../../design/o_components.dart';
import '../../design/o_motion.dart';
import '../../design/o_tokens.dart';

// TODO(l10n): move user-facing copy to ARB keys in the localization pass.

/// Width at which the model chip stops growing and starts ellipsizing its
/// label. The chat app bar only has room for a compact chip, so capping the
/// whole chip keeps the title readable at 320 dp.
const double v2ModelChipMaxWidth = 132;

/// The model selector in a chat app bar: model icon, current model name and a
/// chevron. An optional badge counts the subagents in the session.
///
/// The chip is presentational. [onTap] opens the caller's model menu; passing
/// null (or [enabled] false) renders and announces a disabled chip. The tap
/// target is always at least 48 dp even though the visible pill is shorter.
class V2ModelChip extends StatelessWidget {
  const V2ModelChip({
    super.key,
    required this.label,
    this.icon = Icons.auto_awesome_rounded,
    this.onTap,
    this.enabled = true,
    this.autoOnly = false,
    this.subagentCount = 0,
    this.semanticLabel,
  }) : assert(subagentCount >= 0, 'subagentCount cannot be negative');

  /// Current model name, e.g. "Auto" or "Ovid Pro 1.5".
  final String label;

  /// Model/provider glyph. Defaults to the Auto sparkle.
  final IconData icon;

  /// Opens the model menu. Null means the chip is disabled.
  final VoidCallback? onTap;

  /// Lets a caller disable the chip without dropping its callback, e.g. while
  /// a model switch is in flight.
  final bool enabled;

  /// Free and Go are Auto-only. Adds "Auto only" to the spoken label; the
  /// chip stays tappable so the upgrade menu can open.
  final bool autoOnly;

  /// Subagents launched in this session. When greater than zero, a small
  /// count badge sits next to the label.
  final int subagentCount;

  /// Overrides the generated accessibility label.
  final String? semanticLabel;

  bool get _active => enabled && onTap != null;

  String get _spokenLabel {
    if (semanticLabel != null) return semanticLabel!;
    final buffer = StringBuffer('Model: $label');
    if (autoOnly) buffer.write('. Auto only');
    if (subagentCount == 1) {
      buffer.write('. 1 subagent');
    } else if (subagentCount > 1) {
      buffer.write('. $subagentCount subagents');
    }
    buffer.write(_active ? '. Change model' : '. Model selection unavailable');
    return buffer.toString();
  }

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    final active = _active;
    final foreground = active ? c.text : c.textFaint;
    final accent = active ? c.accent : c.textFaint;
    final chevron = active ? c.textMuted : c.textFaint;

    return Semantics(
      container: true,
      label: _spokenLabel,
      button: true,
      enabled: active,
      onTap: active ? onTap : null,
      excludeSemantics: true,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: v2ModelChipMaxWidth),
        child: OPressable(
          onTap: active ? onTap : null,
          child: SizedBox(
            height: OSpace.touch,
            child: Center(
              widthFactor: 1,
              heightFactor: 1,
              child: Container(
                constraints: const BoxConstraints(
                  minWidth: OSpace.touch,
                  minHeight: 32,
                ),
                padding: const EdgeInsets.symmetric(
                  horizontal: OSpace.pillPad,
                  vertical: OSpace.xs,
                ),
                decoration: BoxDecoration(
                  color: active ? c.surfaceAlt : c.surface,
                  borderRadius: BorderRadius.circular(ORadius.pill),
                  border: Border.all(
                    color: active ? c.hairline : c.hairlineStrong,
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(icon, size: 15, color: accent),
                    const SizedBox(width: OSpace.xs),
                    Flexible(
                      child: Text(
                        label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: OType.label.copyWith(color: foreground),
                      ),
                    ),
                    if (subagentCount > 0) ...[
                      const SizedBox(width: OSpace.xs),
                      OCountBadge(count: subagentCount, active: active),
                    ],
                    const SizedBox(width: OSpace.xxs),
                    Icon(Icons.expand_more_rounded, size: 16, color: chevron),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

