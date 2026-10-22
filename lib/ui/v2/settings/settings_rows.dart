import 'package:flutter/material.dart';

import '../../design/o_components.dart';
import '../../design/o_tokens.dart';

// TODO(l10n): move user-facing copy to the ARB files in the localization pass.

/// The one settings row rhythm: a 40 dp icon tile, a title, and an optional
/// value or chevron, sitting on the page background with hairline dividers.
///
/// Every settings list (the hub, Account, Data control, the memory pages,
/// About, Credentials, …) builds from these pieces so the pages read as one
/// family instead of seventeen variations.
const double v2SettingsTileSize = 40;

/// Divider inset that skips the icon tile and its gap, so the hairline runs
/// from the row's text edge to the content edge.
const double v2SettingsRowDividerIndent =
    v2SettingsTileSize + OSpace.m;

/// The 40 dp leading tile: `surfaceAlt`, radius m, one 20 dp glyph.
class V2SettingsTile extends StatelessWidget {
  const V2SettingsTile({super.key, required this.icon, this.danger = false});

  final IconData icon;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    return Container(
      width: v2SettingsTileSize,
      height: v2SettingsTileSize,
      decoration: BoxDecoration(
        color: danger ? c.danger.withValues(alpha: 0.10) : c.surfaceAlt,
        borderRadius: BorderRadius.circular(ORadius.m),
      ),
      child: Icon(icon, size: 20, color: danger ? c.danger : c.textMuted),
    );
  }
}

/// A trailing value plus the chevron, for rows that navigate and carry a
/// real value ("Voice language · English").
class V2SettingsRowValue extends StatelessWidget {
  const V2SettingsRowValue({super.key, required this.value, this.chevron = true});

  final String value;
  final bool chevron;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Flexible(
          child: Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: OType.caption.copyWith(color: c.textMuted),
          ),
        ),
        if (chevron) ...[
          const SizedBox(width: OSpace.xs),
          Icon(Icons.chevron_right_rounded, size: 20, color: c.textFaint),
        ],
      ],
    );
  }
}

/// One flat settings row on the page background.
///
/// This is [OListRow] with the family defaults applied: the 40 dp tile, no
/// horizontal padding (the page gutter owns the sides) and an optional
/// trailing [value]. Anything richer (a switch, a pill, a menu) goes through
/// [trailing] exactly as with `OListRow`.
class V2SettingsRow extends StatelessWidget {
  const V2SettingsRow({
    super.key,
    required this.title,
    this.icon,
    this.leading,
    this.subtitle,
    this.value,
    this.trailing,
    this.stacksTrailing = false,
    this.onTap,
    this.danger = false,
    this.enabled = true,
    this.showChevron = true,
  });

  final String title;
  final IconData? icon;
  final Widget? leading;
  final String? subtitle;

  /// A short real value at the end of the row ("English", "170 MB").
  final String? value;
  final Widget? trailing;

  /// When true, a wide trailing control (a status pill) drops under the title
  /// at large text instead of squeezing the title into a sliver.
  final bool stacksTrailing;
  final VoidCallback? onTap;
  final bool danger;
  final bool enabled;
  final bool showChevron;

  /// Above this scale the trailing control drops below the title.
  static const _stackAbove = 1.4;

  @override
  Widget build(BuildContext context) {
    final leadingWidget =
        leading ??
        (icon == null ? null : V2SettingsTile(icon: icon!, danger: danger));
    final trailingWidget =
        trailing ??
        (value == null
            ? null
            : V2SettingsRowValue(
                value: value!,
                // The chevron belongs to navigation; an immediate action
                // (clear cache) shows its value alone.
                chevron: showChevron && onTap != null,
              ));
    if (trailingWidget != null &&
        stacksTrailing &&
        MediaQuery.textScalerOf(context).scale(1) > _stackAbove) {
      return _stacked(context, leadingWidget, trailingWidget);
    }
    // The key stays on this wrapper: forwarding it to the row would put the
    // same ValueKey on two widgets.
    return OListRow(
      title: title,
      subtitle: subtitle,
      leading: leadingWidget,
      trailing: trailingWidget,
      onTap: onTap,
      danger: danger,
      enabled: enabled,
      // A value row already ends in its value; the chevron rides with it.
      showChevron: trailingWidget == null && showChevron,
      padding: const EdgeInsets.symmetric(vertical: OSpace.m),
    );
  }

  /// The 200 % layout: the trailing control sits under the title, so a long
  /// title and a pill never compete for the same line.
  Widget _stacked(BuildContext context, Widget? leading, Widget trailing) {
    final c = OColors.of(context);
    final fg = danger ? c.danger : (enabled ? c.text : c.textFaint);
    final label = subtitle == null ? title : '$title, $subtitle';
    final content = ConstrainedBox(
      constraints: const BoxConstraints(minHeight: OSpace.listRow),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: OSpace.m),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (leading != null) ...[
              leading,
              const SizedBox(width: OSpace.m),
            ],
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  ExcludeSemantics(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          style: OType.body.copyWith(
                            color: fg,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        if (subtitle != null) ...[
                          const SizedBox(height: OSpace.xxs),
                          Text(
                            subtitle!,
                            style: OType.caption.copyWith(color: c.textMuted),
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(height: OSpace.s),
                  Align(alignment: Alignment.centerLeft, child: trailing),
                ],
              ),
            ),
          ],
        ),
      ),
    );
    if (onTap == null) {
      return Semantics(label: label, enabled: enabled, child: content);
    }
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: enabled ? onTap : null,
        borderRadius: BorderRadius.circular(ORadius.m),
        child: Semantics(label: label, button: true, child: content),
      ),
    );
  }
}

/// A list of rows on the page background: no card, hairline dividers aligned
/// with the row text.
class V2SettingsRowList extends StatelessWidget {
  const V2SettingsRowList({super.key, required this.rows});

  final List<Widget> rows;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var index = 0; index < rows.length; index++) ...[
          if (index > 0)
            Divider(
              height: 1,
              thickness: 1,
              indent: v2SettingsRowDividerIndent,
              color: c.hairline,
            ),
          rows[index],
        ],
      ],
    );
  }
}
