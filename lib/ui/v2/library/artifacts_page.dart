// TODO(l10n): move user-facing copy to the ARB files in the localization pass.
import 'package:flutter/material.dart';

import '../../design/o_components.dart';
import '../../design/o_motion.dart';
import '../../design/o_tokens.dart';

/// The four artifact families shown by the filter chips.
enum V2ArtifactKind { image, document, code, data }

enum V2ArtifactsStatus { loading, content, empty, error }

@immutable
class V2ArtifactItem {
  const V2ArtifactItem({
    required this.id,
    required this.name,
    required this.kind,
    required this.createdAt,
    required this.sizeLabel,
    this.thumbnail,
    this.badge,
    this.live = false,
  });

  final String id;
  final String name;
  final V2ArtifactKind kind;
  final DateTime createdAt;
  final String sizeLabel;
  final ImageProvider? thumbnail;
  final String? badge;
  final bool live;
}

@immutable
class V2ArtifactsData {
  const V2ArtifactsData({
    this.status = V2ArtifactsStatus.content,
    this.artifacts = const <V2ArtifactItem>[],
    this.errorMessage = 'We could not load your artifacts. Check your connection and try again.',
    this.now,
  });

  final V2ArtifactsStatus status;
  final List<V2ArtifactItem> artifacts;
  final String errorMessage;

  /// Injectable clock so relative dates stay stable in tests and previews.
  final DateTime? now;
}

/// Artifacts library: every file Ovid made, grouped by kind.
///
/// Presentational only. The wiring layer owns the list, loading, errors and
/// every navigation callback.
class ArtifactsPage extends StatefulWidget {
  const ArtifactsPage({
    super.key,
    required this.data,
    this.onArtifactTap,
    this.onArtifactMenu,
    this.onNewArtifact,
    this.onSeeIdeas,
    this.onRetry,
    this.onOpenMenu,
    this.onSearch,
    this.onNotifications,
  });

  final V2ArtifactsData data;
  final ValueChanged<V2ArtifactItem>? onArtifactTap;
  final ValueChanged<V2ArtifactItem>? onArtifactMenu;
  final VoidCallback? onNewArtifact;
  final VoidCallback? onSeeIdeas;
  final VoidCallback? onRetry;
  final VoidCallback? onOpenMenu;
  final VoidCallback? onSearch;
  final VoidCallback? onNotifications;

  @override
  State<ArtifactsPage> createState() => _ArtifactsPageState();
}

class _ArtifactsPageState extends State<ArtifactsPage> {
  V2ArtifactKind? _filter;

  List<V2ArtifactItem> get _visible {
    final kind = _filter;
    if (kind == null) return widget.data.artifacts;
    return widget.data.artifacts.where((a) => a.kind == kind).toList();
  }

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    final showFab = widget.data.status == V2ArtifactsStatus.content ||
        widget.data.status == V2ArtifactsStatus.empty;

    return OScaffold(
      appBar: OAppBar(
        title: 'Ovid Si',
        subtitle: 'Artifacts Library',
        showBack: false,
        leading: OIconButton(
          icon: Icons.menu_rounded,
          semanticLabel: 'Open menu',
          onPressed: widget.onOpenMenu,
        ),
        actions: [
          OIconButton(
            icon: Icons.search_rounded,
            semanticLabel: 'Search artifacts',
            onPressed: widget.onSearch,
          ),
          OIconButton(
            icon: Icons.notifications_none_rounded,
            semanticLabel: 'Notifications',
            onPressed: widget.onNotifications,
          ),
        ],
      ),
      floatingActionButton: showFab
          ? Padding(
              padding: const EdgeInsets.only(bottom: OSpace.s),
              child: OButton(
                label: 'New artifact',
                icon: Icons.add_rounded,
                onPressed: widget.onNewArtifact,
              ),
            )
          : null,
      body: OFadeSlide(
        child: OAnimatedSwap(
          child: switch (widget.data.status) {
            V2ArtifactsStatus.loading => const OSkeletonList(rows: 6),
            V2ArtifactsStatus.error => OErrorState(
              message: widget.data.errorMessage,
              onRetry: widget.onRetry,
            ),
            V2ArtifactsStatus.empty => _empty(),
            V2ArtifactsStatus.content => _content(c),
          },
        ),
      ),
    );
  }

  Widget _empty() {
    return OEmptyState(
      icon: Icons.auto_awesome_rounded,
      title: 'Nothing here yet',
      message:
          'Files Ovid makes in chats, Studio, or the browser show up here. Start something and it will appear.',
      action: OButton(
        label: 'See what Ovid can make',
        icon: Icons.arrow_forward_rounded,
        onPressed: widget.onSeeIdeas,
      ),
    );
  }

  Widget _content(OColors c) {
    final items = _visible;
    final rows = <Widget>[];
    for (var i = 0; i < items.length; i += 2) {
      final left = items[i];
      final right = i + 1 < items.length ? items[i + 1] : null;
      rows.add(
        IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(child: _card(c, left)),
              const SizedBox(width: OSpace.m),
              Expanded(
                child: right == null
                    ? const SizedBox.shrink()
                    : _card(c, right),
              ),
            ],
          ),
        ),
      );
    }

    return ListView(
      padding: const EdgeInsets.fromLTRB(
        OSpace.screen,
        OSpace.s,
        OSpace.screen,
        OSpace.huge + OSpace.huge,
      ),
      children: [
        _filters(),
        const SizedBox(height: OSpace.l),
        Row(
          children: [
            Expanded(
              child: OSectionHeader(
                label: 'Recent artifacts',
                padding: EdgeInsets.zero,
              ),
            ),
            Text(
              '${items.length} ${items.length == 1 ? 'item' : 'items'}',
              style: OType.caption.copyWith(color: c.accent),
            ),
          ],
        ),
        const SizedBox(height: OSpace.m),
        if (items.isEmpty)
          _filter == null
              ? OEmptyState(
                  compact: true,
                  icon: Icons.auto_awesome_rounded,
                  title: 'Nothing here yet',
                  message:
                      'Files Ovid makes in chats, Studio, or the browser show up here.',
                  action: OButton(
                    label: 'New artifact',
                    icon: Icons.add_rounded,
                    onPressed: widget.onNewArtifact,
                  ),
                )
              : OEmptyState(
                  compact: true,
                  icon: Icons.filter_alt_off_rounded,
                  title: 'No ${_filterLabel(_filter).toLowerCase()} yet',
                  message: 'Try another filter, or make something new with Ovid.',
                  action: OButton(
                    label: 'Show all artifacts',
                    variant: OButtonVariant.secondary,
                    onPressed: () => setState(() => _filter = null),
                  ),
                )
        else
          OStagger(children: rows),
        const SizedBox(height: OSpace.xl),
        _callout(c),
      ],
    );
  }

  Widget _filters() {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          OChip(
            label: 'All',
            icon: Icons.apps_rounded,
            selected: _filter == null,
            onTap: () => setState(() => _filter = null),
          ),
          const SizedBox(width: OSpace.s),
          for (final kind in V2ArtifactKind.values) ...[
            OChip(
              label: _filterLabel(kind),
              icon: _filterIcon(kind),
              selected: _filter == kind,
              onTap: () => setState(() => _filter = kind),
            ),
            if (kind != V2ArtifactKind.values.last)
              const SizedBox(width: OSpace.s),
          ],
        ],
      ),
    );
  }

  Widget _card(OColors c, V2ArtifactItem item) {
    final ext = _extension(item.name);
    return OCard(
      padding: EdgeInsets.zero,
      onTap: () => widget.onArtifactTap?.call(item),
      semanticLabel:
          '${item.name}, ${_filterLabel(item.kind)}, ${item.sizeLabel}, ${_dateLabel(item.createdAt, widget.data.now ?? DateTime.now())}',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AspectRatio(
            aspectRatio: 4 / 3,
            child: ClipRRect(
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(ORadius.l),
              ),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  _thumb(c, item),
                  if (item.live || item.badge != null)
                    Positioned(
                      top: OSpace.s,
                      left: OSpace.s,
                      right: OSpace.s,
                      child: Wrap(
                        spacing: OSpace.xs,
                        runSpacing: OSpace.xs,
                        children: [
                          if (item.live)
                            _previewPill(
                              c,
                              label: 'Live',
                              icon: null,
                              dotColor: c.success,
                            ),
                          if (item.badge != null)
                            _previewPill(
                              c,
                              label: item.badge!,
                              icon: _filterIcon(item.kind),
                              dotColor: null,
                            ),
                        ],
                      ),
                    ),
                  if (item.badge == null && !item.live)
                    Positioned(
                      bottom: OSpace.s,
                      right: OSpace.s,
                      child: _extensionPill(c, ext),
                    ),
                ],
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(
              OSpace.m,
              0,
              OSpace.xs,
              OSpace.m,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        item.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: OType.bodySm.copyWith(
                          color: c.text,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    OIconButton(
                      icon: Icons.more_vert_rounded,
                      semanticLabel: 'More options for ${item.name}',
                      size: 18,
                      onPressed: () => widget.onArtifactMenu?.call(item),
                    ),
                  ],
                ),
                Row(
                  children: [
                    Icon(
                      _filterIcon(item.kind),
                      size: 14,
                      color: c.accent,
                    ),
                    const SizedBox(width: OSpace.xs),
                    Expanded(
                      child: Text(
                        '$ext · ${item.sizeLabel} · '
                        '${_dateLabel(item.createdAt, widget.data.now ?? DateTime.now())}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: OType.caption.copyWith(color: c.textMuted),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _thumb(OColors c, V2ArtifactItem item) {
    final thumbnail = item.thumbnail;
    if (thumbnail != null) {
      return Image(
        image: thumbnail,
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) => _mockThumb(c, item.kind),
      );
    }
    return _mockThumb(c, item.kind);
  }

  Widget _mockThumb(OColors c, V2ArtifactKind kind) {
    return Container(
      color: c.codeBg,
      child: switch (kind) {
        V2ArtifactKind.image => Center(
          child: Container(
            width: 54,
            height: 54,
            decoration: BoxDecoration(
              color: c.accentSoft,
              borderRadius: BorderRadius.circular(ORadius.m),
              border: Border.all(
                color: c.accentFill.withValues(alpha: 0.35),
              ),
            ),
            child: Icon(Icons.landscape_rounded, size: 28, color: c.accent),
          ),
        ),
        V2ArtifactKind.document => Padding(
          padding: const EdgeInsets.all(OSpace.m),
          child: Container(
            padding: const EdgeInsets.all(OSpace.s),
            decoration: BoxDecoration(
              color: c.surface,
              borderRadius: BorderRadius.circular(ORadius.s),
              border: Border.all(color: c.hairline),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 40,
                  height: 5,
                  decoration: BoxDecoration(
                    color: c.accent,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                const SizedBox(height: OSpace.s),
                _line(c.surfaceRaised, 1),
                const SizedBox(height: 5),
                _line(c.surfaceRaised, 0.86),
                const SizedBox(height: 5),
                _line(c.surfaceRaised, 0.68),
                const Spacer(),
                Icon(Icons.description_rounded, size: 18, color: c.textFaint),
              ],
            ),
          ),
        ),
        V2ArtifactKind.code => Padding(
          padding: const EdgeInsets.all(OSpace.m),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _codeLine(c, 0.52, accent: true),
              const SizedBox(height: 6),
              _codeLine(c, 0.8),
              const SizedBox(height: 6),
              _codeLine(c, 0.66),
              const SizedBox(height: 6),
              _codeLine(c, 0.4, accent: true),
            ],
          ),
        ),
        V2ArtifactKind.data => Padding(
          padding: const EdgeInsets.fromLTRB(
            OSpace.l,
            OSpace.l,
            OSpace.l,
            OSpace.m,
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              for (final (height, color) in [
                (26.0, c.accentFill.withValues(alpha: 0.45)),
                (44.0, c.accentFill),
                (34.0, c.success.withValues(alpha: 0.7)),
                (56.0, c.accentFill),
                (40.0, c.accentFill.withValues(alpha: 0.45)),
              ]) ...[
                Expanded(
                  child: Container(
                    height: height,
                    decoration: BoxDecoration(
                      color: color,
                      borderRadius: BorderRadius.circular(ORadius.s),
                    ),
                  ),
                ),
                const SizedBox(width: OSpace.xs),
              ],
            ],
          ),
        ),
      },
    );
  }

  Widget _line(Color color, double widthFactor) {
    return FractionallySizedBox(
      widthFactor: widthFactor,
      child: Container(
        height: 4,
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(2),
        ),
      ),
    );
  }

  Widget _codeLine(OColors c, double widthFactor, {bool accent = false}) {
    return FractionallySizedBox(
      widthFactor: widthFactor,
      child: Container(
        height: 6,
        decoration: BoxDecoration(
          color: accent
              ? c.accentFill.withValues(alpha: 0.65)
              : c.surfaceRaised,
          borderRadius: BorderRadius.circular(3),
        ),
      ),
    );
  }

  Widget _previewPill(
    OColors c, {
    required String label,
    required IconData? icon,
    required Color? dotColor,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: OSpace.s,
        vertical: OSpace.xs,
      ),
      decoration: BoxDecoration(
        color: c.surfaceRaised,
        borderRadius: BorderRadius.circular(ORadius.pill),
        border: Border.all(color: c.hairline),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (dotColor != null)
            Container(
              width: 6,
              height: 6,
              decoration: BoxDecoration(
                color: dotColor,
                shape: BoxShape.circle,
              ),
            )
          else if (icon != null)
            Icon(icon, size: 11, color: c.textMuted),
          const SizedBox(width: OSpace.xs),
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: OType.overline.copyWith(color: c.text),
            ),
          ),
        ],
      ),
    );
  }

  Widget _extensionPill(OColors c, String ext) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: OSpace.s,
        vertical: OSpace.xs,
      ),
      decoration: BoxDecoration(
        color: c.surfaceRaised,
        borderRadius: BorderRadius.circular(ORadius.pill),
        border: Border.all(color: c.hairline),
      ),
      child: Text(
        ext,
        style: OType.overline.copyWith(color: c.textMuted),
      ),
    );
  }

  Widget _callout(OColors c) {
    return OCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: c.accentSoft,
                  shape: BoxShape.circle,
                ),
                child: Icon(Icons.auto_awesome_rounded, size: 20, color: c.accent),
              ),
              const SizedBox(width: OSpace.m),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Every output, organized',
                      style: OType.bodyStrong.copyWith(color: c.text),
                    ),
                    const SizedBox(height: OSpace.xs),
                    Text(
                      'Files Ovid makes in chats, Studio scripts, or browser runs land here automatically.',
                      style: OType.bodySm.copyWith(color: c.textMuted),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: OSpace.m),
          OButton(
            label: 'See what Ovid can make',
            variant: OButtonVariant.ghost,
            icon: Icons.arrow_forward_rounded,
            onPressed: widget.onSeeIdeas,
          ),
        ],
      ),
    );
  }

  String _filterLabel(V2ArtifactKind? kind) => switch (kind) {
    null => 'All',
    V2ArtifactKind.image => 'Images',
    V2ArtifactKind.document => 'Documents',
    V2ArtifactKind.code => 'Code',
    V2ArtifactKind.data => 'Data',
  };

  IconData _filterIcon(V2ArtifactKind kind) => switch (kind) {
    V2ArtifactKind.image => Icons.image_rounded,
    V2ArtifactKind.document => Icons.description_rounded,
    V2ArtifactKind.code => Icons.code_rounded,
    V2ArtifactKind.data => Icons.table_chart_rounded,
  };

  String _extension(String name) {
    final dot = name.lastIndexOf('.');
    if (dot < 0 || dot == name.length - 1) return 'FILE';
    return name.substring(dot + 1).toUpperCase();
  }

  String _dateLabel(DateTime createdAt, DateTime now) {
    final local = createdAt.toLocal();
    final today = DateTime(now.year, now.month, now.day);
    final day = DateTime(local.year, local.month, local.day);
    final days = today.difference(day).inDays;
    if (days <= 0) return 'Today';
    if (days == 1) return 'Yesterday';
    if (days < 7) return '${days}d ago';
    const months = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    return '${months[local.month - 1]} ${local.day}';
  }
}
