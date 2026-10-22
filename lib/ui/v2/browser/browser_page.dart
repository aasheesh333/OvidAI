import 'package:flutter/material.dart';

import '../../design/o_components.dart';
import '../../design/o_motion.dart';
import '../../design/o_screen.dart';
import '../../design/o_tokens.dart';
import 'control_bar.dart';
import 'tab_strip.dart';
import 'viewport.dart';

// TODO(l10n): move user-facing copy to the ARB files in the next wave.

/// Visual state of the browser screen.
enum V2BrowserStatus { loading, empty, error, content }

/// One open tab. Ovid owns the tabs; the person only switches between them.
///
/// A tab whose live view was closed for 45 seconds or more is [headless]:
/// Ovid keeps driving the page in the background, but there is no picture.
@immutable
class V2BrowserTab {
  const V2BrowserTab({
    required this.id,
    required this.title,
    required this.host,
    this.icon = Icons.language_rounded,
    this.favicon,
    this.headless = false,
    this.closable = true,
  });

  final String id;
  final String title;
  final String host;
  final IconData icon;

  /// A real favicon supplied by the wiring layer. Never fetched here.
  final ImageProvider? favicon;

  /// True when the live view was left closed long enough to go headless.
  final bool headless;

  /// False for a tab the wiring layer does not allow closing.
  final bool closable;
}

/// Everything the browser screen needs to render. Immutable so the wiring
/// layer can rebuild it from a stream without the page holding state.
///
/// The page, its address and the live picture all default to empty: they are
/// facts about a real session, so the wiring layer supplies them.
@immutable
class V2BrowserData {
  const V2BrowserData({
    this.tabs = const <V2BrowserTab>[],
    this.activeTabId = '',
    this.address = '',
    this.status = V2BrowserStatus.content,
    this.frame,
    this.viewportStatus = V2ViewportStatus.live,
    this.cursor,
    this.controlling = false,
    this.keyboard = false,
    this.canGoBack = false,
    this.canGoForward = false,
    this.viewportAspectRatio,
    this.emptyTitle = 'No page open',
    this.emptyMessage = 'Pages Ovid opens appear here.',
    this.errorMessage = 'The live view lost its connection.',
  });

  final List<V2BrowserTab> tabs;
  final String activeTabId;
  final String address;
  final V2BrowserStatus status;

  /// The latest decoded screencast frame. Null means "no picture yet", which
  /// shows the viewport's neutral waiting state instead of inventing content.
  final ImageProvider? frame;

  /// What the live picture is doing, separate from the page status.
  final V2ViewportStatus viewportStatus;

  /// Where Ovid's pointer is inside the frame, normalized to `0..1`.
  final V2ViewportCursor? cursor;

  /// True while this person holds the page.
  final bool controlling;

  /// Input tools that are currently switched on while controlling.
  final bool keyboard;

  /// Browser history availability for the back / forward controls.
  final bool canGoBack;
  final bool canGoForward;

  /// The live page's aspect ratio (`width / height`) from the server, used to
  /// map a tap on a letterboxed frame to the right page pixel.
  final double? viewportAspectRatio;

  final String emptyTitle;
  final String emptyMessage;
  final String errorMessage;

  V2BrowserTab? get activeTab {
    for (final tab in tabs) {
      if (tab.id == activeTabId) return tab;
    }
    return tabs.isEmpty ? null : tabs.first;
  }
}

/// The live browser view.
///
/// The page is the picture: one header (back, address pill, menu), a tab
/// strip only when there is more than one tab, and the frame filling all the
/// remaining space. Watching shows one take-control pill over the picture;
/// controlling swaps it for the icon-only dock at the bottom of the frame.
/// This widget is presentational and deliberately has no fallback handlers:
/// a control whose callback is null is not rendered, so an un-wired build
/// shows fewer buttons instead of dead ones. The live wiring lives in
/// `BrowserLivePage`.
class BrowserPage extends StatelessWidget {
  const BrowserPage({
    super.key,
    required this.data,
    this.viewportChild,
    this.onTakeControl,
    this.onSelectTab,
    this.onCloseTab,
    this.onOpenRequested,
    this.onRetry,
    this.onMenu,
    this.onReleaseControl,
    this.onToggleKeyboard,
    this.onBack,
    this.onForward,
    this.onPageTap,
  });

  final V2BrowserData data;

  /// The live page. When null the built-in viewport is shown.
  final Widget? viewportChild;

  final VoidCallback? onTakeControl;
  final ValueChanged<String>? onSelectTab;
  final ValueChanged<String>? onCloseTab;
  final VoidCallback? onOpenRequested;
  final VoidCallback? onRetry;
  final VoidCallback? onMenu;
  final VoidCallback? onReleaseControl;
  final VoidCallback? onToggleKeyboard;
  final VoidCallback? onBack;
  final VoidCallback? onForward;

  /// A tap on the live picture while the person controls it, normalized to
  /// the frame.
  final void Function(double x, double y)? onPageTap;

  @override
  Widget build(BuildContext context) {
    // The browser is a window: above 600 dp it gets one centred surface at the
    // contract cap (640 / 720), never a phone layout stretched across a
    // desktop.
    final window = MediaQuery.sizeOf(context).width;
    final pageMax = window >= OBreakpoints.wide
        ? 1100.0
        : OBreakpoints.contentMaxWidth(window);
    return OScaffold(
      appBar: _BrowserAppBar(address: data.address, onMenu: onMenu),
      body: Center(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: pageMax),
          child: OFadeSlide(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // A single tab is the page itself; the strip would only repeat
                // the address already in the header.
                if (data.tabs.length > 1)
                  BrowserTabStrip(
                    tabs: [
                      for (final tab in data.tabs)
                        V2BrowserTabItem(
                          id: tab.id,
                          title: tab.title,
                          host: tab.host,
                          icon: tab.icon,
                          favicon: tab.favicon,
                          headless: tab.headless,
                          closable: tab.closable,
                        ),
                    ],
                    activeTabId: data.activeTab?.id ?? '',
                    onSelectTab: onSelectTab,
                    onCloseTab: onCloseTab,
                  ),
                Expanded(child: _body(context)),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _body(BuildContext context) {
    return switch (data.status) {
      V2BrowserStatus.loading => const Padding(
        padding: EdgeInsets.all(OSpace.l),
        child: OSkeletonList(rows: 5),
      ),
      V2BrowserStatus.empty => OEmptyState(
        icon: Icons.travel_explore_rounded,
        title: data.emptyTitle,
        message: data.emptyMessage,
        // One action: ask Ovid for a page when that is wired, otherwise the
        // only useful thing left is to re-attach.
        action: onOpenRequested != null
            ? OButton(
                label: 'Open a page',
                icon: Icons.add_rounded,
                onPressed: onOpenRequested,
              )
            : onRetry == null
            ? null
            : OButton(
                label: 'Try again',
                icon: Icons.refresh_rounded,
                onPressed: onRetry,
              ),
      ),
      V2BrowserStatus.error => OErrorState(
        title: 'Live view paused',
        message: data.errorMessage,
        onRetry: onRetry,
      ),
      V2BrowserStatus.content => _content(context),
    };
  }

  Widget _content(BuildContext context) {
    final r = OResponsive.of(context);
    final viewport =
        viewportChild ??
        BrowserViewport(
          frame: data.frame,
          status: data.viewportStatus,
          cursor: data.cursor,
          controlling: data.controlling,
          onRetry: onRetry,
          onPageTap: onPageTap,
          frameAspectRatio: data.viewportAspectRatio,
        );
    return SafeArea(
      top: false,
      child: Padding(
        padding: EdgeInsets.fromLTRB(r.gutter, 0, r.gutter, OSpace.m),
        child: Stack(
          fit: StackFit.expand,
          children: [
            _frame(context, viewport),
            if (!data.controlling && onTakeControl != null)
              Positioned(
                left: 0,
                right: 0,
                bottom: OSpace.m,
                child: Center(
                  child: BrowserTakeControlPill(onPressed: onTakeControl),
                ),
              ),
            if (data.controlling)
              Positioned(
                left: 0,
                right: 0,
                bottom: OSpace.m,
                child: Center(
                  child: BrowserControlBar(
                    controlling: true,
                    keyboard: data.keyboard,
                    canGoBack: data.canGoBack,
                    canGoForward: data.canGoForward,
                    onTakeControl: onTakeControl,
                    onReleaseControl: onReleaseControl,
                    onToggleKeyboard: onToggleKeyboard,
                    onBack: onBack,
                    onForward: onForward,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// The frame fills its whole area; the screencast letterboxes itself with
  /// `BoxFit.contain` inside the viewport, so the window never crops a page.
  Widget _frame(BuildContext context, Widget child) {
    final c = OColors.of(context);
    return DecoratedBox(
      // Foreground: a border drawn as decoration would shave 2 dp off the
      // picture's width.
      position: DecorationPosition.foreground,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(ORadius.l),
        border: Border.all(color: c.hairline),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(ORadius.l),
        child: child,
      ),
    );
  }
}

/// The browser header: back, the address pill and the overflow menu.
///
/// A URL is a widget, not a title, so this mirrors [OAppBar]'s height, leading
/// and semantics instead of using its text-only title slot.
class _BrowserAppBar extends StatelessWidget implements PreferredSizeWidget {
  const _BrowserAppBar({required this.address, this.onMenu});

  final String address;
  final VoidCallback? onMenu;

  @override
  Size get preferredSize => const Size.fromHeight(56);

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    final canPop = Navigator.of(context).canPop();
    return AppBar(
      automaticallyImplyLeading: false,
      backgroundColor: c.bg,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      toolbarHeight: 56,
      leadingWidth: OSpace.touch,
      titleSpacing: canPop ? 0 : OSpace.l,
      leading: canPop
          ? OIconButton(
              icon: Icons.arrow_back_rounded,
              semanticLabel: 'Back',
              onPressed: () => Navigator.maybePop(context),
            )
          : null,
      title: MediaQuery.withClampedTextScaling(
        maxScaleFactor: 1.3,
        child: _AddressPill(address: address),
      ),
      actions: [
        if (onMenu != null)
          OIconButton(
            icon: Icons.more_vert_rounded,
            semanticLabel: 'Browser menu',
            onPressed: onMenu,
          ),
        const SizedBox(width: OSpace.s),
      ],
    );
  }
}

/// The address, and nothing else: no copy button (that lives in the menu), no
/// read-only badge and no stream size.
class _AddressPill extends StatelessWidget {
  const _AddressPill({required this.address});

  final String address;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    final empty = address.isEmpty;
    final secure = address.startsWith('https://');
    return Semantics(
      container: true,
      // The address is this screen's title: a browser has no page heading, and
      // without the flag TalkBack reported a screen with no header at all.
      header: true,
      label: empty ? 'Address' : 'Address, $address',
      child: ExcludeSemantics(
        child: Container(
          constraints: const BoxConstraints(minHeight: 36),
          padding: const EdgeInsets.symmetric(horizontal: OSpace.m),
          decoration: BoxDecoration(
            color: c.surface,
            borderRadius: BorderRadius.circular(ORadius.pill),
            border: Border.all(color: c.hairline),
          ),
          child: Row(
            children: [
              Icon(
                secure ? Icons.lock_rounded : Icons.language_rounded,
                size: 14,
                color: c.textMuted,
              ),
              const SizedBox(width: OSpace.s),
              Expanded(
                child: Text(
                  empty ? 'No page' : address,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: OType.bodySm.copyWith(
                    color: empty ? c.textMuted : c.text,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
