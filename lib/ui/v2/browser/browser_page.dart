import 'package:flutter/material.dart';

import '../../design/o_components.dart';
import '../../design/o_motion.dart';
import '../../design/o_tokens.dart';

// TODO(l10n): move user-facing copy to the ARB files in the next wave.

/// Visual state of the browser screen. The page keeps its tab strip in every
/// state so the user can always see what Ovid has open.
enum V2BrowserStatus { loading, empty, error, content }

/// How healthy the live picture is. The stream can recover on its own, so this
/// is separate from the page status.
enum V2BrowserConnection { live, reconnecting, offline }

/// One step Ovid took while driving the page.
enum V2BrowserActionState { done, active, waiting }

@immutable
class V2BrowserAction {
  const V2BrowserAction({
    required this.id,
    required this.label,
    this.detail = '',
    this.timeLabel = '',
    this.state = V2BrowserActionState.done,
  });

  final String id;
  final String label;
  final String detail;
  final String timeLabel;
  final V2BrowserActionState state;
}

/// One open tab. Ovid owns the tabs; the person only switches between them.
@immutable
class V2BrowserTab {
  const V2BrowserTab({
    required this.id,
    required this.title,
    required this.host,
    this.icon = Icons.language_rounded,
  });

  final String id;
  final String title;
  final String host;
  final IconData icon;
}

/// Everything the browser screen needs to render. Immutable so the wiring
/// layer can rebuild it from a stream without the page holding state.
///
/// The page, its address, the live-stream numbers and the action log all
/// default to empty: they are facts about a real session, so the wiring layer
/// supplies them. Nothing here is sample data, and an un-wired instance shows
/// the empty action log instead of fake steps.
@immutable
class V2BrowserData {
  const V2BrowserData({
    this.tabs = const <V2BrowserTab>[],
    this.activeTabId = '',
    this.address = '',
    this.readOnly = true,
    this.drivingTitle = 'Ovid is driving',
    this.drivingDetail = '',
    this.liveLabel = '',
    this.streamLabel = '',
    this.headlessLabel = '',
    this.connection = V2BrowserConnection.live,
    this.actions = const <V2BrowserAction>[],
    this.status = V2BrowserStatus.content,
    this.emptyTitle = 'No page open',
    this.emptyMessage = 'Ask Ovid to open a page and it will show up here.',
    this.errorMessage = 'The live view lost its connection.',
    this.offlineMessage =
        'Ovid will reconnect on its own. You can also try now.',
  });

  final List<V2BrowserTab> tabs;
  final String activeTabId;
  final String address;
  final bool readOnly;
  final String drivingTitle;
  final String drivingDetail;
  final String liveLabel;
  final String streamLabel;
  final String headlessLabel;
  final V2BrowserConnection connection;
  final List<V2BrowserAction> actions;
  final V2BrowserStatus status;
  final String emptyTitle;
  final String emptyMessage;
  final String errorMessage;
  final String offlineMessage;

  V2BrowserTab? get activeTab {
    for (final tab in tabs) {
      if (tab.id == activeTabId) return tab;
    }
    return tabs.isEmpty ? null : tabs.first;
  }

  String get connectionLabel => switch (connection) {
    V2BrowserConnection.live => liveLabel.isEmpty ? 'Live' : liveLabel,
    V2BrowserConnection.reconnecting => 'Reconnecting…',
    V2BrowserConnection.offline => 'Offline',
  };

  bool get isLive => connection == V2BrowserConnection.live;
}

/// The live browser view. Ovid opens and closes tabs, so the plus is disabled
/// and explains who is in charge.
class BrowserPage extends StatelessWidget {
  const BrowserPage({
    super.key,
    required this.data,
    this.viewportChild,
    this.onTakeControl,
    this.onSelectTab,
    this.onCloseTab,
    this.onCopyAddress,
    this.onOpenRequested,
    this.onRetry,
    this.onMenu,
    this.onStop,
    this.onDownload,
    this.onUpload,
    this.onShowActionLog,
  });

  final V2BrowserData data;

  /// The live page. When null a calm placeholder document is shown so the
  /// screen still has weight in previews and tests.
  final Widget? viewportChild;

  final VoidCallback? onTakeControl;
  final ValueChanged<String>? onSelectTab;
  final ValueChanged<String>? onCloseTab;
  final VoidCallback? onCopyAddress;
  final VoidCallback? onOpenRequested;
  final VoidCallback? onRetry;
  final VoidCallback? onMenu;
  final VoidCallback? onStop;
  final VoidCallback? onDownload;
  final VoidCallback? onUpload;
  final VoidCallback? onShowActionLog;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    final active = data.activeTab;
    return OScaffold(
      appBar: OAppBar(
        title: 'Browser',
        subtitle: data.tabs.isEmpty
            ? null
            : '${data.tabs.length} tabs · read-only view',
        actions: [
          OIconButton(
            icon: Icons.download_rounded,
            semanticLabel: 'Download file',
            tooltip: 'Download file',
            onPressed: onDownload,
          ),
          OIconButton(
            icon: Icons.upload_rounded,
            semanticLabel: 'Upload file',
            tooltip: 'Upload file',
            onPressed: onUpload,
          ),
          OIconButton(
            icon: Icons.more_vert_rounded,
            semanticLabel: 'Browser menu',
            onPressed: onMenu,
          ),
        ],
      ),
      body: OFadeSlide(
        child: Column(
          children: [
            _TabStrip(
              tabs: data.tabs,
              activeTabId: active?.id ?? '',
              onSelect: onSelectTab,
              onClose: onCloseTab,
            ),
            Expanded(child: _body(context, c)),
          ],
        ),
      ),
    );
  }

  Widget _body(BuildContext context, OColors c) {
    return switch (data.status) {
      V2BrowserStatus.loading => const OSkeletonList(rows: 5),
      V2BrowserStatus.empty => OEmptyState(
        icon: Icons.travel_explore_rounded,
        title: data.emptyTitle,
        message: data.emptyMessage,
        action: OButton(
          label: 'Ask Ovid to open a page',
          icon: Icons.add_rounded,
          onPressed: onOpenRequested,
        ),
      ),
      V2BrowserStatus.error => OErrorState(
        title: 'Live view paused',
        message: data.errorMessage,
        onRetry: onRetry,
      ),
      V2BrowserStatus.content => _content(context, c),
    };
  }

  Widget _content(BuildContext context, OColors c) {
    final header = <Widget>[
      _AddressBlock(
        address: data.address,
        readOnly: data.readOnly,
        liveLabel: data.connectionLabel,
        streamLabel: data.streamLabel,
        connection: data.connection,
        onCopyAddress: onCopyAddress,
      ),
      if (!data.isLive)
        _ConnectionBanner(
          message: data.connection == V2BrowserConnection.offline
              ? data.offlineMessage
              : 'Ovid is trying to reconnect. The page will stay here.',
          onRetry: onRetry,
        ),
    ];
    final footer = <Widget>[
      _ActionLog(
        actions: data.actions,
        headlessLabel: data.headlessLabel,
        onShowAll: onShowActionLog,
      ),
      Padding(
        padding: const EdgeInsets.all(OSpace.l),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final driving = _DrivingCard(
              title: data.drivingTitle,
              detail: data.drivingDetail,
            );
            final stop = OButton(
              label: 'Stop',
              icon: Icons.stop_circle_outlined,
              variant: OButtonVariant.secondary,
              onPressed: onStop,
            );
            final takeControl = OButton(
              label: 'Take control',
              icon: Icons.front_hand_outlined,
              onPressed: onTakeControl,
            );
            // At 320 dp, or as soon as the text grows, two side-by-side
            // buttons would squeeze "Take control" to an ellipsis. Stack
            // them instead of shrinking the copy.
            final textScale = MediaQuery.textScalerOf(context).scale(14) / 14;
            if (constraints.maxWidth < 330 || textScale > 1.3) {
              return Column(
                children: [
                  Row(
                    children: [
                      Expanded(child: driving),
                      const SizedBox(width: OSpace.s),
                      stop,
                    ],
                  ),
                  const SizedBox(height: OSpace.s),
                  SizedBox(width: double.infinity, child: takeControl),
                ],
              );
            }
            return Row(
              children: [
                Expanded(child: driving),
                const SizedBox(width: OSpace.m),
                stop,
                const SizedBox(width: OSpace.s),
                takeControl,
              ],
            );
          },
        ),
      ),
    ];
    final viewport = Padding(
      padding: const EdgeInsets.fromLTRB(OSpace.l, 0, OSpace.l, 0),
      child: Container(
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: c.surface,
          borderRadius: BorderRadius.circular(ORadius.l),
          border: Border.all(color: c.hairline),
        ),
        child: viewportChild ?? const _ViewportPlaceholder(),
      ),
    );
    final textScale = MediaQuery.textScalerOf(context).scale(14) / 14;
    return LayoutBuilder(
      builder: (context, constraints) {
        // A short window (landscape, split screen) cannot hold the fixed rows
        // either, so it gets the same scroll treatment as large text.
        if (textScale <= 1.3 && constraints.maxHeight >= 420) {
          return Column(
            children: [
              ...header,
              Expanded(child: viewport),
              ...footer,
            ],
          );
        }
        // Large text makes the fixed rows taller than a short phone. Scroll
        // the whole page and keep a readable slice of the live view instead
        // of squeezing the copy or dropping rows.
        final viewportHeight = (constraints.maxHeight * 0.4).clamp(
          140.0,
          360.0,
        );
        return SingleChildScrollView(
          child: Column(
            children: [
              ...header,
              SizedBox(height: viewportHeight, child: viewport),
              ...footer,
            ],
          ),
        );
      },
    );
  }
}

class _DrivingCard extends StatelessWidget {
  const _DrivingCard({required this.title, required this.detail});

  final String title;
  final String detail;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    return Container(
      constraints: const BoxConstraints(minHeight: 56),
      padding: const EdgeInsets.symmetric(
        horizontal: OSpace.m,
        vertical: OSpace.s,
      ),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(ORadius.l),
        border: Border.all(color: c.hairline),
      ),
      child: Row(
        children: [
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color: c.accentSoft,
              shape: BoxShape.circle,
            ),
            child: Icon(Icons.smart_toy_outlined, size: 18, color: c.accent),
          ),
          const SizedBox(width: OSpace.m),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: OType.bodySm.copyWith(
                    color: c.text,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (detail.isNotEmpty)
                  Text(
                    detail,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
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

class _ConnectionBanner extends StatelessWidget {
  const _ConnectionBanner({required this.message, this.onRetry});

  final String message;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(OSpace.l, 0, OSpace.l, OSpace.s),
      child: Container(
        padding: const EdgeInsets.fromLTRB(
          OSpace.m,
          OSpace.s,
          OSpace.s,
          OSpace.s,
        ),
        decoration: BoxDecoration(
          color: c.warn.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(ORadius.m),
          border: Border.all(color: c.warn.withValues(alpha: 0.35)),
        ),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final textScale = MediaQuery.textScalerOf(context).scale(14) / 14;
            final messageRow = Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.wifi_off_rounded, size: 18, color: c.warn),
                const SizedBox(width: OSpace.s),
                Expanded(
                  child: Text(
                    message,
                    style: OType.caption.copyWith(color: c.textMuted),
                  ),
                ),
              ],
            );
            // Narrow or large text: the retry moves under the message so the
            // label keeps its full size instead of squeezing the sentence.
            if (constraints.maxWidth < 330 || textScale > 1.3) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  messageRow,
                  const SizedBox(height: OSpace.s),
                  OButton(
                    label: 'Reconnect',
                    variant: OButtonVariant.ghost,
                    expand: true,
                    onPressed: onRetry,
                  ),
                ],
              );
            }
            return Row(
              children: [
                Icon(Icons.wifi_off_rounded, size: 18, color: c.warn),
                const SizedBox(width: OSpace.s),
                Expanded(
                  child: Text(
                    message,
                    style: OType.caption.copyWith(color: c.textMuted),
                  ),
                ),
                OButton(
                  label: 'Reconnect',
                  variant: OButtonVariant.ghost,
                  onPressed: onRetry,
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _ActionLog extends StatelessWidget {
  const _ActionLog({
    required this.actions,
    required this.headlessLabel,
    this.onShowAll,
  });

  final List<V2BrowserAction> actions;
  final String headlessLabel;
  final VoidCallback? onShowAll;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    final shown = actions.take(2).toList();
    return Padding(
      padding: const EdgeInsets.fromLTRB(OSpace.l, OSpace.s, OSpace.l, 0),
      child: Container(
        decoration: BoxDecoration(
          color: c.surface,
          borderRadius: BorderRadius.circular(ORadius.l),
          border: Border.all(color: c.hairline),
        ),
        child: Column(
          children: [
            Semantics(
              button: onShowAll != null,
              enabled: onShowAll != null,
              label: 'Action log',
              child: InkWell(
                onTap: onShowAll,
                borderRadius: BorderRadius.circular(ORadius.l),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: OSpace.touch),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(
                      OSpace.m,
                      OSpace.s,
                      OSpace.s,
                      OSpace.s,
                    ),
                    child: Row(
                      children: [
                        Icon(
                          Icons.receipt_long_outlined,
                          size: 16,
                          color: c.textMuted,
                        ),
                        const SizedBox(width: OSpace.s),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Text(
                                'Action log',
                                style: OType.label.copyWith(color: c.text),
                              ),
                              if (headlessLabel.isNotEmpty)
                                Row(
                                  children: [
                                    Icon(
                                      Icons.timer_outlined,
                                      size: 12,
                                      color: c.warn,
                                    ),
                                    const SizedBox(width: OSpace.xs),
                                    Flexible(
                                      child: Text(
                                        headlessLabel,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: OType.caption.copyWith(
                                          color: c.warn,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                            ],
                          ),
                        ),
                        const SizedBox(width: OSpace.xs),
                        Icon(
                          Icons.chevron_right_rounded,
                          size: 18,
                          color: c.textFaint,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            if (shown.isEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  OSpace.m,
                  0,
                  OSpace.m,
                  OSpace.m,
                ),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    'No steps yet. Ovid will list what it does here.',
                    style: OType.caption.copyWith(color: c.textMuted),
                  ),
                ),
              )
            else
              OStagger(
                children: [
                  for (var i = 0; i < shown.length; i++) ...[
                    if (i > 0) Divider(color: c.hairline, height: 1),
                    _ActionRow(action: shown[i]),
                  ],
                ],
              ),
          ],
        ),
      ),
    );
  }
}

class _ActionRow extends StatelessWidget {
  const _ActionRow({required this.action});

  final V2BrowserAction action;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    final (color, icon) = switch (action.state) {
      V2BrowserActionState.done => (c.success, Icons.check_rounded),
      V2BrowserActionState.active => (c.accent, Icons.bolt_rounded),
      V2BrowserActionState.waiting => (c.textFaint, Icons.schedule_rounded),
    };
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        OSpace.m,
        OSpace.s,
        OSpace.m,
        OSpace.s,
      ),
      child: Row(
        children: [
          Container(
            width: 24,
            height: 24,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.12),
              shape: BoxShape.circle,
            ),
            child: Icon(icon, size: 14, color: color),
          ),
          const SizedBox(width: OSpace.s),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  action.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: OType.bodySm.copyWith(color: c.text),
                ),
                if (action.detail.isNotEmpty)
                  Text(
                    action.detail,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: OType.caption.copyWith(color: c.textMuted),
                  ),
              ],
            ),
          ),
          if (action.timeLabel.isNotEmpty) ...[
            const SizedBox(width: OSpace.s),
            Text(
              action.timeLabel,
              style: OType.caption.copyWith(color: c.textFaint),
            ),
          ],
        ],
      ),
    );
  }
}

class _TabStrip extends StatelessWidget {
  const _TabStrip({
    required this.tabs,
    required this.activeTabId,
    this.onSelect,
    this.onClose,
  });

  final List<V2BrowserTab> tabs;
  final String activeTabId;
  final ValueChanged<String>? onSelect;
  final ValueChanged<String>? onClose;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    return SizedBox(
      height: 56,
      child: Row(
        children: [
          Expanded(
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: OSpace.l),
              itemCount: tabs.length,
              separatorBuilder: (_, _) => const SizedBox(width: OSpace.s),
              itemBuilder: (context, index) {
                final tab = tabs[index];
                final selected = tab.id == activeTabId;
                return Center(
                  child: Semantics(
                    selected: selected,
                    label: '${tab.title}, ${tab.host}',
                    child: OPressable(
                      onTap: onSelect == null ? null : () => onSelect!(tab.id),
                      semanticLabel: '${tab.title}, ${tab.host}',
                      child: Container(
                        height: 48,
                        padding: const EdgeInsets.only(left: OSpace.m),
                        decoration: BoxDecoration(
                          color: selected ? c.surface : c.surfaceAlt,
                          borderRadius: const BorderRadius.vertical(
                            top: Radius.circular(ORadius.m),
                          ),
                          border: Border(
                            bottom: BorderSide(
                              color: selected ? c.accent : Colors.transparent,
                              width: 2,
                            ),
                          ),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              tab.icon,
                              size: 16,
                              color: selected ? c.accent : c.textMuted,
                            ),
                            const SizedBox(width: OSpace.s),
                            ConstrainedBox(
                              constraints: const BoxConstraints(maxWidth: 150),
                              child: Text(
                                tab.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: OType.label.copyWith(
                                  color: selected ? c.text : c.textMuted,
                                ),
                              ),
                            ),
                            OIconButton(
                              icon: Icons.close_rounded,
                              semanticLabel: 'Close ${tab.title}',
                              size: 16,
                              onPressed: onClose == null
                                  ? null
                                  : () => onClose!(tab.id),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(right: OSpace.s),
            child: OIconButton(
              icon: Icons.add_rounded,
              semanticLabel: 'Ovid opens tabs',
              tooltip: 'Ovid opens tabs',
              onPressed: null,
            ),
          ),
        ],
      ),
    );
  }
}

class _AddressBlock extends StatelessWidget {
  const _AddressBlock({
    required this.address,
    required this.readOnly,
    required this.liveLabel,
    required this.streamLabel,
    required this.connection,
    this.onCopyAddress,
  });

  final String address;
  final bool readOnly;
  final String liveLabel;
  final String streamLabel;
  final V2BrowserConnection connection;
  final VoidCallback? onCopyAddress;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    final liveColor = switch (connection) {
      V2BrowserConnection.live => c.success,
      V2BrowserConnection.reconnecting => c.warn,
      V2BrowserConnection.offline => c.danger,
    };
    // At 200 % text the badge and the copy button no longer share a line with
    // the address, so the badge drops below it instead of clipping the label.
    final textScale = MediaQuery.textScalerOf(context).scale(14) / 14;
    final badgeOnOwnLine = textScale > 1.3;
    final badge = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.visibility_outlined, size: 15, color: c.textMuted),
        const SizedBox(width: OSpace.xs),
        Flexible(child: OPill(label: readOnly ? 'Read-only' : 'Can edit')),
      ],
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(OSpace.l, 0, OSpace.l, OSpace.s),
      child: Container(
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: c.surface,
          borderRadius: BorderRadius.circular(ORadius.l),
          border: Border.all(color: c.hairline),
        ),
        child: Column(
          children: [
            ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 56),
              child: Row(
                children: [
                  const SizedBox(width: OSpace.m),
                  if (address.isNotEmpty) ...[
                    Icon(Icons.lock_rounded, size: 16, color: c.success),
                    const SizedBox(width: OSpace.s),
                  ],
                  Expanded(
                    child: Text(
                      address,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: OType.bodySm.copyWith(color: c.text),
                    ),
                  ),
                  const SizedBox(width: OSpace.s),
                  if (!badgeOnOwnLine) badge,
                  OIconButton(
                    icon: Icons.content_copy_rounded,
                    semanticLabel: 'Copy address',
                    size: 18,
                    onPressed: address.isEmpty ? null : onCopyAddress,
                  ),
                ],
              ),
            ),
            if (badgeOnOwnLine)
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  OSpace.m,
                  0,
                  OSpace.m,
                  OSpace.s,
                ),
                child: Align(alignment: Alignment.centerLeft, child: badge),
              ),
            Container(
              constraints: const BoxConstraints(minHeight: 36),
              color: c.surfaceAlt,
              padding: const EdgeInsets.symmetric(
                horizontal: OSpace.m,
                vertical: OSpace.xs,
              ),
              child: Row(
                children: [
                  OPulse(
                    child: Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                        color: liveColor,
                        shape: BoxShape.circle,
                      ),
                    ),
                  ),
                  const SizedBox(width: OSpace.s),
                  Expanded(
                    child: Text(
                      liveLabel,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: OType.caption.copyWith(
                        color: liveColor,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  if (streamLabel.isNotEmpty) ...[
                    const SizedBox(width: OSpace.s),
                    Icon(Icons.speed_rounded, size: 14, color: c.textMuted),
                    const SizedBox(width: OSpace.xs),
                    Flexible(
                      child: Text(
                        streamLabel,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: OType.caption.copyWith(color: c.textMuted),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Calm placeholder for the live page. The page itself is injected through
/// [BrowserPage.viewportChild]; this never draws sample content, so a build
/// that forgot to wire the view cannot show fake pages or fake secrets.
class _ViewportPlaceholder extends StatelessWidget {
  const _ViewportPlaceholder();

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
              width: 56,
              height: 56,
              decoration: BoxDecoration(
                color: c.accentSoft,
                shape: BoxShape.circle,
              ),
              child: Icon(Icons.visibility_outlined, size: 26, color: c.accent),
            ),
            const SizedBox(height: OSpace.m),
            Text(
              'The live page shows here',
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
                'Ovid draws the page it is reading in this space.',
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
