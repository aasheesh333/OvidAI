import 'dart:async';

import 'package:flutter/material.dart';

import '../../design/o_components.dart';
import '../../design/o_motion.dart';
import '../../design/o_screen.dart';
import '../../design/o_tokens.dart';
import 'step_progress.dart';

// TODO(l10n): move the splash copy (status, error and retry labels) to the ARB
// files.

const String _slowMessage = 'Still starting. Check connection.';

/// Data for the splash screen. The splash owns no navigation: the wiring layer
/// swaps it out when startup finishes, or passes [SplashPage.onReady] when the
/// host wants the screen to advance itself.
@immutable
class V2SplashData {
  const V2SplashData({
    this.progress = 0,
    this.statusLabel = 'Starting your agent',
    this.errorLabel,
  });

  /// Startup progress, 0 to 1, from real completed work. Defaults to the
  /// honest "nothing loaded yet" value; the wiring layer injects real progress.
  /// The splash never advances this on a timer.
  final double progress;

  /// One short line under the wordmark. Six words maximum.
  final String statusLabel;

  /// Set when startup failed. One short line; the splash then shows it with a
  /// retry action instead of the progress line. Longer host copy stays a
  /// single ellipsized line and keeps its full accessible name.
  final String? errorLabel;

  /// A blank error is not a failure: rendering it would paint an empty red
  /// line with a retry that has no message to explain itself.
  bool get hasError => errorLabel != null && errorLabel!.trim().isNotEmpty;

  /// Startup completed. The host normally replaces the splash at this point;
  /// [SplashPage.onReady] covers hosts that prefer to advance from here.
  bool get isReady => !hasError && progress.isFinite && progress >= 1;
}

/// Startup screen: the same mark and wordmark as the welcome step, with the
/// real startup progress docked where every other step puts its action.
///
/// A full-screen state, so it has no header and no step counter: during boot
/// the tour has not started, and a signed-in launch never sees the tour at
/// all. It shares the onboarding gutter, content width and identity block,
/// which is what makes it read as the first screen of the same flow. There are
/// deliberately no actions on the happy path; the only control is the retry
/// shown after a failure or after startup stops making progress.
class SplashPage extends StatefulWidget {
  const SplashPage({
    super.key,
    this.data = const V2SplashData(),
    this.onRetry,
    this.onReady,
    this.slowAfter = const Duration(seconds: 10),
  });

  final V2SplashData data;

  /// Called by the retry action that appears when startup failed or timed out.
  /// When null there is nothing that can retry, so no retry control is
  /// rendered.
  final VoidCallback? onRetry;

  /// Called once per screen when [V2SplashData.isReady] becomes true. The
  /// splash never navigates on its own: a host that replaces the screen can
  /// leave this null; a host that advances from here gets exactly one call,
  /// so a rebuild can never double-navigate.
  final VoidCallback? onReady;

  /// How long startup may make no progress before the splash admits that it is
  /// slow and offers a retry. This is a real elapsed timeout, not a progress
  /// animation. Null disables the watchdog.
  final Duration? slowAfter;

  @override
  State<SplashPage> createState() => _SplashPageState();
}

class _SplashPageState extends State<SplashPage> {
  Timer? _slowTimer;
  bool _slow = false;

  /// Latched for the lifetime of the screen. A ready transition may fire at
  /// most once even if the host rebuilds with the same data or restarts the
  /// boot, so two listeners can never both push a route.
  bool _readyFired = false;

  @override
  void initState() {
    super.initState();
    _armSlowTimer();
    _fireReadyIfNeeded();
  }

  @override
  void didUpdateWidget(covariant SplashPage oldWidget) {
    super.didUpdateWidget(oldWidget);

    final dataChanged =
        oldWidget.data.progress != widget.data.progress ||
        oldWidget.data.statusLabel != widget.data.statusLabel ||
        oldWidget.data.errorLabel != widget.data.errorLabel;
    final timeoutChanged = oldWidget.slowAfter != widget.slowAfter;

    if (widget.data.hasError || widget.data.isReady) {
      // The screen is no longer loading. Never leave a timer armed to replace
      // the error or the ready state with a stale "still starting" message.
      _slowTimer?.cancel();
      _slow = false;
    } else if (dataChanged || timeoutChanged) {
      // Real work moved, or the host restarted startup: the old timeout is
      // stale, so time this phase from zero.
      _slow = false;
      _armSlowTimer();
    }

    _fireReadyIfNeeded();
  }

  @override
  void dispose() {
    _slowTimer?.cancel();
    super.dispose();
  }

  /// Starts the honest slow/offline watchdog. It fires once, after real
  /// elapsed time, and is replaced whenever the host reports progress.
  void _armSlowTimer() {
    _slowTimer?.cancel();
    final after = widget.slowAfter;
    if (after == null || widget.data.hasError || widget.data.isReady) return;
    _slowTimer = Timer(after, () {
      if (!mounted || _slow) return;
      if (widget.data.hasError || widget.data.isReady) return;
      setState(() => _slow = true);
    });
  }

  /// Schedules the single ready callback after the frame that first sees
  /// [V2SplashData.isReady]. The latch is set even when there is no listener,
  /// so a late listener can never make the screen advance twice.
  void _fireReadyIfNeeded() {
    if (!widget.data.isReady || _readyFired) return;
    _readyFired = true;
    if (widget.onReady == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (!widget.data.isReady) return;
      widget.onReady?.call();
    });
  }

  /// Returns to the loading state before asking the host to retry, so a tap
  /// always produces visible movement even when the host's retry keeps the
  /// same progress data.
  void _retry() {
    final retry = widget.onRetry;
    if (retry == null) return;
    if (_slow) setState(() => _slow = false);
    _armSlowTimer();
    retry();
  }

  @override
  Widget build(BuildContext context) {
    final data = widget.data;
    final c = OColors.of(context);
    final Widget footer = data.hasError
        ? _SplashNotice(
            label: data.errorLabel!,
            color: c.danger,
            onRetry: widget.onRetry == null ? null : _retry,
          )
        : _slow
        ? _SplashNotice(
            label: _slowMessage,
            color: c.textMuted,
            onRetry: widget.onRetry == null ? null : _retry,
          )
        : _SplashProgress(
            progress: data.progress,
            label: data.isReady ? 'Ready' : data.statusLabel,
          );

    return OScaffold(
      body: LayoutBuilder(
        builder: (context, constraints) {
          // The identity and the bottom dock share one scroll view: they
          // spread out on a tall screen and scroll instead of clipping when
          // the text scale is large.
          return SingleChildScrollView(
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: constraints.maxHeight),
              child: OContent(
                maxWidth: onboardingContentMaxWidth(
                  MediaQuery.sizeOf(context).width,
                ),
                child: ConstrainedBox(
                  constraints: BoxConstraints(minHeight: constraints.maxHeight),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const SizedBox.shrink(),
                      const OFadeSlide(
                        duration: OMotion.base,
                        child: OnboardingIdentity(),
                      ),
                      Padding(
                        padding: const EdgeInsets.only(bottom: OSpace.m),
                        child: OFadeSlide(
                          duration: OMotion.base,
                          child: footer,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

/// Loading state: one merged announcement for the bar and its label, so a
/// screen reader does not read the same sentence twice.
class _SplashProgress extends StatelessWidget {
  const _SplashProgress({required this.progress, required this.label});

  final double progress;
  final String label;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    final raw = progress.isFinite ? progress : 0.0;
    final value = raw.clamp(0.0, 1.0);
    final percent = (value * 100).round();
    return Semantics(
      container: true,
      label: label,
      value: '$percent percent',
      child: ExcludeSemantics(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // The design-system bar animates its fill. With reduced motion
            // requested, paint the same value statically instead.
            if (OMove.reduced(context))
              _StaticProgressBar(value: value, height: 3)
            else
              OProgressBar(value: value, height: 3),
            const SizedBox(height: OSpace.m),
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: OType.caption.copyWith(color: c.textMuted),
            ),
          ],
        ),
      ),
    );
  }
}

/// Static equivalent of [OProgressBar] for reduced-motion builds. It shows the
/// same real value without a fill animation.
class _StaticProgressBar extends StatelessWidget {
  const _StaticProgressBar({required this.value, required this.height});

  final double value;
  final double height;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    return ClipRRect(
      borderRadius: BorderRadius.circular(ORadius.pill),
      child: SizedBox(
        height: height,
        child: Stack(
          fit: StackFit.expand,
          children: [
            ColoredBox(color: c.surfaceRaised),
            Align(
              alignment: Alignment.centerLeft,
              child: FractionallySizedBox(
                widthFactor: value,
                heightFactor: 1,
                child: ColoredBox(color: c.accentFill),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Error or slow/offline state: one honest line plus the only action that can
/// help. The retry button sits in the same bottom slot as every onboarding
/// primary action.
class _SplashNotice extends StatelessWidget {
  const _SplashNotice({required this.label, required this.color, this.onRetry});

  final String label;
  final Color color;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Semantics(
          container: true,
          liveRegion: true,
          label: label,
          child: ExcludeSemantics(
            child: Text(
              label,
              // Host copy that runs long must stay one line instead of turning
              // the splash into a paragraph; the accessible name keeps the
              // full message.
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: OType.caption.copyWith(color: color),
            ),
          ),
        ),
        // No handler, no control: a visible "Try again" that cannot retry is
        // a dead end dressed up as a recovery path.
        if (onRetry != null) ...[
          const SizedBox(height: OSpace.m),
          OButton(
            key: const Key('splash-retry'),
            label: 'Try again',
            icon: Icons.refresh_rounded,
            variant: OButtonVariant.secondary,
            expand: true,
            onPressed: onRetry,
          ),
        ],
      ],
    );
  }
}
