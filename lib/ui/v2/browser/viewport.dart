import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../design/o_components.dart';
import '../../design/o_tokens.dart';

// TODO(l10n): move user-facing copy to the ARB files in the next wave.

/// What the live picture is doing.
///
/// A tab can be open while the picture is still connecting, and a lost
/// picture never closes the page. While waiting or lost, the surface is one
/// centred line plus one retry — no explainer; when the picture is live, the
/// picture itself is the status.
enum V2ViewportStatus {
  /// Connecting: the viewer is attached and the first frame is on its way.
  loading,

  /// Attached but still no picture after the connect window.
  waiting,

  /// Frames are arriving and the page is being drawn.
  live,

  /// The picture stopped; the last frame stays behind the notice.
  streamLost,
}

/// Where Ovid's pointer is, in normalized frame coordinates.
///
/// `0, 0` is the top-left of the live page and `1, 1` the bottom-right, so the
/// wiring layer can pass the server's input coordinates straight through.
@immutable
class V2ViewportCursor {
  const V2ViewportCursor({
    required this.x,
    required this.y,
    this.label = 'Ovid',
  });

  final double x;
  final double y;

  /// Spoken name next to the pointer, e.g. "Ovid".
  final String label;
}

/// The picture of the page Ovid is driving.
///
/// This widget never hosts a WebView and never talks to the network: it only
/// paints an injected [ImageProvider] (a decoded screencast frame) or a calm
/// neutral placeholder. The live adapter owns decoding and input.
///
/// There is no chrome on the picture itself: no status pill, no frame-rate
/// explainer. The page overlays the one take-control pill and, while
/// controlling, the control dock.
class BrowserViewport extends StatelessWidget {
  const BrowserViewport({
    super.key,
    this.frame,
    this.frameImage,
    this.status = V2ViewportStatus.live,
    this.cursor,
    this.controlling = false,
    this.onRetry,
    this.onPageTap,
    this.frameAspectRatio,
    this.fit = BoxFit.contain,
    this.borderRadius = ORadius.l,
  });

  /// Key for the agent cursor marker, for tests and a11y probes.
  static const cursorKey = ValueKey<String>('browser-viewport-cursor');

  /// Key for the stream-lost retry button.
  static const retryKey = ValueKey<String>('browser-viewport-retry');

  /// Key for the "no picture yet" retry button.
  static const waitingRetryKey = ValueKey<String>('browser-viewport-waiting');

  /// Key for the surface that turns a tap into page input while controlling.
  static const pageTapKey = ValueKey<String>('browser-viewport-page-tap');

  /// The latest decoded screencast frame. Null means "no picture yet", which
  /// shows the waiting state instead of inventing page content.
  final ImageProvider? frame;

  /// The same frame as an engine image, when the stream decoder already
  /// produced one.
  ///
  /// MEMORY (browser screencast): the live stream decodes every frame once, at
  /// up to 5 fps. Painting [frame] would decode those bytes a second time and
  /// leave each result in the global image cache (100 MiB by default) until it
  /// is evicted — a browser left open would keep tens of megabytes of frames
  /// alive for no reason. When this is supplied the viewport paints it
  /// directly with [RawImage]: no decode, no cache entry, no second bitmap.
  /// [frame] stays the fallback for decoders that report dimensions without an
  /// engine image.
  final ui.Image? frameImage;

  final V2ViewportStatus status;

  /// Server input position, normalized to the frame.
  final V2ViewportCursor? cursor;

  /// True while this person holds the page.
  final bool controlling;

  final VoidCallback? onRetry;

  /// A tap on the live page while [controlling], in coordinates normalized
  /// to the FRAME (`0..1`), not to the widget box.
  final void Function(double x, double y)? onPageTap;

  /// The page viewport's aspect ratio (`width / height`) from the server, so
  /// a tap on a letterboxed picture lands on the pixel under the finger.
  final double? frameAspectRatio;

  /// How the frame is fitted. `contain` is the default so a screencast is
  /// never cropped, even when the phone's aspect ratio differs.
  final BoxFit fit;

  final double borderRadius;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    final effective = _effectiveStatus;
    final hasFrame =
        effective == V2ViewportStatus.live ||
        effective == V2ViewportStatus.streamLost;

    Widget base;
    if (hasFrame) {
      base = _FrameSurface(frame: frame, frameImage: frameImage, fit: fit);
      if (effective == V2ViewportStatus.live &&
          controlling &&
          onPageTap != null) {
        base = _PageTapSurface(
          aspectRatio: frameAspectRatio,
          onTap: onPageTap!,
          child: base,
        );
      }
    } else if (effective == V2ViewportStatus.loading) {
      base = const _LoadingBody();
    } else {
      base = _NoticeBody(
        title: 'Waiting for the page…',
        actionKey: waitingRetryKey,
        actionLabel: 'Try again',
        onRetry: onRetry,
      );
    }

    return Semantics(
      container: true,
      label: 'Browser view',
      child: LayoutBuilder(
        builder: (context, constraints) {
          final content = ClipRRect(
            borderRadius: BorderRadius.circular(borderRadius),
            child: ColoredBox(
              color: c.surfaceAlt,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  base,
                  if (effective == V2ViewportStatus.streamLost) ...[
                    ColoredBox(color: c.scrim.withValues(alpha: 0.55)),
                    _NoticeBody(
                      title: 'Stream lost',
                      actionKey: retryKey,
                      actionLabel: 'Reconnect',
                      onRetry: onRetry,
                      announce: true,
                    ),
                  ],
                  if (effective == V2ViewportStatus.live && cursor != null)
                    _AgentCursor(cursor: cursor!),
                ],
              ),
            ),
          );
          // A preview or a gallery card may forget to give the viewport a
          // height. Keep rendering instead of throwing from the Stack.
          if (!constraints.hasBoundedHeight) {
            return SizedBox(height: 200, child: content);
          }
          return content;
        },
      ),
    );
  }

  /// `live` without a frame is not a live picture: it is still waiting. The
  /// screen must never paint "Live" over an empty surface.
  V2ViewportStatus get _effectiveStatus {
    if (status == V2ViewportStatus.live && !_hasFrame) {
      return V2ViewportStatus.waiting;
    }
    return status;
  }

  bool get _hasFrame => frameImage != null || frame != null;
}

/// Paints the frame (or the neutral placeholder) without any page chrome.
class _FrameSurface extends StatelessWidget {
  const _FrameSurface({
    required this.frame,
    required this.frameImage,
    required this.fit,
  });

  final ImageProvider? frame;
  final ui.Image? frameImage;
  final BoxFit fit;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    // A decoded frame is painted directly: no image-cache entry and no second
    // decode of the same bytes (see [BrowserViewport.frameImage]).
    final decoded = frameImage;
    if (decoded != null) {
      // RawImage takes no semanticLabel, so the name is wrapped around it.
      // Without this the frame is an unnamed image node to TalkBack.
      return Semantics(
        image: true,
        label: 'Live page',
        child: RawImage(
          image: decoded,
          fit: fit,
          filterQuality: FilterQuality.medium,
        ),
      );
    }
    if (frame == null) return const _Placeholder();
    return Image(
      image: frame!,
      fit: fit,
      gaplessPlayback: true,
      filterQuality: FilterQuality.medium,
      semanticLabel: 'Live page',
      // A corrupt or still-encoding frame must not leave a black hole.
      errorBuilder: (context, error, stackTrace) =>
          ColoredBox(color: c.surfaceAlt, child: const _Placeholder()),
    );
  }
}

class _LoadingBody extends StatelessWidget {
  const _LoadingBody();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: SingleChildScrollView(
        padding: EdgeInsets.all(OSpace.l),
        child: OLoadingState(label: 'Connecting…'),
      ),
    );
  }
}

/// The honest "attached, but no picture yet" and "stream lost" surfaces: one
/// line and one real retry, never a spinner that spins forever.
class _NoticeBody extends StatelessWidget {
  const _NoticeBody({
    required this.title,
    required this.actionKey,
    required this.actionLabel,
    this.onRetry,
    this.announce = false,
  });

  final String title;
  final Key actionKey;
  final String actionLabel;
  final VoidCallback? onRetry;

  /// True for a state that changes while the person is watching (the stream
  /// dropping), so a screen reader announces it instead of staying silent.
  final bool announce;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    return Semantics(
      container: true,
      liveRegion: announce,
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(OSpace.m),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                title,
                textAlign: TextAlign.center,
                style: OType.bodySm.copyWith(
                  color: c.text,
                  fontWeight: FontWeight.w600,
                ),
              ),
              if (onRetry != null) ...[
                const SizedBox(height: OSpace.m),
                OButton(
                  key: actionKey,
                  label: actionLabel,
                  variant: OButtonVariant.secondary,
                  onPressed: onRetry,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Turns a tap into page input. The picture is painted with `contain`, so the
/// tap is mapped through the painted image rect — a tap in the letterbox is
/// ignored rather than clicking an arbitrary page pixel.
class _PageTapSurface extends StatelessWidget {
  const _PageTapSurface({
    required this.aspectRatio,
    required this.onTap,
    required this.child,
  });

  final double? aspectRatio;
  final void Function(double x, double y) onTap;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      key: BrowserViewport.pageTapKey,
      builder: (context, constraints) {
        final size = constraints.biggest;
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapUp: (details) {
            if (!size.width.isFinite || !size.height.isFinite) return;
            final rect = _imageRect(size, aspectRatio);
            final local = details.localPosition;
            if (!rect.contains(local)) return;
            final x = ((local.dx - rect.left) / rect.width).clamp(0.0, 1.0);
            final y = ((local.dy - rect.top) / rect.height).clamp(0.0, 1.0);
            onTap(x, y);
          },
          child: child,
        );
      },
    );
  }

  static Rect _imageRect(Size box, double? aspectRatio) {
    if (box.width <= 0 || box.height <= 0) {
      return Rect.fromLTWH(0, 0, box.width, box.height);
    }
    final ratio =
        (aspectRatio != null && aspectRatio.isFinite && aspectRatio > 0)
        ? aspectRatio
        : box.width / box.height;
    final boxRatio = box.width / box.height;
    if (boxRatio > ratio) {
      final width = box.height * ratio;
      return Rect.fromLTWH((box.width - width) / 2, 0, width, box.height);
    }
    final height = box.width / ratio;
    return Rect.fromLTWH(0, (box.height - height) / 2, box.width, height);
  }
}

/// Calm neutral document. It deliberately contains no sample page, no forms
/// and no secrets: a build that forgot to wire the view cannot look real.
class _Placeholder extends StatelessWidget {
  const _Placeholder();

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(OSpace.l),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.visibility_outlined, size: 24, color: c.textFaint),
            const SizedBox(height: OSpace.s),
            Text(
              'Frame unavailable',
              textAlign: TextAlign.center,
              style: OType.bodySm.copyWith(
                color: c.text,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A small pointer with a short spoken tag. It is decorative for input (the
/// page below owns taps) but still announced, so a screen-reader user knows
/// where Ovid is working.
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
            final x = cursor.x.clamp(0.0, 1.0) * width;
            final y = cursor.y.clamp(0.0, 1.0) * height;
            final left = (x - marker / 2).clamp(0.0, width - marker);
            final top = (y - marker / 2).clamp(0.0, height - marker);
            return Stack(
              children: [
                Positioned(
                  left: left,
                  top: top,
                  child: Semantics(
                    container: true,
                    label: '${cursor.label} cursor',
                    child: ExcludeSemantics(
                      child: Container(
                        key: BrowserViewport.cursorKey,
                        width: marker,
                        height: marker,
                        decoration: BoxDecoration(
                          color: c.accentFill,
                          shape: BoxShape.circle,
                        ),
                        child: Icon(
                          Icons.auto_awesome_rounded,
                          size: 16,
                          color: c.onAccent,
                        ),
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
