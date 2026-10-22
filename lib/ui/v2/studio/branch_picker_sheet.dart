import 'package:flutter/material.dart';

import '../../design/o_components.dart';
import '../../design/o_screen.dart';
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
    this.stashNote = '',
    this.errorMessage,
  });

  final V2BranchPickerStatus status;
  final V2Branch? current;
  final List<V2Branch> branches;

  /// Kept for wiring compatibility. The sheet no longer prints an explanatory
  /// paragraph: switching branches is not destructive.
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
    this.onClose,
    this.showHandle = true,
  });

  final V2BranchPickerData data;
  final ValueChanged<V2Branch>? onSelectBranch;
  final VoidCallback? onCreateBranch;
  final ValueChanged<String>? onSearch;
  final VoidCallback? onRetry;
  final VoidCallback? onClose;
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
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
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
                      borderRadius: BorderRadius.circular(ORadius.xs),
                    ),
                  ),
                ],
                OSheetHeader(
                  title: 'Switch branch',
                  onClose:
                      widget.onClose ?? () => Navigator.of(context).maybePop(),
                  closeKey: const Key('branch-picker-close'),
                  closeLabel: 'Close branch picker',
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: OSpace.l),
                  child: OSearchField(
                    controller: _search,
                    hint: 'Search branches',
                    onChanged: _onSearch,
                  ),
                ),
                const SizedBox(height: OSpace.s),
                Expanded(
                  child: OFadeIn(child: _buildBody(context, current, visible)),
                ),
              ],
            ),
          ),
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
          message: data.errorMessage ?? 'Branches did not load.',
          onRetry: widget.onRetry,
        );
      case V2BranchPickerStatus.empty:
        return _buildEmpty();
      case V2BranchPickerStatus.content:
        if (current == null && data.branches.isEmpty) {
          return _buildEmpty();
        }
        if (visible.isEmpty && _query.isNotEmpty) {
          return OEmptyState(
            compact: true,
            icon: Icons.search_off_rounded,
            title: 'No branches found',
            message: '',
            action: OButton(
              label: 'Clear search',
              variant: OButtonVariant.secondary,
              onPressed: _clearSearch,
            ),
          );
        }
        return ListView(
          padding: const EdgeInsets.fromLTRB(OSpace.l, 0, OSpace.l, OSpace.xl),
          children: [
            if (current != null && _matches(current)) ...[
              OSectionTitle(title: 'Current'),
              _CurrentBranchCard(branch: current),
              const SizedBox(height: OSpace.l),
            ],
            for (final branch in visible)
              Padding(
                padding: const EdgeInsets.only(bottom: OSpace.s),
                child: _BranchRow(
                  branch: branch,
                  onTap: widget.onSelectBranch == null
                      ? null
                      : () => widget.onSelectBranch!(branch),
                ),
              ),
            const SizedBox(height: OSpace.xs),
            if (widget.onCreateBranch != null)
              OButton(
                label: 'Create new branch',
                icon: Icons.add_rounded,
                variant: OButtonVariant.secondary,
                expand: true,
                onPressed: widget.onCreateBranch,
              ),
          ],
        );
    }
  }

  Widget _buildEmpty() {
    return OEmptyState(
      compact: true,
      icon: Icons.account_tree_outlined,
      title: 'No branches yet',
      message: '',
      action: widget.onCreateBranch == null
          ? null
          : OButton(
              label: 'Create new branch',
              icon: Icons.add_rounded,
              onPressed: widget.onCreateBranch,
            ),
    );
  }
}

class _CurrentBranchCard extends StatelessWidget {
  const _CurrentBranchCard({required this.branch});

  final V2Branch branch;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    final meta = branch.lastCommitLabel.isNotEmpty
        ? branch.lastCommitLabel
        : (branch.isDefault ? 'Default' : '');
    return Container(
      padding: const EdgeInsets.all(OSpace.m),
      decoration: BoxDecoration(
        color: c.surfaceAlt,
        borderRadius: BorderRadius.circular(ORadius.l),
        border: Border.all(color: c.hairline),
      ),
      child: Row(
        children: [
          Icon(Icons.fork_right_rounded, size: 19, color: c.accent),
          const SizedBox(width: OSpace.m),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  branch.name,
                  style: OType.bodyStrong.copyWith(color: c.text),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                if (meta.isNotEmpty)
                  Text(
                    meta,
                    style: OType.caption.copyWith(color: c.textMuted),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
              ],
            ),
          ),
          const SizedBox(width: OSpace.s),
          Icon(Icons.check_circle_rounded, size: 18, color: c.accent),
        ],
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
      child: Material(
        color: c.surface,
        borderRadius: BorderRadius.circular(ORadius.l),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(ORadius.l),
          child: Container(
            constraints: const BoxConstraints(minHeight: OSpace.listRow),
            padding: const EdgeInsets.symmetric(
              horizontal: OSpace.m,
              vertical: OSpace.s,
            ),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(ORadius.l),
              border: Border.all(color: c.hairline),
            ),
            child: Row(
              children: [
                Icon(Icons.fork_right_rounded, size: 19, color: c.textMuted),
                const SizedBox(width: OSpace.m),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
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
                if (onTap != null)
                  Icon(
                    Icons.arrow_forward_rounded,
                    size: 18,
                    color: c.textFaint,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
