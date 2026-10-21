import 'package:flutter/material.dart';

import '../../design/o_components.dart';
import '../../design/o_motion.dart';
import '../../design/o_tokens.dart';

// TODO(l10n): move user-facing copy to ARB keys in the localization pass.

/// Widest the popover ever gets; narrower phones get a full-width menu.
const double _menuMaxWidth = 336;

/// Plan a locked model belongs to. Kept in one place so the pill and the
/// spoken label can never drift apart.
const String _lockedPlanLabel = 'Plus plan';

/// A locked model row in the compact chip menu.
@immutable
class V2ChipModel {
  const V2ChipModel({
    required this.id,
    required this.name,
    required this.subtitle,
    this.icon = Icons.auto_awesome_rounded,
  });

  final String id;
  final String name;
  final String subtitle;
  final IconData icon;
}

/// Data for the compact model menu anchored under the chat model chip.
@immutable
class V2ModelChipMenuData {
  const V2ModelChipMenuData({
    required this.lockedModels,
    this.tierLabel = 'Free',
    this.autoName = 'Auto',
    this.autoSubtitle = 'Picks the best model for each task',
    this.autoTag = 'Included free',
    this.autoSelected = true,
    this.manageLabel = 'Manage models',
    this.compareLabel = 'Compare plans',
    this.comparePriceLabel = 'From \$18/mo',
    this.note = 'Free plan uses Auto only.',
  });

  final List<V2ChipModel> lockedModels;
  final String tierLabel;
  final String autoName;
  final String autoSubtitle;
  final String autoTag;
  final bool autoSelected;
  final String manageLabel;
  final String compareLabel;
  final String comparePriceLabel;
  final String note;
}

/// Compact popover shown from the model chip in the chat app bar.
class V2ModelChipMenu extends StatelessWidget {
  const V2ModelChipMenu({
    super.key,
    required this.data,
    required this.onSelect,
    required this.onManageModels,
    required this.onComparePlans,
  });

  final V2ModelChipMenuData data;
  final ValueChanged<String> onSelect;
  final VoidCallback onManageModels;
  final VoidCallback onComparePlans;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    return Container(
      width: double.infinity,
      constraints: const BoxConstraints(maxWidth: _menuMaxWidth),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(ORadius.l),
        border: Border.all(color: c.hairline),
        boxShadow: OShadow.sheet,
      ),
      padding: const EdgeInsets.all(OSpace.s),
      // The menu grows with the text scale, so it scrolls instead of
      // overflowing a short screen. When the parent leaves the height
      // unbounded it simply sizes to its content.
      clipBehavior: Clip.antiAlias,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                OSpace.s,
                OSpace.xs,
                OSpace.s,
                OSpace.s,
              ),
              child: Wrap(
                alignment: WrapAlignment.spaceBetween,
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: OSpace.s,
                runSpacing: OSpace.xs,
                children: [
                  Text(
                    'MODEL SELECTION',
                    style: OType.overline.copyWith(color: c.textMuted),
                  ),
                  Text(
                    'Tier: ${data.tierLabel}',
                    style: OType.overline.copyWith(color: c.textFaint),
                  ),
                ],
              ),
            ),
            _AutoRow(data: data, onTap: () => onSelect('auto')),
            for (final model in data.lockedModels) _LockedRow(model: model),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: OSpace.s),
              child: Divider(height: 1, color: c.hairline),
            ),
            _ActionRow(
              icon: Icons.key_rounded,
              label: data.manageLabel,
              onTap: onManageModels,
            ),
            _ActionRow(
              icon: Icons.stars_rounded,
              label: data.compareLabel,
              trailing: data.comparePriceLabel,
              accent: true,
              onTap: onComparePlans,
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(
                OSpace.s,
                OSpace.s,
                OSpace.s,
                OSpace.xs,
              ),
              child: Text(
                data.note,
                style: OType.caption.copyWith(color: c.textFaint),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Small status tag. Mirrors the shared `OPill` look but grows with the text
/// scale instead of clipping its label inside a fixed 24 dp box.
class _PlanTag extends StatelessWidget {
  const _PlanTag({required this.label, required this.tone});

  final String label;
  final OPillTone tone;

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
    return Container(
      constraints: const BoxConstraints(minHeight: 24),
      padding: const EdgeInsets.symmetric(horizontal: 10),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(ORadius.pill),
      ),
      child: Text(
        label,
        style: OType.caption.copyWith(color: fg, fontWeight: FontWeight.w600),
      ),
    );
  }
}

class _AutoRow extends StatelessWidget {
  const _AutoRow({required this.data, required this.onTap});

  final V2ModelChipMenuData data;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    return Semantics(
      label: '${data.autoName}, ${data.autoTag}',
      button: true,
      selected: data.autoSelected,
      onTap: onTap,
      excludeSemantics: true,
      child: OPressable(
        onTap: onTap,
        child: Container(
          constraints: const BoxConstraints(minHeight: OSpace.listRow),
          padding: const EdgeInsets.all(OSpace.s),
          decoration: BoxDecoration(
            color: c.surfaceAlt,
            borderRadius: BorderRadius.circular(ORadius.m),
          ),
          child: Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: c.accentSoft,
                  borderRadius: BorderRadius.circular(ORadius.m),
                ),
                child: Icon(
                  Icons.auto_awesome_rounded,
                  size: 20,
                  color: c.accent,
                ),
              ),
              const SizedBox(width: OSpace.s),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Wrap(
                      spacing: OSpace.xs,
                      runSpacing: 2,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Text(
                          data.autoName,
                          style: OType.label.copyWith(color: c.text),
                        ),
                        _PlanTag(label: data.autoTag, tone: OPillTone.success),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      data.autoSubtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: OType.caption.copyWith(color: c.textMuted),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: OSpace.s),
              Icon(
                data.autoSelected
                    ? Icons.check_circle_rounded
                    : Icons.radio_button_unchecked_rounded,
                size: 22,
                color: data.autoSelected ? c.accent : c.textFaint,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _LockedRow extends StatelessWidget {
  const _LockedRow({required this.model});

  final V2ChipModel model;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    return Semantics(
      label: '${model.name}, ${model.subtitle}, locked, $_lockedPlanLabel',
      enabled: false,
      excludeSemantics: true,
      child: Container(
        constraints: const BoxConstraints(minHeight: OSpace.listRow),
        padding: const EdgeInsets.all(OSpace.s),
        child: LayoutBuilder(
          builder: (context, constraints) => Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: c.surfaceAlt,
                  borderRadius: BorderRadius.circular(ORadius.m),
                ),
                child: Icon(model.icon, size: 20, color: c.textFaint),
              ),
              const SizedBox(width: OSpace.s),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      model.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: OType.label.copyWith(
                        color: c.textMuted,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      model.subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: OType.caption.copyWith(color: c.textFaint),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: OSpace.xs),
              // The tag never takes more than half the row; its own label
              // wraps rather than pushing the row past the screen edge.
              ConstrainedBox(
                constraints: BoxConstraints(maxWidth: constraints.maxWidth / 2),
                child: const _PlanTag(
                  label: _lockedPlanLabel,
                  tone: OPillTone.accent,
                ),
              ),
              const SizedBox(width: OSpace.xs),
              Icon(Icons.lock_outline_rounded, size: 18, color: c.textFaint),
            ],
          ),
        ),
      ),
    );
  }
}

class _ActionRow extends StatelessWidget {
  const _ActionRow({
    required this.icon,
    required this.label,
    required this.onTap,
    this.trailing,
    this.accent = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final String? trailing;
  final bool accent;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    final fg = accent ? c.accent : c.text;
    return Semantics(
      label: trailing == null ? label : '$label, $trailing',
      button: true,
      onTap: onTap,
      excludeSemantics: true,
      child: Material(
        color: accent ? c.accentSoft : Colors.transparent,
        borderRadius: BorderRadius.circular(ORadius.m),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(ORadius.m),
          child: Container(
            constraints: const BoxConstraints(minHeight: OSpace.touch),
            padding: const EdgeInsets.symmetric(horizontal: OSpace.s),
            child: Row(
              children: [
                Icon(icon, size: 19, color: accent ? c.accent : c.textMuted),
                const SizedBox(width: OSpace.s),
                Expanded(
                  child: Wrap(
                    alignment: WrapAlignment.spaceBetween,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    spacing: OSpace.s,
                    runSpacing: 2,
                    children: [
                      Text(
                        label,
                        style: OType.label.copyWith(
                          color: fg,
                          fontWeight: accent
                              ? FontWeight.w600
                              : FontWeight.w500,
                        ),
                      ),
                      if (trailing != null)
                        Text(
                          trailing!,
                          style: OType.caption.copyWith(color: c.accent),
                        ),
                    ],
                  ),
                ),
                const SizedBox(width: OSpace.xs),
                Icon(Icons.chevron_right_rounded, size: 18, color: c.textFaint),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Shows the compact model menu near the top-left of the screen. The caller
/// supplies the anchor when it has one; otherwise it opens under the app bar.
Future<void> showV2ModelChipMenu(
  BuildContext context, {
  required V2ModelChipMenuData data,
  required ValueChanged<String> onSelect,
  required VoidCallback onManageModels,
  required VoidCallback onComparePlans,
  Rect? anchor,
}) {
  final c = OColors.of(context);
  final media = MediaQuery.sizeOf(context);
  final insets = MediaQuery.paddingOf(context);
  final available = media.width - OSpace.m * 2;
  final width = available < _menuMaxWidth ? available : _menuMaxWidth;
  final rawTop = anchor == null ? 88.0 : anchor.bottom + OSpace.s;
  // Keep the menu on screen and leave it a scrollable height on short phones.
  final minTop = insets.top + OSpace.s;
  final maxTop = media.height - insets.bottom - 200;
  final top = rawTop
      .clamp(minTop, maxTop < minTop ? minTop : maxTop)
      .toDouble();
  final maxHeight = media.height - insets.bottom - top - OSpace.s;

  return showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'Close model menu',
    barrierColor: c.scrim,
    transitionDuration: OMove.duration(context, OMotion.fast),
    pageBuilder: (dialogContext, animation, secondaryAnimation) {
      return Stack(
        children: [
          Positioned(
            left: OSpace.m,
            top: top,
            width: width,
            child: Material(
              color: Colors.transparent,
              child: OFadeSlide(
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    maxHeight: maxHeight < 160 ? 160 : maxHeight,
                  ),
                  child: V2ModelChipMenu(
                    data: data,
                    onSelect: (id) {
                      Navigator.of(dialogContext).maybePop();
                      onSelect(id);
                    },
                    onManageModels: () {
                      Navigator.of(dialogContext).maybePop();
                      onManageModels();
                    },
                    onComparePlans: () {
                      Navigator.of(dialogContext).maybePop();
                      onComparePlans();
                    },
                  ),
                ),
              ),
            ),
          ),
        ],
      );
    },
    transitionBuilder: (dialogContext, animation, secondaryAnimation, child) {
      return FadeTransition(opacity: animation, child: child);
    },
  );
}
