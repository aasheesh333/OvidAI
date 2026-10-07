import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/theme.dart';

/// Ovid Si brand mark — the ring (workspace) with the Signal Red square (the
/// agent) at its centre. Geometry follows the brand guidelines v2:
///   ring   : rounded square, 80% of the box, radius 28.6%, stroke 12.9%
///   square : centred, 22.9% of the box, radius 7.1%
///
/// Only the ring and the square ever move; never rotate or distort the mark.
/// All animation respects the platform "reduce motion" setting.
enum OvidMarkVariant { primary, reversed, onRed, monoBlack, monoWhite }

class OvidMark extends StatelessWidget {
  const OvidMark({
    super.key,
    this.size = 48,
    this.variant = OvidMarkVariant.primary,
  });

  final double size;
  final OvidMarkVariant variant;

  @override
  Widget build(BuildContext context) {
    final (Color ring, Color dot) = switch (variant) {
      OvidMarkVariant.primary => (Aether.ink, Aether.signalRed),
      OvidMarkVariant.reversed => (Aether.paper, Aether.signalRed),
      OvidMarkVariant.onRed => (Aether.paper, Aether.ink),
      OvidMarkVariant.monoBlack => (Aether.ink, Aether.ink),
      OvidMarkVariant.monoWhite => (Aether.paper, Aether.paper),
    };
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(
        painter: _OvidMarkPainter(ring: ring, dot: dot),
        isComplex: false,
      ),
    );
  }
}

class _OvidMarkPainter extends CustomPainter {
  const _OvidMarkPainter({required this.ring, required this.dot});

  final Color ring;
  final Color dot;

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.shortestSide;
    final ringRect = RRect.fromRectAndRadius(
      Rect.fromLTWH(0.10 * s, 0.10 * s, 0.80 * s, 0.80 * s),
      Radius.circular(0.286 * s),
    );
    canvas.drawRRect(
      ringRect,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.129 * s
        ..color = ring
        ..strokeJoin = StrokeJoin.round,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(0.386 * s, 0.386 * s, 0.229 * s, 0.229 * s),
        Radius.circular(0.071 * s),
      ),
      Paint()..color = dot,
    );
  }

  @override
  bool shouldRepaint(_OvidMarkPainter old) =>
      old.ring != ring || old.dot != dot;
}

/// Wordmark — "Ovid" in Ink (bold) with "Si" in Signal Red. On dark surfaces
/// pass [onDark] so "Ovid" renders in Paper.
class OvidWordmark extends StatelessWidget {
  const OvidWordmark({super.key, this.size = 26, this.onDark = false});

  final double size;
  final bool onDark;

  @override
  Widget build(BuildContext context) {
    return Text.rich(
      TextSpan(
        children: [
          TextSpan(
            text: 'Ovid ',
            style: TextStyle(
              fontSize: size,
              fontWeight: FontWeight.w700,
              letterSpacing: -0.03 * size,
              color: onDark ? Aether.paper : Aether.ink,
            ),
          ),
          TextSpan(
            text: 'Si',
            style: TextStyle(
              fontSize: size,
              fontWeight: FontWeight.w700,
              letterSpacing: -0.03 * size,
              color: Aether.signalRed,
            ),
          ),
        ],
      ),
      semanticsLabel: Aether.brandName,
    );
  }
}

/// Horizontal lockup — mark + wordmark.
class OvidLockup extends StatelessWidget {
  const OvidLockup({
    super.key,
    this.markSize = 40,
    this.textSize = 26,
    this.onDark = false,
  });

  final double markSize;
  final double textSize;
  final bool onDark;

  @override
  Widget build(BuildContext context) {
    // Scale down to fit narrow widths / large text scales so the lockup never
    // overflows; never upscale (the mark stays crisp at its design size).
    return FittedBox(
      fit: BoxFit.scaleDown,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          OvidMark(
            size: markSize,
            variant: onDark
                ? OvidMarkVariant.reversed
                : OvidMarkVariant.primary,
          ),
          SizedBox(width: markSize * 0.28),
          OvidWordmark(size: textSize, onDark: onDark),
        ],
      ),
    );
  }
}

// ── Motion ─────────────────────────────────────────────────────────────────
// Four of the six brand loops that have a product use: draw-on (splash),
// pulse (idle agent), blink (cursor), chase (loader). 1–3 s ambient, ease
// cubic-bezier(.2,.8,.2,1); frozen to a static mark under reduce-motion.

enum OvidMarkAnimation { drawOn, reveal, pulse, blink, chase }

class OvidMarkAnimated extends StatefulWidget {
  const OvidMarkAnimated({
    super.key,
    this.size = 96,
    this.animation = OvidMarkAnimation.drawOn,
    this.variant = OvidMarkVariant.primary,
  });

  final double size;
  final OvidMarkAnimation animation;
  final OvidMarkVariant variant;

  @override
  State<OvidMarkAnimated> createState() => _OvidMarkAnimatedState();
}

class _OvidMarkAnimatedState extends State<OvidMarkAnimated>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c;

  @override
  void initState() {
    super.initState();
    _c = AnimationController(vsync: this, duration: _duration);
  }

  Duration get _duration => switch (widget.animation) {
    OvidMarkAnimation.drawOn => const Duration(milliseconds: 1400),
    OvidMarkAnimation.reveal => const Duration(milliseconds: 3000),
    OvidMarkAnimation.pulse => const Duration(milliseconds: 1800),
    OvidMarkAnimation.blink => const Duration(milliseconds: 1100),
    OvidMarkAnimation.chase => const Duration(milliseconds: 1600),
  };

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final reduce = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    if (reduce) {
      _c.stop();
      _c.value = 0;
    } else if (!_c.isAnimating) {
      _c.repeat();
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final (Color ring, Color dot) = switch (widget.variant) {
      OvidMarkVariant.primary => (Aether.ink, Aether.signalRed),
      OvidMarkVariant.reversed => (Aether.paper, Aether.signalRed),
      OvidMarkVariant.onRed => (Aether.paper, Aether.ink),
      OvidMarkVariant.monoBlack => (Aether.ink, Aether.ink),
      OvidMarkVariant.monoWhite => (Aether.paper, Aether.paper),
    };
    return SizedBox(
      width: widget.size,
      height: widget.size,
      child: AnimatedBuilder(
        animation: _c,
        builder: (_, _) => CustomPaint(
          painter: _OvidMarkAnimatedPainter(
            ring: ring,
            dot: dot,
            t: _c.value,
            animation: widget.animation,
          ),
        ),
      ),
    );
  }
}

class _OvidMarkAnimatedPainter extends CustomPainter {
  _OvidMarkAnimatedPainter({
    required this.ring,
    required this.dot,
    required this.t,
    required this.animation,
  });

  final Color ring;
  final Color dot;
  final double t;
  final OvidMarkAnimation animation;

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.shortestSide;
    final ringRect = RRect.fromRectAndRadius(
      Rect.fromLTWH(0.10 * s, 0.10 * s, 0.80 * s, 0.80 * s),
      Radius.circular(0.286 * s),
    );
    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.129 * s
      ..color = ring
      ..strokeJoin = StrokeJoin.round;

    final dotRect = Rect.fromLTWH(0.386 * s, 0.386 * s, 0.229 * s, 0.229 * s);
    final dotPaint = Paint()..color = dot;

    switch (animation) {
      case OvidMarkAnimation.drawOn:
      case OvidMarkAnimation.reveal:
        // Ring draws on (0..0.55), then the agent square pops.
        final drawT = (t / 0.55).clamp(0.0, 1.0);
        final metric = (Path()..addRRect(ringRect)).computeMetrics().first;
        canvas.drawPath(metric.extractPath(0, metric.length * drawT), stroke);
        final popT = ((t - 0.45) / 0.25).clamp(0.0, 1.0);
        final scale = popT == 0
            ? 0.0
            : popT < 0.7
            ? popT / 0.7 * 1.25
            : 1.25 - (popT - 0.7) / 0.3 * 0.25;
        _drawDot(canvas, dotRect, dotPaint, scale);
      case OvidMarkAnimation.pulse:
        canvas.drawRRect(ringRect, stroke);
        final scale = 1 + 0.4 * (0.5 - 0.5 * math.cos(2 * math.pi * t));
        _drawDot(canvas, dotRect, dotPaint, scale);
      case OvidMarkAnimation.blink:
        canvas.drawRRect(ringRect, stroke);
        final visible = t < 0.6;
        if (visible) canvas.drawRRect(_dotRrect(dotRect), dotPaint);
      case OvidMarkAnimation.chase:
        // A moving dash segment chases around the ring.
        final metric = (Path()..addRRect(ringRect)).computeMetrics().first;
        const seg = 0.25;
        final start = (t % 1.0) * metric.length;
        final end = start + metric.length * seg;
        if (end <= metric.length) {
          canvas.drawPath(metric.extractPath(start, end), stroke);
        } else {
          canvas.drawPath(metric.extractPath(start, metric.length), stroke);
          canvas.drawPath(metric.extractPath(0, end - metric.length), stroke);
        }
        canvas.drawRRect(_dotRrect(dotRect), dotPaint);
    }
  }

  void _drawDot(Canvas canvas, Rect r, Paint paint, double scale) {
    if (scale <= 0) return;
    final center = r.center;
    canvas.save();
    canvas.translate(center.dx, center.dy);
    canvas.scale(scale);
    canvas.translate(-center.dx, -center.dy);
    canvas.drawRRect(_dotRrect(r), paint);
    canvas.restore();
  }

  RRect _dotRrect(Rect r) =>
      RRect.fromRectAndRadius(r, Radius.circular(r.width * 0.31));

  @override
  bool shouldRepaint(_OvidMarkAnimatedPainter old) =>
      old.t != t || old.ring != ring || old.dot != dot;
}
