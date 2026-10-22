import 'dart:async';

import 'package:flutter/material.dart';

import '../../design/o_components.dart';
import '../../design/o_screen.dart';
import '../../design/o_tokens.dart';

// TODO(l10n): move user-facing copy to the ARB files in the next wave.

/// Formats the time left before a preview expires.
///
/// Hours are shown for long previews, seconds only in the final hour so the
/// countdown visibly moves without shouting.
String formatPreviewCountdown(Duration remaining) {
  if (remaining <= Duration.zero) return 'Expired';
  final hours = remaining.inHours;
  final minutes = remaining.inMinutes % 60;
  final seconds = remaining.inSeconds % 60;
  if (hours > 0) {
    return '${hours}h ${minutes.toString().padLeft(2, '0')}m';
  }
  if (minutes > 0) {
    return '${minutes}m ${seconds.toString().padLeft(2, '0')}s';
  }
  return '${seconds}s';
}

/// What the live preview is doing right now.
enum V2PreviewStatus { loading, content, empty, error }

/// One metric the previewed site reports. Kept for the data contract; the
/// frame shows the site itself, never a dashboard of tiles.
@immutable
class V2PreviewMetric {
  const V2PreviewMetric({
    required this.value,
    required this.label,
    required this.caption,
    this.icon = Icons.bolt_rounded,
  });

  final String value;
  final String label;
  final String caption;
  final IconData icon;
}

/// Everything the live preview needs to render.
///
/// Every string defaults to empty: the copy belongs to the site being
/// previewed, so the wiring layer supplies it. Nothing here is sample data.
@immutable
class V2LivePreviewData {
  const V2LivePreviewData({
    this.status = V2PreviewStatus.content,
    this.siteName = '',
    this.url = '',
    this.version = '',
    this.eyebrow = '',
    this.headline = '',
    this.description = '',
    this.primaryCta = '',
    this.secondaryCta = '',
    this.metrics = const <V2PreviewMetric>[],
    this.featureTitle = '',
    this.featureBody = '',
    this.featureBadge = '',
    this.expiresLabel = '',
    this.expiresAt,
    this.frame,
    this.errorMessage,
  });

  final V2PreviewStatus status;
  final String siteName;
  final String url;
  final String version;
  final String eyebrow;
  final String headline;
  final String description;
  final String primaryCta;
  final String secondaryCta;
  final List<V2PreviewMetric> metrics;
  final String featureTitle;
  final String featureBody;
  final String featureBadge;
  final String expiresLabel;

  /// When the preview URL stops working. When set, the expiry line shows a
  /// live countdown instead of the static [expiresLabel].
  final DateTime? expiresAt;

  /// Real preview pixels from the sandbox. When null, the screen shows either
  /// the injected site fields or a neutral waiting state — never invented
  /// content.
  final ImageProvider? frame;
  final String? errorMessage;

  bool get hasFrame => frame != null;

  /// Real copy for the previewed site. A lone [siteName] is not enough: the
  /// header alone must not be presented as a loaded preview. Metrics and the
  /// feature card are data only — the frame never renders them.
  bool get hasSiteCopy =>
      eyebrow.trim().isNotEmpty ||
      headline.trim().isNotEmpty ||
      description.trim().isNotEmpty ||
      primaryCta.trim().isNotEmpty ||
      secondaryCta.trim().isNotEmpty;

  /// True only when there is something real to show. Drives the status pill so
  /// it can never describe an empty box.
  bool get hasPreviewContent => hasFrame || hasSiteCopy;
}

/// A viewer for the site running in the workspace: header, one frame, one
/// status pill over it.
///
/// It owns no primary action. Share, open and stop are compact secondary
/// controls below the frame and only appear when the wiring layer supplies
/// them.
class V2LivePreviewPage extends StatelessWidget {
  const V2LivePreviewPage({
    super.key,
    required this.data,
    this.onRefresh,
    this.onOpenInBrowser,
    this.onShareLink,
    this.onStop,
    this.onExtend,
    this.onStart,
    this.onRetry,
  });

  final V2LivePreviewData data;
  final VoidCallback? onRefresh;
  final VoidCallback? onOpenInBrowser;
  final VoidCallback? onShareLink;
  final VoidCallback? onStop;
  final VoidCallback? onExtend;
  final VoidCallback? onStart;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final hasPreview = data.status == V2PreviewStatus.content;
    return OScreen(
      title: 'Live preview',
      padding: false,
      actions: [
        if (hasPreview && onRefresh != null)
          OIconButton(
            icon: Icons.refresh_rounded,
            semanticLabel: 'Refresh preview',
            tooltip: 'Refresh',
            onPressed: onRefresh,
          ),
      ],
      child: switch (data.status) {
        V2PreviewStatus.loading => _buildLoading(context),
        V2PreviewStatus.error => OErrorState(
          message: data.errorMessage ?? 'This preview did not start.',
          onRetry: onRetry,
        ),
        V2PreviewStatus.empty => OEmptyState(
          icon: Icons.play_circle_outline_rounded,
          title: 'No preview running',
          message: '',
          action: onStart == null
              ? null
              : OButton(
                  label: 'Start preview',
                  icon: Icons.play_arrow_rounded,
                  onPressed: onStart,
                ),
        ),
        V2PreviewStatus.content => _buildContent(context),
      },
    );
  }

  Widget _buildLoading(BuildContext context) {
    final r = OResponsive.of(context);
    return Padding(
      padding: EdgeInsets.fromLTRB(r.gutter, OSpace.s, r.gutter, OSpace.l),
      child: const _FrameArea(
        child: OSkeleton(height: double.infinity, radius: ORadius.xl),
      ),
    );
  }

  Widget _buildContent(BuildContext context) {
    final hasActions =
        onShareLink != null || onOpenInBrowser != null || onStop != null;
    final expiresLabel = data.expiresLabel.trim();
    final hasExpiry = expiresLabel.isNotEmpty || data.expiresAt != null;
    final url = data.url.trim();
    final r = OResponsive.of(context);
    return Padding(
      padding: EdgeInsets.fromLTRB(r.gutter, OSpace.s, r.gutter, OSpace.l),
      child: OFadeIn(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: _FrameArea(
                child: _Frame(data: data, onRetry: onRetry),
              ),
            ),
            if (url.isNotEmpty || hasExpiry) ...[
              const SizedBox(height: OSpace.s),
              _MetaLine(
                url: url,
                expiresLabel: expiresLabel,
                expiresAt: data.expiresAt,
              ),
            ],
            if (hasActions) ...[
              const SizedBox(height: OSpace.xs),
              _SecondaryActions(
                onShare: onShareLink,
                onOpenInBrowser: onOpenInBrowser,
                onStop: onStop,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// The frame's footprint: all the space under the header, centred, never
/// wider than 16:10 so a wide window letterboxes instead of stretching.
class _FrameArea extends StatelessWidget {
  const _FrameArea({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final maxWidth = constraints.maxWidth;
        final maxHeight = constraints.maxHeight;
        if (!maxWidth.isFinite || !maxHeight.isFinite || maxHeight <= 0) {
          return child;
        }
        const maxAspect = 16 / 10;
        final width = maxWidth / maxHeight > maxAspect
            ? maxHeight * maxAspect
            : maxWidth;
        return Center(
          child: SizedBox(width: width, height: maxHeight, child: child),
        );
      },
    );
  }
}

/// The previewed site and the one status pill over its corner.
class _Frame extends StatelessWidget {
  const _Frame({required this.data, this.onRetry});

  final V2LivePreviewData data;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    final live = data.hasPreviewContent;
    final Widget content;
    if (data.frame != null) {
      content = Image(
        image: data.frame!,
        fit: BoxFit.cover,
        width: double.infinity,
        height: double.infinity,
        gaplessPlayback: true,
        semanticLabel: data.siteName.isEmpty
            ? 'Live preview'
            : 'Live preview of ${data.siteName}',
        errorBuilder: (context, error, stack) => _FrameError(onRetry: onRetry),
      );
    } else if (data.hasSiteCopy) {
      content = SingleChildScrollView(
        padding: const EdgeInsets.all(OSpace.l),
        child: _SiteContent(data: data),
      );
    } else {
      content = _WaitingFrame(onRetry: onRetry);
    }
    return Container(
      key: const Key('preview-frame'),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(ORadius.xl),
        border: Border.all(color: c.hairlineStrong),
      ),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        fit: StackFit.expand,
        children: [
          content,
          Positioned(
            left: OSpace.s,
            top: OSpace.s,
            child: OPill(
              label: live ? 'Online' : 'Starting',
              tone: live ? OPillTone.success : OPillTone.neutral,
              dot: true,
            ),
          ),
        ],
      ),
    );
  }
}

/// Shown when the sandbox frame cannot be decoded. It is explicitly an error,
/// never a blank rectangle that looks loaded.
class _FrameError extends StatelessWidget {
  const _FrameError({this.onRetry});

  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    return ConstrainedBox(
      key: const Key('preview-frame-error'),
      constraints: const BoxConstraints(minHeight: 260),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.broken_image_outlined, size: 40, color: c.danger),
          const SizedBox(height: OSpace.m),
          Text(
            'Frame did not load',
            textAlign: TextAlign.center,
            style: OType.body.copyWith(color: c.text),
          ),
          if (onRetry != null) ...[
            const SizedBox(height: OSpace.m),
            OButton(
              label: 'Try again',
              variant: OButtonVariant.secondary,
              onPressed: onRetry,
            ),
          ],
        ],
      ),
    );
  }
}

class _WaitingFrame extends StatelessWidget {
  const _WaitingFrame({this.onRetry});

  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    return ConstrainedBox(
      key: const Key('preview-waiting-frame'),
      constraints: const BoxConstraints(minHeight: 260),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.phone_iphone_rounded, size: 40, color: c.textFaint),
          const SizedBox(height: OSpace.m),
          Text(
            'Waiting for the first frame',
            textAlign: TextAlign.center,
            style: OType.body.copyWith(color: c.text),
          ),
          if (onRetry != null) ...[
            const SizedBox(height: OSpace.m),
            OButton(
              label: 'Check again',
              variant: OButtonVariant.secondary,
              onPressed: onRetry,
            ),
          ],
        ],
      ),
    );
  }
}

/// The site itself when no screenshot has arrived yet: name, headline and
/// its own calls to action. Metrics and feature cards are not re-drawn here —
/// the frame is the preview, not a dashboard about it.
class _SiteContent extends StatelessWidget {
  const _SiteContent({required this.data});

  final V2LivePreviewData data;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    final hasActions =
        data.primaryCta.isNotEmpty || data.secondaryCta.isNotEmpty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(
              width: 30,
              height: 30,
              decoration: BoxDecoration(
                color: c.accentFill,
                borderRadius: BorderRadius.circular(ORadius.s),
              ),
              child: Icon(Icons.cloud_rounded, size: 18, color: c.onAccent),
            ),
            const SizedBox(width: OSpace.s),
            Expanded(
              child: Text(
                data.siteName,
                style: OType.h3.copyWith(color: c.text),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (data.version.isNotEmpty)
              // Flexible so a 200 % text scale shrinks the pill instead of
              // pushing the row past its width.
              Flexible(child: OPill(label: data.version)),
          ],
        ),
        if (data.eyebrow.isNotEmpty) ...[
          const SizedBox(height: OSpace.l),
          Text(
            data.eyebrow.toUpperCase(),
            style: OType.overline.copyWith(color: c.accent),
          ),
        ],
        if (data.headline.isNotEmpty) ...[
          const SizedBox(height: OSpace.s),
          Text(data.headline, style: OType.h1.copyWith(color: c.text)),
        ],
        if (data.description.isNotEmpty) ...[
          const SizedBox(height: OSpace.s),
          Text(
            data.description,
            style: OType.bodySm.copyWith(color: c.textMuted),
          ),
        ],
        if (hasActions) ...[
          const SizedBox(height: OSpace.l),
          Wrap(
            spacing: OSpace.s,
            runSpacing: OSpace.s,
            children: [
              if (data.primaryCta.isNotEmpty)
                _SiteButton(label: data.primaryCta, primary: true),
              if (data.secondaryCta.isNotEmpty)
                _SiteButton(label: data.secondaryCta),
            ],
          ),
        ],
      ],
    );
  }
}

class _SiteButton extends StatelessWidget {
  const _SiteButton({required this.label, this.primary = false});

  final String label;
  final bool primary;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    return Container(
      constraints: const BoxConstraints(minHeight: 44),
      padding: const EdgeInsets.symmetric(
        horizontal: OSpace.l,
        vertical: OSpace.s,
      ),
      decoration: BoxDecoration(
        color: primary ? c.accentFill : c.surfaceAlt,
        borderRadius: BorderRadius.circular(ORadius.pill),
        border: primary ? null : Border.all(color: c.hairline),
      ),
      alignment: Alignment.center,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: Text(
              label,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: OType.label.copyWith(color: primary ? c.onAccent : c.text),
            ),
          ),
          if (primary) ...[
            const SizedBox(width: OSpace.xs),
            Icon(Icons.arrow_forward_rounded, size: 16, color: c.onAccent),
          ],
        ],
      ),
    );
  }
}

/// The one line under the frame: the real url on the left, the expiry on the
/// right. No card, no explainer.
class _MetaLine extends StatelessWidget {
  const _MetaLine({
    required this.url,
    required this.expiresLabel,
    this.expiresAt,
  });

  final String url;
  final String expiresLabel;
  final DateTime? expiresAt;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    final hasExpiry = expiresLabel.isNotEmpty || expiresAt != null;
    return Row(
      children: [
        if (url.isNotEmpty) ...[
          Icon(Icons.lock_outline_rounded, size: 14, color: c.success),
          const SizedBox(width: OSpace.xs),
          Flexible(
            child: Text(
              url,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: OType.caption.copyWith(color: c.textMuted),
            ),
          ),
          const SizedBox(width: OSpace.m),
        ] else
          const Spacer(),
        if (hasExpiry)
          Flexible(
            child: _ExpiryLine(
              expiresLabel: expiresLabel,
              expiresAt: expiresAt,
            ),
          ),
      ],
    );
  }
}

/// One compact expiry readout. No button, no card.
class _ExpiryLine extends StatelessWidget {
  const _ExpiryLine({required this.expiresLabel, this.expiresAt});

  final String expiresLabel;
  final DateTime? expiresAt;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.schedule_rounded, size: 16, color: c.textMuted),
        const SizedBox(width: OSpace.xs),
        Flexible(
          child: expiresAt != null
              ? _CountdownLabel(expiresAt: expiresAt!)
              : Text(
                  'Expires in $expiresLabel',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: OType.caption.copyWith(color: c.textMuted),
                ),
        ),
      ],
    );
  }
}

class _SecondaryActions extends StatelessWidget {
  const _SecondaryActions({this.onShare, this.onOpenInBrowser, this.onStop});

  final VoidCallback? onShare;
  final VoidCallback? onOpenInBrowser;
  final VoidCallback? onStop;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: OSpace.s,
      runSpacing: OSpace.xs,
      children: [
        if (onShare != null)
          OTextAction(
            label: 'Share',
            icon: Icons.share_rounded,
            onPressed: onShare,
          ),
        if (onOpenInBrowser != null)
          OTextAction(
            label: 'Open',
            icon: Icons.open_in_new_rounded,
            onPressed: onOpenInBrowser,
          ),
        if (onStop != null)
          OTextAction(
            label: 'Stop',
            icon: Icons.stop_circle_outlined,
            onPressed: onStop,
          ),
      ],
    );
  }
}

/// A ticking "Expires in …" label.
///
/// The remaining time is captured when the widget mounts and decremented on
/// each tick, so a rebuild or a resumed app does not reset the countdown.
class _CountdownLabel extends StatefulWidget {
  const _CountdownLabel({required this.expiresAt});

  final DateTime expiresAt;

  @override
  State<_CountdownLabel> createState() => _CountdownLabelState();
}

class _CountdownLabelState extends State<_CountdownLabel> {
  Timer? _timer;
  late Duration _remaining;

  @override
  void initState() {
    super.initState();
    _remaining = widget.expiresAt.difference(DateTime.now());
    _startIfNeeded();
  }

  @override
  void didUpdateWidget(_CountdownLabel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.expiresAt != widget.expiresAt) {
      _timer?.cancel();
      _timer = null;
      _remaining = widget.expiresAt.difference(DateTime.now());
      _startIfNeeded();
    }
  }

  void _startIfNeeded() {
    if (_remaining <= Duration.zero) {
      _remaining = Duration.zero;
      return;
    }
    _timer = Timer.periodic(const Duration(seconds: 1), _tick);
  }

  void _tick(Timer timer) {
    final next = _remaining - const Duration(seconds: 1);
    if (next <= Duration.zero) {
      timer.cancel();
      _timer = null;
      if (!mounted) return;
      setState(() => _remaining = Duration.zero);
      return;
    }
    if (!mounted) return;
    setState(() => _remaining = next);
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    final expired = _remaining <= Duration.zero;
    return Text(
      expired ? 'Expired' : 'Expires in ${formatPreviewCountdown(_remaining)}',
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: OType.caption.copyWith(
        color: expired ? c.danger : c.textMuted,
        fontWeight: FontWeight.w600,
      ),
    );
  }
}
