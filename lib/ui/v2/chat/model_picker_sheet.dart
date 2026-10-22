import 'package:flutter/material.dart';

import '../../design/o_components.dart';
import '../../design/o_motion.dart';
import '../../design/o_tokens.dart';
import 'composer_sheet.dart';

// TODO(l10n): move user-facing copy to ARB keys in the localization pass.

/// One selectable model row. The shape mirrors the shared model contract:
/// id, name, subtitle, costHint, locked.
///
/// There is deliberately no speed or latency field. The chat catalogue carries
/// no measured per-model value for either (the only timing the app holds is the
/// analytics of the session that just ran), so a row cannot state one without
/// inventing it.
@immutable
class V2ModelOption {
  const V2ModelOption({
    required this.id,
    required this.name,
    required this.subtitle,
    this.costHint,
    this.locked = false,
    this.advanced = false,
    this.tag,
    this.tagTone = OPillTone.accent,
    this.icon = Icons.auto_awesome_rounded,
  });

  final String id;
  final String name;
  final String subtitle;

  /// What the model costs on the plan the caller is on, and nothing more:
  /// `Included` when the subscription covers it, `Your key` when it runs on the
  /// caller's own provider key. Null when the row is gated — the plan pill
  /// already names the gate, and there is no per-model price to quote.
  final String? costHint;

  /// A per-row gate. The plan gate ([V2ModelPickerData.autoOnly]) is applied
  /// on top, so a Free/Go caller cannot leak a row by leaving this false.
  final bool locked;

  /// Section the row belongs to. Separate from [locked] so a Free plan does
  /// not relabel every gated row as "Advanced reasoning".
  final bool advanced;

  /// Optional recommendation shown beside the name on an unlocked row. A
  /// locked row shows the plan gate instead.
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
    this.searchHint = 'Search models',
    this.manageLabel = 'Manage models',
    this.freePlanNote,
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

  final String searchHint;
  final String manageLabel;

  /// Optional override for the header subtitle while the plan is Auto-only.
  /// When omitted the sheet names the actual plan, so a Go caller never reads
  /// "Free plan". On a paid plan the rows speak for themselves and no
  /// subtitle is drawn.
  final String? freePlanNote;
  final String standardLabel;
  final String advancedLabel;

  /// Whether the current plan may pick a model manually. Free and Go are
  /// Auto-only; Plus and Pro allow every model. When false, manual rows stay
  /// visible but are greyed out and cannot be selected.
  final bool manualModelsAllowed;

  /// Spoken explanation attached to every locked row. Screen readers hear the
  /// label first ("locked, Plus plan") and then this hint.
  final String upgradeHint;

  /// Plan a manual model requires, used by the locked-row tag and its spoken
  /// label. Free and Go both need Plus.
  final String lockedPlanLabel;
  final bool loading;
  final String? errorMessage;

  /// True when Auto is the model that will actually run: it was picked
  /// explicitly, or the remembered manual pick is no longer selectable (a
  /// downgrade, or a row the caller gated).
  bool get autoSelected {
    if (selectedId == 'auto') return true;
    for (final model in models) {
      if (model.id == selectedId) return autoOnly || model.locked;
    }
    return true;
  }

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

  /// The one-line gate explanation, named for the actual plan so a Go caller
  /// never reads "Free plan". [freePlanNote] wins when the caller supplies it.
  String get planNote {
    final override = freePlanNote;
    if (override != null && override.isNotEmpty) return override;
    final label = planLabel.toLowerCase().endsWith('plan')
        ? planLabel
        : '$planLabel plan';
    return '$label uses Auto only.';
  }
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

  String get _normalizedQuery => _query.trim().toLowerCase();

  bool _matches(V2ModelOption model) {
    final q = _normalizedQuery;
    if (q.isEmpty) return true;
    final cost = model.costHint;
    return model.name.toLowerCase().contains(q) ||
        model.subtitle.toLowerCase().contains(q) ||
        (cost != null && cost.toLowerCase().contains(q));
  }

  bool get _autoMatches {
    final q = _normalizedQuery;
    if (q.isEmpty) return true;
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

    // The 560 dp cap belongs to the surface, not just the column inside it:
    // rendered outside showV2ChatSheet (gallery, tests) the sheet must still
    // look like a dialog rather than a full-width page.
    return Center(
      heightFactor: 1,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: Material(
          color: c.surface,
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
                  // One line of context only while the plan gates the list.
                  subtitle: data.autoOnly ? data.planNote : null,
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
          message: 'Try a name or provider.',
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

    Widget row(V2ModelOption model) {
      final locked = data.autoOnly || model.locked;
      return _ModelRow(
        model: model,
        selected: data.selectedId == model.id,
        // The plan gate wins over the row flag: on an Auto-only plan every
        // manual model is locked even if the caller left it unlocked.
        locked: locked,
        planLabel: data.lockedPlanLabel,
        hint: locked ? data.upgradeHint : null,
        onTap: locked ? null : () => widget.onSelect(model.id),
      );
    }

    // Grouped by tier so the labels always read Standard then Advanced, even
    // when the caller interleaves the two. Rows sit on the sheet surface with
    // one hairline between them, indented to the name.
    final standard = models.where((model) => !model.advanced).toList();
    final advanced = models.where((model) => model.advanced).toList();
    void addGroup(String label, List<V2ModelOption> group) {
      if (group.isEmpty) return;
      rows.add(
        OSectionHeader(
          label: label,
          padding: const EdgeInsets.fromLTRB(
            OSpace.s,
            OSpace.m,
            OSpace.s,
            OSpace.xs,
          ),
        ),
      );
      for (var i = 0; i < group.length; i++) {
        // Indented to the model name: row padding, icon tile, icon gap.
        if (i > 0) {
          rows.add(
            const ODivider(indent: OSpace.s + OSpace.iconTile + OSpace.m),
          );
        }
        rows.add(row(group[i]));
      }
    }

    addGroup(data.standardLabel, standard);
    addGroup(data.advancedLabel, advanced);

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
    // A row like the models below it: the recommendation shows as the accent
    // tile and the check, not as a filled card on the sheet's surface.
    return OPressable(
      onTap: onTap,
      selected: selected,
      // One spoken node: name, state and availability. Excluding the child
      // stops the visible name and subtitle from being read twice.
      semanticLabel: '${data.autoName}, ${data.autoSubtitle}, available',
      child: ExcludeSemantics(
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: OSpace.listRow),
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: OSpace.s,
              vertical: OSpace.s,
            ),
            child: Row(
              children: [
                Container(
                  width: OSpace.iconTile,
                  height: OSpace.iconTile,
                  decoration: BoxDecoration(
                    color: c.accentSoft,
                    borderRadius: BorderRadius.circular(ORadius.m),
                  ),
                  child: Icon(
                    Icons.auto_awesome_rounded,
                    size: 19,
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
                      const SizedBox(height: OSpace.xxs),
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
    required this.hint,
    required this.onTap,
  });

  final V2ModelOption model;
  final bool selected;
  final bool locked;
  final String planLabel;
  final String? hint;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    // One meta line, then the cost. A locked row carries the plan gate as its
    // only tag; the caller's recommendation is shown only when it is reachable.
    final tag = locked ? planLabel : model.tag;
    final tagTone = locked ? OPillTone.accent : model.tagTone;
    final row = ConstrainedBox(
      constraints: const BoxConstraints(minHeight: OSpace.listRow),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: OSpace.s,
          vertical: OSpace.s,
        ),
        child: Row(
          children: [
            Container(
              width: OSpace.iconTile,
              height: OSpace.iconTile,
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
                      if (tag != null) OPill(label: tag, tone: tagTone),
                    ],
                  ),
                  const SizedBox(height: OSpace.xxs),
                  // Wrap, not Row: at 200 % text the meta line and the cost
                  // each get a full line instead of overflowing the row.
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
                      // A gated row states the gate (the pill above), never a
                      // cost: the model is not usable on this plan, so any
                      // price line would be describing something unreachable.
                      if (!locked && model.costHint != null)
                        Text(
                          model.costHint!,
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
            if (!locked) _SelectionMark(selected: selected),
          ],
        ),
      ),
    );

    if (onTap == null) {
      return Semantics(
        label: '${model.name}, ${model.subtitle}, locked, $planLabel',
        hint: hint,
        enabled: false,
        // One node: the visible name, meta line, gate pill and lock glyph are
        // already covered by the label.
        excludeSemantics: true,
        child: row,
      );
    }
    return OPressable(
      onTap: onTap,
      selected: selected,
      semanticLabel: '${model.name}, ${model.subtitle}, available',
      child: ExcludeSemantics(child: row),
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
