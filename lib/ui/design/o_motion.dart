import 'dart:async';

import 'package:flutter/material.dart';

import 'o_tokens.dart';

/// Motion helpers shared by every rebuilt screen.
///
/// Rules:
/// - never block input; the longest entrance is 360 ms;
/// - every helper honours the platform "remove animations" setting;
/// - list stagger is capped so a long list never feels slow.
abstract final class OMove {
  // Reads only the accessibility flag, so a keyboard opening or a rotation
  // (viewInsets / size changes) does not rebuild every animated widget.
  static bool reduced(BuildContext context) =>
      MediaQuery.maybeDisableAnimationsOf(context) ?? false;

  static Duration duration(BuildContext context, Duration value) =>
      reduced(context) ? Duration.zero : value;

  static Widget pageTransition(Animation<double> animation, Widget child) {
    final curved = CurvedAnimation(
      parent: animation,
      curve: OMotion.emphasized,
      reverseCurve: OMotion.exit,
    );
    return FadeTransition(
      opacity: curved,
      child: SlideTransition(
        position: Tween<Offset>(
          begin: const Offset(0, 0.035),
          end: Offset.zero,
        ).animate(curved),
        child: child,
      ),
    );
  }
}

/// Page route used for full-screen pushes.
class OFadeSlideRoute<T> extends PageRouteBuilder<T> {
  OFadeSlideRoute({required WidgetBuilder builder, super.settings})
    : super(
        transitionDuration: OMotion.medium,
        reverseTransitionDuration: OMotion.fast,
        pageBuilder: (context, animation, secondary) => builder(context),
        transitionsBuilder: (context, animation, secondary, child) =>
            OMove.pageTransition(animation, child),
      );
}

/// Route used by bottom sheets that are full pages on small phones.
class OSheetRoute<T> extends PageRouteBuilder<T> {
  OSheetRoute({required WidgetBuilder builder, super.settings})
    : super(
        opaque: false,
        barrierColor: OColors.dark.scrim,
        transitionDuration: OMotion.medium,
        reverseTransitionDuration: OMotion.base,
        pageBuilder: (context, animation, secondary) => builder(context),
        transitionsBuilder: (context, animation, secondary, child) {
          if (OMove.reduced(context)) return child;
          final curved = CurvedAnimation(
            parent: animation,
            curve: OMotion.emphasized,
            reverseCurve: OMotion.exit,
          );
          return SlideTransition(
            position: Tween<Offset>(
              begin: const Offset(0, 0.08),
              end: Offset.zero,
            ).animate(curved),
            child: FadeTransition(opacity: curved, child: child),
          );
        },
      );
}

/// Fades and lifts a child into place. Used for page headers, cards and the
/// first paint of a list row.
class OFadeSlide extends StatefulWidget {
  const OFadeSlide({
    super.key,
    required this.child,
    this.delay = Duration.zero,
    this.duration,
    this.offset = const Offset(0, 0.04),
    this.curve = OMotion.emphasized,
  });

  final Widget child;
  final Duration delay;
  final Duration? duration;
  final Offset offset;
  final Curve curve;

  @override
  State<OFadeSlide> createState() => _OFadeSlideState();
}

class _OFadeSlideState extends State<OFadeSlide> {
  bool _shown = false;
  Timer? _timer;
  bool _scheduled = false;

  @override
  void initState() {
    super.initState();
    if (widget.delay == Duration.zero) _shown = true;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_shown || _scheduled) return;
    _scheduled = true;
    if (OMove.reduced(context)) {
      _shown = true;
      return;
    }
    _timer = Timer(widget.delay, () {
      if (mounted) setState(() => _shown = true);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (OMove.reduced(context)) return widget.child;
    final duration = widget.duration ?? OMotion.medium;
    // Keep the subtree in the semantics tree from the first frame. A delayed
    // fade used to start at opacity 0, which made screen readers skip the
    // content (and any error/retry inside it) until the delay elapsed.
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: _shown ? 1 : 0, end: _shown ? 1 : 0),
      duration: duration,
      curve: widget.curve,
      builder: (context, value, child) => Opacity(
        opacity: value,
        alwaysIncludeSemantics: true,
        child: child,
      ),
      child: AnimatedSlide(
        offset: _shown ? Offset.zero : widget.offset,
        duration: duration,
        curve: widget.curve,
        child: widget.child,
      ),
    );
  }
}

/// Staggers its children. Delay is capped at 400 ms in total.
class OStagger extends StatelessWidget {
  const OStagger({
    super.key,
    required this.children,
    this.initialDelay = Duration.zero,
    this.step = OMotion.stagger,
  });

  final List<Widget> children;
  final Duration initialDelay;
  final Duration step;

  @override
  Widget build(BuildContext context) {
    if (OMove.reduced(context)) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: children,
      );
    }
    var delay = initialDelay;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final child in children)
          Builder(
            builder: (_) {
              final current = delay;
              delay += step;
              final capped = current > const Duration(milliseconds: 400)
                  ? const Duration(milliseconds: 400)
                  : current;
              return OFadeSlide(delay: capped, child: child);
            },
          ),
      ],
    );
  }
}

/// Scale-on-press wrapper. The visual feedback is 3 %, short and subtle.
class OPressable extends StatefulWidget {
  const OPressable({
    super.key,
    required this.child,
    this.onTap,
    this.onLongPress,
    this.scale = 0.97,
    this.semanticLabel,
    this.selected,
  });

  final Widget child;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final double scale;
  final String? semanticLabel;

  /// Selection state for chips and option rows. Null leaves the flag
  /// unspecified so an enclosing [Semantics] can own it.
  final bool? selected;

  @override
  State<OPressable> createState() => _OPressableState();
}

class _OPressableState extends State<OPressable> {
  bool _down = false;

  void _set(bool value) {
    if (widget.onTap == null || _down == value) return;
    setState(() => _down = value);
  }

  @override
  Widget build(BuildContext context) {
    final reduced = OMove.reduced(context);
    final enabled = widget.onTap != null || widget.onLongPress != null;
    return Semantics(
      label: widget.semanticLabel,
      button: enabled,
      enabled: enabled,
      selected: widget.selected,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        onLongPress: widget.onLongPress,
        onTapDown: widget.onTap == null ? null : (_) => _set(true),
        onTapUp: widget.onTap == null ? null : (_) => _set(false),
        onTapCancel: widget.onTap == null ? null : () => _set(false),
        child: AnimatedScale(
          scale: _down && !reduced ? widget.scale : 1,
          duration: OMotion.instant,
          curve: OMotion.standard,
          child: widget.child,
        ),
      ),
    );
  }
}

/// Fade-through switcher used when a screen swaps between loading, content,
/// empty and error without pushing a route.
class OAnimatedSwap extends StatelessWidget {
  const OAnimatedSwap({super.key, required this.child, this.duration});

  final Widget child;
  final Duration? duration;

  @override
  Widget build(BuildContext context) {
    if (OMove.reduced(context)) return child;
    return AnimatedSwitcher(
      duration: duration ?? OMotion.base,
      switchInCurve: OMotion.emphasized,
      switchOutCurve: OMotion.exit,
      transitionBuilder: (child, animation) {
        return FadeTransition(
          opacity: animation,
          child: ScaleTransition(
            scale: Tween<double>(begin: 0.985, end: 1).animate(animation),
            child: child,
          ),
        );
      },
      child: child,
    );
  }
}

/// A soft pulse used by "thinking" and "working" indicators. It stops when the
/// platform asks for reduced motion.
class OPulse extends StatefulWidget {
  const OPulse({
    super.key,
    required this.child,
    this.min = 0.55,
    this.duration = OMotion.ambient,
  });

  final Widget child;
  final double min;
  final Duration duration;

  @override
  State<OPulse> createState() => _OPulseState();
}

class _OPulseState extends State<OPulse> with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: widget.duration,
  );

  @override
  void initState() {
    super.initState();
    _controller.repeat(reverse: true);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Do not keep a ticker running when the platform asks for no motion.
    if (OMove.reduced(context)) {
      _controller.stop();
    } else if (!_controller.isAnimating) {
      _controller.repeat(reverse: true);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (OMove.reduced(context)) return widget.child;
    return FadeTransition(
      opacity: Tween<double>(
        begin: widget.min,
        end: 1,
      ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeInOut)),
      child: widget.child,
    );
  }
}
