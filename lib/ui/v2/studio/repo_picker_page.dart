import 'dart:async';

import 'package:flutter/material.dart';

import '../../design/o_components.dart';
import '../../design/o_screen.dart';
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

  /// One meta line: language and last update, never a paragraph.
  String get metaLabel => [
    if (language != null && language!.trim().isNotEmpty) language!.trim(),
    if (updatedLabel != null && updatedLabel!.trim().isNotEmpty)
      updatedLabel!.trim(),
  ].join(' · ');

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

/// Pick a GitHub repository and a branch to copy into the cloud workspace.
///
/// Two steps, one primary action. The action stays disabled until both a
/// repository and a branch are selected, so a Studio chat can never start
/// without a folder binding.
class V2RepoPickerPage extends StatefulWidget {
  const V2RepoPickerPage({
    super.key,
    required this.data,
    this.onConfirm,
    this.onLoadBranches,
    this.onLoadMore,
    this.onConnectGithub,
    this.onOpenToken,
    this.onSearch,
    this.onRetry,
  });

  final V2RepoPickerData data;

  /// Fires when the user confirms a repository **and** a branch. This is the
  /// only callback that binds the folder for Studio mode, so a repository tap
  /// alone can never open the chat gate. When null the primary action is
  /// absent: a page that cannot bind must not pretend it started a workspace.
  final void Function(V2Repo repo, String branch)? onConfirm;

  /// Loads the real branch list for a repository when the data snapshot did
  /// not carry one. Returning an empty list is treated as "no branches".
  final Future<List<V2RepoBranch>> Function(V2Repo repo)? onLoadBranches;

  /// Fetches the next repository page. The gateway pages with `hasMore`, so
  /// the list is extended when the user reaches the end rather than fetching
  /// an unbounded list up front. Null means the list is already complete.
  final Future<void> Function()? onLoadMore;

  final VoidCallback? onConnectGithub;
  final VoidCallback? onOpenToken;
  final ValueChanged<String>? onSearch;
  final VoidCallback? onRetry;

  @override
  State<V2RepoPickerPage> createState() => _V2RepoPickerPageState();
}

class _V2RepoPickerPageState extends State<V2RepoPickerPage> {
  final TextEditingController _search = TextEditingController();
  final ScrollController _scroll = ScrollController();
  String _query = '';
  V2Repo? _selectedRepo;
  String? _selectedBranch;
  List<V2RepoBranch> _loadedBranches = const <V2RepoBranch>[];
  bool _loadingBranches = false;
  String? _branchError;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_maybeLoadMore);
  }

  @override
  void dispose() {
    _scroll.removeListener(_maybeLoadMore);
    _scroll.dispose();
    _search.dispose();
    super.dispose();
  }

  /// Asks for the next page when the repository list nears its end. The host
  /// owns the "already loading" guard, so a burst of scroll events is safe.
  void _maybeLoadMore() {
    final loadMore = widget.onLoadMore;
    if (loadMore == null || _selectedRepo != null) return;
    if (!_scroll.hasClients) return;
    final position = _scroll.position;
    if (!position.hasContentDimensions) return;
    if (position.pixels >= position.maxScrollExtent - 240) {
      unawaited(loadMore());
    }
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
        _branchError = 'Branches did not load.';
      });
    }
  }

  static String? _preferredBranchOf(V2Repo repo, List<V2RepoBranch> branches) {
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
    if (_selectedBranch == null) return 'Choose branch';
    return 'Start';
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
    final repo = _selectedRepo;
    // No confirm handler means no way to bind the folder, so there is no
    // primary action at all — never a permanently disabled "Start".
    final showPrimary =
        repo != null &&
        widget.onConfirm != null &&
        (data.status == V2RepoPickerStatus.content ||
            data.status == V2RepoPickerStatus.empty);
    return OScreen(
      title: repo == null ? 'Repositories' : repo.fullName,
      padding: false,
      // On the branch step the header back returns to the repository list, so
      // the body never repeats a second back affordance.
      leading: repo == null
          ? null
          : OIconButton(
              key: const Key('repo-picker-back-to-repos'),
              icon: Icons.arrow_back_rounded,
              semanticLabel: 'Back to repositories',
              onPressed: _changeRepo,
            ),
      bottomNavigationBar: showPrimary ? _buildPrimaryBar(context) : null,
      child: switch (data.status) {
        V2RepoPickerStatus.loading => const OSkeletonList(rows: 6),
        V2RepoPickerStatus.error => OErrorState(
          message: data.errorMessage ?? 'Repositories did not load.',
          onRetry: widget.onRetry,
        ),
        V2RepoPickerStatus.content || V2RepoPickerStatus.empty =>
          repo == null
              ? _buildRepoStep(context)
              : _buildBranchStep(context, repo),
      },
    );
  }

  Widget _buildRepoStep(BuildContext context) {
    final data = widget.data;
    if (!data.githubConnected) return _buildDisconnected(context);
    final repos = _visibleRepos;
    return CustomScrollView(
      controller: _scroll,
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(
            OSpace.l,
            OSpace.s,
            OSpace.l,
            OSpace.s,
          ),
          sliver: SliverToBoxAdapter(
            child: OSearchField(
              controller: _search,
              hint: 'Search repositories',
              onChanged: _onSearch,
            ),
          ),
        ),
        if (repos.isEmpty)
          SliverFillRemaining(
            hasScrollBody: false,
            child: data.repos.isEmpty
                ? OEmptyState(
                    compact: true,
                    icon: Icons.folder_open_rounded,
                    title: 'No repositories yet',
                    message: '',
                    action: widget.onRetry == null
                        ? null
                        : OButton(
                            label: 'Refresh',
                            icon: Icons.refresh_rounded,
                            onPressed: widget.onRetry,
                          ),
                  )
                : OEmptyState(
                    compact: true,
                    icon: Icons.search_off_rounded,
                    title: 'No matching repositories',
                    message: '',
                    action: OButton(
                      label: 'Clear search',
                      variant: OButtonVariant.secondary,
                      onPressed: _clearSearch,
                    ),
                  ),
          )
        else
          SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: OSpace.l),
            sliver: SliverList.builder(
              itemCount: repos.length,
              itemBuilder: (context, index) => _RepoRow(
                repo: repos[index],
                onTap: () => _selectRepo(repos[index]),
              ),
            ),
          ),
        const SliverToBoxAdapter(child: SizedBox(height: OSpace.xl)),
      ],
    );
  }

  /// Step two: the branch list for the selected repository.
  Widget _buildBranchStep(BuildContext context, V2Repo repo) {
    final branches = _branchesFor(repo);
    final error = _branchError;
    return CustomScrollView(
      slivers: [
        if (_loadingBranches)
          const SliverToBoxAdapter(
            child: SizedBox(
              height: 320,
              child: OSkeletonList(
                key: Key('repo-picker-branches-loading'),
                rows: 4,
              ),
            ),
          )
        else if (error != null)
          SliverFillRemaining(
            hasScrollBody: false,
            child: OEmptyState(
              compact: true,
              icon: Icons.cloud_off_rounded,
              title: 'Branches did not load',
              message: '',
              action: OButton(
                label: 'Try again',
                icon: Icons.refresh_rounded,
                variant: OButtonVariant.secondary,
                onPressed: () => _loadBranches(repo),
              ),
            ),
          )
        else if (branches.isEmpty)
          SliverFillRemaining(
            hasScrollBody: false,
            child: OEmptyState(
              compact: true,
              icon: Icons.account_tree_outlined,
              title: 'No branches found',
              message: '',
              action: widget.onLoadBranches == null
                  ? null
                  : OButton(
                      label: 'Reload',
                      icon: Icons.refresh_rounded,
                      variant: OButtonVariant.secondary,
                      onPressed: () => _loadBranches(repo),
                    ),
            ),
          )
        else
          SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: OSpace.l),
            sliver: SliverList.builder(
              itemCount: branches.length,
              itemBuilder: (context, index) {
                final branch = branches[index];
                return _BranchChoice(
                  branch: branch,
                  selected: branch.name == _selectedBranch,
                  onTap: () => _selectBranch(branch.name),
                );
              },
            ),
          ),
        const SliverToBoxAdapter(child: SizedBox(height: OSpace.xl)),
      ],
    );
  }

  Widget _buildDisconnected(BuildContext context) {
    return OEmptyState(
      icon: Icons.account_tree_rounded,
      title: 'No repositories yet',
      message: '',
      action: widget.onConnectGithub == null
          ? null
          : OButton(
              label: 'Connect GitHub',
              icon: Icons.code_rounded,
              onPressed: widget.onConnectGithub,
            ),
      secondaryAction: widget.onOpenToken == null
          ? null
          : OTextAction(label: 'Use a token', onPressed: widget.onOpenToken),
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
        child: OButton(
          key: const Key('repo-picker-primary'),
          label: _primaryLabel,
          icon: ready ? Icons.play_arrow_rounded : null,
          expand: true,
          onPressed: ready ? _confirm : null,
        ),
      ),
    );
  }
}

/// One repository row: an icon and `owner/name`. Nothing else — the list is
/// the picker, not a dashboard about the account.
class _RepoRow extends StatelessWidget {
  const _RepoRow({required this.repo, this.onTap});

  final V2Repo repo;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    return Semantics(
      container: true,
      button: onTap != null,
      enabled: onTap != null,
      label:
          '${repo.fullName}, ${repo.isPrivate ? 'private' : 'public'} repository',
      excludeSemantics: true,
      onTap: onTap,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: OSpace.listRow),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: OSpace.s,
                vertical: OSpace.s,
              ),
              child: Row(
                children: [
                  Icon(
                    repo.isPrivate
                        ? Icons.lock_outline_rounded
                        : Icons.folder_outlined,
                    size: 18,
                    color: c.textMuted,
                  ),
                  const SizedBox(width: OSpace.m),
                  Expanded(
                    child: Text(
                      repo.fullName,
                      style: OType.body.copyWith(
                        color: c.text,
                        fontWeight: FontWeight.w500,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (onTap != null) ...[
                    const SizedBox(width: OSpace.xs),
                    Icon(
                      Icons.chevron_right_rounded,
                      size: 20,
                      color: c.textFaint,
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// One branch row: the same list pattern as the repository step — an icon,
/// the branch name, and a check at the trailing edge when selected.
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
    return Semantics(
      container: true,
      excludeSemantics: true,
      button: onTap != null,
      enabled: onTap != null,
      selected: selected,
      label: selected ? '$label, selected' : label,
      onTap: onTap,
      child: Material(
        color: selected ? c.accentSoft : Colors.transparent,
        child: InkWell(
          key: Key('repo-picker-branch-${branch.name}'),
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: OSpace.listRow),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: OSpace.s,
                vertical: OSpace.s,
              ),
              child: Row(
                children: [
                  Icon(
                    Icons.account_tree_outlined,
                    size: 18,
                    color: selected ? c.accent : c.textMuted,
                  ),
                  const SizedBox(width: OSpace.m),
                  Expanded(
                    child: Text(
                      branch.name,
                      style: OType.body.copyWith(
                        color: selected ? c.accent : c.text,
                        fontWeight: selected
                            ? FontWeight.w600
                            : FontWeight.w400,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (selected) ...[
                    const SizedBox(width: OSpace.xs),
                    Icon(Icons.check_rounded, size: 20, color: c.accent),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
