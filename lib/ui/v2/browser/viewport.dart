import 'package:flutter/material.dart';

import '../../design/o_components.dart';
import '../../design/o_tokens.dart';

// TODO(l10n): move user-facing copy to the ARB files in the next wave.

/// What the live picture is doing.
///
/// The stream is only one part of the browser screen, so this stays separate
/// from the page status: a tab can be open while the picture is still
/// connecting, and a lost picture never closes the page.
enum V2ViewportStatus {
  /// Waiting for the first frame from the cloud browser.
  loading,

  /// Frames are arriving and the page is being drawn.
  live,

  /// The picture stopped; the last frame stays behind a notice.
  streamLost,
}

/// Where Ovid's pointer is, in normalized frame coordinates.
///
/// `0, 0` is the top-left of the live page and `1, 1` the bottom-right, so the
/// wiring layer can pass the server's input coordinates straight through
/// without knowing the size of the viewport. Values outside the range are
/// clamped when painted.
@immutable
class V2ViewportCursor {
  const V2ViewportCursor({
    required this.x,
    required this.y,
    this.label = 'Ovid',
  });

  final double x;
  final double y;

  /// Short tag next to the pointer, e.g. "Ovid" or "Reading".
  final String label;
}

/// The picture of the page Ovid is driving.
///
/// This widget never hosts a WebView and never talks to the network: it only
/// paints an injected [ImageProvider] (a decoded screencast frame) or a calm
/// neutral placeholder. The live adapter owns decoding, credentials and the
/// actual input channel.
///
/// The frame is wrapped in its own chrome:
///
///  * a status strip with the 3–5 fps hint, the connecting state, or the
///    stream-lost state;
///  * Ovid's cursor marker at [cursor];
///  * a tap-to-control overlay while Ovid is driving.
///
/// Give it a bounded height (inside [Expanded] or a [SizedBox]); otherwise it
/// falls back to a 200 dp tall box so previews still render.
class BrowserViewport extends StatelessWidget {
  const BrowserViewport({
    super.key,
    this.frame,
    this.status = V2ViewportStatus.live,
    this.cursor,
    this.controlling = false,
    this.onTakeControl,
    this.onRetry,
    this.fit = BoxFit.contain,
    this.showFpsHint = true,
    this.borderRadius = ORadius.l,
    this.liveLabel = 'Live',
    this.fpsLabel = '3–5 fps',
    this.connectingLabel = 'Connecting…',
    this.loadingLabel = 'Waiting for the first frame…',
    this.streamLostTitle = 'Stream lost',
    this.streamLostMessage =
        'Ovid keeps working. The picture returns on its own, or reconnect now.',
    this.retryLabel = 'Reconnect',
    this.takeControlLabel = 'Take control',
    this.controllingLabel = 'You are controlling',
    this.placeholderTitle = 'The live page shows here',
    this.placeholderMessage =
        'Ovid draws the page it is reading in this space.',
    this.viewSemanticLabel = 'Browser view',
    this.frameSemanticLabel = 'Live page',
  });

  /// Key for the agent cursor marker, for tests and a11y probes.
  static const cursorKey = ValueKey<String>('browser-viewport-cursor');

  /// Key for the tap-to-control overlay.
  static const takeControlKey = ValueKey<String>(
    'browser-viewport-take-control',
  );

  /// Key for the stream-lost retry button.
  static const retryKey = ValueKey<String>('browser-viewport-retry');

  /// The latest decoded screencast frame. Null means "no picture yet", which
  /// shows the neutral placeholder instead of inventing page content.
  final ImageProvider? frame;

  final V2ViewportStatus status;

  /// Server input position, normalized to the frame.
  final V2ViewportCursor? cursor;

  /// True while this person holds the page. The take-control overlay turns
  /// into a quiet "You are controlling" marker.
  final bool controlling;

  final VoidCallback? onTakeControl;
  final VoidCallback? onRetry;

  /// How the frame is fitted. `contain` is the default so a screencast is
  /// never cropped, even when the phone's aspect ratio differs.
  final BoxFit fit;

  final bool showFpsHint;
  final double borderRadius;

  final String liveLabel;
  final String fpsLabel;
  final String connectingLabel;
  final String loadingLabel;
  final String streamLostTitle;
  final String streamLostMessage;
  final String retryLabel;
  final String takeControlLabel;
  final String controllingLabel;
  final String placeholderTitle;
  final String placeholderMessage;
  final String viewSemanticLabel;
  final String frameSemanticLabel;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    final body = ClipRRect(
      borderRadius: BorderRadius.circular(borderRadius),
      child: ColoredBox(
        color: c.surfaceAlt,
        child: Column(
          children: [
            _StatusStrip(
              status: status,
              liveLabel: liveLabel,
              fpsLabel: fpsLabel,
              connectingLabel: connectingLabel,
              streamLostTitle: streamLostTitle,
              showFpsHint: showFpsHint,
            ),
            Expanded(child: _frameArea(context, c)),
          ],
        ),
      ),
    );

    return Semantics(
      container: true,
      label: viewSemanticLabel,
      child: LayoutBuilder(
        builder: (context, constraints) {
          // A preview or a gallery card may forget to give the viewport a
          // height. Keep rendering instead of throwing an unbounded-height
          // error from the Column above.
          if (!constraints.hasBoundedHeight) {
            return SizedBox(height: 200, child: body);
          }
          return body;
        },
      ),
    );
  }

  Widget _frameArea(BuildContext context, OColors c) {
    return Stack(
      fit: StackFit.expand,
      children: [
        switch (status) {
          V2ViewportStatus.loading => _LoadingBody(label: loadingLabel),
          V2ViewportStatus.live => _FrameSurface(
            frame: frame,
            fit: fit,
            frameSemanticLabel: frameSemanticLabel,
            placeholderTitle: placeholderTitle,
            placeholderMessage: placeholderMessage,
          ),
          V2ViewportStatus.streamLost => _FrameSurface(
            frame: frame,
            fit: fit,
            frameSemanticLabel: frameSemanticLabel,
            placeholderTitle: placeholderTitle,
            placeholderMessage: placeholderMessage,
          ),
        },
        if (status == V2ViewportStatus.streamLost) ...[
          ColoredBox(color: c.scrim.withValues(alpha: 0.55)),
          _StreamLostPanel(
            title: streamLostTitle,
            message: streamLostMessage,
            retryLabel: retryLabel,
            onRetry: onRetry,
          ),
        ],
        if (status == V2ViewportStatus.live && cursor != null)
          _AgentCursor(cursor: cursor!),
        if (status == V2ViewportStatus.live && controlling)
          _ControllingBadge(label: controllingLabel),
        if (status == V2ViewportStatus.live &&
            !controlling &&
            onTakeControl != null)
          _TakeControlOverlay(
            label: takeControlLabel,
            onPressed: onTakeControl,
          ),
      ],
    );
  }
}

/// The top strip. It is always present so the person can tell a frozen frame
/// from a page that is simply slow: the fps hint only appears while live.
class _StatusStrip extends StatelessWidget {
  const _StatusStrip({
    required this.status,
    required this.liveLabel,
    required this.fpsLabel,
    required this.connectingLabel,
    required this.streamLostTitle,
    required this.showFpsHint,
  });

  final V2ViewportStatus status;
  final String liveLabel;
  final String fpsLabel;
  final String connectingLabel;
  final String streamLostTitle;
  final bool showFpsHint;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    final showFps =
        status == V2ViewportStatus.live && showFpsHint && fpsLabel.isNotEmpty;
    final (color, text) = switch (status) {
      V2ViewportStatus.loading => (c.warn, connectingLabel),
      V2ViewportStatus.live => (
        c.success,
        showFps ? '$liveLabel · $fpsLabel' : liveLabel,
      ),
      V2ViewportStatus.streamLost => (c.danger, streamLostTitle),
    };
    return Container(
      constraints: const BoxConstraints(minHeight: 32),
      padding: const EdgeInsets.symmetric(
        horizontal: OSpace.m,
        vertical: OSpace.xs,
      ),
      decoration: BoxDecoration(
        color: c.surface,
        border: Border(bottom: BorderSide(color: c.hairline)),
      ),
      child: Row(
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: OSpace.s),
          Expanded(
            child: Text(
              text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: OType.caption.copyWith(
                color: c.text,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          if (showFps) ...[
            const SizedBox(width: OSpace.s),
            Icon(Icons.speed_rounded, size: 14, color: c.textMuted),
          ],
        ],
      ),
    );
  }
}

/// Paints the frame (or the neutral placeholder) without any page chrome.
class _FrameSurface extends StatelessWidget {
  const _FrameSurface({
    required this.frame,
    required this.fit,
    required this.frameSemanticLabel,
    required this.placeholderTitle,
    required this.placeholderMessage,
  });

  final ImageProvider? frame;
  final BoxFit fit;
  final String frameSemanticLabel;
  final String placeholderTitle;
  final String placeholderMessage;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    final placeholder = _Placeholder(
      title: placeholderTitle,
      message: placeholderMessage,
    );
    if (frame == null) return placeholder;

    return Image(
      image: frame!,
      fit: fit,
      gaplessPlayback: true,
      filterQuality: FilterQuality.medium,
      semanticLabel: frameSemanticLabel.isEmpty ? null : frameSemanticLabel,
      excludeFromSemantics: frameSemanticLabel.isEmpty,
      // A corrupt or still-encoding frame must not leave a black hole. Fall
      // back to the same neutral document the un-wired state uses.
      errorBuilder: (context, error, stackTrace) =>
          ColoredBox(color: c.surfaceAlt, child: placeholder),
    );
  }
}

class _LoadingBody extends StatelessWidget {
  const _LoadingBody({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: OColors.of(context).surfaceAlt,
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(OSpace.l),
          child: OLoadingState(label: label),
        ),
      ),
    );
  }
}

/// Calm neutral document. It deliberately contains no sample page, no forms
/// and no secrets: a build that forgot to wire the view cannot look real.
class _Placeholder extends StatelessWidget {
  const _Placeholder({required this.title, required this.message});

  final String title;
  final String message;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(OSpace.l),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                color: c.accentSoft,
                shape: BoxShape.circle,
              ),
              child: Icon(Icons.visibility_outlined, size: 24, color: c.accent),
            ),
            const SizedBox(height: OSpace.m),
            Text(
              title,
              textAlign: TextAlign.center,
              style: OType.bodySm.copyWith(
                color: c.text,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: OSpace.xs),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 280),
              child: Text(
                message,
                textAlign: TextAlign.center,
                style: OType.caption.copyWith(color: c.textMuted),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _StreamLostPanel extends StatelessWidget {
  const _StreamLostPanel({
    required this.title,
    required this.message,
    required this.retryLabel,
    required this.onRetry,
  });

  final String title;
  final String message;
  final String retryLabel;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(OSpace.m),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 320),
          child: Container(
            padding: const EdgeInsets.all(OSpace.m),
            decoration: BoxDecoration(
              color: c.surface,
              borderRadius: BorderRadius.circular(ORadius.m),
              border: Border.all(color: c.hairline),
              boxShadow: OShadow.floating,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.wifi_off_rounded, size: 18, color: c.danger),
                    const SizedBox(width: OSpace.s),
                    Expanded(
                      child: Text(
                        title,
                        style: OType.bodySm.copyWith(
                          color: c.text,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: OSpace.xs),
                Text(
                  message,
                  style: OType.caption.copyWith(color: c.textMuted),
                ),
                const SizedBox(height: OSpace.m),
                OButton(
                  key: BrowserViewport.retryKey,
                  label: retryLabel,
                  icon: Icons.refresh_rounded,
                  variant: OButtonVariant.secondary,
                  expand: true,
                  onPressed: onRetry,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A gradient shelf with the one tap that hands the page over. It sits over
/// the picture but keeps a 48 dp target, and it is absent when the person
/// already holds control.
class _TakeControlOverlay extends StatelessWidget {
  const _TakeControlOverlay({required this.label, required this.onPressed});

  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: Container(
        padding: const EdgeInsets.fromLTRB(
          OSpace.s,
          OSpace.xl,
          OSpace.s,
          OSpace.s,
        ),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Colors.transparent, c.scrim.withValues(alpha: 0.72)],
          ),
        ),
        child: OButton(
          key: BrowserViewport.takeControlKey,
          label: label,
          icon: Icons.front_hand_outlined,
          expand: true,
          onPressed: onPressed,
        ),
      ),
    );
  }
}

class _ControllingBadge extends StatelessWidget {
  const _ControllingBadge({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    return Positioned(
      left: OSpace.s,
      right: OSpace.s,
      bottom: OSpace.s,
      child: Semantics(
        container: true,
        label: label,
        child: ExcludeSemantics(
          child: Container(
            constraints: const BoxConstraints(minHeight: OSpace.touch),
            padding: const EdgeInsets.symmetric(horizontal: OSpace.m),
            decoration: BoxDecoration(
              color: c.surface.withValues(alpha: 0.94),
              borderRadius: BorderRadius.circular(ORadius.m),
              border: Border.all(color: c.accentFill),
            ),
            child: Row(
              children: [
                Icon(Icons.front_hand_rounded, size: 18, color: c.accent),
                const SizedBox(width: OSpace.s),
                Expanded(
                  child: Text(
                    label,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: OType.label.copyWith(color: c.text),
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

/// Glowing pointer with a short tag. It is decorative for input (the page
/// below owns taps) but still announced, so a screen-reader user knows where
/// Ovid is working.
class _AgentCursor extends StatelessWidget {
  const _AgentCursor({required this.cursor});

  final V2ViewportCursor cursor;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    return Positioned.fill(
      child: IgnorePointer(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final width = constraints.maxWidth;
            final height = constraints.maxHeight;
            if (!width.isFinite || !height.isFinite) {
              return const SizedBox.shrink();
            }
            const marker = 18.0;
            const gap = 6.0;
            final hasLabel = width >= 180 && cursor.label.isNotEmpty;
            final labelWidth = hasLabel
                ? (width * 0.42).clamp(48.0, 150.0)
                : 0.0;
            final rowWidth = marker + (hasLabel ? gap + labelWidth : 0.0);
            final x = cursor.x.clamp(0.0, 1.0) * width;
            final y = cursor.y.clamp(0.0, 1.0) * height;
            final labelOnRight = cursor.x <= 0.55;
            final left = labelOnRight
                ? (x - marker / 2).clamp(0.0, width - rowWidth)
                : (x - rowWidth + marker / 2).clamp(0.0, width - rowWidth);
            final top = (y - marker / 2).clamp(0.0, height - marker);

            final dot = Container(
              key: BrowserViewport.cursorKey,
              width: marker,
              height: marker,
              decoration: BoxDecoration(
                color: c.accentFill,
                shape: BoxShape.circle,
                boxShadow: OShadow.glow,
              ),
              child: Icon(
                Icons.auto_awesome_rounded,
                size: 10,
                color: c.onAccent,
              ),
            );
            final tag = Container(
              constraints: BoxConstraints(maxWidth: labelWidth),
              padding: const EdgeInsets.symmetric(
                horizontal: OSpace.s,
                vertical: 2,
              ),
              decoration: BoxDecoration(
                color: c.accentFill,
                borderRadius: BorderRadius.circular(ORadius.s),
              ),
              child: Text(
                cursor.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: OType.caption.copyWith(
                  color: c.onAccent,
                  fontWeight: FontWeight.w600,
                ),
              ),
            );

            return Stack(
              children: [
                Positioned(
                  left: left,
                  top: top,
                  child: Semantics(
                    container: true,
                    label: '${cursor.label} cursor',
                    child: ExcludeSemantics(
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          if (hasLabel && !labelOnRight) ...[
                            tag,
                            const SizedBox(width: gap),
                          ],
                          dot,
                          if (hasLabel && labelOnRight) ...[
                            const SizedBox(width: gap),
                            tag,
                          ],
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}
