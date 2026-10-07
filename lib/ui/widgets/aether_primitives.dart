import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/theme.dart';

/// Aether design-system primitives.
///
/// A low-level widget library that mirrors the OvidAI "Aether" look —
/// a restrained monochrome surface with a single muted accent — so screens
/// can be composed from consistent building blocks instead of rolling bespoke
/// containers, buttons, and inputs per route.
///
/// Nothing here reaches outside of this file plus [Aether] from
/// `lib/core/theme.dart`. These primitives are safe to use anywhere.

/// Spacing scale used throughout the Aether UI.
///
/// Multiples of 4 keep rhythms stable across devices.
class AetherSpacing {
  AetherSpacing._();
  static const double space1 = 4;
  static const double space2 = 8;
  static const double space3 = 12;
  static const double space4 = 16;
  static const double space5 = 20;
  static const double space6 = 24;
  static const double space7 = 32;
  static const double space8 = 40;
  static const double space9 = 56;
  static const double space10 = 72;
}

/// Border-radius scale.
class AetherRadius {
  AetherRadius._();
  static const double rSm = 8;
  static const double rMd = 12;
  static const double rLg = 16;
  static const double rXl = 22;
  static const double rPill = 999;
}

/// Elevation shadow presets.
class AetherShadows {
  AetherShadows._();

  /// Low elevation — card edges, pill highlights.
  static List<BoxShadow> get shadowS => const [
    BoxShadow(
      color: Color(0x14000000), // black @ 0.08
      offset: Offset(0, 1),
      blurRadius: 2,
      spreadRadius: 0,
    ),
  ];

  /// Medium elevation — floating sheets, modals.
  static List<BoxShadow> get shadowM => const [
    BoxShadow(
      color: Color(0x24000000), // black @ 0.14
      offset: Offset(0, 4),
      blurRadius: 12,
      spreadRadius: 0,
    ),
    BoxShadow(
      color: Color(0x14000000), // black @ 0.08
      offset: Offset(0, 1),
      blurRadius: 2,
      spreadRadius: 0,
    ),
  ];
}

/// Typography presets. These are getters because [Aether.text] is theme-aware.
class AetherType {
  AetherType._();

  static TextStyle get display => TextStyle(
    fontSize: 34,
    fontWeight: FontWeight.w700,
    height: 1.05,
    letterSpacing: -1.0,
    color: Aether.text,
  );

  static TextStyle get h1 => TextStyle(
    fontSize: 22,
    fontWeight: FontWeight.w600,
    height: 1.2,
    letterSpacing: -0.4,
    color: Aether.text,
  );

  static TextStyle get h2 => TextStyle(
    fontSize: 18,
    fontWeight: FontWeight.w700,
    height: 1.3,
    color: Aether.text,
  );

  static TextStyle get title => TextStyle(
    fontSize: 15,
    fontWeight: FontWeight.w600,
    height: 1.4,
    color: Aether.text,
  );

  static TextStyle get body => TextStyle(
    fontSize: 14,
    fontWeight: FontWeight.w500,
    height: 1.5,
    color: Aether.text,
  );

  static TextStyle get bodyMuted => TextStyle(
    fontSize: 14,
    fontWeight: FontWeight.w500,
    height: 1.5,
    color: Aether.textMuted,
  );

  static TextStyle get label => TextStyle(
    fontSize: 12,
    fontWeight: FontWeight.w600,
    letterSpacing: 0.2,
    color: Aether.textMuted,
  );

  static TextStyle get caption => TextStyle(
    fontSize: 11,
    fontWeight: FontWeight.w500,
    color: Aether.textFaint,
  );

  static TextStyle get mono => const TextStyle(
    fontSize: 12,
    fontFamily: 'JetBrainsMono',
  );
}

/// A standard surface card with hairline border and soft elevation.
///
/// Optional [title]/[trailing] render a header row with a divider; [footer]
/// renders a divider plus trailing content underneath [child].
class AetherCard extends StatelessWidget {
  final Widget? title;
  final Widget? trailing;
  final Widget child;
  final Widget? footer;
  final EdgeInsets padding;
  final Color? color;

  const AetherCard({
    super.key,
    this.title,
    this.trailing,
    required this.child,
    this.footer,
    this.padding = const EdgeInsets.all(20),
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    final hasHeader = title != null || trailing != null;
    final resolvedColor = color ?? Aether.surface;
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(AetherRadius.rLg),
        border: Border.all(color: Aether.hairline),
        boxShadow: AetherShadows.shadowS,
      ),
      clipBehavior: Clip.antiAlias,
      child: Material(
        color: resolvedColor,
        borderRadius: BorderRadius.circular(AetherRadius.rLg),
        child: Padding(
          padding: padding,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (hasHeader) ...[
                OverflowBar(
                  alignment: MainAxisAlignment.spaceBetween,
                  overflowAlignment: OverflowBarAlignment.start,
                  spacing: 12,
                  overflowSpacing: 8,
                  children: [
                    if (title != null)
                      DefaultTextStyle.merge(style: AetherType.title, child: title!),
                    ?trailing,
                  ],
                ),
                const SizedBox(height: 12),
                Divider(height: 1, thickness: 1, color: Aether.hairline),
                const SizedBox(height: 12),
              ],
              child,
              if (footer != null) ...[
                const SizedBox(height: 12),
                Divider(height: 1, thickness: 1, color: Aether.hairline),
                const SizedBox(height: 12),
                footer!,
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Soft vertical gradient header, typically used atop screens.
class AetherGradientHeader extends StatelessWidget {
  final Widget child;
  final double height;

  const AetherGradientHeader({
    super.key,
    required this.child,
    this.height = 120,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      height: height,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Aether.surfaceAlt, Aether.bg],
        ),
      ),
      child: child,
    );
  }
}

/// Section eyebrow + optional subtitle. Uppercase, letter-spaced label.
class AetherSectionTitle extends StatelessWidget {
  final String eyebrow;
  final String? subtitle;

  const AetherSectionTitle({
    super.key,
    required this.eyebrow,
    this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          eyebrow.toUpperCase(),
          style: AetherType.label.copyWith(
            letterSpacing: 1.4,
            color: Aether.textFaint,
          ),
        ),
        if (subtitle != null) ...[
          const SizedBox(height: 4),
          Text(subtitle!, style: AetherType.bodyMuted),
        ],
      ],
    );
  }
}

enum _AetherBtnKind { primary, secondary, ghost, danger }

class _AetherButton extends StatelessWidget {
  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final bool loading;
  final double minWidth;
  final _AetherBtnKind kind;

  /// When true, render as a compact square icon action instead of a pill with
  /// label. Used by the chat composer's send/stop control.
  final bool iconOnly;

  /// Side length when [iconOnly] is true.
  final double iconSize;

  /// Tooltip for icon-only buttons; falls back to [label].
  final String? tooltip;

  const _AetherButton({
    required this.label,
    required this.onPressed,
    required this.kind,
    this.icon,
    this.loading = false,
    this.minWidth = 0,
    this.iconOnly = false,
    this.iconSize = 44,
    this.tooltip,
  });

  @override
  Widget build(BuildContext context) {
    final effectiveOnPressed = (loading || onPressed == null) ? null : onPressed;

    if (iconOnly) {
      final fg =
          (kind == _AetherBtnKind.primary || kind == _AetherBtnKind.danger)
          ? Colors.white
          : Aether.text;
      final bg = switch (kind) {
        _AetherBtnKind.primary => effectiveOnPressed == null
            ? Aether.accent.withValues(alpha: 0.4)
            : Aether.accent,
        _AetherBtnKind.danger => effectiveOnPressed == null
            ? Aether.danger.withValues(alpha: 0.4)
            : Aether.danger,
        _AetherBtnKind.secondary => Aether.surfaceAlt,
        _AetherBtnKind.ghost => Colors.transparent,
      };
      final border = switch (kind) {
        _AetherBtnKind.secondary => Border.all(color: Aether.hairlineStrong),
        _AetherBtnKind.ghost => null,
        _ => null,
      };
      final content = loading
          ? SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                valueColor: AlwaysStoppedAnimation<Color>(fg),
              ),
            )
          : Icon(icon ?? Icons.arrow_upward, size: 18, color: fg);
      final btn = Material(
        color: bg,
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: effectiveOnPressed,
          child: Container(
            width: iconSize < 44 ? 44 : iconSize,
            height: iconSize < 44 ? 44 : iconSize,
            alignment: Alignment.center,
            decoration: BoxDecoration(shape: BoxShape.circle, border: border),
            child: ExcludeSemantics(child: content),
          ),
        ),
      );
      final tip = tooltip ?? label;
      final accessible = Semantics(
        container: true,
        button: true,
        enabled: effectiveOnPressed != null,
        label: tip,
        value: loading ? 'Loading' : null,
        liveRegion: loading,
        child: btn,
      );
      return tip.isEmpty
          ? accessible
          : Tooltip(message: tip, excludeFromSemantics: true, child: accessible);
    }

    final child = loading
        ? SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              valueColor: AlwaysStoppedAnimation<Color>(
                kind == _AetherBtnKind.primary || kind == _AetherBtnKind.danger
                    ? Colors.white
                    : Aether.text,
              ),
            ),
          )
        : Row(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (icon != null) ...[
                Icon(icon, size: 16),
                const SizedBox(width: 8),
              ],
              Flexible(
                child: Text(
                  label,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          );

    final content = Center(
      widthFactor: 1,
      heightFactor: 1,
      child: loading
          ? Semantics(
              label: label,
              value: 'Loading',
              liveRegion: true,
              excludeSemantics: true,
              child: child,
            )
          : child,
    );

    Widget button;
    switch (kind) {
      case _AetherBtnKind.primary:
        button = FilledButton(
          onPressed: effectiveOnPressed,
          style: FilledButton.styleFrom(
            backgroundColor: Aether.accent,
            foregroundColor: Colors.white,
            disabledBackgroundColor: Aether.accent.withValues(alpha: 0.4),
            disabledForegroundColor: Colors.white70,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(AetherRadius.rMd),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            minimumSize: Size(minWidth < 44 ? 44 : minWidth, 44),
            visualDensity: VisualDensity.standard,
          ),
          child: content,
        );
        break;
      case _AetherBtnKind.secondary:
        button = OutlinedButton(
          onPressed: effectiveOnPressed,
          style: OutlinedButton.styleFrom(
            foregroundColor: Aether.text,
            side: BorderSide(color: Aether.hairlineStrong),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(AetherRadius.rMd),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            minimumSize: Size(minWidth < 44 ? 44 : minWidth, 44),
            visualDensity: VisualDensity.standard,
          ),
          child: content,
        );
        break;
      case _AetherBtnKind.ghost:
        button = TextButton(
          onPressed: effectiveOnPressed,
          style: TextButton.styleFrom(
            foregroundColor: Aether.textMuted,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(AetherRadius.rMd),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            minimumSize: Size(minWidth < 44 ? 44 : minWidth, 44),
            visualDensity: VisualDensity.standard,
          ),
          child: content,
        );
        break;
      case _AetherBtnKind.danger:
        button = FilledButton(
          onPressed: effectiveOnPressed,
          style: FilledButton.styleFrom(
            backgroundColor: Aether.danger,
            foregroundColor: Colors.white,
            disabledBackgroundColor: Aether.danger.withValues(alpha: 0.4),
            disabledForegroundColor: Colors.white70,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(AetherRadius.rMd),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            minimumSize: Size(minWidth < 44 ? 44 : minWidth, 44),
            visualDensity: VisualDensity.standard,
          ),
          child: content,
        );
        break;
    }

    // Label-mode buttons can carry an explicit tooltip (the old IconButtons
    // did) so controls remain discoverable and existing byTooltip finders keep
    // working. Only wrap when the caller actually asked for one.
    final tip = tooltip;
    if (tip != null && tip.isNotEmpty) {
      return Tooltip(message: tip, excludeFromSemantics: true, child: button);
    }
    return button;
  }
}

/// Solid accent call-to-action.
///
/// Set [iconOnly] to render a compact circular icon action (used by the chat
/// composer's send/stop button). In icon mode [label] is used as the tooltip
/// when [tooltip] is omitted.
class AetherPrimaryButton extends StatelessWidget {
  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final bool loading;
  final double minWidth;
  final bool iconOnly;
  final double iconSize;
  final String? tooltip;

  const AetherPrimaryButton({
    super.key,
    required this.label,
    this.onPressed,
    this.icon,
    this.loading = false,
    this.minWidth = 0,
    this.iconOnly = false,
    this.iconSize = 44,
    this.tooltip,
  });

  @override
  Widget build(BuildContext context) => _AetherButton(
    label: label,
    onPressed: onPressed,
    icon: icon,
    loading: loading,
    minWidth: minWidth,
    iconOnly: iconOnly,
    iconSize: iconSize,
    tooltip: tooltip,
    kind: _AetherBtnKind.primary,
  );
}

/// Outlined secondary action.
class AetherSecondaryButton extends StatelessWidget {
  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final bool loading;
  final double minWidth;

  const AetherSecondaryButton({
    super.key,
    required this.label,
    this.onPressed,
    this.icon,
    this.loading = false,
    this.minWidth = 0,
  });

  @override
  Widget build(BuildContext context) => _AetherButton(
    label: label,
    onPressed: onPressed,
    icon: icon,
    loading: loading,
    minWidth: minWidth,
    kind: _AetherBtnKind.secondary,
  );
}

/// Low-emphasis text-only button.
class AetherGhostButton extends StatelessWidget {
  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final bool loading;
  final double minWidth;
  final bool iconOnly;
  final double iconSize;
  final String? tooltip;

  const AetherGhostButton({
    super.key,
    required this.label,
    this.onPressed,
    this.icon,
    this.loading = false,
    this.minWidth = 0,
    this.iconOnly = false,
    this.iconSize = 40,
    this.tooltip,
  });

  @override
  Widget build(BuildContext context) => _AetherButton(
    label: label,
    onPressed: onPressed,
    icon: icon,
    loading: loading,
    minWidth: minWidth,
    iconOnly: iconOnly,
    iconSize: iconSize,
    tooltip: tooltip,
    kind: _AetherBtnKind.ghost,
  );
}

/// Destructive filled button.
class AetherDangerButton extends StatelessWidget {
  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final bool loading;
  final double minWidth;
  final bool iconOnly;
  final double iconSize;
  final String? tooltip;

  const AetherDangerButton({
    super.key,
    required this.label,
    this.onPressed,
    this.icon,
    this.loading = false,
    this.minWidth = 0,
    this.iconOnly = false,
    this.iconSize = 44,
    this.tooltip,
  });

  @override
  Widget build(BuildContext context) => _AetherButton(
    label: label,
    onPressed: onPressed,
    icon: icon,
    loading: loading,
    minWidth: minWidth,
    iconOnly: iconOnly,
    iconSize: iconSize,
    tooltip: tooltip,
    kind: _AetherBtnKind.danger,
  );
}

/// Standard text input with label, hint, helper, and inline error text.
///
/// Set [showLabel] to false to omit the label row (used by the chat composer
/// where the field surface is self-explanatory). [radius] overrides the
/// field corner radius; [minLines]/[maxLines] enable a multiline composer.
class AetherField extends StatelessWidget {
  final String label;
  final String? hint;
  final String? helper;
  final String? errorText;
  final TextEditingController? controller;
  final TextInputType? keyboardType;
  final bool obscure;
  final Iterable<String>? autofillHints;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;
  final FocusNode? focusNode;
  final bool enabled;
  final int? maxLines;
  final int? minLines;
  final bool showLabel;
  final double? radius;
  final EdgeInsets? contentPadding;
  final Widget? prefixIcon;
  final Widget? suffix;
  final bool autofocus;

  /// Optional key forwarded to the inner [TextField]. Lets callers (e.g. the
  /// chat composer) hand tests a stable handle on the real text field even
  /// though the public widget is the [AetherField] wrapper.
  final Key? fieldKey;

  const AetherField({
    super.key,
    required this.label,
    this.hint,
    this.helper,
    this.errorText,
    this.controller,
    this.keyboardType,
    this.obscure = false,
    this.autofillHints,
    this.onChanged,
    this.onSubmitted,
    this.focusNode,
    this.enabled = true,
    this.maxLines = 1,
    this.minLines,
    this.showLabel = true,
    this.radius,
    this.contentPadding,
    this.prefixIcon,
    this.suffix,
    this.autofocus = false,
    this.fieldKey,
  });

  @override
  Widget build(BuildContext context) {
    final hasError = errorText != null && errorText!.isNotEmpty;
    final r = radius ?? AetherRadius.rMd;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (showLabel) ...[
          ExcludeSemantics(child: Text(label, style: AetherType.label)),
          const SizedBox(height: 6),
        ],
        Semantics(
          label: hasError ? '$label\n$errorText' : label,
          child: TextField(
            key: fieldKey,
            controller: controller,
            focusNode: focusNode,
            enabled: enabled,
            keyboardType: keyboardType,
            obscureText: obscure,
            autofillHints: autofillHints,
            onChanged: onChanged,
            onSubmitted: onSubmitted,
            maxLines: obscure ? 1 : maxLines,
            minLines: obscure ? 1 : minLines,
            autofocus: autofocus,
            style: AetherType.body,
            decoration: InputDecoration(
              filled: true,
              fillColor: Aether.surfaceAlt,
              hintText: hint,
              hintStyle: TextStyle(color: Aether.textFaint, fontSize: 14),
              prefixIcon: prefixIcon,
              suffixIcon: suffix,
              contentPadding:
                  contentPadding ??
                  const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(r),
                borderSide: BorderSide(
                  color: hasError ? Aether.danger : Aether.hairline,
                ),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(r),
                borderSide: BorderSide(
                  color: hasError ? Aether.danger : Aether.accent,
                  width: 1.2,
                ),
              ),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(r),
                borderSide: BorderSide(
                  color: hasError ? Aether.danger : Aether.hairline,
                ),
              ),
            ),
          ),
        ),
        if (hasError) ...[
          const SizedBox(height: 6),
          Semantics(
            liveRegion: true,
            child: Text(
              errorText!,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w500,
                color: Aether.dangerC,
              ),
            ),
          ),
        ] else if (helper != null) ...[
          const SizedBox(height: 6),
          Text(helper!, style: AetherType.caption),
        ],
      ],
    );
  }
}

/// Small colored dot, optionally pulsing for live status.
class AetherStatusDot extends StatefulWidget {
  final Color color;
  final double size;
  final bool pulsing;

  const AetherStatusDot({
    super.key,
    required this.color,
    this.size = 8,
    this.pulsing = false,
  });

  @override
  State<AetherStatusDot> createState() => _AetherStatusDotState();
}

class _AetherStatusDotState extends State<AetherStatusDot>
    with SingleTickerProviderStateMixin {
  AnimationController? _controller;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncPulse();
  }

  @override
  void didUpdateWidget(covariant AetherStatusDot oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncPulse();
  }

  void _syncPulse() {
    final animate = widget.pulsing && !MediaQuery.disableAnimationsOf(context);
    if (animate) {
      if (_controller == null) _startPulse();
      if (!_controller!.isAnimating) _controller!.repeat(reverse: true);
    } else {
      _controller?.stop();
    }
  }

  void _startPulse() {
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final dot = Container(
      width: widget.size,
      height: widget.size,
      decoration: BoxDecoration(
        color: widget.color,
        shape: BoxShape.circle,
      ),
    );
    if (_controller == null || !_controller!.isAnimating) return dot;
    return AnimatedBuilder(
      animation: _controller!,
      builder: (context, _) {
        final t = _controller!.value;
        final opacity = 0.5 + 0.5 * t; // 0.5 -> 1.0
        return Opacity(opacity: opacity, child: dot);
      },
    );
  }
}

/// Rounded pill tag; filled background with 14% tint, outlined otherwise.
class AetherPill extends StatelessWidget {
  final String label;
  final Color? color;
  final bool filled;
  final IconData? icon;

  const AetherPill({
    super.key,
    required this.label,
    this.color,
    this.filled = true,
    this.icon,
  });

  @override
  Widget build(BuildContext context) {
    final c = color ?? Aether.textMuted;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: filled ? c.withValues(alpha: 0.14) : Colors.transparent,
        borderRadius: BorderRadius.circular(AetherRadius.rPill),
        border: Border.all(color: c.withValues(alpha: 0.4)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 12, color: c),
            const SizedBox(width: 4),
          ],
          Text(
            label,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.6,
              color: c,
            ),
          ),
        ],
      ),
    );
  }
}

/// Centered empty-state block (icon + title + optional message/action).
class AetherEmptyState extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? message;
  final Widget? action;

  const AetherEmptyState({
    super.key,
    required this.icon,
    required this.title,
    this.message,
    this.action,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Icon(icon, size: 44, color: Aether.textFaint),
            const SizedBox(height: 16),
            Text(title, style: AetherType.h2, textAlign: TextAlign.center),
            if (message != null) ...[
              const SizedBox(height: 8),
              Text(
                message!,
                style: AetherType.bodyMuted,
                textAlign: TextAlign.center,
              ),
            ],
            if (action != null) ...[
              const SizedBox(height: 20),
              action!,
            ],
          ],
        ),
      ),
    );
  }
}

/// Horizontal pill-tab segmented control.
class AetherSegmentedControl<T> extends StatelessWidget {
  final List<({T value, String label, IconData? icon})> options;
  final T value;
  final ValueChanged<T> onChanged;

  const AetherSegmentedControl({
    super.key,
    required this.options,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: Aether.surfaceAlt,
        borderRadius: BorderRadius.circular(AetherRadius.rPill),
        border: Border.all(color: Aether.hairline),
      ),
      child: Wrap(
        spacing: 4,
        runSpacing: 4,
        children: [
          for (final opt in options)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 2),
              child: _SegItem(
                selected: opt.value == value,
                label: opt.label,
                icon: opt.icon,
                onTap: () => onChanged(opt.value),
              ),
            ),
        ],
      ),
    );
  }
}

class _SegItem extends StatelessWidget {
  final bool selected;
  final String label;
  final IconData? icon;
  final VoidCallback onTap;

  const _SegItem({
    required this.selected,
    required this.label,
    required this.onTap,
    this.icon,
  });

  @override
  Widget build(BuildContext context) {
    final fg = selected ? Aether.text : Aether.textMuted;
    return Semantics(
      button: true,
      selected: selected,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(AetherRadius.rPill),
          child: Container(
            constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            decoration: BoxDecoration(
              color: selected ? Aether.surfaceRaised : Colors.transparent,
              borderRadius: BorderRadius.circular(AetherRadius.rPill),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (icon != null) ...[
                  Icon(icon, size: 14, color: fg),
                  const SizedBox(width: 6),
                ],
                Flexible(
                  child: Text(
                    label,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: fg,
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

/// One-time passcode input with [length] monospace cells.
class AetherOtpField extends StatefulWidget {
  final int length;
  final ValueChanged<String> onChanged;
  final String? errorText;
  final bool enabled;

  const AetherOtpField({
    super.key,
    required this.length,
    required this.onChanged,
    this.errorText,
    this.enabled = true,
  }) : assert(length > 0);

  @override
  State<AetherOtpField> createState() => _AetherOtpFieldState();
}

class _AetherOtpFieldState extends State<AetherOtpField> {
  late final List<TextEditingController> _controllers;
  late final List<FocusNode> _focusNodes;

  @override
  void initState() {
    super.initState();
    _controllers = List.generate(widget.length, (_) => TextEditingController());
    _focusNodes = List.generate(widget.length, (_) => FocusNode());
  }

  @override
  void didUpdateWidget(covariant AetherOtpField oldWidget) {
    super.didUpdateWidget(oldWidget);
    while (_controllers.length < widget.length) {
      _controllers.add(TextEditingController());
      _focusNodes.add(FocusNode());
    }
    if (_controllers.length > widget.length) {
      // EditableText detaches listeners during this frame's rebuild.
      final removedControllers = _controllers.sublist(widget.length);
      final removedNodes = _focusNodes.sublist(widget.length);
      _controllers.removeRange(widget.length, _controllers.length);
      _focusNodes.removeRange(widget.length, _focusNodes.length);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        for (final controller in removedControllers) {
          controller.dispose();
        }
        for (final node in removedNodes) {
          node.dispose();
        }
      });
    }
  }

  @override
  void dispose() {
    for (final c in _controllers) {
      c.dispose();
    }
    for (final f in _focusNodes) {
      f.dispose();
    }
    super.dispose();
  }

  void _emit() {
    final joined = _controllers.map((c) => c.text).join();
    widget.onChanged(joined);
  }

  void _handleChanged(int i, String v) {
    if (v.length > 1) {
      // Pasted or auto-filled block
      final chars = v.split('');
      // A full autofill code replaces the whole code, regardless of focus.
      final start = chars.length >= widget.length ? 0 : i;
      for (var k = 0; k < chars.length && start + k < widget.length; k++) {
        _controllers[start + k].text = chars[k];
      }
      final next = (start + chars.length).clamp(0, widget.length - 1);
      _focusCell(next);
      _emit();
      return;
    }
    if (v.isNotEmpty && i < widget.length - 1) {
      _focusCell(i + 1);
    } else if (v.isEmpty && i > 0) {
      // Soft keyboards send editing updates, not hardware key events.
      _focusCell(i - 1);
    }
    _emit();
  }

  void _focusCell(int i) {
    _controllers[i].selection = TextSelection(
      baseOffset: 0,
      extentOffset: _controllers[i].text.length,
    );
    _focusNodes[i].requestFocus();
  }

  KeyEventResult _handleKey(int i, KeyEvent event) {
    if (widget.enabled &&
        event is KeyDownEvent &&
        event.logicalKey == LogicalKeyboardKey.backspace &&
        _controllers[i].text.isEmpty && i > 0) {
      _controllers[i - 1].clear();
      _focusCell(i - 1);
      _emit();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final hasError = widget.errorText != null && widget.errorText!.isNotEmpty;
    final digitWidth = MediaQuery.textScalerOf(context).scale(20) + 24;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (var i = 0; i < widget.length; i++)
              SizedBox(
                width: digitWidth < 44 ? 44 : digitWidth,
                child: Focus(
                  canRequestFocus: false,
                  onFocusChange: (focused) {
                    if (focused) {
                      _controllers[i].selection = TextSelection(
                        baseOffset: 0,
                        extentOffset: _controllers[i].text.length,
                      );
                    }
                  },
                  onKeyEvent: (_, event) => _handleKey(i, event),
                  child: _OtpCell(
                    label: 'Digit ${i + 1} of ${widget.length}',
                    controller: _controllers[i],
                    focusNode: _focusNodes[i],
                    enabled: widget.enabled,
                    hasError: hasError,
                    onChanged: (v) => _handleChanged(i, v),
                  ),
                ),
              ),
          ],
        ),
        if (hasError) ...[
          const SizedBox(height: 8),
          Semantics(
            liveRegion: true,
            child: Text(
              widget.errorText!,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w500,
                color: Aether.dangerC,
              ),
            ),
          ),
        ],
      ],
    );
  }
}

class _OtpCell extends StatelessWidget {
  final String label;
  final TextEditingController controller;
  final FocusNode focusNode;
  final bool enabled;
  final bool hasError;
  final ValueChanged<String> onChanged;

  const _OtpCell({
    required this.label,
    required this.controller,
    required this.focusNode,
    required this.enabled,
    required this.hasError,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: label,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 52),
        child: TextField(
          controller: controller,
          focusNode: focusNode,
          enabled: enabled,
          keyboardType: TextInputType.number,
          textAlign: TextAlign.center,
          autofillHints: const [AutofillHints.oneTimeCode],
          onTap: () => controller.selection = TextSelection(
            baseOffset: 0,
            extentOffset: controller.text.length,
          ),
          onChanged: onChanged,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          style: const TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.w700,
            fontFamily: 'JetBrainsMono',
          ),
          decoration: InputDecoration(
            counterText: '',
            filled: true,
            fillColor: Aether.surfaceAlt,
            contentPadding: const EdgeInsets.symmetric(vertical: 12),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(AetherRadius.rMd),
              borderSide: BorderSide(
                color: hasError ? Aether.danger : Aether.hairline,
              ),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(AetherRadius.rMd),
              borderSide: BorderSide(
                color: hasError ? Aether.danger : Aether.accent,
                width: 1.2,
              ),
            ),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(AetherRadius.rMd),
              borderSide: BorderSide(
                color: hasError ? Aether.danger : Aether.hairline,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Numeric stepper: `[-] value [+]`, clamped to `[min, max]`.
class AetherStepper extends StatelessWidget {
  final int value;
  final ValueChanged<int> onChanged;
  final int min;
  final int max;
  final String? label;

  const AetherStepper({
    super.key,
    required this.value,
    required this.onChanged,
    this.min = 0,
    this.max = 99,
    this.label,
  });

  @override
  Widget build(BuildContext context) {
    final canDec = value > min;
    final canInc = value < max;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (label != null) ...[
          Text(label!, style: AetherType.label),
          const SizedBox(height: 6),
        ],
        Container(
          decoration: BoxDecoration(
            color: Aether.surfaceAlt,
            borderRadius: BorderRadius.circular(AetherRadius.rMd),
            border: Border.all(color: Aether.hairline),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _stepperBtn(
                icon: Icons.remove,
                onTap: canDec
                    ? () => onChanged((value - 1).clamp(min, max))
                    : null,
              ),
              SizedBox(
                width: 48,
                child: Center(
                  child: Text(
                    '$value',
                    style: AetherType.title.copyWith(
                      fontFamily: 'JetBrainsMono',
                    ),
                  ),
                ),
              ),
              _stepperBtn(
                icon: Icons.add,
                onTap: canInc
                    ? () => onChanged((value + 1).clamp(min, max))
                    : null,
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _stepperBtn({required IconData icon, VoidCallback? onTap}) {
    return IconButton(
      onPressed: onTap,
      tooltip: '${icon == Icons.remove ? 'Decrease' : 'Increase'} ${label ?? 'value'}',
      constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
      visualDensity: VisualDensity.standard,
      icon: Icon(
        icon,
        size: 18,
        color: onTap == null ? Aether.textFaint : Aether.text,
      ),
    );
  }
}

/// Full-screen bottom sheet with drag handle, title, body, and action row.
///
/// Use via `showModalBottomSheet(context: context, builder: (_) => AetherSheet(...))`.
class AetherSheet extends StatelessWidget {
  final String title;
  final Widget child;
  final List<Widget>? actions;

  const AetherSheet({
    super.key,
    required this.title,
    required this.child,
    this.actions,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final media = MediaQuery.of(context);
        // Some existing callers already inset the sheet. Consume only the
        // remaining keyboard obstruction instead of applying it twice.
        final consumed = media.size.height - constraints.maxHeight;
        final keyboardInset = (media.viewInsets.bottom - consumed)
            .clamp(0.0, media.viewInsets.bottom);
        return Padding(
          padding: EdgeInsets.only(bottom: keyboardInset),
          child: SafeArea(
            top: false,
            child: Container(
              decoration: BoxDecoration(
                color: Aether.surface,
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(AetherRadius.rXl),
                ),
                boxShadow: AetherShadows.shadowM,
              ),
              padding: const EdgeInsets.fromLTRB(20, 10, 20, 20),
              child: LayoutBuilder(
                builder: (context, bodyConstraints) {
                  return SingleChildScrollView(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Center(
                          child: Container(
                            width: 36,
                            height: 4,
                            decoration: BoxDecoration(
                              color: Aether.hairlineStrong,
                              borderRadius: BorderRadius.circular(AetherRadius.rPill),
                            ),
                          ),
                        ),
                        const SizedBox(height: 14),
                        Text(title, style: AetherType.h2),
                        const SizedBox(height: 16),
                        // Keep list/Expanded-based bodies bounded, while
                        // allowing the title and actions to scroll when large
                        // text or the keyboard leaves too little room.
                        ConstrainedBox(
                          constraints: BoxConstraints(
                            maxHeight: bodyConstraints.maxHeight,
                          ),
                          child: child,
                        ),
                        if (actions != null && actions!.isNotEmpty) ...[
                          const SizedBox(height: 16),
                          OverflowBar(
                            alignment: MainAxisAlignment.end,
                            overflowAlignment: OverflowBarAlignment.end,
                            spacing: 8,
                            overflowSpacing: 8,
                            children: actions!,
                          ),
                        ],
                      ],
                    ),
                  );
                },
              ),
            ),
          ),
        );
      },
    );
  }
}
