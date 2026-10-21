// TODO(l10n): move user-facing copy to the ARB files in the localization pass.
import 'package:flutter/material.dart';

import '../../design/o_components.dart';
import '../../design/o_motion.dart';
import '../../design/o_tokens.dart';
import '../chat/transcript_actions.dart';
import 'artifact_actions.dart';
import 'artifact_detail_page.dart';
import 'artifact_filters.dart';

/// The four artifact families shown by the filter chips.
enum V2ArtifactKind { image, document, code, data }

/// Where an artifact came from. The library holds both agent output and files
/// the user uploaded; Studio drafts are deliberately not part of it.
enum V2ArtifactSource { generated, uploaded }

enum V2ArtifactsStatus { loading, content, empty, error }

@immutable
class V2ArtifactItem {
  const V2ArtifactItem({
    required this.id,
    required this.name,
    required this.kind,
    required this.createdAt,
    required this.sizeLabel,
    this.sizeBytes = 0,
    this.source = V2ArtifactSource.generated,
    this.sessionTitle = '',
    this.thumbnail,
    this.url,
    this.badge,
    this.live = false,
  });

  final String id;
  final String name;
  final V2ArtifactKind kind;
  final DateTime createdAt;
  final String sizeLabel;

  /// Raw size for the library total. Optional so older wiring keeps working;
  /// when it is zero the row still shows [sizeLabel].
  final int sizeBytes;
  final V2ArtifactSource source;

  /// Title of the chat or run that produced the artifact. Empty for older
  /// entries and for uploads that are not tied to a session.
  final String sessionTitle;
  final ImageProvider? thumbnail;

  /// A fresh, signed URL for the file, when the wiring layer has one. It backs
  /// the image thumbnail, the download action and "copy link"; when it is null
  /// those controls are not offered at all.
  final String? url;
  final String? badge;
  final bool live;
}

@immutable
class V2ArtifactsData {
  const V2ArtifactsData({
    this.status = V2ArtifactsStatus.content,
    this.artifacts = const <V2ArtifactItem>[],
    this.totalSizeLabel,
    this.errorMessage =
        'We could not load your artifacts. Check your connection and try again.',
    this.now,
  });

  final V2ArtifactsStatus status;
  final List<V2ArtifactItem> artifacts;

  /// Pre-formatted total supplied by the wiring layer. When null the page adds
  /// up [V2ArtifactItem.sizeBytes] itself.
  final String? totalSizeLabel;
  final String errorMessage;

  /// Injectable clock so relative dates stay stable in tests and previews.
  final DateTime? now;
}

/// Artifacts library: the user's lifetime library of agent-made files and
/// uploads, searchable across every session.
///
/// Presentational only. The wiring layer owns the list, loading, errors and
/// every navigation callback.
class ArtifactsPage extends StatefulWidget {
  const ArtifactsPage({
    super.key,
    required this.data,
    this.onArtifactTap,
    this.onArtifactMenu,
    this.onNewArtifact,
    this.onSeeIdeas,
    this.onRetry,
    this.onOpenMenu,
    this.onSearch,
    this.onNotifications,
  });

  final V2ArtifactsData data;
  final ValueChanged<V2ArtifactItem>? onArtifactTap;
  final ValueChanged<V2ArtifactItem>? onArtifactMenu;
  final VoidCallback? onNewArtifact;
  final VoidCallback? onSeeIdeas;
  final VoidCallback? onRetry;
  final VoidCallback? onOpenMenu;
  final VoidCallback? onSearch;
  final VoidCallback? onNotifications;

  @override
  State<ArtifactsPage> createState() => _ArtifactsPageState();
}

class _ArtifactsPageState extends State<ArtifactsPage> {
  final TextEditingController _searchController = TextEditingController();
  V2ArtifactFilters _filters = const V2ArtifactFilters();
  String _query = '';

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  bool get _filtering => _query.trim().isNotEmpty || _filters.isActive;

  /// One filter option per chat title, with how many files it made.
  List<V2ArtifactSession> _sessionsFor(List<V2ArtifactItem> artifacts) {
    final counts = <String, int>{};
    for (final artifact in artifacts) {
      final title = artifact.sessionTitle.trim();
      if (title.isEmpty) continue;
      counts[title] = (counts[title] ?? 0) + 1;
    }
    return [
      for (final entry in counts.entries)
        V2ArtifactSession(
          id: _sessionId(entry.key),
          title: entry.key,
          count: entry.value,
        ),
    ];
  }

  String _sessionId(String title) => 'session:$title';

  List<V2ArtifactItem> get _visible {
    final query = _query.trim().toLowerCase();
    final items = widget.data.artifacts
        .where(
          (artifact) =>
              _matchesSource(artifact) &&
              _matchesType(artifact) &&
              _matchesDate(artifact) &&
              _matchesSession(artifact) &&
              (query.isEmpty ||
                  artifact.name.toLowerCase().contains(query) ||
                  artifact.sessionTitle.toLowerCase().contains(query)),
        )
        .toList();
    return _sorted(items);
  }

  bool _matchesSource(V2ArtifactItem artifact) => switch (_filters.source) {
    V2ArtifactSourceFilter.all => true,
    V2ArtifactSourceFilter.generated =>
      artifact.source == V2ArtifactSource.generated,
    V2ArtifactSourceFilter.uploaded =>
      artifact.source == V2ArtifactSource.uploaded,
  };

  /// Type families are exclusive: an HTML page is a "Page", never a "Doc", and
  /// "Other" only catches the data files the four named families miss.
  bool _matchesType(V2ArtifactItem artifact) => switch (_filters.type) {
    V2ArtifactTypeFilter.all => true,
    V2ArtifactTypeFilter.image => artifact.kind == V2ArtifactKind.image,
    V2ArtifactTypeFilter.page => _isPage(artifact),
    V2ArtifactTypeFilter.code => artifact.kind == V2ArtifactKind.code,
    V2ArtifactTypeFilter.doc =>
      artifact.kind == V2ArtifactKind.document && !_isPage(artifact),
    V2ArtifactTypeFilter.other => artifact.kind == V2ArtifactKind.data,
  };

  /// HTML artifacts are the library's pages. The vault maps them onto the
  /// document kind, so the file name is what tells a page from a PDF.
  bool _isPage(V2ArtifactItem artifact) {
    if (artifact.kind != V2ArtifactKind.document) return false;
    final ext = _extension(artifact.name).toLowerCase();
    return ext == 'html' || ext == 'htm';
  }

  bool _matchesDate(V2ArtifactItem artifact) {
    final filter = _filters.date;
    if (filter == V2ArtifactDateFilter.all) return true;
    final now = widget.data.now ?? DateTime.now();
    final created = artifact.createdAt.toLocal();
    final today = DateTime(now.year, now.month, now.day);
    final day = DateTime(created.year, created.month, created.day);
    final days = today.difference(day).inDays;
    // A future timestamp (clock skew) still counts as "today".
    if (days < 0) return true;
    return switch (filter) {
      V2ArtifactDateFilter.all => true,
      V2ArtifactDateFilter.today => days == 0,
      V2ArtifactDateFilter.week => days < 7,
      V2ArtifactDateFilter.month => days < 30,
    };
  }

  bool _matchesSession(V2ArtifactItem artifact) {
    final id = _filters.sessionId;
    if (id == null) return true;
    final title = artifact.sessionTitle.trim();
    return title.isNotEmpty && _sessionId(title) == id;
  }

  List<V2ArtifactItem> _sorted(List<V2ArtifactItem> items) {
    final sorted = [...items];
    switch (_filters.sort) {
      case V2ArtifactSort.newest:
        sorted.sort((a, b) => b.createdAt.compareTo(a.createdAt));
      case V2ArtifactSort.oldest:
        sorted.sort((a, b) => a.createdAt.compareTo(b.createdAt));
      case V2ArtifactSort.largest:
        sorted.sort((a, b) {
          final bySize = b.sizeBytes.compareTo(a.sizeBytes);
          return bySize != 0 ? bySize : b.createdAt.compareTo(a.createdAt);
        });
      case V2ArtifactSort.name:
        sorted.sort(
          (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
        );
    }
    return sorted;
  }

  void _setQuery(String value) {
    setState(() => _query = value);
  }

  void _clearFilters() {
    _searchController.clear();
    setState(() {
      _query = '';
      _filters = const V2ArtifactFilters();
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    final showFab =
        widget.onNewArtifact != null &&
        (widget.data.status == V2ArtifactsStatus.content ||
            widget.data.status == V2ArtifactsStatus.empty);

    return OScaffold(
      appBar: OAppBar(
        title: 'Ovid Si',
        subtitle: 'Artifacts Library',
        showBack: false,
        // Host-level chrome is only drawn when the host can actually handle it:
        // a visible icon with a null handler is a dead control.
        leading: widget.onOpenMenu == null
            ? null
            : OIconButton(
                icon: Icons.menu_rounded,
                semanticLabel: 'Open menu',
                onPressed: widget.onOpenMenu,
              ),
        actions: [
          if (widget.onSearch != null)
            OIconButton(
              icon: Icons.search_rounded,
              semanticLabel: 'Search artifacts',
              onPressed: widget.onSearch,
            ),
          if (widget.onNotifications != null)
            OIconButton(
              icon: Icons.notifications_none_rounded,
              semanticLabel: 'Notifications',
              onPressed: widget.onNotifications,
            ),
        ],
      ),
      floatingActionButton: showFab
          ? Padding(
              padding: const EdgeInsets.only(bottom: OSpace.s),
              child: OButton(
                label: 'New artifact',
                icon: Icons.add_rounded,
                onPressed: widget.onNewArtifact,
              ),
            )
          : null,
      body: OFadeSlide(
        child: OAnimatedSwap(
          child: switch (widget.data.status) {
            V2ArtifactsStatus.loading => const OSkeletonList(rows: 6),
            V2ArtifactsStatus.error => OErrorState(
              message: widget.data.errorMessage,
              onRetry: widget.onRetry,
            ),
            V2ArtifactsStatus.empty => _empty(),
            V2ArtifactsStatus.content => _content(c),
          },
        ),
      ),
    );
  }

  /// Shown when the library itself is empty (status empty). Distinct from
  /// "No matches", which means artifacts exist but none pass the filters.
  Widget _empty() {
    return OEmptyState(
      icon: Icons.auto_awesome_rounded,
      title: 'No artifacts yet',
      message:
          'Files Ovid makes in any chat, plus files you upload, show up here. '
          'Studio drafts stay in Studio. Deleting an artifact frees its '
          'storage right away.',
      action: widget.onSeeIdeas == null
          ? null
          : OButton(
              label: 'See what Ovid can make',
              icon: Icons.arrow_forward_rounded,
              onPressed: widget.onSeeIdeas,
            ),
    );
  }

  Widget _content(OColors c) {
    final items = _visible;
    final sessions = _sessionsFor(widget.data.artifacts);
    final rowCount = (items.length + 1) ~/ 2;
    // The header and footer are fixed; the grid itself is lazy, so a library
    // with thousands of artifacts only builds the visible rows.
    final header = <Widget>[
      _librarySummary(c),
      const SizedBox(height: OSpace.m),
      OSearchField(
        controller: _searchController,
        hint: 'Search files and chats',
        onChanged: _setQuery,
        trailing: _query.isEmpty
            ? null
            : OIconButton(
                icon: Icons.close_rounded,
                semanticLabel: 'Clear search',
                size: 18,
                onPressed: () {
                  _searchController.clear();
                  _setQuery('');
                },
              ),
      ),
      const SizedBox(height: OSpace.m),
      ArtifactFilterBar(
        filters: _filters,
        summary: _sizeSummary(items),
        sessions: sessions,
        onChanged: (next) => setState(() => _filters = next),
      ),
      const SizedBox(height: OSpace.l),
      Row(
        children: [
          Expanded(
            child: OSectionHeader(
              label: _filtering ? 'Matching artifacts' : 'Recent artifacts',
              padding: EdgeInsets.zero,
            ),
          ),
          Text(
            '${items.length} ${items.length == 1 ? 'item' : 'items'}',
            style: OType.caption.copyWith(color: c.accent),
          ),
        ],
      ),
      const SizedBox(height: OSpace.m),
    ];
    final bodyCount = items.isEmpty ? 1 : rowCount;

    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(
        OSpace.screen,
        OSpace.s,
        OSpace.screen,
        OSpace.huge + OSpace.huge,
      ),
      itemCount: header.length + bodyCount + 2,
      itemBuilder: (context, index) {
        if (index < header.length) return header[index];
        final body = index - header.length;
        if (body < bodyCount) {
          if (items.isEmpty) return _emptyResults(c);
          final left = items[body * 2];
          final rightIndex = body * 2 + 1;
          final right = rightIndex < items.length ? items[rightIndex] : null;
          final row = IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(child: _card(context, c, left)),
                const SizedBox(width: OSpace.m),
                Expanded(
                  child: right == null
                      ? const SizedBox.shrink()
                      : _card(context, c, right),
                ),
              ],
            ),
          );
          // Only the first screenful animates; lazily-built rows must not
          // each schedule an entrance timer.
          if (body >= 8) return row;
          final delay = OMotion.stagger * body;
          return OFadeSlide(
            delay: delay > const Duration(milliseconds: 400)
                ? const Duration(milliseconds: 400)
                : delay,
            child: row,
          );
        }
        if (body == bodyCount) return const SizedBox(height: OSpace.xl);
        return _callout(c);
      },
    );
  }

  Widget _emptyResults(OColors c) {
    if (!_filtering) {
      return OEmptyState(
        compact: true,
        icon: Icons.auto_awesome_rounded,
        title: 'No artifacts yet',
        message:
            'Files from every chat and every upload show up here. '
            'Deleting an artifact frees its storage right away.',
        action: widget.onNewArtifact == null
            ? null
            : OButton(
                label: 'New artifact',
                icon: Icons.add_rounded,
                onPressed: widget.onNewArtifact,
              ),
      );
    }
    return OEmptyState(
      compact: true,
      icon: Icons.search_off_rounded,
      title: 'No matches',
      message:
          'No artifacts match these filters. Try another search '
          'or clear them.',
      action: OButton(
        label: 'Clear filters',
        variant: OButtonVariant.secondary,
        onPressed: _clearFilters,
      ),
    );
  }

  Widget _librarySummary(OColors c) {
    final all = widget.data.artifacts;
    final total = widget.data.totalSizeLabel ?? _totalSize(all);
    final count = '${all.length} ${all.length == 1 ? 'file' : 'files'}';
    return OCard(
      padding: const EdgeInsets.all(OSpace.m),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: c.accentSoft,
              borderRadius: BorderRadius.circular(ORadius.m),
            ),
            child: Icon(Icons.folder_copy_outlined, size: 20, color: c.accent),
          ),
          const SizedBox(width: OSpace.m),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Your lifetime library',
                  style: OType.bodyStrong.copyWith(color: c.text),
                ),
                const SizedBox(height: 2),
                Text(
                  total.isEmpty ? count : '$count · $total stored',
                  style: OType.bodySm.copyWith(color: c.textMuted),
                ),
                const SizedBox(height: OSpace.xs),
                Text(
                  'Every chat file and upload, in one place. Studio drafts '
                  'stay in Studio.',
                  style: OType.caption.copyWith(color: c.textMuted),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  V2ArtifactSizeSummary _sizeSummary(List<V2ArtifactItem> visible) {
    final all = widget.data.artifacts;
    final bytes = all.fold<int>(0, (sum, item) => sum + item.sizeBytes);
    return V2ArtifactSizeSummary(
      totalBytes: bytes,
      totalCount: all.length,
      visibleCount: visible.length,
      sizeLabel: widget.data.totalSizeLabel,
    );
  }

  Widget _card(BuildContext context, OColors c, V2ArtifactItem item) {
    final ext = _extension(item.name);
    final sourceLabel = item.source == V2ArtifactSource.uploaded
        ? 'Uploaded'
        : 'Generated';
    return OCard(
      padding: EdgeInsets.zero,
      onTap: () => _open(item),
      semanticLabel:
          '${item.name}, $sourceLabel, ${_filterLabel(item.kind)}, '
          '${item.sizeLabel}, ${_dateLabel(item.createdAt, widget.data.now ?? DateTime.now())}'
          '${item.sessionTitle.isEmpty ? '' : ', from ${item.sessionTitle}'}',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AspectRatio(
            aspectRatio: 4 / 3,
            child: ClipRRect(
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(ORadius.l),
              ),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  _thumb(context, c, item),
                  if (item.live || item.badge != null)
                    Positioned(
                      top: OSpace.s,
                      left: OSpace.s,
                      right: OSpace.s,
                      child: Wrap(
                        spacing: OSpace.xs,
                        runSpacing: OSpace.xs,
                        children: [
                          if (item.live)
                            _previewPill(
                              c,
                              label: 'Live',
                              icon: null,
                              dotColor: c.success,
                            ),
                          if (item.badge != null)
                            _previewPill(
                              c,
                              label: item.badge!,
                              icon: _filterIcon(item.kind),
                              dotColor: null,
                            ),
                        ],
                      ),
                    ),
                  if (item.badge == null && !item.live)
                    Positioned(
                      bottom: OSpace.s,
                      right: OSpace.s,
                      child: _extensionPill(c, ext),
                    ),
                ],
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(
              OSpace.m,
              0,
              OSpace.xs,
              OSpace.m,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        item.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: OType.bodySm.copyWith(
                          color: c.text,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    OIconButton(
                      icon: Icons.more_vert_rounded,
                      semanticLabel: 'More options for ${item.name}',
                      size: 18,
                      onPressed: () => _openMenu(item),
                    ),
                  ],
                ),
                Row(
                  children: [
                    Icon(_filterIcon(item.kind), size: 14, color: c.accent),
                    const SizedBox(width: OSpace.xs),
                    Expanded(
                      child: Text(
                        '${item.source == V2ArtifactSource.uploaded ? 'Uploaded · ' : ''}'
                        '$ext · ${item.sizeLabel} · '
                        '${_dateLabel(item.createdAt, widget.data.now ?? DateTime.now())}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: OType.caption.copyWith(color: c.textMuted),
                      ),
                    ),
                  ],
                ),
                if (item.sessionTitle.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Row(
                    children: [
                      Icon(
                        Icons.chat_bubble_outline_rounded,
                        size: 13,
                        color: c.textFaint,
                      ),
                      const SizedBox(width: OSpace.xs),
                      Expanded(
                        child: Text(
                          'From ${item.sessionTitle}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: OType.caption.copyWith(color: c.textMuted),
                        ),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Opening a card always goes somewhere real: the host callback when it has
  /// one, otherwise the library's own detail route built from the item.
  void _open(V2ArtifactItem item) {
    final handler = widget.onArtifactTap;
    if (handler != null) {
      handler(item);
      return;
    }
    _openDetail(item);
  }

  void _openDetail(V2ArtifactItem item) {
    final now = widget.data.now ?? DateTime.now();
    final link = _link(item);
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ArtifactDetailPage(
          data: V2ArtifactDetailData(
            name: item.name,
            typeLabel: _filterLabel(item.kind),
            sizeLabel: item.sizeLabel,
            createdLabel: 'Created ${_dateLabel(item.createdAt, now).toLowerCase()}',
            sourceChatTitle: item.sessionTitle,
            previewKind: _previewKindFor(item),
            previewCodeFile: item.name,
            thumbnail: item.thumbnail,
            downloadUrl: link ?? '',
            shareUrl: link ?? '',
            details: <V2ArtifactDetailRow>[
              V2ArtifactDetailRow(
                label: 'Type',
                value: _filterLabel(item.kind),
              ),
              V2ArtifactDetailRow(label: 'Size', value: item.sizeLabel),
              V2ArtifactDetailRow(
                label: 'Added',
                value: _dateLabel(item.createdAt, now),
              ),
              V2ArtifactDetailRow(
                label: 'Source',
                value: item.source == V2ArtifactSource.uploaded
                    ? 'Uploaded'
                    : 'Made by Ovid',
              ),
              if (item.sessionTitle.isNotEmpty)
                V2ArtifactDetailRow(label: 'Chat', value: item.sessionTitle),
            ],
          ),
        ),
      ),
    );
  }

  V2ArtifactPreviewKind _previewKindFor(V2ArtifactItem item) =>
      switch (item.kind) {
        V2ArtifactKind.image => V2ArtifactPreviewKind.image,
        V2ArtifactKind.code => V2ArtifactPreviewKind.code,
        V2ArtifactKind.document => _isPage(item)
            ? V2ArtifactPreviewKind.code
            : V2ArtifactPreviewKind.document,
        V2ArtifactKind.data => V2ArtifactPreviewKind.data,
      };

  String? _link(V2ArtifactItem item) {
    final url = item.url;
    if (url == null || url.isEmpty) return null;
    return url;
  }

  /// The card menu. A host menu wins; otherwise the library offers only
  /// actions it can really perform with the item it was given.
  Future<void> _openMenu(V2ArtifactItem item) async {
    final handler = widget.onArtifactMenu;
    if (handler != null) {
      handler(item);
      return;
    }
    final link = _link(item);
    final action = await showOSheet<String>(
      context,
      title: item.name,
      builder: (sheetContext) => ListView(
        shrinkWrap: true,
        padding: const EdgeInsets.only(bottom: OSpace.l),
        children: [
          OListRow(
            title: 'Open',
            icon: Icons.open_in_new_rounded,
            showChevron: false,
            onTap: () => Navigator.of(sheetContext).pop('open'),
          ),
          OListRow(
            title: 'Copy file name',
            icon: Icons.copy_rounded,
            showChevron: false,
            onTap: () => Navigator.of(sheetContext).pop('copy-name'),
          ),
          if (link != null) ...[
            OListRow(
              title: 'Copy link',
              icon: Icons.link_rounded,
              showChevron: false,
              onTap: () => Navigator.of(sheetContext).pop('copy-link'),
            ),
            OListRow(
              title: 'Download',
              icon: Icons.download_rounded,
              showChevron: false,
              onTap: () => Navigator.of(sheetContext).pop('download'),
            ),
          ],
        ],
      ),
    );
    if (!mounted || action == null) return;
    switch (action) {
      case 'open':
        _open(item);
      case 'copy-name':
        {
          final copied = await v2CopyArtifactText(item.name);
          if (!mounted) return;
          _notify(
            copied ? 'File name copied' : 'Could not copy the file name',
          );
        }
      case 'copy-link':
        {
          if (link == null) return;
          final copied = await v2CopyArtifactText(link);
          if (!mounted) return;
          _notify(copied ? 'Link copied' : 'Could not copy the link');
        }
      case 'download':
        {
          if (link == null) return;
          await v2SaveTranscriptLink(
            context,
            link,
            suggestedName: item.name,
          );
        }
    }
  }

  void _notify(String message) {
    if (!mounted) return;
    ScaffoldMessenger.maybeOf(context)
      ?..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Widget _thumb(BuildContext context, OColors c, V2ArtifactItem item) {
    // Decode at roughly the width the card is drawn at instead of full
    // resolution: a 12 MP upload no longer decodes 48 MB into memory.
    final cardWidth =
        (MediaQuery.sizeOf(context).width - OSpace.screen * 2 - OSpace.m) / 2;
    final cacheWidth =
        (cardWidth * MediaQuery.devicePixelRatioOf(context)).round();
    final thumbnail = item.thumbnail;
    if (thumbnail != null) {
      return Image(
        image: ResizeImage.resizeIfNeeded(cacheWidth, null, thumbnail),
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) => _mockThumb(c, item.kind),
      );
    }
    final link = _link(item);
    if (item.kind == V2ArtifactKind.image && link != null) {
      return Image.network(
        link,
        cacheWidth: cacheWidth,
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) => _mockThumb(c, item.kind),
      );
    }
    return _mockThumb(c, item.kind);
  }

  Widget _mockThumb(OColors c, V2ArtifactKind kind) {
    return Container(
      color: c.codeBg,
      child: switch (kind) {
        V2ArtifactKind.image => Center(
          child: Container(
            width: 54,
            height: 54,
            decoration: BoxDecoration(
              color: c.accentSoft,
              borderRadius: BorderRadius.circular(ORadius.m),
              border: Border.all(color: c.accentFill.withValues(alpha: 0.35)),
            ),
            child: Icon(Icons.landscape_rounded, size: 28, color: c.accent),
          ),
        ),
        V2ArtifactKind.document => Padding(
          padding: const EdgeInsets.all(OSpace.m),
          child: Container(
            padding: const EdgeInsets.all(OSpace.s),
            decoration: BoxDecoration(
              color: c.surface,
              borderRadius: BorderRadius.circular(ORadius.s),
              border: Border.all(color: c.hairline),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 40,
                  height: 5,
                  decoration: BoxDecoration(
                    color: c.accent,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                const SizedBox(height: OSpace.s),
                _line(c.surfaceRaised, 1),
                const SizedBox(height: 5),
                _line(c.surfaceRaised, 0.86),
                const SizedBox(height: 5),
                _line(c.surfaceRaised, 0.68),
                const Spacer(),
                Icon(Icons.description_rounded, size: 18, color: c.textFaint),
              ],
            ),
          ),
        ),
        V2ArtifactKind.code => Padding(
          padding: const EdgeInsets.all(OSpace.m),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _codeLine(c, 0.52, accent: true),
              const SizedBox(height: 6),
              _codeLine(c, 0.8),
              const SizedBox(height: 6),
              _codeLine(c, 0.66),
              const SizedBox(height: 6),
              _codeLine(c, 0.4, accent: true),
            ],
          ),
        ),
        V2ArtifactKind.data => Padding(
          padding: const EdgeInsets.fromLTRB(
            OSpace.l,
            OSpace.l,
            OSpace.l,
            OSpace.m,
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              for (final (height, color) in [
                (26.0, c.accentFill.withValues(alpha: 0.45)),
                (44.0, c.accentFill),
                (34.0, c.success.withValues(alpha: 0.7)),
                (56.0, c.accentFill),
                (40.0, c.accentFill.withValues(alpha: 0.45)),
              ]) ...[
                Expanded(
                  child: Container(
                    height: height,
                    decoration: BoxDecoration(
                      color: color,
                      borderRadius: BorderRadius.circular(ORadius.s),
                    ),
                  ),
                ),
                const SizedBox(width: OSpace.xs),
              ],
            ],
          ),
        ),
      },
    );
  }

  Widget _line(Color color, double widthFactor) {
    return FractionallySizedBox(
      widthFactor: widthFactor,
      child: Container(
        height: 4,
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(2),
        ),
      ),
    );
  }

  Widget _codeLine(OColors c, double widthFactor, {bool accent = false}) {
    return FractionallySizedBox(
      widthFactor: widthFactor,
      child: Container(
        height: 6,
        decoration: BoxDecoration(
          color: accent
              ? c.accentFill.withValues(alpha: 0.65)
              : c.surfaceRaised,
          borderRadius: BorderRadius.circular(3),
        ),
      ),
    );
  }

  Widget _previewPill(
    OColors c, {
    required String label,
    required IconData? icon,
    required Color? dotColor,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: OSpace.s,
        vertical: OSpace.xs,
      ),
      decoration: BoxDecoration(
        color: c.surfaceRaised,
        borderRadius: BorderRadius.circular(ORadius.pill),
        border: Border.all(color: c.hairline),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (dotColor != null)
            Container(
              width: 6,
              height: 6,
              decoration: BoxDecoration(
                color: dotColor,
                shape: BoxShape.circle,
              ),
            )
          else if (icon != null)
            Icon(icon, size: 11, color: c.textMuted),
          const SizedBox(width: OSpace.xs),
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: OType.overline.copyWith(color: c.text),
            ),
          ),
        ],
      ),
    );
  }

  Widget _extensionPill(OColors c, String ext) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: OSpace.s,
        vertical: OSpace.xs,
      ),
      decoration: BoxDecoration(
        color: c.surfaceRaised,
        borderRadius: BorderRadius.circular(ORadius.pill),
        border: Border.all(color: c.hairline),
      ),
      child: Text(ext, style: OType.overline.copyWith(color: c.textMuted)),
    );
  }

  Widget _callout(OColors c) {
    return OCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
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
                  children: [
                    Text(
                      'Every output, in one library',
                      style: OType.bodyStrong.copyWith(color: c.text),
                    ),
                    const SizedBox(height: OSpace.xs),
                    Text(
                      'Files from every chat and every upload live here. '
                      'Studio drafts stay in Studio. Deleting an artifact '
                      'frees its storage right away.',
                      style: OType.bodySm.copyWith(color: c.textMuted),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: OSpace.m),
          if (widget.onSeeIdeas != null)
            OButton(
              label: 'See what Ovid can make',
              variant: OButtonVariant.ghost,
              icon: Icons.arrow_forward_rounded,
              onPressed: widget.onSeeIdeas,
            ),
        ],
      ),
    );
  }

  String _totalSize(List<V2ArtifactItem> items) {
    final bytes = items.fold<int>(0, (sum, item) => sum + item.sizeBytes);
    if (bytes <= 0) return '';
    return _formatBytes(bytes);
  }

  String _formatBytes(int bytes) {
    const kilo = 1024;
    if (bytes < kilo) return '$bytes B';
    final kb = bytes / kilo;
    if (kb < kilo) return '${kb.toStringAsFixed(kb < 10 ? 1 : 0)} KB';
    final mb = kb / kilo;
    if (mb < kilo) return '${mb.toStringAsFixed(mb < 10 ? 1 : 0)} MB';
    final gb = mb / kilo;
    return '${gb.toStringAsFixed(1)} GB';
  }

  String _filterLabel(V2ArtifactKind? kind) => switch (kind) {
    null => 'All',
    V2ArtifactKind.image => 'Images',
    V2ArtifactKind.document => 'Documents',
    V2ArtifactKind.code => 'Code',
    V2ArtifactKind.data => 'Data',
  };

  IconData _filterIcon(V2ArtifactKind kind) => switch (kind) {
    V2ArtifactKind.image => Icons.image_rounded,
    V2ArtifactKind.document => Icons.description_rounded,
    V2ArtifactKind.code => Icons.code_rounded,
    V2ArtifactKind.data => Icons.table_chart_rounded,
  };

  String _extension(String name) {
    final dot = name.lastIndexOf('.');
    if (dot < 0 || dot == name.length - 1) return 'FILE';
    return name.substring(dot + 1).toUpperCase();
  }

  String _dateLabel(DateTime createdAt, DateTime now) {
    final local = createdAt.toLocal();
    final today = DateTime(now.year, now.month, now.day);
    final day = DateTime(local.year, local.month, local.day);
    final days = today.difference(day).inDays;
    if (days <= 0) return 'Today';
    if (days == 1) return 'Yesterday';
    if (days < 7) return '${days}d ago';
    const months = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    return '${months[local.month - 1]} ${local.day}';
  }
}
