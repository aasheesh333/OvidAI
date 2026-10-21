import 'dart:async';

import 'package:flutter/material.dart';

import '../../design/o_components.dart';
import '../../design/o_motion.dart';
import '../../design/o_tokens.dart';

// TODO(l10n): move user-facing copy to the ARB files in the next wave.

/// What the repo picker is doing right now.
enum V2RepoPickerStatus { loading, content, empty, error }

/// One branch the user can clone when binding a repository.
@immutable
class V2RepoBranch {
  const V2RepoBranch({
    required this.name,
    this.lastCommitLabel = '',
    this.isDefault = false,
  });

  final String name;
  final String lastCommitLabel;
  final bool isDefault;
}

/// One repository the user can open in Studio.
@immutable
class V2Repo {
  const V2Repo({
    required this.id,
    required this.name,
    this.owner = '',
    this.description,
    this.language,
    this.updatedLabel,
    this.isPrivate = false,
    this.defaultBranch,
    this.branches = const <V2RepoBranch>[],
  });

  final String id;
  final String name;
  final String owner;
  final String? description;
  final String? language;
  final String? updatedLabel;
  final bool isPrivate;

  /// Branch the picker preselects. When null, the first branch flagged
  /// [V2RepoBranch.isDefault] is used instead.
  final String? defaultBranch;

  /// Branches available in this repository. Empty means the wiring layer could
  /// not list them yet, so the user cannot continue past the branch step.
  final List<V2RepoBranch> branches;

  String get fullName => owner.isEmpty ? name : '$owner/$name';

  /// The branch to preselect in the "Choose branch" step, or null when the
  /// user must pick one explicitly.
  String? get preferredBranch {
    final explicit = defaultBranch?.trim();
    if (explicit != null && explicit.isNotEmpty) return explicit;
    for (final branch in branches) {
      if (branch.isDefault) return branch.name;
    }
    return null;
  }
}

/// Everything the repo picker needs to render. Supplied by the wiring layer.
@immutable
class V2RepoPickerData {
  const V2RepoPickerData({
    this.status = V2RepoPickerStatus.content,
    this.repos = const <V2Repo>[],
    this.githubConnected = true,
    this.accountLabel,
    this.errorMessage,
  });

  final V2RepoPickerStatus status;
  final List<V2Repo> repos;
  final bool githubConnected;
  final String? accountLabel;
  final String? errorMessage;
}

/// Pick a GitHub repository to copy into the private cloud workspace.
///
/// The picker is a two-step gate: the user first chooses a repository, then a
/// branch. The primary action stays disabled until both are selected, so a
/// Studio chat can never start without a folder binding.
class V2RepoPickerPage extends StatefulWidget {
  const V2RepoPickerPage({
    super.key,
    required this.data,
    this.onSelectRepo,
    this.onConfirm,
    this.onLoadBranches,
    this.onConnectGithub,
    this.onOpenToken,
    this.onOpenAdvanced,
    this.onSearch,
    this.onRetry,
  });

  final V2RepoPickerData data;

  /// Fires when a repository row is tapped. Kept for callers that navigate as
  /// soon as a repo is known; new wiring should use [onConfirm] instead.
  final ValueChanged<V2Repo>? onSelectRepo;

  /// Fires when the user confirms a repository **and** a branch. This is the
  /// only callback that should bind the folder for Studio mode. When null the
  /// primary action stays disabled: a page that cannot bind must not pretend
  /// it started a workspace.
  final void Function(V2Repo repo, String branch)? onConfirm;

  /// Loads the real branch list for a repository when the data snapshot did
  /// not carry one. Returning an empty list is treated as "no branches".
  final Future<List<V2RepoBranch>> Function(V2Repo repo)? onLoadBranches;
  final VoidCallback? onConnectGithub;
  final VoidCallback? onOpenToken;
  final VoidCallback? onOpenAdvanced;
  final ValueChanged<String>? onSearch;
  final VoidCallback? onRetry;

  @override
  State<V2RepoPickerPage> createState() => _V2RepoPickerPageState();
}

class _V2RepoPickerPageState extends State<V2RepoPickerPage> {
  final TextEditingController _search = TextEditingController();
  String _query = '';
  V2Repo? _selectedRepo;
  String? _selectedBranch;
  List<V2RepoBranch> _loadedBranches = const <V2RepoBranch>[];
  bool _loadingBranches = false;
  String? _branchError;

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

  void _selectRepo(V2Repo repo) {
    final preferred = repo.preferredBranch;
    final hasPreferred =
        preferred != null && repo.branches.any((b) => b.name == preferred);
    setState(() {
      _selectedRepo = repo;
      _selectedBranch = hasPreferred ? preferred : null;
      _loadedBranches = const <V2RepoBranch>[];
      _loadingBranches = false;
      _branchError = null;
    });
    widget.onSelectRepo?.call(repo);
    if (repo.branches.isEmpty && widget.onLoadBranches != null) {
      unawaited(_loadBranches(repo));
    }
  }

  /// Fetches the real branch list for [repo] when the snapshot had none.
  Future<void> _loadBranches(V2Repo repo) async {
    final loader = widget.onLoadBranches;
    if (loader == null) return;
    setState(() {
      _loadingBranches = true;
      _branchError = null;
      _loadedBranches = const <V2RepoBranch>[];
    });
    try {
      final branches = await loader(repo);
      if (!mounted || _selectedRepo?.id != repo.id) return;
      setState(() {
        _loadingBranches = false;
        _loadedBranches = branches;
        _selectedBranch ??= _preferredBranchOf(repo, branches);
      });
    } catch (_) {
      if (!mounted || _selectedRepo?.id != repo.id) return;
      setState(() {
        _loadingBranches = false;
        _branchError =
            'We could not load branches for ${repo.fullName}. Check your '
            'connection and try again.';
      });
    }
  }

  static String? _preferredBranchOf(
    V2Repo repo,
    List<V2RepoBranch> branches,
  ) {
    final explicit = repo.defaultBranch?.trim();
    if (explicit != null &&
        explicit.isNotEmpty &&
        branches.any((branch) => branch.name == explicit)) {
      return explicit;
    }
    for (final branch in branches) {
      if (branch.isDefault) return branch.name;
    }
    return null;
  }

  List<V2RepoBranch> _branchesFor(V2Repo repo) =>
      repo.branches.isNotEmpty ? repo.branches : _loadedBranches;

  void _changeRepo() {
    setState(() {
      _selectedRepo = null;
      _selectedBranch = null;
      _loadedBranches = const <V2RepoBranch>[];
      _loadingBranches = false;
      _branchError = null;
    });
  }

  void _selectBranch(String branch) {
    setState(() => _selectedBranch = branch);
  }

  bool get _canConfirm =>
      _selectedRepo != null &&
      _selectedBranch != null &&
      widget.onConfirm != null;

  void _confirm() {
    final repo = _selectedRepo;
    final branch = _selectedBranch;
    final confirm = widget.onConfirm;
    if (repo == null || branch == null || confirm == null) return;
    confirm(repo, branch);
  }

  String get _primaryLabel {
    if (_selectedRepo == null) return 'Choose a repository';
    if (_selectedBranch == null) return 'Choose a branch';
    return 'Start coding';
  }

  List<V2Repo> get _visibleRepos {
    if (_query.isEmpty) return widget.data.repos;
    return widget.data.repos
        .where((repo) {
          final haystack =
              '${repo.fullName} ${repo.description ?? ''} ${repo.language ?? ''}'
                  .toLowerCase();
          return haystack.contains(_query);
        })
        .toList(growable: false);
  }

  @override
  Widget build(BuildContext context) {
    final data = widget.data;
    final showPrimary =
        data.status == V2RepoPickerStatus.content ||
        data.status == V2RepoPickerStatus.empty;
    return OScaffold(
      appBar: OAppBar(
        title: 'Studio',
        subtitle: _selectedRepo == null ? 'Pick a repository' : 'Choose a branch',
        actions: [
          if (!data.githubConnected)
            OIconButton(
              icon: Icons.link_rounded,
              semanticLabel: 'Connect GitHub',
              tooltip: 'Connect GitHub',
              onPressed: widget.onConnectGithub,
            ),
        ],
      ),
      bottomNavigationBar: showPrimary ? _buildPrimaryBar(context) : null,
      body: switch (data.status) {
        V2RepoPickerStatus.loading => const OSkeletonList(rows: 5),
        V2RepoPickerStatus.error => OErrorState(
          message:
              data.errorMessage ??
              'We could not load your repositories. Check your connection and try again.',
          onRetry: widget.onRetry,
        ),
        V2RepoPickerStatus.content ||
        V2RepoPickerStatus.empty => _buildContent(context),
      },
    );
  }

  Widget _buildContent(BuildContext context) {
    final repo = _selectedRepo;
    if (repo != null) return _buildBranchStep(context, repo);
    final data = widget.data;
    final repos = _visibleRepos;
    final showHero = !data.githubConnected;
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(
        OSpace.screen,
        OSpace.m,
        OSpace.screen,
        OSpace.xxl,
      ),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: OFadeSlide(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (showHero) ...[
                  _ConnectHero(onConnectGithub: widget.onConnectGithub),
                  const SizedBox(height: OSpace.l),
                  const _NoReposHeader(),
                  const SizedBox(height: OSpace.s),
                ] else ...[
                  _ConnectedHeader(
                    accountLabel: data.accountLabel,
                    repoCount: data.repos.length,
                  ),
                  const SizedBox(height: OSpace.l),
                  OSearchField(
                    controller: _search,
                    hint: 'Search your repositories',
                    onChanged: _onSearch,
                  ),
                  const SizedBox(height: OSpace.m),
                  if (data.repos.isEmpty)
                    OEmptyState(
                      compact: true,
                      icon: Icons.folder_open_rounded,
                      title: 'No repositories yet',
                      message:
                          'Create a repository on GitHub, then refresh this list.',
                      action: OButton(
                        label: 'Refresh',
                        icon: Icons.refresh_rounded,
                        onPressed: widget.onRetry,
                      ),
                    )
                  else if (repos.isEmpty)
                    OEmptyState(
                      compact: true,
                      icon: Icons.search_off_rounded,
                      title: 'No matching repositories',
                      message: 'Try a different name.',
                      action: OButton(
                        label: 'Clear search',
                        variant: OButtonVariant.secondary,
                        onPressed: _clearSearch,
                      ),
                    )
                  else
                    _buildRepoList(repos),
                  const SizedBox(height: OSpace.l),
                ],
                _AdvancedRows(
                  onOpenToken: widget.onOpenToken,
                  onOpenAdvanced: widget.onOpenAdvanced,
                ),
                const SizedBox(height: OSpace.l),
                const _SecurityNote(),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Step two: the branch list for the selected repository. The primary action
  /// in the dock stays disabled until a branch is selected.
  Widget _buildBranchStep(BuildContext context, V2Repo repo) {
    final c = OColors.of(context);
    final branches = _branchesFor(repo);
    final loading = _loadingBranches;
    final error = _branchError;
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(
        OSpace.screen,
        OSpace.m,
        OSpace.screen,
        OSpace.xxl,
      ),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: OFadeSlide(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Align(
                  alignment: Alignment.centerLeft,
                  child: OButton(
                    key: const Key('repo-picker-change-repo'),
                    label: 'Change repository',
                    icon: Icons.arrow_back_rounded,
                    variant: OButtonVariant.ghost,
                    size: OButtonSize.compact,
                    onPressed: _changeRepo,
                  ),
                ),
                const SizedBox(height: OSpace.s),
                _SelectedRepoCard(repo: repo),
                const SizedBox(height: OSpace.l),
                Text(
                  'Choose branch',
                  style: OType.h2.copyWith(color: c.text),
                ),
                const SizedBox(height: OSpace.xs),
                Text(
                  'Pick the branch Ovid should work on. You can switch later.',
                  style: OType.bodySm.copyWith(color: c.textMuted),
                ),
                const SizedBox(height: OSpace.m),
                if (loading)
                  OCard(
                    key: const Key('repo-picker-branches-loading'),
                    child: Row(
                      children: [
                        const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                        const SizedBox(width: OSpace.m),
                        Expanded(
                          child: Text(
                            'Loading branches for ${repo.fullName}…',
                            style: OType.bodySm.copyWith(color: c.textMuted),
                          ),
                        ),
                      ],
                    ),
                  )
                else if (error != null)
                  OEmptyState(
                    compact: true,
                    icon: Icons.cloud_off_rounded,
                    title: 'Branches did not load',
                    message: error,
                    action: OButton(
                      label: 'Try again',
                      icon: Icons.refresh_rounded,
                      variant: OButtonVariant.secondary,
                      onPressed: () => _loadBranches(repo),
                    ),
                  )
                else if (branches.isEmpty)
                  OEmptyState(
                    compact: true,
                    icon: Icons.account_tree_outlined,
                    title: 'No branches found',
                    message:
                        'We could not load branches for ${repo.fullName}. Go back and choose another repository.',
                    action: widget.onLoadBranches == null
                        ? OButton(
                            label: 'Change repository',
                            variant: OButtonVariant.secondary,
                            onPressed: _changeRepo,
                          )
                        : OButton(
                            label: 'Reload branches',
                            icon: Icons.refresh_rounded,
                            variant: OButtonVariant.secondary,
                            onPressed: () => _loadBranches(repo),
                          ),
                  )
                else
                  OStagger(
                    children: [
                      for (final branch in branches)
                        Padding(
                          padding: const EdgeInsets.only(bottom: OSpace.s),
                          child: _BranchChoice(
                            branch: branch,
                            selected: branch.name == _selectedBranch,
                            onTap: () => _selectBranch(branch.name),
                          ),
                        ),
                    ],
                  ),
                const SizedBox(height: OSpace.l),
                const _SecurityNote(),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildPrimaryBar(BuildContext context) {
    final c = OColors.of(context);
    final ready = _canConfirm;
    return SafeArea(
      top: false,
      child: Container(
        decoration: BoxDecoration(
          color: c.surface,
          border: Border(top: BorderSide(color: c.hairline)),
        ),
        padding: const EdgeInsets.fromLTRB(
          OSpace.l,
          OSpace.m,
          OSpace.l,
          OSpace.m,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (!ready)
              Padding(
                padding: const EdgeInsets.only(bottom: OSpace.s),
                child: Text(
                  widget.onConfirm == null
                      ? 'Studio setup is not connected yet, so this cannot '
                            'start a workspace.'
                      : _selectedRepo == null
                      ? 'Choose a repository to continue.'
                      : 'Choose a branch to continue.',
                  style: OType.caption.copyWith(color: c.textMuted),
                ),
              ),
            OButton(
              key: const Key('repo-picker-primary'),
              label: _primaryLabel,
              icon: ready ? Icons.play_arrow_rounded : null,
              expand: true,
              onPressed: ready ? _confirm : null,
            ),
          ],
        ),
      ),
    );
  }

  /// Repo rows, with entrance motion capped to the first eight as the contract
  /// asks. Long lists stay snappy because the stagger stops there.
  Widget _buildRepoList(List<V2Repo> repos) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        OStagger(
          children: [
            for (final repo in repos.take(8)) _repoTile(repo),
          ],
        ),
        for (final repo in repos.skip(8)) _repoTile(repo),
      ],
    );
  }

  Widget _repoTile(V2Repo repo) {
    return Padding(
      padding: const EdgeInsets.only(bottom: OSpace.s),
      child: _RepoRow(repo: repo, onTap: () => _selectRepo(repo)),
    );
  }
}

class _SelectedRepoCard extends StatelessWidget {
  const _SelectedRepoCard({required this.repo});

  final V2Repo repo;

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
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: c.accentSoft,
              borderRadius: BorderRadius.circular(ORadius.m),
            ),
            child: Icon(Icons.folder_open_rounded, size: 20, color: c.accent),
          ),
          const SizedBox(width: OSpace.m),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  repo.fullName,
                  style: OType.bodyStrong.copyWith(color: c.text),
                ),
                const SizedBox(height: 2),
                Text(
                  'Selected repository',
                  style: OType.caption.copyWith(color: c.textMuted),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _BranchChoice extends StatelessWidget {
  const _BranchChoice({
    required this.branch,
    required this.selected,
    this.onTap,
  });

  final V2RepoBranch branch;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    final label = branch.isDefault
        ? 'Branch ${branch.name}, default'
        : 'Branch ${branch.name}';
    return OPressable(
      key: Key('repo-picker-branch-${branch.name}'),
      onTap: onTap,
      selected: selected,
      semanticLabel: selected ? '$label, selected' : label,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: OSpace.listRow),
        child: Container(
          padding: const EdgeInsets.symmetric(
            horizontal: OSpace.m,
            vertical: OSpace.s,
          ),
          decoration: BoxDecoration(
            color: selected ? c.accentSoft : c.surface,
            borderRadius: BorderRadius.circular(ORadius.l),
            border: Border.all(
              color: selected
                  ? c.accentFill.withValues(alpha: 0.5)
                  : c.hairline,
            ),
          ),
          child: Row(
            children: [
              Icon(
                selected
                    ? Icons.radio_button_checked_rounded
                    : Icons.radio_button_unchecked_rounded,
                size: 20,
                color: selected ? c.accent : c.textFaint,
              ),
              const SizedBox(width: OSpace.m),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      branch.name,
                      style: OType.body.copyWith(
                        color: selected ? c.accent : c.text,
                        fontWeight: selected
                            ? FontWeight.w600
                            : FontWeight.w400,
                      ),
                    ),
                    if (branch.lastCommitLabel.isNotEmpty)
                      Text(
                        branch.lastCommitLabel,
                        style: OType.caption.copyWith(color: c.textMuted),
                      ),
                    if (branch.isDefault) ...[
                      const SizedBox(height: OSpace.xs),
                      _StatusBadge(
                        label: 'Default',
                        tone: _BadgeTone.success,
                        dot: true,
                      ),
                    ],
                  ],
                ),
              ),
              if (selected) ...[
                const SizedBox(width: OSpace.s),
                Icon(Icons.check_rounded, size: 20, color: c.accent),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _ConnectHero extends StatelessWidget {
  const _ConnectHero({this.onConnectGithub});

  final VoidCallback? onConnectGithub;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    return OCard(
      padding: const EdgeInsets.fromLTRB(
        OSpace.xl,
        OSpace.xxl,
        OSpace.xl,
        OSpace.xl,
      ),
      child: Column(
        children: [
          Container(
            width: 76,
            height: 76,
            decoration: BoxDecoration(
              color: c.accentSoft,
              shape: BoxShape.circle,
            ),
            child: Icon(Icons.account_tree_rounded, size: 36, color: c.accent),
          ),
          const SizedBox(height: OSpace.l),
          Text(
            'Pick a repository to start',
            textAlign: TextAlign.center,
            style: OType.h1.copyWith(color: c.text),
          ),
          const SizedBox(height: OSpace.s),
          Text(
            'Ovid copies it to your private cloud workspace so you can build and edit safely.',
            textAlign: TextAlign.center,
            style: OType.bodySm.copyWith(color: c.textMuted),
          ),
          const SizedBox(height: OSpace.xl),
          if (onConnectGithub != null)
            OButton(
              label: 'Connect GitHub',
              icon: Icons.code_rounded,
              expand: true,
              onPressed: onConnectGithub,
            )
          else
            Text(
              'GitHub sign-in is not available yet. Enter a personal access '
              'token below.',
              textAlign: TextAlign.center,
              style: OType.caption.copyWith(color: c.textMuted),
            ),
        ],
      ),
    );
  }
}

class _ConnectedHeader extends StatelessWidget {
  const _ConnectedHeader({this.accountLabel, required this.repoCount});

  final String? accountLabel;
  final int repoCount;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    return Wrap(
      spacing: OSpace.m,
      runSpacing: OSpace.s,
      alignment: WrapAlignment.spaceBetween,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            OAvatar(initials: accountLabel ?? 'GitHub', size: 36),
            const SizedBox(width: OSpace.m),
            Flexible(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    accountLabel == null
                        ? 'Connected to GitHub'
                        : 'Connected as $accountLabel',
                    style: OType.bodySm.copyWith(
                      color: c.text,
                      fontWeight: FontWeight.w600,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  Text(
                    repoCount == 1 ? '1 repository' : '$repoCount repositories',
                    style: OType.caption.copyWith(color: c.textMuted),
                  ),
                ],
              ),
            ),
          ],
        ),
        const _StatusBadge(
          label: 'Connected',
          tone: _BadgeTone.success,
          dot: true,
        ),
      ],
    );
  }
}

class _NoReposHeader extends StatelessWidget {
  const _NoReposHeader();

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    return Wrap(
      spacing: OSpace.s,
      runSpacing: OSpace.xs,
      alignment: WrapAlignment.spaceBetween,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Text(
          'NO REPOSITORIES YET',
          style: OType.overline.copyWith(color: c.textMuted),
        ),
        const _StatusBadge(
          label: 'Ready to sync',
          tone: _BadgeTone.success,
          dot: true,
        ),
      ],
    );
  }
}

class _RepoRow extends StatelessWidget {
  const _RepoRow({required this.repo, this.onTap});

  final V2Repo repo;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    return OCard(
      onTap: onTap,
      semanticLabel:
          '${repo.fullName}, ${repo.isPrivate ? 'private' : 'public'} repository',
      padding: const EdgeInsets.symmetric(
        horizontal: OSpace.l,
        vertical: OSpace.m,
      ),
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: c.surfaceAlt,
              borderRadius: BorderRadius.circular(ORadius.m),
            ),
            child: Icon(
              repo.isPrivate
                  ? Icons.lock_outline_rounded
                  : Icons.folder_outlined,
              size: 21,
              color: c.textMuted,
            ),
          ),
          const SizedBox(width: OSpace.m),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: OSpace.s,
                  runSpacing: OSpace.xs,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text(
                      repo.fullName,
                      style: OType.bodyStrong.copyWith(color: c.text),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (repo.isPrivate)
                      const _StatusBadge(label: 'Private'),
                  ],
                ),
                if (repo.description != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    repo.description!,
                    style: OType.caption.copyWith(color: c.textMuted),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
                if (repo.language != null || repo.updatedLabel != null) ...[
                  const SizedBox(height: OSpace.xs),
                  Wrap(
                    spacing: 6,
                    runSpacing: 2,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      if (repo.language != null) ...[
                        Container(
                          width: 7,
                          height: 7,
                          decoration: BoxDecoration(
                            color: c.accent,
                            shape: BoxShape.circle,
                          ),
                        ),
                        Text(
                          repo.language!,
                          style: OType.caption.copyWith(color: c.textMuted),
                        ),
                      ],
                      if (repo.language != null && repo.updatedLabel != null)
                        Text(
                          '·',
                          style: OType.caption.copyWith(color: c.textFaint),
                        ),
                      if (repo.updatedLabel != null)
                        Text(
                          repo.updatedLabel!,
                          style: OType.caption.copyWith(color: c.textFaint),
                        ),
                    ],
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: OSpace.xs),
          Icon(Icons.chevron_right_rounded, size: 20, color: c.textFaint),
        ],
      ),
    );
  }
}

class _AdvancedRows extends StatelessWidget {
  const _AdvancedRows({this.onOpenToken, this.onOpenAdvanced});

  final VoidCallback? onOpenToken;
  final VoidCallback? onOpenAdvanced;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    return OCard(
      padding: EdgeInsets.zero,
      child: Column(
        children: [
          OListRow(
            key: const Key('repo-picker-token'),
            icon: Icons.key_rounded,
            title: 'Enter a personal access token',
            subtitle: onOpenToken == null
                ? 'Token entry is not connected yet'
                : 'Use for private organization setups',
            enabled: onOpenToken != null,
            showChevron: onOpenToken != null,
            onTap: onOpenToken,
          ),
          if (onOpenAdvanced != null) ...[
            Divider(height: 1, color: c.hairline),
            OListRow(
              key: const Key('repo-picker-advanced'),
              icon: Icons.tune_rounded,
              title: 'Advanced options',
              subtitle: 'Self-hosted GitLab, Bitbucket, SSH keys',
              onTap: onOpenAdvanced,
            ),
          ],
        ],
      ),
    );
  }
}

class _SecurityNote extends StatelessWidget {
  const _SecurityNote();

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    return Container(
      padding: const EdgeInsets.all(OSpace.m),
      decoration: BoxDecoration(
        color: c.surfaceAlt,
        borderRadius: BorderRadius.circular(ORadius.m),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.verified_user_rounded, size: 20, color: c.success),
          const SizedBox(width: OSpace.m),
          Expanded(
            child: Text(
              'Ovid asks for read-only access to your code. Your files stay in your private cloud.',
              style: OType.caption.copyWith(color: c.textMuted),
            ),
          ),
        ],
      ),
    );
  }
}

enum _BadgeTone { neutral, success }

/// Small status badge that can grow and wrap its label.
///
/// `OPill` is a fixed 24 dp tall row, so at 200% text its label both overflows
/// the pill and forces the surrounding row wider than a 320 dp phone. This
/// badge keeps the same tokens and colours but lets the label wrap, so it can
/// sit inside a `Wrap` or an `Expanded` without a horizontal overflow. It must
/// be placed where its width is bounded.
class _StatusBadge extends StatelessWidget {
  const _StatusBadge({
    required this.label,
    this.tone = _BadgeTone.neutral,
    this.dot = false,
  });

  final String label;
  final _BadgeTone tone;
  final bool dot;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    final (bg, fg) = switch (tone) {
      _BadgeTone.neutral => (c.surfaceAlt, c.textMuted),
      _BadgeTone.success => (c.success.withValues(alpha: 0.12), c.success),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
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
            const SizedBox(width: 6),
          ],
          Flexible(
            child: Text(
              label,
              style: OType.caption.copyWith(
                color: fg,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
