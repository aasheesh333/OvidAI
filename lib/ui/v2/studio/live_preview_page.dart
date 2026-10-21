import 'dart:async';

import 'package:flutter/material.dart';

import '../../design/o_components.dart';
import '../../design/o_motion.dart';
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

/// One metric tile inside the previewed site.
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

  /// When the preview URL stops working. When set, the expiry card shows a
  /// live countdown instead of the static [expiresLabel].
  final DateTime? expiresAt;

  /// Real preview pixels from the sandbox. When null, the screen shows either
  /// the injected site fields or a neutral waiting state — never invented
  /// content.
  final ImageProvider? frame;
  final String? errorMessage;

  bool get hasFrame => frame != null;

  /// Real copy for the previewed site. A lone [siteName] is not enough: the
  /// header alone must not be presented as a loaded preview.
  bool get hasSiteCopy =>
      eyebrow.trim().isNotEmpty ||
      headline.trim().isNotEmpty ||
      description.trim().isNotEmpty ||
      primaryCta.trim().isNotEmpty ||
      secondaryCta.trim().isNotEmpty ||
      metrics.isNotEmpty ||
      featureTitle.trim().isNotEmpty ||
      featureBody.trim().isNotEmpty ||
      featureBadge.trim().isNotEmpty;

  /// True only when there is something real to show. Drives the "Live" and
  /// "Online" indicators so they can never describe an empty box.
  bool get hasPreviewContent => hasFrame || hasSiteCopy;
}

/// A phone-sized preview of the site in the workspace.
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
    return OScaffold(
      appBar: OAppBar(
        title: 'Live preview',
        subtitle: hasPreview && data.siteName.isNotEmpty ? data.siteName : null,
        actions: [
          if (hasPreview) ...[
            OIconButton(
              icon: Icons.refresh_rounded,
              semanticLabel: 'Refresh preview',
              tooltip: 'Refresh preview',
              onPressed: onRefresh,
            ),
            OIconButton(
              icon: Icons.open_in_new_rounded,
              semanticLabel: 'Open in browser',
              tooltip: 'Open in browser',
              onPressed: onOpenInBrowser,
            ),
          ],
        ],
      ),
      body: switch (data.status) {
        V2PreviewStatus.loading => _buildLoading(context),
        V2PreviewStatus.error => OErrorState(
          message:
              data.errorMessage ??
              'We could not start your preview. Check your connection and try again.',
          onRetry: onRetry,
        ),
        V2PreviewStatus.empty => OEmptyState(
          icon: Icons.play_circle_outline_rounded,
          title: 'No preview running',
          message: onStart == null
              ? 'A preview cannot be started from here yet.'
              : 'Start a preview to see your site on a phone.',
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
    return SingleChildScrollView(
      padding: const EdgeInsets.all(OSpace.screen),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: const Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              OSkeleton(height: 40, radius: ORadius.m),
              SizedBox(height: OSpace.m),
              OSkeleton(height: 420, radius: ORadius.xl),
              SizedBox(height: OSpace.m),
              OSkeleton(height: 80, radius: ORadius.l),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildContent(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(
        OSpace.screen,
        OSpace.s,
        OSpace.screen,
        OSpace.xxl,
      ),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: OFadeSlide(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _PreviewHeader(data: data),
                const SizedBox(height: OSpace.m),
                _PhoneFrame(data: data, onRetry: onRetry),
                const SizedBox(height: OSpace.m),
                const _ReadOnlyNote(),
                if (data.expiresLabel.isNotEmpty || data.expiresAt != null) ...[
                  const SizedBox(height: OSpace.m),
                  _ExpiryCard(
                    expiresLabel: data.expiresLabel,
                    expiresAt: data.expiresAt,
                    onExtend: onExtend,
                  ),
                ],
                const SizedBox(height: OSpace.m),
                _PreviewActions(
                  onShare: onShareLink,
                  onOpenInBrowser: onOpenInBrowser,
                  onStop: onStop,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _PreviewHeader extends StatelessWidget {
  const _PreviewHeader({required this.data});

  final V2LivePreviewData data;
  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    final live = data.hasPreviewContent;
    return Row(
      children: [
        OPill(
          label: live ? 'Online' : 'Starting',
          tone: live ? OPillTone.success : OPillTone.neutral,
          dot: true,
        ),
        const SizedBox(width: OSpace.s),
        Expanded(
          child: Text(
            live
                ? 'Changes from Studio show up here.'
                : 'Waiting for the first frame from your workspace.',
            style: OType.caption.copyWith(color: c.textMuted),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }
}

class _ReadOnlyNote extends StatelessWidget {
  const _ReadOnlyNote();

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    return Container(
      padding: const EdgeInsets.all(OSpace.m),
      decoration: BoxDecoration(
        color: c.surfaceAlt,
        borderRadius: BorderRadius.circular(ORadius.m),
        border: Border.all(color: c.hairline),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.visibility_outlined, size: 18, color: c.textMuted),
          const SizedBox(width: OSpace.s),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Read-only preview',
                  style: OType.bodySm.copyWith(
                    color: c.text,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  'This is a view-only copy of your site. Edits happen in '
                  'Studio.',
                  style: OType.caption.copyWith(color: c.textMuted),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _PreviewActions extends StatelessWidget {
  const _PreviewActions({this.onShare, this.onOpenInBrowser, this.onStop});

  final VoidCallback? onShare;
  final VoidCallback? onOpenInBrowser;
  final VoidCallback? onStop;

  @override
  Widget build(BuildContext context) {
    final share = OButton(
      label: 'Share preview',
      icon: Icons.share_rounded,
      variant: OButtonVariant.secondary,
      onPressed: onShare,
    );
    final open = OButton(
      label: 'Open in browser',
      semanticLabel: 'Open preview in browser',
      icon: Icons.open_in_new_rounded,
      variant: OButtonVariant.secondary,
      onPressed: onOpenInBrowser,
    );
    final stop = OButton(
      label: 'Stop preview',
      icon: Icons.stop_circle_outlined,
      variant: OButtonVariant.danger,
      onPressed: onStop,
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        // Two labels plus icons ellipsize on a narrow phone or at a large text
        // scale, so the actions stack instead of squeezing.
        final tight =
            constraints.maxWidth < 460 ||
            MediaQuery.textScalerOf(context).scale(1) > 1.3;
        if (tight) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              share,
              const SizedBox(height: OSpace.s),
              open,
              const SizedBox(height: OSpace.s),
              stop,
            ],
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(child: share),
                const SizedBox(width: OSpace.s),
                Expanded(child: open),
              ],
            ),
            const SizedBox(height: OSpace.s),
            stop,
          ],
        );
      },
    );
  }
}

class _PhoneFrame extends StatelessWidget {
  const _PhoneFrame({required this.data, this.onRetry});

  final V2LivePreviewData data;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    return Container(
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(ORadius.xl),
        border: Border.all(color: c.hairlineStrong),
        boxShadow: OShadow.floating,
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _BrowserChrome(url: data.url),
          // Both children sit in the stack so the live chip can grow with the
          // text scale instead of being clipped by a fixed bottom inset.
          Stack(
            alignment: Alignment.bottomCenter,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  OSpace.l,
                  OSpace.l,
                  OSpace.l,
                  OSpace.huge,
                ),
                child: SizedBox(
                  width: double.infinity,
                  child: data.frame != null
                      ? Image(
                          image: data.frame!,
                          fit: BoxFit.cover,
                          gaplessPlayback: true,
                          semanticLabel: data.siteName.isEmpty
                              ? 'Live preview'
                              : 'Live preview of ${data.siteName}',
                          errorBuilder: (context, error, stack) =>
                              _FrameError(onRetry: onRetry),
                        )
                      : data.hasSiteCopy
                      ? _SiteContent(data: data)
                      : _WaitingFrame(onRetry: onRetry),
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(
                  left: OSpace.m,
                  right: OSpace.m,
                  bottom: OSpace.m,
                ),
                child: _LiveChip(live: data.hasPreviewContent),
              ),
            ],
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
            'The preview frame could not load',
            textAlign: TextAlign.center,
            style: OType.body.copyWith(color: c.text),
          ),
          const SizedBox(height: OSpace.xs),
          Text(
            'The sandbox is running but its frame did not arrive.',
            textAlign: TextAlign.center,
            style: OType.caption.copyWith(color: c.textMuted),
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
          const SizedBox(height: OSpace.xs),
          Text(
            'Your site appears here as soon as the workspace starts it.',
            textAlign: TextAlign.center,
            style: OType.caption.copyWith(color: c.textMuted),
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

class _BrowserChrome extends StatelessWidget {
  const _BrowserChrome({required this.url});

  final String url;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    final hasUrl = url.trim().isNotEmpty;
    return Container(
      constraints: const BoxConstraints(minHeight: 44),
      color: c.surfaceAlt,
      padding: const EdgeInsets.symmetric(
        horizontal: OSpace.m,
        vertical: OSpace.xs,
      ),
      child: Row(
        children: [
          for (var i = 0; i < 3; i++) ...[
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                color: c.hairlineStrong,
                shape: BoxShape.circle,
              ),
            ),
            if (i < 2) const SizedBox(width: OSpace.xs),
          ],
          const SizedBox(width: OSpace.m),
          Expanded(
            child: Container(
              constraints: const BoxConstraints(minHeight: 28),
              padding: const EdgeInsets.symmetric(
                horizontal: OSpace.s,
                vertical: 2,
              ),
              decoration: BoxDecoration(
                color: c.surface,
                borderRadius: BorderRadius.circular(ORadius.pill),
                border: Border.all(color: c.hairline),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    hasUrl
                        ? Icons.lock_outline_rounded
                        : Icons.hourglass_empty_rounded,
                    size: 12,
                    color: hasUrl ? c.success : c.textFaint,
                  ),
                  const SizedBox(width: OSpace.xs),
                  Flexible(
                    child: Text(
                      hasUrl ? url : 'Waiting for preview URL',
                      style: OType.caption.copyWith(
                        color: hasUrl ? c.textMuted : c.textFaint,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(width: OSpace.m),
          Icon(Icons.devices_rounded, size: 17, color: c.textMuted),
        ],
      ),
    );
  }
}

class _SiteContent extends StatelessWidget {
  const _SiteContent({required this.data});

  final V2LivePreviewData data;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    final hasActions =
        data.primaryCta.isNotEmpty || data.secondaryCta.isNotEmpty;
    final hasFeature =
        data.featureTitle.isNotEmpty ||
        data.featureBody.isNotEmpty ||
        data.featureBadge.isNotEmpty;
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
            if (data.version.isNotEmpty) OPill(label: data.version),
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
        if (data.metrics.isNotEmpty) ...[
          const SizedBox(height: OSpace.l),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (var i = 0; i < data.metrics.length; i++) ...[
                if (i > 0) const SizedBox(width: OSpace.s),
                Expanded(child: _MetricTile(metric: data.metrics[i])),
              ],
            ],
          ),
        ],
        if (hasFeature) ...[
          const SizedBox(height: OSpace.l),
          _FeatureCard(
            title: data.featureTitle,
            body: data.featureBody,
            badge: data.featureBadge,
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

class _MetricTile extends StatelessWidget {
  const _MetricTile({required this.metric});

  final V2PreviewMetric metric;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    return Container(
      padding: const EdgeInsets.all(OSpace.m),
      decoration: BoxDecoration(
        color: c.surfaceAlt,
        borderRadius: BorderRadius.circular(ORadius.m),
        border: Border.all(color: c.hairline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(metric.icon, size: 14, color: c.success),
              const SizedBox(width: OSpace.xs),
              Flexible(
                child: Text(
                  metric.value,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: OType.caption.copyWith(
                    color: c.success,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: OSpace.xs),
          Text(
            metric.label,
            style: OType.bodySm.copyWith(
              color: c.text,
              fontWeight: FontWeight.w600,
            ),
          ),
          Text(
            metric.caption,
            style: OType.caption.copyWith(color: c.textMuted),
          ),
        ],
      ),
    );
  }
}

class _FeatureCard extends StatelessWidget {
  const _FeatureCard({
    required this.title,
    required this.body,
    required this.badge,
  });

  final String title;
  final String body;
  final String badge;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    return Container(
      decoration: BoxDecoration(
        color: c.surfaceAlt,
        borderRadius: BorderRadius.circular(ORadius.m),
        border: Border.all(color: c.hairline),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            height: 96,
            color: c.surfaceRaised,
            alignment: Alignment.center,
            child: Icon(Icons.hub_outlined, size: 38, color: c.accent),
          ),
          Padding(
            padding: const EdgeInsets.all(OSpace.m),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: OSpace.s,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: c.surface,
                    borderRadius: BorderRadius.circular(ORadius.s),
                    border: Border.all(color: c.hairline),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.tune_rounded, size: 12, color: c.success),
                      const SizedBox(width: OSpace.xs),
                      Flexible(
                        child: Text(
                          badge,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: OType.caption.copyWith(color: c.text),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: OSpace.s),
                Text(
                  title,
                  style: OType.bodySm.copyWith(
                    color: c.text,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(body, style: OType.caption.copyWith(color: c.textMuted)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _LiveChip extends StatelessWidget {
  const _LiveChip({required this.live});

  final bool live;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: OSpace.m,
        vertical: OSpace.s,
      ),
      decoration: BoxDecoration(
        color: c.surfaceRaised,
        borderRadius: BorderRadius.circular(ORadius.pill),
        border: Border.all(color: c.hairlineStrong),
        boxShadow: OShadow.floating,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              color: live ? c.success : c.textFaint,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: OSpace.s),
          Flexible(
            child: Text(
              live
                  ? 'Live · Preview from your workspace'
                  : 'Waiting for the first frame',
              style: OType.caption.copyWith(color: c.text),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}

class _ExpiryCard extends StatelessWidget {
  const _ExpiryCard({
    required this.expiresLabel,
    this.expiresAt,
    this.onExtend,
  });

  final String expiresLabel;
  final DateTime? expiresAt;
  final VoidCallback? onExtend;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    final info = Row(
      children: [
        Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: c.accentSoft,
            shape: BoxShape.circle,
          ),
          child: Icon(Icons.schedule_rounded, size: 20, color: c.accent),
        ),
        const SizedBox(width: OSpace.m),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (expiresAt != null)
                _CountdownLabel(expiresAt: expiresAt!)
              else
                Text(
                  'Expires in $expiresLabel',
                  style: OType.bodySm.copyWith(
                    color: c.text,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              Text(
                'Sandboxed cloud instance',
                style: OType.caption.copyWith(color: c.textMuted),
              ),
            ],
          ),
        ),
      ],
    );
    final extend = OButton(
      label: '+30 min',
      variant: OButtonVariant.ghost,
      onPressed: onExtend,
    );
    return OCard(
      child: LayoutBuilder(
        builder: (context, constraints) {
          // A narrow phone or a large text scale leaves no room for the label
          // beside the button, so the button moves under the text instead of
          // squeezing it.
          final tight =
              constraints.maxWidth < 280 ||
              MediaQuery.textScalerOf(context).scale(1) > 1.3;
          if (!tight) {
            return Row(
              children: [
                Expanded(child: info),
                const SizedBox(width: OSpace.s),
                extend,
              ],
            );
          }
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              info,
              const SizedBox(height: OSpace.s),
              Align(alignment: Alignment.centerRight, child: extend),
            ],
          );
        },
      ),
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
      style: OType.bodySm.copyWith(
        color: expired ? c.danger : c.text,
        fontWeight: FontWeight.w600,
      ),
    );
  }
}
