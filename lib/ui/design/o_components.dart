import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';

import 'o_motion.dart';
import 'o_screen.dart' show OBreakpoints;
import 'o_tokens.dart';

enum OButtonVariant { primary, secondary, ghost, danger, dangerFill }

enum OButtonSize { regular, compact }

/// The one button in the rebuilt UI. It is always at least 48 dp tall, always
/// carries a text label, and reports its disabled state to accessibility.
class OButton extends StatelessWidget {
  const OButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.variant = OButtonVariant.primary,
    this.icon,
    this.trailing,
    this.loading = false,
    this.expand = false,
    this.size = OButtonSize.regular,
    this.semanticLabel,
  });

  final String label;
  final VoidCallback? onPressed;
  final OButtonVariant variant;
  final IconData? icon;
  final Widget? trailing;
  final bool loading;
  final bool expand;
  final OButtonSize size;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    final enabled = onPressed != null && !loading;
    // Compact is shorter *content* (tighter horizontal padding), never a
    // smaller hit area: both sizes keep the 48 dp touch floor.
    final height = OSpace.touch;
    final content = Row(
      mainAxisSize: expand ? MainAxisSize.max : MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        if (loading)
          SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: switch (variant) {
                OButtonVariant.primary || OButtonVariant.dangerFill =>
                  c.onAccent,
                _ => c.accent,
              },
            ),
          )
        else if (icon != null)
          Icon(icon, size: 19),
        if (loading || icon != null) const SizedBox(width: OSpace.s),
        Flexible(
          child: semanticLabel == null
              ? Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: OType.label.copyWith(
                    color: _foreground(c, enabled),
                  ),
                )
              : ExcludeSemantics(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: OType.label.copyWith(
                      color: _foreground(c, enabled),
                    ),
                  ),
                ),
        ),
        if (trailing != null) ...[const SizedBox(width: OSpace.s), trailing!],
      ],
    );

    final shape = const StadiumBorder();
    final padded = Padding(
      padding: EdgeInsets.symmetric(
        horizontal: size == OButtonSize.compact ? OSpace.m : OSpace.buttonPad,
      ),
      child: content,
    );

    final Widget button = switch (variant) {
      OButtonVariant.primary => FilledButton(
        onPressed: enabled ? onPressed : null,
        style: FilledButton.styleFrom(
          minimumSize: Size(0, height),
          backgroundColor: c.accentFill,
          foregroundColor: c.onAccent,
          disabledBackgroundColor: c.surfaceRaised,
          disabledForegroundColor: c.textFaint,
          padding: EdgeInsets.zero,
          shape: shape,
        ),
        child: padded,
      ),
      OButtonVariant.secondary => OutlinedButton(
        onPressed: enabled ? onPressed : null,
        style: OutlinedButton.styleFrom(
          minimumSize: Size(0, height),
          foregroundColor: c.text,
          disabledForegroundColor: c.textFaint,
          side: BorderSide(color: enabled ? c.hairlineStrong : c.hairline),
          padding: EdgeInsets.zero,
          shape: shape,
        ),
        child: padded,
      ),
      OButtonVariant.ghost => TextButton(
        onPressed: enabled ? onPressed : null,
        style: TextButton.styleFrom(
          minimumSize: Size(0, height),
          foregroundColor: c.accent,
          disabledForegroundColor: c.textFaint,
          padding: EdgeInsets.zero,
          shape: shape,
        ),
        child: padded,
      ),
      OButtonVariant.danger => OutlinedButton(
        onPressed: enabled ? onPressed : null,
        style: OutlinedButton.styleFrom(
          minimumSize: Size(0, height),
          foregroundColor: c.danger,
          disabledForegroundColor: c.textFaint,
          side: BorderSide(color: enabled ? c.danger : c.hairline),
          padding: EdgeInsets.zero,
          shape: shape,
        ),
        child: padded,
      ),
      OButtonVariant.dangerFill => FilledButton(
        onPressed: enabled ? onPressed : null,
        style: FilledButton.styleFrom(
          minimumSize: Size(0, height),
          backgroundColor: c.danger,
          foregroundColor: c.onDanger,
          disabledBackgroundColor: c.surfaceRaised,
          disabledForegroundColor: c.textFaint,
          padding: EdgeInsets.zero,
          shape: shape,
        ),
        child: padded,
      ),
    };

    final sized = expand
        ? SizedBox(width: double.infinity, child: button)
        : button;
    return Semantics(
      label: semanticLabel ?? label,
      button: true,
      enabled: enabled,
      // A button nested inside a tappable row or card must stay its own node;
      // without a container its label is merged into the parent's and the
      // action becomes unreachable for a screen reader.
      container: true,
      // The label above is the whole button. Keeping the inner Text in the
      // tree as well produced a second node with the same label, so a
      // `find.bySemanticsLabel('Retry')` matched twice and TalkBack read the
      // button twice. Excluding the child also drops its tap action, so the
      // wrapper declares the action itself.
      excludeSemantics: true,
      onTap: enabled ? onPressed : null,
      child: sized,
    );
  }

  Color _foreground(OColors c, bool enabled) {
    if (!enabled) return c.textFaint;
    return switch (variant) {
      OButtonVariant.primary || OButtonVariant.dangerFill => c.onAccent,
      OButtonVariant.secondary => c.text,
      OButtonVariant.ghost => c.accent,
      OButtonVariant.danger => c.danger,
    };
  }
}

/// 48 × 48 icon control with a required semantic label.
class OIconButton extends StatelessWidget {
  const OIconButton({
    super.key,
    required this.icon,
    required this.semanticLabel,
    this.onPressed,
    this.tooltip,
    this.active = false,
    this.size = 22,
    this.badge,
  });

  final IconData icon;
  final String semanticLabel;
  final VoidCallback? onPressed;
  final String? tooltip;
  final bool active;
  final double size;
  final Widget? badge;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    final enabled = onPressed != null;
    final button = SizedBox(
      width: OSpace.touch,
      height: OSpace.touch,
      child: IconButton(
        onPressed: onPressed,
        iconSize: size,
        style: IconButton.styleFrom(
          foregroundColor: active ? c.accent : c.text,
          disabledForegroundColor: c.textFaint,
          backgroundColor: active ? c.accentSoft : Colors.transparent,
        ),
        icon: badge == null
            ? Icon(icon)
            : Badge(
                backgroundColor: c.accentFill,
                label: badge,
                child: Icon(icon),
              ),
      ),
    );
    return Semantics(
      label: semanticLabel,
      button: true,
      enabled: enabled,
      // See OButton: keep the icon button's own node so an overflow menu
      // inside a tappable card is still reachable.
      container: true,
      excludeSemantics: true,
      onTap: onPressed,
      child: tooltip == null ? button : Tooltip(message: tooltip!, child: button),
    );
  }
}

class OCard extends StatelessWidget {
  const OCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(OSpace.l),
    this.onTap,
    this.accent = false,
    this.border = true,
    this.semanticLabel,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final VoidCallback? onTap;
  final bool accent;
  final bool border;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    final content = Container(
      padding: padding,
      decoration: BoxDecoration(
        color: accent ? c.accentSoft : c.surface,
        borderRadius: BorderRadius.circular(ORadius.l),
        border: border
            ? Border.all(color: accent ? c.accentFill.withValues(alpha: 0.35) : c.hairline)
            : null,
      ),
      child: child,
    );
    if (onTap == null) return content;
    return OPressable(
      onTap: onTap,
      semanticLabel: semanticLabel,
      child: content,
    );
  }
}

/// The one horizontal rule. [label] centres a word between two hairlines
/// (the "OR" divider on sign-in); [indent] lines it up with row content.
class ODivider extends StatelessWidget {
  const ODivider({super.key, this.label, this.indent = 0});

  final String? label;
  final double indent;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    final rule = Divider(height: 1, thickness: 1, color: c.hairline);
    if (label == null) {
      return Padding(padding: EdgeInsets.only(left: indent), child: rule);
    }
    return Row(
      children: [
        Expanded(child: rule),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: OSpace.m),
          child: Text(
            label!,
            style: OType.overline.copyWith(color: c.textFaint),
          ),
        ),
        Expanded(child: rule),
      ],
    );
  }
}

/// Settings/list row. Icon + title + optional subtitle + trailing affordance.
class OListRow extends StatelessWidget {
  const OListRow({
    super.key,
    required this.title,
    this.subtitle,
    this.icon,
    this.leading,
    this.trailing,
    this.onTap,
    this.danger = false,
    this.enabled = true,
    this.showChevron = true,
    this.padding = const EdgeInsets.symmetric(
      horizontal: OSpace.l,
      vertical: OSpace.m,
    ),
  });

  final String title;
  final String? subtitle;
  final IconData? icon;
  final Widget? leading;
  final Widget? trailing;
  final VoidCallback? onTap;
  final bool danger;
  final bool enabled;
  final bool showChevron;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    final fg = danger ? c.danger : (enabled ? c.text : c.textFaint);
    final leadingWidget = leading ??
        (icon == null
            ? null
            : Container(
                width: OSpace.iconTile,
                height: OSpace.iconTile,
                decoration: BoxDecoration(
                  color: danger ? c.danger.withValues(alpha: 0.10) : c.surfaceAlt,
                  borderRadius: BorderRadius.circular(ORadius.m),
                ),
                child: Icon(icon, size: 19, color: danger ? c.danger : c.textMuted),
              ));
    // The visible title/subtitle text is decoration once the row has an
    // explicit label: leaving it in the tree makes TalkBack read every row
    // twice ("Rename chat, Rename chat"). Trailing/leading controls keep their
    // own semantics.
    final content = Row(
      children: [
        if (leadingWidget != null) ...[
          leadingWidget,
          const SizedBox(width: OSpace.m),
        ],
        Expanded(
          child: ExcludeSemantics(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
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
        ),
        if (trailing != null) ...[
          const SizedBox(width: OSpace.s),
          trailing!,
        ] else if (showChevron && onTap != null)
          Icon(Icons.chevron_right_rounded, size: 20, color: c.textFaint),
      ],
    );
    final labelledRow = ConstrainedBox(
      constraints: const BoxConstraints(minHeight: OSpace.listRow),
      child: Padding(padding: padding, child: content),
    );
    if (onTap == null) {
      // A row without an action is informational unless the caller explicitly
      // marked it disabled. Announcing "disabled" on a value row ("Storage
      // left, 3 GB") is wrong: it is not a control at all.
      if (enabled) {
        return Semantics(
          label: subtitle == null ? title : '$title, $subtitle',
          child: labelledRow,
        );
      }
      return Semantics(
        label: subtitle == null ? title : '$title, $subtitle',
        enabled: false,
        child: labelledRow,
      );
    }
    if (!enabled) {
      return Semantics(
        label: subtitle == null ? title : '$title, $subtitle',
        enabled: false,
        child: labelledRow,
      );
    }
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(ORadius.m),
        child: Semantics(
          label: subtitle == null ? title : '$title, $subtitle',
          button: true,
          // Without this the row announced a tap but no state, so TalkBack
          // read "Clear cache, button" with no way to know it can act.
          enabled: true,
          child: labelledRow,
        ),
      ),
    );
  }
}

/// Uppercase section label used in Settings and the sidebar.
class OSectionHeader extends StatelessWidget {
  const OSectionHeader({
    super.key,
    required this.label,
    this.trailing,
    this.padding = const EdgeInsets.fromLTRB(
      OSpace.l,
      OSpace.l,
      OSpace.l,
      OSpace.s,
    ),
  });

  final String label;
  final Widget? trailing;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    return Padding(
      padding: padding,
      child: Row(
        children: [
          Expanded(
            child: Semantics(
              container: true,
              header: true,
              child: Text(
                label.toUpperCase(),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: OType.overline.copyWith(color: c.textMuted),
              ),
            ),
          ),
          if (trailing != null)
            // Callers that already own their flex (search's "Best matches")
            // must not be wrapped twice; Flexible cannot nest in a Row.
            trailing is Flexible || trailing is Expanded
                ? trailing!
                : Flexible(fit: FlexFit.loose, child: trailing!),
        ],
      ),
    );
  }
}

class OChip extends StatelessWidget {
  const OChip({
    super.key,
    required this.label,
    this.selected = false,
    this.onTap,
    this.icon,
    this.danger = false,
    this.semanticLabel,
  });

  final String label;
  final bool selected;
  final VoidCallback? onTap;
  final IconData? icon;
  final bool danger;

  /// Overrides the spoken label when the visible text needs context
  /// ("Open file Hero.tsx"). Defaults to [label].
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    final fg = danger
        ? c.danger
        : (selected ? c.accent : c.textMuted);
    final content = AnimatedContainer(
      duration: OMotion.fast,
      curve: OMotion.standard,
      constraints: const BoxConstraints(minHeight: 34),
      padding: const EdgeInsets.symmetric(
        horizontal: OSpace.controlPad,
        vertical: OSpace.xs,
      ),
      decoration: BoxDecoration(
        color: selected ? c.accentSoft : c.surface,
        borderRadius: BorderRadius.circular(ORadius.m),
        border: Border.all(
          color: selected ? c.accentFill.withValues(alpha: 0.5) : c.hairline,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 15, color: fg),
            const SizedBox(width: OSpace.iconGap),
          ],
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: OType.label.copyWith(
                color: fg,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
    final body = SizedBox(
      height: OSpace.touch,
      child: Center(widthFactor: 1, heightFactor: 1, child: content),
    );
    if (onTap == null) {
      // Informational chip: it is not a control, so it publishes neither the
      // selected nor the enabled flag. A `selected: false` flag is still a
      // state flag, which makes TalkBack treat a static chip as interactive;
      // the state is carried in the spoken label instead.
      final spoken = semanticLabel ?? label;
      return Semantics(
        label: selected ? '$spoken, selected' : spoken,
        child: ExcludeSemantics(child: body),
      );
    }
    return OPressable(
      onTap: onTap,
      semanticLabel: semanticLabel ?? label,
      selected: selected,
      child: ExcludeSemantics(child: body),
    );
  }
}

enum OPillTone { neutral, accent, success, warn, danger }

/// A fixed-scale numeric badge: a count that sits inside another control and
/// must not reflow it.
///
/// This is the one allowed `fontSize` exception in the contract (§4): the
/// label never scales, so a 99+ badge stays inside a 120 dp model chip at
/// 200 % text. Its floor is still 11 sp. Any other status label uses [OPill].
class OCountBadge extends StatelessWidget {
  const OCountBadge({
    super.key,
    required this.count,
    this.active = false,
    this.maxCount = 99,
  });

  final int count;
  final bool active;
  final int maxCount;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    return Container(
      constraints: const BoxConstraints(minWidth: 18, minHeight: 18),
      padding: const EdgeInsets.symmetric(horizontal: OSpace.xs),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: active ? c.accentSoft : c.surfaceRaised,
        borderRadius: BorderRadius.circular(ORadius.pill),
      ),
      child: Text(
        count > maxCount ? '$maxCount+' : '$count',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        // See the class comment: a fixed scale is the point of this badge.
        textScaler: TextScaler.noScaling,
        style: OType.overline.copyWith(
          color: active ? c.accent : c.textFaint,
          fontSize: 12,
          height: 1.2,
          letterSpacing: 0,
        ),
      ),
    );
  }
}

/// The one pill/tag in the rebuilt UI: a 24 dp status label with an optional
/// leading dot or icon.
///
/// This replaces the ~25 screen-local `_Tag` / `_Pill` / `_Badge` / `_Chip`
/// copies that each re-implemented the same tone switch with a bare 10 dp
/// padding and a hand-rolled radius. Any new tag belongs here.
class OPill extends StatelessWidget {
  const OPill({
    super.key,
    required this.label,
    this.tone = OPillTone.neutral,
    this.dot = false,
    this.icon,
    this.semanticLabel,
  });

  final String label;
  final OPillTone tone;

  /// A 6 dp status dot before the label.
  final bool dot;

  /// A leading glyph, for tags that need one ("Most popular", "Connected").
  final IconData? icon;

  /// Overrides the spoken label when the visible text is an abbreviation.
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    final (bg, fg) = switch (tone) {
      OPillTone.neutral => (c.surfaceAlt, c.textMuted),
      OPillTone.accent => (c.accentSoft, c.accent),
      OPillTone.success => (c.success.withValues(alpha: 0.12), c.success),
      OPillTone.warn => (c.warn.withValues(alpha: 0.12), c.warn),
      OPillTone.danger => (c.danger.withValues(alpha: 0.12), c.danger),
    };
    final pill = Container(
      constraints: const BoxConstraints(minHeight: 24),
      padding: const EdgeInsets.symmetric(
        horizontal: OSpace.pillPad,
        vertical: OSpace.xxs,
      ),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(ORadius.pill),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (dot) ...[
            Container(
              width: 6,
              height: 6,
              decoration: BoxDecoration(color: fg, shape: BoxShape.circle),
            ),
            const SizedBox(width: OSpace.iconGap),
          ],
          if (icon != null) ...[
            Icon(icon, size: 13, color: fg),
            const SizedBox(width: OSpace.xs),
          ],
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: OType.caption.copyWith(
                color: fg,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
    if (semanticLabel == null) return pill;
    return Semantics(
      label: semanticLabel,
      container: true,
      excludeSemantics: true,
      child: pill,
    );
  }
}

class OAvatar extends StatelessWidget {
  const OAvatar({super.key, this.initials, this.image, this.size = 40, this.semanticLabel});

  final String? initials;
  final ImageProvider? image;
  final double size;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    final text = (initials ?? 'O').trim();
    final label = text.isEmpty
        ? 'O'
        : text
              .split(RegExp(r'\s+'))
              .take(2)
              .map((w) => w.characters.first)
              .join()
              .toUpperCase();
    return Semantics(
      label: semanticLabel ?? label,
      image: image != null,
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: c.accentSoft,
          image: image == null
              ? null
              : DecorationImage(image: image!, fit: BoxFit.cover),
          border: Border.all(color: c.hairline),
        ),
        alignment: Alignment.center,
        child: image != null
            ? null
            : ExcludeSemantics(
                child: Text(
                  label,
                  style: OType.label.copyWith(
                    color: c.accent,
                    // Initials scale with the circle but never drop below the
                    // 11 sp floor or above the 18 sp cap.
                    fontSize: (size * 0.36).clamp(11.0, 18.0),
                  ),
                ),
              ),
      ),
    );
  }
}

/// An avatar backed by a real photo: the image when [photoUrl] is a usable
/// HTTPS URL, initials otherwise. Loading and failure both keep the initials
/// visible, so a slow or broken URL never leaves an empty circle.
class OPhotoAvatar extends StatelessWidget {
  const OPhotoAvatar({
    super.key,
    required this.initials,
    required this.size,
    this.image,
    this.photoUrl,
    this.semanticLabel,
  });

  final String? initials;
  final double size;
  final ImageProvider? image;
  final String? photoUrl;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final fallback = OAvatar(
      initials: initials,
      image: image,
      size: size,
      semanticLabel: semanticLabel,
    );
    final uri = Uri.tryParse(photoUrl?.trim() ?? '');
    final valid = uri != null && uri.scheme == 'https' && uri.host.isNotEmpty;
    if (!valid) return fallback;
    final c = OColors.of(context);
    return Semantics(
      label: semanticLabel,
      image: true,
      excludeSemantics: true,
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: c.hairline),
        ),
        child: ClipOval(
          child: Image.network(
            uri.toString(),
            width: size,
            height: size,
            fit: BoxFit.cover,
            errorBuilder: (_, _, _) => fallback,
            loadingBuilder: (_, child, progress) =>
                progress == null ? child : fallback,
          ),
        ),
      ),
    );
  }
}

class OSearchField extends StatelessWidget {
  const OSearchField({
    super.key,
    this.controller,
    this.hint = 'Search',
    this.onChanged,
    this.onSubmitted,
    this.autofocus = false,
    this.trailing,
  });

  final TextEditingController? controller;
  final String hint;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;
  final bool autofocus;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    return TextField(
      controller: controller,
      autofocus: autofocus,
      onChanged: onChanged,
      onSubmitted: onSubmitted,
      textInputAction: TextInputAction.search,
      style: OType.bodySm.copyWith(color: c.text),
      decoration: InputDecoration(
        hintText: hint,
        prefixIcon: Icon(Icons.search_rounded, size: 20, color: c.textFaint),
        suffixIcon: trailing,
        contentPadding: const EdgeInsets.symmetric(vertical: OSpace.m),
      ),
    );
  }
}

/// The single empty-state component. No list may render a bare "No data".
class OEmptyState extends StatelessWidget {
  const OEmptyState({
    super.key,
    required this.icon,
    required this.title,
    required this.message,
    this.action,
    this.secondaryAction,
    this.compact = false,
  });

  final IconData icon;
  final String title;
  final String message;
  final Widget? action;
  final Widget? secondaryAction;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    return Center(
      child: SingleChildScrollView(
        padding: EdgeInsets.all(compact ? OSpace.l : OSpace.xl),
        child: OFadeSlide(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: compact ? 56 : 72,
                height: compact ? 56 : 72,
                decoration: BoxDecoration(
                  color: c.accentSoft,
                  shape: BoxShape.circle,
                ),
                child: Icon(icon, size: compact ? 26 : 32, color: c.accent),
              ),
              SizedBox(height: compact ? OSpace.m : OSpace.l),
              Semantics(
                container: true,
                header: true,
                child: Text(
                  title,
                  textAlign: TextAlign.center,
                  style: OType.h2.copyWith(color: c.text),
                ),
              ),
              const SizedBox(height: OSpace.s),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 320),
                child: Text(
                  message,
                  textAlign: TextAlign.center,
                  style: OType.bodySm.copyWith(color: c.textMuted),
                ),
              ),
              if (action != null) ...[
                const SizedBox(height: OSpace.l),
                action!,
              ],
              if (secondaryAction != null) ...[
                const SizedBox(height: OSpace.s),
                secondaryAction!,
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class OErrorState extends StatelessWidget {
  const OErrorState({
    super.key,
    this.title = 'That did not work',
    required this.message,
    this.onRetry,
    this.retryLabel = 'Try again',
  });

  final String title;
  final String message;
  final VoidCallback? onRetry;
  final String retryLabel;

  @override
  Widget build(BuildContext context) {
    return OEmptyState(
      icon: Icons.error_outline_rounded,
      title: title,
      message: message,
      action: onRetry == null
          ? null
          : OButton(
              label: retryLabel,
              icon: Icons.refresh_rounded,
              onPressed: onRetry,
            ),
    );
  }
}

class OLoadingState extends StatelessWidget {
  const OLoadingState({super.key, this.label});

  final String? label;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 26,
            height: 26,
            child: CircularProgressIndicator(
              strokeWidth: 2.4,
              color: c.accentFill,
            ),
          ),
          if (label != null) ...[
            const SizedBox(height: OSpace.m),
            Text(label!, style: OType.bodySm.copyWith(color: c.textMuted)),
          ],
        ],
      ),
    );
  }
}

/// Shimmer skeleton. Honours reduced motion (renders a static block).
class OSkeleton extends StatefulWidget {
  const OSkeleton({
    super.key,
    this.width,
    this.height = 14,
    this.radius = ORadius.s,
  });

  final double? width;
  final double height;
  final double radius;

  @override
  State<OSkeleton> createState() => _OSkeletonState();
}

class _OSkeletonState extends State<OSkeleton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (OMove.reduced(context)) {
      _controller.stop();
    } else if (!_controller.isAnimating) {
      _controller.repeat();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    final base = c.surfaceAlt;
    final highlight = c.surfaceRaised;
    final reduced = OMove.reduced(context);
    return SizedBox(
      width: widget.width,
      height: widget.height,
      child: reduced
          ? DecoratedBox(
              decoration: BoxDecoration(
                color: base,
                borderRadius: BorderRadius.circular(widget.radius),
              ),
            )
          // Flat system: a loading placeholder pulses its opacity rather than
          // sweeping a gradient across the surface.
          : AnimatedBuilder(
              animation: _controller,
              builder: (context, _) {
                final t = _controller.value;
                final pulse = 0.55 + (t < 0.5 ? t : 1 - t) * 0.45;
                return DecoratedBox(
                  decoration: BoxDecoration(
                    color: Color.lerp(base, highlight, pulse),
                    borderRadius: BorderRadius.circular(widget.radius),
                  ),
                );
              },
            ),
    );
  }
}

class OSkeletonList extends StatelessWidget {
  const OSkeletonList({super.key, this.rows = 6});

  final int rows;

  @override
  Widget build(BuildContext context) {
    return ListView.separated(
      padding: const EdgeInsets.all(OSpace.l),
      itemCount: rows,
      separatorBuilder: (_, _) => const SizedBox(height: OSpace.l),
      itemBuilder: (_, index) => Row(
        children: [
          const OSkeleton(width: 40, height: 40, radius: ORadius.m),
          const SizedBox(width: OSpace.m),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                OSkeleton(width: index.isEven ? 180 : 140, height: 14),
                const SizedBox(height: OSpace.s),
                const OSkeleton(width: 96, height: 11),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Standard app bar for every rebuilt screen.
class OAppBar extends StatelessWidget implements PreferredSizeWidget {
  const OAppBar({
    super.key,
    required this.title,
    this.subtitle,
    this.leading,
    this.actions = const <Widget>[],
    this.bottom,
    this.showBack = true,
  });

  final String title;
  final String? subtitle;
  final Widget? leading;
  final List<Widget> actions;
  final PreferredSizeWidget? bottom;
  final bool showBack;

  @override
  Size get preferredSize =>
      Size.fromHeight(56 + (subtitle == null ? 0 : 20) + (bottom?.preferredSize.height ?? 0));

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    return Semantics(
      container: true,
      explicitChildNodes: true,
      // TalkBack reads the tree in widget order; the Scaffold lays the body
      // out before the app bar, which would read content before its title.
      // Sort keys keep the visible top-to-bottom order.
      sortKey: OrdinalSortKey(0),
      child: AppBar(
      automaticallyImplyLeading: false,
      leading: leading ??
          (showBack
              ? OIconButton(
                  icon: Icons.arrow_back_rounded,
                  semanticLabel: 'Back',
                  onPressed: () => Navigator.maybePop(context),
                )
              : null),
      titleSpacing: showBack || leading != null ? 0 : OSpace.l,
      title: MediaQuery.withClampedTextScaling(
        maxScaleFactor: 1.3,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Semantics(
              container: true,
              header: true,
              child: Text(
                title,
                style: OType.h2.copyWith(color: c.text),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (subtitle != null)
              Text(
                subtitle!,
                style: OType.caption.copyWith(color: c.textMuted),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
          ],
        ),
      ),
      actions: [
        ...actions,
        const SizedBox(width: OSpace.s),
      ],
      bottom: bottom,
      ),
    );
  }
}

/// Scaffold with the design background and safe-area body.
class OScaffold extends StatelessWidget {
  const OScaffold({
    super.key,
    this.appBar,
    required this.body,
    this.floatingActionButton,
    this.bottomNavigationBar,
    this.resizeToAvoidBottomInset = true,
    this.backgroundColor,
  });

  final PreferredSizeWidget? appBar;
  final Widget body;
  final Widget? floatingActionButton;
  final Widget? bottomNavigationBar;
  final bool resizeToAvoidBottomInset;
  final Color? backgroundColor;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    return Scaffold(
      backgroundColor: backgroundColor ?? c.bg,
      appBar: appBar,
      body: Semantics(
        container: true,
        explicitChildNodes: true,
        sortKey: OrdinalSortKey(1),
        child: SafeArea(child: body),
      ),
      floatingActionButton: floatingActionButton,
      bottomNavigationBar: bottomNavigationBar,
      resizeToAvoidBottomInset: resizeToAvoidBottomInset,
    );
  }
}

/// The one header row inside a bottom sheet: optional leading control or icon
/// tile, a title with one optional line of context, and a close control.
///
/// [showOSheet] draws the grabber and uses this widget for its own title, so a
/// sheet that needs a subtitle, a leading control or a close button keeps the
/// same rhythm instead of hand-rolling a `_Header` in its body.
class OSheetHeader extends StatelessWidget {
  const OSheetHeader({
    super.key,
    this.title,
    this.subtitle,
    this.icon,
    this.leading,
    this.titleTrailing,
    this.body,
    this.onClose,
    this.closeLabel = 'Close',
    this.closeKey,
    this.padding = const EdgeInsets.fromLTRB(
      OSpace.l,
      OSpace.l,
      OSpace.s,
      OSpace.s,
    ),
  });

  /// Null for a navigation-only row (for example back + close).
  final String? title;

  /// One line of context under the title.
  final String? subtitle;

  /// A 40 dp accent tile before the title.
  final IconData? icon;

  /// Replaces [icon] when the leading element is a control.
  final Widget? leading;

  /// A status glyph beside the title (a dot, a pill).
  final Widget? titleTrailing;

  /// A full-width line under the title row, for a sheet's intro copy.
  final String? body;

  /// Defaults to popping the route, because a sheet is always dismissible.
  /// Pass a handler to do extra work first (discard a draft, abort a request).
  final VoidCallback? onClose;
  final String closeLabel;
  final Key? closeKey;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    final lead =
        leading ??
        (icon == null
            ? null
            : Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: c.accentSoft,
                  borderRadius: BorderRadius.circular(ORadius.m),
                ),
                child: Icon(icon, size: 21, color: c.accent),
              ));
    final hasTitle = title != null;
    // A sheet always has a way out. Without a default the header silently
    // dropped its close whenever a caller forgot the callback, which left the
    // user with no visible dismiss affordance.
    final close = onClose ??
        (Navigator.of(context).canPop()
            ? () => Navigator.maybePop(context)
            : null);
    return Padding(
      padding: padding,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (lead != null) ...[
                lead,
                if (hasTitle) const SizedBox(width: OSpace.m),
              ],
              if (hasTitle)
                Expanded(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Semantics(
                              container: true,
                              header: true,
                              child: Text(
                                title!,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: OType.h2.copyWith(color: c.text),
                              ),
                            ),
                          ),
                          if (titleTrailing != null) ...[
                            const SizedBox(width: OSpace.s),
                            titleTrailing!,
                          ],
                        ],
                      ),
                      if (subtitle != null) ...[
                        const SizedBox(height: OSpace.xxs),
                        Text(
                          subtitle!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: OType.caption.copyWith(color: c.textMuted),
                        ),
                      ],
                    ],
                  ),
                )
              else
                const Spacer(),
              if (close != null) ...[
                const SizedBox(width: OSpace.s),
                OIconButton(
                  key: closeKey,
                  icon: Icons.close_rounded,
                  semanticLabel: closeLabel,
                  onPressed: close,
                ),
              ],
            ],
          ),
          if (body != null) ...[
            const SizedBox(height: OSpace.s),
            Text(body!, style: OType.bodySm.copyWith(color: c.textMuted)),
          ],
        ],
      ),
    );
  }
}

/// Bottom sheet with the shared grabber, title and motion.
///
/// From [OBreakpoints.tablet] up a sheet is a centred dialog capped at 560 dp:
/// a full-width bottom sheet on a desktop reads as a page that forgot to end.
/// Below the breakpoint it stays the phone bottom sheet.
Future<T?> showOSheet<T>(
  BuildContext context, {
  required WidgetBuilder builder,
  String? title,
  bool isScrollControlled = true,
  bool useSafeArea = true,
}) {
  final c = OColors.of(context);
  if (MediaQuery.sizeOf(context).width >= OBreakpoints.tablet) {
    return showDialog<T>(
      context: context,
      barrierColor: c.scrim,
      builder: (context) {
        final media = MediaQuery.of(context);
        return AnimatedPadding(
          duration: OMotion.fast,
          curve: OMotion.standard,
          padding: EdgeInsets.only(bottom: media.viewInsets.bottom),
          child: Dialog(
            backgroundColor: Colors.transparent,
            insetPadding: const EdgeInsets.all(OSpace.xl),
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: 560,
                maxHeight: media.size.height * 0.9,
              ),
              child: Material(
                key: const ValueKey<String>('o-sheet-surface'),
                color: c.surface,
                clipBehavior: Clip.antiAlias,
                borderRadius: BorderRadius.circular(ORadius.xl),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (title != null)
                      OSheetHeader(
                        title: title,
                        padding: const EdgeInsets.fromLTRB(
                          OSpace.l,
                          OSpace.l,
                          OSpace.s,
                          OSpace.s,
                        ),
                      ),
                    Flexible(child: builder(context)),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: isScrollControlled,
    useSafeArea: useSafeArea,
    backgroundColor: OColors.of(context).surface,
    barrierColor: OColors.of(context).scrim,
    builder: (context) {
      final c = OColors.of(context);
      return ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.9,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: OSpace.s),
            Container(
              width: 36,
              height: OSpace.xs,
              decoration: BoxDecoration(
                color: c.hairlineStrong,
                borderRadius: BorderRadius.circular(ORadius.pill),
              ),
            ),
            if (title != null)
              OSheetHeader(
                title: title,
                padding: const EdgeInsets.fromLTRB(
                  OSpace.l,
                  OSpace.m,
                  OSpace.l,
                  OSpace.s,
                ),
              ),
            Flexible(child: builder(context)),
            SizedBox(height: MediaQuery.viewInsetsOf(context).bottom),
          ],
        ),
      );
    },
  );
}

void showOSnack(BuildContext context, String message, {String? action, VoidCallback? onAction}) {
  final messenger = ScaffoldMessenger.maybeOf(context);
  if (messenger == null) return;
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        content: Text(message),
        action: action == null
            ? null
            : SnackBarAction(label: action, onPressed: onAction ?? () {}),
      ),
    );
}

/// Thin progress bar with the accent colour.
class OProgressBar extends StatelessWidget {
  const OProgressBar({super.key, required this.value, this.height = 6});

  final double value;
  final double height;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    return ClipRRect(
      borderRadius: BorderRadius.circular(ORadius.pill),
      child: TweenAnimationBuilder<double>(
        tween: Tween<double>(begin: 0, end: value.clamp(0, 1)),
        duration: OMotion.slow,
        curve: OMotion.emphasized,
        builder: (context, v, _) => LinearProgressIndicator(
          value: v,
          minHeight: height,
          backgroundColor: c.surfaceRaised,
          valueColor: AlwaysStoppedAnimation<Color>(c.accentFill),
        ),
      ),
    );
  }
}

/// Small keyboard-dismiss surface used by forms.
class ODismissKeyboard extends StatelessWidget {
  const ODismissKeyboard({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onTap: () => FocusManager.instance.primaryFocus?.unfocus(),
      child: child,
    );
  }
}
