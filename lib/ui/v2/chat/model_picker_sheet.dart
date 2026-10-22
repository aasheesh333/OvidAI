import 'package:flutter/material.dart';

import '../../design/o_components.dart';
import '../../design/o_motion.dart';
import '../../design/o_tokens.dart';
import 'composer_sheet.dart';

// TODO(l10n): move user-facing copy to ARB keys in the localization pass.

/// One selectable model row. The shape mirrors the shared model contract:
/// id, name, subtitle, speed, costHint, locked.
@immutable
class V2ModelOption {
  const V2ModelOption({
    required this.id,
    required this.name,
    required this.subtitle,
    required this.speed,
    required this.costHint,
    this.locked = false,
    this.tag,
    this.tagTone = OPillTone.accent,
    this.icon = Icons.auto_awesome_rounded,
  });

  final String id;
  final String name;
  final String subtitle;
  final String speed;
  final String costHint;
  final bool locked;
  final String? tag;
  final OPillTone tagTone;
  final IconData icon;
}

/// Everything the model picker needs to render. The caller owns selection.
@immutable
class V2ModelPickerData {
  const V2ModelPickerData({
    required this.models,
    this.selectedId = 'auto',
    this.planLabel = 'Free',
    this.autoName = 'Auto',
    this.autoSubtitle = 'Smart routing',
    this.autoDescription =
        'Automatically picks the fastest, smartest model for your question.',
    this.autoTag = 'Recommended',
    this.searchHint = 'Search models',
    this.manageLabel = 'Manage models',
    this.freePlanNote = 'Free plan uses Auto only.',
    this.standardLabel = 'Standard models',
    this.advancedLabel = 'Advanced reasoning',
    this.manualModelsAllowed = true,
    this.upgradeHint =
        'Upgrade to Plus or Pro to pick a model manually. '
        'Auto is included on every plan.',
    this.lockedPlanLabel = 'Plus plan',
    this.loading = false,
    this.errorMessage,
  });

  final List<V2ModelOption> models;
  final String selectedId;
  final String planLabel;
  final String autoName;

  /// The one description line on the Auto card.
  final String autoSubtitle;

  /// Kept so callers keep compiling. The minimal card draws [autoSubtitle]
  /// only; there is no second paragraph and no tag.
  final String autoDescription;
  final String autoTag;
  final String searchHint;
  final String manageLabel;

  /// Kept for callers. The plan gate lives on the locked rows, so the sheet
  /// draws no footer note.
  final String freePlanNote;
  final String standardLabel;
  final String advancedLabel;

  /// Whether the current plan may pick a model manually. Free and Go are
  /// Auto-only; Plus and Pro allow every model. When false, manual rows stay
  /// visible but are greyed out and cannot be selected.
  final bool manualModelsAllowed;

  /// Kept for callers. The minimal sheet shows the gate as a row tag instead
  /// of an upgrade paragraph.
  final String upgradeHint;

  /// Plan a manual model requires, used by the locked-row tag and its spoken
  /// label. Free and Go both need Plus.
  final String lockedPlanLabel;
  final bool loading;
  final String? errorMessage;

  bool get autoSelected => selectedId == 'auto';

  /// True when the plan can only use Auto, regardless of per-row flags. The
  /// explicit [manualModelsAllowed] gate wins, and an Auto-only plan label is
  /// also treated as such so a caller that forgets the flag cannot leak manual
  /// models. `Starter` is the catalog's legacy name for the Go tier.
  bool get autoOnly =>
      !manualModelsAllowed ||
      planLabel == 'Free' ||
      planLabel == 'Free plan' ||
      planLabel == 'Go' ||
      planLabel == 'Starter';
}

/// Bottom-sheet contents for choosing a model. Search, Auto recommendation,
/// model rows and a locked paid tier.
class V2ModelPickerSheet extends StatefulWidget {
  const V2ModelPickerSheet({
    super.key,
    required this.data,
    required this.onSelect,
    required this.onManageModels,
    this.onClose,
    this.onRetry,
  });

  final V2ModelPickerData data;
  final ValueChanged<String> onSelect;
  final VoidCallback onManageModels;
  final VoidCallback? onClose;
  final VoidCallback? onRetry;

  @override
  State<V2ModelPickerSheet> createState() => _V2ModelPickerSheetState();
}

class _V2ModelPickerSheetState extends State<V2ModelPickerSheet> {
  final TextEditingController _search = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  void _clearSearch() {
    _search.clear();
    setState(() => _query = '');
  }

  bool _matches(V2ModelOption model) {
    if (_query.trim().isEmpty) return true;
    final q = _query.toLowerCase();
    return model.name.toLowerCase().contains(q) ||
        model.subtitle.toLowerCase().contains(q) ||
        model.speed.toLowerCase().contains(q) ||
        model.costHint.toLowerCase().contains(q);
  }

  bool get _autoMatches {
    if (_query.trim().isEmpty) return true;
    final q = _query.toLowerCase();
    final d = widget.data;
    return d.autoName.toLowerCase().contains(q) ||
        d.autoSubtitle.toLowerCase().contains(q);
  }

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    final data = widget.data;
    final models = data.models.where(_matches).toList(growable: false);
    final showAuto = _autoMatches;
    final hasResults = showAuto || models.isNotEmpty;

    return Material(
      color: c.surface,
      // A sheet body never stretches past the contract's 560 dp dialog cap,
      // even when a gallery or test renders it outside showV2ChatSheet.
      child: Center(
        heightFactor: 1,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  OSpace.l,
                  OSpace.s,
                  OSpace.s,
                  0,
                ),
                child: OSheetHeader(
                  title: 'Select model',
                  onClose: widget.onClose ?? () => Navigator.maybePop(context),
                  closeLabel: 'Close model picker',
                  padding: EdgeInsets.zero,
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  OSpace.l,
                  OSpace.m,
                  OSpace.l,
                  OSpace.s,
                ),
                child: OSearchField(
                  controller: _search,
                  hint: data.searchHint,
                  onChanged: (value) => setState(() => _query = value),
                  trailing: _query.isEmpty
                      ? null
                      : IconButton(
                          tooltip: 'Clear search',
                          onPressed: _clearSearch,
                          icon: Icon(
                            Icons.cancel_rounded,
                            size: 18,
                            color: c.textFaint,
                          ),
                        ),
                ),
              ),
              Flexible(
                child: OAnimatedSwap(
                  child: _buildBody(models, showAuto, hasResults),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  OSpace.l,
                  OSpace.s,
                  OSpace.l,
                  OSpace.l,
                ),
                child: OButton(
                  label: data.manageLabel,
                  icon: Icons.tune_rounded,
                  variant: OButtonVariant.secondary,
                  expand: true,
                  onPressed: widget.onManageModels,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBody(
    List<V2ModelOption> models,
    bool showAuto,
    bool hasResults,
  ) {
    final data = widget.data;
    if (data.loading) {
      return const SizedBox(height: 280, child: OSkeletonList(rows: 4));
    }
    if (data.errorMessage != null) {
      return SizedBox(
        height: 280,
        child: OErrorState(
          message: data.errorMessage!,
          onRetry: widget.onRetry,
        ),
      );
    }
    if (!hasResults) {
      return SizedBox(
        height: 300,
        child: OEmptyState(
          compact: true,
          icon: Icons.search_off_rounded,
          title: 'No models found',
          message: 'Try another name.',
          action: OButton(
            label: 'Clear search',
            variant: OButtonVariant.secondary,
            onPressed: _clearSearch,
          ),
        ),
      );
    }

    final rows = <Widget>[];
    if (showAuto) {
      rows.add(_AutoCard(data: data, onTap: () => widget.onSelect('auto')));
    }

    Widget row(V2ModelOption model) => _ModelRow(
      model: model,
      selected: data.selectedId == model.id,
      // The plan gate wins over the row flag: on an Auto-only plan every
      // manual model is locked even if the caller left it unlocked.
      locked: data.autoOnly || model.locked,
      planLabel: data.lockedPlanLabel,
      onTap: (data.autoOnly || model.locked)
          ? null
          : () => widget.onSelect(model.id),
    );

    // Grouped by tier so the labels always read Standard then Advanced, even
    // when the caller interleaves the two.
    final standard = models.where((model) => !model.locked).toList();
    final advanced = models.where((model) => model.locked).toList();
    if (standard.isNotEmpty) {
      rows.add(
        OSectionHeader(
          label: data.standardLabel,
          padding: const EdgeInsets.fromLTRB(
            OSpace.xs,
            OSpace.m,
            OSpace.xs,
            OSpace.xs,
          ),
        ),
      );
      rows.addAll(standard.map(row));
    }
    if (advanced.isNotEmpty) {
      rows.add(
        OSectionHeader(
          label: data.advancedLabel,
          padding: const EdgeInsets.fromLTRB(
            OSpace.xs,
            OSpace.m,
            OSpace.xs,
            OSpace.xs,
          ),
        ),
      );
      rows.addAll(advanced.map(row));
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(
        OSpace.l,
        OSpace.xs,
        OSpace.l,
        OSpace.s,
      ),
      child: OStagger(children: rows),
    );
  }
}

class _AutoCard extends StatelessWidget {
  const _AutoCard({required this.data, required this.onTap});

  final V2ModelPickerData data;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    final selected = data.autoSelected;
    return Semantics(
      selected: selected,
      child: OCard(
        accent: selected,
        onTap: onTap,
        semanticLabel: '${data.autoName}, ${data.autoSubtitle}',
        child: Row(
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: c.accentSoft,
                shape: BoxShape.circle,
              ),
              child: Icon(
                Icons.auto_awesome_rounded,
                size: 20,
                color: c.accent,
              ),
            ),
            const SizedBox(width: OSpace.m),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    data.autoName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: OType.bodyStrong.copyWith(color: c.text),
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
            _SelectionMark(selected: selected),
          ],
        ),
      ),
    );
  }
}

class _ModelRow extends StatelessWidget {
  const _ModelRow({
    required this.model,
    required this.selected,
    required this.locked,
    required this.planLabel,
    required this.onTap,
  });

  final V2ModelOption model;
  final bool selected;
  final bool locked;
  final String planLabel;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    // One meta line, then the cost. A locked row carries the plan gate as its
    // only tag; the caller's tag is dropped when it would repeat the gate.
    final gateTag = locked ? planLabel : null;
    final row = Container(
      constraints: const BoxConstraints(minHeight: OSpace.listRow),
      padding: const EdgeInsets.symmetric(
        horizontal: OSpace.m,
        vertical: OSpace.s,
      ),
      decoration: BoxDecoration(
        color: locked ? c.surfaceAlt.withValues(alpha: 0.55) : c.surface,
        borderRadius: BorderRadius.circular(ORadius.l),
        border: Border.all(color: c.hairline),
      ),
      child: Row(
        children: [
          ExcludeSemantics(
            child: Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: c.surfaceAlt,
                borderRadius: BorderRadius.circular(ORadius.m),
              ),
              child: Icon(
                locked ? Icons.lock_outline_rounded : model.icon,
                size: 19,
                color: locked ? c.textFaint : c.textMuted,
              ),
            ),
          ),
          const SizedBox(width: OSpace.m),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Wrap(
                  spacing: OSpace.s,
                  runSpacing: OSpace.xs,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text(
                      model.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: OType.body.copyWith(
                        color: locked ? c.textMuted : c.text,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    if (gateTag != null)
                      OPill(label: gateTag, tone: OPillTone.accent),
                  ],
                ),
                const SizedBox(height: 2),
                // Wrap, not Row: at 200 % text the meta line and the cost each
                // get a full line instead of overflowing the row.
                Wrap(
                  spacing: OSpace.s,
                  runSpacing: OSpace.xxs,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text(
                      model.subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: OType.caption.copyWith(color: c.textMuted),
                    ),
                    Text(
                      model.costHint,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: OType.caption.copyWith(color: c.textFaint),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(width: OSpace.xs),
          if (locked)
            ExcludeSemantics(
              child: Icon(
                Icons.lock_outline_rounded,
                size: 18,
                color: c.textFaint,
              ),
            )
          else
            _SelectionMark(selected: selected),
        ],
      ),
    );

    if (onTap == null) {
      return Semantics(
        label: '${model.name}, locked, $planLabel',
        enabled: false,
        child: row,
      );
    }
    return Semantics(
      selected: selected,
      child: OPressable(
        onTap: onTap,
        semanticLabel: '${model.name}, ${model.subtitle}',
        child: row,
      ),
    );
  }
}

class _SelectionMark extends StatelessWidget {
  const _SelectionMark({required this.selected});

  final bool selected;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    return Container(
      width: 26,
      height: 26,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: selected ? c.accentFill : Colors.transparent,
        border: Border.all(color: selected ? c.accentFill : c.hairlineStrong),
      ),
      child: selected
          ? Icon(Icons.check_rounded, size: 16, color: c.onAccent)
          : null,
    );
  }
}

/// Opens the picker in the shared sheet container. Selection and manage
/// actions close the sheet after the caller callback runs.
Future<void> showV2ModelPickerSheet(
  BuildContext context, {
  required V2ModelPickerData data,
  required ValueChanged<String> onSelect,
  required VoidCallback onManageModels,
  VoidCallback? onRetry,
}) {
  return showV2ChatSheet<void>(
    context,
    builder: (sheetContext) => V2ModelPickerSheet(
      data: data,
      onSelect: (id) {
        Navigator.of(sheetContext).maybePop();
        onSelect(id);
      },
      onManageModels: () {
        Navigator.of(sheetContext).maybePop();
        onManageModels();
      },
      onRetry: onRetry,
      onClose: () => Navigator.of(sheetContext).maybePop(),
    ),
  );
}
