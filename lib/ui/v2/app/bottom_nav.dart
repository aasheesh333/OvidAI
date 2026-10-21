import 'package:flutter/material.dart';

import '../../design/o_tokens.dart';

// TODO(l10n): route all user-facing copy through the ARB pass.

/// The persistent bottom bar from the Stitch reference.
///
/// Chat surfaces use four tabs; work surfaces (Studio, Browser, Connectors,
/// Artifacts) use five. The bar is presentational: the shell owns the current
/// index and the navigation callbacks.
enum V2NavTab { chat, studio, browser, library, settings }

@immutable
class V2NavItem {
  const V2NavItem({
    required this.tab,
    required this.label,
    required this.icon,
    required this.activeIcon,
  });

  final V2NavTab tab;
  final String label;
  final IconData icon;
  final IconData activeIcon;
}

const List<V2NavItem> v2ChatNavItems = <V2NavItem>[
  V2NavItem(
    tab: V2NavTab.chat,
    label: 'Chat',
    icon: Icons.chat_bubble_outline_rounded,
    activeIcon: Icons.chat_bubble_rounded,
  ),
  V2NavItem(
    tab: V2NavTab.studio,
    label: 'Studio',
    icon: Icons.code_rounded,
    activeIcon: Icons.code_rounded,
  ),
  V2NavItem(
    tab: V2NavTab.browser,
    label: 'Browser',
    icon: Icons.public_rounded,
    activeIcon: Icons.public_rounded,
  ),
  V2NavItem(
    tab: V2NavTab.settings,
    label: 'Settings',
    icon: Icons.tune_rounded,
    activeIcon: Icons.tune_rounded,
  ),
];

const List<V2NavItem> v2WorkNavItems = <V2NavItem>[
  ...v2ChatNavItems,
  V2NavItem(
    tab: V2NavTab.library,
    label: 'Library',
    icon: Icons.inventory_2_outlined,
    activeIcon: Icons.inventory_2_rounded,
  ),
];

/// Bottom navigation with a hairline top border and an accent pill on the
/// active tab. Every target is at least 48 dp and announces its selection.
///
/// [onSelect] is required: the bar never renders a tab that cannot go
/// anywhere. The host owns [current] and decides which tab a route belongs to.
class V2BottomNav extends StatelessWidget {
  const V2BottomNav({
    super.key,
    required this.current,
    this.items = v2ChatNavItems,
    required this.onSelect,
  });

  final V2NavTab current;
  final List<V2NavItem> items;
  final ValueChanged<V2NavTab> onSelect;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    return Semantics(
      container: true,
      label: 'Main navigation',
      child: Container(
        decoration: BoxDecoration(
          color: c.surface,
          border: Border(top: BorderSide(color: c.hairline)),
        ),
        child: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: OSpace.s,
              vertical: OSpace.xs,
            ),
            child: Row(
              children: [
                for (final item in items)
                  Expanded(
                    child: _NavButton(
                      key: ValueKey<String>('v2-nav-${item.tab.name}'),
                      item: item,
                      selected: item.tab == current,
                      onTap: () => onSelect(item.tab),
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

class _NavButton extends StatelessWidget {
  const _NavButton({
    super.key,
    required this.item,
    required this.selected,
    required this.onTap,
  });

  final V2NavItem item;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    final fg = selected ? c.accent : c.textMuted;
    return Semantics(
      label: item.label,
      button: true,
      selected: selected,
      enabled: true,
      onTap: onTap,
      excludeSemantics: true,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(ORadius.m),
        child: SizedBox(
          height: OSpace.touch,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(selected ? item.activeIcon : item.icon, size: 22, color: fg),
              const SizedBox(height: 2),
              Flexible(
                child: Text(
                  item.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: OType.caption.copyWith(
                    color: fg,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
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
