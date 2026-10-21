import 'package:flutter/material.dart';

import '../../design/o_components.dart';
import '../../design/o_motion.dart';
import '../../design/o_tokens.dart';

// TODO(l10n): route all user-facing copy through the ARB pass.

enum V2SearchStatus { loading, content, error }

/// Immutable view data for the Search screen.
@immutable
class V2SearchData {
  const V2SearchData({
    this.initialQuery = '',
    this.recentSearches = const <String>[],
    this.chats = const <V2SearchChat>[],
    this.projects = const <V2SearchProject>[],
    this.artifacts = const <V2SearchArtifact>[],
    this.suggestions = const <String>[],
    this.status = V2SearchStatus.content,
    this.errorMessage,
  });

  final String initialQuery;
  final List<String> recentSearches;
  final List<V2SearchChat> chats;
  final List<V2SearchProject> projects;
  final List<V2SearchArtifact> artifacts;
  final List<String> suggestions;
  final V2SearchStatus status;
  final String? errorMessage;
}

@immutable
class V2SearchChat {
  const V2SearchChat({
    required this.id,
    required this.title,
    required this.modelLabel,
    required this.timeLabel,
    this.snippet = '',
  });

  final String id;
  final String title;
  final String modelLabel;
  final String timeLabel;
  final String snippet;
}

@immutable
class V2SearchProject {
  const V2SearchProject({
    required this.id,
    required this.name,
    required this.chatCount,
    this.detail = '',
  });

  final String id;
  final String name;
  final int chatCount;
  final String detail;

  String get chatLabel => chatCount == 1 ? '1 chat' : '$chatCount chats';
}

@immutable
class V2SearchArtifact {
  const V2SearchArtifact({
    required this.id,
    required this.name,
    this.meta = '',
  });

  final String id;
  final String name;
  final String meta;
}

/// Search across chats, projects and artifacts, with recent searches and
/// highlighted matches. Results are filtered locally from [data] so the screen
/// is useful before the wiring connects a live query.
class SearchPage extends StatefulWidget {
  const SearchPage({
    super.key,
    required this.data,
    this.onChatTap,
    this.onProjectTap,
    this.onArtifactTap,
    this.onQueryChanged,
    this.onRemoveRecent,
    this.onClearRecents,
    this.onCancel,
    this.onRetry,
  });

  final V2SearchData data;
  final ValueChanged<V2SearchChat>? onChatTap;
  final ValueChanged<V2SearchProject>? onProjectTap;
  final ValueChanged<V2SearchArtifact>? onArtifactTap;
  final ValueChanged<String>? onQueryChanged;
  final ValueChanged<String>? onRemoveRecent;
  final VoidCallback? onClearRecents;
  final VoidCallback? onCancel;
  final VoidCallback? onRetry;

  @override
  State<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage> {
  late final TextEditingController _controller;
  late String _query;
  late List<String> _recents;

  @override
  void initState() {
    super.initState();
    _query = widget.data.initialQuery;
    _controller = TextEditingController(text: _query);
    _recents = List<String>.of(widget.data.recentSearches);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// Chips offered when there is no history. Wiring can pass its own; the
  /// fallback reuses titles already in the injected index so the screen never
  /// ships demo search terms as production copy.
  List<String> get _suggestions {
    if (widget.data.suggestions.isNotEmpty) return widget.data.suggestions;
    final titles = <String>{
      for (final chat in widget.data.chats)
        if (chat.title.trim().isNotEmpty) chat.title.trim(),
      for (final project in widget.data.projects)
        if (project.name.trim().isNotEmpty) project.name.trim(),
    };
    return titles.take(3).toList(growable: false);
  }

  bool _has(String text) {
    final query = _query.trim().toLowerCase();
    return query.isNotEmpty && text.toLowerCase().contains(query);
  }

  void _onChanged(String value) {
    setState(() => _query = value);
    widget.onQueryChanged?.call(value);
  }

  void _setQuery(String value) {
    _controller.value = TextEditingValue(
      text: value,
      selection: TextSelection.collapsed(offset: value.length),
    );
    setState(() => _query = value);
    widget.onQueryChanged?.call(value);
  }

  void _clearQuery() => _setQuery('');

  void _removeRecent(String value) {
    setState(() => _recents.remove(value));
    widget.onRemoveRecent?.call(value);
  }

  void _clearRecents() {
    setState(_recents.clear);
    widget.onClearRecents?.call();
  }

  @override
  Widget build(BuildContext context) {
    return OScaffold(
      appBar: const OAppBar(title: 'Search'),
      body: OFadeSlide(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: OSpace.screen),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: OSpace.s),
              Row(
                children: [
                  Expanded(
                    child: OSearchField(
                      controller: _controller,
                      hint: 'Search chats, projects, and files',
                      autofocus: true,
                      onChanged: _onChanged,
                      trailing: _query.isEmpty
                          ? null
                          : OIconButton(
                              icon: Icons.close_rounded,
                              semanticLabel: 'Clear search',
                              size: 18,
                              onPressed: _clearQuery,
                            ),
                    ),
                  ),
                  const SizedBox(width: OSpace.s),
                  OButton(
                    label: 'Cancel',
                    variant: OButtonVariant.ghost,
                    size: OButtonSize.compact,
                    onPressed:
                        widget.onCancel ?? () => Navigator.maybePop(context),
                  ),
                ],
              ),
              const SizedBox(height: OSpace.m),
              Expanded(child: _buildBody(context)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBody(BuildContext context) {
    switch (widget.data.status) {
      case V2SearchStatus.loading:
        return Semantics(
          label: 'Loading search results',
          child: const OSkeletonList(rows: 5),
        );
      case V2SearchStatus.error:
        return OErrorState(
          title: 'Search did not load',
          message:
              widget.data.errorMessage ??
              'Check your connection and try again.',
          onRetry: widget.onRetry,
        );
      case V2SearchStatus.content:
        if (_query.trim().isEmpty) return _buildBrowse(context);
        return _buildResults(context);
    }
  }

  Widget _buildBrowse(BuildContext context) {
    final c = OColors.of(context);
    final suggestions = _suggestions;
    if (_recents.isEmpty) {
      return OEmptyState(
        icon: Icons.search_rounded,
        title: suggestions.isEmpty ? 'Nothing to search yet' : 'Search Ovid Si',
        message: suggestions.isEmpty
            ? 'Chats, projects, and files you make will show up here.'
            : 'Find chats, projects, and artifacts in one place.',
        action: suggestions.isEmpty
            ? null
            : _SuggestionChips(
                suggestions: suggestions,
                onSelected: _setQuery,
              ),
      );
    }

    return ListView(
      padding: const EdgeInsets.only(bottom: OSpace.xl),
      children: [
        OSectionHeader(
          label: 'Recent searches',
          trailing: OButton(
            label: 'Clear all',
            variant: OButtonVariant.ghost,
            size: OButtonSize.compact,
            onPressed: _clearRecents,
          ),
          padding: const EdgeInsets.fromLTRB(0, OSpace.s, 0, OSpace.s),
        ),
        OStagger(
          children: [
            for (final recent in _recents)
              Padding(
                padding: const EdgeInsets.only(bottom: OSpace.s),
                child: _RecentRow(
                  value: recent,
                  onTap: () => _setQuery(recent),
                  onRemove: () => _removeRecent(recent),
                ),
              ),
          ],
        ),
        const SizedBox(height: OSpace.m),
        if (suggestions.isNotEmpty) ...[
          Text(
            'Try a search',
            style: OType.caption.copyWith(color: c.textMuted),
          ),
          const SizedBox(height: OSpace.s),
          _SuggestionChips(suggestions: suggestions, onSelected: _setQuery),
        ],
      ],
    );
  }

  Widget _buildResults(BuildContext context) {
    final c = OColors.of(context);
    final chats = widget.data.chats
        .where((chat) => _has(chat.title) || _has(chat.snippet))
        .toList(growable: false);
    final projects = widget.data.projects
        .where((project) => _has(project.name) || _has(project.detail))
        .toList(growable: false);
    final artifacts = widget.data.artifacts
        .where((artifact) => _has(artifact.name) || _has(artifact.meta))
        .toList(growable: false);

    if (chats.isEmpty && projects.isEmpty && artifacts.isEmpty) {
      final suggestions = _suggestions;
      return OEmptyState(
        icon: Icons.search_off_rounded,
        title: 'No matches for “${_query.trim()}”',
        message: 'Try another word or check the spelling.',
        action: suggestions.isEmpty
            ? OButton(
                label: 'Clear search',
                variant: OButtonVariant.ghost,
                onPressed: _clearQuery,
              )
            : _SuggestionChips(
                suggestions: suggestions,
                onSelected: _setQuery,
              ),
      );
    }

    return ListView(
      padding: const EdgeInsets.only(bottom: OSpace.xl),
      children: [
        if (chats.isNotEmpty) ...[
          OSectionHeader(
            label: 'Chats (${chats.length})',
            trailing: Flexible(
              child: Text(
                'Best matches',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.end,
                style: OType.caption.copyWith(color: c.textMuted),
              ),
            ),
            padding: const EdgeInsets.fromLTRB(0, OSpace.s, 0, OSpace.s),
          ),
          OStagger(
            children: [
              for (final chat in chats)
                Padding(
                  padding: const EdgeInsets.only(bottom: OSpace.s),
                  child: _ChatResult(
                    chat: chat,
                    query: _query,
                    onTap: widget.onChatTap == null
                        ? null
                        : () => widget.onChatTap!(chat),
                  ),
                ),
            ],
          ),
        ],
        if (projects.isNotEmpty) ...[
          OSectionHeader(
            label: 'Projects (${projects.length})',
            padding: const EdgeInsets.fromLTRB(0, OSpace.m, 0, OSpace.s),
          ),
          OStagger(
            children: [
              for (final project in projects)
                Padding(
                  padding: const EdgeInsets.only(bottom: OSpace.s),
                  child: _ProjectResult(
                    project: project,
                    query: _query,
                    onTap: widget.onProjectTap == null
                        ? null
                        : () => widget.onProjectTap!(project),
                  ),
                ),
            ],
          ),
        ],
        if (artifacts.isNotEmpty) ...[
          OSectionHeader(
            label: 'Artifacts (${artifacts.length})',
            padding: const EdgeInsets.fromLTRB(0, OSpace.m, 0, OSpace.s),
          ),
          OStagger(
            children: [
              for (final artifact in artifacts)
                Padding(
                  padding: const EdgeInsets.only(bottom: OSpace.s),
                  child: _ArtifactResult(
                    artifact: artifact,
                    query: _query,
                    onTap: widget.onArtifactTap == null
                        ? null
                        : () => widget.onArtifactTap!(artifact),
                  ),
                ),
            ],
          ),
        ],
      ],
    );
  }
}

class _RecentRow extends StatelessWidget {
  const _RecentRow({required this.value, this.onTap, this.onRemove});

  final String value;
  final VoidCallback? onTap;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    return Container(
      decoration: BoxDecoration(
        color: c.surfaceAlt,
        borderRadius: BorderRadius.circular(ORadius.m),
      ),
      child: Row(
        children: [
          Expanded(
            child: OPressable(
              onTap: onTap,
              semanticLabel: 'Search for $value',
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: OSpace.touch),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: OSpace.m,
                    vertical: OSpace.s,
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.history_rounded, size: 18, color: c.textFaint),
                      const SizedBox(width: OSpace.m),
                      Expanded(
                        child: Text(
                          value,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: OType.bodySm.copyWith(color: c.text),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          OIconButton(
            icon: Icons.close_rounded,
            semanticLabel: 'Remove $value from recent searches',
            size: 18,
            onPressed: onRemove,
          ),
        ],
      ),
    );
  }
}

class _SuggestionChips extends StatelessWidget {
  const _SuggestionChips({required this.suggestions, required this.onSelected});

  final List<String> suggestions;
  final ValueChanged<String> onSelected;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: OSpace.m,
      runSpacing: 0,
      alignment: WrapAlignment.center,
      children: [
        for (final suggestion in suggestions)
          _SuggestionChip(
            label: suggestion,
            onTap: () => onSelected(suggestion),
          ),
      ],
    );
  }
}

/// A suggestion chip with a 48 dp touch target and a label that ellipsizes
/// instead of overflowing at large text scales.
class _SuggestionChip extends StatelessWidget {
  const _SuggestionChip({required this.label, this.onTap});

  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    return OPressable(
      onTap: onTap,
      semanticLabel: 'Search for $label',
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: OSpace.touch),
        child: Align(
          widthFactor: 1,
          heightFactor: 1,
          child: Container(
            constraints: const BoxConstraints(minHeight: 36),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            decoration: BoxDecoration(
              color: c.surface,
              borderRadius: BorderRadius.circular(ORadius.m),
              border: Border.all(color: c.hairline),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.search_rounded, size: 15, color: c.textMuted),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: OType.label.copyWith(color: c.textMuted),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ChatResult extends StatelessWidget {
  const _ChatResult({required this.chat, required this.query, this.onTap});

  final V2SearchChat chat;
  final String query;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    final titleStyle = OType.bodySm.copyWith(
      color: c.text,
      fontWeight: FontWeight.w600,
    );
    final snippetStyle = OType.bodySm.copyWith(color: c.textMuted);
    return OCard(
      padding: const EdgeInsets.all(OSpace.m),
      onTap: onTap,
      semanticLabel: 'Chat, ${chat.title}',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              _ResultIcon(
                icon: Icons.chat_bubble_outline_rounded,
                color: c.accent,
              ),
              const SizedBox(width: OSpace.m),
              Expanded(
                child: Text.rich(
                  TextSpan(
                    children: _highlight(
                      chat.title,
                      query,
                      titleStyle,
                      _highlightStyle(c, titleStyle),
                    ),
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          if (chat.modelLabel.isNotEmpty || chat.timeLabel.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(left: OSpace.touch, top: OSpace.xs),
              child: Wrap(
                spacing: OSpace.s,
                runSpacing: OSpace.xs,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  if (chat.modelLabel.isNotEmpty)
                    _MetaPill(label: chat.modelLabel),
                  if (chat.timeLabel.isNotEmpty)
                    Text(
                      chat.timeLabel,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: OType.caption.copyWith(color: c.textFaint),
                    ),
                ],
              ),
            ),
          if (chat.snippet.isNotEmpty) ...[
            const SizedBox(height: OSpace.s),
            Padding(
              padding: const EdgeInsets.only(left: OSpace.touch),
              child: Text.rich(
                TextSpan(
                  children: _highlight(
                    chat.snippet,
                    query,
                    snippetStyle,
                    _highlightStyle(c, snippetStyle),
                  ),
                ),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Model badge that grows with the text scale. `OPill` has a fixed height, so
/// it would clip or overlap at 200 % text.
class _MetaPill extends StatelessWidget {
  const _MetaPill({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    return Container(
      constraints: const BoxConstraints(minHeight: 24),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
      decoration: BoxDecoration(
        color: c.surfaceAlt,
        borderRadius: BorderRadius.circular(ORadius.pill),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: OType.caption.copyWith(
                color: c.textMuted,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ProjectResult extends StatelessWidget {
  const _ProjectResult({
    required this.project,
    required this.query,
    this.onTap,
  });

  final V2SearchProject project;
  final String query;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    final style = OType.bodySm.copyWith(
      color: c.text,
      fontWeight: FontWeight.w600,
    );
    return OCard(
      padding: const EdgeInsets.all(OSpace.m),
      onTap: onTap,
      semanticLabel: 'Project, ${project.name}',
      child: Row(
        children: [
          _ResultIcon(icon: Icons.folder_rounded, color: c.success),
          const SizedBox(width: OSpace.m),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text.rich(
                  TextSpan(
                    children: _highlight(
                      project.name,
                      query,
                      style,
                      _highlightStyle(c, style),
                    ),
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                Text(
                  project.detail.isEmpty
                      ? project.chatLabel
                      : '${project.chatLabel} · ${project.detail}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: OType.caption.copyWith(color: c.textMuted),
                ),
              ],
            ),
          ),
          Icon(Icons.chevron_right_rounded, size: 20, color: c.textFaint),
        ],
      ),
    );
  }
}

class _ArtifactResult extends StatelessWidget {
  const _ArtifactResult({
    required this.artifact,
    required this.query,
    this.onTap,
  });

  final V2SearchArtifact artifact;
  final String query;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    final style = OType.bodySm.copyWith(
      color: c.text,
      fontWeight: FontWeight.w600,
    );
    return OCard(
      padding: const EdgeInsets.all(OSpace.m),
      onTap: onTap,
      semanticLabel: 'Artifact, ${artifact.name}',
      child: Row(
        children: [
          _ResultIcon(icon: Icons.code_rounded, color: c.accent),
          const SizedBox(width: OSpace.m),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text.rich(
                        TextSpan(
                          children: _highlight(
                            artifact.name,
                            query,
                            style,
                            _highlightStyle(c, style),
                          ),
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: OSpace.s),
                    Container(
                      width: 7,
                      height: 7,
                      decoration: BoxDecoration(
                        color: c.success,
                        shape: BoxShape.circle,
                      ),
                    ),
                  ],
                ),
                if (artifact.meta.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    artifact.meta,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: OType.caption.copyWith(color: c.textMuted),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: OSpace.s),
          Flexible(
            child: Align(
              alignment: Alignment.centerRight,
              child: OButton(
                label: 'Preview',
                variant: OButtonVariant.ghost,
                size: OButtonSize.compact,
                onPressed: onTap,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ResultIcon extends StatelessWidget {
  const _ResultIcon({required this.icon, required this.color});

  final IconData icon;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 36,
      height: 36,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(ORadius.m),
      ),
      child: Icon(icon, size: 19, color: color),
    );
  }
}

TextStyle _highlightStyle(OColors c, TextStyle base) => base.copyWith(
  color: c.accent,
  backgroundColor: c.accentSoft,
  fontWeight: FontWeight.w600,
);

List<TextSpan> _highlight(
  String text,
  String query,
  TextStyle base,
  TextStyle highlight,
) {
  final needle = query.trim().toLowerCase();
  if (needle.isEmpty || text.isEmpty) {
    return <TextSpan>[TextSpan(text: text, style: base)];
  }
  final lower = text.toLowerCase();
  final spans = <TextSpan>[];
  var start = 0;
  while (true) {
    final index = lower.indexOf(needle, start);
    if (index < 0) break;
    if (index > start) {
      spans.add(TextSpan(text: text.substring(start, index), style: base));
    }
    spans.add(
      TextSpan(
        text: text.substring(index, index + needle.length),
        style: highlight,
      ),
    );
    start = index + needle.length;
  }
  if (start < text.length) {
    spans.add(TextSpan(text: text.substring(start), style: base));
  }
  if (spans.isEmpty) {
    spans.add(TextSpan(text: text, style: base));
  }
  return spans;
}
