import 'package:flutter/material.dart';

import '../../design/o_components.dart';
import '../../design/o_motion.dart';
import '../../design/o_tokens.dart';

// TODO(l10n): move user-facing copy to the ARB files in the next wave.

/// One open tab in Ovid's browser.
///
/// Ovid opens every tab. The person can switch between tabs and close one, but
/// there is deliberately no way to create one by hand. A tab whose live view
/// was left closed long enough is [headless]: Ovid still owns the page and can
/// keep working on it, but there is no picture until it is opened again.
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

  /// True when the live view was closed for 45 seconds or more. Ovid keeps
  /// the page alive in the background.
  final bool headless;

  final bool closable;

  String get label {
    final name = title.trim();
    if (name.isNotEmpty) return name;
    final address = host.trim();
    return address.isEmpty ? 'New tab' : address;
  }
}

/// The tab strip above the live browser view.
///
/// It is presentational: the page supplies the tabs, the active id and the
/// callbacks. The strip keeps its shape in every page state (loading, empty,
/// error, content) so the user can always see what Ovid has open.
///
/// There is no plus button: a disabled plus is shown with a tooltip and a
/// screen-reader label so the rule is explained rather than silently missing.
class BrowserTabStrip extends StatelessWidget {
  const BrowserTabStrip({
    super.key,
    required this.tabs,
    this.activeTabId = '',
    this.onSelectTab,
    this.onCloseTab,
    this.noteLabel = 'Ovid opens tabs',
    this.emptyLabel = 'No tabs yet. Ovid opens the first one.',
    this.headlessLabel = 'Headless',
    this.headlessHint = 'Headless · the live view paused',
    this.plusSemanticLabel = 'New tab unavailable. Ovid opens tabs.',
  });

  final List<V2BrowserTabItem> tabs;

  /// The tab whose live view is on screen. When it is missing (or empty) the
  /// first tab is shown as active, matching the page's own fallback.
  final String activeTabId;

  final ValueChanged<String>? onSelectTab;
  final ValueChanged<String>? onCloseTab;

  /// The header note that explains who owns the tabs.
  final String noteLabel;
  final String emptyLabel;
  final String headlessLabel;
  final String headlessHint;
  final String plusSemanticLabel;

  String get _activeId {
    if (tabs.isEmpty) return '';
    for (final tab in tabs) {
      if (tab.id == activeTabId) return tab.id;
    }
    return tabs.first.id;
  }

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    final activeId = _activeId;
    return OFadeSlide(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _HeaderNote(label: noteLabel, plusSemanticLabel: plusSemanticLabel),
          if (tabs.isEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                OSpace.l,
                OSpace.xs,
                OSpace.l,
                OSpace.s,
              ),
              child: Text(
                emptyLabel,
                style: OType.caption.copyWith(color: c.textMuted),
              ),
            )
          else
            SingleChildScrollView(
              key: const ValueKey('v2-browser-tab-strip-scroll'),
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.fromLTRB(
                OSpace.l,
                OSpace.xs,
                OSpace.l,
                OSpace.s,
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  for (var i = 0; i < tabs.length; i++) ...[
                    if (i > 0) const SizedBox(width: OSpace.s),
                    _Tab(
                      tab: tabs[i],
                      selected: tabs[i].id == activeId,
                      headlessLabel: headlessLabel,
                      headlessHint: headlessHint,
                      onSelect: onSelectTab,
                      onClose: onCloseTab,
                    ),
                  ],
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _HeaderNote extends StatelessWidget {
  const _HeaderNote({required this.label, required this.plusSemanticLabel});

  final String label;
  final String plusSemanticLabel;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(OSpace.l, OSpace.s, OSpace.s, 0),
      child: Row(
        children: [
          Icon(Icons.smart_toy_outlined, size: 15, color: c.textMuted),
          const SizedBox(width: OSpace.xs),
          Expanded(
            child: Text(
              label,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: OType.caption.copyWith(color: c.textMuted),
            ),
          ),
          OIconButton(
            key: const ValueKey('v2-browser-tab-add'),
            icon: Icons.add_rounded,
            semanticLabel: plusSemanticLabel,
            tooltip: label,
            onPressed: null,
          ),
        ],
      ),
    );
  }
}

class _Tab extends StatelessWidget {
  const _Tab({
    required this.tab,
    required this.selected,
    required this.headlessLabel,
    required this.headlessHint,
    this.onSelect,
    this.onClose,
  });

  final V2BrowserTabItem tab;
  final bool selected;
  final String headlessLabel;
  final String headlessHint;
  final ValueChanged<String>? onSelect;
  final ValueChanged<String>? onClose;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    final foreground = selected ? c.text : c.textMuted;
    // A tab is a switch target and a close target. The whole body selects;
    // the close control keeps its own 48 dp target and callbacks, so closing
    // one never also switches to it.
    return OPressable(
      key: ValueKey('v2-browser-tab-${tab.id}'),
      onTap: onSelect == null ? null : () => onSelect!(tab.id),
      semanticLabel: _semanticsLabel,
      selected: selected,
      child: Container(
        constraints: const BoxConstraints(minHeight: OSpace.touch),
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
              height: 2,
              child: selected
                  ? ColoredBox(
                      key: ValueKey('v2-browser-tab-active-${tab.id}'),
                      color: c.accent,
                    )
                  : null,
            ),
            Padding(
              padding: EdgeInsets.only(
                left: OSpace.m,
                right: tab.closable ? 0 : OSpace.s,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ExcludeSemantics(
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _Favicon(tab: tab, selected: selected),
                        const SizedBox(width: OSpace.s),
                        ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 160),
                          child: Text(
                            tab.label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: OType.label.copyWith(color: foreground),
                          ),
                        ),
                        if (tab.headless) ...[
                          const SizedBox(width: OSpace.s),
                          _HeadlessBadge(
                            tabId: tab.id,
                            label: headlessLabel,
                            hint: headlessHint,
                          ),
                        ],
                      ],
                    ),
                  ),
                  if (tab.closable)
                    OIconButton(
                      key: ValueKey('v2-browser-tab-close-${tab.id}'),
                      icon: Icons.close_rounded,
                      semanticLabel: 'Close ${tab.label}',
                      size: 16,
                      onPressed: onClose == null
                          ? null
                          : () => onClose!(tab.id),
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
  /// The visible title and badge are excluded from semantics so a screen
  /// reader does not read the same words twice.
  String get _semanticsLabel {
    final parts = <String>[tab.label];
    final address = tab.host.trim();
    if (address.isNotEmpty && address != tab.label) parts.add(address);
    if (tab.headless) parts.add(headlessLabel);
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
      padding: const EdgeInsets.all(2),
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

/// Marks a tab Ovid kept open after the live view was closed. The page is
/// still running for Ovid; only the picture is gone.
class _HeadlessBadge extends StatelessWidget {
  const _HeadlessBadge({
    required this.tabId,
    required this.label,
    required this.hint,
  });

  final String tabId;
  final String label;
  final String hint;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    return Tooltip(
      message: hint,
      child: Container(
        key: ValueKey('v2-browser-tab-headless-$tabId'),
        constraints: const BoxConstraints(minHeight: 20),
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
        decoration: BoxDecoration(
          color: c.warn.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(ORadius.pill),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.timer_outlined, size: 12, color: c.warn),
            const SizedBox(width: OSpace.xs),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 120),
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: OType.caption.copyWith(
                  color: c.warn,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
