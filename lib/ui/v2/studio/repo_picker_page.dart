import 'package:flutter/material.dart';

import '../../design/o_components.dart';
import '../../design/o_motion.dart';
import '../../design/o_tokens.dart';

// TODO(l10n): move user-facing copy to the ARB files in the next wave.

/// What the repo picker is doing right now.
enum V2RepoPickerStatus { loading, content, empty, error }

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
  });

  final String id;
  final String name;
  final String owner;
  final String? description;
  final String? language;
  final String? updatedLabel;
  final bool isPrivate;

  String get fullName => owner.isEmpty ? name : '$owner/$name';
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
class V2RepoPickerPage extends StatefulWidget {
  const V2RepoPickerPage({
    super.key,
    required this.data,
    this.onSelectRepo,
    this.onConnectGithub,
    this.onOpenToken,
    this.onOpenAdvanced,
    this.onSearch,
    this.onRetry,
  });

  final V2RepoPickerData data;
  final ValueChanged<V2Repo>? onSelectRepo;
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
    return OScaffold(
      appBar: OAppBar(
        title: 'Studio',
        subtitle: 'Pick a repository',
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
      child: _RepoRow(
        repo: repo,
        onTap: () => widget.onSelectRepo?.call(repo),
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
          OButton(
            label: 'Connect GitHub',
            icon: Icons.code_rounded,
            expand: true,
            onPressed: onConnectGithub,
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
            icon: Icons.key_rounded,
            title: 'Enter a personal access token',
            subtitle: 'Use for private organization setups',
            onTap: onOpenToken,
          ),
          Divider(height: 1, color: c.hairline),
          OListRow(
            icon: Icons.tune_rounded,
            title: 'Advanced options',
            subtitle: 'Self-hosted GitLab, Bitbucket, SSH keys',
            onTap: onOpenAdvanced,
          ),
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
