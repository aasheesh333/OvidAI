import 'package:flutter/material.dart';

import '../../design/o_components.dart';
import '../../design/o_motion.dart';
import '../../design/o_screen.dart';
import '../../design/o_tokens.dart';
import '../chat/transcript_actions.dart';
import 'artifact_actions.dart';
import 'artifact_preview.dart';

// TODO(l10n): move user-facing copy to the ARB files in the next wave.

enum V2ArtifactDetailStatus { loading, content, error, missing }

enum V2ArtifactDetailTab { preview, details }

enum V2ArtifactDetailTone { neutral, success }

/// What the lightweight preview shows. Documents and data are never rendered
/// in-app; they show metadata and an "Open externally" action instead.
enum V2ArtifactPreviewKind { image, code, document, data }

/// Code previews render at most this many lines, so opening a huge file never
/// stalls the UI. The rest stays one "Open externally" tap away.
///
/// The preview widget owns the cap; the page keeps the name because wiring and
/// tests refer to it.
const int v2ArtifactCodeLineCap = v2ArtifactPreviewCodeLineCap;

@immutable
class V2ArtifactDetailRow {
  const V2ArtifactDetailRow({
    required this.label,
    required this.value,
    this.tone = V2ArtifactDetailTone.neutral,
  });

  final String label;
  final String value;
  final V2ArtifactDetailTone tone;
}

@immutable
class V2ArtifactDetailData {
  const V2ArtifactDetailData({
    this.status = V2ArtifactDetailStatus.content,
    this.name = '',
    this.typeLabel = '',
    this.sizeLabel = '',
    this.createdLabel = '',
    this.versionLabel = 'Ready',
    this.sourceChatTitle = '',
    V2ArtifactPreviewKind? previewKind,
    this.previewHeadline = '',
    this.previewCodeFile = '',
    this.previewCode = '',
    this.previewTotalLines,
    this.documentText = '',
    this.details = const <V2ArtifactDetailRow>[],
    this.thumbnail,
    this.downloadUrl = '',
    this.shareUrl = '',
    this.openUrl = '',
    this.errorMessage =
        'We could not open this artifact. Check your connection and try again.',
  }) : previewKindOverride = previewKind;

  final V2ArtifactDetailStatus status;
  final String name;
  final String typeLabel;
  final String sizeLabel;
  final String createdLabel;
  final String versionLabel;
  final String sourceChatTitle;
  final V2ArtifactPreviewKind? previewKindOverride;

  /// What the preview shows. When the wiring layer does not say, the file name
  /// decides, so a `.png` is never previewed as an image-less document and a
  /// `.ts` never as a blank image.
  V2ArtifactPreviewKind get previewKind =>
      previewKindOverride ?? v2ArtifactPreviewKindForName(name);
  final String previewHeadline;
  final String previewCodeFile;
  final String previewCode;

  /// Total lines in the real file when [previewCode] only carries the head of
  /// it. Defaults to the number of lines in [previewCode].
  final int? previewTotalLines;

  /// The document's real text, when the wiring layer could read it.
  final String documentText;
  final List<V2ArtifactDetailRow> details;
  final ImageProvider? thumbnail;

  /// A fresh, signed URL the Download button really fetches. Empty means the
  /// library does not have one, so Download is not offered.
  final String downloadUrl;

  /// A link the share action can really copy. Empty means no share action.
  final String shareUrl;

  /// Where "Open externally" goes when no handler is injected. Defaults to the
  /// download URL.
  final String openUrl;
  final String errorMessage;

  /// The URL the external action uses: explicit [openUrl], else the download
  /// URL. Empty when nothing can be opened.
  String get resolvedOpenUrl => openUrl.isNotEmpty ? openUrl : downloadUrl;

  bool get isCode => previewKind == V2ArtifactPreviewKind.code;
}

/// The preview family implied by a file name.
V2ArtifactPreviewKind v2ArtifactPreviewKindForName(String name) {
  final dot = name.lastIndexOf('.');
  if (dot < 0 || dot == name.length - 1) return V2ArtifactPreviewKind.document;
  return switch (name.substring(dot + 1).toLowerCase()) {
    'png' ||
    'jpg' ||
    'jpeg' ||
    'gif' ||
    'webp' ||
    'bmp' ||
    'svg' ||
    'avif' ||
    'heic' => V2ArtifactPreviewKind.image,
    'dart' ||
    'js' ||
    'mjs' ||
    'cjs' ||
    'ts' ||
    'tsx' ||
    'jsx' ||
    'py' ||
    'rb' ||
    'go' ||
    'rs' ||
    'java' ||
    'kt' ||
    'kts' ||
    'swift' ||
    'c' ||
    'h' ||
    'cc' ||
    'cpp' ||
    'cs' ||
    'php' ||
    'sh' ||
    'bash' ||
    'zsh' ||
    'sql' ||
    'html' ||
    'htm' ||
    'css' ||
    'scss' ||
    'less' ||
    'json' ||
    'yaml' ||
    'yml' ||
    'toml' ||
    'xml' ||
    'ini' ||
    'gradle' => V2ArtifactPreviewKind.code,
    'csv' || 'tsv' || 'xls' || 'xlsx' => V2ArtifactPreviewKind.data,
    _ => V2ArtifactPreviewKind.document,
  };
}

/// A single artifact with its lightweight preview, origin chat, share/delete
/// actions and technical details.
///
/// The preview is [V2ArtifactPreview]: no WebView, no document renderer. Images
/// are drawn with [Image], code stops at [v2ArtifactCodeLineCap] lines, and
/// documents show metadata with an "Open externally" action.
class ArtifactDetailPage extends StatefulWidget {
  const ArtifactDetailPage({
    super.key,
    required this.data,
    this.onDownload,
    this.onShareLink,
    this.onOpenInStudio,
    this.onOpenExternally,
    this.onOpenChat,
    this.onDelete,
    this.onMore,
    this.onRetry,
    this.onBackToArtifacts,
  });

  final V2ArtifactDetailData data;
  final VoidCallback? onDownload;
  final VoidCallback? onShareLink;
  final VoidCallback? onOpenInStudio;
  final VoidCallback? onOpenExternally;
  final VoidCallback? onOpenChat;
  final VoidCallback? onDelete;
  final VoidCallback? onMore;
  final VoidCallback? onRetry;
  final VoidCallback? onBackToArtifacts;

  @override
  State<ArtifactDetailPage> createState() => _ArtifactDetailPageState();
}

class _ArtifactDetailPageState extends State<ArtifactDetailPage> {
  bool _downloading = false;

  /// Download is only offered when it can really happen: a host handler, or a
  /// signed URL the page fetches and writes to disk itself.
  bool get _canDownload =>
      widget.onDownload != null || widget.data.downloadUrl.isNotEmpty;

  /// Share is only offered when it can really happen: a host handler, or a
  /// link the page can really put on the clipboard.
  bool get _canShare =>
      widget.onShareLink != null || widget.data.shareUrl.isNotEmpty;

  bool get _canOpen =>
      widget.onOpenExternally != null || widget.data.resolvedOpenUrl.isNotEmpty;

  bool get _canStudio => widget.data.isCode && widget.onOpenInStudio != null;

  bool get _canDelete => widget.onDelete != null;

  bool get _hasMenu =>
      widget.onMore != null ||
      _canDownload ||
      _canShare ||
      _canStudio ||
      _canDelete;

  Future<void> _download() async {
    final handler = widget.onDownload;
    if (handler != null) {
      handler();
      return;
    }
    final url = widget.data.downloadUrl;
    if (url.isEmpty || _downloading) return;
    setState(() => _downloading = true);
    try {
      await v2SaveTranscriptLink(context, url, suggestedName: widget.data.name);
    } finally {
      if (mounted) setState(() => _downloading = false);
    }
  }

  Future<void> _share() async {
    final handler = widget.onShareLink;
    if (handler != null) {
      // The host owns the share result; this screen must not claim the link
      // was copied when the host may have opened a share sheet instead.
      handler();
      return;
    }
    final link = widget.data.shareUrl;
    if (link.isEmpty) return;
    final copied = await v2CopyArtifactText(link);
    if (!mounted) return;
    _notify(copied ? 'Link copied' : 'Could not copy the link');
  }

  Future<void> _open() async {
    final handler = widget.onOpenExternally;
    if (handler != null) {
      handler();
      return;
    }
    final url = widget.data.resolvedOpenUrl;
    if (url.isEmpty) return;
    await v2OpenTranscriptLink(context, url);
  }

  void _notify(String message) {
    if (!mounted) return;
    ScaffoldMessenger.maybeOf(context)
      ?..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _openMenu() async {
    final host = widget.onMore;
    if (host != null) {
      host();
      return;
    }
    final action = await showOSheet<String>(
      context,
      title: widget.data.name.isEmpty ? 'Artifact' : widget.data.name,
      builder: (sheetContext) => ListView(
        shrinkWrap: true,
        padding: const EdgeInsets.only(bottom: OSpace.l),
        children: [
          if (_canDownload)
            OListRow(
              title: 'Download',
              icon: Icons.download_rounded,
              showChevron: false,
              onTap: () => Navigator.of(sheetContext).pop('download'),
            ),
          if (_canShare)
            OListRow(
              title: widget.onShareLink != null ? 'Share link' : 'Copy link',
              icon: Icons.link_rounded,
              showChevron: false,
              onTap: () => Navigator.of(sheetContext).pop('share'),
            ),
          if (_canStudio)
            OListRow(
              title: 'Open in Studio',
              icon: Icons.terminal_rounded,
              showChevron: false,
              onTap: () => Navigator.of(sheetContext).pop('studio'),
            ),
          if (_canDelete)
            OListRow(
              title: 'Delete',
              icon: Icons.delete_outline_rounded,
              danger: true,
              showChevron: false,
              onTap: () => Navigator.of(sheetContext).pop('delete'),
            ),
        ],
      ),
    );
    if (!mounted || action == null) return;
    switch (action) {
      case 'download':
        await _download();
      case 'share':
        await _share();
      case 'studio':
        widget.onOpenInStudio?.call();
      case 'delete':
        await _confirmDelete();
    }
  }

  Future<void> _confirmDelete() async {
    final data = widget.data;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        final c = OColors.of(dialogContext);
        final frees = data.sizeLabel.isEmpty
            ? 'This frees its storage'
            : 'This frees ${data.sizeLabel} of storage';
        return AlertDialog(
          backgroundColor: c.surface,
          title: Text(
            'Delete this artifact?',
            style: OType.h2.copyWith(color: c.text),
          ),
          content: Text(
            'This removes ${data.name} from your library. '
            '$frees. This cannot be undone.',
            style: OType.bodySm.copyWith(color: c.textMuted),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              style: TextButton.styleFrom(foregroundColor: c.danger),
              child: const Text('Delete'),
            ),
          ],
        );
      },
    );
    if (confirmed == true) widget.onDelete?.call();
  }

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    final data = widget.data;
    return OScreen(
      title: data.name.isEmpty ? 'Artifact' : data.name,
      showBack: true,
      actions: [
        if (_hasMenu)
          OIconButton(
            icon: Icons.more_vert_rounded,
            semanticLabel: 'More options',
            onPressed: _openMenu,
          ),
      ],
      child: OFadeSlide(
        child: OAnimatedSwap(
          child: switch (data.status) {
            V2ArtifactDetailStatus.loading => const OSkeletonList(rows: 5),
            V2ArtifactDetailStatus.error => OErrorState(
              message: data.errorMessage,
              onRetry: widget.onRetry,
            ),
            V2ArtifactDetailStatus.missing => OEmptyState(
              icon: Icons.broken_image_outlined,
              title: 'This artifact is gone',
              message: 'It may have been deleted.',
              action: widget.onBackToArtifacts == null
                  ? null
                  : OButton(
                      label: 'Back',
                      icon: Icons.arrow_back_rounded,
                      onPressed: widget.onBackToArtifacts,
                    ),
            ),
            V2ArtifactDetailStatus.content => _content(c),
          },
        ),
      ),
    );
  }

  Widget _content(OColors c) {
    final data = widget.data;
    final rows = _metadataRows(data);
    return ListView(
      padding: const EdgeInsets.only(top: OSpace.s, bottom: OSpace.xxl),
      children: [
        _preview(data),
        if (_canOpen) ...[
          const SizedBox(height: OSpace.m),
          OButton(
            label: 'Open',
            icon: Icons.open_in_new_rounded,
            expand: true,
            onPressed: _open,
          ),
        ],
        if (rows.isNotEmpty) ...[
          const SizedBox(height: OSpace.m),
          _metadata(c, rows),
        ],
      ],
    );
  }

  /// Three facts at most: the detail page shows the file, then the essentials.
  List<V2ArtifactDetailRow> _metadataRows(V2ArtifactDetailData data) {
    if (data.details.isNotEmpty) return data.details.take(3).toList();
    return [
      if (data.typeLabel.isNotEmpty)
        V2ArtifactDetailRow(label: 'Type', value: data.typeLabel),
      if (data.sizeLabel.isNotEmpty)
        V2ArtifactDetailRow(label: 'Size', value: data.sizeLabel),
      if (data.createdLabel.isNotEmpty)
        V2ArtifactDetailRow(label: 'Added', value: data.createdLabel),
    ];
  }

  Widget _preview(V2ArtifactDetailData data) {
    return V2ArtifactPreview(
      showName: false,
      showHeader: false,
      showFooter: false,
      data: V2ArtifactPreviewData(
        name: data.name,
        type: _previewType(data.previewKind),
        typeLabel: data.typeLabel,
        sizeLabel: data.sizeLabel,
        image: data.thumbnail,
        // With no inline thumbnail, an image still previews from the signed
        // link the page already holds instead of a placeholder.
        imageUrl: data.previewKind == V2ArtifactPreviewKind.image
            ? data.resolvedOpenUrl
            : '',
        code: data.previewCode,
        codeFile: data.previewCodeFile == data.name ? '' : data.previewCodeFile,
        codeTotalLines: data.previewTotalLines,
        documentText: data.documentText,
      ),
    );
  }

  V2ArtifactPreviewType _previewType(V2ArtifactPreviewKind kind) =>
      switch (kind) {
        V2ArtifactPreviewKind.image => V2ArtifactPreviewType.image,
        V2ArtifactPreviewKind.code => V2ArtifactPreviewType.code,
        V2ArtifactPreviewKind.document ||
        V2ArtifactPreviewKind.data => V2ArtifactPreviewType.document,
      };

  Widget _metadata(OColors c, List<V2ArtifactDetailRow> rows) {
    return OCard(
      padding: EdgeInsets.zero,
      child: Column(
        children: [
          for (var i = 0; i < rows.length; i++) ...[
            if (i > 0) Divider(height: 1, color: c.hairline),
            Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: OSpace.l,
                vertical: OSpace.m,
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    flex: 2,
                    child: Text(
                      rows[i].label,
                      style: OType.bodySm.copyWith(color: c.textMuted),
                    ),
                  ),
                  const SizedBox(width: OSpace.m),
                  Expanded(
                    flex: 3,
                    child: Text(
                      rows[i].value,
                      textAlign: TextAlign.end,
                      style: OType.bodySm.copyWith(
                        color: rows[i].tone == V2ArtifactDetailTone.success
                            ? c.success
                            : c.text,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}
