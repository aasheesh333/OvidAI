import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/native_share.dart';
import '../../core/theme.dart';
import '../../l10n/l10n.dart';
import '../share_actions.dart';
import 'aether_primitives.dart';

/// Compact attachment tiles for the chat composer and transcript, modelled on
/// the Gemini / ChatGPT mobile apps: square image thumbnails and fixed-width
/// file cards whose single-line name keeps its extension visible
/// ("very_long_report_na…final.pdf").
///
/// Sizes (dp): composer tiles are [kAttachmentTileExtent] tall, file cards at
/// most [kAttachmentFileCardWidth] wide, and the composer row never exceeds
/// [kComposerAttachmentRowHeight]. Every remove button has a 48dp target.

/// Height of an attachment tile (image side, file-card height).
const double kAttachmentTileExtent = 56;

/// Maximum width of a file card.
const double kAttachmentFileCardWidth = 180;

/// Space above and after a composer tile for the corner remove button. The
/// button's 48dp square sits in this margin and only overlaps the tile's
/// top-end corner, never its centre, so tapping a tile previews it.
const double _kRemoveTop = 16;
const double _kRemoveEnd = 24;

/// Total height of the composer attachment row.
const double kComposerAttachmentRowHeight = kAttachmentTileExtent + _kRemoveTop;

/// Text inside the fixed-size tiles stops growing past this factor; the full
/// name stays available in the tooltip, the semantics label and the preview.
const double _kMaxTileTextScale = 1.3;

/// Coarse file category, which picks the badge icon and colour.
enum AttachmentKind {
  image,
  pdf,
  doc,
  sheet,
  csv,
  archive,
  code,
  audio,
  video,
  other,
}

/// Lowercase extension without the dot, or '' when there is none.
String attachmentExtension(String name) {
  final dot = name.lastIndexOf('.');
  if (dot <= 0 || dot == name.length - 1) return '';
  return name.substring(dot + 1).toLowerCase();
}

AttachmentKind attachmentKindFor(String name) {
  return switch (attachmentExtension(name)) {
    'png' ||
    'jpg' ||
    'jpeg' ||
    'gif' ||
    'webp' ||
    'bmp' ||
    'heic' ||
    'heif' => AttachmentKind.image,
    'pdf' => AttachmentKind.pdf,
    'doc' || 'docx' || 'odt' || 'rtf' || 'pages' => AttachmentKind.doc,
    'xls' || 'xlsx' || 'ods' || 'numbers' => AttachmentKind.sheet,
    'csv' || 'tsv' => AttachmentKind.csv,
    'zip' ||
    'tar' ||
    'gz' ||
    'tgz' ||
    'rar' ||
    '7z' ||
    'bz2' ||
    'xz' => AttachmentKind.archive,
    'mp3' ||
    'wav' ||
    'm4a' ||
    'aac' ||
    'ogg' ||
    'flac' ||
    'opus' => AttachmentKind.audio,
    'mp4' ||
    'mov' ||
    'mkv' ||
    'webm' ||
    'avi' ||
    '3gp' ||
    'm4v' => AttachmentKind.video,
    'dart' ||
    'py' ||
    'js' ||
    'ts' ||
    'jsx' ||
    'tsx' ||
    'json' ||
    'yaml' ||
    'yml' ||
    'toml' ||
    'xml' ||
    'md' ||
    'txt' ||
    'log' ||
    'html' ||
    'css' ||
    'sh' ||
    'java' ||
    'kt' ||
    'swift' ||
    'go' ||
    'rs' ||
    'c' ||
    'cpp' ||
    'h' ||
    'rb' ||
    'php' ||
    'sql' => AttachmentKind.code,
    _ => AttachmentKind.other,
  };
}

/// Human-readable size: "512 B", "48 KB", "1.2 MB".
String formatAttachmentSize(int bytes) => bytes >= 1048576
    ? '${(bytes / 1048576).toStringAsFixed(1)} MB'
    : bytes >= 1024
    ? '${(bytes / 1024).toStringAsFixed(0)} KB'
    : '$bytes B';

/// MIME type for opening [name] in another app, when it is well known.
String? attachmentMime(String name) => switch (attachmentExtension(name)) {
  'png' => 'image/png',
  'jpg' || 'jpeg' => 'image/jpeg',
  'gif' => 'image/gif',
  'webp' => 'image/webp',
  'bmp' => 'image/bmp',
  'pdf' => 'application/pdf',
  'txt' || 'log' || 'md' => 'text/plain',
  'csv' => 'text/csv',
  'json' => 'application/json',
  'html' => 'text/html',
  'zip' => 'application/zip',
  'mp3' => 'audio/mpeg',
  'mp4' => 'video/mp4',
  'doc' => 'application/msword',
  'docx' =>
    'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
  'xls' => 'application/vnd.ms-excel',
  'xlsx' => 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
  _ => null,
};

/// Shortens [name] to [keep] characters of its stem plus an ellipsis, keeping
/// both ends of the stem and the whole extension: `middleEllipsize(
/// 'very_long_report_name_final.pdf', 12)` → `very_lon…inal.pdf`.
///
/// Returns [name] unchanged when the stem already fits. Works on grapheme
/// clusters, so emoji and combining marks are never split.
String middleEllipsize(String name, int keep) {
  final dot = name.lastIndexOf('.');
  final hasExt = dot > 0 && name.length - dot <= 9;
  final stem = (hasExt ? name.substring(0, dot) : name).characters;
  final ext = hasExt ? name.substring(dot) : '';
  if (keep >= stem.length) return name;
  final k = math.max(0, keep);
  final tail = (k * 0.4).ceil();
  final head = k - tail;
  return '${stem.take(head)}…${stem.skip(stem.length - tail)}$ext';
}

/// One line of text that, when too long, drops characters from the middle of
/// the file name rather than the end, so the extension stays readable.
class MiddleEllipsisText extends StatelessWidget {
  final String text;
  final TextStyle style;
  const MiddleEllipsisText(this.text, {super.key, required this.style});

  @override
  Widget build(BuildContext context) {
    final scaler = MediaQuery.textScalerOf(context);
    final dir = Directionality.of(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        var shown = text;
        final max = constraints.maxWidth;
        if (max.isFinite) {
          bool fits(String s) {
            final p = TextPainter(
              text: TextSpan(text: s, style: style),
              textDirection: dir,
              textScaler: scaler,
              maxLines: 1,
            )..layout();
            final ok = p.width <= max;
            p.dispose();
            return ok;
          }

          if (!fits(text)) {
            // Largest stem budget that fits, by binary search.
            var lo = 0, hi = text.characters.length;
            while (lo < hi) {
              final mid = (lo + hi + 1) ~/ 2;
              if (fits(middleEllipsize(text, mid))) {
                lo = mid;
              } else {
                hi = mid - 1;
              }
            }
            shown = middleEllipsize(text, lo);
          }
        }
        return Text(
          shown,
          style: style,
          maxLines: 1,
          softWrap: false,
          overflow: TextOverflow.ellipsis,
        );
      },
    );
  }
}

/// A staged or sent attachment, independent of its storage type.
class AttachmentTileData {
  final String name;
  final int size;

  /// Local file path, or null for messages saved before paths were kept.
  final String? path;
  const AttachmentTileData({required this.name, required this.size, this.path});

  AttachmentKind get kind => attachmentKindFor(name);

  /// Images with a local path render as thumbnails; everything else as cards.
  bool get showsThumbnail => kind == AttachmentKind.image && path != null;
}

String _kindLabel(BuildContext context, AttachmentKind kind) {
  final l = context.l10n;
  return switch (kind) {
    AttachmentKind.image => l.attachmentTypeImage,
    AttachmentKind.pdf => l.attachmentTypePdf,
    AttachmentKind.doc => l.attachmentTypeDoc,
    AttachmentKind.sheet => l.attachmentTypeSheet,
    AttachmentKind.csv => l.attachmentTypeCsv,
    AttachmentKind.archive => l.attachmentTypeArchive,
    AttachmentKind.code => l.attachmentTypeCode,
    AttachmentKind.audio => l.attachmentTypeAudio,
    AttachmentKind.video => l.attachmentTypeVideo,
    AttachmentKind.other => l.attachmentTypeOther,
  };
}

/// Full screen-reader label: name, type and size.
String attachmentSemanticsLabel(BuildContext context, AttachmentTileData a) =>
    context.l10n.attachmentSemantics(
      a.name,
      _kindLabel(context, a.kind),
      formatAttachmentSize(a.size),
    );

IconData _kindIcon(AttachmentKind kind) => switch (kind) {
  AttachmentKind.image => Icons.image_outlined,
  AttachmentKind.pdf => Icons.picture_as_pdf_outlined,
  AttachmentKind.doc => Icons.description_outlined,
  AttachmentKind.sheet => Icons.table_chart_outlined,
  AttachmentKind.csv => Icons.grid_on_outlined,
  AttachmentKind.archive => Icons.folder_zip_outlined,
  AttachmentKind.code => Icons.code,
  AttachmentKind.audio => Icons.audiotrack_outlined,
  AttachmentKind.video => Icons.videocam_outlined,
  AttachmentKind.other => Icons.insert_drive_file_outlined,
};

/// Badge colour per kind. Icons are non-text UI, so they need 3:1 against
/// the tinted badge; both variants clear that on the Aether surfaces.
Color _kindColor(AttachmentKind kind, AetherColors c, bool dark) =>
    switch (kind) {
      AttachmentKind.pdf => c.danger,
      AttachmentKind.sheet || AttachmentKind.csv => c.success,
      AttachmentKind.archive => c.warn,
      AttachmentKind.doc =>
        dark ? const Color(0xFF8AB4F8) : const Color(0xFF1F5FBF),
      AttachmentKind.audio || AttachmentKind.video =>
        dark ? const Color(0xFFC3A6F7) : const Color(0xFF6B3FBF),
      AttachmentKind.image => c.accent,
      AttachmentKind.code || AttachmentKind.other => c.textMuted,
    };

Widget _clampText(BuildContext context, Widget child) =>
    MediaQuery.withClampedTextScaling(
      maxScaleFactor: _kMaxTileTextScale,
      child: child,
    );

/// Square rounded image thumbnail, decoded at its on-screen size.
class AttachmentImageThumb extends StatelessWidget {
  final AttachmentTileData data;
  final double extent;
  const AttachmentImageThumb({
    super.key,
    required this.data,
    this.extent = kAttachmentTileExtent,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.aether;
    final dpr = MediaQuery.devicePixelRatioOf(context);
    return ClipRRect(
      borderRadius: BorderRadius.circular(AetherRadius.rMd),
      child: Container(
        width: extent,
        height: extent,
        color: c.surfaceAlt,
        child: Image.file(
          File(data.path!),
          fit: BoxFit.cover,
          width: extent,
          height: extent,
          cacheWidth: (extent * dpr).round(),
          gaplessPlayback: true,
          excludeFromSemantics: true,
          frameBuilder: (context, child, frame, sync) => AnimatedOpacity(
            opacity: sync || frame != null ? 1 : 0,
            duration: const Duration(milliseconds: 160),
            child: child,
          ),
          errorBuilder: (context, _, _) => Tooltip(
            message: context.l10n.attachmentPreviewError,
            excludeFromSemantics: true,
            child: Center(
              child: Icon(
                Icons.broken_image_outlined,
                size: math.min(24, extent / 2),
                color: c.danger,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Fixed-size file card: kind badge, middle-ellipsized name, "EXT · size".
class AttachmentFileCard extends StatelessWidget {
  final AttachmentTileData data;
  final double width;
  final double height;
  const AttachmentFileCard({
    super.key,
    required this.data,
    this.width = kAttachmentFileCardWidth,
    this.height = kAttachmentTileExtent,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.aether;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final color = _kindColor(data.kind, c, dark);
    final ext = attachmentExtension(data.name).toUpperCase();
    final size = formatAttachmentSize(data.size);
    return Container(
      width: width,
      height: height,
      padding: const EdgeInsetsDirectional.fromSTEB(8, 6, 10, 6),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(AetherRadius.rMd),
        border: Border.all(color: c.hairline),
      ),
      child: Row(
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(AetherRadius.rSm),
            ),
            child: Icon(_kindIcon(data.kind), size: 20, color: color),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: _clampText(
              context,
              Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  MiddleEllipsisText(
                    data.name,
                    style: TextStyle(
                      fontSize: 12.5,
                      height: 1.2,
                      fontWeight: FontWeight.w600,
                      color: c.text,
                    ),
                  ),
                  const SizedBox(height: 1),
                  Text(
                    ext.isEmpty || ext.length > 6 ? size : '$ext · $size',
                    maxLines: 1,
                    softWrap: false,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 11,
                      height: 1.2,
                      color: c.textMuted,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// A tappable attachment tile (thumbnail or card) with the full name in a
/// long-press tooltip and one screen-reader label.
class AttachmentTile extends StatelessWidget {
  final AttachmentTileData data;
  final VoidCallback? onTap;

  /// Image side, or file-card height.
  final double extent;
  final double fileWidth;
  const AttachmentTile({
    super.key,
    required this.data,
    this.onTap,
    this.extent = kAttachmentTileExtent,
    this.fileWidth = kAttachmentFileCardWidth,
  });

  @override
  Widget build(BuildContext context) {
    final visual = data.showsThumbnail
        ? AttachmentImageThumb(data: data, extent: extent)
        : AttachmentFileCard(data: data, width: fileWidth, height: extent);
    return Semantics(
      container: true,
      button: onTap != null,
      label: attachmentSemanticsLabel(context, data),
      hint: onTap == null ? null : context.l10n.attachmentPreviewHint,
      onTap: onTap,
      excludeSemantics: true,
      child: Tooltip(
        message: data.name,
        excludeFromSemantics: true,
        triggerMode: TooltipTriggerMode.longPress,
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            borderRadius: BorderRadius.circular(AetherRadius.rMd),
            onTap: onTap,
            child: visual,
          ),
        ),
      ),
    );
  }
}

/// Opens the preview for [a]: [onOpenImage] for thumbnails, otherwise the
/// file info sheet with Open / Share.
void openAttachmentPreview(
  BuildContext context,
  AttachmentTileData a, {
  void Function(String path)? onOpenImage,
}) {
  if (a.showsThumbnail && onOpenImage != null) {
    onOpenImage(a.path!);
  } else {
    showAttachmentInfoSheet(context, a);
  }
}

/// Bottom sheet with the full file name, type, size and Open / Share.
Future<void> showAttachmentInfoSheet(
  BuildContext context,
  AttachmentTileData a,
) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (sheetCtx) {
      final c = sheetCtx.aether;
      final l = sheetCtx.l10n;
      final dark = Theme.of(sheetCtx).brightness == Brightness.dark;
      final color = _kindColor(a.kind, c, dark);
      final path = a.path;
      final typeLine =
          '${_kindLabel(sheetCtx, a.kind)} · ${formatAttachmentSize(a.size)}';
      return SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsetsDirectional.fromSTEB(20, 0, 20, 16),
          child: Column(
            key: const ValueKey('attachment-info-sheet'),
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      color: color.withValues(alpha: 0.14),
                      borderRadius: BorderRadius.circular(AetherRadius.rMd),
                    ),
                    child: Icon(_kindIcon(a.kind), color: color),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SelectableText(
                          a.name,
                          maxLines: 4,
                          style: AetherType.title.copyWith(color: c.text),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          typeLine,
                          style: TextStyle(fontSize: 12.5, color: c.textMuted),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              if (path == null)
                Text(
                  l.attachmentMissing,
                  style: TextStyle(fontSize: 13, color: c.textMuted),
                )
              else
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    FilledButton.tonalIcon(
                      style: FilledButton.styleFrom(
                        minimumSize: const Size(48, 48),
                      ),
                      onPressed: () async {
                        final messenger = ScaffoldMessenger.maybeOf(context);
                        final noApp = l.attachmentNoApp(a.name);
                        Navigator.pop(sheetCtx);
                        try {
                          await NativeShare.open(
                            path,
                            mime: attachmentMime(a.name),
                          );
                        } catch (_) {
                          messenger?.showSnackBar(
                            SnackBar(
                              content: Text(noApp),
                              behavior: SnackBarBehavior.floating,
                            ),
                          );
                        }
                      },
                      icon: const Icon(Icons.open_in_new, size: 18),
                      label: Text(l.attachmentOpen),
                    ),
                    OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        minimumSize: const Size(48, 48),
                      ),
                      onPressed: () {
                        Navigator.pop(sheetCtx);
                        showNativeShare(context, () => NativeShare.file(path));
                      },
                      icon: const Icon(Icons.share_outlined, size: 18),
                      label: Text(l.attachmentShare),
                    ),
                  ],
                ),
            ],
          ),
        ),
      );
    },
  );
}

/// The composer's staged attachments: one horizontally scrolling row of
/// compact tiles (never wrapping), a count hint near the limit, placeholder
/// tiles for files still being copied, and a 48dp × on every tile.
class ComposerAttachmentRow extends StatelessWidget {
  final List<AttachmentTileData> items;

  /// Files picked but still being copied into the workspace.
  final int staging;
  final int max;
  final ValueChanged<AttachmentTileData> onRemove;
  final void Function(String path)? onOpenImage;

  /// Key of the horizontal scroll view (tests and scroll restoration).
  final Key? scrollKey;

  /// The count hint appears once this many slots or fewer remain.
  static const nearLimitSlots = 5;

  const ComposerAttachmentRow({
    super.key,
    required this.items,
    required this.max,
    required this.onRemove,
    this.staging = 0,
    this.onOpenImage,
    this.scrollKey,
  });

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty && staging == 0) return const SizedBox.shrink();
    final c = context.aether;
    final count = items.length;
    final showHint = count >= max - nearLimitSlots;
    final total = items.length + staging;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (showHint)
          Padding(
            padding: const EdgeInsetsDirectional.only(start: 4, top: 2),
            child: _clampText(
              context,
              Text(
                context.l10n.attachmentCount(count, max),
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: count >= max ? FontWeight.w600 : FontWeight.w500,
                  color: count >= max ? c.warn : c.textMuted,
                ),
              ),
            ),
          ),
        SizedBox(
          height: kComposerAttachmentRowHeight,
          child: ListView.separated(
            key: scrollKey,
            primary: false,
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsetsDirectional.only(start: 2, end: 2),
            itemCount: total,
            separatorBuilder: (_, _) => const SizedBox.shrink(),
            itemBuilder: (context, i) {
              if (i >= items.length) return const _StagingTile();
              final a = items[i];
              return _RemovableTile(
                key: ValueKey(a.path ?? '${a.name}#$i'),
                data: a,
                onTap: () =>
                    openAttachmentPreview(context, a, onOpenImage: onOpenImage),
                onRemove: () => onRemove(a),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _RemovableTile extends StatelessWidget {
  final AttachmentTileData data;
  final VoidCallback onTap;
  final VoidCallback onRemove;
  const _RemovableTile({
    super.key,
    required this.data,
    required this.onTap,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.aether;
    final label = context.l10n.attachmentRemove(data.name);
    return Stack(
      children: [
        Padding(
          padding: const EdgeInsetsDirectional.only(
            top: _kRemoveTop,
            end: _kRemoveEnd,
          ),
          child: AttachmentTile(data: data, onTap: onTap),
        ),
        // The × is drawn as a 22dp disc centred on the tile corner, while
        // the button itself spans a 48dp square for touch.
        PositionedDirectional(
          top: 0,
          end: 0,
          child: IconButton(
            tooltip: label,
            onPressed: onRemove,
            style: IconButton.styleFrom(
              fixedSize: const Size.square(48),
              minimumSize: const Size.square(48),
              padding: const EdgeInsetsDirectional.only(
                top: _kRemoveTop - 11,
                end: 48 - _kRemoveEnd - 11,
              ),
              alignment: AlignmentDirectional.topEnd,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              highlightColor: Colors.transparent,
            ),
            icon: Container(
              width: 22,
              height: 22,
              decoration: BoxDecoration(
                color: c.text.withValues(alpha: 0.85),
                shape: BoxShape.circle,
                border: Border.all(color: c.surface, width: 1.5),
              ),
              child: Icon(Icons.close, size: 13, color: c.surface),
            ),
          ),
        ),
      ],
    );
  }
}

class _StagingTile extends StatelessWidget {
  const _StagingTile();

  @override
  Widget build(BuildContext context) {
    final c = context.aether;
    return Padding(
      padding: const EdgeInsetsDirectional.only(
        top: _kRemoveTop,
        end: _kRemoveEnd,
      ),
      child: Semantics(
        liveRegion: true,
        label: context.l10n.attachmentStaging,
        child: Container(
          key: const ValueKey('attachment-staging-tile'),
          width: kAttachmentTileExtent,
          height: kAttachmentTileExtent,
          decoration: BoxDecoration(
            color: c.surfaceAlt,
            borderRadius: BorderRadius.circular(AetherRadius.rMd),
            border: Border.all(color: c.hairline),
          ),
          child: Center(
            child: SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: c.textMuted,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Attachments under a sent user message: images in a 1/2/3-column grid of
/// rounded thumbnails (Gemini style) and files as compact cards, all aligned
/// to the end of the bubble. Never wider than the bubble, at any text scale.
class TranscriptAttachments extends StatelessWidget {
  final List<AttachmentTileData> items;
  final void Function(String path)? onOpenImage;
  const TranscriptAttachments({
    super.key,
    required this.items,
    this.onOpenImage,
  });

  static const _gap = 4.0;

  @override
  Widget build(BuildContext context) {
    final images = [
      for (final a in items)
        if (a.showsThumbnail) a,
    ];
    final files = [
      for (final a in items)
        if (!a.showsThumbnail) a,
    ];
    return LayoutBuilder(
      builder: (context, constraints) {
        final maxW = constraints.maxWidth.isFinite
            ? math.min(constraints.maxWidth, 360.0)
            : 360.0;
        final cols = images.length == 1
            ? 1
            : images.length == 2 || images.length == 4
            ? 2
            : 3;
        final cap = images.length == 1 ? 200.0 : 112.0;
        final extent = math.min(cap, (maxW - (cols - 1) * _gap) / cols);
        final fileW = math.min(kAttachmentFileCardWidth, maxW);
        return Column(
          key: const ValueKey('transcript-attachments'),
          crossAxisAlignment: CrossAxisAlignment.end,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (images.isNotEmpty)
              SizedBox(
                width: cols * extent + (cols - 1) * _gap,
                child: Wrap(
                  key: const ValueKey('transcript-attachment-grid'),
                  spacing: _gap,
                  runSpacing: _gap,
                  alignment: WrapAlignment.end,
                  children: [
                    for (final a in images)
                      AttachmentTile(
                        data: a,
                        extent: extent,
                        onTap: () => openAttachmentPreview(
                          context,
                          a,
                          onOpenImage: onOpenImage,
                        ),
                      ),
                  ],
                ),
              ),
            if (images.isNotEmpty && files.isNotEmpty)
              const SizedBox(height: 6),
            if (files.isNotEmpty)
              Wrap(
                spacing: 6,
                runSpacing: 6,
                alignment: WrapAlignment.end,
                children: [
                  for (final a in files)
                    AttachmentTile(
                      data: a,
                      fileWidth: fileW,
                      onTap: () => showAttachmentInfoSheet(context, a),
                    ),
                ],
              ),
          ],
        );
      },
    );
  }
}
