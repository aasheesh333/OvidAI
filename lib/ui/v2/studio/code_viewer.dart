// TODO(l10n): move user-facing copy to the ARB files in the localization pass.

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../design/o_components.dart';
import '../../design/o_motion.dart';
import '../../design/o_tokens.dart';

/// What the code viewer is showing right now.
enum V2CodeViewerStatus { loading, content, empty, error }

/// The role of one line when the viewer is in diff mode.
enum V2CodeViewerLineKind { context, added, removed }

/// One line of a file or of a unified diff.
@immutable
class V2CodeViewerLine {
  const V2CodeViewerLine({
    required this.text,
    this.kind = V2CodeViewerLineKind.context,
    this.number,
    this.oldNumber,
    this.newNumber,
  });

  final String text;
  final V2CodeViewerLineKind kind;

  /// 1-based line number for a plain file. When omitted the viewer numbers
  /// the lines in order.
  final int? number;

  /// 1-based old/new line numbers for diff mode. When omitted the viewer
  /// numbers them in order, skipping the side a change does not exist on.
  final int? oldNumber;
  final int? newNumber;
}

/// Everything the code viewer needs to render. Supplied by the wiring layer.
@immutable
class V2CodeViewerData {
  const V2CodeViewerData({
    this.status = V2CodeViewerStatus.content,
    this.fileName = '',
    this.filePath = '',
    this.lines = const <V2CodeViewerLine>[],
    this.diff = false,
    this.lineLimit = defaultLineLimit,
    this.errorMessage,
  }) : assert(lineLimit > 0, 'lineLimit must be positive');

  /// Rendering stops after this many lines so a huge generated file cannot
  /// stall the frame. The rest is reachable through "Open externally".
  static const defaultLineLimit = 2000;

  final V2CodeViewerStatus status;
  final String fileName;
  final String filePath;
  final List<V2CodeViewerLine> lines;

  /// Render two line-number gutters and add/remove markers.
  final bool diff;
  final int lineLimit;
  final String? errorMessage;

  bool get hasContent =>
      status == V2CodeViewerStatus.content && lines.isNotEmpty;

  bool get truncated => lines.length > lineLimit;

  int get addedCount =>
      lines.where((line) => line.kind == V2CodeViewerLineKind.added).length;

  int get removedCount =>
      lines.where((line) => line.kind == V2CodeViewerLineKind.removed).length;

  String get fileType {
    final dot = fileName.lastIndexOf('.');
    if (dot == -1 || dot == fileName.length - 1) return '';
    return fileName.substring(dot + 1).toUpperCase();
  }
}

/// Read-only code and diff viewer for a Studio file.
///
/// The full [V2CodeViewerData.lines] list is owned by the wiring layer; the
/// viewer only builds the first [V2CodeViewerData.lineLimit] rows. [onCopy] is
/// called when the user asks for a copy and should copy the whole file (or the
/// whole diff), even when rendering is capped.
class V2CodeViewerPage extends StatefulWidget {
  const V2CodeViewerPage({
    super.key,
    required this.data,
    this.onCopy,
    this.onOpenExternally,
    this.onRetry,
    this.onBack,
  });

  final V2CodeViewerData data;
  final VoidCallback? onCopy;
  final VoidCallback? onOpenExternally;
  final VoidCallback? onRetry;
  final VoidCallback? onBack;

  @override
  State<V2CodeViewerPage> createState() => _V2CodeViewerPageState();
}

class _V2CodeViewerPageState extends State<V2CodeViewerPage> {
  final ScrollController _vertical = ScrollController();
  final ScrollController _horizontal = ScrollController();

  @override
  void didUpdateWidget(covariant V2CodeViewerPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.data.filePath != widget.data.filePath) {
      if (_vertical.hasClients) _vertical.jumpTo(0);
      if (_horizontal.hasClients) _horizontal.jumpTo(0);
    }
  }

  @override
  void dispose() {
    _vertical.dispose();
    _horizontal.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final data = widget.data;
    final name = data.fileName.trim();
    final path = data.filePath.trim();
    return OScaffold(
      appBar: OAppBar(
        title: name.isEmpty ? 'Code' : name,
        subtitle: path.isEmpty ? null : path,
        actions: [
          OIconButton(
            key: const Key('v2-code-viewer-copy'),
            icon: Icons.copy_rounded,
            semanticLabel: data.diff ? 'Copy diff' : 'Copy file contents',
            tooltip: 'Copy',
            onPressed: data.hasContent ? widget.onCopy : null,
          ),
        ],
      ),
      body: switch (data.status) {
        V2CodeViewerStatus.loading => const OSkeletonList(rows: 6),
        V2CodeViewerStatus.error => OErrorState(
          message:
              data.errorMessage ??
              'We could not load this file. Check your connection and try again.',
          onRetry: widget.onRetry,
        ),
        V2CodeViewerStatus.empty => _buildEmpty(),
        V2CodeViewerStatus.content =>
          data.lines.isEmpty ? _buildEmpty() : _buildContent(context),
      },
    );
  }

  Widget _buildEmpty() {
    return OEmptyState(
      icon: Icons.code_off_rounded,
      title: 'No file selected',
      message: 'Pick a file in Studio to read its code here.',
      action: OButton(
        label: 'Back to workspace',
        variant: OButtonVariant.secondary,
        onPressed: widget.onBack,
      ),
    );
  }

  Widget _buildContent(BuildContext context) {
    final data = widget.data;
    final visible = data.lines.take(data.lineLimit).toList(growable: false);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            OSpace.l,
            OSpace.m,
            OSpace.l,
            OSpace.s,
          ),
          child: OFadeSlide(
            child: _ViewerMeta(
              fileType: data.fileType,
              lineCount: data.lines.length,
              diff: data.diff,
              added: data.addedCount,
              removed: data.removedCount,
              truncated: data.truncated,
            ),
          ),
        ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: OSpace.l),
            child: OFadeSlide(
              delay: OMotion.stagger,
              child: _CodeSurface(
                lines: visible,
                diff: data.diff,
                verticalController: _vertical,
                horizontalController: _horizontal,
              ),
            ),
          ),
        ),
        if (data.truncated)
          _TruncationBar(
            shown: visible.length,
            total: data.lines.length,
            onOpenExternally: widget.onOpenExternally,
          )
        else
          const SizedBox(height: OSpace.l),
      ],
    );
  }
}

class _ViewerMeta extends StatelessWidget {
  const _ViewerMeta({
    required this.fileType,
    required this.lineCount,
    required this.diff,
    required this.added,
    required this.removed,
    required this.truncated,
  });

  final String fileType;
  final int lineCount;
  final bool diff;
  final int added;
  final int removed;
  final bool truncated;

  @override
  Widget build(BuildContext context) {
    final lineLabel = lineCount == 1 ? '1 line' : '$lineCount lines';
    return Wrap(
      spacing: OSpace.s,
      runSpacing: OSpace.xs,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        const _MetaPill(
          label: 'Read only',
          icon: Icons.lock_outline_rounded,
          tone: OPillTone.neutral,
        ),
        if (fileType.isNotEmpty) _MetaPill(label: fileType),
        if (diff) ...[
          _MetaPill(
            label: '+$added',
            tone: OPillTone.success,
            semanticLabel: '$added added ${added == 1 ? 'line' : 'lines'}',
          ),
          _MetaPill(
            label: '−$removed',
            tone: OPillTone.danger,
            semanticLabel:
                '$removed removed ${removed == 1 ? 'line' : 'lines'}',
          ),
        ] else
          _MetaPill(
            label: lineLabel,
            semanticLabel: truncated ? '$lineLabel, preview only' : lineLabel,
          ),
        if (truncated)
          const _MetaPill(
            label: 'Preview',
            tone: OPillTone.warn,
            semanticLabel: 'Large file, preview only',
          ),
      ],
    );
  }
}

class _CodeSurface extends StatelessWidget {
  const _CodeSurface({
    required this.lines,
    required this.diff,
    required this.verticalController,
    required this.horizontalController,
  });

  final List<V2CodeViewerLine> lines;
  final bool diff;
  final ScrollController verticalController;
  final ScrollController horizontalController;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    final resolved = _resolveLines(lines);
    final maxNumber = resolved.fold<int>(1, (largest, line) {
      return math.max(
        largest,
        math.max(line.oldNumber ?? 0, line.newNumber ?? 0),
      );
    });
    final digits = math.max(2, maxNumber.toString().length);
    final scaledMono = MediaQuery.textScalerOf(
      context,
    ).scale(OType.mono.fontSize ?? 13);
    final gutterWidth = math.max(28.0, scaledMono * 0.62 * digits + 12);

    return Container(
      key: const Key('v2-code-viewer-surface'),
      decoration: BoxDecoration(
        color: c.codeBg,
        borderRadius: BorderRadius.circular(ORadius.l),
        border: Border.all(color: c.hairline),
      ),
      clipBehavior: Clip.antiAlias,
      child: Scrollbar(
        controller: verticalController,
        child: SingleChildScrollView(
          controller: verticalController,
          padding: const EdgeInsets.symmetric(vertical: OSpace.s),
          child: SingleChildScrollView(
            controller: horizontalController,
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: OSpace.m),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (var i = 0; i < resolved.length; i++)
                  _CodeLineRow(
                    key: ValueKey<String>('v2-code-line-${i + 1}'),
                    line: resolved[i],
                    plainNumber: i + 1,
                    diff: diff,
                    gutterWidth: gutterWidth,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  List<_ResolvedLine> _resolveLines(List<V2CodeViewerLine> source) {
    var oldNumber = 0;
    var newNumber = 0;
    final resolved = <_ResolvedLine>[];
    for (final line in source) {
      if (line.kind != V2CodeViewerLineKind.added) oldNumber += 1;
      if (line.kind != V2CodeViewerLineKind.removed) newNumber += 1;
      resolved.add(
        _ResolvedLine(
          line: line,
          oldNumber: line.kind == V2CodeViewerLineKind.added
              ? null
              : line.oldNumber ?? oldNumber,
          newNumber: line.kind == V2CodeViewerLineKind.removed
              ? null
              : line.newNumber ?? newNumber,
        ),
      );
    }
    return resolved;
  }
}

@immutable
class _ResolvedLine {
  const _ResolvedLine({
    required this.line,
    required this.oldNumber,
    required this.newNumber,
  });

  final V2CodeViewerLine line;
  final int? oldNumber;
  final int? newNumber;
}

class _CodeLineRow extends StatelessWidget {
  const _CodeLineRow({
    super.key,
    required this.line,
    required this.plainNumber,
    required this.diff,
    required this.gutterWidth,
  });

  final _ResolvedLine line;
  final int plainNumber;
  final bool diff;
  final double gutterWidth;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    final kind = line.line.kind;
    final background = switch (kind) {
      V2CodeViewerLineKind.added => c.success.withValues(alpha: 0.12),
      V2CodeViewerLineKind.removed => c.danger.withValues(alpha: 0.12),
      V2CodeViewerLineKind.context => Colors.transparent,
    };
    final markerColor = switch (kind) {
      V2CodeViewerLineKind.added => c.success,
      V2CodeViewerLineKind.removed => c.danger,
      V2CodeViewerLineKind.context => c.textFaint,
    };
    final marker = switch (kind) {
      V2CodeViewerLineKind.added => '+',
      V2CodeViewerLineKind.removed => '−',
      V2CodeViewerLineKind.context => ' ',
    };
    final codeStyle = OType.mono.copyWith(color: c.text);
    final numberStyle = codeStyle.copyWith(color: c.textFaint);
    final markerStyle = codeStyle.copyWith(
      color: markerColor,
      fontWeight: FontWeight.w600,
    );
    final number = line.line.number ?? plainNumber;

    return Semantics(
      label: _semanticLabel(number),
      excludeSemantics: true,
      child: ColoredBox(
        color: background,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 1),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (diff) ...[
                _Gutter(
                  text: line.oldNumber?.toString() ?? '',
                  width: gutterWidth,
                  style: numberStyle,
                ),
                _Gutter(
                  text: line.newNumber?.toString() ?? '',
                  width: gutterWidth,
                  style: numberStyle,
                ),
                SizedBox(
                  width: 20,
                  child: Text(
                    marker,
                    textAlign: TextAlign.center,
                    softWrap: false,
                    style: markerStyle,
                  ),
                ),
              ] else ...[
                _Gutter(
                  text: number.toString(),
                  width: gutterWidth,
                  style: numberStyle,
                ),
                const SizedBox(width: OSpace.s),
              ],
              Text(line.line.text, softWrap: false, style: codeStyle),
            ],
          ),
        ),
      ),
    );
  }

  String _semanticLabel(int number) {
    final text = line.line.text;
    return switch (line.line.kind) {
      V2CodeViewerLineKind.added =>
        'Added line ${line.newNumber ?? number}: $text',
      V2CodeViewerLineKind.removed =>
        'Removed line ${line.oldNumber ?? number}: $text',
      V2CodeViewerLineKind.context =>
        diff
            ? 'Line ${line.newNumber ?? number}: $text'
            : 'Line $number: $text',
    };
  }
}

class _Gutter extends StatelessWidget {
  const _Gutter({required this.text, required this.width, required this.style});

  final String text;
  final double width;
  final TextStyle style;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      child: Text(
        text,
        textAlign: TextAlign.right,
        softWrap: false,
        style: style,
      ),
    );
  }
}

class _TruncationBar extends StatelessWidget {
  const _TruncationBar({
    required this.shown,
    required this.total,
    this.onOpenExternally,
  });

  final int shown;
  final int total;
  final VoidCallback? onOpenExternally;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    return Container(
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
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.layers_outlined, size: 18, color: c.warn),
              const SizedBox(width: OSpace.s),
              Expanded(
                child: Semantics(
                  label:
                      'Large file. Showing the first $shown of $total lines. '
                      'Open externally to read the rest.',
                  excludeSemantics: true,
                  child: Text(
                    '$shown of $total lines shown',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: OType.bodySm.copyWith(
                      color: c.text,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: OSpace.s),
          OButton(
            key: const Key('v2-code-viewer-open-externally'),
            label: 'Open externally',
            icon: Icons.open_in_new_rounded,
            variant: OButtonVariant.secondary,
            expand: true,
            onPressed: onOpenExternally,
          ),
        ],
      ),
    );
  }
}

/// Small status pill that grows with the text scale instead of clipping at a
/// fixed height.
class _MetaPill extends StatelessWidget {
  const _MetaPill({
    required this.label,
    this.tone = OPillTone.neutral,
    this.icon,
    this.semanticLabel,
  });

  final String label;
  final OPillTone tone;
  final IconData? icon;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    final (bg, fg) = switch (tone) {
      OPillTone.neutral => (c.surfaceAlt, c.textMuted),
      OPillTone.accent => (c.accentSoft, c.accent),
      OPillTone.success => (c.success.withValues(alpha: 0.12), c.success),
      OPillTone.warn => (c.warn.withValues(alpha: 0.12), c.warn),
      OPillTone.danger => (c.danger.withValues(alpha: 0.12), c.danger),
    };
    return Semantics(
      label: semanticLabel ?? label,
      excludeSemantics: true,
      child: Container(
        constraints: const BoxConstraints(minHeight: 24),
        padding: const EdgeInsets.symmetric(
          horizontal: 10,
          vertical: OSpace.xs / 2,
        ),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(ORadius.pill),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              Icon(icon, size: 13, color: fg),
              const SizedBox(width: 5),
            ],
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: OType.caption.copyWith(
                  color: fg,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
