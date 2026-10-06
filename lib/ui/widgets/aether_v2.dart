import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart' show OrdinalSortKey;

import '../../core/theme.dart';
import 'aether_primitives.dart';

/// Aether v2 premium primitives.
///
/// Higher-level building blocks that sit on top of the low-level widgets in
/// `aether_primitives.dart` and the tokens in `lib/core/theme.dart`
/// ([Aether], [AetherType], [AetherSpacing], [AetherRadius]). They power the
/// "premium" surfaces — goal/todo/queue/approval docks, context-usage stats,
/// credential entry, loading placeholders, and calm status lines — so those
/// screens stay visually uniform.
///
/// Everything here is token-driven, light/dark aware via [Aether], const
/// where possible, keeps interactive targets at 44px or larger, and carries
/// semantic labels for assistive tech. Animated pieces honor
/// [AetherMotion.reduced] and freeze to a static presentation.

/// Uniform collapsible dock card for goal/todo/queue/approval surfaces.
///
/// The header is a single 44px+ tap target that expands/collapses [child];
/// an optional [trailing] action sits outside the toggle area so activating
/// it never collapses the dock. [priority] feeds a11y ordering (lower sorts
/// earlier). When [statusColor] is set, a status dot leads the title and
/// pulses when [pulsing] is true (frozen under reduced motion).
class AetherDock extends StatefulWidget {
  final String title;
  final Widget child;
  final Widget? trailing;
  final int priority;
  final Color? statusColor;
  final bool pulsing;
  final bool initiallyExpanded;
  final ValueChanged<bool>? onExpansionChanged;
  final String? semanticsLabel;

  const AetherDock({
    super.key,
    required this.title,
    required this.child,
    this.trailing,
    this.priority = 0,
    this.statusColor,
    this.pulsing = false,
    this.initiallyExpanded = true,
    this.onExpansionChanged,
    this.semanticsLabel,
  });

  @override
  State<AetherDock> createState() => _AetherDockState();
}

class _AetherDockState extends State<AetherDock> {
  late bool _expanded = widget.initiallyExpanded;

  @override
  void didUpdateWidget(covariant AetherDock oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.initiallyExpanded != widget.initiallyExpanded) {
      _expanded = widget.initiallyExpanded;
    }
  }

  void _toggle() {
    setState(() => _expanded = !_expanded);
    widget.onExpansionChanged?.call(_expanded);
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      container: true,
      sortKey: OrdinalSortKey(widget.priority.toDouble()),
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(AetherRadius.rLg),
          border: Border.all(color: Aether.hairline),
          boxShadow: AetherShadows.shadowS,
        ),
        clipBehavior: Clip.antiAlias,
        child: Material(
          color: Aether.surface,
          borderRadius: BorderRadius.circular(AetherRadius.rLg),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Semantics(
                      container: true,
                      button: true,
                      expanded: _expanded,
                      label: widget.semanticsLabel ?? widget.title,
                      onTap: _toggle,
                      child: InkWell(
                        excludeFromSemantics: true,
                        onTap: _toggle,
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(minHeight: 44),
                          child: ExcludeSemantics(
                            child: Padding(
                              padding: const EdgeInsets.only(
                                left: AetherSpacing.space4,
                                right: AetherSpacing.space3,
                              ),
                              child: Row(
                                children: [
                                  if (widget.statusColor != null) ...[
                                    AetherStatusDot(
                                      color: widget.statusColor!,
                                      pulsing: widget.pulsing,
                                    ),
                                    const SizedBox(
                                      width: AetherSpacing.space2,
                                    ),
                                  ],
                                  Expanded(
                                    child: Text(
                                      widget.title,
                                      style: AetherType.title,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                  const SizedBox(width: AetherSpacing.space2),
                                  AnimatedRotation(
                                    turns: _expanded ? 0 : -0.25,
                                    duration: const Duration(milliseconds: 200),
                                    curve: Curves.easeOutCubic,
                                    child: Icon(
                                      Icons.expand_more,
                                      size: 20,
                                      color: Aether.textMuted,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  if (widget.trailing != null)
                    Padding(
                      padding: const EdgeInsets.only(
                        right: AetherSpacing.space2,
                      ),
                      child: widget.trailing,
                    ),
                ],
              ),
              AnimatedSize(
                duration: const Duration(milliseconds: 220),
                curve: Curves.easeOutCubic,
                alignment: Alignment.topCenter,
                child: _expanded
                    ? Padding(
                        key: const ValueKey<String>('aether-dock-body'),
                        padding: const EdgeInsets.fromLTRB(
                          AetherSpacing.space4,
                          0,
                          AetherSpacing.space4,
                          AetherSpacing.space4,
                        ),
                        child: widget.child,
                      )
                    : const SizedBox(
                        key: ValueKey<String>('aether-dock-closed'),
                        width: double.infinity,
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Compact one-line stat with a circular context-percentage ring.
///
/// The ring is a monochrome hairline track with an accent arc for [percent]
/// (clamped to 0..1). The stats text stays on one line and ellipsizes.
class AetherMetric extends StatelessWidget {
  final String label;
  final String value;
  final double percent;
  final String? semanticsLabel;

  const AetherMetric({
    super.key,
    required this.label,
    required this.value,
    this.percent = 0,
    this.semanticsLabel,
  });

  @override
  Widget build(BuildContext context) {
    final p = percent.clamp(0.0, 1.0).toDouble();
    final pctText = '${(p * 100).round()}%';
    return Semantics(
      container: true,
      label: semanticsLabel ?? '$label: $value, $pctText',
      child: Row(
        children: [
          Expanded(
            child: ExcludeSemantics(
              child: Text.rich(
                TextSpan(
                  children: [
                    TextSpan(text: label, style: AetherType.label),
                    TextSpan(
                      text: '  $value',
                      style: AetherType.mono.copyWith(
                        fontSize: 13,
                        color: Aether.text,
                      ),
                    ),
                  ],
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
          const SizedBox(width: AetherSpacing.space3),
          ExcludeSemantics(
            child: CustomPaint(
              size: const Size.square(22),
              painter: _AetherRingPainter(
                percent: p,
                trackColor: Aether.hairline,
                color: Aether.accent,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Credential text field with an obscure toggle and a "saved" tick.
///
/// Never-echo semantics: the underlying field stays `obscureText: true` at
/// all times, so assistive tech only ever hears the masked value. Revealing
/// swaps the field's glyphs for an [ExcludeSemantics] overlay of the raw
/// text — the secret never enters the semantics tree. [saved] shows a small
/// confirmation tick next to the label; [errorText] renders inline below.
class AetherSecretField extends StatefulWidget {
  final String label;
  final String? hint;
  final String? errorText;
  final TextEditingController? controller;
  final ValueChanged<String>? onChanged;
  final bool saved;
  final bool canReveal;
  final bool enabled;
  final Iterable<String>? autofillHints;
  final String? semanticsLabel;

  const AetherSecretField({
    super.key,
    required this.label,
    this.hint,
    this.errorText,
    this.controller,
    this.onChanged,
    this.saved = false,
    this.canReveal = true,
    this.enabled = true,
    this.autofillHints,
    this.semanticsLabel,
  });

  @override
  State<AetherSecretField> createState() => _AetherSecretFieldState();
}

class _AetherSecretFieldState extends State<AetherSecretField> {
  TextEditingController? _ownedController;
  bool _revealed = false;

  TextEditingController get _controller =>
      widget.controller ?? (_ownedController ??= TextEditingController());

  @override
  void dispose() {
    _ownedController?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final hasError = widget.errorText != null && widget.errorText!.isNotEmpty;
    final label = widget.semanticsLabel ?? widget.label;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: ExcludeSemantics(
                child: Text(
                  widget.label,
                  style: AetherType.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
            if (widget.saved) ...[
              const SizedBox(width: AetherSpacing.space2),
              Semantics(
                container: true,
                label: 'Saved',
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    ExcludeSemantics(
                      child: Icon(
                        Icons.check_circle,
                        size: 14,
                        color: Aether.successC,
                      ),
                    ),
                    const SizedBox(width: 4),
                    ExcludeSemantics(
                      child: Text(
                        'Saved',
                        style: AetherType.caption.copyWith(
                          color: Aether.successC,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
        const SizedBox(height: 6),
        Semantics(
          label: hasError ? '$label\n${widget.errorText}' : label,
          child: Stack(
            children: [
              TextField(
                controller: _controller,
                enabled: widget.enabled,
                obscureText: true,
                keyboardType: TextInputType.visiblePassword,
                autocorrect: false,
                enableSuggestions: false,
                autofillHints: widget.autofillHints,
                onChanged: widget.onChanged,
                maxLines: 1,
                style: _revealed
                    ? AetherType.body.copyWith(color: Colors.transparent)
                    : AetherType.body,
                cursorColor: _revealed ? Colors.transparent : null,
                decoration: InputDecoration(
                  filled: true,
                  fillColor: Aether.surfaceAlt,
                  hintText: widget.hint,
                  hintStyle: TextStyle(color: Aether.textFaint, fontSize: 14),
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 12,
                  ),
                  suffixIconConstraints: const BoxConstraints(
                    minWidth: 44,
                    minHeight: 44,
                  ),
                  suffixIcon: widget.canReveal
                      ? IconButton(
                          tooltip: _revealed
                              ? 'Hide ${widget.label}'
                              : 'Show ${widget.label}',
                          onPressed: () =>
                              setState(() => _revealed = !_revealed),
                          icon: Icon(
                            _revealed
                                ? Icons.visibility_off_outlined
                                : Icons.visibility_outlined,
                            size: 18,
                            color: Aether.textMuted,
                          ),
                        )
                      : null,
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
              if (_revealed)
                Positioned.fill(
                  child: IgnorePointer(
                    child: ExcludeSemantics(
                      child: Padding(
                        padding: EdgeInsets.only(
                          left: 14,
                          right: widget.canReveal ? 52 : 14,
                        ),
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: ValueListenableBuilder<TextEditingValue>(
                            valueListenable: _controller,
                            builder: (context, value, _) => Text(
                              value.text,
                              style: AetherType.body,
                              maxLines: 1,
                              softWrap: false,
                              overflow: TextOverflow.clip,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
        if (hasError) ...[
          const SizedBox(height: 6),
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

/// Shimmer placeholder block for loading states.
///
/// Sweeps a soft highlight across a [Aether.surfaceAlt] block; freezes to the
/// plain block under reduced motion. [semanticsLabel] defaults to "Loading".
class AetherSkeleton extends StatefulWidget {
  final double width;
  final double height;
  final double radius;
  final String? semanticsLabel;

  const AetherSkeleton({
    super.key,
    this.width = double.infinity,
    this.height = 14,
    this.radius = AetherRadius.rSm,
    this.semanticsLabel,
  });

  @override
  State<AetherSkeleton> createState() => _AetherSkeletonState();
}

class _AetherSkeletonState extends State<AetherSkeleton>
    with SingleTickerProviderStateMixin {
  AnimationController? _controller;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (AetherMotion.reduced(context)) {
      _controller?.stop();
    } else {
      _controller ??= AnimationController(
        vsync: this,
        duration: const Duration(milliseconds: 1400),
      )..repeat();
      if (!_controller!.isAnimating) _controller!.repeat();
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(widget.radius);
    final anim = _controller;
    final Widget block = (anim == null || !anim.isAnimating)
        ? Container(
            width: widget.width,
            height: widget.height,
            decoration: BoxDecoration(
              color: Aether.surfaceAlt,
              borderRadius: radius,
            ),
          )
        : AnimatedBuilder(
            animation: anim,
            builder: (context, _) => Container(
              width: widget.width,
              height: widget.height,
              decoration: BoxDecoration(
                borderRadius: radius,
                gradient: LinearGradient(
                  colors: [
                    Aether.surfaceAlt,
                    Aether.surfaceRaised,
                    Aether.surfaceAlt,
                  ],
                  transform: _ShimmerSlide(anim.value),
                ),
              ),
            ),
          );
    return Semantics(
      label: widget.semanticsLabel ?? 'Loading',
      child: ExcludeSemantics(child: block),
    );
  }
}

/// Slides a gradient horizontally across its rect, used by [AetherSkeleton].
class _ShimmerSlide extends GradientTransform {
  const _ShimmerSlide(this.t);

  final double t;

  @override
  Matrix4? transform(Rect bounds, {TextDirection? textDirection}) {
    return Matrix4.translationValues((t * 2 - 1) * bounds.width, 0.0, 0.0);
  }
}

/// Small accent-arc spinner — a calm alternative to a bare
/// `CircularProgressIndicator`. Freezes to a static arc under reduced motion.
/// [semanticsLabel] defaults to "Loading".
class AetherSpinner extends StatefulWidget {
  final double size;
  final double strokeWidth;
  final Color color;
  final Color? trackColor;
  final String? semanticsLabel;

  const AetherSpinner({
    super.key,
    this.size = 18,
    this.strokeWidth = 2,
    this.color = Aether.accent,
    this.trackColor,
    this.semanticsLabel,
  });

  @override
  State<AetherSpinner> createState() => _AetherSpinnerState();
}

class _AetherSpinnerState extends State<AetherSpinner>
    with SingleTickerProviderStateMixin {
  AnimationController? _controller;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (AetherMotion.reduced(context)) {
      _controller?.stop();
    } else {
      _controller ??= AnimationController(
        vsync: this,
        duration: const Duration(milliseconds: 900),
      )..repeat();
      if (!_controller!.isAnimating) _controller!.repeat();
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final anim = _controller;
    final spinning = anim != null && anim.isAnimating;
    final Widget spinner = spinning
        ? AnimatedBuilder(
            animation: anim,
            builder: (context, _) => CustomPaint(
              size: Size.square(widget.size),
              painter: _AetherSpinnerPainter(
                progress: anim.value,
                color: widget.color,
                trackColor: widget.trackColor ?? Aether.hairline,
                strokeWidth: widget.strokeWidth,
              ),
            ),
          )
        : CustomPaint(
            size: Size.square(widget.size),
            painter: _AetherSpinnerPainter(
              progress: 0.12,
              color: widget.color,
              trackColor: widget.trackColor ?? Aether.hairline,
              strokeWidth: widget.strokeWidth,
            ),
          );
    return Semantics(
      label: widget.semanticsLabel ?? 'Loading',
      child: ExcludeSemantics(child: spinner),
    );
  }
}

/// One-line status row: leading icon (or status dot) + title + optional
/// trailing [action]. Keeps a 44px minimum height, ellipsizes the title, and
/// presents a single calm semantics line for health/status surfaces.
class AetherStateRow extends StatelessWidget {
  final String title;
  final IconData? icon;
  final Color? color;
  final bool pulsing;
  final Widget? action;
  final String? semanticsLabel;

  const AetherStateRow({
    super.key,
    required this.title,
    this.icon,
    this.color,
    this.pulsing = false,
    this.action,
    this.semanticsLabel,
  });

  @override
  Widget build(BuildContext context) {
    return Semantics(
      container: true,
      label: semanticsLabel ?? title,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 44),
        child: Row(
          children: [
            ExcludeSemantics(
              child: icon != null
                  ? Icon(
                      icon,
                      size: 16,
                      color: color ?? Aether.textMuted,
                    )
                  : Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      child: AetherStatusDot(
                        color: color ?? Aether.success,
                        pulsing: pulsing,
                      ),
                    ),
            ),
            const SizedBox(width: AetherSpacing.space2),
            Expanded(
              child: ExcludeSemantics(
                child: Text(
                  title,
                  style: AetherType.body,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
            if (action != null) ...[
              const SizedBox(width: AetherSpacing.space2),
              action!,
            ],
          ],
        ),
      ),
    );
  }
}

/// Monochrome hairline track with an accent arc for [AetherMetric].
class _AetherRingPainter extends CustomPainter {
  const _AetherRingPainter({
    required this.percent,
    required this.trackColor,
    required this.color,
  });

  final double percent;
  final Color trackColor;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    const strokeWidth = 2.5;
    final center = size.center(Offset.zero);
    final radius = (size.shortestSide - strokeWidth) / 2;
    final track = Paint()
      ..color = trackColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth;
    canvas.drawCircle(center, radius, track);
    if (percent <= 0) return;
    final arc = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round;
    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius),
      -math.pi / 2,
      percent * 2 * math.pi,
      false,
      arc,
    );
  }

  @override
  bool shouldRepaint(_AetherRingPainter oldDelegate) =>
      oldDelegate.percent != percent ||
      oldDelegate.trackColor != trackColor ||
      oldDelegate.color != color;
}

/// Rotating accent arc on a hairline track for [AetherSpinner].
class _AetherSpinnerPainter extends CustomPainter {
  const _AetherSpinnerPainter({
    required this.progress,
    required this.color,
    required this.trackColor,
    required this.strokeWidth,
  });

  final double progress;
  final Color color;
  final Color trackColor;
  final double strokeWidth;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final radius = (size.shortestSide - strokeWidth) / 2;
    final track = Paint()
      ..color = trackColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth;
    canvas.drawCircle(center, radius, track);
    final arc = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round;
    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius),
      -math.pi / 2 + progress * 2 * math.pi,
      math.pi * 1.5,
      false,
      arc,
    );
  }

  @override
  bool shouldRepaint(_AetherSpinnerPainter oldDelegate) =>
      oldDelegate.progress != progress ||
      oldDelegate.color != color ||
      oldDelegate.trackColor != trackColor ||
      oldDelegate.strokeWidth != strokeWidth;
}
