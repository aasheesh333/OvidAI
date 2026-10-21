// TODO(l10n): move user-facing copy to the ARB files in the localization pass.
import 'package:flutter/material.dart';

import '../../design/o_components.dart';
import '../../design/o_tokens.dart';

/// How an artifact is previewed. Documents and pages are never rendered in the
/// app: they show metadata or a static thumbnail and an "Open externally"
/// action instead.
enum V2ArtifactPreviewType { image, code, document, page }

/// Code previews draw at most this many lines. The cap is fixed, so opening a
/// very large file can never stall the UI; the rest stays one tap away.
const int v2ArtifactPreviewCodeLineCap = 120;

/// Metadata rows shown for documents and data files. Keeps the card compact
/// even when the detailed view knows more facts than fit here.
const int _metadataRowLimit = 6;

@immutable
class V2ArtifactPreviewMeta {
  const V2ArtifactPreviewMeta({required this.label, required this.value});

  final String label;
  final String value;
}

@immutable
class V2ArtifactPreviewData {
  const V2ArtifactPreviewData({
    required this.name,
    this.type = V2ArtifactPreviewType.document,
    this.typeLabel = '',
    this.sizeLabel = '',
    this.metadata = const <V2ArtifactPreviewMeta>[],
    this.image,
    this.code = '',
    this.codeFile = '',
    this.codeTotalLines,
    this.pageThumbnail,
    this.pageUrl = '',
    this.note = '',
    this.heavy = false,
  });

  final String name;
  final V2ArtifactPreviewType type;
  final String typeLabel;
  final String sizeLabel;

  /// Extra facts for documents and data files (pages, rows, columns, …).
  final List<V2ArtifactPreviewMeta> metadata;

  /// Thumbnail for image artifacts. Decoded with [Image], never a WebView.
  final ImageProvider? image;

  /// The head of a code artifact, plus the full file name and line count when
  /// the wiring layer only sent a snippet.
  final String code;
  final String codeFile;
  final int? codeTotalLines;

  /// Optional *static* page screenshot. When null the preview draws a
  /// placeholder frame. A page is never loaded or executed in the app.
  final ImageProvider? pageThumbnail;
  final String pageUrl;

  /// Overrides the preview note under the stage.
  final String note;

  /// Set by the wiring layer for files that are too large to preview inline.
  final bool heavy;

  int get actualCodeLines {
    if (code.isEmpty) return 0;
    return '\n'.allMatches(code).length + 1;
  }

  int get totalCodeLines {
    final declared = codeTotalLines ?? 0;
    return declared > actualCodeLines ? declared : actualCodeLines;
  }
}

/// A deliberately cheap artifact preview.
///
/// - images use [Image];
/// - code is capped at [v2ArtifactPreviewCodeLineCap] lines;
/// - documents render metadata only;
/// - pages render a supplied static thumbnail or a drawn placeholder;
/// - heavy files skip the body entirely.
///
/// There is no WebView, no HTML renderer and no live page load anywhere in
/// this widget. Files that need more than a glance offer "Open externally".
///
/// Presentational only: the wiring layer owns the data and the callback.
class V2ArtifactPreview extends StatelessWidget {
  const V2ArtifactPreview({
    super.key,
    required this.data,
    this.onOpenExternally,
  });

  final V2ArtifactPreviewData data;
  final VoidCallback? onOpenExternally;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    return Container(
      padding: const EdgeInsets.all(OSpace.m),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(ORadius.l),
        border: Border.all(color: c.hairline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _header(c),
          const SizedBox(height: OSpace.m),
          if (data.heavy) _heavyStage(c) else _stage(c),
          const SizedBox(height: OSpace.m),
          _footer(c),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Header
  // ---------------------------------------------------------------------------

  Widget _header(OColors c) {
    final meta = [
      if (data.typeLabel.isNotEmpty) data.typeLabel,
      if (data.sizeLabel.isNotEmpty) data.sizeLabel,
    ].join(' · ');
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: c.accentSoft,
            borderRadius: BorderRadius.circular(ORadius.m),
          ),
          child: Icon(_typeIcon(data.type), size: 20, color: c.accent),
        ),
        const SizedBox(width: OSpace.s),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                data.name,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: OType.bodyStrong.copyWith(color: c.text),
              ),
              if (meta.isNotEmpty) ...[
                const SizedBox(height: 2),
                Text(
                  meta,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: OType.bodySm.copyWith(color: c.textMuted),
                ),
              ],
              if (data.heavy) ...[
                const SizedBox(height: OSpace.xs),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Semantics(
                    label: 'Large file, preview skipped',
                    excludeSemantics: true,
                    child: const OPill(
                      label: 'Large file',
                      tone: OPillTone.warn,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // Stage — one cheap representation per type.
  // ---------------------------------------------------------------------------

  Widget _stage(OColors c) {
    return switch (data.type) {
      V2ArtifactPreviewType.image => _imageStage(c),
      V2ArtifactPreviewType.code => _codeStage(c),
      V2ArtifactPreviewType.document => _documentStage(c),
      V2ArtifactPreviewType.page => _pageStage(c),
    };
  }

  Widget _imageStage(OColors c) {
    final image = data.image;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(ORadius.m),
          child: AspectRatio(
            aspectRatio: 16 / 10,
            child: Container(
              color: c.codeBg,
              child: image == null
                  ? _imagePlaceholder(c)
                  : Image(
                      image: image,
                      fit: BoxFit.contain,
                      semanticLabel: 'Preview of ${data.name}',
                      errorBuilder: (_, _, _) => _imagePlaceholder(c),
                    ),
            ),
          ),
        ),
        const SizedBox(height: OSpace.s),
        Row(
          children: [
            Icon(Icons.image_rounded, size: 13, color: c.accent),
            const SizedBox(width: OSpace.xs),
            Expanded(
              child: Text(
                'Image preview',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: OType.caption.copyWith(color: c.textMuted),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _imagePlaceholder(OColors c) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(OSpace.m),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 52,
              height: 52,
              decoration: BoxDecoration(
                color: c.accentSoft,
                borderRadius: BorderRadius.circular(ORadius.m),
                border: Border.all(color: c.accentFill.withValues(alpha: 0.35)),
              ),
              child: Icon(Icons.landscape_rounded, size: 26, color: c.accent),
            ),
            const SizedBox(height: OSpace.s),
            Text(
              'Image preview unavailable',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: OType.caption.copyWith(color: c.textMuted),
            ),
          ],
        ),
      ),
    );
  }

  Widget _codeStage(OColors c) {
    final code = data.code;
    final actual = data.actualCodeLines;
    final total = data.totalCodeLines;
    final shown = actual > v2ArtifactPreviewCodeLineCap
        ? v2ArtifactPreviewCodeLineCap
        : actual;
    final language = _codeLanguage(data.codeFile);
    return Container(
      padding: const EdgeInsets.all(OSpace.m),
      decoration: BoxDecoration(
        color: c.codeBg,
        borderRadius: BorderRadius.circular(ORadius.m),
        border: Border.all(color: c.hairline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.code_rounded, size: 16, color: c.accent),
              const SizedBox(width: OSpace.s),
              Expanded(
                child: Text(
                  data.codeFile.isEmpty ? 'Code' : data.codeFile,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: OType.mono.copyWith(color: c.accent),
                ),
              ),
              if (language != null) ...[
                const SizedBox(width: OSpace.s),
                Flexible(
                  child: Text(
                    language,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: OType.overline.copyWith(color: c.textFaint),
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: OSpace.s),
          if (code.isEmpty)
            Text(
              'No preview lines were sent with this artifact.',
              style: OType.bodySm.copyWith(color: c.textMuted),
            )
          else
            _codeText(c, code, shown),
          if (total > shown) ...[
            const SizedBox(height: OSpace.s),
            Text(
              'Showing first $shown of $total lines. Open the file externally '
              'for the rest.',
              style: OType.caption.copyWith(color: c.textMuted),
            ),
          ],
        ],
      ),
    );
  }

  Widget _codeText(OColors c, String code, int maxLines) {
    final lines = code.split('\n').take(maxLines).toList();
    final digits = '${lines.length}'.length;
    final numbered = <String>[
      for (var i = 0; i < lines.length; i++)
        '${(i + 1).toString().padLeft(digits)}  ${lines[i]}',
    ].join('\n');
    return Text(numbered, style: OType.mono.copyWith(color: c.textMuted));
  }

  Widget _documentStage(OColors c) {
    final rows = data.metadata.take(_metadataRowLimit).toList();
    return Container(
      padding: const EdgeInsets.all(OSpace.l),
      decoration: BoxDecoration(
        color: c.codeBg,
        borderRadius: BorderRadius.circular(ORadius.m),
        border: Border.all(color: c.hairline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.description_rounded, size: 22, color: c.accent),
              const SizedBox(width: OSpace.s),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Metadata only',
                      style: OType.bodyStrong.copyWith(color: c.text),
                    ),
                    const SizedBox(height: OSpace.xs),
                    Text(
                      'Documents are not rendered in the app, so large files '
                      'stay fast. Open it externally to read the full file.',
                      style: OType.bodySm.copyWith(color: c.textMuted),
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (rows.isNotEmpty) ...[
            const SizedBox(height: OSpace.m),
            Divider(height: 1, color: c.hairline),
            const SizedBox(height: OSpace.m),
            for (var i = 0; i < rows.length; i++) ...[
              if (i > 0) const SizedBox(height: OSpace.s),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Text(
                      rows[i].label,
                      style: OType.bodySm.copyWith(color: c.textMuted),
                    ),
                  ),
                  const SizedBox(width: OSpace.m),
                  Flexible(
                    child: Text(
                      rows[i].value,
                      textAlign: TextAlign.end,
                      style: OType.bodySm.copyWith(
                        color: c.text,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ],
        ],
      ),
    );
  }

  Widget _pageStage(OColors c) {
    final thumbnail = data.pageThumbnail;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(ORadius.m),
          child: AspectRatio(
            aspectRatio: 16 / 10,
            child: Semantics(
              container: true,
              image: true,
              excludeSemantics: true,
              label: thumbnail == null
                  ? 'Page thumbnail placeholder'
                  : 'Page thumbnail for ${data.name}',
              child: Container(
                decoration: BoxDecoration(
                  color: c.codeBg,
                  border: Border.all(color: c.hairline),
                  borderRadius: BorderRadius.circular(ORadius.m),
                ),
                child: thumbnail == null
                    ? _pagePlaceholder(c)
                    : Image(
                        image: thumbnail,
                        fit: BoxFit.contain,
                        excludeFromSemantics: true,
                        errorBuilder: (_, _, _) => _pagePlaceholder(c),
                      ),
              ),
            ),
          ),
        ),
        if (data.pageUrl.isNotEmpty) ...[
          const SizedBox(height: OSpace.s),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.link_rounded, size: 14, color: c.textFaint),
              const SizedBox(width: OSpace.xs),
              Expanded(
                child: Text(
                  data.pageUrl,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: OType.caption.copyWith(color: c.textMuted),
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }

  Widget _pagePlaceholder(OColors c) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          height: 26,
          padding: const EdgeInsets.symmetric(horizontal: OSpace.s),
          color: c.surfaceAlt,
          child: Row(
            children: [
              for (final color in <Color>[
                c.danger.withValues(alpha: 0.55),
                c.warn.withValues(alpha: 0.55),
                c.success.withValues(alpha: 0.55),
              ]) ...[
                Container(
                  width: 6,
                  height: 6,
                  decoration: BoxDecoration(
                    color: color,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: OSpace.xs),
              ],
            ],
          ),
        ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.all(OSpace.m),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _placeholderBar(c, 0.55),
                const SizedBox(height: 6),
                _placeholderBar(c, 0.9),
                const SizedBox(height: 6),
                _placeholderBar(c, 0.72),
                const Spacer(),
                Row(
                  children: [
                    Icon(Icons.public_rounded, size: 15, color: c.textFaint),
                    const SizedBox(width: OSpace.xs),
                    Expanded(
                      child: Text(
                        'Page thumbnail',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: OType.caption.copyWith(color: c.textFaint),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _placeholderBar(OColors c, double widthFactor) {
    return FractionallySizedBox(
      alignment: Alignment.centerLeft,
      widthFactor: widthFactor,
      child: Container(
        height: 5,
        decoration: BoxDecoration(
          color: c.surfaceRaised,
          borderRadius: BorderRadius.circular(2),
        ),
      ),
    );
  }

  Widget _heavyStage(OColors c) {
    return Container(
      padding: const EdgeInsets.all(OSpace.l),
      decoration: BoxDecoration(
        color: c.codeBg,
        borderRadius: BorderRadius.circular(ORadius.m),
        border: Border.all(color: c.hairline),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: c.surface,
              borderRadius: BorderRadius.circular(ORadius.m),
              border: Border.all(color: c.hairline),
            ),
            child: Icon(Icons.speed_rounded, size: 20, color: c.warn),
          ),
          const SizedBox(width: OSpace.m),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Too large to preview',
                  style: OType.bodyStrong.copyWith(color: c.text),
                ),
                const SizedBox(height: OSpace.xs),
                Text(
                  'Nothing is rendered in the app for large files. Open it '
                  'externally to view the whole thing.',
                  style: OType.bodySm.copyWith(color: c.textMuted),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Footer
  // ---------------------------------------------------------------------------

  Widget _footer(OColors c) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.info_outline_rounded, size: 16, color: c.textFaint),
            const SizedBox(width: OSpace.s),
            Expanded(
              child: Text(
                _note(),
                style: OType.caption.copyWith(color: c.textMuted),
              ),
            ),
          ],
        ),
        const SizedBox(height: OSpace.m),
        OButton(
          label: 'Open externally',
          icon: Icons.open_in_new_rounded,
          variant: OButtonVariant.secondary,
          expand: true,
          semanticLabel: 'Open ${data.name} externally',
          onPressed: onOpenExternally,
        ),
      ],
    );
  }

  String _note() {
    if (data.note.isNotEmpty) return data.note;
    if (data.heavy) {
      return 'Large files are not rendered in the app. Open it externally to '
          'use the full file.';
    }
    return switch (data.type) {
      V2ArtifactPreviewType.image =>
        'Read-only preview. Open the image externally for the full resolution.',
      V2ArtifactPreviewType.code =>
        'Read-only preview. Open the file externally to edit it.',
      V2ArtifactPreviewType.document =>
        'Preview only. Download or open the document externally to read it.',
      V2ArtifactPreviewType.page =>
        'This thumbnail is static. Open the page externally to interact with '
            'it.',
    };
  }

  // ---------------------------------------------------------------------------
  // Small helpers
  // ---------------------------------------------------------------------------

  IconData _typeIcon(V2ArtifactPreviewType type) => switch (type) {
    V2ArtifactPreviewType.image => Icons.image_rounded,
    V2ArtifactPreviewType.code => Icons.code_rounded,
    V2ArtifactPreviewType.document => Icons.description_rounded,
    V2ArtifactPreviewType.page => Icons.public_rounded,
  };

  /// Language badge taken from the file extension, so a `.ts` artifact is
  /// never labelled `HTML`. Null when there is no usable extension.
  String? _codeLanguage(String file) {
    final dot = file.lastIndexOf('.');
    if (dot < 0 || dot == file.length - 1) return null;
    return switch (file.substring(dot + 1).toLowerCase()) {
      'html' || 'htm' => 'HTML',
      'ts' || 'tsx' => 'TS',
      'js' || 'jsx' => 'JS',
      'css' => 'CSS',
      'json' => 'JSON',
      'md' => 'MD',
      'py' => 'Python',
      final other => other.toUpperCase(),
    };
  }
}
