import 'package:flutter/material.dart';

import '../../design/o_components.dart';
import '../../design/o_motion.dart';
import '../../design/o_tokens.dart';

// TODO(l10n): move user-facing copy to the ARB files in the next wave.

/// One open tab in Ovid's browser.
///
/// Ovid opens every tab. The person can switch between tabs, and can close one
/// only when the wiring layer supplies a close handler. There is deliberately
/// no way to create a tab by hand.
@immutable
class V2BrowserTabItem {
  const V2BrowserTabItem({
    required this.id,
    required this.title,
    this.host = '',
    this.icon = Icons.language_rounded,
    this.favicon,
    this.headless = false,
    this.closable = true,
  });

  final String id;

  /// What the tab shows. Falls back to [host] when Ovid has not titled it yet.
  final String title;

  /// Where the tab points, e.g. `ovidsi.com`. Used for the screen-reader label.
  final String host;

  /// Fallback mark when [favicon] is absent or fails to load.
  final IconData icon;

  /// A real favicon, supplied by the wiring layer. Never fetched from here.
  final ImageProvider? favicon;

  /// True when the live view was closed long enough to go headless. Ovid keeps
  /// the page alive in the background.
  final bool headless;

  final bool closable;

  String get label {
    final name = title.trim();
    if (name.isNotEmpty) return name;
    final address = host.trim();
    // Never "New tab": the person cannot open one.
    return address.isEmpty ? 'Untitled page' : address;
  }
}

/// The tab strip above the live browser view.
///
/// Icon-only: the favicon is the tab. The page only mounts the strip when
/// there is more than one tab, so a single-tab session reads as one clean
/// window. It is presentational: the page supplies the tabs, the active id
/// and the callbacks.
class BrowserTabStrip extends StatelessWidget {
  const BrowserTabStrip({
    super.key,
    required this.tabs,
    this.activeTabId = '',
    this.onSelectTab,
    this.onCloseTab,
  });

  final List<V2BrowserTabItem> tabs;

  /// The tab whose live view is on screen. When it is missing (or empty) the
  /// first tab is shown as active, matching the page's own fallback.
  final String activeTabId;

  final ValueChanged<String>? onSelectTab;
  final ValueChanged<String>? onCloseTab;

  String get _activeId {
    if (tabs.isEmpty) return '';
    for (final tab in tabs) {
      if (tab.id == activeTabId) return tab.id;
    }
    return tabs.first.id;
  }

  @override
  Widget build(BuildContext context) {
    if (tabs.isEmpty) return const SizedBox.shrink();
    final activeId = _activeId;
    return OFadeSlide(
      child: SingleChildScrollView(
        key: const ValueKey('v2-browser-tab-strip-scroll'),
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(OSpace.l, OSpace.s, OSpace.l, 0),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            for (var i = 0; i < tabs.length; i++) ...[
              if (i > 0) const SizedBox(width: OSpace.s),
              _Tab(
                tab: tabs[i],
                selected: tabs[i].id == activeId,
                onSelect: onSelectTab,
                onClose: onCloseTab,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _Tab extends StatelessWidget {
  const _Tab({
    required this.tab,
    required this.selected,
    this.onSelect,
    this.onClose,
  });

  final V2BrowserTabItem tab;
  final bool selected;
  final ValueChanged<String>? onSelect;
  final ValueChanged<String>? onClose;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    // A tab is a switch target and a close target. The icon body selects; the
    // close control keeps its own 48 dp target and callbacks. No title text:
    // the favicon is the tab, and the semantics label carries the name.
    return OPressable(
      key: ValueKey('v2-browser-tab-${tab.id}'),
      onTap: onSelect == null ? null : () => onSelect!(tab.id),
      semanticLabel: _semanticsLabel,
      selected: selected,
      child: Container(
        constraints: const BoxConstraints(
          minWidth: OSpace.touch,
          minHeight: OSpace.touch,
        ),
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: selected ? c.surfaceRaised : c.surfaceAlt,
          borderRadius: const BorderRadius.vertical(
            top: Radius.circular(ORadius.m),
            bottom: Radius.circular(ORadius.s),
          ),
          border: Border.all(color: selected ? c.hairlineStrong : c.hairline),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              height: OSpace.xxs,
              child: selected
                  ? ColoredBox(
                      key: ValueKey('v2-browser-tab-active-${tab.id}'),
                      color: c.accent,
                    )
                  : null,
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: OSpace.s),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ExcludeSemantics(child: _Favicon(tab: tab, selected: selected)),
                  if (tab.headless) ...[
                    const SizedBox(width: OSpace.xxs),
                    ExcludeSemantics(child: _HeadlessMark(tabId: tab.id)),
                  ],
                  // Only a wired close control is shown.
                  if (tab.closable && onClose != null)
                    OIconButton(
                      key: ValueKey('v2-browser-tab-close-${tab.id}'),
                      icon: Icons.close_rounded,
                      semanticLabel: 'Close ${tab.label}',
                      size: 16,
                      onPressed: () => onClose!(tab.id),
                    )
                  else
                    const SizedBox(width: OSpace.xs),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// One clean label for the whole tab: name, host and the headless state.
  String get _semanticsLabel {
    final parts = <String>[tab.label];
    final address = tab.host.trim();
    if (address.isNotEmpty && address != tab.label) parts.add(address);
    if (tab.headless) parts.add('Headless');
    return parts.join(', ');
  }
}

/// The site mark. A real favicon when the wiring layer has one, otherwise a
/// neutral glyph so the row never collapses or shows a broken image.
class _Favicon extends StatelessWidget {
  const _Favicon({required this.tab, required this.selected});

  final V2BrowserTabItem tab;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    final fallback = Icon(
      tab.icon,
      size: 13,
      color: selected ? c.accent : c.textMuted,
    );
    return Container(
      width: 22,
      height: 22,
      padding: const EdgeInsets.all(OSpace.xxs),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(ORadius.s),
        border: Border.all(
          color: selected ? c.accentFill.withValues(alpha: 0.35) : c.hairline,
        ),
      ),
      child: tab.favicon == null
          ? fallback
          : ClipRRect(
              borderRadius: BorderRadius.circular(ORadius.s),
              child: Image(
                image: tab.favicon!,
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => fallback,
              ),
            ),
    );
  }
}

/// Marks a tab Ovid kept open after the live view was closed. An icon, not a
/// word: the tooltip and the tab's own label carry the meaning.
class _HeadlessMark extends StatelessWidget {
  const _HeadlessMark({required this.tabId});

  final String tabId;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    return Tooltip(
      message: 'Headless',
      child: Container(
        key: ValueKey('v2-browser-tab-headless-$tabId'),
        constraints: const BoxConstraints(minHeight: 20),
        padding: const EdgeInsets.symmetric(horizontal: OSpace.xs, vertical: 1),
        decoration: BoxDecoration(
          color: c.warn.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(ORadius.pill),
        ),
        child: Icon(Icons.timer_outlined, size: 16, color: c.warn),
      ),
    );
  }
}
