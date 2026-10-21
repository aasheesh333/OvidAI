import 'dart:async';

import 'package:flutter/material.dart';

import '../../design/o_components.dart';
import '../../design/o_motion.dart';
import '../../design/o_tokens.dart';
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
    this.sourcePrompt = '',
    this.previewKind = V2ArtifactPreviewKind.image,
    this.previewHeadline = '',
    this.previewSubtitle = '',
    this.previewTag = '',
    this.previewCodeFile = '',
    this.previewCode = '',
    this.previewTotalLines,
    this.previewNote =
        'This preview is read-only. Open the file to make changes.',
    this.details = const <V2ArtifactDetailRow>[],
    this.thumbnail,
    this.errorMessage =
        'We could not open this artifact. Check your connection and try again.',
  });

  final V2ArtifactDetailStatus status;
  final String name;
  final String typeLabel;
  final String sizeLabel;
  final String createdLabel;
  final String versionLabel;
  final String sourceChatTitle;
  final String sourcePrompt;
  final V2ArtifactPreviewKind previewKind;
  final String previewHeadline;
  final String previewSubtitle;
  final String previewTag;
  final String previewCodeFile;
  final String previewCode;

  /// Total lines in the real file when [previewCode] only carries the head of
  /// it. Defaults to the number of lines in [previewCode].
  final int? previewTotalLines;
  final String previewNote;
  final List<V2ArtifactDetailRow> details;
  final ImageProvider? thumbnail;
  final String errorMessage;

  bool get isCode => previewKind == V2ArtifactPreviewKind.code;
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
  V2ArtifactDetailTab _tab = V2ArtifactDetailTab.preview;
  bool _shareCopied = false;
  Timer? _shareResetTimer;

  @override
  void dispose() {
    _shareResetTimer?.cancel();
    super.dispose();
  }

  void _share() {
    widget.onShareLink?.call();
    if (widget.onShareLink == null) return;
    setState(() => _shareCopied = true);
    _shareResetTimer?.cancel();
    _shareResetTimer = Timer(const Duration(seconds: 2), () {
      if (mounted) setState(() => _shareCopied = false);
    });
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
    return OScaffold(
      appBar: OAppBar(
        title: 'Artifact detail',
        actions: [
          OIconButton(
            icon: Icons.more_vert_rounded,
            semanticLabel: 'More options',
            onPressed: widget.onMore,
          ),
        ],
      ),
      body: OFadeSlide(
        child: OAnimatedSwap(
          child: switch (widget.data.status) {
            V2ArtifactDetailStatus.loading => const OSkeletonList(rows: 5),
            V2ArtifactDetailStatus.error => OErrorState(
              message: widget.data.errorMessage,
              onRetry: widget.onRetry,
            ),
            V2ArtifactDetailStatus.missing => OEmptyState(
              icon: Icons.broken_image_outlined,
              title: 'This artifact is gone',
              message:
                  'It may have been deleted or moved. Your other artifacts are safe.',
              action: OButton(
                label: 'Back to artifacts',
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
    return ListView(
      padding: const EdgeInsets.fromLTRB(
        OSpace.screen,
        OSpace.s,
        OSpace.screen,
        OSpace.xxl,
      ),
      children: [
        _summary(c),
        const SizedBox(height: OSpace.m),
        _sourceChat(c),
        const SizedBox(height: OSpace.m),
        _tabs(c),
        const SizedBox(height: OSpace.m),
        _actions(),
        const SizedBox(height: OSpace.m),
        OAnimatedSwap(
          child: _tab == V2ArtifactDetailTab.preview
              ? _preview(data)
              : _detailsTab(c, data),
        ),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // Preview — delegated to the shared cheap preview widget.
  // ---------------------------------------------------------------------------

  Widget _preview(V2ArtifactDetailData data) {
    return V2ArtifactPreview(
      data: V2ArtifactPreviewData(
        name: data.name,
        type: _previewType(data.previewKind),
        typeLabel: data.typeLabel,
        sizeLabel: data.sizeLabel,
        metadata: [
          for (final row in data.details)
            V2ArtifactPreviewMeta(label: row.label, value: row.value),
        ],
        image: data.thumbnail,
        code: data.previewCode,
        codeFile: data.previewCodeFile,
        codeTotalLines: data.previewTotalLines,
        note: data.previewNote,
      ),
      onOpenExternally: widget.onOpenExternally,
    );
  }

  V2ArtifactPreviewType _previewType(V2ArtifactPreviewKind kind) =>
      switch (kind) {
        V2ArtifactPreviewKind.image => V2ArtifactPreviewType.image,
        V2ArtifactPreviewKind.code => V2ArtifactPreviewType.code,
        V2ArtifactPreviewKind.document ||
        V2ArtifactPreviewKind.data => V2ArtifactPreviewType.document,
      };

  Widget _summary(OColors c) {
    final data = widget.data;
    return OCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: OSpace.s,
            runSpacing: OSpace.xs,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(data.name, style: OType.h2.copyWith(color: c.text)),
              _versionBadge(c),
            ],
          ),
          const SizedBox(height: OSpace.s),
          Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: OSpace.s,
            runSpacing: OSpace.xs,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 7,
                    height: 7,
                    decoration: BoxDecoration(
                      color: c.success,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: OSpace.xs),
                  Flexible(
                    child: Text(
                      data.typeLabel,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: OType.bodySm.copyWith(
                        color: c.text,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                ],
              ),
              Text('•', style: OType.caption.copyWith(color: c.textFaint)),
              Text(
                data.sizeLabel,
                style: OType.bodySm.copyWith(color: c.textMuted),
              ),
              Text('•', style: OType.caption.copyWith(color: c.textFaint)),
              Text(
                data.createdLabel,
                style: OType.bodySm.copyWith(color: c.textMuted),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _versionBadge(OColors c) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
      decoration: BoxDecoration(
        color: c.accentSoft,
        borderRadius: BorderRadius.circular(ORadius.pill),
      ),
      child: Text(
        widget.data.versionLabel,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: OType.caption.copyWith(
          color: c.accent,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  Widget _sourceChat(OColors c) {
    return OCard(
      padding: const EdgeInsets.all(OSpace.m),
      onTap: widget.onOpenChat,
      semanticLabel:
          'Made in chat, ${widget.data.sourceChatTitle}. Open the source chat.',
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: c.accentSoft,
              borderRadius: BorderRadius.circular(ORadius.m),
            ),
            child: Icon(Icons.auto_awesome_rounded, size: 20, color: c.accent),
          ),
          const SizedBox(width: OSpace.m),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Made in chat',
                  style: OType.bodySm.copyWith(
                    color: c.text,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  'Prompted in "${widget.data.sourcePrompt}"',
                  maxLines: 2,
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

  Widget _tabs(OColors c) {
    return Container(
      padding: const EdgeInsets.all(OSpace.xs),
      decoration: BoxDecoration(
        color: c.surfaceAlt,
        borderRadius: BorderRadius.circular(ORadius.m),
        border: Border.all(color: c.hairline),
      ),
      child: Row(
        children: [
          Expanded(
            child: _tabButton(
              c,
              tab: V2ArtifactDetailTab.preview,
              label: 'Preview',
              icon: Icons.visibility_outlined,
            ),
          ),
          const SizedBox(width: OSpace.xs),
          Expanded(
            child: _tabButton(
              c,
              tab: V2ArtifactDetailTab.details,
              label: 'Details',
              icon: Icons.info_outline_rounded,
            ),
          ),
        ],
      ),
    );
  }

  Widget _tabButton(
    OColors c, {
    required V2ArtifactDetailTab tab,
    required String label,
    required IconData icon,
  }) {
    final selected = _tab == tab;
    return Semantics(
      label: label,
      button: true,
      selected: selected,
      child: OPressable(
        onTap: () => setState(() => _tab = tab),
        child: AnimatedContainer(
          duration: OMotion.fast,
          curve: OMotion.standard,
          height: OSpace.touch,
          decoration: BoxDecoration(
            color: selected ? c.surface : Colors.transparent,
            borderRadius: BorderRadius.circular(ORadius.s),
            border: Border.all(
              color: selected ? c.hairline : Colors.transparent,
            ),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 17, color: selected ? c.accent : c.textMuted),
              const SizedBox(width: OSpace.s),
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: OType.label.copyWith(
                    color: selected ? c.text : c.textMuted,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _actions() {
    final canShare = widget.onShareLink != null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        OButton(
          label: 'Download',
          icon: Icons.download_rounded,
          expand: true,
          onPressed: widget.onDownload,
        ),
        const SizedBox(height: OSpace.s),
        Row(
          children: [
            Expanded(
              child: OButton(
                label: _shareCopied ? 'Link copied' : 'Share link',
                icon: _shareCopied ? Icons.check_rounded : Icons.link_rounded,
                variant: OButtonVariant.secondary,
                expand: true,
                onPressed: canShare ? _share : null,
                semanticLabel: _shareCopied
                    ? 'Link copied to clipboard'
                    : 'Share link',
              ),
            ),
            if (widget.data.isCode) ...[
              const SizedBox(width: OSpace.s),
              Expanded(
                child: OButton(
                  label: 'Open in Studio',
                  icon: Icons.terminal_rounded,
                  variant: OButtonVariant.secondary,
                  expand: true,
                  onPressed: widget.onOpenInStudio,
                ),
              ),
            ],
          ],
        ),
        const SizedBox(height: OSpace.s),
        OButton(
          label: 'Delete artifact',
          icon: Icons.delete_outline_rounded,
          variant: OButtonVariant.danger,
          expand: true,
          onPressed: widget.onDelete == null ? null : _confirmDelete,
        ),
      ],
    );
  }

  Widget _detailsTab(OColors c, V2ArtifactDetailData data) {
    return Container(
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(ORadius.l),
        border: Border.all(color: c.hairline),
      ),
      child: Column(
        children: [
          for (var i = 0; i < data.details.length; i++) ...[
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
                    child: Text(
                      data.details[i].label,
                      style: OType.bodySm.copyWith(color: c.textMuted),
                    ),
                  ),
                  const SizedBox(width: OSpace.m),
                  Flexible(
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (data.details[i].tone ==
                            V2ArtifactDetailTone.success) ...[
                          Icon(
                            Icons.check_circle_rounded,
                            size: 16,
                            color: c.success,
                          ),
                          const SizedBox(width: OSpace.xs),
                        ],
                        Flexible(
                          child: Text(
                            data.details[i].value,
                            textAlign: TextAlign.end,
                            style: OType.bodySm.copyWith(
                              color:
                                  data.details[i].tone ==
                                      V2ArtifactDetailTone.success
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
              ),
            ),
          ],
        ],
      ),
    );
  }
}
