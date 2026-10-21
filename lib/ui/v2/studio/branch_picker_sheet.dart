import 'package:flutter/material.dart';

import '../../design/o_components.dart';
import '../../design/o_motion.dart';
import '../../design/o_tokens.dart';

// TODO(l10n): move this sheet's English copy to the ARB files in the next wave.

/// What the branch picker is doing right now.
enum V2BranchPickerStatus { loading, content, empty, error }

/// One branch the user can switch to.
@immutable
class V2Branch {
  const V2Branch({
    required this.name,
    this.lastCommitLabel = '',
    this.isDefault = false,
    this.isCurrent = false,
  });

  final String name;
  final String lastCommitLabel;
  final bool isDefault;
  final bool isCurrent;
}

/// Everything the branch picker needs to render.
@immutable
class V2BranchPickerData {
  const V2BranchPickerData({
    this.status = V2BranchPickerStatus.content,
    this.current,
    this.branches = const <V2Branch>[],
    this.stashNote =
        'Switching will copy your uncommitted changes to a stash. Nothing will be lost.',
    this.errorMessage,
  });

  final V2BranchPickerStatus status;
  final V2Branch? current;
  final List<V2Branch> branches;
  final String stashNote;
  final String? errorMessage;
}

/// The "Switch branch" sheet. Host it with [showOSheet] and pass
/// `showHandle: false` there because the host already draws a grabber.
class V2BranchPickerSheet extends StatefulWidget {
  const V2BranchPickerSheet({
    super.key,
    required this.data,
    this.onSelectBranch,
    this.onCreateBranch,
    this.onSearch,
    this.onRetry,
    this.showHandle = true,
  });

  final V2BranchPickerData data;
  final ValueChanged<V2Branch>? onSelectBranch;
  final VoidCallback? onCreateBranch;
  final ValueChanged<String>? onSearch;
  final VoidCallback? onRetry;
  final bool showHandle;

  @override
  State<V2BranchPickerSheet> createState() => _V2BranchPickerSheetState();
}

class _V2BranchPickerSheetState extends State<V2BranchPickerSheet> {
  final TextEditingController _search = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  void _onSearch(String value) {
    setState(() => _query = value.trim().toLowerCase());
    widget.onSearch?.call(value);
  }

  void _clearSearch() {
    _search.clear();
    _onSearch('');
  }

  bool _matches(V2Branch branch) =>
      _query.isEmpty || branch.name.toLowerCase().contains(_query);

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    final data = widget.data;
    final current = data.current;
    final visible = data.branches
        .where((branch) => branch.name != current?.name && _matches(branch))
        .toList(growable: false);
    return Material(
      color: c.surface,
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.max,
          children: [
            if (widget.showHandle) ...[
              const SizedBox(height: OSpace.s),
              Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: c.hairlineStrong,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ],
            Padding(
              padding: const EdgeInsets.fromLTRB(
                OSpace.xl,
                OSpace.l,
                OSpace.xl,
                OSpace.m,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Semantics(
                          container: true,
                          header: true,
                          child: Text(
                            'Switch branch',
                            style: OType.h2.copyWith(color: c.text),
                          ),
                        ),
                      ),
                      Icon(Icons.alt_route_rounded, size: 22, color: c.accent),
                    ],
                  ),
                  const SizedBox(height: OSpace.xs),
                  Text(
                    'Your current work stays safe.',
                    style: OType.bodySm.copyWith(color: c.textMuted),
                  ),
                  const SizedBox(height: OSpace.l),
                  OSearchField(
                    controller: _search,
                    hint: 'Search branches',
                    onChanged: _onSearch,
                  ),
                ],
              ),
            ),
            Expanded(
              child: OFadeSlide(child: _buildBody(context, current, visible)),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBody(
    BuildContext context,
    V2Branch? current,
    List<V2Branch> visible,
  ) {
    final data = widget.data;
    switch (data.status) {
      case V2BranchPickerStatus.loading:
        return const OSkeletonList(rows: 4);
      case V2BranchPickerStatus.error:
        return OErrorState(
          message:
              data.errorMessage ??
              'We could not load your branches. Check your connection and try again.',
          onRetry: widget.onRetry,
        );
      case V2BranchPickerStatus.empty:
        return OEmptyState(
          compact: true,
          icon: Icons.account_tree_outlined,
          title: 'No branches yet',
          message: 'Create a branch to start making changes.',
          action: OButton(
            label: 'Create new branch',
            icon: Icons.add_rounded,
            onPressed: widget.onCreateBranch,
          ),
        );
      case V2BranchPickerStatus.content:
        if (current == null && data.branches.isEmpty) {
          return OEmptyState(
            compact: true,
            icon: Icons.account_tree_outlined,
            title: 'No branches yet',
            message: 'Create a branch to start making changes.',
            action: OButton(
              label: 'Create new branch',
              icon: Icons.add_rounded,
              onPressed: widget.onCreateBranch,
            ),
          );
        }
        if (visible.isEmpty && _query.isNotEmpty) {
          return OEmptyState(
            compact: true,
            icon: Icons.search_off_rounded,
            title: 'No branches found',
            message: 'Try another search.',
            action: OButton(
              label: 'Clear search',
              variant: OButtonVariant.secondary,
              onPressed: _clearSearch,
            ),
          );
        }
        return ListView(
          padding: const EdgeInsets.fromLTRB(
            OSpace.xl,
            0,
            OSpace.xl,
            OSpace.xl,
          ),
          children: [
            if (current != null && _matches(current)) ...[
              const _SectionLabel(label: 'Current branch'),
              const SizedBox(height: OSpace.xs),
              _CurrentBranchCard(branch: current),
              const SizedBox(height: OSpace.l),
            ],
            _SectionLabel(
              label: 'Recent branches (${visible.length})',
              trailing: 'Local',
            ),
            const SizedBox(height: OSpace.xs),
            OStagger(
              children: [
                for (final branch in visible)
                  Padding(
                    padding: const EdgeInsets.only(bottom: OSpace.s),
                    child: _BranchRow(
                      branch: branch,
                      onTap: () => widget.onSelectBranch?.call(branch),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: OSpace.xs),
            OButton(
              label: 'Create new branch',
              icon: Icons.add_rounded,
              variant: OButtonVariant.secondary,
              expand: true,
              onPressed: widget.onCreateBranch,
            ),
            const SizedBox(height: OSpace.m),
            _StashNote(note: data.stashNote),
          ],
        );
    }
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel({required this.label, this.trailing});

  final String label;
  final String? trailing;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    return Row(
      children: [
        Expanded(
          child: Text(
            label.toUpperCase(),
            style: OType.overline.copyWith(color: c.textMuted),
          ),
        ),
        if (trailing != null)
          Text(trailing!, style: OType.caption.copyWith(color: c.textFaint)),
      ],
    );
  }
}

class _CurrentBranchCard extends StatelessWidget {
  const _CurrentBranchCard({required this.branch});

  final V2Branch branch;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    return Container(
      padding: const EdgeInsets.all(OSpace.m),
      decoration: BoxDecoration(
        color: c.surfaceAlt,
        borderRadius: BorderRadius.circular(ORadius.l),
        border: Border.all(color: c.hairline),
      ),
      child: Row(
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: c.accentSoft,
              shape: BoxShape.circle,
            ),
            child: Icon(Icons.fork_right_rounded, size: 19, color: c.accent),
          ),
          const SizedBox(width: OSpace.m),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: double.infinity,
                  child: Wrap(
                    alignment: WrapAlignment.spaceBetween,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    spacing: OSpace.s,
                    runSpacing: OSpace.xs,
                    children: [
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Flexible(
                            child: Text(
                              branch.name,
                              style: OType.bodyStrong.copyWith(color: c.text),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          const SizedBox(width: OSpace.xs),
                          Icon(
                            Icons.check_circle_rounded,
                            size: 16,
                            color: c.accent,
                          ),
                        ],
                      ),
                      const _ActiveBadge(),
                    ],
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  branch.isDefault
                      ? 'Default · Synced with remote'
                      : 'Synced with remote',
                  style: OType.caption.copyWith(color: c.textMuted),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Content-sized "Active" pill. [OPill] has a fixed height, which would clip its
/// label when the user raises the text size.
class _ActiveBadge extends StatelessWidget {
  const _ActiveBadge();

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    return Container(
      constraints: const BoxConstraints(minHeight: 24),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: c.accentSoft,
        borderRadius: BorderRadius.circular(ORadius.pill),
      ),
      child: Text(
        'Active',
        style: OType.caption.copyWith(
          color: c.accent,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class _BranchRow extends StatelessWidget {
  const _BranchRow({required this.branch, this.onTap});

  final V2Branch branch;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    final label = branch.lastCommitLabel.isEmpty
        ? branch.name
        : '${branch.name}, ${branch.lastCommitLabel}';
    return Semantics(
      container: true,
      excludeSemantics: true,
      button: onTap != null,
      enabled: onTap != null,
      label: label,
      onTap: onTap,
      child: OCard(
        onTap: onTap,
        padding: const EdgeInsets.symmetric(
          horizontal: OSpace.m,
          vertical: OSpace.s,
        ),
        child: Row(
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: c.surfaceAlt,
                shape: BoxShape.circle,
              ),
              child: Icon(
                Icons.fork_right_rounded,
                size: 19,
                color: c.textMuted,
              ),
            ),
            const SizedBox(width: OSpace.m),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    branch.name,
                    style: OType.body.copyWith(
                      color: c.text,
                      fontWeight: FontWeight.w500,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (branch.lastCommitLabel.isNotEmpty)
                    Text(
                      branch.lastCommitLabel,
                      style: OType.caption.copyWith(color: c.textMuted),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                ],
              ),
            ),
            const SizedBox(width: OSpace.s),
            Icon(Icons.arrow_forward_rounded, size: 20, color: c.textFaint),
          ],
        ),
      ),
    );
  }
}

class _StashNote extends StatelessWidget {
  const _StashNote({required this.note});

  final String note;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    return Container(
      padding: const EdgeInsets.all(OSpace.m),
      decoration: BoxDecoration(
        color: c.warn.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(ORadius.m),
        border: Border.all(color: c.warn.withValues(alpha: 0.25)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.shield_outlined, size: 19, color: c.warn),
          const SizedBox(width: OSpace.s),
          Expanded(
            child: Text(
              note,
              style: OType.caption.copyWith(color: c.textMuted),
            ),
          ),
        ],
      ),
    );
  }
}
